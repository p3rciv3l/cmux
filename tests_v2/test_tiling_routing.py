#!/usr/bin/env python3
"""Verify tiling target rejection without touching any pre-existing workspace.

Run against an isolated tagged Debug app: CMUX_TAG=tiling python3 tests_v2/test_tiling_routing.py
"""

import os
import re
import time
import uuid
from typing import Any

from cmux import cmux, cmuxError


def cleanup_owned_fixture(socket_path: str, window_id: str, workspace_id: str | None,
                          timeout_s: float = 3) -> dict[str, Any]:
    """Dispose the test workspace before closing its explicitly owned window.

    A closed window may remain in the recoverable-route inventory with its
    initial default workspace. A fresh connection keeps cleanup independent
    of any failed request on the test connection.
    """
    result: dict[str, Any] = {"window_id": window_id, "workspace_id": workspace_id}
    with cmux(socket_path) as cleanup:
        if workspace_id is not None:
            cleanup._call("workspace.close", {"window_id": window_id, "workspace_id": workspace_id})
            remaining = cleanup._call("workspace.list", {"window_id": window_id})["workspaces"]
            remaining_ids = [workspace["id"] for workspace in remaining]
            if workspace_id in remaining_ids:
                raise cmuxError(f"Owned fixture workspace was not disposed: {workspace_id}")
            result["fixture_workspace_disposed"] = True
            result["remaining_default_workspace_ids"] = remaining_ids
        cleanup.close_window(window_id)
        deadline = time.monotonic() + timeout_s
        while True:
            window = next((item for item in cleanup.list_windows() if item["id"] == window_id), None)
            if window is None or window.get("visible") is False:
                result["window_visible"] = False
                result["retained_recoverable_route"] = window is not None
                return result
            if time.monotonic() >= deadline:
                raise cmuxError(f"Owned fixture window remained visible after close: {window_id}")
            time.sleep(0.01)


def main() -> None:
    tag = os.environ.get("CMUX_TAG", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", tag):
        raise ValueError("CMUX_TAG must name an isolated Debug app")
    socket = f"/tmp/cmux-debug-{tag}.sock"
    if os.environ.get("CMUX_SOCKET_PATH", socket) != socket:
        raise ValueError("CMUX_SOCKET_PATH must match CMUX_TAG")

    with cmux(socket) as client:
        window_id = client.new_window()
        workspace_id = None
        try:
            workspace_id = client.new_workspace(window_id=window_id)
            client.select_workspace(workspace_id)
            target = {"window_id": window_id, "workspace_id": workspace_id}
            initial = client._call("workspace.tiling.state", target)
            assert initial["layout"] == "manual", initial
            invalid_targets = [
                {key: "not-a-valid-id"}
                for key in ("window_id", "workspace_id", "surface_id", "terminal_id", "tab_id", "pane_id")
            ] + [
                {key: str(uuid.uuid4())}
                for key in ("window_id", "workspace_id", "surface_id", "terminal_id", "tab_id", "pane_id")
            ]
            for invalid in invalid_targets:
                try:
                    result = client._call("workspace.tiling.action", {
                        "window_id": window_id, **invalid, "action": "tile",
                    })
                except cmuxError:
                    pass
                else:
                    raise AssertionError(f"Invalid target accepted: {invalid}: {result}")
                current = client._call("workspace.tiling.state", target)
                assert current["layout"] == "manual", (invalid, current)
                assert current["pane_ids"] == initial["pane_ids"], (invalid, current)

            # Explicit workspace targets take priority over stale ambient pane
            # context; valid pane targeting resolves the same owned workspace.
            result = client._call("workspace.tiling.action", {
                **target, "pane_id": str(uuid.uuid4()), "action": "tile",
            })
            assert result["workspace_id"] == workspace_id, result
            assert result["layout"] == "tile", result
            result = client._call("workspace.tiling.action", {
                "window_id": window_id, "pane_id": initial["pane_ids"][0], "action": "manual",
            })
            assert result["workspace_id"] == workspace_id, result
            assert result["layout"] == "manual", result
            print("PASS: invalid tiling targets rejected; explicit workspace and valid pane routing preserved")
        finally:
            print("Cleanup:", cleanup_owned_fixture(socket, window_id, workspace_id))


if __name__ == "__main__":
    main()
