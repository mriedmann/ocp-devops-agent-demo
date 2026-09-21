#!/usr/bin/env bash
# Prints what you need to use litellm from your laptop without cluster/oc
# access: the Admin UI URL + login, and the opencode config for it (the
# opencode/config.snippet.json baseURL rewritten to litellm's public Route
# host) — then offers to merge that config into your local
# ~/.config/opencode/opencode.json.
#
# The merge is:
#   - idempotent: re-running after a redeploy (new Route host, new models,
#     ...) converges the file to match, without piling up duplicate entries.
#   - non-destructive: deep-merged with `jq` — anything else already in
#     your opencode.json (other providers, agents, permissions, ...) is left
#     untouched, and a timestamped .bak copy is written before any change.
#   - manual: always shows a diff of what would change and asks for
#     confirmation first. Decline (or pipe/non-interactive with no -y) and
#     nothing is written — the config block is printed instead, unchanged
#     from before, for you to merge by hand.
#
# Usage:
#   ./print-opencode-config.sh          # prompts before writing
#   ./print-opencode-config.sh -y       # skip the confirmation prompt
#
# Env vars:
#   OPENCODE_CONFIG_PATH   override the target file (default: ~/.config/opencode/opencode.json)
set -euo pipefail
cd "$(dirname "$0")/.."

ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    *) echo "Usage: $0 [-y|--yes]" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required (see README Prerequisites)." >&2; exit 1; }

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

NEW_CONFIG=$(sed "s#{env:LITELLM_URL}#https://${HOST}#g" opencode/config.snippet.json)
TARGET="${OPENCODE_CONFIG_PATH:-$HOME/.config/opencode/opencode.json}"

print_block() {
  echo "── opencode config (merge into ${TARGET}) ─────"
  echo "$NEW_CONFIG"
}

if [ ! -f "$TARGET" ]; then
  echo "No existing config at $TARGET."
  print_block
  if [ "$ASSUME_YES" = false ]; then
    read -rp "Create it with the config above? [y/N] " REPLY || REPLY=""
    [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ] || { echo "Not written."; exit 0; }
  fi
  mkdir -p "$(dirname "$TARGET")"
  echo "$NEW_CONFIG" | jq . > "$TARGET"
  echo "Wrote $TARGET"
  exit 0
fi

if ! jq empty "$TARGET" >/dev/null 2>&1; then
  echo "Existing $TARGET is not valid JSON — not touching it." >&2
  print_block
  exit 1
fi

#   - only touches your top-level default `model` if it's unset or already
#     points at `litellm/*` — a default you've since switched to some other
#     provider is left alone, even though this config still refreshes.
MERGED=$(jq -s '
  (.[0].model) as $old_model |
  (.[1].model) as $new_model |
  (.[0] * .[1]) + {
    model: (if ($old_model == null) or ($old_model | test("^litellm/"))
            then $new_model else $old_model end)
  }
' "$TARGET" <(echo "$NEW_CONFIG"))

if diff -q <(jq -S . "$TARGET") <(echo "$MERGED" | jq -S .) >/dev/null; then
  echo "$TARGET is already up to date, nothing to do."
  exit 0
fi

echo "This would change $TARGET (existing content on the left, merged result on the right):"
echo
diff -u <(jq . "$TARGET") <(echo "$MERGED" | jq .) || true
echo

if [ "$ASSUME_YES" = false ]; then
  read -rp "Apply this merge to $TARGET? [y/N] " REPLY || REPLY=""
  if [ "$REPLY" != "y" ] && [ "$REPLY" != "Y" ]; then
    echo "Not written."
    print_block
    exit 0
  fi
fi

BACKUP="${TARGET}.bak.$(date +%Y%m%d%H%M%S)"
cp "$TARGET" "$BACKUP"
echo "$MERGED" | jq . > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"
echo "Merged. Backup of the previous file: $BACKUP"
