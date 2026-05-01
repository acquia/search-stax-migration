<?php

/**
 * @file
 * Create or update a Key entity holding the SearchStax analytics key.
 *
 * Requires the contrib `key` module to be installed.
 *
 * Invoked via:
 *   SRSX_KEY_VALUE=<secret> drush php:script lib/php-eval/create-key-entity.php
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$value = getenv('SRSX_KEY_VALUE') ?: '';
$keyId = getenv('SRSX_KEY_ID') ?: 'searchstax_analytics_key';

if ($value === '') {
  fwrite(STDERR, "[create-key-entity] SRSX_KEY_VALUE is required.\n");
  exit(1);
}
if (!\Drupal::moduleHandler()->moduleExists('key')) {
  fwrite(STDERR, "[create-key-entity] The 'key' module is not enabled.\n");
  exit(1);
}

$storage = \Drupal::entityTypeManager()->getStorage('key');
$entity = $storage->load($keyId);
if (!$entity) {
  $entity = $storage->create([
    'id' => $keyId,
    'label' => 'SearchStax Analytics Key',
    'description' => 'Analytics API key for SearchStax. Managed by srsx-migrate.',
    'key_type' => 'authentication',
    'key_provider' => 'config',
    'key_input' => 'text_field',
    'key_provider_settings' => ['key_value' => $value],
  ]);
} else {
  $settings = $entity->getKeyProviderSettings();
  $settings['key_value'] = $value;
  $entity->setKeyProviderSettings($settings);
}
$entity->save();
fwrite(STDOUT, "[create-key-entity] Saved key entity '{$keyId}'\n");
exit(0);
