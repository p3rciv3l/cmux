#!/usr/bin/env python3
"""Browser media suspension is exposed as a paired, non-focus socket lease."""

import os
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", cmux.DEFAULT_SOCKET_PATH)


def main() -> int:
    lease_id = f"browser-media-test-{uuid.uuid4()}"

    with cmux(SOCKET_PATH) as client:
        methods = set(client.capabilities().get("methods") or [])
        expected = {"browser.media.suspend_all", "browser.media.resume_all"}
        missing = sorted(expected - methods)
        if missing:
            raise cmuxError(f"Missing browser media methods: {missing}")

        suspended = client._call(
            "browser.media.suspend_all",
            {"lease_id": lease_id},
        )
        resumed = client._call(
            "browser.media.resume_all",
            {"lease_id": lease_id},
        )

    if suspended.get("lease_id") != lease_id:
        raise cmuxError(f"Suspend response lost lease identity: {suspended!r}")
    if resumed.get("lease_id") != lease_id:
        raise cmuxError(f"Resume response lost lease identity: {resumed!r}")
    if not isinstance(suspended.get("candidate_count"), int):
        raise cmuxError(f"Suspend response missing candidate count: {suspended!r}")
    if not isinstance(resumed.get("resumed_count"), int):
        raise cmuxError(f"Resume response missing resumed count: {resumed!r}")

    print("PASS: browser media suspension RPC exposes a paired lease")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
