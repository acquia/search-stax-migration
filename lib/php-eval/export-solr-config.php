<?php

/**
 * @file
 * Write the Solr config set search_api_solr generates for a server.
 *
 * A hosted Solr collection created from a stock template runs the
 * "default-config" schema, which accepts indexed documents and then answers no
 * search_api query — Drupal reports it as "You are using an incompatible Solr
 * schema". The fix is to install the config set generated here, which is the
 * same one behind the "Get config.zip" button on the server's admin page.
 *
 * Generating it from the SearchStax server (not the legacy one) matters: the
 * connector's alterConfigFiles() adjusts solrconfig.xml for SolrCloud and
 * stamps the schema version the connector reports.
 *
 * Invoked via:
 *   SRSX_SERVER_ID=<id> SRSX_OUT_DIR=<dir> \
 *     drush php:script lib/php-eval/export-solr-config.php
 *
 * No `use` statements: the body is wrapped in a closure where imports are
 * illegal, so classes are referenced fully qualified.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$serverId = getenv('SRSX_SERVER_ID') ?: 'searchstax_server';
$outDir   = getenv('SRSX_OUT_DIR') ?: '';

if ($outDir === '') {
  fwrite(STDERR, "[export-solr-config] SRSX_OUT_DIR is required.\n");
  return 1;
}

$server = \Drupal::entityTypeManager()
  ->getStorage('search_api_server')
  ->load($serverId);
if (!$server) {
  fwrite(STDERR, "[export-solr-config] ERR server not found: {$serverId}\n");
  return 1;
}

if (!\Drupal::hasService('search_api_solr.configset_controller')) {
  fwrite(STDERR, "[export-solr-config] ERR search_api_solr does not expose\n");
  fwrite(STDERR, "[export-solr-config]   'search_api_solr.configset_controller' on this site.\n");
  fwrite(STDERR, "[export-solr-config]   Use the 'Get config.zip' button on the server's admin page instead.\n");
  return 1;
}

$controller = \Drupal::service('search_api_solr.configset_controller');
$controller->setServer($server);

try {
  $files = $controller->getConfigFiles();
}
catch (\Exception $e) {
  fwrite(STDERR, "[export-solr-config] ERR could not generate the config set: "
    . $e->getMessage() . "\n");
  return 1;
}

if (!$files) {
  fwrite(STDERR, "[export-solr-config] ERR the generated config set is empty.\n");
  return 1;
}

if (!is_dir($outDir) && !mkdir($outDir, 0777, TRUE) && !is_dir($outDir)) {
  fwrite(STDERR, "[export-solr-config] ERR could not create {$outDir}\n");
  return 1;
}

$written = 0;
foreach ($files as $name => $content) {
  // Guard against a name escaping the output directory.
  $safe = basename((string) $name);
  if ($safe === '' || $safe === '.' || $safe === '..') {
    continue;
  }
  if (file_put_contents($outDir . '/' . $safe, $content) === FALSE) {
    fwrite(STDERR, "[export-solr-config] ERR could not write {$safe}\n");
    return 1;
  }
  $written++;
  fwrite(STDOUT, sprintf("[export-solr-config]   %-28s %7d bytes\n", $safe, strlen($content)));
}

// The schema name is what Drupal compares against; printing it here means the
// upload can be verified against the exact value that was generated.
$schemaName = '(unknown)';
if (isset($files['schema.xml'])
  && preg_match('/<schema\s+name="([^"]+)"/', $files['schema.xml'], $m)) {
  $schemaName = $m[1];
}

fwrite(STDOUT, "[export-solr-config] server: {$serverId}\n");
fwrite(STDOUT, "[export-solr-config] schema name: {$schemaName}\n");
fwrite(STDOUT, "[export-solr-config] wrote {$written} file(s) to {$outDir}\n");
return 0;
