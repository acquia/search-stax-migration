#!/usr/bin/env bash
# tests/test-index-detection.sh
#
# The index phase found nothing on a real migration:
#
#   jq: error (at <stdin>:29): startswith() requires string inputs
#   [WARN] No legacy (non-SearchStax) indexes found. Nothing to clone.
#
# Cause: it filtered `search-api:status` on `.value.server`, but that command
# reports only id/name/complete/indexed/total — CommandHelper::indexStatusCommand
# never returns a server. `search-api:list` (indexListCommand) is the one with
# 'server'. So the filter compared against null, jq errored, and every index was
# silently skipped.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && { echo "--- log ---"; tail -30 "$2"; }; exit 1; }

# --- the phase must read the server from `search-api:list` -------------------
grep -q '_drush_sapi_list() {' srsx-migrate \
    || fail "no _drush_sapi_list helper: the server field only exists in search-api:list"
grep -q 'search-api:list --format=json' srsx-migrate \
    || fail "_drush_sapi_list must call search-api:list"

fn="$(sed -n '/^_phase_index_site()/,/^}/p' srsx-migrate)"
grep -q '_drush_sapi_list' <<<"$fn" \
    || fail "the index phase still does not consult search-api:list"
if grep -q '_drush_sapi_indexes' <<<"$fn"; then
    fail "the index phase reads search-api:status, which has no 'server' field"
fi
# The old filter blew up on a null server; nothing may depend on it again.
if grep -q 'startswith("searchstax")' <<<"$fn"; then
    fail "index phase still matches server names by prefix instead of the server id"
fi
echo "  index phase reads the server from search-api:list OK"

# --- a null/missing server must never abort the filter -----------------------
command -v jq >/dev/null 2>&1 || { echo "  (jq missing — skipping filter check)"; exit 0; }

# Shape returned by search-api:status: no 'server' key at all.
status_json='{"a":{"id":"a","name":"A","complete":"-","indexed":0,"total":0}}'
if printf '%s' "$status_json" | jq -e 'to_entries[] | select(.value.server | startswith("x"))' >/dev/null 2>&1; then
    fail "expected the old filter to be broken against real status output"
fi

# The filter actually used must tolerate a missing or null server.
list_json='{"a":{"id":"a","server":"acquia_search_server"},"b":{"id":"b","server":null},"c":{"id":"c"}}'
got="$(printf '%s' "$list_json" \
    | jq -r --arg new "searchstax_server" \
        'to_entries[] | select((.value.server // "") != $new) | .key' 2>/dev/null | tr '\n' ' ')"
[[ "$got" == "a b c " ]] \
    || { echo "FAIL: legacy filter mishandled a null/missing server (got: '${got}')"; exit 1; }

# And it must exclude indexes already on the SearchStax server.
list_json='{"a":{"server":"acquia_search_server"},"n":{"server":"searchstax_server"}}'
got="$(printf '%s' "$list_json" \
    | jq -r --arg new "searchstax_server" \
        'to_entries[] | select((.value.server // "") != $new) | .key' 2>/dev/null | tr '\n' ' ')"
[[ "$got" == "a " ]] \
    || { echo "FAIL: filter did not exclude indexes already migrated (got: '${got}')"; exit 1; }

echo "  legacy filter tolerates null/missing server OK"

# --- copies are made by the module's own command ------------------------------
grep -q 'drush searchstax:copy-index' srsx-migrate \
    || fail "index phase must use the module's searchstax:copy-index command"
grep -q 'drush searchstax:switch-view-index' srsx-migrate \
    || fail "views phase must use the module's searchstax:switch-view-index command"
# copy-index refuses unless the old server is registered as migrated.
grep -q 'addMigratedServer' lib/php-eval/create-server.php \
    || fail "create-server.php must register the legacy server as migrated, or copy-index refuses"
echo "  module drush commands are used, with the server mapping registered OK"

# --- a demo run must actually reach those commands ----------------------------
export SRSX_DEMO_HOME=/tmp/srsx-demo-home-index
rm -rf "$SRSX_DEMO_HOME"
LOG=/tmp/srsx-index.log
DEMO_ANSWERS="demoapp,dev,n,,main,https://h.searchstax.com/29847/core1/update,rt,wt,,1" \
    ./srsx-migrate --demo all </dev/null >"$LOG" 2>&1 \
    || fail "demo run exited non-zero" "$LOG"

grep -q "searchstax:copy-index" "$LOG"        || fail "copy-index was never invoked" "$LOG"
grep -q "searchstax:switch-view-index" "$LOG" || fail "switch-view-index was never invoked" "$LOG"
grep -q "Nothing to clone" "$LOG"             && fail "indexes were still not detected" "$LOG"

echo "  demo run copies indexes and switches views OK"
echo "  index-detection OK"
