# Tests

Smoke tests for the AgentENV prototype on `barkland-test`, mapped to
[../plans/acceptance-criteria.md](../plans/acceptance-criteria.md). Results of the last
run are in [RESULTS.md](RESULTS.md).

## Prerequisites

- `kubectl` access to context `gke_gke-ai-eco-dev_us-central1-a_barkland-test`, with the
  prototype deployed (`../scripts/deploy.sh`).
- `curl`, `python3`, `bc`.
- The official E2B Python SDK in a venv, used for command execution inside sandboxes:

  ```bash
  uv venv /tmp/aenv-test-venv --python 3.12
  uv pip install --python /tmp/aenv-test-venv/bin/python e2b
  ```

## Run

```bash
./tests/smoke.sh            # AC-1..AC-10; starts a port-forward on 127.0.0.1:8080 if needed
```

Environment overrides: `GW` (gateway URL), `KEY` (API key; default from
`scripts/get-api-key.sh`), `PY` (venv python), `IMAGE` (default `ubuntu:22.04`),
`SBX_TIMEOUT` (sandbox TTL in seconds, default 900).

The script prints one `AC-n PASS|FAIL: ...` line per criterion and a timing table, kills
every sandbox it created on exit (also on failure), and exits non-zero if any criterion
failed. AC-11 to AC-13 (redeploy, teardown, blast radius) are manual steps described in
the test plan; their evidence is recorded in RESULTS.md.

## Command execution helper

`e2b_commands.py` runs commands and file operations inside a sandbox with the E2B SDK:

```bash
export GW=http://127.0.0.1:8080 KEY=$(../scripts/get-api-key.sh)
/tmp/aenv-test-venv/bin/python tests/e2b_commands.py run   <sandbox-id> 'uname -r'
/tmp/aenv-test-venv/bin/python tests/e2b_commands.py write <sandbox-id> /root/x.txt hello
/tmp/aenv-test-venv/bin/python tests/e2b_commands.py read  <sandbox-id> /root/x.txt
```

It builds the `Sandbox` object directly instead of calling `Sandbox.connect`, because the
SDK's connect uses `POST /v2/sandboxes/{id}/connect`, which AgentENV v0.2.2 does not
serve. envd traffic is routed through the gateway with the `X-API-Key`, `e2b-sandbox-id`
and `e2b-sandbox-port: 49983` headers (`extra_sandbox_headers`), the same contract curl
uses. The `/proxy/...` path prefix from newer upstream docs is not served by v0.2.2;
header routing with the original path (`/health`, `/files?path=...`) is.

## Sweep every converted image

`tests/sweep.sh` runs each converted SWE-bench Verified image once (cold create from the
overlaybd image with 2 CPU / 4096 MB, wait for running, one command via the E2B SDK, kill),
`PAR` at a time (default 8), and writes `tests/sweep-results.csv` plus `tests/sweep-summary.md`.
Only instances whose converted tag exists are run; re-running fills gaps (`RESUME=1`).
`tests/sweep-one.sh <instance>` is the per-image worker.
