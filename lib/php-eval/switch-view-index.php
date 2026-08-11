<?php

/**
 * @file
 * Repoint one Search-API view from its legacy index to the copy on SearchStax.
 *
 * Invoked via:
 *   SRSX_VIEW_ID=<view_id> drush php:script lib/php-eval/switch-view-index.php
 *
 * Prefers MigrationHelper::switchViewToNewIndex(), the same method behind
 * `drush searchstax:switch-view-index`. That service only exists on newer
 * searchstax releases (1.9.x has the submodule but not the helper), so the same
 * rewrite is also implemented inline: set base_table to the new index and
 * rewrite every nested "table" key that names the old one.
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

if (!\Drupal::hasService('solr_to_searchstax_ss_migration.utility')) {
  fwrite(STDERR, "[switch-view-index] ERR solr_to_searchstax_ss_migration is not enabled;\n");
  fwrite(STDERR, "[switch-view-index]   without it there is no record of which index was copied.\n");
  return 1;
}
$utility = \Drupal::service('solr_to_searchstax_ss_migration.utility');
$helper = \Drupal::hasService('solr_to_searchstax_ss_migration.migration_helper')
  ? \Drupal::service('solr_to_searchstax_ss_migration.migration_helper')
  : NULL;

$entityTypeManager = \Drupal::entityTypeManager();
$view = $entityTypeManager->getStorage('view')->load($viewId);
if (!$view) {
  fwrite(STDERR, "[switch-view-index] ERR view not found: {$viewId}\n");
  return 1;
}

$oldBaseTable = (string) $view->get('base_table');
$originalBaseTable = $utility->getOriginalBaseTables()[$viewId] ?? NULL;
if ($originalBaseTable && $oldBaseTable !== $originalBaseTable) {
  fwrite(STDOUT, "[switch-view-index] SKIP {$viewId} (already switched)\n");
  return 0;
}

// Search-API views sit on search_api_index_<id> or search_api_datasource_<id>_<ds>,
// and both the index ID and the datasource contain underscores, so the index is
// identified by testing the copied ones against the table name.
$oldIndexId = '';
$newIndexId = '';
foreach ($utility->getCopiedIndexes() as $from => $to) {
  if (preg_match('/^search_api_(?:index|datasource)_' . preg_quote($from, '/') . '(_\w+)?$/', $oldBaseTable)) {
    $oldIndexId = $from;
    $newIndexId = $to;
    break;
  }
}
if ($oldIndexId === '') {
  fwrite(STDERR, "[switch-view-index] ERR view '{$viewId}' is on '{$oldBaseTable}', "
    . "which is not a copied index.\n");
  return 1;
}
if (!$entityTypeManager->getStorage('search_api_index')->load($newIndexId)) {
  fwrite(STDERR, "[switch-view-index] ERR the recorded copy '{$newIndexId}' no longer exists.\n");
  return 1;
}

if ($helper) {
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
}
else {
  fwrite(STDOUT, "[switch-view-index] this searchstax release has no migration_helper "
    . "service; switching by hand.\n");

  $switchTables = function (array &$config, string $from, string $to) use (&$switchTables): bool {
    $changed = FALSE;
    if (is_string($config['table'] ?? NULL)) {
      $new = preg_replace(
        '/^(search_api_(?:index|datasource)_)' . preg_quote($from, '/') . '(_\w+)?$/',
        '$1' . $to . '$2',
        $config['table']
      );
      if ($new !== $config['table']) {
        $config['table'] = $new;
        $changed = TRUE;
      }
    }
    foreach ($config as &$value) {
      if (is_array($value) && $switchTables($value, $from, $to)) {
        $changed = TRUE;
      }
    }
    return $changed;
  };

  $view->set('base_table', 'search_api_index_' . $newIndexId);
  foreach ($view->toArray() as $key => $value) {
    if (is_array($value) && $switchTables($value, $oldIndexId, $newIndexId)) {
      $view->set($key, $value);
    }
  }
}

$view->save();
if (!$originalBaseTable) {
  $utility->addOriginalBaseTable($viewId, $oldBaseTable);
}
fwrite(STDOUT, "[switch-view-index] OK {$viewId}: {$oldIndexId} -> {$newIndexId}\n");

// Facets keep a dependency on the index behind their view, so they have to be
// re-saved or they keep pointing at the old one.
if ($helper) {
  foreach ($helper->viewsIndexSwitchResaveAffectedFacets($view) as $facet) {
    fwrite(STDOUT, "[switch-view-index] WARN facet '{$facet->id()}' could not be re-saved; "
      . "re-save it by hand so it points at the new index.\n");
  }
}
elseif ($entityTypeManager->hasDefinition('facets_facet')) {
  foreach ($entityTypeManager->getStorage('facets_facet')->loadMultiple() as $facet) {
    if (strpos((string) $facet->getFacetSourceId(), '__' . $viewId . '__') === FALSE) {
      continue;
    }
    try {
      $facet->save();
    }
    catch (\Exception $e) {
      fwrite(STDOUT, "[switch-view-index] WARN facet '{$facet->id()}' could not be re-saved: "
        . $e->getMessage() . "\n");
    }
  }
}

if ($helper && method_exists($helper, 'viewsIndexSwitchAdaptAffectedAutocompleteSearches')) {
  try {
    $helper->viewsIndexSwitchAdaptAffectedAutocompleteSearches($view, $newIndexId);
  }
  catch (\Exception $e) {
    fwrite(STDOUT, "[switch-view-index] WARN autocomplete searches not adapted: "
      . $e->getMessage() . "\n");
  }
}
elseif (\Drupal::moduleHandler()->moduleExists('search_api_autocomplete')) {
  fwrite(STDOUT, "[switch-view-index] WARN search_api_autocomplete is enabled but this "
    . "searchstax release cannot adapt it;\n");
  fwrite(STDOUT, "[switch-view-index]   check the 'index' value of any autocomplete search "
    . "defined for '{$viewId}'.\n");
}

return 0;
