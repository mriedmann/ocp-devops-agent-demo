#!/usr/bin/env bash
# Sanity-checks that this is the kind of Red Hat Developer Sandbox this
# howto targets: a 30-day trial with the OpenShift AI (RHOAI) add-on,
# which pre-provisions a `sandbox-shared-models` project holding shared,
# already-running vLLM InferenceServices.
#
# Usage: ./00-check-prereqs.sh
set -euo pipefail

command -v oc >/dev/null || { echo "oc CLI not found. Install it and 'oc login' to your sandbox first."; exit 1; }
command -v jq >/dev/null || { echo "jq not found. Install it (apt/brew install jq)."; exit 1; }

oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run 'oc login --token=... --server=...' (copy this from the sandbox web console's 'Copy login command')."; exit 1; }

echo "Logged in as: $(oc whoami)"

SHARED_NS="${SHARED_MODELS_NAMESPACE:-sandbox-shared-models}"

if ! oc get project "$SHARED_NS" >/dev/null 2>&1; then
  echo "Project '$SHARED_NS' not found or not visible to this user."
  echo "This howto assumes a sandbox with a pre-provisioned shared-models project."
  echo "If your sandbox uses a different name, re-run with:"
  echo "  SHARED_MODELS_NAMESPACE=<name> ./00-check-prereqs.sh"
  exit 1
fi

echo "Found shared models project: $SHARED_NS"

COUNT=$(oc get inferenceservice -n "$SHARED_NS" -o json 2>/dev/null | jq '.items | length')
if [ "$COUNT" -eq 0 ]; then
  echo "No InferenceServices found in $SHARED_NS. Nothing to point litellm at yet."
  exit 1
fi

echo "Found $COUNT InferenceService(s) in $SHARED_NS:"
oc get inferenceservice -n "$SHARED_NS" -o custom-columns=NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status'

DEV_NS="${NAMESPACE:-$(oc project -q)}"
echo
echo "Deploy target (your own project): $DEV_NS"
echo "Prereqs look good. Next: ./01-deploy.sh"
