#!/usr/bin/env bash
# tests/test-clone-index.sh
#
# Executes lib/php-eval/clone-index.php against a stubbed Drupal container, so
# the three branches that matter are exercised for real rather than grepped:
#
#   1. the module is present  → MigrationHelper::createIndexCopy() is called
#   2. the index was copied before → SKIP, nothing is created a second time
#      (neither the module's form nor its drush command checks this, which is
#      how a re-run used to mint searchstax_index_2, _3, …)
#   3. the submodule is missing → hand-rolled copy with the same field surgery
#   4. SRSX_INDEX_DIRECTLY_OFF=1 turns "Index items immediately" off on the
#      copy, on both the module path and the fallback, and is a no-op otherwise
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

command -v php >/dev/null 2>&1 || { echo "  (php missing — skipping clone-index test)"; exit 0; }

harness="$(mktemp -t srsx-clone-index-XXXXXX.php)"
trap 'rm -f "$harness"' EXIT

cat > "$harness" <<'PHP'
<?php

class FakeIndex {
  public array $options = [];
  public function __construct(public string $id, public array $values = []) {}
  public function id(): string { return $this->id; }
  public function label(): string { return 'Legacy ' . $this->id; }
  public function toArray(): array { return $this->values + ['id' => $this->id]; }
  public function getOptions(): array { return $this->options; }
  public function setOptions(array $options): void { $this->options = $options; }
  public function save(): void { FakeStorage::$saved[] = $this->values; }
}

class FakeStorage {
  public static array $saved = [];
  public function __construct(private array $entities) {}
  public function load($id) { return $this->entities[$id] ?? NULL; }
  public function create(array $values) {
    $index = new FakeIndex($values['id'], $values);
    return $index;
  }
}

class FakeUtility {
  public array $copied = [];
  public array $added = [];
  public function getCopiedIndexes(): array { return $this->copied; }
  public function addCopiedIndex($from, $to): void { $this->added[$from] = $to; }
}

class FakeHelper {
  public array $calls = [];
  public ?FakeIndex $last = NULL;
  public function createIndexCopy($index, $serverId) {
    $this->calls[] = [$index->id(), $serverId];
    $this->last = new FakeIndex('searchstax_index');
    return $this->last;
  }
}

class FakeEtm {
  public function __construct(private array $storages) {}
  public function getStorage($type) { return $this->storages[$type]; }
}

class Drupal {
  public static FakeEtm $etm;
  public static array $services = [];
  public static function entityTypeManager() { return static::$etm; }
  public static function hasService($id): bool { return isset(static::$services[$id]); }
  public static function service($id) { return static::$services[$id]; }
}

function srsx_setup(array $copied, bool $withHelper, array $existing = []): array {
  FakeStorage::$saved = [];
  $legacy = new FakeIndex('acquia_search_index', [
    'uuid' => 'x',
    'dependencies' => ['module' => ['acquia_search']],
    'third_party_settings' => ['acquia_search' => ['a' => 1], 'other' => ['b' => 2]],
    '_core' => ['default_config_hash' => 'h'],
    'server' => 'acquia_search_server',
  ]);
  $indexes = ['acquia_search_index' => $legacy] + $existing;
  Drupal::$etm = new FakeEtm([
    'search_api_index' => new FakeStorage($indexes),
    'search_api_server' => new FakeStorage(['searchstax_server' => new FakeIndex('searchstax_server')]),
  ]);
  $utility = new FakeUtility();
  $utility->copied = $copied;
  $helper = new FakeHelper();
  Drupal::$services = ['solr_to_searchstax_ss_migration.utility' => $utility];
  if ($withHelper) {
    Drupal::$services['solr_to_searchstax_ss_migration.migration_helper'] = $helper;
  }
  return [$utility, $helper];
}

function srsx_run(): void {
  // The script reports with fwrite(STDOUT), which no output buffer can capture,
  // so its printed lines are asserted by the caller instead.
  $rc = (function () {
    return include __DIR__ . '/SCRIPT';
  })();
  if ($rc !== 0) {
    fwrite(STDERR, "clone-index returned {$rc}\n");
    exit(1);
  }
}

