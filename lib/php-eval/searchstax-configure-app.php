<?php

/**
 * @file
 * Configure the SearchStax app so its collection is set up for Drupal.
 *
 * This is the step the migration was missing. Creating the Drupal-side server
 * config is only half of what the module's own migration does; the other half
 * is telling SearchStax which languages the app serves, which is what makes
 * SearchStax provision Drupal-compatible field types on the collection.
 * Without it the collection keeps the stock "default-config" schema, accepts
 * every document Drupal sends, and answers no query.
 *
 * Uses the searchstax module's own API client (service "searchstax.api", present
 * in every release) rather than reimplementing the REST calls. The auth token is
 * injected into the store that client reads, which is what
 * `drush searchstax:set-auth-token` does on releases new enough to have it.
 *
 * Invoked via:
 *   SRSX_SSX_TOKEN=<token> SRSX_SERVER_ID=<id> [SRSX_ACCOUNT=<name>] \
 *   [SRSX_APP_ID=<id>] drush php:script lib/php-eval/searchstax-configure-app.php
 *
 * No `use` statements: the body is wrapped in a closure where imports are
 * illegal, so classes are referenced fully qualified.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$token    = getenv('SRSX_SSX_TOKEN') ?: '';
$serverId = getenv('SRSX_SERVER_ID') ?: 'searchstax_server';
$account  = getenv('SRSX_ACCOUNT') ?: '';
$appId    = (int) (getenv('SRSX_APP_ID') ?: 0);

if ($token === '') {
  fwrite(STDERR, "[searchstax-configure-app] SRSX_SSX_TOKEN is required.\n");
  return 1;
}
if (!\Drupal::hasService('searchstax.api')) {
  fwrite(STDERR, "[searchstax-configure-app] ERR the searchstax module is not enabled here.\n");
  return 1;
}

// The client reads its token from this store; writing it here is a login as far
// as the client is concerned.
\Drupal::service('keyvalue.expirable')->get('searchstax')->setWithExpire(
  'api.auth_token',
  ['token' => $token, 'expire' => time() + 86400],
  86400
);

$api = \Drupal::service('searchstax.api');
if (!$api->isLoggedIn()) {
  fwrite(STDERR, "[searchstax-configure-app] ERR the injected token was not accepted.\n");
  return 1;
}

try {
  if ($account === '') {
    $accounts = array_keys($api->getAccounts());
    if (count($accounts) === 1) {
      $account = $accounts[0];
    }
    elseif (!$accounts) {
      fwrite(STDERR, "[searchstax-configure-app] ERR this login has no SearchStax accounts.\n");
      return 1;
    }
    else {
      fwrite(STDERR, "[searchstax-configure-app] ERR several accounts available; set SRSX_ACCOUNT to one of:\n");
      foreach ($accounts as $a) {
        fwrite(STDERR, "[searchstax-configure-app]   {$a}\n");
      }
      return 1;
    }
  }
  fwrite(STDOUT, "[searchstax-configure-app] account: {$account}\n");

  // Identify the app by the collection the Drupal server points at, so the
  // right one is configured when the account holds several.
  if ($appId === 0) {
    $server = \Drupal::entityTypeManager()->getStorage('search_api_server')->load($serverId);
    if (!$server) {
      fwrite(STDERR, "[searchstax-configure-app] ERR server not found: {$serverId}\n");
      return 1;
    }
    $connector = $server->getBackendConfig()['connector_config'] ?? [];
    $context = (string) ($connector['context'] ?? '');
    $core = (string) ($connector['core'] ?? '');
    if ($context === '' || $core === '') {
      fwrite(STDERR, "[searchstax-configure-app] ERR '{$serverId}' has no context/core to match on.\n");
      return 1;
    }
    foreach ($api->getApps($account) as $id => $app) {
      $endpoint = (string) ($app['update_endpoint'] ?? '');
      if (strpos($endpoint, "/{$context}/{$core}/") !== FALSE) {
        $appId = (int) $id;
        break;
      }
    }
    if ($appId === 0) {
      fwrite(STDERR, "[searchstax-configure-app] ERR no app in '{$account}' serves /{$context}/{$core}/.\n");
      fwrite(STDERR, "[searchstax-configure-app]   Set SRSX_APP_ID explicitly. Apps seen:\n");
      foreach ($api->getApps($account) as $id => $app) {
        fwrite(STDERR, "[searchstax-configure-app]   {$id}  " . ($app['name'] ?? '?')
          . '  ' . ($app['update_endpoint'] ?? '') . "\n");
      }
      return 1;
    }
  }
  fwrite(STDOUT, "[searchstax-configure-app] app id: {$appId}\n");

  // Only languages SearchStax offers can be enabled, so the site's languages
  // are intersected with that list rather than sent blindly.
  $available = $api->getAvailableLanguages($account, $appId);
  if (!$available) {
    fwrite(STDERR, "[searchstax-configure-app] ERR SearchStax listed no available languages.\n");
    return 1;
  }

  $siteLangcodes = array_keys(\Drupal::languageManager()->getLanguages());
  $wanted = array_values(array_intersect($siteLangcodes, array_keys($available)));
  if (!$wanted) {
    // A site whose langcode SearchStax does not offer still needs one enabled,
    // or the collection keeps the stock schema.
    $wanted = isset($available['en']) ? ['en'] : [array_key_first($available)];
    fwrite(STDOUT, "[searchstax-configure-app] no site language is offered by SearchStax; "
      . "falling back to '{$wanted[0]}'.\n");
  }

  $defaultLangcode = \Drupal::languageManager()->getDefaultLanguage()->getId();
  $languages = [];
  foreach ($wanted as $code) {
    $entry = [
      'name' => $available[$code],
      'language_code' => $code,
    ];
    if ($code === $defaultLangcode) {
      $entry['default'] = TRUE;
    }
    $languages[] = $entry;
  }
  // SearchStax requires exactly one default.
  if (!array_filter($languages, static fn(array $l): bool => !empty($l['default']))) {
    $languages[0]['default'] = TRUE;
  }

  fwrite(STDOUT, '[searchstax-configure-app] enabling language(s): '
    . implode(', ', array_column($languages, 'language_code')) . "\n");
  $api->setLanguages($account, $appId, $languages);
  fwrite(STDOUT, "[searchstax-configure-app] OK SearchStax accepted the language configuration.\n");
  fwrite(STDOUT, "[searchstax-configure-app]   The collection is rebuilt asynchronously; the\n");
  fwrite(STDOUT, "[searchstax-configure-app]   schema check that follows may need a moment.\n");
}
catch (\Exception $e) {
  fwrite(STDERR, "[searchstax-configure-app] ERR " . get_class($e) . ': '
    . $e->getMessage() . "\n");
  return 1;
}

return 0;
