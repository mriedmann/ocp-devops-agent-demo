#!/usr/bin/env bash
# Workshop driver: one broken-app scenario at a time in your sandbox project.
#
#   ./scripts/scenario.sh                 menu (active scenario marked with >; "menu -v" adds titles)
#   ./scripts/scenario.sh up 4            tear down whatever is active, break scenario 4,
#                                         print + clipboard-copy the prompt for the agent
#   ./scripts/scenario.sh next | prev     down + up of the following / preceding scenario
#   ./scripts/scenario.sh prompt [n]      print (and copy) the agent prompt
#   ./scripts/scenario.sh ask [n]         run the prompt through `opencode run` (non-interactive)
#   ./scripts/scenario.sh status          what the presenter sees with plain `oc get`
#   ./scripts/scenario.sh reveal [n]      presenter notes: root cause, expected tool path, fix
#   ./scripts/scenario.sh fix             apply the fix the agent should have proposed
#   ./scripts/scenario.sh down            remove the active scenario (leaves nothing behind)
#   ./scripts/scenario.sh preflight       check login, MCP pod, quota headroom, leftovers
#
# [n] is the number (4 or 04) or a name fragment (oom). Omitted = the active scenario.
# Everything a scenario creates carries the label ocp-agent-demo=<scenario>, and `down`
# deletes strictly by that label, so litellm/postgres/openshift-mcp are never touched.
#
# Env vars (all optional):
#   NAMESPACE        project to use (default: current oc project)
#   OPENCODE_MODEL   model for `ask` (default: litellm/nemotron-3.5-lightning)
set -euo pipefail
cd "$(dirname "$0")/.."

export NAMESPACE="${NAMESPACE:-$(oc project -q)}"
ROOT="scenarios"
LABEL="ocp-agent-demo"
KINDS="pod,deployment,replicaset,job,service,route,configmap,persistentvolumeclaim,networkpolicy"

PROMPT_PREFIX="You are debugging the OpenShift project ${NAMESPACE} with the openshift MCP tools. You cannot change anything: investigate, state the root cause with the evidence you found, and propose the exact fix (oc command or YAML). Keep it short."

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

apply_file() { oc apply -n "$NAMESPACE" -f "$1"; }

all_dirs() { ls -1d "$ROOT"/[0-9][0-9]-* 2>/dev/null | xargs -n1 basename; }

title_of() { sed -n '1s/^# *//p' "$ROOT/$1/notes.md"; }

# Scenario currently deployed (empty if none), read from the labels in the cluster.
active() {
  oc get "$KINDS" -n "$NAMESPACE" -l "$LABEL" \
    -o jsonpath="{range .items[*]}{.metadata.labels.${LABEL//./\\.}}{\"\\n\"}{end}" 2>/dev/null \
    | sort -u | head -n1
}

