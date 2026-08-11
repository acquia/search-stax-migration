#!/usr/bin/env bash
# tests/test-index-detection.sh
#
# Two regressions guard this phase.
#
# 1. It once filtered `search-api:status` on `.value.server`, but that command
#    reports only id/name/complete/indexed/total — CommandHelper::indexStatusCommand
#    never returns a server. `search-api:list` (indexListCommand) is the one with
#    'server'. So the filter compared against null, jq errored, and every index
#    was silently skipped.
#
# 2. It then copied indexes with `drush searchstax:copy-index`, which only
#    exists from searchstax 1.12.0 and, even there, refuses any index whose
#    current server is not registered in the module's migrated_servers map:
#
#      There are no commands defined in the "searchstax" namespace.
#      Migration is not supported for this index.
#
#    The copy now goes through lib/php-eval/clone-index.php, which calls
#    MigrationHelper::createIndexCopy() — the single implementation behind both
#    that command and the module's "Create copy" button.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && { echo "--- log ---"; tail -30 "$2"; }; exit 1; }

# --- classification must NOT come from `search-api:list` ---------------------
# Its default field set is id,name,serverName,typeNames,status,limit: `server`
# (the machine-readable server ID) is omitted and `serverName` is a human label,
# so every index came back looking as if it had no server.
grep -q 'fields=id,name,server,serverName,status' srsx-migrate \
    || fail "_drush_sapi_list must ask for the 'server' field explicitly"

fn="$(sed -n '/^_phase_index_copy()/,/^}/p' srsx-migrate)"
[[ -n "$fn" ]] || fail "no _phase_index_copy function in srsx-migrate"
grep -q 'inspect-index-topology.php' <<<"$fn" \
    || fail "the index phase must classify from inspect-index-topology.php"
if grep -qE '_drush_sapi_(list|indexes)' <<<"$fn"; then
    fail "the index phase still classifies from drush output instead of the entity API"
fi
site_fn="$(sed -n '/^_phase_index_site()/,/^}/p' srsx-migrate)"
if grep -qE '_drush_sapi_(list|indexes)' <<<"$site_fn"; then
    fail "the post-copy check still reads drush output instead of the entity API"
fi
# The old filter blew up on a null server; nothing may depend on it again.
if grep -q 'startswith("searchstax")' <<<"$fn"; then
    fail "index phase still matches server names by prefix instead of the server id"
fi
echo "  index phase classifies from the entity API, not search-api:list OK"

# --- a missing or misconfigured target server must stop the site -------------
grep -q '_phase_index_check_target' srsx-migrate \
    || fail "index phase must verify the target server before copying"
for state in missing not-solr wrong-connector; do
    grep -q "$state" srsx-migrate \
        || fail "index phase does not handle a '${state}' target server"
    grep -q "$state" lib/php-eval/inspect-index-topology.php \
        || fail "topology script never reports a '${state}' target server"
done
echo "  a missing or non-SearchStax target server fails the site OK"

# --- copies go through the module's service, not its drush command ------------
# Comment lines are stripped: the code explains why those commands are avoided.
code="$(grep -vE '^[[:space:]]*#' srsx-migrate)"
if grep -q 'drush searchstax:copy-index' <<<"$code"; then
    fail "index phase still calls searchstax:copy-index (missing before module 1.12.0)"
fi
if grep -q 'drush searchstax:switch-view-index' <<<"$code"; then
    fail "views phase still calls searchstax:switch-view-index (missing before module 1.12.0)"
fi
grep -qE 'drush_php(_soft)? clone-index\.php' srsx-migrate \
    || fail "index phase must copy via drush_php clone-index.php"
grep -qE 'drush_php(_soft)? switch-view-index\.php' srsx-migrate \
    || fail "views phase must switch via drush_php switch-view-index.php"
grep -q 'createIndexCopy' lib/php-eval/clone-index.php \
    || fail "clone-index.php must call MigrationHelper::createIndexCopy()"
grep -q 'switchViewToNewIndex' lib/php-eval/switch-view-index.php \
    || fail "switch-view-index.php must call MigrationHelper::switchViewToNewIndex()"
# cloneIndex() does not exist on any searchstax release; it was a phantom API.
if grep -q 'cloneIndex' lib/php-eval/clone-index.php; then
    fail "clone-index.php calls UtilityService::cloneIndex(), which does not exist"
