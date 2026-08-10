<?php

/**
 * @file
 * Report where a service class really lives and what it really implements.
 *
 * Used when a container rebuild fails with "Service X must implement interface
 * EventSubscriberInterface". Drupal decides that by reflecting on the loaded
 * class, so the message means the class PHP loaded does not implement it —
 * which is usually not a defect in the module's source. This probe separates
 * the plausible causes: a stale opcache copy, a second copy of the module
 * shadowing the real one, or genuinely old code deployed to the environment.
 *
 * Invoked via srsx-migrate's drush_php helper with SRSX_CLASS set.
 *
 * No `use` statements: php:eval evaluates a raw body where imports are illegal.
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$class = getenv('SRSX_CLASS') ?: '';
if ($class === '') {
  fwrite(STDERR, "[inspect-service-class] SRSX_CLASS is required.\n");
  return 1;
}

if (!class_exists($class)) {
  fwrite(STDOUT, "[inspect-service-class] {$class}\n");
  fwrite(STDOUT, "[inspect-service-class]   NOT FOUND by the autoloader — the module providing it is missing or not registered.\n");
  return 0;
}

$interface = 'Symfony\Component\EventDispatcher\EventSubscriberInterface';
$reflection = new \ReflectionClass($class);
$file = $reflection->getFileName();
$loadedImplements = $reflection->implementsInterface($interface);

fwrite(STDOUT, "[inspect-service-class] {$class}\n");
fwrite(STDOUT, "[inspect-service-class]   file:              " . ($file ?: '(unknown)') . "\n");
fwrite(STDOUT, "[inspect-service-class]   loaded class implements EventSubscriberInterface: " . ($loadedImplements ? 'YES' : 'NO') . "\n");

if ($file && is_file($file)) {
  fwrite(STDOUT, "[inspect-service-class]   file last modified: " . date('c', filemtime($file)) . "\n");
  $source = file_get_contents($file);
  $sourceDeclares = strpos($source, 'EventSubscriberInterface') !== FALSE;
  fwrite(STDOUT, "[inspect-service-class]   file on disk mentions EventSubscriberInterface: " . ($sourceDeclares ? 'YES' : 'NO') . "\n");

  if (!$loadedImplements && $sourceDeclares) {
    fwrite(STDOUT, "[inspect-service-class]   DIAGNOSIS: the file on disk is correct but PHP is running an older\n");
    fwrite(STDOUT, "[inspect-service-class]              compiled copy. Clear the PHP opcache on this environment.\n");
  }
  elseif (!$loadedImplements && !$sourceDeclares) {
    fwrite(STDOUT, "[inspect-service-class]   DIAGNOSIS: the deployed file itself is out of date. The environment is\n");
    fwrite(STDOUT, "[inspect-service-class]              running older module code than your repository — redeploy it.\n");
  }
}

// A second copy of the module shadowing the real one produces the same symptom.
if (function_exists('drupal_get_path') || \Drupal::hasService('extension.list.module')) {
  try {
    $path = \Drupal::service('extension.list.module')->getPath('searchstax');
    fwrite(STDOUT, "[inspect-service-class]   searchstax module path: {$path}\n");
  }
  catch (\Throwable $e) {
    // Extension list is unavailable; the file path above is enough to go on.
  }
}

$info = \Drupal::service('extension.list.module')->getExtensionInfo('searchstax');
if (!empty($info['version'])) {
  fwrite(STDOUT, "[inspect-service-class]   searchstax version: {$info['version']}\n");
}

return 0;
