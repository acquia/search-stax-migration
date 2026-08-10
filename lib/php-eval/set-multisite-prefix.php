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

$indexStorage = \Drupal::entityTypeManager()->getStorage('search_api_index');
$count = 0;
foreach ($indexStorage->loadMultiple() as $idx) {
  if (substr($idx->id(), -11) !== '_searchstax') {
    continue;
  }
  $opts = $idx->getOptions();
  $opts['index_prefix'] = $prefix;
  $idx->setOptions($opts);
  $idx->save();
  $count++;
  fwrite(STDOUT, "[set-multisite-prefix] {$idx->id()} prefix='{$prefix}'\n");
}

fwrite(STDOUT, "[set-multisite-prefix] Updated {$count} index(es).\n");
return 0;
