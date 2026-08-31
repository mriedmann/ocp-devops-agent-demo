#!/usr/bin/env bash
# Lists the Ready InferenceServices in the shared-models project along with
# their internal predictor URLs. Useful to see what your sandbox actually
# has available, since the shared model pool changes over time.
#
# Usage: ./list-shared-models.sh
set -euo pipefail

SHARED_NS="${SHARED_MODELS_NAMESPACE:-sandbox-shared-models}"

oc get inferenceservice -n "$SHARED_NS" -o json | jq -r '
  .items[]
  | select((.status.conditions // []) | any(.type == "Ready" and .status == "True"))
  | "\(.metadata.name)\t\(.status.url // .status.address.url)"
' | column -t -N "NAME,PREDICTOR-URL"
