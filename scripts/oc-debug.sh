#!/usr/bin/env bash
# Minimal OpenShift debugging with hermes, working around the fact that
# hermes' terminal/tool-calling can't work against these vLLM backends
# (see README "Tool-calling limitation"): run an `oc` command yourself,
# then hand its output to hermes as a one-shot analysis prompt. No native
# function-calling involved — hermes never runs `oc` itself, it only
# reasons over text you already captured, so this works today with zero
# server-side changes.
#
# Usage:
#   ./oc-debug.sh get pods -n my-namespace
#   ./oc-debug.sh describe pod some-pod -n my-namespace
#   ./oc-debug.sh logs deploy/litellm-deployment -n my-namespace --tail=200
#
# Env vars:
#   HERMES_MODEL   override the model for this call (default: hermes'
#                   configured default — see hermes/config.snippet.yaml)
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 <oc subcommand and args...>" >&2
  echo "Example: $0 get pods -n my-namespace" >&2
  exit 1
fi

echo "+ oc $*" >&2
OUTPUT=$(oc "$@" 2>&1) || true

MODEL_FLAG=()
if [ -n "${HERMES_MODEL:-}" ]; then
  MODEL_FLAG=(-m "$HERMES_MODEL")
fi

hermes "${MODEL_FLAG[@]}" -z "Here is the output of \`oc $*\`:

\`\`\`
$OUTPUT
\`\`\`

Analyze this for problems (crashloops, pending/failed pods, image pull
errors, high restart counts, resource pressure, anything else unusual).
If everything looks healthy, say so briefly. Be concise."
