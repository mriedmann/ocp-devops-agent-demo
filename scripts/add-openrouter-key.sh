#!/usr/bin/env bash
# Adds (or rotates) the OPENROUTER_API_KEY entry in the litellm-secrets
# Secret, then restarts litellm-deployment so the new env var is picked up
# (env vars from a Secret are only read at container start).
#
# Prompts interactively with hidden input — never pass the key as a CLI
# arg or env var on the command line, it'd end up in your shell history.
#
# Get a free key at: https://openrouter.ai/keys
#
# Usage: ./add-openrouter-key.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-$(oc project -q)}"

if ! oc get secret litellm-secrets -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "litellm-secrets not found in $NAMESPACE — run 01-deploy.sh first." >&2
  exit 1
fi

read -rsp "OpenRouter API key (from https://openrouter.ai/keys): " OPENROUTER_KEY
echo
if [ -z "$OPENROUTER_KEY" ]; then
  echo "No key entered, aborting." >&2
  exit 1
fi

ENCODED=$(printf '%s' "$OPENROUTER_KEY" | base64 | tr -d '\n')
unset OPENROUTER_KEY

# JSON merge patch on `data` only touches the keys named here — the
# existing LITELLM_MASTER_KEY (and anything else already in the Secret)
# is left alone.
oc patch secret litellm-secrets -n "$NAMESPACE" --type=merge \
  -p "{\"data\":{\"OPENROUTER_API_KEY\":\"$ENCODED\"}}"
unset ENCODED

echo "Restarting litellm-deployment to pick up the new key..."
oc rollout restart deployment/litellm-deployment -n "$NAMESPACE"
oc rollout status deployment/litellm-deployment -n "$NAMESPACE" --timeout=180s

echo
echo "Done. Verify with:"
echo "  ./02-verify.sh"
echo "or directly:"
echo "  curl -s http://localhost:4000/v1/chat/completions \\"
echo "    -d '{\"model\":\"nemotron-3.5-lightning\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
