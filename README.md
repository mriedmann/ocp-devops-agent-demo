# litellm on a Red Hat Developer Sandbox (RHOAI) + local opencode

Reproducible setup for running [litellm](https://github.com/BerriAI/litellm) inside a
**Red Hat Developer Sandbox 30-day trial with the OpenShift AI (RHOAI) add-on**, fronting
the sandbox's shared, pre-deployed KServe `InferenceService` vLLM models — and then
pointing a local [opencode](https://github.com/anomalyco/opencode) at it over
a public OpenShift Route, so no cluster/`oc` access is needed on the machine running
opencode. (Prefer not to expose litellm publicly? `oc port-forward` still works as a
fallback — see "Accessing litellm" below.) Also wires in one free hosted model
([OpenRouter](https://openrouter.ai)) behind the same litellm instance to demonstrate real
tool-calling, which the RHOAI models can't do — see "Real tool-calling: the OpenRouter
model" below.

## Why this isn't just "point litellm at the model URL"

The shared InferenceServices in this sandbox flavor:

- live in a `sandbox-shared-models` project you don't own, are **ClusterIP-only**
  (`*.svc.cluster.local`) — there's no public Route, so any client (litellm included) has
  to run **inside** the cluster to reach them at all;
- have `security.opendatahub.io/enable-auth: "true"`, enforced by an `oauth-proxy`
  sidecar per predictor pod, requiring `Authorization: Bearer <token>` on every request;
- authorize that token via a SubjectAccessReview requiring `get` on the specific
  `InferenceService` — which, in this sandbox, a RoleBinding grants to
  **`system:authenticated`**, i.e. *any* valid OpenShift identity, including a plain pod's
  own default ServiceAccount token. No special access to `sandbox-shared-models` needs to
  be requested.

Send a request with no bearer token and oauth-proxy doesn't 401 cleanly — it tries an
interactive OAuth browser-login redirect, which errors out on a non-browser client with:

```json
{"error":"server_error","error_description":"The authorization server encountered an unexpected condition that prevented it from fulfilling the request."}
```

If you hit that error, this is almost certainly why: no `api_key` configured on the
litellm model entry, so no `Authorization` header ever reached the predictor.

## Architecture

```
 laptop (anywhere)                      Red Hat Developer Sandbox

┌────────────────────────────────────────┐   ┌─────────────────────────────────────┐   ┌────────────────────────────┐
│ opencode (CLI)                         │   │ litellm-deployment                  │   │ litellm-token-refresh      │
│                                        │   │ (<your>-dev project)                │   │ CronJob                    │
│ default:                               │   │                                     │   │                            │
│   baseURL: https://<route-host>/v1     │   │ - reached via Route "litellm"       │   │ restarts the Deployment    │
│                                        │   │   (public, edge-TLS), or            │   │ every 45m so KSERVE_TOKEN  │
│ fallback (no public Route):            │   │   oc port-forward :4000             │   │ never goes stale           │
│   baseURL: http://localhost:4000/v1    │   │ - reads KSERVE_TOKEN from its       │   └────────────────────────────┘
│                                        │   │   own SA token at container start   │
│ apiKey: {env:LITELLM_MASTER_KEY}       │   │ - api_key: os.environ/KSERVE_TOKEN  │
└────────────────────────────────────────┘   │ - master_key gates the proxy        │
                                             └─────────────────────────────────────┘

                                                 │ calls whichever model was requested
                                                 ▼
                                             ┌────────────────────────────────────┐
                                             │ sandbox-shared-models project      │
                                             │ (each predictor behind an          │
                                             │  oauth-proxy sidecar, :8443)       │
                                             │                                    │
                                             │ isvc-qwen3-8b-fp8-predictor        │
                                             │ isvc-granite-31-8b-fp8-predictor   │
                                             │ isvc-nemotron-nano-9b-v2-fp8-...   │
                                             └────────────────────────────────────┘
```

## Project layout

```
k8s/       Kubernetes manifests (envsubst templates — ${NAMESPACE}, ${SHARED_MODELS_NAMESPACE})
scripts/   bash: prereq check, deploy, verify, Route/port-forward access, model discovery, oc-debug helper
opencode/  config.snippet.json — what to merge into ~/.config/opencode/opencode.json (or run scripts/print-opencode-config.sh)
           Dockerfile, entrypoint.sh — portable opencode container image, see scripts/run-opencode-container.sh
```

## Prerequisites

- A Red Hat Developer Sandbox trial with the RHOAI add-on (has a `sandbox-shared-models`
  project visible to you with `Ready` InferenceServices in it — `00-check-prereqs.sh`
  verifies this).
- `oc` CLI, logged in (`oc login --token=... --server=...`, from the sandbox console's
  "Copy login command").
- `jq`, `envsubst` (part of `gettext`), `openssl`.
- [opencode](https://github.com/anomalyco/opencode) installed locally
  (`curl -fsSL https://opencode.ai/install | bash` — see
  [opencode.ai/docs](https://opencode.ai/docs) for other install methods), only needed for
  the last section.
- A free [OpenRouter](https://openrouter.ai/keys) API key, only needed for "Real
  tool-calling: the OpenRouter model" below.

## Install

```bash
cd scripts
./00-check-prereqs.sh
./01-deploy.sh
./02-verify.sh
```

`01-deploy.sh` deploys into your **current `oc project`** by default and assumes the
shared models live in `sandbox-shared-models`. Override either with env vars:

```bash
NAMESPACE=my-dev-project SHARED_MODELS_NAMESPACE=sandbox-shared-models ./01-deploy.sh
```

It also generates a random `LITELLM_MASTER_KEY` on first run (stored in the
`litellm-secrets` Secret) — save it, you'll need it for both `02-verify.sh` (does this
for you) and the opencode config:

```bash
oc get secret litellm-secrets -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d
```

It also deploys a small Postgres instance (`k8s/deployment-postgres.yaml`,
backed by a 1Gi PVC in `k8s/pvc-postgres.yaml`) and generates a
`POSTGRES_PASSWORD`/`DATABASE_URL` pair in the same Secret. This is only needed for
litellm's **Admin UI** — the plain API works fine without it — see "Accessing litellm"
below for why.

### If your sandbox's shared models differ from the ones in `k8s/configmap-litellm-config.yaml`

The three models baked into that file (`qwen3-8b-fp8`, `granite-31-8b-fp8`,
`nemotron-nano-9b-v2-fp8`) were what this sandbox trial had on 2026-08-31 — the shared
pool can change. Check what's actually there and regenerate the model list:

```bash
./list-shared-models.sh
./generate-model-list.sh    # prints a model_list: block — paste it into
                             # k8s/configmap-litellm-config.yaml, then re-run 01-deploy.sh
```

### The RoleBinding may need applying manually

`01-deploy.sh` applies `k8s/rolebinding-litellm-restarter.yaml`, which grants the
`litellm-restarter` ServiceAccount `edit` on your own namespace so the token-refresh
CronJob can restart the Deployment. If your account can't grant RBAC (some automated
tooling deliberately blocks this), the deploy still succeeds otherwise — just apply it
yourself:

```bash
oc apply -f k8s/rolebinding-litellm-restarter.yaml
```

Without it, litellm keeps working for about an hour after each deploy/restart, then
every model call starts 401ing until you restart it manually
(`oc rollout restart deployment/litellm-deployment`).

## Using it directly (no opencode)

`01-deploy.sh` applies a public Route by default, so this works from any machine with
network access, no `oc` required:

```bash
ROUTE_HOST=$(oc get route litellm -o jsonpath='{.spec.host}')
curl -s "https://${ROUTE_HOST}/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-8b-fp8","messages":[{"role":"user","content":"hi"}]}'
```
Don't want litellm publicly reachable? Remove the Route (`oc delete -f
k8s/route-litellm.yaml`) and use `http://localhost:4000/...` instead, after starting
`./03-port-forward.sh` in another terminal. Swap `"model"` for `"nemotron-3.5-lightning"`
to hit the OpenRouter-backed entry instead (see "Real tool-calling: the OpenRouter model"
below — needs `./add-openrouter-key.sh` run first).

## Accessing litellm

`01-deploy.sh` applies `k8s/route-litellm.yaml` by default (edge-terminated TLS, HTTP
redirected to HTTPS), so litellm's `/v1` API and `/ui` Admin UI are both reachable
without cluster/`oc` access — this is what makes opencode (and anyone else) able to
use it without a running `oc port-forward`. **It adds no new auth layer** — the Route
just forwards to the same litellm proxy, whose Admin UI login and API are already gated
by `LITELLM_MASTER_KEY` (`general_settings.master_key` in
`k8s/configmap-litellm-config.yaml`). Get the URL and credentials any time with:

```bash
cd scripts
./print-opencode-config.sh
```

which prints the Admin UI URL (log in as `admin` with `LITELLM_MASTER_KEY` as the
password), then offers to merge the opencode config for it into
`~/.config/opencode/opencode.json` (see "Local opencode setup" below). Anyone with the
Route's URL can reach the login page, but not the API or UI content, without that key.

Don't want litellm reachable from the public internet at all? Remove the Route and fall
back to `oc port-forward` for both opencode and direct API access:

```bash
oc delete -f k8s/route-litellm.yaml
```

### Why the UI needs a database and the API doesn't

`/ui/login` requires a Postgres `DATABASE_URL` to be set — without one it fails with
**"Not connected to DB!"**, even though the plain proxy API works fine with just
`LITELLM_MASTER_KEY` (curl/opencode never hit this). `./01-deploy.sh` provisions this for
you (`k8s/deployment-postgres.yaml` + `k8s/pvc-postgres.yaml`), so if you deployed with
an older version of this repo and hit that error, just re-run it — it detects the
missing `DATABASE_URL` on your existing `litellm-secrets` Secret, adds it, and restarts
`litellm-deployment` to pick it up.

## Local opencode setup

1. Install opencode (`curl -fsSL https://opencode.ai/install | bash`) and run it once
   (`opencode`) so `~/.config/opencode/` exists.
2. Export the master key so opencode can read it:
   ```bash
   export LITELLM_MASTER_KEY="<value from the Secret, see above>"
   ```
   Add it to your shell profile instead if you want it to persist across shells.
3. Generate and merge the config:
   ```bash
   cd scripts && ./print-opencode-config.sh
   ```
   It shows a diff of what it would change in `~/.config/opencode/opencode.json` and asks
   for confirmation before writing anything (pass `-y` to skip the prompt); a timestamped
   `.bak` copy is written first, and anything else already in that file (other providers,
   agents, permissions, ...) is left untouched — safe to re-run any time (after a
   redeploy, to pick up a new Route host or model list) or decline, in which case nothing
   is written and the config block is printed instead for you to merge by hand. **Use it
   as generated** — it already encodes the two fixes below (see "Context and output-token
   limits" and "Tool-calling limitation"), verified by actually running `opencode run`
   against this setup on 2026-08-31; a naive auto-discovery config will hit both.
4. Test with a one-shot prompt (no TUI, prints only the final answer):
   ```bash
   opencode run "Say OK and nothing else."
   ```
5. Run `opencode` for the interactive TUI. Switch models mid-session with the `/models`
   slash command, or pass `-m litellm/nemotron-nano-9b-v2-fp8` to `opencode run` for a
   one-off call on a different model.

**No public Route (port-forward fallback):** if you removed `k8s/route-litellm.yaml` and
run `./03-port-forward.sh` instead, merge `opencode/config.snippet.json` as-is (its
`baseURL` fields already point at `http://localhost:4000/v1`) rather than running
`print-opencode-config.sh`. **WSL2 note:** if opencode runs on native Windows while `oc
port-forward` runs inside WSL2 (or vice versa), `localhost` doesn't route between them by
default — use WSL2 mirrored networking, or point `baseURL` at the WSL2 VM's actual IP
instead of `localhost`. Running both in the same shell environment avoids the issue
entirely.

### Context and output-token limits

opencode can't discover a custom provider's context window or safe output-token budget
on its own, and defaults its output-token request higher than these fixed-context vLLM
backends allow — the model's `limit.context`/`limit.output` fields in
`opencode/config.snippet.json` **must** match what each ServingRuntime was actually
deployed with (`--max-model-len`), or you'll hit a context-window-exceeded error from
vLLM. All three shared models plus `nemotron-3.5-lightning` are set correctly in the
shipped config — `qwen3-8b-fp8` (40,960 context) included, since (unlike some other CLI agents)
opencode has no hard minimum-context requirement of its own; it was verified working
end-to-end at that context size on 2026-08-31.

### Tool-calling limitation (important — read before expecting opencode to run `oc` itself)

None of the three ServingRuntimes in `sandbox-shared-models` were started with vLLM's
`--enable-auto-tool-choice`/`--tool-call-parser` flags (we don't control that project —
read-only). vLLM hard-rejects **any** request carrying `tools` with `tool_choice`
`"auto"` or `"required"`:

```json
{"error":{"message":"\"auto\" tool choice requires --enable-auto-tool-choice and --tool-call-parser to be set", ...}}
```

opencode always attaches its own tool definitions (bash, edit, read, ...) to every
request — there's no client-side flag that produces a genuinely toolless call, so every
opencode request would 400 against this backend as-is.

**The fix applied here** (`k8s/configmap-litellm-config.yaml`'s `tool_choice_shim.py`,
wired in via `litellm_settings.callbacks`): a litellm pre-call hook that forces
`tool_choice` to `"none"` whenever `tools` is present, before forwarding to vLLM. This
makes opencode's requests succeed — but it means **opencode can never actually invoke a
tool through this endpoint**. Ask it to run a command and the model will describe or
hallucinate a tool-call-shaped response as plain text instead (confirmed against
`granite-31-8b-fp8` on 2026-08-31 — asking it to list files produced a fabricated
transcript, not a real directory listing); nothing executes, because `tool_choice: none`
means the API layer never returns a real `tool_calls` object for opencode's harness to
act on. This is a hard backend limitation, not a bug in the shim — short of getting
`--enable-auto-tool-choice` added to the shared ServingRuntime (not something a sandbox
user can do), there's no way around it.

## Containerized opencode (no local install needed)

Don't want to install opencode on the machine you're working from, or want to point it
at some *other* project without touching your own opencode config? `opencode/Dockerfile`
builds a small image with just opencode in it; `scripts/run-opencode-container.sh` builds
it (if needed) and runs it against any local directory, bind-mounted at `/workspace`.

Prerequisites: Docker or Podman, and a working `~/.config/opencode/opencode.json` (run
`./print-opencode-config.sh` once first — the container reuses that file as-is rather
than regenerating it).

```bash
cd scripts
./run-opencode-container.sh                  # opencode against $PWD
./run-opencode-container.sh ~/some-other-repo   # opencode against that directory
./run-opencode-container.sh ~/some-other-repo bash   # plain shell instead, opencode on PATH
```

It picks up `LITELLM_MASTER_KEY` from your shell if already exported, or falls back to
fetching it from the `litellm-secrets` Secret via `oc` (same as `print-opencode-config.sh`)
and injects it into the container as an env var on boot.

The image is rebuilt automatically whenever `opencode/Dockerfile` or
`opencode/entrypoint.sh` change. Since the Dockerfile always installs opencode's
*latest* release, an unchanged Dockerfile can still mean a stale opencode binary over
time — pass `--rebuild` to force a fresh build and pick up updates.

## Real tool-calling: the OpenRouter model

Everything above gets you working *chat* through litellm, but never real tool execution
— the shared vLLM models structurally can't do it (previous section). To showcase the
*full* loop — opencode actually calling its own tools, e.g. to run `oc` commands itself,
still mandatorily routed through this same litellm instance — we added one more
`model_list` entry backed by [OpenRouter](https://openrouter.ai)'s free API
(`nvidia/nemotron-3.5-lightning:free`, which does support native tool calling).

**Why OpenRouter and not Groq:** an earlier version of this used Groq's free
`llama-3.3-70b-versatile`, which Groq has since removed. Its replacements
(`openai/gpt-oss-120b`, Qwen3, etc.) all share an **8,000 tokens-per-minute** free-tier
cap — too small for opencode's own baseline overhead (its system prompt plus full
built-in tool schema, ~8,800 tokens before the actual conversation even starts), causing
constant rate-limit errors regardless of which Groq model or which opencode tools are
enabled (verified against this setup on 2026-08-31 — confirmed with `openai/gpt-oss-120b`,
including that it genuinely did execute `oc get pods` once, before the follow-up turn hit
the cap). OpenRouter's free tier limits by **request count** instead (20/min, 50-1000/day
depending on account credit history), which comfortably fits a large single request
regardless of its token size — the actual constraint that broke Groq. Nemotron 3.5
Lightning was picked over the other 17 free tool-calling-capable models on OpenRouter for
its 1M-token context (ties for the largest) and its MoE design (3B active/30B total),
which NVIDIA specifically targets at low-latency, high-throughput agentic workloads —
exactly this use case.

This is the point of fronting everything with litellm rather than pointing opencode
straight at a model: litellm-on-OpenShift is a single control plane over a *mix* of
self-hosted (the RHOAI predictors) and hosted (OpenRouter) models. opencode only ever
talks to litellm's proxy (over the Route, or `localhost:4000` via port-forward) — it has
no idea, and doesn't need to know, that `nemotron-3.5-lightning`'s tokens run on
OpenRouter's infrastructure instead of cluster GPUs. Swapping, adding, or removing
backends is a `model_list` edit, never an opencode-side change.

**Setup** (one-time, after `01-deploy.sh`):
1. Get a free key at [openrouter.ai/keys](https://openrouter.ai/keys) — no card
   required.
2. Run `./add-openrouter-key.sh` and paste it at the hidden prompt. It patches the
   `OPENROUTER_API_KEY` entry into `litellm-secrets` (leaving `LITELLM_MASTER_KEY` alone)
   and restarts `litellm-deployment` to pick it up.

**Using it with opencode:** `opencode/config.snippet.json` already wires it up as
`litellm/nemotron-3.5-lightning`. Switch to it and ask for something that needs a real
command:

```bash
opencode run -m litellm/nemotron-3.5-lightning "Run 'oc get pods' and tell me if anything looks unhealthy."
```

or interactively: `/models`, pick it, then just ask. Unlike the `rhoai-*` models, this
one actually invokes one of opencode's real tools and returns real command output in its
answer — you can watch it happen (opencode normally prompts for approval before running a
command; pass `--auto` to skip that if you want it fully unattended, but for a first run
leave it on so you can see what it's about to execute). Verified end-to-end on
2026-08-31: a real `oc get pods` ran and its actual output was summarized correctly.

**Verify the routing, not just the answer:** tail the litellm pod logs while you run the
command above — you'll see the `/v1/chat/completions` call for `nemotron-3.5-lightning`
hit litellm *inside the cluster* (not your laptop calling OpenRouter directly), same as
every other model:

```bash
oc logs -n "$NAMESPACE" -l app=litellm -f
```

## Minimal OpenShift debugging with opencode

If you'd rather not set up OpenRouter (previous section) — or want to use one of the RHOAI
models specifically — the practical pattern for those is: **you run the `oc` command,
opencode reasons over the output** — a one-shot prompt with the command's output embedded,
no tool-calling involved. This works today, end to end, no server-side changes needed,
against any model including the `rhoai-*` ones:

```bash
cd scripts
./oc-debug.sh get pods -n my-namespace
./oc-debug.sh describe pod some-crashlooping-pod -n my-namespace
./oc-debug.sh logs deploy/litellm-deployment -n my-namespace --tail=200
```

It runs the `oc` command locally, then sends the output to opencode with a prompt asking
it to flag crashloops, pending/failed pods, image-pull errors, high restart counts, etc.
Override the model with `OPENCODE_MODEL=nemotron-nano-9b-v2-fp8 ./oc-debug.sh ...`.

## OpenShift MCP server via litellm

`01-deploy.sh` also deploys a **read-only** OpenShift MCP server
([containers/kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server))
in your project and registers it with litellm's MCP gateway (`mcp_servers` in
`k8s/configmap-litellm-config.yaml`). It has no Route of its own: opencode reaches it at
`<litellm>/mcp/openshift` with the same `LITELLM_MASTER_KEY` it uses for the LLM API, so no
local Node or kubeconfig is needed (this replaces running `npx kubernetes-mcp-server`
locally). `opencode/config.snippet.json` carries the matching `mcp` block, and
`print-opencode-config.sh` merges it like the rest.

- **Permissions:** the `openshift-mcp` ServiceAccount is bound to the built-in `view`
  ClusterRole in your namespace only (no Secrets), and the server runs with `--read-only`.
  Like the restarter, the RoleBinding may need applying by hand:
  `oc apply -f k8s/rolebinding-openshift-mcp.yaml`. To allow writes, bind `edit` instead and
  drop `--read-only` from `k8s/deployment-openshift-mcp.yaml`.
- **Models:** the tools are only usable with a model that supports real tool calling, i.e.
  `nemotron-3.5-lightning` (see "Tool-calling limitation").
- **Check it:** `./scripts/02-verify.sh` lists the gateway's tools as its last step.

## Cleanup

```bash
oc delete -f k8s/deployment-openshift-mcp.yaml -f k8s/service-openshift-mcp.yaml
oc delete -f k8s/rolebinding-openshift-mcp.yaml -f k8s/serviceaccount-openshift-mcp.yaml
oc delete -f k8s/cronjob-litellm-token-refresh.yaml
oc delete -f k8s/route-litellm.yaml
oc delete -f k8s/deployment-litellm.yaml -f k8s/service-litellm.yaml -f k8s/configmap-litellm-config.yaml
oc delete -f k8s/rolebinding-litellm-restarter.yaml -f k8s/serviceaccount-litellm-restarter.yaml
oc delete -f k8s/deployment-postgres.yaml -f k8s/service-postgres.yaml
oc delete -f k8s/pvc-postgres.yaml   # WARNING: permanently deletes Admin UI data (keys, usage history)
oc delete secret litellm-secrets
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `"authorization server encountered an unexpected condition"` | No bearer token reached the predictor | Check `api_key: os.environ/KSERVE_TOKEN` is set on every model in the ConfigMap |
| 401s starting ~1h after a restart | Token-refresh CronJob isn't running (missing RoleBinding) | `oc apply -f k8s/rolebinding-litellm-restarter.yaml`, check `oc get cronjob,jobs -l` |
| `model not found` from vLLM (not litellm) | `litellm_params.model` doesn't match the predictor's `--served-model-name` | Must be `hosted_vllm/<InferenceService name>`, e.g. `hosted_vllm/isvc-qwen3-8b-fp8` |
| SSL errors from litellm | Predictor's TLS cert is signed by OpenShift's internal service-serving CA | `ssl_verify: false` in `litellm_settings` (already set) — or mount `openshift-service-ca.crt` and point litellm at it if you want real verification |
| opencode can't reach litellm | Route not applied yet (`oc get route litellm`), stale host baked into `~/.config/opencode/opencode.json` (re-run `./print-opencode-config.sh` after any redeploy), or — if using the port-forward fallback — the tunnel isn't running / a WSL2-Windows networking split | Re-run `./print-opencode-config.sh`, or restart `./03-port-forward.sh` and check the WSL2 note above |
| opencode: `"auto" tool choice requires --enable-auto-tool-choice...` | `tool_choice_shim.py` callback isn't loaded (old ConfigMap, or `litellm_settings.callbacks` missing) | Redeploy `k8s/configmap-litellm-config.yaml`, check litellm pod logs for import errors, `oc rollout restart deployment/litellm-deployment` |
| opencode: a context/output-token-exceeded error against a shared model | `limit.context`/`limit.output` missing or wrong for that model in `opencode.json` — opencode can't discover a custom provider's real limits and will otherwise request more room than the model has | Match `limit.context`/`limit.output` to the ServingRuntime's actual `--max-model-len` (already set correctly in `opencode/config.snippet.json`) |
| opencode runs but never actually executes a command it says it will | Expected — see "Tool-calling limitation" above | Use `scripts/oc-debug.sh` instead of asking opencode to run `oc` itself, or switch to `/models` → the OpenRouter entry |
| `nemotron-3.5-lightning` call fails with an auth/401-style error from litellm | `OPENROUTER_API_KEY` not set, stale, or invalid in `litellm-secrets` | Run `./add-openrouter-key.sh` with a fresh key from [openrouter.ai/keys](https://openrouter.ai/keys) |
| OpenRouter works via curl but not via opencode | `opencode/config.snippet.json`'s `nemotron-3.5-lightning` entry not merged into `~/.config/opencode/opencode.json`, or still on an old config without it | Re-merge the snippet, `opencode run -m litellm/nemotron-3.5-lightning "hi"` to test directly |
| opencode's `openshift` MCP tools are missing, or calls return 403 | `mcp` block not merged into `opencode.json`, `openshift-mcp` pod not Ready, or its RoleBinding wasn't applied | Re-run `./print-opencode-config.sh`, `oc get pods -l app=openshift-mcp`, `oc apply -f k8s/rolebinding-openshift-mcp.yaml` |
| `Gateway Time-out` from a slower tool-calling round trip (a reasoning model plus opencode's full tool-schema payload) | OpenShift's default Route backend timeout (30s) is too short | Already raised to 120s via the `haproxy.router.openshift.io/timeout` annotation in `k8s/route-litellm.yaml`; if you still see this, raise it further |
| Containerized opencode (`run-opencode-container.sh`) starts but can't authenticate | `LITELLM_MASTER_KEY` wasn't exported and couldn't be fetched via `oc` (see the script's warning) | Export `LITELLM_MASTER_KEY` before running the script, or make sure `oc` is logged in with access to the `litellm-secrets` Secret |
| litellm pod stuck `0/1 Ready` after a redeploy, `oc describe pod` shows the `readinessProbe` failing with 401/403 on `/health/readiness` | Known upstream regression in some litellm builds where that endpoint unexpectedly requires `x-litellm-key` ([BerriAI/litellm#8795](https://github.com/BerriAI/litellm/issues/8795)) | Check litellm pod logs for the actual error; if it's this, pin to an unaffected `litellm` image tag, or open an issue upstream — the readinessProbe itself (`k8s/deployment-litellm.yaml`) is unauthenticated by design per litellm's docs |