fi
# Copies are named searchstax_index…, never <original>_searchstax, so the view
# switch must read the module's recorded mapping instead of guessing names.
grep -q 'getCopiedIndexes' lib/php-eval/switch-view-index.php \
    || fail "switch-view-index.php must resolve the new index from getCopiedIndexes()"
if grep -qF "=== '_searchstax'" lib/php-eval/switch-view-index.php; then
    fail "switch-view-index.php still guesses '<original>_searchstax' index names"
fi
grep -q 'getCopiedIndexes' lib/php-eval/clone-index.php \
    || fail "clone-index.php must skip an index that was already copied"
echo "  copies use the module's own service, and are idempotent OK"

# --- the server mapping still gets registered for the module UI --------------
grep -q 'addMigratedServer' lib/php-eval/create-server.php \
    || fail "create-server.php must register the legacy server as migrated"
echo "  legacy server is registered as migrated OK"

# --- the tab-separated topology rows must parse portably ---------------------
# BSD sed does not read \t as a tab in a regex, so the parsing uses awk.
topology="$(printf '[topology] noise\n[srsx-target]\tok\tsearchstax_server\tsearchstax\n[srsx-index]\tlegacy\tpublic_content_types\tacquia_search_server\tacquia_search_solr\n[srsx-index]\tother\tblog_articles\tdatabase_server\tsearch_api_db\n[srsx-index]\tdetached\tacquia_search_index\t\t\n[srsx-index]\ttarget\tsearchstax_index\tsearchstax_server\tsearch_api_solr\n')"

got="$(awk -F'\t' -v OFS=':' '$1=="[srsx-index]"{print $2,$3}' <<<"$topology" | tr '\n' ' ')"
[[ "$got" == "legacy:public_content_types other:blog_articles detached:acquia_search_index target:searchstax_index " ]] \
    || fail "topology rows did not parse (got: '${got}')"

got="$(awk -F'\t' '$1=="[srsx-index]" && $2=="target"{print $3}' <<<"$topology")"
[[ "$got" == "searchstax_index" ]] \
    || fail "post-copy check did not find the index on the target server (got: '${got}')"

IFS=$'\t' read -r state _ connector \
    < <(awk -F'\t' -v OFS='\t' '$1=="[srsx-target]"{print $2,$3,$4}' <<<"$topology") || true
[[ "$state" == "ok" && "$connector" == "searchstax" ]] \
    || fail "target-server verdict did not parse (state='${state}' connector='${connector}')"

# No target line at all must not wedge the parser.
state="" connector=""
IFS=$'\t' read -r state _ connector \
    < <(awk -F'\t' -v OFS='\t' '$1=="[srsx-target]"{print $2,$3,$4}' <<<"nothing here") || true
[[ -z "$state" ]] || fail "a missing target line should leave the state empty (got: '${state}')"
echo "  topology rows parse portably, including a missing target line OK"

# --- a demo run must actually reach the copy path ----------------------------
export SRSX_DEMO_HOME=/tmp/srsx-demo-home-index
rm -rf "$SRSX_DEMO_HOME"
LOG=/tmp/srsx-index.log
DEMO_ANSWERS="demoapp,dev,n,,main,https://h.searchstax.com/29847/core1/update,rt,wt,,1" \
    ./srsx-migrate --demo all </dev/null >"$LOG" 2>&1 \
    || fail "demo run exited non-zero" "$LOG"

grep -q 'clone-index' "$LOG"       || fail "clone-index was never invoked" "$LOG"
grep -q 'switch-view-index' "$LOG" || fail "switch-view-index was never invoked" "$LOG"
grep -q 'Nothing to clone' "$LOG"  && fail "indexes were still not detected" "$LOG"
grep -q 'no commands defined' "$LOG" \
    && fail "a searchstax:* drush command was still called" "$LOG"

# The demo must exercise the real classification, not just print audit lines.
grep -q '\[legacy\]' "$LOG" \
    || fail "demo run never classified an index — the copy path was skipped" "$LOG"
echo "  demo run copies indexes and switches views OK"

# A demo run must not leave state behind in the repo's fixtures dir.
[[ -e lib/demo/fixtures/.state-after-clone ]] \
    && fail "demo run wrote .state-after-clone into the repo fixtures dir"

echo "  index-detection OK"
