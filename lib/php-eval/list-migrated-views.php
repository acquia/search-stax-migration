<?php

/**
 * @file
 * Inventory every Search-API view and say which ones move to SearchStax.
 *
 * A view's index is not a matter of opinion: Views stores it in `base_table`
 * (search_api_index_<id>, or search_api_datasource_<id>_<datasource>), and no
 * display can override it. So every Search API view is reported with the index
 * it sits on, the server behind that index and that server's backend — which is
 * what decides whether a view is "Acquia Search" or "DB search" — together with
 * the action the migration will take on it.
 *
 * Only views on an index recorded in the module's copied_indexes map are
 * switched. The mapping is read from that record rather than guessed from index
 * names: copies are called "searchstax_index…", not "<original>_searchstax".
 *
 * Emits tab-separated rows the views phase consumes:
 *
 *   [srsx-view]<TAB>view_id<TAB>base_table<TAB>old_index<TAB>new_index
 *
 * Set SRSX_REPORT_ONLY=1 for the inventory alone (no rows, never fails).
 *
 * Invoked via srsx-migrate's drush_php helper, which sets SRSX_* via putenv().
 *
 * No `use` statements: the body is wrapped in a closure where imports are
 * illegal, so classes are referenced fully qualified.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$reportOnly = getenv('SRSX_REPORT_ONLY') === '1';

if (!\Drupal::moduleHandler()->moduleExists('views')) {
  fwrite(STDOUT, "[list-migrated-views] The views module is not enabled; nothing to switch.\n");
  return 0;
}

$copied = [];
$utility = NULL;
if (\Drupal::hasService('solr_to_searchstax_ss_migration.utility')) {
  $utility = \Drupal::service('solr_to_searchstax_ss_migration.utility');
  $copied = $utility->getCopiedIndexes();
}

$entityTypeManager = \Drupal::entityTypeManager();
$indexes = $entityTypeManager->getStorage('search_api_index')->loadMultiple();
$servers = $entityTypeManager->getStorage('search_api_server')->loadMultiple();

// Index IDs and datasource names both contain underscores, so the index behind
// a base table is found by testing the known IDs against it, not by splitting.
$resolveIndex = function (string $base) use ($indexes): string {
  foreach (array_keys($indexes) as $id) {
    if (preg_match('/^search_api_(?:index|datasource)_' . preg_quote($id, '/') . '(_\w+)?$/', $base)) {
      return $id;
    }
  }
  return '';
};

$rows = [];
$reported = 0;
$pending = 0;
$originals = $utility ? $utility->getOriginalBaseTables() : [];
$switchedTo = array_flip($copied);
fwrite(STDOUT, "[list-migrated-views] Search API views on this site:\n");
foreach ($entityTypeManager->getStorage('view')->loadMultiple() as $view) {
  $base = $view->get('base_table');
  if (!is_string($base) || strpos($base, 'search_api_') !== 0) {
    continue;
  }
  $reported++;

  $indexId = $resolveIndex($base);
  $serverId = '';
  $backend = '';
  if ($indexId !== '' && isset($indexes[$indexId])) {
    $serverId = $indexes[$indexId]->getServerId() ?: '';
    if ($serverId !== '' && isset($servers[$serverId])) {
      $backend = $servers[$serverId]->getBackendId() ?: '';
    }
  }

  if ($indexId === '') {
    $action = 'leave (index behind ' . $base . ' not found)';
  }
  elseif (isset($copied[$indexId])) {
    $action = 'SWITCH -> ' . $copied[$indexId];
    $rows[] = "[srsx-view]\t{$view->id()}\t{$base}\t{$indexId}\t{$copied[$indexId]}";
  }
  elseif (isset($switchedTo[$indexId])) {
    $action = 'done (already on SearchStax)';
  }
  elseif ($serverId === '') {
    $action = 'leave (index is on no server)';
  }
  elseif ($backend === 'search_api_db') {
    $action = 'leave (database search, not Acquia Search)';
  }
  elseif ($utility && isset($servers[$serverId])
    && $utility->isNonSearchStaxSolrServer($servers[$serverId])) {
    // Acquia Search, and therefore in scope: it is only waiting on the copy.
    $action = 'PENDING (Acquia Search — switches once the index phase copies '
      . $indexId . ')';
    $pending++;
  }
  else {
    $action = 'leave (index not copied)';
  }

  // The base table each view had before the migration touched it. This is the
  // record of what a switched view actually came from, so "that one was a
  // database view" can be checked instead of reconstructed from memory.
  $was = '';
  if (isset($originals[$view->id()]) && $originals[$view->id()] !== $base) {
    $was = '  was=' . $originals[$view->id()];
  }

  fwrite(STDOUT, '[list-migrated-views]   ' . $view->id()
    . '  index=' . ($indexId ?: '(unknown)')
    . '  server=' . ($serverId ?: '(none)')
    . '  backend=' . ($backend ?: '(none)')
    . '  base_table=' . $base
    . $was
    . '  => ' . $action . "\n");
}

if ($reported === 0) {
  fwrite(STDOUT, "[list-migrated-views]   (none)\n");
}

if ($pending > 0) {
  fwrite(STDOUT, "[list-migrated-views] {$pending} view(s) are on Acquia Search and still have to move.\n");
  fwrite(STDOUT, "[list-migrated-views]   They switch automatically once the index phase copies their\n");
  fwrite(STDOUT, "[list-migrated-views]   index; leaving them behind would strand them on the old server.\n");
}

if (!$copied) {
  fwrite($reportOnly ? STDOUT : STDERR,
    "[list-migrated-views] No copied indexes are recorded yet. Run the index phase first.\n");
  return $reportOnly ? 0 : 1;
}

fwrite(STDOUT, '[list-migrated-views] copied indexes: '
  . implode(', ', array_map(
      static function ($from, $to) {
        return "{$from} -> {$to}";
      },
      array_keys($copied),
      $copied
    )) . "\n");
fwrite(STDOUT, '[list-migrated-views] ' . count($rows) . " view(s) to switch.\n");

if (!$reportOnly) {
  foreach ($rows as $row) {
    fwrite(STDOUT, $row . "\n");
  }
}

return 0;
