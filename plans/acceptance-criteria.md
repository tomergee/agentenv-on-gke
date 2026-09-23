# Acceptance criteria: AgentENV prototype on `barkland-test`

Conventions used below:

- `$K` = `kubectl --context gke_gke-ai-eco-dev_us-central1-a_barkland-test -n agentenv-system`
- `$GW` = `http://127.0.0.1:8080` (port-forward to Service `agentenv-gateway`, see the test plan)
- `$KEY` = the API key from Secret `agentenv-auth`
- `AUTH` = `-H "X-API-Key: $KEY"`
- `$ID` = a sandbox ID returned by a create call; `$TOK` = its `envdAccessToken`
- Timings are wall-clock seconds measured by the tester (`date +%s.%N` around the call, or
  the time to the first `state: running`). Every timing criterion is **record only**: it
  passes when the number is written down with the method used. Nested virtualization on a
  `c2-standard-8` makes upstream targets meaningless here.
- Evidence is a command transcript or a JSON excerpt pasted into `tests/RESULTS.md`.

The API paths are those of AgentENV v0.2.2 (`src/api/openapi.yml`). There is no
`/v2/sandboxes/{id}/connect` in v0.2.2; resume is `POST /sandboxes/{id}/resume` and
`POST /sandboxes/{id}/connect`.

| ID | Title |
|---|---|
| AC-1 | All AgentENV pods Ready in `agentenv-system` |
| AC-2 | Gateway health and node discovery |
| AC-3 | Cold create of `ubuntu:22.04` reaches running |
| AC-4 | Command runs inside the sandbox through the gateway |
| AC-5 | Pause succeeds and the sandbox is listed as paused |
| AC-6 | Resume succeeds and a file written before the pause survives |
| AC-7 | Fork into two children that run commands independently |
| AC-8 | Kill removes the sandbox from the list |
| AC-9 | Timings recorded for every lifecycle step |
| AC-10 | Warm second create of the same image recorded |
| AC-11 | Redeploy from the repo is repeatable |
| AC-12 | Teardown leaves only documented node state |
| AC-13 | Nothing outside `agentenv-system` and this repo's resources was modified |

## AC-1: All AgentENV pods Ready

- **Command:** `$K get pods -o wide`
- **Expected:** exactly one `agentenv-node-*` pod, one `agentenv-gateway-*`, one
  `agentenv-scheduler-*`, all `READY 1/1`, `STATUS Running`, restarts `0` (or a restart
  count explained in RESULTS). The node pod is on a node in pool `kvm-pool-c2`.
- **Pass rule:** all three Ready within 10 minutes of `scripts/deploy.sh` finishing.
- **Evidence:** the `get pods -o wide` output and `$K get events --sort-by=.lastTimestamp | tail -30`.

## AC-2: Gateway health and node discovery

- **Commands:**
  - `curl -s -o /dev/null -w '%{http_code}\n' $GW/health`
  - `curl -s $AUTH $GW/nodes`
  - `curl -s $AUTH $GW/nodes/<nodeID>`
- **Expected:** `/health` returns 204 (No Content). `/nodes` returns a JSON array with exactly one node
  whose ID is the runtime pod name (`AENV_NODE_ID` is the pod name). `/nodes/<id>`
  returns the node detail with CPU and memory figures and a sandbox count of 0.
- **Pass rule:** all three responses as expected; `/nodes` must not be empty.
- **Evidence:** the three responses.

## AC-3: Cold create reaches running

- **Command:**
  ```
  curl -s -X POST $AUTH -H 'Content-Type: application/json' \
    -d '{"image":"ubuntu:22.04","timeout":900,"autoPause":false,"cpuCount":1,"memoryMB":1024}' \
    $GW/sandboxes-cold
  ```
  then poll `curl -s $AUTH $GW/sandboxes/$ID` until `state` is `running`.
