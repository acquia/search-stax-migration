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
 * Mirrors what the module's CloneIndexesForm does, minus the UI:
 * duplicate the index onto the new server, drop acquia_search third-party
 * settings so the clone survives acquia_search being uninstalled during
 * cleanup, and record the pair through UtilityService::addCopiedIndex() so
 * the module's own admin forms recognize the migration state.
 * (UtilityService has no cloneIndex() method — addCopiedIndex() is the
 * bookkeeping API the form itself uses.)
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$extra = $extra ?? [];
$indexId  = $extra[0] ?? '';
$serverId = $extra[1] ?? 'searchstax_server';

if ($indexId === '') {
  throw new \RuntimeException("[clone-index] Usage: drush php:script clone-index.php -- <index_id> [server_id]");
}

$indexStorage = \Drupal::entityTypeManager()->getStorage('search_api_index');

$index = $indexStorage->load($indexId);
if (!$index) {
  throw new \RuntimeException("[clone-index] Index not found: {$indexId}");
}

$server = \Drupal::entityTypeManager()
  ->getStorage('search_api_server')
  ->load($serverId);
if (!$server) {
  throw new \RuntimeException("[clone-index] Target server not found: {$serverId}");
}

// Idempotency: phase re-runs must not fail on an already-cloned index.
$cloneId = $indexId . '_searchstax';
if ($indexStorage->load($cloneId)) {
  fwrite(STDOUT, "[clone-index] OK (already exists): {$indexId} -> {$cloneId}\n");
  return;
}

$clone = $index->createDuplicate();
$clone->set('id', $cloneId);
$clone->set('name', $index->label() . ' (SearchStax)');
$clone->set('description', 'Copy of index ' . $index->label() . '. Created by srsx-migrate.');
$clone->set('server', $serverId);
$clone->set('status', TRUE);

// Match CloneIndexesForm: strip acquia_search third-party settings so the
// clone doesn't retain a dependency on the module being removed at cleanup.
foreach (array_keys($clone->getThirdPartySettings('acquia_search')) as $tpsKey) {
  $clone->unsetThirdPartySetting('acquia_search', $tpsKey);
}

$clone->save();

// Record the copy in the module's keyvalue bookkeeping so CloneIndexesForm /
// SearchViewSwitchIndexForm treat the pair as migrated, and so
// switch-view-index.php can build its map from the same source of truth.
if (\Drupal::hasService('solr_to_searchstax_ss_migration.utility')) {
  \Drupal::service('solr_to_searchstax_ss_migration.utility')
    ->addCopiedIndex($indexId, $clone->id());
}

fwrite(STDOUT, "[clone-index] OK: {$indexId} -> {$clone->id()}\n");
return;
