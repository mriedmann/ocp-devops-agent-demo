# litellm on a Red Hat Developer Sandbox (RHOAI) + local hermes-agent

Reproducible setup for running [litellm](https://github.com/BerriAI/litellm) inside a
**Red Hat Developer Sandbox 30-day trial with the OpenShift AI (RHOAI) add-on**, fronting
the sandbox's shared, pre-deployed KServe `InferenceService` vLLM models — and then
pointing a local [hermes-agent](https://github.com/NousResearch/hermes-agent) at it over
a public OpenShift Route, so no cluster/`oc` access is needed on the machine running
hermes. (Prefer not to expose litellm publicly? `oc port-forward` still works as a
fallback — see "Accessing litellm" below.) Also wires in one free hosted model
([Groq](https://console.groq.com)) behind the same litellm instance to demonstrate real
tool-calling, which the RHOAI models can't do — see "Real tool-calling: the Groq model"
below.

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
│ hermes-agent (CLI)                     │   │ litellm-deployment                  │   │ litellm-token-refresh      │
│                                        │   │ (<your>-dev project)                │   │ CronJob                    │
│ default:                               │   │                                     │   │                            │
│   base_url: https://<route-host>/v1    │   │ - reached via Route "litellm"       │   │ restarts the Deployment    │
│                                        │   │   (public, edge-TLS), or            │   │ every 45m so KSERVE_TOKEN  │
│ fallback (no public Route):            │   │   oc port-forward :4000             │   │ never goes stale           │
│   base_url: http://localhost:4000/v1   │   │ - reads KSERVE_TOKEN from its       │   └────────────────────────────┘
│                                        │   │   own SA token at container start   │
│ key_env: LITELLM_MASTER_KEY            │   │ - api_key: os.environ/KSERVE_TOKEN  │
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
hermes/    config.snippet.yaml — what to merge into ~/.hermes/config.yaml (or run scripts/print-hermes-config.sh)
```

## Prerequisites

- A Red Hat Developer Sandbox trial with the RHOAI add-on (has a `sandbox-shared-models`
  project visible to you with `Ready` InferenceServices in it — `00-check-prereqs.sh`
  verifies this).
- `oc` CLI, logged in (`oc login --token=... --server=...`, from the sandbox console's
  "Copy login command").
- `jq`, `envsubst` (part of `gettext`), `openssl`.
- [hermes-agent](https://github.com/NousResearch/hermes-agent) installed locally, only
  needed for the last section.
- A free [Groq](https://console.groq.com/keys) API key, only needed for "Real
  tool-calling: the Groq model" below.

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
for you) and the hermes config:

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

## Using it directly (no hermes)

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
`./03-port-forward.sh` in another terminal. Swap `"model"` for `"groq-llama-3.3-70b"` to
hit the Groq-backed entry instead (see "Real tool-calling: the Groq model" below — needs
`./add-groq-key.sh` run first).

## Accessing litellm

`01-deploy.sh` applies `k8s/route-litellm.yaml` by default (edge-terminated TLS, HTTP
redirected to HTTPS), so litellm's `/v1` API and `/ui` Admin UI are both reachable
without cluster/`oc` access — this is what makes hermes-agent (and anyone else) able to
use it without a running `oc port-forward`. **It adds no new auth layer** — the Route
just forwards to the same litellm proxy, whose Admin UI login and API are already gated
by `LITELLM_MASTER_KEY` (`general_settings.master_key` in
`k8s/configmap-litellm-config.yaml`). Get the URL and credentials any time with:

```bash
cd scripts
./print-hermes-config.sh
```

which prints the Admin UI URL (log in as `admin` with `LITELLM_MASTER_KEY` as the
password) and a ready-to-merge hermes config block (see "Local hermes-agent setup"
below). Anyone with the Route's URL can reach the login page, but not the API or UI
content, without that key.

Don't want litellm reachable from the public internet at all? Remove the Route and fall
back to `oc port-forward` for both hermes and direct API access:

```bash
oc delete -f k8s/route-litellm.yaml
```

### Why the UI needs a database and the API doesn't

`/ui/login` requires a Postgres `DATABASE_URL` to be set — without one it fails with
**"Not connected to DB!"**, even though the plain proxy API works fine with just
`LITELLM_MASTER_KEY` (curl/hermes never hit this). `./01-deploy.sh` provisions this for
you (`k8s/deployment-postgres.yaml` + `k8s/pvc-postgres.yaml`), so if you deployed with
an older version of this repo and hit that error, just re-run it — it detects the
missing `DATABASE_URL` on your existing `litellm-secrets` Secret, adds it, and restarts
`litellm-deployment` to pick it up.

## Local hermes-agent setup

1. Install hermes-agent (see its README) and run it once (`hermes`) so `~/.hermes/`
   exists.
2. Export the master key so hermes can read it:
   ```bash
   export LITELLM_MASTER_KEY="<value from the Secret, see above>"
   ```
   Add it to `~/.hermes/.env` instead if you want it to persist across shells.
3. Generate and merge the config:
   ```bash
   cd scripts && ./print-hermes-config.sh
   ```
   Merge the printed block into `~/.hermes/config.yaml` (both blocks — `model:` sets the
   default provider/model, `model_aliases:` adds a short name for the other usable
   model). **Use it as printed** — it already encodes two fixes verified by actually
   running `hermes -z` against this setup (see "Known-good models only" and
   "Tool-calling limitation" below); a naive `hermes setup`/auto-discovery config will
   hit both.
4. Test with a one-shot prompt (no TUI, prints only the final answer):
   ```bash
   hermes -z "Say OK and nothing else."
   ```
5. Run `hermes` for the interactive REPL. Switch models mid-session with
   `/model rhoai-nemotron`, or `hermes model` to pick interactively.

**No public Route (port-forward fallback):** if you removed `k8s/route-litellm.yaml` and
run `./03-port-forward.sh` instead, merge `hermes/config.snippet.yaml` as-is (its
`base_url` fields already point at `http://localhost:4000/v1`) rather than running
`print-hermes-config.sh`. **WSL2 note:** if hermes runs on native Windows while `oc
port-forward` runs inside WSL2 (or vice versa), `localhost` doesn't route between them by
default — use WSL2 mirrored networking, or point `base_url` at the WSL2 VM's actual IP
instead of `localhost`. Running both in the same shell environment avoids the issue
entirely.

### Known-good models only: qwen3-8b-fp8 doesn't qualify

hermes-agent hard-requires **≥64K context** on its main model (`Model ... has a context
window of ... which is below the minimum 64,000 required by Hermes Agent`, checked
before any API call). Of the three shared models, only `granite-31-8b-fp8` and
`nemotron-nano-9b-v2-fp8` were deployed with `--max-model-len=65536`; `qwen3-8b-fp8` has
no override and reports 40,960. hermes refuses it outright, as default model or as an
alias. `hermes/config.snippet.yaml` only wires up the two that qualify — use qwen3
directly via curl/litellm if you need it, not through hermes.

### Tool-calling limitation (important — read before expecting hermes to run `oc` itself)

None of the three ServingRuntimes in `sandbox-shared-models` were started with vLLM's
`--enable-auto-tool-choice`/`--tool-call-parser` flags (we don't control that project —
read-only). vLLM hard-rejects **any** request carrying `tools` with `tool_choice`
`"auto"` or `"required"`:

```json
{"error":{"message":"\"auto\" tool choice requires --enable-auto-tool-choice and --tool-call-parser to be set", ...}}
```

hermes-agent always attaches its own tool definitions (terminal, memory, todo, ...) to
every request — there's no client-side flag that produces a genuinely toolless call, so
every hermes request would 400 against this backend as-is.

**The fix applied here** (`k8s/configmap-litellm-config.yaml`'s `tool_choice_shim.py`,
wired in via `litellm_settings.callbacks`): a litellm pre-call hook that forces
`tool_choice` to `"none"` whenever `tools` is present, before forwarding to vLLM. This
makes hermes' requests succeed — but it means **hermes can never actually invoke a tool
through this endpoint**. Ask it to run a command and the model will describe or
hallucinate a tool-call-shaped JSON blob as plain text; nothing executes, because
`tool_choice: none` means the API layer never returns a real `tool_calls` object for
hermes' harness to act on. This is a hard backend limitation, not a bug in the shim —
short of getting `--enable-auto-tool-choice` added to the shared ServingRuntime (not
something a sandbox user can do), there's no way around it.

## Real tool-calling: the Groq model

Everything above gets you working *chat* through litellm, but never real tool execution
— the shared vLLM models structurally can't do it (previous section). To showcase the
*full* loop — hermes actually calling its `terminal` tool, e.g. to run `oc` commands
itself, still mandatorily routed through this same litellm instance — we added one more
`model_list` entry backed by [Groq](https://console.groq.com)'s free API
(`llama-3.3-70b-versatile`, which does support native tool calling).

This is the point of fronting everything with litellm rather than pointing hermes
straight at a model: litellm-on-OpenShift is a single control plane over a *mix* of
self-hosted (the RHOAI predictors) and hosted (Groq) models. hermes only ever talks to
litellm's proxy (over the Route, or `localhost:4000` via port-forward) — it has no idea,
and doesn't need to know, that `groq-llama-3.3-70b`'s tokens run on Groq's infrastructure
instead of cluster GPUs. Swapping, adding, or removing backends is a `model_list` edit,
never a hermes-side change.

**Setup** (one-time, after `01-deploy.sh`):
1. Get a free key at [console.groq.com/keys](https://console.groq.com/keys) — no card
   required.
2. Run `./add-groq-key.sh` and paste it at the hidden prompt. It patches the
   `GROQ_API_KEY` entry into `litellm-secrets` (leaving `LITELLM_MASTER_KEY` alone) and
   restarts `litellm-deployment` to pick it up.

**Using it with hermes:** `hermes/config.snippet.yaml` already wires it up as the
`groq` alias. Switch to it and ask for something that needs a real command:

```bash
hermes -m groq -z "Run 'oc get pods' and tell me if anything looks unhealthy."
```

or interactively: `/model groq`, then just ask. Unlike the `rhoai-*` models, this one
actually invokes hermes' `terminal` tool and returns real command output in its answer
— you can watch it happen (hermes normally prompts for approval before running a
command; pass `--yolo` to skip that if you want it fully unattended, but for a first run
leave it on so you can see what it's about to execute).

**Verify the routing, not just the answer:** tail the litellm pod logs while you run the
command above — you'll see the `/v1/chat/completions` call for `groq-llama-3.3-70b` hit
litellm *inside the cluster* (not your laptop calling Groq directly), same as every
other model:

```bash
oc logs -n "$NAMESPACE" -l app=litellm -f
```

## Minimal OpenShift debugging with hermes

If you'd rather not set up Groq (previous section) — or want to use one of the RHOAI
models specifically — the practical pattern for those is: **you run the `oc` command,
hermes reasons over the output** — a one-shot prompt with the command's output embedded,
no tool-calling involved. This works today, end to end, no server-side changes needed,
against any model including the `rhoai-*` ones:

```bash
cd scripts
./oc-debug.sh get pods -n my-namespace
./oc-debug.sh describe pod some-crashlooping-pod -n my-namespace
./oc-debug.sh logs deploy/litellm-deployment -n my-namespace --tail=200
```

It runs the `oc` command locally, then sends the output to hermes with a prompt asking
it to flag crashloops, pending/failed pods, image-pull errors, high restart counts, etc.
Override the model with `HERMES_MODEL=nemotron-nano-9b-v2-fp8 ./oc-debug.sh ...`.

## Cleanup

```bash
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
| hermes can't reach litellm | Route not applied yet (`oc get route litellm`), stale host baked into `~/.hermes/config.yaml` (re-run `./print-hermes-config.sh` after any redeploy), or — if using the port-forward fallback — the tunnel isn't running / a WSL2-Windows networking split | Re-run `./print-hermes-config.sh`, or restart `./03-port-forward.sh` and check the WSL2 note above |
| hermes: `"auto" tool choice requires --enable-auto-tool-choice...` | `tool_choice_shim.py` callback isn't loaded (old ConfigMap, or `litellm_settings.callbacks` missing) | Redeploy `k8s/configmap-litellm-config.yaml`, check litellm pod logs for import errors, `oc rollout restart deployment/litellm-deployment` |
| hermes: `"Context length exceeded (N tokens). Cannot compress further"` for a *tiny* prompt | Misleading — hermes' error classifier mis-files a `ContextWindowExceededError` as "conversation too big". Real cause: `max_tokens` defaulted to the model's full context window, leaving no room for hermes' ~15K tokens of tool-schema overhead | Set `model.max_tokens: 8192` (already in `hermes/config.snippet.yaml`) |
| hermes: `"Model ... has a context window of ... below the minimum 64,000"` | That model's `--max-model-len` is under 64K (true for `qwen3-8b-fp8` here) | Use a model with ≥64K context (`granite-31-8b-fp8`, `nemotron-nano-9b-v2-fp8`) |
| hermes runs but never actually executes a command it says it will | Expected — see "Tool-calling limitation" above | Use `scripts/oc-debug.sh` instead of asking hermes to run `oc` itself, or switch to `/model groq` |
| `groq-llama-3.3-70b` call fails with an auth/401-style error from litellm | `GROQ_API_KEY` not set (or stale) in `litellm-secrets` | Run `./add-groq-key.sh` |
| Groq works via curl but not via hermes | `hermes/config.snippet.yaml`'s `groq` alias not merged into `~/.hermes/config.yaml`, or still on the old config without it | Re-merge the snippet, `hermes -m groq -z "hi"` to test directly |
| litellm pod stuck `0/1 Ready` after a redeploy, `oc describe pod` shows the `readinessProbe` failing with 401/403 on `/health/readiness` | Known upstream regression in some litellm builds where that endpoint unexpectedly requires `x-litellm-key` ([BerriAI/litellm#8795](https://github.com/BerriAI/litellm/issues/8795)) | Check litellm pod logs for the actual error; if it's this, pin to an unaffected `litellm` image tag, or open an issue upstream — the readinessProbe itself (`k8s/deployment-litellm.yaml`) is unauthenticated by design per litellm's docs |
