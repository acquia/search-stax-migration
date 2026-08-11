<?php

/**
 * @file
 * List views that should be repointed at their copied SearchStax index.
 *
 * The module records every index copy itself (UtilityService::getCopiedIndexes,
 * original id => copy id), so the mapping is read from there rather than guessed
 * from index names — copies are called "searchstax_index…", not
 * "<original>_searchstax".
 *
 * A view's index is decided by its base_table, so that is what is reported: the
 * views to switch, and every other Search API view with the table it sits on.
 *
 * Emits tab-separated rows the views phase consumes:
 *
 *   [srsx-view]<TAB>view_id<TAB>base_table<TAB>old_index<TAB>new_index
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
$rows = [];
$skipped = [];
foreach ($storage->loadMultiple() as $view) {
  $base = $view->get('base_table');
  if (!is_string($base) || strpos($base, 'search_api_') !== 0) {
    continue;
  }
  // Search API views sit on search_api_index_<id> or
  // search_api_datasource_<id>_<datasource>. Both the index ID and the
  // datasource contain underscores, so the index is identified by testing the
  // copied ones against the table name rather than by splitting the string.
  // switch-view-index.php resolves it the same way; they must agree.
  $matched = '';
  foreach (array_keys($copied) as $index_id) {
    if (preg_match('/^search_api_(?:index|datasource)_' . preg_quote($index_id, '/') . '(_\w+)?$/', $base)) {
      $matched = $index_id;
      break;
    }
  }
  if ($matched === '') {
    $skipped[] = $view->id() . ' (' . $base . ')';
    continue;
  }
  $rows[] = "[srsx-view]\t{$view->id()}\t{$base}\t{$matched}\t{$copied[$matched]}";
  fwrite(STDOUT, '[list-migrated-views] view: ' . $view->id()
    . '  base_table=' . $base . '  ' . $matched . ' -> ' . $copied[$matched] . "\n");
}

// Printed so "that view isn't really on Acquia Search" can be checked against
// the config rather than argued about: base_table is what decides.
if ($skipped) {
  fwrite(STDOUT, '[list-migrated-views] other Search API views, left alone ('
    . count($skipped) . "):\n");
  foreach ($skipped as $entry) {
    fwrite(STDOUT, "[list-migrated-views]   {$entry}\n");
  }
}

fwrite(STDOUT, '[list-migrated-views] ' . count($rows) . " view(s) to switch.\n");
foreach ($rows as $row) {
  fwrite(STDOUT, $row . "\n");
}
return 0;
