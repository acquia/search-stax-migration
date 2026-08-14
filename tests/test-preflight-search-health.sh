#!/usr/bin/env bash
# tests/test-preflight-search-health.sh
#
# Executes lib/php-eval/preflight-search-health.php against a stubbed Drupal
# container. Every state the pre-check has to distinguish is pinned here, since
# a wrong verdict either blocks a healthy migration or lets a broken one run on
# to fail in a later phase:
#
#   1. search_api not installed / no servers   -> no-servers
#   2. Acquia Search resolves no core          -> no-url  (host stays localhost)
#   3. URL resolves but the core does not ping -> unreachable
#   4. reachable but no index attached         -> no-indexes
#   5. reachable with an index                 -> ok
#   6. database backend                        -> not-solr (reported, not a problem)
#
# The script reports with fwrite(STDOUT), which bypasses ob_start() (see
# tests/test-clone-index.sh), so cases are delimited with echo markers and
# sliced out of the combined process output with awk.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

command -v php >/dev/null 2>&1 || { echo "  (php missing — skipping preflight-search-health test)"; exit 0; }

harness="$(mktemp -t srsx-search-health-XXXXXX.php)"
work="$(mktemp -d)"
trap 'rm -f "$harness"; rm -rf "$work"' EXIT

cat > "$harness" <<'PHP'
<?php

class FakeConnector {
  public function __construct(private array $config, private bool $ping) {}
  public function getConfiguration(): array { return $this->config; }
  public function pingCore() { return $this->ping; }
}

class FakeSolrBackend {
  public function __construct(private FakeConnector $connector) {}
  public function getSolrConnector() { return $this->connector; }
}

class FakeDbBackend {}

class FakeServer {
  public function __construct(
    private string $id,
    private $backend,
    private int $indexes,
    private string $backendId
  ) {}
  public function id() { return $this->id; }
  public function status() { return TRUE; }
  public function getBackend() { return $this->backend; }
  public function getBackendId() { return $this->backendId; }
  public function getIndexes(array $properties = []) { return array_fill(0, $this->indexes, 'idx'); }
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

class Drupal {
  public static FakeEtm $etm;
  public static FakeModuleHandler $moduleHandler;
  public static function moduleHandler() { return static::$moduleHandler; }
  public static function entityTypeManager() { return static::$etm; }
}

function srsx_servers(array $servers): void {
  Drupal::$etm = new FakeEtm(['search_api_server' => new FakeStorage($servers)]);
}

function srsx_run(): void {
  $rc = (function () {
    return include __DIR__ . '/SCRIPT';
  })();
  if ($rc !== 0) {
    fwrite(STDERR, "preflight-search-health returned {$rc}\n");
    exit(1);
  }
}

$healthy = ['scheme' => 'https', 'host' => 'useast1.acquia-search.com', 'port' => '443', 'path' => 'solr', 'core' => 'WXYZ-12345.dev.mysitedev'];
// An Acquia Search subscription that resolves nothing leaves exactly this.
$unresolved = ['scheme' => 'https', 'host' => 'localhost', 'port' => '443', 'path' => 'solr', 'core' => NULL];

echo "=== CASE 1 ===\n";
Drupal::$moduleHandler = new FakeModuleHandler(false);
srsx_servers([]);
srsx_run();

echo "=== CASE 2 ===\n";
Drupal::$moduleHandler = new FakeModuleHandler(true);
srsx_servers(['acquia_search_server' => new FakeServer(
  'acquia_search_server', new FakeSolrBackend(new FakeConnector($unresolved, true)), 1, 'acquia_search_solr')]);
srsx_run();

echo "=== CASE 3 ===\n";
srsx_servers(['acquia_search_server' => new FakeServer(
  'acquia_search_server', new FakeSolrBackend(new FakeConnector($healthy, false)), 1, 'acquia_search_solr')]);
srsx_run();

echo "=== CASE 4 ===\n";
srsx_servers(['acquia_search_server' => new FakeServer(
  'acquia_search_server', new FakeSolrBackend(new FakeConnector($healthy, true)), 0, 'acquia_search_solr')]);
srsx_run();

echo "=== CASE 5 ===\n";
srsx_servers([
  'acquia_search_server' => new FakeServer(
    'acquia_search_server', new FakeSolrBackend(new FakeConnector($healthy, true)), 2, 'acquia_search_solr'),
  'database_server' => new FakeServer('database_server', new FakeDbBackend(), 3, 'search_api_db'),
]);
srsx_run();

echo "=== END ===\n";
PHP

sed "s#__DIR__ . '/SCRIPT'#'$PWD/lib/php-eval/preflight-search-health.php'#" "$harness" > "$work/run.php"
out="$(php "$work/run.php")"

slice() { awk "/=== $1 ===/,/=== $2 ===/" <<<"$out"; }

grep -qF $'[srsx-health]\tno-servers\t(none)\t\t0' <<<"$(slice 'CASE 1' 'CASE 2')" \
    || { echo "FAIL: search_api absent did not report no-servers"; exit 1; }
echo "  reports no-servers when search_api is not installed OK"

grep -qF $'[srsx-health]\tno-url\tacquia_search_server\t\t1' <<<"$(slice 'CASE 2' 'CASE 3')" \
    || { echo "FAIL: an unresolved Acquia core did not report no-url"; exit 1; }
echo "  reports no-url when Acquia Search resolves no core OK"

grep -qF $'[srsx-health]\tunreachable\tacquia_search_server\thttps://useast1.acquia-search.com:443/solr/WXYZ-12345.dev.mysitedev\t1' <<<"$(slice 'CASE 3' 'CASE 4')" \
    || { echo "FAIL: a non-pinging core did not report unreachable with its URL"; exit 1; }
echo "  reports unreachable, naming the server URL, when the core does not ping OK"

grep -qF $'[srsx-health]\tno-indexes\tacquia_search_server\thttps://useast1.acquia-search.com:443/solr/WXYZ-12345.dev.mysitedev\t0' <<<"$(slice 'CASE 4' 'CASE 5')" \
    || { echo "FAIL: a server with no index did not report no-indexes"; exit 1; }
echo "  reports no-indexes when a reachable server holds nothing OK"

case5="$(slice 'CASE 5' 'END')"
grep -qF $'[srsx-health]\tok\tacquia_search_server\thttps://useast1.acquia-search.com:443/solr/WXYZ-12345.dev.mysitedev\t2' <<<"$case5" \
    || { echo "FAIL: a healthy server did not report ok"; exit 1; }
grep -qF $'[srsx-health]\tnot-solr\tdatabase_server\t\t3' <<<"$case5" \
    || { echo "FAIL: a database server was not reported as not-solr"; exit 1; }
echo "  reports ok for a healthy Solr server and not-solr for a database one OK"

# A URL must never carry credentials into a log.
grep -qiE '(password|token|api_key)' <<<"$out" \
    && { echo "FAIL: health output contains a credential-looking field"; exit 1; }
echo "  composed URLs carry no credentials OK"

echo "  preflight-search-health OK"
