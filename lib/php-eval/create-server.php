<?php

/**
 * @file
 * Create/update the SearchStax-backed search_api server.
 *
 * The connector matters: a plain "standard" Solr connector cannot authenticate
 * against SearchStax. The module ships a 'searchstax' connector — shown in the
 * UI as the token-auth option — whose real fields are just the update endpoint
 * and the read & write token; scheme/host/port/path/core/context are derived
 * from that endpoint, and key_id stays empty for "Do not use Key module".
 * Field names come from SearchStaxConnector::defaultConfiguration().
 *
 * Set SRSX_CONNECTOR to force a different plugin id.
 *
 * SRSX_SITE_HASH=1 turns on "Retrieve results for this site only", so a
 * multisite doesn't see its siblings' documents. Leave it unset to keep
 * whatever the server already has — this script re-runs under --force and
 * must not silently revert an operator's UI choice.
 *
 * Invoked via srsx-migrate's drush_php helper, which sets SRSX_* via putenv().
 *
 * No `use` statements: the body is wrapped in a closure where imports are
 * illegal, so classes are referenced fully qualified.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$id       = getenv('SRSX_SERVER_ID') ?: 'searchstax_server';
$name     = getenv('SRSX_SERVER_NAME') ?: 'SearchStax Cloud';
$host     = getenv('SRSX_HOST') ?: '';
$port     = (int) (getenv('SRSX_PORT') ?: 443);
$core     = getenv('SRSX_CORE') ?: '';
$context  = getenv('SRSX_CONTEXT') ?: '';
$endpoint = getenv('SRSX_UPDATE_ENDPOINT') ?: '';
$token    = getenv('SRSX_UPDATE_TOKEN') ?: '';
$suggest  = getenv('SRSX_AUTOSUGGEST_ENDPOINT') ?: '';
$wanted   = getenv('SRSX_CONNECTOR') ?: '';
$site_hash = getenv('SRSX_SITE_HASH') ?: '';

if ($endpoint === '') {
  fwrite(STDERR, "[create-server] SRSX_UPDATE_ENDPOINT is required.\n");
  return 1;
}
if (!\Drupal::hasService('plugin.manager.search_api_solr.connector')) {
  fwrite(STDERR, "[create-server] search_api_solr is not installed on this site.\n");
  return 1;
}

$manager = \Drupal::service('plugin.manager.search_api_solr.connector');
$definitions = $manager->getDefinitions();

$connector = '';
foreach ([$wanted, 'searchstax'] as $candidate) {
  if ($candidate !== '' && isset($definitions[$candidate])) {
    $connector = $candidate;
    break;
  }
}
if ($connector === '') {
  foreach ($definitions as $pid => $definition) {
    if (stripos($pid . ' ' . (string) ($definition['label'] ?? ''), 'searchstax') !== FALSE) {
      $connector = $pid;
      break;
    }
  }
}
if ($connector === '') {
  fwrite(STDERR, "[create-server] No SearchStax Solr connector is available. Connectors found:\n");
  foreach ($definitions as $pid => $definition) {
    fwrite(STDERR, "[create-server]   {$pid} — " . (string) ($definition['label'] ?? '') . "\n");
  }
  fwrite(STDERR, "[create-server] Enable drupal/searchstax on this site, or set SRSX_CONNECTOR.\n");
  return 1;
}

$config = [
  'scheme' => 'https',
  'host' => $host,
  'port' => $port,
  'path' => '/',
  'core' => $core,
  'context' => $context,
  'update_endpoint' => $endpoint,
  'update_token' => $token,
  'autosuggest_endpoint' => $suggest,
  // Empty means "- Do not use Key module -"; the credentials live in config.
  'key_id' => '',
];
try {
  $config += $manager->createInstance($connector, [])->defaultConfiguration();
}
catch (\Throwable $e) {
  fwrite(STDOUT, "[create-server] could not read defaults for {$connector}: {$e->getMessage()}\n");
}

$storage = \Drupal::entityTypeManager()->getStorage('search_api_server');
$server = $storage->load($id);
if (!$server) {
  $server = $storage->create([
    'id' => $id,
    'name' => $name,
    'description' => 'SearchStax-backed Solr server. Created by srsx-migrate.',
    'status' => TRUE,
    'backend' => 'search_api_solr',
  ]);
}

$backend = $server->get('backend_config') ?: [];
$backend['connector'] = $connector;
$backend['connector_config'] = $config;
if ($site_hash !== '') {
  $backend['site_hash'] = ($site_hash === '1');
}
$server->set('backend', 'search_api_solr');
$server->set('backend_config', $backend);
$server->save();

fwrite(STDOUT, "[create-server] connector: {$connector}\n");
fwrite(STDOUT, "[create-server] endpoint:  {$endpoint}\n");
fwrite(STDOUT, "[create-server] host={$host} context={$context} core={$core} port={$port} path=/\n");
fwrite(STDOUT, "[create-server] key_id: (none — credentials stored in config)\n");
fwrite(STDOUT, "[create-server] site_hash: " . ($site_hash === '' ? 'unchanged' : ($site_hash === '1' ? 'on' : 'off')) . "\n");
fwrite(STDOUT, "[create-server] Saved search_api.server.{$id}\n");

// The module's UI decides what it can copy from this map, so register every
// legacy Solr server as pointing at the new one. The toolkit's own copy step no
// longer depends on it, but leaving it empty means the migration form at
// /admin/config/search/solr-to-searchstax-ss-migration shows nothing to do.
if (\Drupal::hasService('solr_to_searchstax_ss_migration.utility')) {
  $utility = \Drupal::service('solr_to_searchstax_ss_migration.utility');
  $registered = 0;
  foreach ($storage->loadMultiple() as $existing) {
    if ($existing->id() === $id) {
      continue;
    }
    if ($utility->isNonSearchStaxSolrServer($existing)) {
      $utility->addMigratedServer($existing->id(), $id);
      $registered++;
      fwrite(STDOUT, "[create-server] registered migration: {$existing->id()} -> {$id}\n");
    }
    else {
      $why = $existing->getBackendId() === 'search_api_solr'
        ? 'already looks like a SearchStax Solr server'
        : "backend is '{$existing->getBackendId()}', not Solr";
      fwrite(STDOUT, "[create-server] not registered: {$existing->id()} ({$why})\n");
    }
  }
  if ($registered === 0) {
    fwrite(STDOUT, "[create-server] WARNING: no legacy Solr server was registered as migrated.\n");
    fwrite(STDOUT, "[create-server]   The module's copy form will offer nothing. Run\n");
    fwrite(STDOUT, "[create-server]   './srsx-migrate doctor' to see what servers exist here.\n");
  }
}
else {
  fwrite(STDOUT, "[create-server] NOTE: solr_to_searchstax_ss_migration is not enabled,\n");
  fwrite(STDOUT, "[create-server]       so index copies cannot record the old -> new mapping.\n");
}

if ($token === '') {
  fwrite(STDOUT, "[create-server] WARNING: no read & write token was supplied; SearchStax will reject requests.\n");
}

return 0;
