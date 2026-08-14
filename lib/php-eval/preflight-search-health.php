<?php

/**
 * @file
 * Report whether the search this migration reads from is working.
 *
 * The toolkit migrates an existing, working search, so a site with no reachable
 * core or no index attached has nothing to copy. Checking that in preflight
 * keeps it cheap: later phases only reach the same conclusion after `install`
 * has changed the repository and `provision` has created SearchStax apps.
 *
 * Two questions per Search API server, which is all a pre-check needs:
 *   1. does it resolve to a server URL, and does that URL answer?
 *   2. does it actually hold any index?
 *
 * For an Acquia Search server, question 1 covers subscription health for free:
 * AcquiaSearchSolrBackend::getSolrConnector() fills host/core from the
 * preferred core, so a subscription that resolves nothing leaves host
 * 'localhost' with an empty core.
 *
 * Alongside the human-readable report this emits tab-separated lines that the
 * preflight phase consumes:
 *
 *   [srsx-health]<TAB>ok|no-servers|no-url|unreachable|no-indexes|not-solr<TAB>server_id<TAB>url<TAB>index_count
 *
 * Invoked via: drush php:script lib/php-eval/preflight-search-health.php
 * (no SRSX_* input required).
 *
 * No `use` imports: php:eval evaluates a raw body where imports are illegal.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

if (!\Drupal::moduleHandler()->moduleExists('search_api')) {
  fwrite(STDOUT, "[search-health] search_api is not installed on this site.\n");
  fwrite(STDOUT, "[srsx-health]\tno-servers\t(none)\t\t0\n");
  return 0;
}

$servers = \Drupal::entityTypeManager()->getStorage('search_api_server')->loadMultiple();
if (!$servers) {
  fwrite(STDOUT, "[search-health] no Search API servers exist on this site.\n");
  fwrite(STDOUT, "[srsx-health]\tno-servers\t(none)\t\t0\n");
  return 0;
}

fwrite(STDOUT, '[search-health] servers (' . count($servers) . "):\n");
foreach ($servers as $server) {
  $id = $server->id();
  $indexCount = count($server->getIndexes());
  $enabled = $server->status() ? 'enabled' : 'disabled';

  try {
    $backend = $server->getBackend();
  }
  catch (\Exception $e) {
    fwrite(STDOUT, "[search-health]   {$id}  BACKEND UNAVAILABLE: " . $e->getMessage() . "\n");
    fwrite(STDOUT, "[srsx-health]\tno-url\t{$id}\t\t{$indexCount}\n");
    continue;
  }

  if (!method_exists($backend, 'getSolrConnector')) {
    // A database (or other non-Solr) server is not what this migration reads
    // from, so it is reported and otherwise left alone.
    fwrite(STDOUT, "[search-health]   {$id}  backend={$server->getBackendId()}"
      . "  (not Solr)  indexes={$indexCount}  {$enabled}\n");
    fwrite(STDOUT, "[srsx-health]\tnot-solr\t{$id}\t\t{$indexCount}\n");
    continue;
  }

  $url = '';
  $connector = NULL;
  try {
    $connector = $backend->getSolrConnector();
    $config = $connector->getConfiguration();
    $host = (string) ($config['host'] ?? '');
    $core = (string) ($config['core'] ?? '');
    // Only the address is composed — never the auth fields, so nothing here
    // can leak a token into a log.
    if ($host !== '' && $host !== 'localhost' && $core !== '') {
      $scheme = (string) ($config['scheme'] ?? 'https');
      $port = (string) ($config['port'] ?? '');
      $path = trim((string) ($config['path'] ?? ''), '/');
      $url = $scheme . '://' . $host . ($port !== '' ? ':' . $port : '')
        . ($path !== '' ? '/' . $path : '') . '/' . $core;
    }
  }
  catch (\Exception $e) {
    fwrite(STDOUT, "[search-health]   {$id}  CONNECTOR ERROR: " . $e->getMessage() . "\n");
  }

  if ($url === '') {
    fwrite(STDOUT, "[search-health]   {$id}  NO SERVER URL — this server resolves to nothing.\n");
    fwrite(STDOUT, "[search-health]     For an Acquia Search server this means the subscription\n");
    fwrite(STDOUT, "[search-health]     produced no usable core, so search here is already dead.\n");
    fwrite(STDOUT, "[srsx-health]\tno-url\t{$id}\t\t{$indexCount}\n");
    continue;
  }

  $reachable = FALSE;
  try {
    $reachable = (bool) $connector->pingCore();
  }
  catch (\Exception $e) {
    $reachable = FALSE;
  }

  if (!$reachable) {
    fwrite(STDOUT, "[search-health]   {$id}  UNREACHABLE  {$url}  indexes={$indexCount}  {$enabled}\n");
    fwrite(STDOUT, "[srsx-health]\tunreachable\t{$id}\t{$url}\t{$indexCount}\n");
    continue;
  }

  if ($indexCount === 0) {
    fwrite(STDOUT, "[search-health]   {$id}  reachable but holds NO INDEX  {$url}  {$enabled}\n");
    fwrite(STDOUT, "[srsx-health]\tno-indexes\t{$id}\t{$url}\t0\n");
    continue;
  }

  fwrite(STDOUT, "[search-health]   {$id}  OK  {$url}  indexes={$indexCount}  {$enabled}\n");
  fwrite(STDOUT, "[srsx-health]\tok\t{$id}\t{$url}\t{$indexCount}\n");
}

return 0;
