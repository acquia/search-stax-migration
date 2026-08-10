<?php

/**
 * @file
 * Clone a legacy Search-API index onto the SearchStax server.
 *
 * Invoked via:
 *   SRSX_INDEX_ID=<legacy_id> SRSX_NEW_SERVER_ID=<server_id> \
 *     drush php:script lib/php-eval/clone-index.php
 *
 * Bypasses the CloneIndexesForm UI step from solr_to_searchstax_ss_migration
 * by calling the same UtilityService method that form invokes.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$indexId  = getenv('SRSX_INDEX_ID') ?: '';
$serverId = getenv('SRSX_NEW_SERVER_ID') ?: 'searchstax_server';

if ($indexId === '') {
  fwrite(STDERR, "[clone-index] SRSX_INDEX_ID is required.\n");
  return 1;
}

$index = \Drupal::entityTypeManager()
  ->getStorage('search_api_index')
  ->load($indexId);

if (!$index) {
  fwrite(STDERR, "[clone-index] Index not found: {$indexId}\n");
  return 1;
}

$server = \Drupal::entityTypeManager()
  ->getStorage('search_api_server')
  ->load($serverId);

if (!$server) {
  fwrite(STDERR, "[clone-index] Target server not found: {$serverId}\n");
  return 1;
}

if (\Drupal::hasService('solr_to_searchstax_ss_migration.utility')) {
  $utility = \Drupal::service('solr_to_searchstax_ss_migration.utility');
  // Method signature mirrors what CloneIndexesForm uses.
  $newId = $utility->cloneIndex($index, $server);
  fwrite(STDOUT, "[clone-index] OK: {$indexId} -> {$newId}\n");
  return 0;
}

// Fallback: hand-rolled clone using only Search-API core APIs.
$clone = $index->createDuplicate();
$clone->set('id', $indexId . '_searchstax');
$clone->set('name', $index->label() . ' (SearchStax)');
$clone->set('server', $serverId);
$clone->set('status', TRUE);
$clone->save();
fwrite(STDOUT, "[clone-index] OK (fallback): {$indexId} -> {$clone->id()}\n");
return 0;
