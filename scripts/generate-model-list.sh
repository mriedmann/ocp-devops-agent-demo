#!/usr/bin/env bash
# Regenerates the `model_list:` block of k8s/configmap-litellm-config.yaml
# from whatever InferenceServices are actually Ready in the shared-models
# project right now, instead of relying on the 3 hardcoded in that file.
#
# Assumes this sandbox's convention that each ServingRuntime's
# --served-model-name matches the InferenceService's metadata.name (true
# for every model observed at doc-writing time). If a future model breaks
# that convention, edit the generated block by hand.
#
# Usage: ./generate-model-list.sh   (prints YAML to stdout, indented to
#                                     paste under model_list: in the ConfigMap)
set -euo pipefail

SHARED_NS="${SHARED_MODELS_NAMESPACE:-sandbox-shared-models}"

oc get inferenceservice -n "$SHARED_NS" -o json | jq -r --arg ns "$SHARED_NS" '
  .items[]
  | select((.status.conditions // []) | any(.type == "Ready" and .status == "True"))
  | .metadata.name as $full
  | ($full | sub("^isvc-"; "")) as $short
  | "      - model_name: \($short)\n        litellm_params:\n          model: hosted_vllm/\($full)\n          api_base: https://\($full)-predictor.\($ns).svc.cluster.local:8443/v1\n          api_key: os.environ/KSERVE_TOKEN"
'
