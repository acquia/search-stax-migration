<?php

/**
 * @file
 * Copy a Search-API index onto the SearchStax server.
 *
 * Invoked via:
 *   SRSX_INDEX_ID=<legacy_id> SRSX_NEW_SERVER_ID=<server_id> \
 *     drush php:script lib/php-eval/clone-index.php
 *
 * Calls MigrationHelperInterface::createIndexCopy() — the one implementation
 * behind both the "Create copy" button on
 * /admin/config/search/solr-to-searchstax-ss-migration and the module's own
 * `drush searchstax:copy-index`. Going straight at it works on every module
 * release (the drush commands only exist from 1.12.0) and is not blocked by
 * that command's eligibility gate, which refuses any index whose current server
 * is not in the module's migrated_servers map — including one with no server.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$indexId  = getenv('SRSX_INDEX_ID') ?: '';
$serverId = getenv('SRSX_NEW_SERVER_ID') ?: 'searchstax_server';

if ($indexId === '') {
  fwrite(STDERR, "[clone-index] SRSX_INDEX_ID is required.\n");
  return 1;
}

$indexStorage = \Drupal::entityTypeManager()->getStorage('search_api_index');
$index = $indexStorage->load($indexId);
if (!$index) {
  fwrite(STDERR, "[clone-index] ERR index not found: {$indexId}\n");
  return 1;
}

$server = \Drupal::entityTypeManager()
  ->getStorage('search_api_server')
  ->load($serverId);
if (!$server) {
  fwrite(STDERR, "[clone-index] ERR target server not found: {$serverId}\n");
  return 1;
}

$utility = \Drupal::hasService('solr_to_searchstax_ss_migration.utility')
  ? \Drupal::service('solr_to_searchstax_ss_migration.utility')
  : NULL;

// Neither the module's form nor its drush command checks this, so repeating
// either mints searchstax_index_2, _3, … Re-running a phase must be safe.
if ($utility) {
  $existingId = $utility->getCopiedIndexes()[$indexId] ?? '';
  if ($existingId !== '' && $indexStorage->load($existingId)) {
    fwrite(STDOUT, "[clone-index] SKIP {$indexId} -> {$existingId} (already copied)\n");
    return 0;
  }
}

if (\Drupal::hasService('solr_to_searchstax_ss_migration.migration_helper')) {
  $helper = \Drupal::service('solr_to_searchstax_ss_migration.migration_helper');
  $newIndex = $helper->createIndexCopy($index, $serverId);
  fwrite(STDOUT, "[clone-index] OK {$indexId} -> {$newIndex->id()}\n");
  return 0;
}

fwrite(STDOUT, $utility
  ? "[clone-index] this searchstax release has no migration_helper service; copying by hand.\n"
  : "[clone-index] solr_to_searchstax_ss_migration is not enabled; copying by hand.\n");

// The same field surgery createIndexCopy() performs, so a fallback copy stays
// interchangeable with one made through the module.
$values = $index->toArray();
unset(
  $values['uuid'],
  $values['dependencies'],
  $values['third_party_settings']['acquia_search'],
  $values['_core'],
);
$newId = 'searchstax_index';
for ($i = 2; $indexStorage->load($newId); $i++) {
  $newId = 'searchstax_index_' . $i;
}
$values['id'] = $newId;
$values['name'] = 'SearchStax index';
$values['description'] = 'Copy of index ' . $index->label() . '.';
$values['server'] = $serverId;

$newIndex = $indexStorage->create($values);
$newIndex->save();

// The views phase resolves old index -> new index through this map.
if ($utility) {
  $utility->addCopiedIndex($indexId, $newIndex->id());
}

fwrite(STDOUT, "[clone-index] OK (fallback) {$indexId} -> {$newIndex->id()}\n");
return 0;
