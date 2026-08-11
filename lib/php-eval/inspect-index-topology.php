<?php

/**
 * @file
 * Report the Search-API server/index topology as Drupal actually sees it.
 *
 * `drush search-api:list` prints "(none)" for an index with no server, but it
 * cannot say WHY: a genuinely detached index and one whose server is supplied
 * by a config override look identical. This dumps both the raw stored config
 * value and the effective entity value side by side, plus everything the
 * migration submodule keys its decisions off, so the difference is visible.
 *
 * Invoked via:
 *   drush php:script lib/php-eval/inspect-index-topology.php
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$moduleHandler = \Drupal::moduleHandler();
$hasMigration = $moduleHandler->moduleExists('solr_to_searchstax_ss_migration');

$version = '(not installed)';
if ($moduleHandler->moduleExists('searchstax')) {
  $info = \Drupal::service('extension.list.module')->getAllAvailableInfo();
  $version = $info['searchstax']['version'] ?? '(dev / unknown)';
}

fwrite(STDOUT, "[topology] searchstax module version: {$version}\n");
fwrite(STDOUT, '[topology] solr_to_searchstax_ss_migration: '
  . ($hasMigration ? 'enabled' : 'NOT ENABLED') . "\n");
if (!$hasMigration) {
  fwrite(STDOUT, "[topology]   Without it there is no createIndexCopy() and no copy bookkeeping.\n");
  fwrite(STDOUT, "[topology]   Enable it with: drush en -y solr_to_searchstax_ss_migration\n");
}

$utility = $hasMigration && \Drupal::hasService('solr_to_searchstax_ss_migration.utility')
  ? \Drupal::service('solr_to_searchstax_ss_migration.utility')
  : NULL;

$servers = \Drupal::entityTypeManager()->getStorage('search_api_server')->loadMultiple();
fwrite(STDOUT, "[topology] servers (" . count($servers) . "):\n");
foreach ($servers as $server) {
  $backendId = $server->getBackendId() ?: '(none)';
  $connector = '(n/a)';
  try {
    $backendConfig = $server->getBackend()->getConfiguration();
    $connector = $backendConfig['connector'] ?? '(none)';
  }
  catch (\Exception $e) {
    $connector = '(backend unavailable: ' . $e->getMessage() . ')';
  }
  $legacy = '?';
  if ($utility) {
    $legacy = $utility->isNonSearchStaxSolrServer($server) ? 'yes' : 'no';
  }
  fwrite(STDOUT, "[topology]   {$server->id()}  backend={$backendId}"
    . "  connector={$connector}  legacy-solr={$legacy}"
    . '  status=' . ($server->status() ? 'enabled' : 'disabled') . "\n");
}

if ($utility) {
  $migrated = $utility->getMigratedServers();
  fwrite(STDOUT, '[topology] migrated_servers map (' . count($migrated) . "):\n");
  foreach ($migrated as $old => $new) {
    fwrite(STDOUT, "[topology]   {$old} -> {$new}\n");
  }
  if (!$migrated) {
    fwrite(STDOUT, "[topology]   (empty — the module UI will offer nothing to copy)\n");
  }
  $copied = $utility->getCopiedIndexes();
  fwrite(STDOUT, '[topology] copied_indexes map (' . count($copied) . "):\n");
  foreach ($copied as $old => $new) {
    fwrite(STDOUT, "[topology]   {$old} -> {$new}\n");
  }
}

$configFactory = \Drupal::configFactory();
$indexes = \Drupal::entityTypeManager()->getStorage('search_api_index')->loadMultiple();
fwrite(STDOUT, '[topology] indexes (' . count($indexes) . "):\n");
$overridden = [];
foreach ($indexes as $index) {
  $effective = $index->getServerId() ?: '';
  // getEditable() bypasses config overrides; the entity does not.
  $raw = (string) ($configFactory
    ->getEditable('search_api.index.' . $index->id())
    ->get('server') ?? '');
  $note = '';
  if ($raw !== $effective) {
    $note = '  <-- OVERRIDDEN (raw config differs from the loaded entity)';
    $overridden[] = $index->id();
  }
  elseif ($effective === '') {
    $note = '  <-- detached: no server in config';
  }
  elseif (!isset($servers[$effective])) {
    $note = '  <-- points at a server entity that does not exist';
  }
  fwrite(STDOUT, "[topology]   {$index->id()}"
    . '  status=' . ($index->status() ? 'enabled' : 'disabled')
    . "  server(entity)='" . ($effective ?: '(none)') . "'"
    . "  server(raw config)='" . ($raw ?: '(none)') . "'"
    . $note . "\n");
}

if ($overridden) {
  fwrite(STDOUT, "[topology] NOTE: " . count($overridden) . " index(es) get their server from a\n");
  fwrite(STDOUT, "[topology]   config override rather than stored config. Drush and the web UI can\n");
  fwrite(STDOUT, "[topology]   then disagree about which server an index is on.\n");
}

return 0;
