<?php

/**
 * @file
 * List views that should be repointed at their copied SearchStax index.
 *
 * The module records every index copy itself (UtilityService::getCopiedIndexes,
 * original id => copy id), so the mapping is read from there rather than guessed
 * from index names — searchstax:copy-index names copies "searchstax_index…",
 * not "<original>_searchstax".
 *
 * Prints one "[list-migrated-views] view: <id>" line per view still bound to an
 * index that has a copy, which the caller feeds to searchstax:switch-view-index.
 *
 * Invoked via srsx-migrate's drush_php helper, which sets SRSX_* via putenv().
 *
 * No `use` statements: the body is wrapped in a closure where imports are
 * illegal, so classes are referenced fully qualified.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

if (!\Drupal::moduleHandler()->moduleExists('views')) {
  fwrite(STDOUT, "[list-migrated-views] The views module is not enabled; nothing to switch.\n");
  return 0;
}

$copied = [];
if (\Drupal::hasService('solr_to_searchstax_ss_migration.utility')) {
  $copied = \Drupal::service('solr_to_searchstax_ss_migration.utility')->getCopiedIndexes();
}
if (!$copied) {
  fwrite(STDERR, "[list-migrated-views] No copied indexes are recorded yet. Run the index phase first.\n");
  return 1;
}
fwrite(STDOUT, "[list-migrated-views] copied indexes: "
  . implode(', ', array_map(
      static function ($from, $to) {
        return "{$from} -> {$to}";
      },
      array_keys($copied),
      $copied
    )) . "\n");

$storage = \Drupal::entityTypeManager()->getStorage('view');
$found = 0;
foreach ($storage->loadMultiple() as $view) {
  $base = $view->get('base_table');
  // Search API views use a "search_api_index_<id>" base table.
  if (!is_string($base) || strpos($base, 'search_api_index_') !== 0) {
    continue;
  }
  $index_id = substr($base, strlen('search_api_index_'));
  if (!isset($copied[$index_id])) {
    continue;
  }
  fwrite(STDOUT, "[list-migrated-views] view: " . $view->id() . "\n");
  $found++;
}

fwrite(STDOUT, "[list-migrated-views] {$found} view(s) to switch.\n");
return 0;