function srsx_assert(bool $cond, string $what): void {
  if (!$cond) {
    fwrite(STDERR, "FAIL: {$what}\n");
    exit(1);
  }
  echo "  {$what} OK\n";
}

putenv('SRSX_INDEX_ID=acquia_search_index');
putenv('SRSX_NEW_SERVER_ID=searchstax_server');
putenv('SRSX_INDEX_DIRECTLY_OFF=0');

// 1. Module present, nothing copied yet.
[$utility, $helper] = srsx_setup([], TRUE);
srsx_run();
srsx_assert($helper->calls === [['acquia_search_index', 'searchstax_server']],
  'copy goes through MigrationHelper::createIndexCopy()');
srsx_assert($helper->last->options === [],
  'index_directly is left alone unless asked for');

// 2. Already copied: must not copy again.
[$utility, $helper] = srsx_setup(
  ['acquia_search_index' => 'searchstax_index'],
  TRUE,
  ['searchstax_index' => new FakeIndex('searchstax_index')]
);
srsx_run();
srsx_assert($helper->calls === [], 're-running does not create a second copy');

// 3. Submodule missing: hand-rolled copy with the same field surgery.
[$utility, $helper] = srsx_setup([], FALSE);
srsx_run();
srsx_assert(count(FakeStorage::$saved) === 1, 'fallback saves exactly one new index');
$values = FakeStorage::$saved[0];
srsx_assert(!isset($values['uuid'], $values['dependencies'], $values['_core']),
  'fallback strips uuid, dependencies and _core');
srsx_assert(!isset($values['third_party_settings']['acquia_search'])
  && isset($values['third_party_settings']['other']),
  'fallback strips only the acquia_search third-party settings');
srsx_assert($values['id'] === 'searchstax_index' && $values['server'] === 'searchstax_server',
  'fallback names the copy searchstax_index on the SearchStax server');
srsx_assert($utility->added === ['acquia_search_index' => 'searchstax_index'],
  'fallback still records the copy the views phase reads');
srsx_assert(!isset($values['options']['index_directly']),
  'fallback leaves index_directly alone unless asked for');

// 4. SRSX_INDEX_DIRECTLY_OFF=1 on both paths.
putenv('SRSX_INDEX_DIRECTLY_OFF=1');
[$utility, $helper] = srsx_setup([], TRUE);
srsx_run();
srsx_assert($helper->last->options['index_directly'] === FALSE,
  'module path turns index_directly off when asked');

[$utility, $helper] = srsx_setup([], FALSE);
srsx_run();
srsx_assert(FakeStorage::$saved[0]['options']['index_directly'] === FALSE,
  'fallback turns index_directly off when asked');
putenv('SRSX_INDEX_DIRECTLY_OFF=0');

echo "  clone-index OK\n";
PHP

# The harness includes the script by a fixed name next to itself.
work="$(mktemp -d)"
trap 'rm -f "$harness"; rm -rf "$work"' EXIT
sed "s#__DIR__ . '/SCRIPT'#'$PWD/lib/php-eval/clone-index.php'#" "$harness" > "$work/run.php"
out="$(php "$work/run.php")"
printf '%s\n' "$out" | sed -n 's/^  /  /p'

grep -q '^\[clone-index\] OK acquia_search_index -> searchstax_index$' <<<"$out" \
    || { echo "FAIL: no OK line for the first copy"; exit 1; }
grep -q '^\[clone-index\] SKIP acquia_search_index -> searchstax_index (already copied)$' <<<"$out" \
    || { echo "FAIL: a repeat run did not report SKIP"; exit 1; }
grep -q '^\[clone-index\] OK (fallback) acquia_search_index -> searchstax_index$' <<<"$out" \
    || { echo "FAIL: no OK line from the no-module fallback"; exit 1; }
echo "  reported lines name the old -> new mapping OK"
