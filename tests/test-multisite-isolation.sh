#!/usr/bin/env bash
# tests/test-multisite-isolation.sh
#
# Covers the three per-site isolation settings the index/server phases apply,
# and specifically the distinctions the PR description and docs claim exist:
#
#   A) _srsx_multisite_active   — true for ANY multisite site (index_prefix,
#      site_hash), false single-site.
#   B) _srsx_index_directly_off — true for EVERY migrated index regardless of
#      site count or app topology, because per-save indexing pushes customers
#      over their SearchStax entitlement. SRSX_KEEP_INDEX_DIRECTLY=1 overrides.
#   C) _ssx_resolve_site_prefix — short first-label prefixes are readable but
#      not unique (dmv.dev-nhdoit… and dmv.nhdoit…, www.example.com and
#      example.org). A shared prefix silently re-merges what the prefix exists
#      to separate, so any collision demotes EVERY site to a full-host prefix.
#   D) set-multisite-prefix.php writes index_prefix where search_api_solr reads
#      it (third_party_settings.search_api_solr.advanced) and clears the dead
#      key earlier releases left in the options bag.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; exit 1; }
eq() { [[ "$2" == "$3" ]] || fail "$1: expected '$3', got '$2'"; echo "  $1 OK"; }
is_true()  { "$@" || fail "expected true: $*"; }
is_false() { ! "$@" || fail "expected false: $*"; }

# srsx-migrate ends in `main "$@"`, so lift just the topology/prefix helpers.
helpers="$(mktemp -t srsx-helpers-XXXXXX.sh)"
trap 'rm -f "$helpers"' EXIT
awk '/^_site_app_index\(\) \{/{f=1}
     /^# Decompose a SearchStax Solr endpoint/{f=0}
     f' srsx-migrate > "$helpers"
for fn in _site_app_index _sites_for_app _ssx_site_prefix _ssx_site_prefix_full \
          _ssx_site_prefixes_collide _ssx_resolve_site_prefix \
          _srsx_multisite_active _srsx_index_directly_off; do
  grep -q "^${fn}() {" "$helpers" || fail "helper extraction missed ${fn}()"
done

declare -a SITES_ARR=()
DRUSH_URI=""
SITE_APP_MAP=""
# shellcheck source=/dev/null
source "$helpers"

# ---------------------------------------------------------------------------
# A — multisite gate
# ---------------------------------------------------------------------------
SITES_ARR=(); DRUSH_URI=""
is_false _srsx_multisite_active
echo "  single-site run is not multisite OK"

SITES_ARR=("https://a.example.com" "https://b.example.com")
DRUSH_URI="https://a.example.com"
is_true _srsx_multisite_active
echo "  multisite run with an active --uri is multisite OK"

# ---------------------------------------------------------------------------
# B — index_directly. Off for every migrated index: the driver is the customer's
#     SearchStax entitlement, not app topology, so single-site and 1:1 runs get
#     it too.
# ---------------------------------------------------------------------------
SITES_ARR=(); DRUSH_URI=""; SITE_APP_MAP=""
is_true _srsx_index_directly_off
echo "  single-site run still turns index_directly off OK"

SITES_ARR=("https://a.example.com" "https://b.example.com" "https://c.example.com")
SITE_APP_MAP="https://a.example.com=1,https://b.example.com=2,https://c.example.com=3"
for u in "${SITES_ARR[@]}"; do
  DRUSH_URI="$u"
  is_true _srsx_index_directly_off
done
echo "  1:1 site-to-app topology turns index_directly off OK"

SITE_APP_MAP="https://a.example.com=1,https://b.example.com=1,https://c.example.com=2"
DRUSH_URI="https://a.example.com"
is_true _srsx_index_directly_off
# An assignment prefix on a function call persists in bash, so set and unset.
SRSX_KEEP_INDEX_DIRECTLY=1
is_false _srsx_index_directly_off
unset SRSX_KEEP_INDEX_DIRECTLY
echo "  SRSX_KEEP_INDEX_DIRECTLY=1 is the only way to keep it on OK"

SITES_ARR=(); DRUSH_URI=""; SITE_APP_MAP=""

# ---------------------------------------------------------------------------
# C — prefix derivation and collision fallback
# ---------------------------------------------------------------------------
eq "first hostname label wins" \
   "$(_ssx_site_prefix 'https://dmv.dev-nhdoit.acsitefactory.com')" 'dmv_'
eq "a leading www label is skipped" \
   "$(_ssx_site_prefix 'https://www.example.com')" 'example_'
eq "non-slug characters are folded" \
   "$(_ssx_site_prefix 'https://dev-nhdoit.example.com/subdir')" 'dev_nhdoit_'

SITES_ARR=("https://a.example.com" "https://b.example.com")
is_false _ssx_site_prefixes_collide
eq "distinct labels keep the short prefix" \
   "$(_ssx_resolve_site_prefix 'https://a.example.com')" 'a_'

