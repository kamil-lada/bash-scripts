#!/bin/bash
# ha-maintenance.sh — Cluster maintenance: HA resources, node maintenance mode, Ceph flags
#
# Usage:
#   ha-maintenance.sh enable  [--yes] [--dry-run]
#   ha-maintenance.sh disable [--yes] [--dry-run]
#
# enable  (pre-maintenance):
#   1. Snapshot all started HA resources and set them to ignored
#   2. Enable HA maintenance mode on all cluster nodes
#   3. Set Ceph flags: noout norebalance norecover nobackfill
#
# disable (post-maintenance):
#   1. Unset Ceph flags
#   2. Disable HA maintenance mode on all cluster nodes
#   3. Restore HA resources to started (from snapshot)
#
# Options:
#   --yes      Skip confirmation prompt
#   --dry-run  Show what would be done without making any changes

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

STATE_FILE="./ha-maintenance-resources.txt"
CEPH_FLAGS=(noout norebalance norecover nobackfill)

# ── Arg parsing ──────────────────────────────────────────────────────────────

ACTION=""
DRY_RUN=false
AUTO_YES=false

usage() {
    grep "^#" "$0" | head -20 | sed 's/^# \?//'
    exit "${1:-0}"
}

for arg in "$@"; do
    case "$arg" in
        enable|disable) ACTION="$arg" ;;
        --dry-run|-n)   DRY_RUN=true ;;
        --yes|-y)       AUTO_YES=true ;;
        --help|-h)      usage 0 ;;
        *)
            echo "ERROR: Unknown argument: $arg"
            usage 1
            ;;
    esac
done

if [[ -z "$ACTION" ]]; then
    echo "ERROR: Action required."
    usage 1
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

step() { echo ""; echo "=== $* ==="; }

run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

