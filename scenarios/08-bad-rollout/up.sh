# Sourced by scenario.sh. Rolls out a healthy v1, then a broken v2 on top.
apply_file "$SCEN_DIR/v1.yaml"
oc rollout status deployment/demo-shop -n "$NAMESPACE" --timeout=90s
apply_file "$SCEN_DIR/broken.yaml"
