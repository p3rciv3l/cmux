#!/usr/bin/env python3
"""Verify the real tab-rename path in an isolated tagged app and Codex home."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests_v2'))
from cmux import cmux
from test_bridge import TitleSyncTest


def main():
    tag = os.environ['CMUX_TAG']
    assert tag == 'codex-title-sync', 'This harness only targets its dedicated test build'
    log = Path('/tmp/cmux-codex-title-sync-build.log').read_text()
    app = Path(log.split('App path:\n', 1)[1].splitlines()[0].strip())
    assert app.name == 'cmux DEV codex-title-sync.app'
    fixture = TitleSyncTest()
    fixture.codex = str(Path.home() / '.cargo/bin/codex')
    fixture.setUp()
    process = None
    try:
        fixture.name('Initial runtime title')
        environment = dict(os.environ, CODEX_HOME=fixture.home.name,
                           CMUX_SOCKET_PATH=f'/tmp/cmux-debug-{tag}.sock')
        process = subprocess.Popen([str(app / 'Contents/MacOS/cmux DEV')],
                                   env=environment, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        with cmux(environment['CMUX_SOCKET_PATH']) as client:
            workspace = client.new_workspace()
            try:
                surface = client._call('surface.list', {'workspace_id': workspace})['surfaces'][0]['id']
                # Use the exact hook registration command; this reaches Workspace.recordAgentPID.
                client._socket.sendall((f'set_agent_pid codex.{fixture.thread_id} '
                    f'{fixture.server.process.pid} --tab={workspace} --panel={surface}\n').encode())
                assert client._recv_line() == 'OK'

                def tab_title():
                    rows = client._call('surface.list', {'workspace_id': workspace})['surfaces']
                    return next(row['title'] for row in rows if row['id'] == surface)

                def wait_for(predicate, timeout=5):
                    deadline = time.monotonic() + timeout
                    while not predicate():
                        if time.monotonic() >= deadline:
                            raise AssertionError('Timed out waiting for title synchronization')

                wait_for(lambda: tab_title() == 'Initial runtime title')
                for i in range(3):
                    title = f'this is a test {i}'
                    start = time.monotonic()
                    # Same shared Workspace.setPanelCustomTitle action used by Command-R.
                    client._call('surface.action', {'surface_id': surface, 'action': 'rename', 'title': title})
                    wait_for(lambda: fixture.rpc('thread/read', {'threadId': fixture.thread_id})['thread']['name'] == title)
                    elapsed = (time.monotonic() - start) * 1000
                    print('Cmux tab -> persisted Codex title ms:', round(elapsed, 2))
                    assert elapsed < 100, elapsed
                    results = fixture.rpc('thread/list', {'searchTerm': title})['data']
                    assert any(t['id'] == fixture.thread_id for t in results), 'Renamed session absent from search'
                    title = f'Codex renamed this {i}'
                    start = time.monotonic()
                    fixture.name(title)
                    wait_for(lambda: tab_title() == title)
                    elapsed = (time.monotonic() - start) * 1000
                    print('Codex rename -> Cmux tab ms:', round(elapsed, 2))
                    assert elapsed < 100, elapsed
                print('PASS: registration, tab rename, Codex session search, reverse sync')
            finally:
                client.close_workspace(workspace)
    finally:
        if process is not None:
            process.terminate()
            process.wait(timeout=15)
        fixture.doCleanups()


if __name__ == '__main__':
    main()
