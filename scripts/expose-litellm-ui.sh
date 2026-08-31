#!/usr/bin/env bash
# Exposes litellm's Admin UI externally via an OpenShift Route, so it can be
# shown to people without cluster/oc access. This does NOT add a new auth
# layer of its own — the UI login (and the API) is already gated by
# LITELLM_MASTER_KEY (general_settings.master_key in
# k8s/configmap-litellm-config.yaml). Log in with username "admin" and that
# key as the password.
#
# Temporary by design — tear it down after the showcase:
#   oc delete -f k8s/route-litellm-ui.yaml
set -euo pipefail
cd "$(dirname "$0")/.."

export NAMESPACE="${NAMESPACE:-$(oc project -q)}"

if ! oc get secret litellm-secrets -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "litellm-secrets not found in $NAMESPACE — run ./01-deploy.sh first." >&2
  exit 1
fi

envsubst < k8s/route-litellm-ui.yaml | oc apply -f -

HOST=$(oc get route litellm-ui -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo
echo "UI exposed at: https://${HOST}/ui"
echo "Log in with username 'admin' and this password (your LITELLM_MASTER_KEY):"
echo
oc get secret litellm-secrets -n "$NAMESPACE" -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d
echo
echo
echo "Tear this down after the showcase:"
echo "  oc delete -f k8s/route-litellm-ui.yaml"
