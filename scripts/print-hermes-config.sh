#!/usr/bin/env bash
# Prints what you need to use litellm from your laptop without cluster/oc
# access: the Admin UI URL + login, and a ready-to-merge hermes config block
# with the real public Route host baked into base_url (replacing the
# hermes/config.snippet.yaml port-forward default of http://localhost:4000).
#
# Usage: ./print-hermes-config.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE="${NAMESPACE:-$(oc project -q)}"

if ! oc get route litellm -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Route 'litellm' not found in $NAMESPACE — run ./01-deploy.sh first." >&2
  exit 1
fi

HOST=$(oc get route litellm -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo "Admin UI: https://${HOST}/ui"
echo "Log in with username 'admin' and this password (your LITELLM_MASTER_KEY):"
echo
oc get secret litellm-secrets -n "$NAMESPACE" -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d
echo
echo
echo "── hermes config (merge into ~/.hermes/config.yaml) ──────────────────"
sed "s#http://localhost:4000#https://${HOST}#g" hermes/config.snippet.yaml
