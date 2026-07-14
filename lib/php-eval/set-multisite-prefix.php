<?php

/**
 * @file
 * Set a per-site index_prefix on every SearchStax-backed Search-API index.
 *
 * For multisite installs sharing a single SearchStax app, each site needs a
 * distinct prefix so documents are namespaced and "results from this site
 * only" filtering works.
 *
 * Uploaded to the target env by srsx-migrate and invoked via:
 *   drush php:script /tmp/srsx-<run>/set-multisite-prefix.php -- <prefix>
 *
 * The prefix arrives as a php:script argument (drush's $extra array), NOT as
 * an environment variable — client env does not survive the acli/SSH hop.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$extra = $extra ?? [];
$prefix = $extra[0] ?? '';
if ($prefix === '') {
  throw new \RuntimeException("[set-multisite-prefix] Usage: drush php:script set-multisite-prefix.php -- <prefix>");
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
return;
