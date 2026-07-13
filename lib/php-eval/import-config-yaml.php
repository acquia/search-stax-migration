<?php

/**
 * @file
 * Import a single rendered YAML file into Drupal active config.
 *
 * Uploaded to the target env by srsx-migrate and invoked via:
 *   drush php:script /tmp/srsx-<run>/import-config-yaml.php -- <yaml_file> <config_name>
 *
 * Parameters arrive as php:script arguments (drush's $extra array), NOT as
 * environment variables — client env does not survive the acli/SSH hop. The
 * YAML file is uploaded to the env alongside this script for the same reason.
 *
 * Used by Phase 'server' to install search_api.server.<id> from the templated
 * YAML rendered under artifacts/.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

use Symfony\Component\Yaml\Yaml;

$extra = $extra ?? [];
$file = $extra[0] ?? '';
$name = $extra[1] ?? '';

if ($file === '' || $name === '') {
  fwrite(STDERR, "[import-config-yaml] Usage: drush php:script import-config-yaml.php -- <yaml_file> <config_name>\n");
  exit(1);
}
if (!is_file($file)) {
  fwrite(STDERR, "[import-config-yaml] File not found: {$file}\n");
  exit(1);
}

$data = Yaml::parseFile($file);
\Drupal::configFactory()->getEditable($name)->setData($data)->save();
fwrite(STDOUT, "[import-config-yaml] Imported {$name} from {$file}\n");
exit(0);