- **Expected:** HTTP 201 with `sandboxID`, `templateID`, `envdVersion`, `envdAccessToken`
  and the `x-agentenv-sandbox-id` response header; the detail call reports
  `state: running`.
- **Pass rule:** `running` within 10 minutes (first use converts the OCI image and
  downloads runtime assets). Record the elapsed time from the POST to the first `running`.
- **Evidence:** the create response with tokens redacted to their first 6 characters, the
  detail response, and the elapsed time. If it fails, also capture
  `$K logs ds/agentenv-node --tail=200`.

## AC-4: Command runs through the gateway

- **Command (preferred, E2B Python SDK against the port-forward):**
  ```
  E2B_API_URL=$GW E2B_SANDBOX_URL=$GW E2B_API_KEY=$KEY python3 -c '
  from e2b import Sandbox
  s = Sandbox.connect("'$ID'")
  r = s.commands.run("echo hello-from-agentenv && uname -r && cat /etc/os-release | head -1")
  print(r.exit_code); print(r.stdout)'
  ```
- **Fallback (curl, envd HTTP through the proxy):**
  ```
  curl -s $AUTH -H "X-Access-Token: $TOK" -H "e2b-sandbox-id: $ID" -H "e2b-sandbox-port: 49983" -o /dev/null -w '%{http_code}\n' $GW/health
  curl -s $AUTH -H "X-Access-Token: $TOK" -H "e2b-sandbox-id: $ID" -H "e2b-sandbox-port: 49983" \
    -X POST -H 'Content-Type: application/octet-stream' --data-binary 'hello-from-agentenv' \
    "$GW/files?path=/root/marker.txt"
  curl -s $AUTH -H "X-Access-Token: $TOK" -H "e2b-sandbox-id: $ID" -H "e2b-sandbox-port: 49983" \
    "$GW/files?path=/root/marker.txt"
  ```
- **Expected:** exit code 0 and `hello-from-agentenv` in stdout, plus a kernel version
  line (the guest kernel, expected `6.1.x`, not the node's `6.12.94`). With the fallback,
  envd `/health` returns 204 and the file round-trips. (v0.2.2 does not serve the
  `/proxy` path prefix; route with the headers and the original path.)
- **Pass rule:** either path succeeds. Record the round-trip time of one `echo` command.
- **Evidence:** the output. Note which path was used.

## AC-5: Pause

- **Command:** `curl -s -o /dev/null -w '%{http_code}\n' -X POST $AUTH $GW/sandboxes/$ID/pause`
  then `curl -s $AUTH "$GW/v2/sandboxes?state=paused"`.
- **Precondition:** before pausing, write a marker file inside the sandbox (AC-4's
  `marker.txt` or `echo $(date +%s) > /root/marker.txt` via the SDK).
- **Expected:** pause returns 204; the paused list includes `$ID`; the running list
  (`?state=running`) does not.
- **Pass rule:** both list checks correct. Record the pause call's duration.
- **Evidence:** the status code, both list responses, the duration.

## AC-6: Resume with state preserved

- **Command:** `curl -s -X POST $AUTH -H 'Content-Type: application/json' -d '{"timeout":900}' $GW/sandboxes/$ID/resume`
  (or `POST $GW/sandboxes/$ID/connect`, which resumes if paused and returns 201), then
  re-read the marker file with the AC-4 method.
- **Expected:** HTTP 201 with the same `sandboxID`; `state: running`; the marker file
  content is unchanged.
- **Pass rule:** same ID, running, marker intact. Record the time from the resume POST to
  a successful command in the sandbox.
- **Evidence:** the resume response, the marker read-back, the timing.

## AC-7: Fork into two children

- **Command:**
  ```
  curl -s -X POST $AUTH -H 'Content-Type: application/json' -d '{"count":2,"timeout":900}' $GW/sandboxes/$ID/fork
  ```
- **Expected:** HTTP 200 with a result list of two entries, each with its own `sandbox`
  (new `sandboxID`s, different from `$ID` and from each other) and no `error`. The parent
  is still running afterwards. In each child, the parent's marker file exists; writing a
  different file in child A does not appear in child B.
- **Pass rule:** two distinct running children, marker present in both, child writes are
  isolated. Record the fork call's duration and the time until both children answer a
  command.
- **Evidence:** the fork response (tokens redacted), the per-child command outputs, the
  timings. Note that fork places children on the same node as the parent.

## AC-8: Kill

- **Command:** for the parent and both children:
  `curl -s -o /dev/null -w '%{http_code}\n' -X DELETE $AUTH $GW/sandboxes/$ID`
  then `curl -s $AUTH "$GW/v2/sandboxes"`.
- **Expected:** 204 per delete; the list no longer contains any of the three IDs;
  `GET /sandboxes/$ID` returns 404.
- **Pass rule:** all three gone.
- **Evidence:** the status codes and the final list.

## AC-9: Timings recorded

- **Rule:** `tests/RESULTS.md` has a timing table with these rows, each with a number in
  seconds and the measurement method: cold create to running (AC-3), command round-trip
  (AC-4), pause (AC-5), resume to first command (AC-6), fork of two to both children
  answering (AC-7), warm second create (AC-10).
- **Pass rule:** every row filled; no thresholds.

## AC-10: Warm second create

- **Command:** repeat AC-3's create after AC-8 (the image is now converted and cached on
  the node), poll to `running`, then kill it.
