#!/bin/bash
# Switch apt sources from http:// to https:// where the mirror supports it.
# Dry run by default (prints the plan); --apply changes the files, verifies with
# apt-get update and rolls back on errors. See apt_https_migrate in lib/common.sh.
#
# Usage: bash apt-https_migrate.sh [--apply]
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

if [[ $EUID -eq 0 ]]; then
    LOGFILE="/var/log/apt-https-migrate.log"
    : > "$LOGFILE"
fi

log_section "APT http -> https migration"
apt_https_migrate "$@"
