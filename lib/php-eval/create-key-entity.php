<?php

/**
 * @file
 * Create or update a Key entity holding the SearchStax analytics key.
 *
 * Requires the contrib `key` module to be installed.
 *
 * Uploaded to the target env by srsx-migrate and invoked via:
 *   drush php:script /tmp/srsx-<run>/create-key-entity.php -- <value_file> [key_id]
 *
 * The secret is uploaded to <value_file> on the env and the PATH is passed as
 * a php:script argument (drush's $extra array). The value itself never rides
 * argv (visible in `ps` and audit logs) or env vars (which do not survive the
 * acli/SSH hop). This script deletes <value_file> after reading it.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$extra = $extra ?? [];
$valueFile = $extra[0] ?? '';
$keyId = $extra[1] ?? 'searchstax_analytics_key';

if ($valueFile === '' || !is_file($valueFile)) {
  throw new \RuntimeException("[create-key-entity] Usage: drush php:script create-key-entity.php -- <value_file> [key_id]");
}
// Check preconditions BEFORE consuming the value file, so a failed run can
// be retried without re-uploading the secret.
if (!\Drupal::moduleHandler()->moduleExists('key')) {
  throw new \RuntimeException("[create-key-entity] The 'key' module is not enabled.");
}
$value = file_get_contents($valueFile);
@unlink($valueFile);
if ($value === FALSE || $value === '') {
  throw new \RuntimeException("[create-key-entity] Could not read a non-empty key value from {$valueFile}.");
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
return;