- **Expected:** a running sandbox, noticeably faster than AC-3 because the OCI conversion
  is skipped. Record the elapsed time; also record the first ready-to-running of a sandbox
  created while another is already running, if time allows.
- **Pass rule:** running; time recorded.
- **Evidence:** elapsed time and the detail response.

## AC-11: Redeploy is repeatable

- **Command:** `scripts/teardown.sh` (keeping node state), then `scripts/deploy.sh`, then
  AC-1 and AC-2 again.
- **Expected:** the second deploy reaches Ready without manual steps, and the API key is
  either reused from the existing Secret or regenerated and documented.
- **Pass rule:** AC-1 and AC-2 pass after the redeploy.
- **Evidence:** the deploy script output and the AC-1/AC-2 checks.

## AC-12: Teardown leaves only documented node state

- **Command:** `scripts/teardown.sh`, then
  `kubectl --context gke_gke-ai-eco-dev_us-central1-a_barkland-test get all,secrets,configmaps,sa,role,rolebinding -n agentenv-system`
  and `kubectl get ns agentenv-system`.
- **Expected:** the namespace and everything in it are gone. What remains on the node
  (`/var/lib/aenv` with caches, secrets seed, snapshot store, persisted sandboxes; the
  loaded `ublk_drv` module) is listed in `plans/decisions.md` with the command to clear it.
- **Pass rule:** namespace gone; leftover node state documented.
- **Evidence:** the `get` output showing not found, and the decisions entry.

## AC-13: Nothing outside the namespace was modified

- **Commands:**
  - `gcloud container node-pools list --cluster barkland-test --zone us-central1-a --project gke-ai-eco-dev --format='value(name)'` shows exactly `default-pool sandbox-pool kvm-pool-c2`.
  - `kubectl get ns` shows no new namespace other than `agentenv-system`.
  - `kubectl -n agent-sandbox-system get pods` unchanged from before the work (same pod
    names and restart counts as recorded at the start of testing).
  - `kubectl get clusterrole,clusterrolebinding | grep -i agentenv` returns nothing (the
    upstream RBAC is namespaced).
- **Expected:** all as stated. Project-level changes made by the orchestrator before this
  plan (the `agentenv` Artifact Registry repo) are allowed and listed in
  `plans/decisions.md`.
- **Pass rule:** no unexpected differences.
- **Evidence:** the command outputs, with the "before" snapshot for `agent-sandbox-system`.
