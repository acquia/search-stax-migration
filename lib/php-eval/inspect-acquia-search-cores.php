<?php

/**
 * @file
 * Report the Acquia Search core IDs available/preferred for this site.
 *
 * `provision` invents SearchStax app names out of thin air
 * (${ACQUIA_APP}_${ACQUIA_TARGET_ENV}). The legacy Acquia Search core already
 * has a real, recognizable identifier assigned by Acquia
 * (PreferredCoreService::getPreferredCoreId(), e.g.
 * "WXYZ-12345.dev.mysitedev") — offer it as a naming candidate instead of a
 * guess. This never decides anything by itself; it only reports, and the
 * operator picks/edits in the shell.
 *
 * Alongside the human-readable report this emits tab-separated lines that
 * srsx-migrate's provision phase parses:
 *
 *   [srsx-acquia-core]<TAB>available<TAB>core_id<TAB>balancer_host
 *   [srsx-acquia-core]<TAB>available<TAB>NONE<TAB>
 *   [srsx-acquia-core]<TAB>preferred<TAB>server_id<TAB>core_id_or_empty
 *
 * Invoked via: drush php:script lib/php-eval/inspect-acquia-search-cores.php
 * (no SRSX_* input required).
 *
 * No `use` imports: php:eval evaluates a raw body where imports are illegal.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

if (!\Drupal::moduleHandler()->moduleExists('acquia_search')) {
  fwrite(STDOUT, "[acquia-cores] acquia_search not enabled — nothing to detect.\n");
  return 0;
}

if (!\Drupal::hasService('acquia_search.api_client')) {
  fwrite(STDOUT, "[acquia-cores] acquia_search.api_client service not found — nothing to detect.\n");
  return 0;
}

$cores = \Drupal::service('acquia_search.api_client')->getSearchIndexes();
if (empty($cores) || !is_array($cores)) {
  fwrite(STDOUT, "[acquia-cores] no Acquia Search cores reachable for this subscription.\n");
  fwrite(STDOUT, "[srsx-acquia-core]\tavailable\tNONE\t\n");
  return 0;
}

fwrite(STDOUT, '[acquia-cores] available cores (' . count($cores) . "):\n");
foreach ($cores as $coreId => $core) {
  $balancer = $core['balancer'] ?? '';
  fwrite(STDOUT, "[acquia-cores]   {$coreId}  balancer={$balancer}\n");
  fwrite(STDOUT, "[srsx-acquia-core]\tavailable\t{$coreId}\t{$balancer}\n");
}

// Per-server "preferred" match: which of the available cores this specific
// site's config would actually use. Only servers running the Acquia Search
// Solr backend can answer that; a plain search_api_solr server has no notion
// of a "preferred" core.
$backendClass = 'Drupal\acquia_search\Plugin\search_api\backend\AcquiaSearchSolrBackend';
$servers = \Drupal::entityTypeManager()->getStorage('search_api_server')->loadMultiple();
foreach ($servers as $server) {
  try {
    $backend = $server->getBackend();
  }
  catch (\Exception $e) {
    continue;
  }
  if (!$backend instanceof $backendClass) {
    continue;
  }
  // getPreferredCoreId() alone (no getSolrConnector() call) avoids opening a
  // real Solr connection just to read a name.
  $coreId = $backend->isPreferredCoreAvailable() ? $backend->getListOfPossibleCores() : [];
  $preferred = '';
  foreach ($coreId as $possible) {
    if (isset($cores[$possible])) {
      $preferred = $possible;
      break;
    }
  }
  fwrite(STDOUT, "[acquia-cores] server '{$server->id()}' preferred core: "
    . ($preferred ?: '(none matched)') . "\n");
  fwrite(STDOUT, "[srsx-acquia-core]\tpreferred\t{$server->id()}\t{$preferred}\n");
}

return 0;