# number / name fragment / empty (=active) -> directory name
resolve() {
  local arg="${1:-}" match
  if [ -z "$arg" ]; then
    match="$(active)"
    [ -n "$match" ] || die "no scenario is active; pass a number, e.g. '$0 up 1'"
    echo "$match"; return
  fi
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    match="$(printf '%02d' "$((10#$arg))")"
    match="$(all_dirs | grep "^${match}-" || true)"
  else
    match="$(all_dirs | grep -- "$arg" || true)"
  fi
  [ -n "$match" ] || die "no scenario matches '$arg' (run '$0' for the list)"
  [ "$(echo "$match" | wc -l)" -eq 1 ] || die "'$arg' is ambiguous: $(echo "$match" | tr '\n' ' ')"
  echo "$match"
}

copy_clip() {
  if command -v clip.exe >/dev/null; then clip.exe
  elif command -v pbcopy >/dev/null; then pbcopy
  elif command -v wl-copy >/dev/null; then wl-copy
  elif command -v xclip >/dev/null; then xclip -selection clipboard
  else cat >/dev/null; return 1
  fi
}

prompt_text() {
  # Only substitute ${NAMESPACE}; leave any other $ in the prompt alone.
  echo "$PROMPT_PREFIX $(envsubst '${NAMESPACE}' < "$ROOT/$1/prompt.txt")"
}

show_prompt() {
  local text; text="$(prompt_text "$1")"
  echo
  bold "Prompt for the agent:"
  echo "$text"
  if printf '%s' "$text" | copy_clip 2>/dev/null; then dim "(copied to clipboard)"; fi
}

# Events outlive their objects for ~1h. Drop the ones about demo-* objects so the next
# scenario starts clean and the agent's events_list is not polluted by the previous one.
purge_events() {
  oc get events -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[] | select(.involvedObject.name | startswith("demo-")) | .metadata.name' \
    | xargs -r oc delete event -n "$NAMESPACE" >/dev/null 2>&1 || true
}

teardown() {
  local found
  found="$(oc get "$KINDS" -n "$NAMESPACE" -l "$LABEL" -o name 2>/dev/null || true)"
  if [ -n "$found" ]; then
    echo "Removing previous scenario ($(active | cut -d- -f1))..."
    oc delete "$KINDS" -n "$NAMESPACE" -l "$LABEL" --wait=true --ignore-not-found >/dev/null
  fi
  purge_events
}

# Give the symptom time to appear (image pulls, restarts, probe failures).
settle() {
  local secs=10 f="$ROOT/$1/settle"
  [ -f "$f" ] && secs="$(cat "$f")"
  printf 'Letting the symptom develop (%ss)' "$secs"
  local i; for ((i = 0; i < secs; i++)); do sleep 1; printf '.'; done
  echo
}

status() {
  oc get pod,deployment,replicaset,job,service,route,persistentvolumeclaim,networkpolicy,configmap \
    -n "$NAMESPACE" -l "$LABEL" 2>&1 | grep -v '^No resources' || true
}

# Titles give away the root cause, so they only show with -v (screen-sharing safe by default).
cmd_menu() {
  local act d verbose="${1:-}"; act="$(active)"
  bold "Scenarios in project $NAMESPACE"
  for d in $(all_dirs); do
    if [ "$d" = "$act" ]; then printf '  > '; else printf '    '; fi
    if [ "$verbose" = "-v" ]; then printf '%s  %s\n' "${d%%-*}" "$(title_of "$d")"; else echo "${d%%-*}"; fi
  done
  echo
  dim "up <n> | next | prev | prompt | ask | status | reveal | fix | down | preflight   (menu -v shows titles = spoilers)"
}

cmd_up() {
  local d; d="$(resolve "${1:?usage: $0 up <n>}")"
  SCEN_DIR="$ROOT/$d"
  teardown
  bold "Starting scenario ${d%%-*}"
  if [ -f "$SCEN_DIR/up.sh" ]; then
    # shellcheck disable=SC1090
    source "$SCEN_DIR/up.sh"
  else
    apply_file "$SCEN_DIR/broken.yaml"
  fi
  settle "$d"
  echo
  bold "What the audience would see with plain oc:"
  status
  show_prompt "$d"
  echo
  dim "After the demo: '$0 reveal' (notes), '$0 fix' (apply the fix), '$0 next'."
}

cmd_next_prev() {
  local step="$1" act i=0 idx=-1 d dirs
  act="$(active)"
  mapfile -t dirs < <(all_dirs)
  for d in "${dirs[@]}"; do
    [ "$d" = "$act" ] && idx=$i
    i=$((i + 1))
  done
  if [ "$idx" -lt 0 ]; then idx=$([ "$step" -gt 0 ] && echo -1 || echo "${#dirs[@]}"); fi
  idx=$((idx + step))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#dirs[@]}" ]; then
    die "already at the $([ "$step" -gt 0 ] && echo last || echo first) scenario"
  fi
  cmd_up "${dirs[$idx]}"
}

cmd_fix() {
  local d; d="$(resolve "${1:-}")"
  SCEN_DIR="$ROOT/$d"
  [ "$(active)" = "$d" ] || die "scenario $d is not active"
  bold "Applying the fix for scenario ${d%%-*}"
  if [ -f "$SCEN_DIR/fix.sh" ]; then
    # shellcheck disable=SC1090
    source "$SCEN_DIR/fix.sh"
  else
    # Several fixes touch immutable fields (image of a bare pod, PVC class, job command),
    # so recreate instead of patching.
    oc delete "$KINDS" -n "$NAMESPACE" -l "$LABEL" --wait=true --ignore-not-found >/dev/null
    apply_file "$SCEN_DIR/fixed.yaml"
  fi
  settle "$d"
  status
}

cmd_preflight() {
  local ok=1
  oc whoami >/dev/null 2>&1 && echo "OK   logged in as $(oc whoami), project $NAMESPACE" || { echo "FAIL not logged in to oc"; ok=0; }
  if oc get pod -n "$NAMESPACE" -l app=openshift-mcp --no-headers 2>/dev/null | grep -q ' 1/1 .*Running'; then
    echo "OK   openshift-mcp pod is Running"
  else
    echo "FAIL openshift-mcp pod not Ready (oc get pods -l app=openshift-mcp)"; ok=0
  fi
  if oc get pod -n "$NAMESPACE" -l app=litellm --no-headers 2>/dev/null | grep -q ' 1/1 .*Running'; then
    echo "OK   litellm pod is Running"
  else
    echo "FAIL litellm pod not Ready"; ok=0
  fi
  local act; act="$(active)"
  [ -z "$act" ] && echo "OK   no scenario left over" || echo "NOTE scenario $act is still active ('$0 down')"
  echo
  bold "Quota headroom (a scenario needs < 100m CPU, < 300Mi memory)"
  oc get resourcequota -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /' || true
  echo
  bold "Replicaset count in the project (the sandbox caps it, keep it well below 30)"
  echo "  $(oc get replicaset -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l) ReplicaSets present"
  [ "$ok" -eq 1 ] || exit 1
}

case "${1:-menu}" in
  menu|list|ls)  shift; cmd_menu "${1:-}" ;;
  up|start)      shift; cmd_up "${1:-}" ;;
  next)          cmd_next_prev 1 ;;
  prev|previous) cmd_next_prev -1 ;;
  prompt)        shift; show_prompt "$(resolve "${1:-}")" ;;
  ask)           shift; d="$(resolve "${1:-}")"
                 exec opencode run -m "${OPENCODE_MODEL:-litellm/nemotron-3.5-lightning}" "$(prompt_text "$d")" ;;
  status)        status ;;
  reveal)        shift; d="$(resolve "${1:-}")"; echo; cat "$ROOT/$d/notes.md" ;;
  fix)           shift; cmd_fix "${1:-}" ;;
  down|stop|clean) teardown; echo "No scenario active." ;;
  preflight|check) cmd_preflight ;;
  -h|--help|help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (try '$0 help')" ;;
esac
