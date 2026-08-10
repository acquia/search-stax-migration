<?php

/**
 * @file
 * Import a rendered YAML config object into Drupal active config.
 *
 * Invoked via srsx-migrate's drush_php helper, which sends this body to
 * `drush php:eval` on the remote environment with SRSX_* set via putenv():
 *   SRSX_YAML_CONTENT  the rendered YAML itself (the toolkit is not deployed
 *                      to the remote host, so a local path is unreadable there)
 *   SRSX_CONFIG_NAME   e.g. search_api.server.searchstax_server
 *
 * Used by Phase 'server' to install search_api.server.<id> from the templated
 * YAML written under artifacts/.
 *
 * No `use` statements: php:eval evaluates a raw body where imports are not
 * allowed, so classes are referenced fully qualified.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$yaml = getenv('SRSX_YAML_CONTENT') ?: '';
$name = getenv('SRSX_CONFIG_NAME') ?: '';

if ($yaml === '' || $name === '') {
  fwrite(STDERR, "[import-config-yaml] SRSX_YAML_CONTENT and SRSX_CONFIG_NAME are required.\n");
  return 1;
}

$data = \Symfony\Component\Yaml\Yaml::parse($yaml);
if (!is_array($data)) {
  fwrite(STDERR, "[import-config-yaml] YAML did not parse into a config array.\n");
  return 1;
}

\Drupal::configFactory()->getEditable($name)->setData($data)->save();
fwrite(STDOUT, "[import-config-yaml] Imported {$name}\n");
return 0;
