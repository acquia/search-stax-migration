<?php

/**
 * @file
 * Repoint every Search-API view from a legacy index to its SearchStax twin.
 *
 * Uploaded to the target env by srsx-migrate and invoked via:
 *   drush php:script /tmp/srsx-<run>/switch-view-index.php
 *
 * Ports the logic of the module's SearchViewSwitchIndexForm: a Search-API
 * view is bound to its index through the view's `base_table`
 * (search_api_index_<id>) AND a `table` key on every handler (fields,
 * filters, sorts, arguments, relationships). Rewriting only
 * display_options.query.options.index — what this script previously did —
 * touches a key most views don't even have, silently changing nothing.
 *
 * For each migrated pair this script:
 *   1. records the view's original base table via
 *      UtilityService::addOriginalBaseTable() (enables the module's rollback),
 *   2. sets base_table to the new index's views table,
 *   3. recursively switches every handler `table` key (same regex as the
 *      form's switchTables()),
 *   4. saves the view.
 *
 * The legacy→new map comes from the module's own bookkeeping
 * (UtilityService::getCopiedIndexes(), which clone-index.php populates), with
 * a fallback scan for the `<legacy>_searchstax` id convention so indexes
 * cloned by other means are still recognized.
 *
 * Exits non-zero when there is a map but no view was (or had already been)
 * switched — a silent no-op almost always means the clone step didn't run.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

/**
 * Recursively switch handler `table` keys, as the form's switchTables() does.
 */
function srsx_switch_tables(array &$config, string $from, string $to): bool {
  $changed = FALSE;
  if (is_string($config['table'] ?? NULL)) {
    $newTable = preg_replace(
      "/^(search_api_(?:index|datasource)_)$from(_\\w+)?\$/",
      "\$1$to\$2",
      $config['table']
    );
    if ($newTable !== $config['table']) {
      $changed = TRUE;
      $config['table'] = $newTable;
    }
  }
  foreach ($config as &$value) {
    if (is_array($value) && srsx_switch_tables($value, $from, $to)) {
      $changed = TRUE;
    }
  }
  return $changed;
}

$entityTypeManager = \Drupal::entityTypeManager();
$utility = \Drupal::hasService('solr_to_searchstax_ss_migration.utility')
  ? \Drupal::service('solr_to_searchstax_ss_migration.utility')
  : NULL;

// Legacy → new map. Prefer the module's bookkeeping; fall back to the id
// suffix convention used by clone-index.php.
$map = $utility ? $utility->getCopiedIndexes() : [];
$indexStorage = $entityTypeManager->getStorage('search_api_index');
foreach ($indexStorage->loadMultiple() as $idx) {
  $id = $idx->id();
  if (substr($id, -11) === '_searchstax') {
    $map[substr($id, 0, -11)] = $map[substr($id, 0, -11)] ?? $id;
  }
}

if (!$map) {
  throw new \RuntimeException("[switch-view-index] No migrated index pairs found. Run clone-index.php first.");
}

$viewStorage = $entityTypeManager->getStorage('view');
$switched = 0;
$already = 0;

foreach ($viewStorage->loadMultiple() as $view) {
  $baseTable = $view->get('base_table');
  foreach ($map as $from => $to) {
    if ($baseTable === "search_api_index_{$to}") {
      $already++;
      continue;
    }
    if ($baseTable !== "search_api_index_{$from}") {
      continue;
    }

    if ($utility) {
      $utility->addOriginalBaseTable($view->id(), $baseTable);
    }
    $view->set('base_table', "search_api_index_{$to}");

    // Handlers carry their own `table` references; switch them all.
    foreach ($view->toArray() as $key => $value) {
      if (is_array($value) && srsx_switch_tables($value, $from, $to)) {
        $view->set($key, $value);
      }
    }

    $view->save();
    $switched++;
    fwrite(STDOUT, "[switch-view-index] {$view->id()}: {$from} -> {$to}\n");
  }
}

fwrite(STDOUT, "[switch-view-index] Switched {$switched} view(s); {$already} already migrated.\n");

if ($switched === 0 && $already === 0) {
  throw new \RuntimeException(
    "[switch-view-index] No Search-API views reference the legacy indexes. "
    . "If this site genuinely has no Search-API views, skip the 'views' phase; "
    . "otherwise the 'index' phase probably didn't clone anything."
  );
}
return;
