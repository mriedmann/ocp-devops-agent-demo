# Workshop scenarios: debugging OpenShift with the MCP agent

Thirteen small, self-contained "broken app" scenarios for showing the `openshift` MCP
tools (via litellm + opencode) diagnosing real OpenShift failures. They are built for the
Developer Sandbox: one project, no extra namespaces, tiny footprint (each scenario is 1 to 3 pods
with `5m` CPU / `8-32Mi` memory requests, and never more than 100m CPU in total).

The agent is **read-only** (`openshift-mcp --read-only`, `view` role): it finds the root
cause and *proposes* the fix. The presenter (you) applies the fix with one command.

## Presenter workflow (per scenario)

```bash
./scripts/scenario.sh preflight     # once, before the workshop
./scripts/scenario.sh up 4          # breaks scenario 4, prints the prompt and copies it to the clipboard
#  ... paste the prompt into opencode, let the agent investigate ...
./scripts/scenario.sh reveal        # your notes: root cause, expected tool path, talking point
./scripts/scenario.sh fix           # apply the fix the agent proposed (optional, shows recovery)
./scripts/scenario.sh next          # tears the current one down and starts the next
./scripts/scenario.sh down          # at the end: nothing is left behind
```

- `up` always tears down the previous scenario first, so only one is ever deployed and the
  quota is never a problem. Deleting is strictly by label `ocp-agent-demo`, so litellm,
  postgres and openshift-mcp are never touched.
- The menu (`./scripts/scenario.sh`) shows only numbers, so a shared screen does not spoil the
  answer. `menu -v` shows the titles.
- `ask [n]` runs the prompt through `opencode run` non-interactively
  (`OPENCODE_MODEL=litellm/qwen3.8-27b ./scripts/scenario.sh ask` to pick another model).
- `prompt [n]` re-prints/re-copies the prompt. `status` shows what plain `oc get` shows.
- `[n]` accepts `4`, `04`, or a name fragment (`oom`). No argument = the active scenario.

**Use a tool-capable model** (`nemotron-3.5-lightning`, `qwen3.8-27b`, `nex-n2.5-pro`,
`north-mini-code`). The default `granite-31-8b-fp8` cannot call tools. The OpenRouter free tier
allows about 20 requests/minute, so leave a short pause between scenarios.

## Scenarios

| # | Failure | Where the evidence is | Suggested time |
|---|---|---|---|
| 01 | ImagePullBackOff (typo in tag) | pod events | 3 min |
| 02 | CreateContainerConfigError (missing ConfigMap) | events (no logs exist) | 3 min |
| 03 | CrashLoopBackOff (missing env var) | previous container log | 3 min |
| 04 | OOMKilled (memory limit too low) | `lastState.terminated` | 4 min |
| 05 | Deployment with no pods (ResourceQuota) | ReplicaSet events + quota | 4 min |
| 06 | SCC violation (`runAsUser: 0`) | ReplicaSet events | 4 min |
| 07 | Route "Application is not available" | Service selector vs pod labels | 5 min |
| 08 | Stuck rollout (bad readiness probe) | Deployment conditions, 2 ReplicaSets | 5 min |
| 09 | Pending pod (PVC, unknown StorageClass) | PVC events | 4 min |
| 10 | Liveness probe kills a slow starter | events + previous log | 4 min |
| 11 | Wrong Service name in app config | app log vs Service list | 4 min |
| 12 | NetworkPolicy egress lock-down | policy + labels (no exec needed) | 5 min |
| 13 | Job BackoffLimitExceeded (app error) | log of the failed pods | 3 min |

**Suggested 30-minute run:** 01, 03, 04, 05, 07, 08 (about 25 min), with 06 and 12 as OpenShift-specific extras.
Warm-up order for a longer workshop: simply 01 -> 13, they get progressively more indirect.

## Files per scenario (`scenarios/NN-name/`)

| File | Purpose |
|---|---|
| `broken.yaml` | the broken state (labelled `ocp-agent-demo=NN-name`) |
| `fixed.yaml` | the state after the proposed fix (applied by `fix`, after a delete + create) |
| `prompt.txt` | what you ask the agent; describes the symptom, never the cause (`${NAMESPACE}` is substituted) |
| `notes.md` | presenter notes: symptom, expected tool path, root cause, proposed fix, talking point |
| `settle` | seconds `up`/`fix` wait for the symptom to develop (default 10) |
| `up.sh` / `fix.sh` | optional hooks for multi-step setups (08 releases v1 then a bad v2; its fix is `oc rollout undo`) |

## Adding a scenario
Copy a directory, keep the number prefix and the `ocp-agent-demo` label on **every** object
(including the pod template of Deployments/Jobs), keep requests tiny, and prefer bare Pods or
`revisionHistoryLimit: 0/1`: the sandbox limits the number of ReplicaSets.

## Notes and limits
- The scenarios only create objects with the prefix `demo-` in your current project.
- Scenario 09 creates one 1Gi PVC (only after `fix`; the broken PVC never binds), scenario 07 one Route.
- Scenario 12 needs NetworkPolicy enforcement (OVN-Kubernetes on OpenShift 4.x: yes).
- Events expire after about an hour: start a scenario shortly before showing it.