confirm() {
    if $AUTO_YES; then
        return 0
    fi
    echo ""
    read -r -p "Proceed? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

get_nodes() {
    pvecm nodes | awk '$1 ~ /^[0-9]+$/ { print $3 }'
}

get_started_resources() {
    ha-manager config | awk '
    /^(vm|ct):/ {
        if (sid != "" && (!has_state || state == "started")) print sid
        sid = $1 $2; has_state = 0; state = ""
    }
    /^[[:space:]]+state[[:space:]]+/ { has_state = 1; state = $2 }
    END { if (sid != "" && (!has_state || state == "started")) print sid }
    '
}

# ── Pre-flight ───────────────────────────────────────────────────────────────

CEPH_AVAILABLE=false

preflight() {
    step "Pre-flight"

    echo -n "  Cluster quorate ... "
    if pvecm status 2>/dev/null | grep -q "Quorate:[[:space:]]*Yes"; then
        echo "ok"
    else
        echo "FAIL"
        echo "ERROR: Cluster is not quorate — aborting"
        exit 1
    fi

    echo -n "  HA manager ... "
    if ha-manager status &>/dev/null; then
        echo "ok"
    else
        echo "FAIL"
        echo "ERROR: ha-manager not accessible — aborting"
        exit 1
    fi

    echo -n "  Ceph ... "
    if ceph status &>/dev/null; then
        CEPH_AVAILABLE=true
        echo "ok"
    else
        echo "not available (Ceph steps will be skipped)"
    fi
}

# ── Enable ───────────────────────────────────────────────────────────────────

do_enable() {
    if [[ -f "$STATE_FILE" ]]; then
        echo ""
        echo "ERROR: State file already exists: $STATE_FILE"
        echo "       Maintenance may already be active, or a previous run was not cleaned up."
        echo "       Inspect the file, then remove it manually if stale."
        exit 1
    fi

    NODES=$(get_nodes)
    if [[ -z "$NODES" ]]; then
        echo "ERROR: No cluster nodes found via pvecm nodes"
        exit 1
    fi

    RESOURCES=$(get_started_resources)
    if [[ -z "$RESOURCES" ]]; then
        echo "ERROR: No HA resources in started state found"
        exit 1
    fi

    step "Plan: enable"
    echo "  Nodes:"
    echo "$NODES"     | sed 's/^/    /'
    echo "  HA resources (started → ignored):"
    echo "$RESOURCES"  | sed 's/^/    /'
    if $DRY_RUN; then
        echo ""
        echo "  [dry-run — no changes will be made]"
    fi

    confirm

    # 1. HA resources → ignored
    step "HA resources → ignored"
    if ! $DRY_RUN; then
        echo "$RESOURCES" > "$STATE_FILE"
    fi
    while IFS= read -r sid; do
        echo -n "  $sid -> ignored ... "
        run ha-manager set "$sid" --state ignored
        if ! $DRY_RUN; then echo "ok"; fi
    done <<< "$RESOURCES"

    # 2. HA node maintenance
    step "HA node maintenance → enable"
    while IFS= read -r node; do
        echo -n "  $node ... "
        run ha-manager crm-command node-maintenance enable "$node"
        if ! $DRY_RUN; then echo "ok"; fi
    done <<< "$NODES"

    # 3. Ceph flags
    step "Ceph flags → set"
    if ! $CEPH_AVAILABLE; then
        echo "  Skipped (Ceph not accessible)"
    else
        for flag in "${CEPH_FLAGS[@]}"; do
            run ceph osd set "$flag"
        done
        if ! $DRY_RUN; then
            echo ""
            ceph osd dump | awk '/^flags/ { print "  " $0 }'
        fi
    fi

    echo ""
    if $DRY_RUN; then
        echo "Dry-run complete. No changes were made."
    else
        echo "Maintenance ENABLED."
        echo "Run '$0 disable' when maintenance is complete."
    fi
}

# ── Disable ──────────────────────────────────────────────────────────────────

do_disable() {
    if ! $DRY_RUN && [[ ! -f "$STATE_FILE" ]]; then
        echo ""
        echo "ERROR: State file not found: $STATE_FILE"
        echo "       Was '$0 enable' run first?"
        exit 1
    fi

    NODES=$(get_nodes)
    if [[ -z "$NODES" ]]; then
        echo "ERROR: No cluster nodes found via pvecm nodes"
        exit 1
    fi

    step "Plan: disable"
    echo "  Nodes:"
    echo "$NODES" | sed 's/^/    /'
    echo "  HA resources (ignored → started):"
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE" | sed 's/^/    /'
    else
        echo "    (state file not present — dry-run only)"
    fi
    if $DRY_RUN; then
        echo ""
        echo "  [dry-run — no changes will be made]"
    fi

    confirm

    # 1. Ceph flags
    step "Ceph flags → unset"
    if ! $CEPH_AVAILABLE; then
        echo "  Skipped (Ceph not accessible)"
    else
        for flag in "${CEPH_FLAGS[@]}"; do
            run ceph osd unset "$flag"
        done
        if ! $DRY_RUN; then
            echo ""
            ceph osd dump | awk '/^flags/ { print "  " $0 }'
        fi
    fi

    # 2. HA node maintenance
    step "HA node maintenance → disable"
    while IFS= read -r node; do
        echo -n "  $node ... "
        run ha-manager crm-command node-maintenance disable "$node"
        if ! $DRY_RUN; then echo "ok"; fi
    done <<< "$NODES"

    # 3. HA resources → started
    step "HA resources → started"
    if $DRY_RUN; then
        if [[ -f "$STATE_FILE" ]]; then
            while IFS= read -r sid; do
                echo "  [dry-run] ha-manager set $sid --state started"
            done < "$STATE_FILE"
        fi
    else
        while IFS= read -r sid; do
            echo -n "  $sid -> started ... "
            ha-manager set "$sid" --state started
            echo "ok"
        done < "$STATE_FILE"
        rm -f "$STATE_FILE"
        echo "  State file removed."
    fi

    echo ""
    if $DRY_RUN; then
        echo "Dry-run complete. No changes were made."
    else
        echo "Maintenance DISABLED."
        echo "Verify: ha-manager status && ceph status"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

preflight

case "$ACTION" in
    enable)  do_enable  ;;
    disable) do_disable ;;
esac