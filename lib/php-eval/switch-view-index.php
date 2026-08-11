<?php

/**
 * @file
 * Repoint one Search-API view from its legacy index to the copy on SearchStax.
 *
 * Invoked via:
 *   SRSX_VIEW_ID=<view_id> drush php:script lib/php-eval/switch-view-index.php
 *
 * Mirrors `drush searchstax:switch-view-index` by calling the same
 * MigrationHelper methods, minus the interactive confirmations. Going straight
 * at the service keeps this working on module releases older than 1.12.0, where
 * that command does not exist.
 *
 * The old -> new mapping is read from the module's own copied_indexes record,
 * never guessed from index names: copies are called "searchstax_index…", not
 * "<original>_searchstax".
 *
 * No `use` statements: the body is wrapped in a closure where imports are
 * illegal, so classes are referenced fully qualified.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$viewId = getenv('SRSX_VIEW_ID') ?: '';
if ($viewId === '') {
  fwrite(STDERR, "[switch-view-index] SRSX_VIEW_ID is required.\n");
  return 1;
}

if (!\Drupal::hasService('solr_to_searchstax_ss_migration.migration_helper')) {
  fwrite(STDERR, "[switch-view-index] ERR solr_to_searchstax_ss_migration is not enabled.\n");
  return 1;
}
$helper = \Drupal::service('solr_to_searchstax_ss_migration.migration_helper');
$utility = \Drupal::service('solr_to_searchstax_ss_migration.utility');
$entityTypeManager = \Drupal::entityTypeManager();

$view = $entityTypeManager->getStorage('view')->load($viewId);
if (!$view) {
  fwrite(STDERR, "[switch-view-index] ERR view not found: {$viewId}\n");
  return 1;
}

$oldBaseTable = $view->get('base_table');
$oldIndex = \Drupal\search_api\Plugin\views\query\SearchApiQuery::getIndexFromTable(
  $oldBaseTable,
  $entityTypeManager
);
if (!$oldIndex) {
  fwrite(STDERR, "[switch-view-index] ERR could not resolve a search index for view {$viewId}.\n");
  return 1;
}
$oldIndexId = $oldIndex->id();

$originalBaseTable = $utility->getOriginalBaseTables()[$viewId] ?? NULL;
if ($originalBaseTable && $oldBaseTable !== $originalBaseTable) {
  fwrite(STDOUT, "[switch-view-index] SKIP {$viewId} (already switched to {$oldIndexId})\n");
  return 0;
}

$newIndexId = $utility->getCopiedIndexes()[$oldIndexId] ?? '';
if ($newIndexId === '' || !$entityTypeManager->getStorage('search_api_index')->load($newIndexId)) {
  fwrite(STDERR, "[switch-view-index] ERR index '{$oldIndexId}' used by view '{$viewId}' has no copy yet.\n");
  return 1;
}

// A handler already broken before the switch must not be blamed on the switch.
$viewExecutable = \Drupal::service('views.executable')->get($view);
$brokenBefore = $helper->getBrokenViewsHandlers($viewExecutable);

$helper->switchViewToNewIndex($view, $oldIndexId, $newIndexId);

$viewExecutable = \Drupal::service('views.executable')->get($view);
$newlyBroken = array_diff($helper->getBrokenViewsHandlers($viewExecutable), $brokenBefore);
if ($newlyBroken) {
  fwrite(STDERR, "[switch-view-index] ERR switching {$viewId} would break: "
    . implode(', ', $newlyBroken) . "\n");
  fwrite(STDERR, "[switch-view-index]   Not saved. Fix the view, then re-run.\n");
  return 1;
}

$view->save();
if (!$originalBaseTable) {
  $utility->addOriginalBaseTable($viewId, $oldBaseTable);
}
fwrite(STDOUT, "[switch-view-index] OK {$viewId}: {$oldIndexId} -> {$newIndexId}\n");

foreach ($helper->viewsIndexSwitchResaveAffectedFacets($view) as $facet) {
  fwrite(STDOUT, "[switch-view-index] WARN facet '{$facet->id()}' could not be re-saved; "
    . "re-save it by hand so it points at the new index.\n");
}

if (method_exists($helper, 'viewsIndexSwitchAdaptAffectedAutocompleteSearches')) {
  try {
    $helper->viewsIndexSwitchAdaptAffectedAutocompleteSearches($view, $newIndexId);
  }
  catch (\Exception $e) {
    fwrite(STDOUT, "[switch-view-index] WARN autocomplete searches not adapted: "
      . $e->getMessage() . "\n");
  }
}

return 0;
