#!/bin/bash
# jenkins-dump — one-off: dump the global settings of a GUI-configured (temporary) Jenkins,
# so they can be baked into jenkins-controller.sh. Not used by jenkins-controller.sh at runtime.
#
# Usage:
#   jenkins-dump.sh <JENKINS_HOME dir | container name> [output dir (default: .)]
#
# Includes: top-level *.xml (except credentials.xml), Jenkins version,
#           plugin list name:version (all, and top-level = not a required dependency of another plugin).
# Excludes: secrets/, secret.key*, identity.key.enc, credentials.xml, users/, nodes/, jobs/,
#           workspace/, logs — only the files above are ever read.
# Encrypted {AQAAAB…} values are not portable: they are masked in the XML and listed in ENCRYPTED.txt.
#
# Standalone: needs bash, tar, awk (+ docker for a container source).
set -Eeuo pipefail

die()  { echo "[✗] $*" >&2; exit 1; }
ok()   { echo "[✓] $*"; }

[[ $# -ge 1 && $1 != -h && $1 != --help ]] || { sed -n '/^# Usage:/,/^# Standalone/s/^# \{0,1\}//p' "$0"; exit 0; }
SRC="$1"
OUT_BASE="${2:-.}"

# Prints a tar stream of the wanted files, run inside JENKINS_HOME (sh-compatible, also used in containers)
# shellcheck disable=SC2016
PICK='find . -maxdepth 1 -type f -name "*.xml" ! -name credentials.xml
      find plugins -mindepth 3 -maxdepth 3 -path "plugins/*/META-INF/MANIFEST.MF" 2>/dev/null
      find plugins -maxdepth 1 -name "*.disabled" 2>/dev/null'

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/raw"

if [[ -d $SRC ]]; then
    [[ -r $SRC/config.xml ]] || die "$SRC/config.xml not readable (not a JENKINS_HOME, or run as root)"
    (cd "$SRC" && eval "{ $PICK; }" | tar cf - -T -) | tar xf - -C "$STAGE/raw"
    LABEL=$(hostname -s)
elif command -v docker >/dev/null && docker inspect "$SRC" >/dev/null 2>&1; then
    docker exec "$SRC" sh -c "cd \"\${JENKINS_HOME:-/var/jenkins_home}\" && { $PICK; } | tar cf - -T -" \
        | tar xf - -C "$STAGE/raw" || die "Reading from container $SRC failed"
    LABEL="$SRC"
else
    die "'$SRC' is neither a directory nor a docker container"
fi
[[ -f $STAGE/raw/config.xml ]] || die "No config.xml found — wrong source?"

NAME="jenkins-dump-$LABEL-$(date +%Y%m%d-%H%M%S)"
OUT="$STAGE/$NAME"
mkdir -p "$OUT/xml"

# --- XML: mask encrypted values, list where they were
: > "$OUT/ENCRYPTED.txt"
for f in "$STAGE"/raw/*.xml; do
    b=$(basename "$f")
    grep -o '<[^/<>]*>{AQAAAB[^}]*}' "$f" | sed "s/>.*//; s/^</$b: </; s/\$/>/" >> "$OUT/ENCRYPTED.txt" || true
    sed 's/{AQAAAB[^}]*}/{ENCRYPTED-NOT-PORTABLE}/g' "$f" > "$OUT/xml/$b"
done

# --- plugins: unfold MANIFEST continuation lines, take name/version/required deps
manifest() { tr -d '\r' < "$1" | awk '/^ /{l=l substr($0,2); next} {if(l!="")print l; l=$0} END{print l}'; }
: > "$STAGE/deps"; : > "$OUT/plugins-all.txt"
for m in "$STAGE"/raw/plugins/*/META-INF/MANIFEST.MF; do
    [[ -f $m ]] || continue
    mf=$(manifest "$m")
    n=$(sed -n 's/^Short-Name: //p' <<< "$mf")
    v=$(sed -n 's/^Plugin-Version: //p' <<< "$mf")
    [[ -n $n ]] || continue
    echo "$n:$v" >> "$OUT/plugins-all.txt"
    # Plugin-Dependencies: a:1.0,b:2.0;resolution:=optional  -> required names only
    sed -n 's/^Plugin-Dependencies: //p' <<< "$mf" | tr ',' '\n' | grep -v 'resolution:=optional' \
        | cut -d: -f1 >> "$STAGE/deps" || true
done
sort -o "$OUT/plugins-all.txt" "$OUT/plugins-all.txt"
sort -u -o "$STAGE/deps" "$STAGE/deps"
awk -F: 'NR==FNR{d[$1]=1; next} !($1 in d)' "$STAGE/deps" "$OUT/plugins-all.txt" > "$OUT/plugins-top.txt"
for d in "$STAGE"/raw/plugins/*.disabled; do
    [[ -f $d ]] && basename "$d" | sed 's/\.[jh]pi\.disabled$//'
done > "$OUT/plugins-disabled.txt"

VERSION=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$STAGE/raw/config.xml" | head -1)
cat > "$OUT/INFO.txt" <<EOF
Jenkins dump for jenkins-controller.sh (build session input)
Source:        $SRC
Date:          $(date -Is)
Jenkins:       ${VERSION:-unknown}
XML files:     $(ls "$OUT/xml" | wc -l)   (xml/, encrypted values masked)
Plugins:       $(wc -l < "$OUT/plugins-all.txt") total, $(wc -l < "$OUT/plugins-top.txt") top-level, $(wc -l < "$OUT/plugins-disabled.txt") disabled
Encrypted:     $(wc -l < "$OUT/ENCRYPTED.txt") value(s) — must become questions / .env values (ENCRYPTED.txt)
Not included:  secrets/, credentials.xml, users/, nodes/, jobs/, workspace/, logs
EOF

mkdir -p "$OUT_BASE"
tar czf "$OUT_BASE/$NAME.tar.gz" -C "$STAGE" "$NAME"
cat "$OUT/INFO.txt"
ok "Written $(readlink -f "$OUT_BASE/$NAME.tar.gz")"
