#!/usr/bin/env bash
# tests/test-loop-stdin.sh
#
# The views phase listed 9 views per site and switched exactly one of them,
# then moved on as if it were finished:
#
#   [list-migrated-views] 9 view(s) to switch.
#   [WARN] switch view 'blog' — FAILED (exit 1)
#   + acli remote:drush ... cr
#
# `acli` reads standard input. Running it inside
#
#   while IFS= read -r view; do ... done <<< "$view_ids"
#
# lets it consume the rest of the here-string, so the next `read` hits EOF and
# the loop exits after the first item. The index phase had the same shape and
# only escaped because the one index it acted on happened to sort last.
#
# Anything that touches the environment must therefore be driven from an array,
# not straight from a redirected `read` loop.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; exit 1; }

# --- demonstrate the failure mode, so the guard below is not superstition -----
swallow() { cat >/dev/null 2>&1 || true; }

count=0
while IFS= read -r _item; do
    count=$((count + 1))
    swallow
done <<< "$(printf 'a\nb\nc\n')"
(( count == 1 )) || fail "expected the stdin-swallowing loop to stop after one item (got ${count})"

count=0
items=()
while IFS= read -r item; do
    [[ -n "$item" ]] && items+=("$item")
done <<< "$(printf 'a\nb\nc\n')"
# The array form leaves the loop's stdin alone, so the swallower can no longer
# eat the item list.
for _item in "${items[@]}"; do
    count=$((count + 1))
    swallow
done < /dev/null
(( count == 3 )) || fail "the array form should process every item (got ${count})"
echo "  a command that reads stdin truncates a redirected read loop OK"

# --- no phase may call out to the environment from such a loop ---------------
offenders="$(awk '
    /while[[:space:]].*[[:space:]]read[[:space:]]/ { inloop = 1; body = ""; start = NR }
    inloop { body = body "\n" $0 }
    inloop && /^[[:space:]]*done[[:space:]]*(<<<|<[[:space:]]*<\()/ {
        if (body ~ /(^|\n)[[:space:]]*(site_step|drush|drush_php|drush_php_soft|drush_cr|acli|composer_in_repo)[[:space:]]/) {
            print "    srsx-migrate:" start
        }
        inloop = 0
    }
' srsx-migrate)"

if [[ -n "$offenders" ]]; then
    echo "FAIL: a loop fed by a redirect runs a command that reads stdin:"
    printf '%s\n' "$offenders"
    echo "  → collect the items into an array first, then iterate the array."
    exit 1
fi
echo "  no phase drives environment commands from a redirected read loop OK"

# --- and the demo must switch every view it was told about -------------------
export SRSX_DEMO_HOME=/tmp/srsx-demo-home-loop
rm -rf "$SRSX_DEMO_HOME"
LOG=/tmp/srsx-loop.log
DEMO_ANSWERS="demoapp,dev,n,,main,https://h.searchstax.com/29847/core1/update,rt,wt,,1" \
    ./srsx-migrate --demo all </dev/null >"$LOG" 2>&1 \
    || { echo "FAIL: demo run exited non-zero"; tail -30 "$LOG"; exit 1; }

# Counted as distinct view names: each one is reported again in the per-site
# summary, so raw line counts double.
switched="$(grep -o "switch view '[^']*'" "$LOG" | sort -u | wc -l | tr -d ' ')"
[[ "$switched" == "3" ]] \
    || { echo "FAIL: demo switched ${switched} view(s), expected 3"; grep "switch view" "$LOG"; exit 1; }
echo "  demo switches every listed view OK"

echo "  loop-stdin OK"
