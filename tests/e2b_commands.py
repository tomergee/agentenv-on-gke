#!/usr/bin/env python3
"""Run commands and file operations inside an AgentENV sandbox with the official E2B SDK.

Why not ``Sandbox.connect``: the e2b SDK's connect path calls
``POST /v2/sandboxes/{id}/connect``, which AgentENV v0.2.2 does not serve (it has the v1
``/sandboxes/{id}/connect`` and ``/resume``), so the SDK reports "Paused sandbox not
found". This helper builds the ``Sandbox`` object directly from a known sandbox ID and
routes envd traffic through the gateway with the same headers curl uses
(``X-API-Key``, ``e2b-sandbox-id``, ``e2b-sandbox-port``).

Usage (env: GW=http://127.0.0.1:8080, KEY=<api key>, optional ENVD_VERSION=0.5.15):
  e2b_commands.py run   <sandbox-id> <shell command>     # prints stdout, exits with the command's code
  e2b_commands.py write <sandbox-id> <path> <content>
  e2b_commands.py read  <sandbox-id> <path>
  e2b_commands.py rtt   <sandbox-id>                      # one `echo` round trip, prints seconds
"""
import os
import sys
import time

from packaging.version import Version

from e2b import Sandbox
from e2b.connection_config import ConnectionConfig


def sandbox(sandbox_id: str) -> Sandbox:
    gw = os.environ.get("GW", "http://127.0.0.1:8080")
    key = os.environ["KEY"]
    headers = {"X-API-Key": key, "e2b-sandbox-id": sandbox_id, "e2b-sandbox-port": "49983"}
    token = os.environ.get("ENVD_ACCESS_TOKEN") or None
    if token:
        headers["X-Access-Token"] = token
    cfg = ConnectionConfig(api_url=gw, sandbox_url=gw, api_key=key, extra_sandbox_headers=headers)
    return Sandbox(
        sandbox_id=sandbox_id,
        sandbox_domain=None,
        envd_version=Version(os.environ.get("ENVD_VERSION", "0.5.15")),
        envd_access_token=token,
        traffic_access_token=None,
        connection_config=cfg,
    )


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    op, sid = argv[1], argv[2]
    s = sandbox(sid)
    if op == "run":
        r = s.commands.run(" ".join(argv[3:]), timeout=120)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        return r.exit_code
    if op == "write":
        s.files.write(argv[3], argv[4])
        return 0
    if op == "read":
        sys.stdout.write(s.files.read(argv[3]))
        return 0
    if op == "rtt":
        t0 = time.monotonic()
        r = s.commands.run("echo hello-from-agentenv")
        dt = time.monotonic() - t0
        ok = r.exit_code == 0 and "hello-from-agentenv" in r.stdout
        print(f"{dt:.3f}")
        return 0 if ok else 1
    print(f"unknown op {op}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
