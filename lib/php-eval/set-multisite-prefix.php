<?php

/**
 * @file
 * Set a per-site index_prefix on every SearchStax-backed Search-API index.
 *
 * For multisite installs sharing a single SearchStax app, each site needs a
 * distinct prefix so documents are namespaced and "results from this site
 * only" filtering works.
 *
 * Invoked via:
 *   SRSX_PREFIX=<prefix> drush php:script lib/php-eval/set-multisite-prefix.php
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$prefix = getenv('SRSX_PREFIX') ?: '';
if ($prefix === '') {
  fwrite(STDERR, "[set-multisite-prefix] SRSX_PREFIX is required.\n");
  return 1;
}
// Copies made by searchstax:copy-index are named "searchstax_index…", so they
// are found by which server they sit on rather than by any name suffix.
$server_id = getenv('SRSX_SERVER_ID') ?: 'searchstax_server';

$indexStorage = \Drupal::entityTypeManager()->getStorage('search_api_index');
$count = 0;
foreach ($indexStorage->loadMultiple() as $idx) {
  if ($idx->getServerId() !== $server_id) {
    continue;
  }
  // search_api_solr reads index_prefix from third-party settings
  // (Utility::getIndexSolrSettings() / SearchApiSolrBackend::getIndexId()),
  // not from the index's options bag — merge into 'advanced' so sibling keys
  // like 'collection' and 'timezone' survive.
  $advanced = $idx->getThirdPartySetting('search_api_solr', 'advanced') ?? [];
  $advanced['index_prefix'] = $prefix;
  $idx->setThirdPartySetting('search_api_solr', 'advanced', $advanced);
  // Drop the key earlier releases wrote to the options bag, where nothing
  // reads it, so config doesn't carry two prefixes that can disagree.
  $opts = $idx->getOptions();
  if (array_key_exists('index_prefix', $opts)) {
    unset($opts['index_prefix']);
    $idx->setOptions($opts);
  }
  $idx->save();
  $count++;
  fwrite(STDOUT, "[set-multisite-prefix] {$idx->id()} prefix='{$prefix}'\n");
}

fwrite(STDOUT, "[set-multisite-prefix] Updated {$count} index(es).\n");
return 0;
