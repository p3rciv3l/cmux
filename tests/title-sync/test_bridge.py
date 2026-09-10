#!/usr/bin/env python3
"""Exercise Codex's real metadata API with an isolated home; no turns/model calls."""
import json
from datetime import datetime, timezone
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Lines:
    def __init__(self, process):
        self.process = process
        self.lines = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            self.lines.put(line.rstrip('\n'))

    def send(self, line):
        self.process.stdin.write(line + '\n')
        self.process.stdin.flush()

    def next(self):
        return self.lines.get(timeout=10)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=10)
        self.process.stdin.close()
        self.process.stdout.close()


class TitleSyncTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='cmux-title-test-build-')
        cls.binary = str(Path(cls.build.name) / 'bridge')
        cls.codex = os.environ.get('CODEX_TEST_BINARY') or shutil.which('codex')
        if not cls.codex:
            raise unittest.SkipTest('Codex CLI required')
        subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                        str(ROOT / 'Sources/CodexTabTitleSync.swift'),
                        str(ROOT / 'tests/title-sync/BridgeHarness.swift'),
                        '-o', cls.binary], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.home = tempfile.TemporaryDirectory(prefix='cmux-title-test-home-', ignore_cleanup_errors=True)
        self.addCleanup(self.home.cleanup)
        env = dict(os.environ, CODEX_HOME=self.home.name)
        self.server = Lines(subprocess.Popen(
            [self.codex, 'app-server', '--stdio'], env=env, text=True,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL))
        self.addCleanup(self.server.close)
        self.request_id = 0
        self.rpc('initialize', {'clientInfo': {'name': 'cmux_title_test', 'version': '1'}})
        self.server.send('{"method":"initialized"}')
        self.thread_id = self.rpc('thread/start', {})['thread']['id']
        # Persist a real conversation without invoking a model. Empty threads take
        # Codex's missing-rollout retry path and are not representative of a chat.
        self.rpc('thread/inject_items', {'threadId': self.thread_id, 'items': [
            {'type': 'message', 'role': 'user', 'content': [
                {'type': 'input_text', 'text': 'Title sync test fixture'}]}]})
        # The resume picker excludes conversations without a UserMessage event.
        # Seed that fixture event only in this temporary home's rollout.
        rollout = Path(self.rpc('thread/read', {'threadId': self.thread_id})['thread']['path'])
        assert rollout.is_relative_to(Path(self.home.name).resolve())
        with rollout.open('a') as stream:
            stream.write(json.dumps({'timestamp': datetime.now(timezone.utc).isoformat(),
                'type': 'event_msg', 'payload': {'type': 'user_message',
                'message': 'Title sync test fixture', 'images': [], 'local_images': [],
                'text_elements': []}}) + '\n')

    def rpc(self, method, params):
        self.request_id += 1
        self.server.send(json.dumps({'id': self.request_id, 'method': method, 'params': params}))
        while True:
            value = json.loads(self.server.next())
            if value.get('id') == self.request_id:
                self.assertNotIn('error', value)
                return value['result']

    def name(self, name):
        self.rpc('thread/name/set', {'threadId': self.thread_id, 'name': name})

    def bridge(self):
        bridge = Lines(subprocess.Popen(
            [self.binary, self.thread_id, self.codex, self.home.name], text=True,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL))
        self.addCleanup(bridge.close)
        return bridge

    def test_cmux_renames_persist(self):
        self.name('Initial Codex name')
        bridge = self.bridge()
        self.assertEqual(bridge.next(), 'INITIAL Initial Codex name')
        latencies = []
        queued_ms = []
        for name in ['Manual name', 'Quotes " and newline-safe \\ text', '日本語 ✓']:
            start = time.monotonic()
            bridge.send(name)
            queued = bridge.next()
            self.assertTrue(queued.startswith('QUEUED '), queued)
            queued_ms.append(float(queued.split()[1]) * 1000)
            self.assertLess(queued_ms[-1], 100)
            self.assertEqual(bridge.next(), 'RENAMED')
            latencies.append((time.monotonic() - start) * 1000)
            # Read through the independent server, proving the name was persisted by Codex.
            thread = self.rpc('thread/read', {'threadId': self.thread_id})['thread']
            self.assertEqual(thread['name'], name)
        print('Synchronous rename dispatch ms:', [round(x, 3) for x in queued_ms])
        print('Warm rename acknowledgment ms:', [round(x, 2) for x in latencies])
        # Report Codex persistence latency separately from the immediate cmux UI mutation.
        self.assertLess(max(latencies), 100)

    def test_full_bidirectional_sync(self):
        self.name('Initial name')
        bridge = self.bridge()
        self.assertEqual(bridge.next(), 'INITIAL Initial name')
        bridge.send('Name from cmux')
        self.assertTrue(bridge.next().startswith('QUEUED '))
        self.assertEqual(bridge.next(), 'RENAMED')
        start = time.monotonic()
        self.name('Name from Codex')
        self.assertEqual(bridge.next(), 'INITIAL Name from Codex')
        elapsed = (time.monotonic() - start) * 1000
        print('Codex to cmux ms:', elapsed)
        self.assertLess(elapsed, 100)
        bridge.send('Second cmux name')
        self.assertTrue(bridge.next().startswith('QUEUED '))
        self.assertEqual(bridge.next(), 'RENAMED')
        self.assertEqual(self.rpc('thread/read', {'threadId': self.thread_id})['thread']['name'], 'Second cmux name')

    def test_delayed_initial_title_from_another_server(self):
        bridge = self.bridge()
        self.name('Generated after startup')
        self.assertEqual(bridge.next(), 'INITIAL Generated after startup')

    def test_manual_rename_before_initial_title(self):
        self.name('Existing name before bridge initialization')
        bridge = self.bridge()
        bridge.send('Manual wins before initialization')
        self.assertTrue(bridge.next().startswith('QUEUED '))
        self.assertEqual(bridge.next(), 'RENAMED')
        self.assertEqual(self.rpc('thread/read', {'threadId': self.thread_id})['thread']['name'],
                         'Manual wins before initialization')


if __name__ == '__main__':
    unittest.main()
