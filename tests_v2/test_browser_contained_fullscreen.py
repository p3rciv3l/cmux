#!/usr/bin/env python3
"""Behavioral fullscreen fixture, run only against an explicitly selected tagged app.

CMUX_SOCKET_PATH=/tmp/cmux-debug-TAG.sock python3 tests_v2/test_browser_contained_fullscreen.py

Uses native debug.shortcut.simulate input and verifies trusted, activated DOM input.
No app is launched. Timing is request-to-two-animation-frames in the page, not socket
round-trip timing. Whole-window containment and visual fidelity require UI validation.
"""

import argparse
from contextlib import contextmanager
import http.server
import json
import os
import sys
import threading
import time

from cmux import cmux, cmuxError


HTML = r"""<!doctype html><meta charset="utf-8"><title>Contained fullscreen behavior</title>
<style>body { margin: 19px; background: #eee; } #target { width: 260px; height: 170px; }
#inner { width: 80px; height: 50px; background: #fa4; } video { width: 200px; height: 120px; }
:fullscreen { --fullscreen-probe: native-selector; }</style>
<div id="target" style="position:relative; color:rgb(12, 34, 56); overflow:visible; background:#48c">
Target<div id="inner">Nested</div><button id="trigger">Run armed action</button></div>
<video id="video" controls muted></video><div id="frames"></div>
<script>
(() => {
  const baseline = () => Array.from(document.querySelectorAll('html,body,#target,#inner,#video'))
    .map(el => [el.tagName, el.id, el.hasAttribute('style'), Array.from(el.style).sort()
      .map(name => [name, el.style.getPropertyValue(name), el.style.getPropertyPriority(name)])]);
  const original = baseline();
  const events = [], inputs = [];
  for (const name of ['fullscreenchange','webkitfullscreenchange','fullscreenerror'])
    document.addEventListener(name, () => events.push({name, at: performance.now(),
      active: document.fullscreenElement?.id || document.webkitFullscreenElement?.id || null}));
  const paintResolvers = new Map();
  const painted = () => new Promise(resolve => {
    if (parent === window) requestAnimationFrame(() => requestAnimationFrame(resolve));
    else {
      const token = Math.random().toString(36); paintResolvers.set(token, resolve);
      parent.postMessage({fixture:'fullscreen', paint:token}, '*');
    }
  });
  let paintReady = false; painted().then(() => { paintReady = true; });
  let command = null, result = null;
  const active = () => document.fullscreenElement || document.webkitFullscreenElement;
  async function run(event) {
    if (!command) return;
    const action = command; command = null;
    const started = performance.now();
    const report = {action, trusted: event.isTrusted,
      activated: navigator.userActivation ? navigator.userActivation.isActive : null};
    try {
      const el = document.getElementById(action === 'nested' ? 'inner' : 'target');
      const video = document.getElementById('video');
      let pending;
      if (action === 'standard' || action === 'nested') pending = el.requestFullscreen();
      else if (action === 'prefixed') pending = el.webkitRequestFullscreen();
      else if (action === 'video') pending = video.webkitEnterFullscreen();
      else if (action === 'presentation') pending = video.webkitSetPresentationMode('fullscreen');
      else if (action === 'presentation-exit') pending = video.webkitSetPresentationMode('inline');
      else if (action === 'exit') pending = document.exitFullscreen();
      else if (action === 'prefixed-exit') pending = document.webkitExitFullscreen();
      else if (action === 'video-exit') pending = video.webkitExitFullscreen();
      else if (action === 'detached') pending = document.createElement('div').requestFullscreen();
      else if (action === 'remove') active().remove();
      else throw new Error('Unknown action: ' + action);
      report.promise = !!pending && typeof pending.then === 'function';
      await pending;
      report.resolved = true;
    } catch (error) { report.resolved = false; report.error = {name: error.name, message: error.message}; }
    await painted();
    const current = active();
    const rect = current?.getBoundingClientRect();
    Object.assign(report, {elapsed: performance.now() - started, active: current?.id || null,
      nativeFullscreenSelector: current ? getComputedStyle(current).getPropertyValue('--fullscreen-probe').trim() === 'native-selector' : null,
      backgroundColor: current ? getComputedStyle(current).backgroundColor : null,
      videoActive: !!document.getElementById('video')?.webkitDisplayingFullscreen,
      presentation: document.getElementById('video')?.webkitPresentationMode,
      policyAPIAvailable: !!(document.permissionsPolicy || document.featurePolicy),
      rect: rect ? {x:rect.x,y:rect.y,width:rect.width,height:rect.height} : null,
      viewport: {width: innerWidth, height: innerHeight}, stylesRestored: JSON.stringify(original) === JSON.stringify(baseline()),
      events: events.slice()});
    result = report;
    if (parent !== window) parent.postMessage({fixture:'fullscreen', result:report}, '*');
  }
  document.getElementById('trigger').addEventListener('click', run);
  document.addEventListener('keydown', event => { inputs.push({key:event.key, trusted:event.isTrusted, activated:navigator.userActivation?.isActive}); if(event.key === 'f') { event.preventDefault(); run(event); } });
  const frameResults = {}, frameArmed = {};
  window.addEventListener('message', event => {
    if (event.data?.fixture !== 'fullscreen') return;
    if (parent !== window && event.source === parent && event.data.painted) {
      paintResolvers.get(event.data.painted)?.(); paintResolvers.delete(event.data.painted);
    } else if (parent !== window && event.source === parent && event.data.arm) {
      result = null; command = event.data.arm;
      document.getElementById('trigger').focus();
      parent.postMessage({fixture:'fullscreen', armed:true}, '*');
    } else if (parent === window) {
      const frame = Array.from(document.querySelectorAll('iframe')).find(frame => frame.contentWindow === event.source);
      if (!frame) return;
      if (event.data.paint) requestAnimationFrame(() => requestAnimationFrame(() =>
        event.source.postMessage({fixture:'fullscreen', painted:event.data.paint}, '*')));
      if (event.data.result) frameResults[frame.id] = event.data.result;
      if (event.data.armed) frameArmed[frame.id] = true;
    }
  });
  window.harness = {arm(action) { result = null; command = action; }, result: () => result,
    paintReady: () => paintReady,
    diagnostics: () => ({inputs, command, focused:document.hasFocus(), activeElement:document.activeElement?.tagName}),
    armFrame(id, action) { frameResults[id] = null; frameArmed[id] = false;
      const frame = document.getElementById(id); frame.focus(); frame.contentWindow.focus();
      frame.contentWindow.postMessage({fixture:'fullscreen', arm:action}, '*'); },
    frameResult: id => frameResults[id], frameArmed: id => frameArmed[id],
    state: () => ({active: active()?.id || null, stylesRestored: JSON.stringify(original) === JSON.stringify(baseline())})};
  if (location.pathname === '/') {
    for (const [id, policy] of [['allowed', 'fullscreen *'], ['denied', "fullscreen 'none'"],
      ['cross-allowed', 'fullscreen *'], ['cross-denied', "fullscreen 'none'"], ['policy-denied', 'fullscreen *']]) {
      const frame = document.createElement('iframe'); frame.id = id; frame.allow = policy;
      frame.src = id.startsWith('cross-') ? location.origin.replace('127.0.0.1', 'localhost') + '/frame' :
        (id === 'policy-denied' ? '/policy-denied' : '/frame');
      document.getElementById('frames').append(frame);
    }
  }
})();
</script>"""


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = HTML.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        if self.path == "/policy-denied":
            self.send_header("Permissions-Policy", "fullscreen=()")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


