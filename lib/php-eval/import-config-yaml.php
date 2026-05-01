<?php

/**
 * @file
 * Import a single rendered YAML file into Drupal active config.
 *
 * Invoked via:
 *   SRSX_YAML_FILE=<path> SRSX_CONFIG_NAME=<name> \
 *     drush php:script lib/php-eval/import-config-yaml.php
 *
 * Used by Phase 'server' to install search_api.server.<id> from the templated
 * YAML written under artifacts/.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

use Symfony\Component\Yaml\Yaml;

$file = getenv('SRSX_YAML_FILE') ?: '';
$name = getenv('SRSX_CONFIG_NAME') ?: '';

if ($file === '' || $name === '') {
  fwrite(STDERR, "[import-config-yaml] SRSX_YAML_FILE and SRSX_CONFIG_NAME are required.\n");
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
