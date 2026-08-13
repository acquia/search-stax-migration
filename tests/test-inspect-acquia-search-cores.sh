#!/usr/bin/env bash
# tests/test-inspect-acquia-search-cores.sh
#
# Executes lib/php-eval/inspect-acquia-search-cores.php against a stubbed
# Drupal container so the three branches that matter are exercised for real:
#
#   1. acquia_search not enabled           -> soft skip, no [srsx-acquia-core] rows
#   2. enabled, no reachable/available cores -> "available NONE" row only
#   3. enabled, cores available, one server matches a preferred core
#      -> "available" row per core + "preferred" row naming the match
#
# The script reports with fwrite(STDOUT), which bypasses ob_start() (see
# tests/test-clone-index.sh), so each case is delimited with a plain `echo`
# marker and asserted with awk over the whole combined output instead of
# per-call output buffering.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

command -v php >/dev/null 2>&1 || { echo "  (php missing — skipping inspect-acquia-search-cores test)"; exit 0; }

harness="$(mktemp -t srsx-acquia-cores-XXXXXX.php)"
work="$(mktemp -d)"
trap 'rm -f "$harness"; rm -rf "$work"' EXIT

cat > "$harness" <<'PHP'
<?php

namespace Drupal\acquia_search\Plugin\search_api\backend {
  class AcquiaSearchSolrBackend {
    public function __construct(private array $possibleCores, private bool $available) {}
    public function isPreferredCoreAvailable(): bool { return $this->available; }
    public function getListOfPossibleCores(): array { return $this->possibleCores; }
  }
}

namespace {

use Drupal\acquia_search\Plugin\search_api\backend\AcquiaSearchSolrBackend;

class FakeServer {
  public function __construct(private string $id, private $backend) {}
  public function id() { return $this->id; }
  public function getBackend() { return $this->backend; }
}

class FakeStorage {
  public function __construct(private array $entities) {}
  public function loadMultiple() { return $this->entities; }
}

class FakeEtm {
  public function __construct(private array $storages) {}
  public function getStorage($type) { return $this->storages[$type]; }
}

class FakeModuleHandler {
  public function __construct(private bool $enabled) {}
  public function moduleExists($name) { return $this->enabled; }
}

class FakeApiClient {
  public function __construct(private $cores) {}
  public function getSearchIndexes() { return $this->cores; }
}

class Drupal {
  public static FakeEtm $etm;
  public static FakeModuleHandler $moduleHandler;
  public static array $services = [];
  public static function moduleHandler() { return static::$moduleHandler; }
  public static function entityTypeManager() { return static::$etm; }
  public static function hasService($id): bool { return isset(static::$services[$id]); }
  public static function service($id) { return static::$services[$id]; }
}

function srsx_run(): void {
  $rc = (function () {
    return include __DIR__ . '/SCRIPT';
  })();
  if ($rc !== 0) {
    fwrite(STDERR, "inspect-acquia-search-cores returned {$rc}\n");
    exit(1);
  }
}

// 1. Module not enabled: soft skip, no machine rows.
echo "=== CASE 1 ===\n";
Drupal::$moduleHandler = new FakeModuleHandler(false);
Drupal::$services = [];
srsx_run();

// 2. Module enabled, no cores reachable.
echo "=== CASE 2 ===\n";
Drupal::$moduleHandler = new FakeModuleHandler(true);
Drupal::$services = ['acquia_search.api_client' => new FakeApiClient(FALSE)];
Drupal::$etm = new FakeEtm(['search_api_server' => new FakeStorage([])]);
srsx_run();

// 3. Module enabled, cores available, one server matches.
echo "=== CASE 3 ===\n";
$cores = [
  'WXYZ-12345.dev.mysitedev' => ['balancer' => 'useast1.acquia-search.com', 'core_id' => 'WXYZ-12345.dev.mysitedev'],
  'WXYZ-12345.dev.othersite' => ['balancer' => 'useast1.acquia-search.com', 'core_id' => 'WXYZ-12345.dev.othersite'],
];
Drupal::$services = ['acquia_search.api_client' => new FakeApiClient($cores)];
$matchingBackend = new AcquiaSearchSolrBackend(['WXYZ-12345.dev.mysitedev'], true);
$noMatchBackend = new AcquiaSearchSolrBackend([], false);
Drupal::$etm = new FakeEtm([
  'search_api_server' => new FakeStorage([
    'acquia_search_server' => new FakeServer('acquia_search_server', $matchingBackend),
    'other_server' => new FakeServer('other_server', $noMatchBackend),
  ]),
]);
srsx_run();

echo "=== END ===\n";

}
PHP

sed "s#__DIR__ . '/SCRIPT'#'$PWD/lib/php-eval/inspect-acquia-search-cores.php'#" "$harness" > "$work/run.php"
out="$(php "$work/run.php")"

case1="$(awk '/=== CASE 1 ===/,/=== CASE 2 ===/' <<<"$out")"
case2="$(awk '/=== CASE 2 ===/,/=== CASE 3 ===/' <<<"$out")"
case3="$(awk '/=== CASE 3 ===/,/=== END ===/' <<<"$out")"

grep -q 'acquia_search not enabled' <<<"$case1" \
    || { echo "FAIL: no skip message when module is disabled"; exit 1; }
grep -q '\[srsx-acquia-core\]' <<<"$case1" \
    && { echo "FAIL: machine rows emitted while module is disabled"; exit 1; }
echo "  reports skip + no machine rows when module is disabled OK"

grep -qF $'[srsx-acquia-core]\tavailable\tNONE\t' <<<"$case2" \
    || { echo "FAIL: no NONE row when no cores are reachable"; exit 1; }
echo "  reports NONE when no cores are reachable OK"

grep -qF $'[srsx-acquia-core]\tavailable\tWXYZ-12345.dev.mysitedev\tuseast1.acquia-search.com' <<<"$case3" \
    && grep -qF $'[srsx-acquia-core]\tavailable\tWXYZ-12345.dev.othersite\tuseast1.acquia-search.com' <<<"$case3" \
    || { echo "FAIL: did not list every available core"; exit 1; }
echo "  lists every available core in the subscription OK"

grep -qF $'[srsx-acquia-core]\tpreferred\tacquia_search_server\tWXYZ-12345.dev.mysitedev' <<<"$case3" \
    || { echo "FAIL: did not name the preferred core for the matching server"; exit 1; }
echo "  names the preferred core for the matching server OK"

grep -qF $'[srsx-acquia-core]\tpreferred\tother_server\t' <<<"$case3" \
    || { echo "FAIL: did not report an empty preferred core for a non-matching server"; exit 1; }
echo "  reports an empty preferred core for a server with no match OK"

echo "  inspect-acquia-search-cores OK"
