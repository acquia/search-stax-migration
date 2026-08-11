<?php

/**
 * @file
 * Report the Search-API server/index topology as Drupal actually sees it.
 *
 * `drush search-api:list --format=json` cannot answer this. Its default field
 * set is id,name,serverName,typeNames,status,limit — the machine-readable
 * `server` (a server ID) is omitted and `serverName` is a human label, so
 * reading it made every index look as if it had no server at all.
 *
 * Alongside the human-readable report this emits tab-separated lines that the
 * index phase consumes:
 *
 *   [srsx-target]<TAB>ok|missing|not-solr|wrong-connector<TAB>id<TAB>connector
 *   [srsx-index]<TAB>target|legacy|other|detached<TAB>id<TAB>server<TAB>backend
 *
 * Invoked via:
 *   SRSX_SERVER_ID=<server_id> drush php:script lib/php-eval/inspect-index-topology.php
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$targetId = getenv('SRSX_SERVER_ID') ?: 'searchstax_server';

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
$connectors = [];
$legacySolr = [];
fwrite(STDOUT, '[topology] servers (' . count($servers) . "):\n");
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
  $connectors[$server->id()] = $connector;
  $legacy = '?';
  if ($utility) {
    $legacySolr[$server->id()] = $utility->isNonSearchStaxSolrServer($server);
    $legacy = $legacySolr[$server->id()] ? 'yes' : 'no';
  }
  fwrite(STDOUT, "[topology]   {$server->id()}  backend={$backendId}"
    . "  connector={$connector}  legacy-solr={$legacy}"
    . '  status=' . ($server->status() ? 'enabled' : 'disabled') . "\n");
}

// A missing target server means the index phase has nothing to copy onto, and
// a non-SearchStax connector produces a server that never reaches SearchStax.
$targetState = 'ok';
if (!isset($servers[$targetId])) {
  $targetState = 'missing';
}
elseif ($servers[$targetId]->getBackendId() !== 'search_api_solr') {
  $targetState = 'not-solr';
}
elseif (stripos((string) $connectors[$targetId], 'searchstax') === FALSE) {
  $targetState = 'wrong-connector';
}

// The verdict decides whether the index phase can run at all, so say it in
// words rather than leaving it to be inferred from the server list above.
switch ($targetState) {
  case 'ok':
    fwrite(STDOUT, "[topology] target server '{$targetId}': OK (SearchStax connector).\n");
    break;

  case 'missing':
    fwrite(STDOUT, "[topology] target server '{$targetId}': MISSING — there is nothing to copy\n");
    fwrite(STDOUT, "[topology]   onto. Run './srsx-migrate server --force' before the index phase.\n");
    break;

  case 'not-solr':
    fwrite(STDOUT, "[topology] target server '{$targetId}': NOT A SOLR SERVER.\n");
    fwrite(STDOUT, "[topology]   Re-create it with './srsx-migrate server --force'.\n");
    break;

  default:
    fwrite(STDOUT, "[topology] target server '{$targetId}': WRONG CONNECTOR "
      . "('" . $connectors[$targetId] . "', not searchstax).\n");
    fwrite(STDOUT, "[topology]   It would accept a copy and index nowhere, so the index phase\n");
    fwrite(STDOUT, "[topology]   refuses. Re-create it with './srsx-migrate server --force'.\n");
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
$rows = [];
foreach ($indexes as $index) {
  $effective = $index->getServerId() ?: '';
  // getEditable() bypasses config overrides; the entity does not.
  $raw = (string) ($configFactory
    ->getEditable('search_api.index.' . $index->id())
    ->get('server') ?? '');

  $backend = isset($servers[$effective]) ? ($servers[$effective]->getBackendId() ?: '') : '';
  if ($effective === '' || !isset($servers[$effective])) {
    $class = 'detached';
  }
  elseif ($effective === $targetId) {
    $class = 'target';
  }
  elseif (($legacySolr[$effective] ?? FALSE) === TRUE) {
    $class = 'legacy';
  }
  else {
    // Neither the target nor a migratable Solr server — a database backend,
    // say. Moving one of those is a decision, not a migration step.
    $class = 'other';
  }
  $rows[] = "[srsx-index]\t{$class}\t{$index->id()}\t{$effective}\t{$backend}";

  $note = '';
  if ($raw !== $effective) {
    $note = '  <-- OVERRIDDEN (raw config differs from the loaded entity)';
    $overridden[] = $index->id();
  }
  elseif ($effective === '') {
    $note = '  <-- no server in config';
  }
  elseif (!isset($servers[$effective])) {
    $note = '  <-- points at a server entity that does not exist';
  }
  fwrite(STDOUT, "[topology]   {$index->id()}"
    . '  status=' . ($index->status() ? 'enabled' : 'disabled')
    . "  server(entity)='" . ($effective ?: '(none)') . "'"
    . "  server(raw config)='" . ($raw ?: '(none)') . "'"
    . "  [{$class}]" . $note . "\n");
}

if ($overridden) {
  fwrite(STDOUT, '[topology] NOTE: ' . count($overridden) . " index(es) get their server from a\n");
  fwrite(STDOUT, "[topology]   config override rather than stored config. Drush and the web UI can\n");
  fwrite(STDOUT, "[topology]   then disagree about which server an index is on.\n");
}

fwrite(STDOUT, "[srsx-target]\t{$targetState}\t{$targetId}\t" . ($connectors[$targetId] ?? '') . "\n");
foreach ($rows as $row) {
  fwrite(STDOUT, $row . "\n");
}

return 0;