# Same label under two different domains — the case the short form broke on.
SITES_ARR=("https://dmv.dev-nhdoit.acsitefactory.com" "https://dmv.nhdoit.acsitefactory.com")
is_true _ssx_site_prefixes_collide
p1="$(_ssx_resolve_site_prefix "${SITES_ARR[0]}")"
p2="$(_ssx_resolve_site_prefix "${SITES_ARR[1]}")"
[[ "$p1" != "$p2" ]] || fail "colliding sites resolved to the same prefix '$p1'"
eq "collision falls back to the full host" "$p1" 'dmv_dev_nhdoit_acsitefactory_com_'

# www-stripping can collide across TLDs too.
SITES_ARR=("https://www.example.com" "https://example.org")
is_true _ssx_site_prefixes_collide
p1="$(_ssx_resolve_site_prefix "${SITES_ARR[0]}")"
p2="$(_ssx_resolve_site_prefix "${SITES_ARR[1]}")"
[[ "$p1" != "$p2" ]] || fail "www/TLD collision resolved to the same prefix '$p1'"
echo "  www.example.com and example.org get distinct prefixes OK"

# ---------------------------------------------------------------------------
# D — set-multisite-prefix.php writes where search_api_solr actually reads
# ---------------------------------------------------------------------------
if ! command -v php >/dev/null 2>&1; then
  echo "  (php missing — skipping set-multisite-prefix test)"
  echo "  multisite isolation OK"
  exit 0
fi

harness="$(mktemp -t srsx-prefix-XXXXXX.php)"
work="$(mktemp -d)"
trap 'rm -f "$helpers" "$harness"; rm -rf "$work"' EXIT

cat > "$harness" <<'PHP'
<?php

class FakeIndex {
  public bool $saved = FALSE;
  public function __construct(
    public string $id,
    public string $server,
    public array $options = [],
    public array $tps = [],
  ) {}
  public function id(): string { return $this->id; }
  public function getServerId(): string { return $this->server; }
  public function getOptions(): array { return $this->options; }
  public function setOptions(array $o): void { $this->options = $o; }
  public function getThirdPartySetting($m, $k) { return $this->tps[$m][$k] ?? NULL; }
  public function setThirdPartySetting($m, $k, $v): void { $this->tps[$m][$k] = $v; }
  public function save(): void { $this->saved = TRUE; }
}

class FakeStorage {
  public function __construct(private array $entities) {}
  public function loadMultiple() { return $this->entities; }
}

class FakeEtm {
  public function __construct(private array $storages) {}
  public function getStorage($type) { return $this->storages[$type]; }
}

class Drupal {
  public static FakeEtm $etm;
  public static function entityTypeManager() { return static::$etm; }
}

function srsx_assert(bool $cond, string $what): void {
  if (!$cond) {
    fwrite(STDERR, "FAIL: {$what}\n");
    exit(1);
  }
  echo "  {$what} OK\n";
}

// One target index carrying both the dead options key and a sibling advanced
// key that must survive, plus an index on another server that must be skipped.
$target = new FakeIndex(
  'searchstax_index',
  'searchstax_server',
  ['index_prefix' => 'stale_', 'cron_limit' => 50],
  ['search_api_solr' => ['advanced' => ['collection' => 'c1']]],
);
$other = new FakeIndex('acquia_search_index', 'acquia_search_server');

Drupal::$etm = new FakeEtm([
  'search_api_index' => new FakeStorage([
    'searchstax_index' => $target,
    'acquia_search_index' => $other,
  ]),
]);

putenv('SRSX_PREFIX=dmv_');
putenv('SRSX_SERVER_ID=searchstax_server');

$rc = (function () {
  return include __DIR__ . '/SCRIPT';
})();
srsx_assert($rc === 0, 'set-multisite-prefix returns 0');

srsx_assert($target->tps['search_api_solr']['advanced']['index_prefix'] === 'dmv_',
  'prefix lands in third_party_settings.search_api_solr.advanced');
srsx_assert($target->tps['search_api_solr']['advanced']['collection'] === 'c1',
  'sibling advanced keys survive the merge');
srsx_assert(!array_key_exists('index_prefix', $target->options),
  'the dead options-bag index_prefix is cleared');
srsx_assert($target->options['cron_limit'] === 50,
  'other options are untouched');
srsx_assert($target->saved === TRUE, 'the target index is saved');
srsx_assert($other->saved === FALSE && $other->tps === [],
  'an index on another server is left alone');
PHP

sed "s#__DIR__ . '/SCRIPT'#'$PWD/lib/php-eval/set-multisite-prefix.php'#" \
    "$harness" > "$work/run.php"
out="$(php "$work/run.php")"
printf '%s\n' "$out" | sed -n 's/^  /  /p'
grep -q "^\[set-multisite-prefix\] searchstax_index prefix='dmv_'$" <<<"$out" \
    || fail "no per-index report line"
grep -q '^\[set-multisite-prefix\] Updated 1 index(es).$' <<<"$out" \
    || fail "the summary counted the wrong number of indexes"

echo "  multisite isolation OK"
