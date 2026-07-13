<?php

/**
 * @file
 * Clone a legacy Search-API index onto the SearchStax server.
 *
 * Uploaded to the target env by srsx-migrate and invoked via:
 *   drush php:script /tmp/srsx-<run>/clone-index.php -- <index_id> [server_id]
 *
 * Parameters arrive as php:script arguments (drush's $extra array), NOT as
 * environment variables — client env does not survive the acli/SSH hop.
 *
 * Bypasses the CloneIndexesForm UI step from solr_to_searchstax_ss_migration
 * by calling the same UtilityService method that form invokes.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$extra = $extra ?? [];
$indexId  = $extra[0] ?? '';
$serverId = $extra[1] ?? 'searchstax_server';

if ($indexId === '') {
  fwrite(STDERR, "[clone-index] Usage: drush php:script clone-index.php -- <index_id> [server_id]\n");
  exit(1);
}

$index = \Drupal::entityTypeManager()
  ->getStorage('search_api_index')
  ->load($indexId);

if (!$index) {
  fwrite(STDERR, "[clone-index] Index not found: {$indexId}\n");
  exit(1);
}

$server = \Drupal::entityTypeManager()
  ->getStorage('search_api_server')
  ->load($serverId);

if (!$server) {
  fwrite(STDERR, "[clone-index] Target server not found: {$serverId}\n");
  exit(1);
}

if (\Drupal::hasService('solr_to_searchstax_ss_migration.utility')) {
  $utility = \Drupal::service('solr_to_searchstax_ss_migration.utility');
  // Method signature mirrors what CloneIndexesForm uses.
  $newId = $utility->cloneIndex($index, $server);
  fwrite(STDOUT, "[clone-index] OK: {$indexId} -> {$newId}\n");
  exit(0);
}

// Fallback: hand-rolled clone using only Search-API core APIs.
$clone = $index->createDuplicate();
$clone->set('id', $indexId . '_searchstax');
$clone->set('name', $index->label() . ' (SearchStax)');
$clone->set('server', $serverId);
$clone->set('status', TRUE);
$clone->save();
fwrite(STDOUT, "[clone-index] OK (fallback): {$indexId} -> {$clone->id()}\n");
exit(0);
