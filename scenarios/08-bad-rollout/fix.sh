# Sourced by scenario.sh. The realistic fix is a rollback, not a re-create.
oc rollout undo deployment/demo-shop -n "$NAMESPACE"
oc rollout status deployment/demo-shop -n "$NAMESPACE" --timeout=90s