@contextmanager
def fixture_server():
    """Yield a local fixture URL, also usable by a separately controlled real UI."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/"
    finally:
        server.shutdown()
        server.server_close()


def require(condition, message):
    if not condition:
        raise cmuxError(message)


def wait_for(probe, label, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.01)
    raise cmuxError(f"Timed out: {label}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cycles", type=int, default=10)
    parser.add_argument("--max-ms", type=float, default=100)
    parser.add_argument("--serve", action="store_true", help="Print fixture URL and serve for independent native UI checks")
    args = parser.parse_args()
    if args.serve:
        with fixture_server() as fixture_url:
            print(fixture_url, flush=True)
            try:
                threading.Event().wait()
            except KeyboardInterrupt:
                pass
        return
    socket_path = os.environ.get("CMUX_SOCKET_PATH", "")
    require(socket_path.startswith("/tmp/cmux-debug-") and socket_path.endswith(".sock"),
            "Set CMUX_SOCKET_PATH to an isolated tagged app socket; this test never launches an app")
    require(args.cycles > 0 and args.max_ms > 0, "cycles and max-ms must be positive")
    reports = []
    engine_gaps = []
    with fixture_server() as fixture_url:
        with cmux(socket_path) as client:
            workspace = client.new_workspace()
            try:
                client.select_workspace(workspace)
                surface = client.new_surface(panel_type="browser", url=fixture_url)
                client.focus_surface(surface)
                client.activate_app()

                def evaluate(script):
                    return (client._call("browser.eval", {"surface_id": surface, "script": script}) or {}).get("value")

                wait_for(lambda: evaluate("!!window.harness && harness.paintReady() && ['allowed','denied'].every(id => !!document.getElementById(id).contentWindow.harness)"), "fixture loaded and painting")

                def action(name, frame=None, succeeds=True):
                    client.focus_webview(surface)
                    if frame:
                        evaluate(f"harness.armFrame({json.dumps(frame)}, {json.dumps(name)}); void 0")
                        wait_for(lambda: evaluate(f"harness.frameArmed({json.dumps(frame)})"), f"{frame} armed")
                        result_expression = f"harness.frameResult({json.dumps(frame)})"
                    else:
                        evaluate(f"harness.arm({json.dumps(name)}); document.getElementById('trigger').focus(); void 0")
                        result_expression = "harness.result()"
                    client.simulate_shortcut("f")
                    try:
                        report = wait_for(lambda: evaluate(result_expression), f"{frame or 'main'} {name}")
                    except cmuxError:
                        print(json.dumps({"diagnostics": evaluate("harness.diagnostics()"), "webview_focused": client.is_webview_focused(surface)}), flush=True)
                        raise
                    reports.append(report)
                    print(json.dumps({"frame": frame or "main", "action_report": report}), flush=True)
                    require(report["trusted"] and report["activated"] is not False,
                            f"Native input did not produce trusted user activation: {report}")
                    if succeeds is not None:
                        require(report["resolved"] == succeeds, f"Unexpected completion: {report}")
                    if report["resolved"]:
                        require(report["elapsed"] < args.max_ms, f"Exceeded {args.max_ms} ms request-to-frame budget: {report}")
                    return report

                def entered(report, expected="target"):
                    require(report["active"] == expected, f"Wrong fullscreen element: {report}")
                    if expected == "target":
                        require(report["backgroundColor"] == "rgb(68, 136, 204)", f"Fullscreen replaced the authored target background: {report}")
                    rect, viewport = report["rect"], report["viewport"]
                    require(abs(rect["x"]) <= 1 and abs(rect["y"]) <= 1 and
                            abs(rect["width"] - viewport["width"]) <= 1 and
                            abs(rect["height"] - viewport["height"]) <= 1, f"Not viewport-contained: {report}")

                def exited(report):
                    require(report["active"] is None and report["stylesRestored"], f"Exit did not restore DOM: {report}")

                for _ in range(args.cycles):
                    enter = action("standard")
                    require(enter["promise"], f"Standard request must return a Promise: {enter}")
                    require(any(event["name"] == "fullscreenchange" and event["active"] == "target"
                                for event in enter["events"]), f"Missing fullscreenchange notification: {enter}")
                    entered(enter)
                    leave = action("exit")
                    require(leave["promise"], f"Standard exit must return a Promise: {leave}")
                    exited(leave)
                    for report in [enter, leave]:
                        require(report["elapsed"] < args.max_ms, f"Exceeded {args.max_ms} ms request-to-frame budget: {report}")

                entered(action("prefixed"))
                exited(action("prefixed-exit"))
                entered(action("standard"))
                entered(action("nested"), "inner")
                entered(action("exit"))
                exited(action("exit"))
                detached = action("detached", succeeds=False)
                require(detached.get("error") and detached["active"] is None, f"Detached request corrupted state: {detached}")
                for enter, leave in [("video", "video-exit"), ("presentation", "presentation-exit")]:
                    entered(action(enter), "video")
                    exited(action(leave))
                for allowed, denied_id in [("allowed", "denied"), ("cross-allowed", "cross-denied")]:
                    entered(action("standard", frame=allowed))
                    require(evaluate(f"document.fullscreenElement === document.getElementById({json.dumps(allowed)})"), "Ancestor fullscreenElement must identify the fullscreen iframe")
                    exited(action("exit", frame=allowed))
                    require(evaluate("document.fullscreenElement === null"), "Iframe exit must clear ancestor state")
                    denied = action("standard", frame=denied_id, succeeds=False)
                    require(denied["active"] is None and evaluate("document.fullscreenElement === null"), "Denied iframe changed fullscreen state")
                denied = action("standard", frame="policy-denied", succeeds=None)
                if denied["resolved"]:
                    require(not denied["policyAPIAvailable"], "Permissions-Policy denied request succeeded despite an available policy API")
                    # A separate unmodified WKWebView probe is required to attribute
                    # this result to WebKit. The native probe for this task confirmed
                    # fullscreenEnabled=true under this header without our shim.
                    engine_gaps.append("HTTP Permissions-Policy fullscreen=() was not enforced; this WebKit lacks a document policy API (native baseline separately confirmed)")
                    exited(action("exit", frame="policy-denied"))
                else:
                    require(denied["active"] is None and evaluate("document.fullscreenElement === null"), "Permissions-Policy HTTP header denial changed fullscreen state")
                entered(action("standard"))
                evaluate("document.getElementById('target').style.letterSpacing = '3px'; void 0")
                changed = action("exit")
                require(changed["active"] is None and evaluate("document.getElementById('target').style.letterSpacing === '3px'"), "Fullscreen exit discarded an unrelated style edit made by the page")
                entered(action("standard"))
                removed = action("remove")
                require(removed["active"] is None, f"Removed target remained fullscreen: {removed}")
                limitations = list(engine_gaps)
                if any(report["active"] and not report["nativeFullscreenSelector"] for report in reports):
                    limitations.append("Native :fullscreen CSS selector does not match the presented element")
                print(json.dumps({"status": "PASS" if not limitations else "COMPATIBILITY_GAPS",
                                  "limitations": limitations, "cycles": args.cycles, "reports": reports}, indent=2))
                return 1 if limitations else 0
            finally:
                client.close_workspace(workspace)


if __name__ == "__main__":
    sys.exit(main())
