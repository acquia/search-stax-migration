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
$server->set('backend', 'search_api_solr');
$server->set('backend_config', $backend);
$server->save();

fwrite(STDOUT, "[create-server] connector: {$connector}\n");
fwrite(STDOUT, "[create-server] endpoint:  {$endpoint}\n");
fwrite(STDOUT, "[create-server] host={$host} context={$context} core={$core} port={$port} path=/\n");
fwrite(STDOUT, "[create-server] key_id: (none — credentials stored in config)\n");
fwrite(STDOUT, "[create-server] Saved search_api.server.{$id}\n");

if ($token === '') {
  fwrite(STDOUT, "[create-server] WARNING: no read & write token was supplied; SearchStax will reject requests.\n");
}

return 0;
