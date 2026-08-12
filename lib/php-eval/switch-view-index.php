<?php

/**
 * @file
 * Repoint one Search-API view between its legacy index and the SearchStax copy.
 *
 * Invoked via:
 *   SRSX_VIEW_ID=<view_id> [SRSX_ROLLBACK=1] \
 *     drush php:script lib/php-eval/switch-view-index.php
 *
 * Prefers MigrationHelper::switchViewToNewIndex(), the same method behind
 * `drush searchstax:switch-view-index`. That service only exists on newer
 * searchstax releases (1.9.x has the submodule but not the helper), so the same
 * rewrite is also implemented inline: repoint base_table and rewrite every
 * nested "table" key that names the old index.
 *
 * The old -> new mapping is read from the module's own copied_indexes record,
 * never guessed from index names: copies are called "searchstax_index…", not
 * "<original>_searchstax". Rollback uses its original_base_tables record, which
 * is written when a view is switched, and restores the exact table the view had
 * — a view built on a datasource table must not come back as an index table.
 *
 * No `use` statements: the body is wrapped in a closure where imports are
 * illegal, so classes are referenced fully qualified.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$viewId = getenv('SRSX_VIEW_ID') ?: '';
$rollback = getenv('SRSX_ROLLBACK') === '1';
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

$copied = $utility->getCopiedIndexes();
$currentBaseTable = (string) $view->get('base_table');
$originalBaseTable = $utility->getOriginalBaseTables()[$viewId] ?? NULL;

// Index IDs and datasource names both contain underscores, so a base table is
// matched against known index IDs rather than split on "_".
$tableNames = function (string $table, string $indexId): bool {
  return (bool) preg_match(
    '/^search_api_(?:index|datasource)_' . preg_quote($indexId, '/') . '(_\w+)?$/',
    $table
  );
};

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

// $finalBaseTable is passed explicitly because switchViewToNewIndex() always
// writes search_api_index_<id>, which would lose a datasource base table.
$applySwitch = function (string $from, string $to, string $finalBaseTable)
  use ($view, $helper, $switchTables): void {
  if ($helper) {
    $helper->switchViewToNewIndex($view, $from, $to);
  }
  else {
    foreach ($view->toArray() as $key => $value) {
      if (is_array($value) && $switchTables($value, $from, $to)) {
        $view->set($key, $value);
      }
    }
  }
  $view->set('base_table', $finalBaseTable);
};

$resaveFacets = function () use ($view, $viewId, $helper, $entityTypeManager): void {
  // Facets keep a dependency on the index behind their view, so they have to be
  // re-saved or they keep pointing at the old one.
  if ($helper) {
    foreach ($helper->viewsIndexSwitchResaveAffectedFacets($view) as $facet) {
      fwrite(STDOUT, "[switch-view-index] WARN facet '{$facet->id()}' could not be re-saved; "
        . "re-save it by hand so it points at the correct index.\n");
    }
    return;
  }
  if (!$entityTypeManager->hasDefinition('facets_facet')) {
    return;
  }
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
};

if ($rollback) {
  if (!$originalBaseTable) {
    fwrite(STDERR, "[switch-view-index] ERR '{$viewId}' has no recorded original index, so it\n");
    fwrite(STDERR, "[switch-view-index]   was not switched by this toolkit and cannot be rolled back.\n");
    return 1;
  }
  if ($originalBaseTable === $currentBaseTable) {
    fwrite(STDOUT, "[switch-view-index] SKIP {$viewId} (already on its original index)\n");
    return 0;
  }

  $restoreTo = '';
  $restoreFrom = '';
  foreach ($copied as $from => $to) {
    if ($tableNames($originalBaseTable, $from)) {
      $restoreTo = $from;
      $restoreFrom = $to;
      break;
    }
  }
  if ($restoreTo === '') {
    fwrite(STDERR, "[switch-view-index] ERR cannot tell which index '{$originalBaseTable}' refers to.\n");
    return 1;
  }

  $applySwitch($restoreFrom, $restoreTo, $originalBaseTable);
  $view->save();
  fwrite(STDOUT, "[switch-view-index] ROLLBACK {$viewId}: {$restoreFrom} -> {$restoreTo}\n");
  $resaveFacets();
  return 0;
}

if ($originalBaseTable && $currentBaseTable !== $originalBaseTable) {
  fwrite(STDOUT, "[switch-view-index] SKIP {$viewId} (already switched)\n");
  return 0;
}

$oldIndexId = '';
$newIndexId = '';
foreach ($copied as $from => $to) {
  if ($tableNames($currentBaseTable, $from)) {
    $oldIndexId = $from;
    $newIndexId = $to;
    break;
  }
}
if ($oldIndexId === '') {
  fwrite(STDERR, "[switch-view-index] ERR view '{$viewId}' is on '{$currentBaseTable}', "
    . "which is not a copied index.\n");
  return 1;
}
if (!$entityTypeManager->getStorage('search_api_index')->load($newIndexId)) {
  fwrite(STDERR, "[switch-view-index] ERR the recorded copy '{$newIndexId}' no longer exists.\n");
  return 1;
}

$brokenBefore = [];
if ($helper) {
  // A handler already broken before the switch must not be blamed on the switch.
  $brokenBefore = $helper->getBrokenViewsHandlers(\Drupal::service('views.executable')->get($view));
}

$applySwitch($oldIndexId, $newIndexId, 'search_api_index_' . $newIndexId);

if ($helper) {
  $newlyBroken = array_diff(
    $helper->getBrokenViewsHandlers(\Drupal::service('views.executable')->get($view)),
    $brokenBefore
  );
  if ($newlyBroken) {
    fwrite(STDERR, "[switch-view-index] ERR switching {$viewId} would break: "
      . implode(', ', $newlyBroken) . "\n");
    fwrite(STDERR, "[switch-view-index]   Not saved. Fix the view, then re-run.\n");
    return 1;
  }
}

$view->save();
if (!$originalBaseTable) {
  $utility->addOriginalBaseTable($viewId, $currentBaseTable);
}
fwrite(STDOUT, "[switch-view-index] OK {$viewId}: {$oldIndexId} -> {$newIndexId}\n");
$resaveFacets();

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
