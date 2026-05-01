<?php

/**
 * @file
 * Repoint every Search-API view from a legacy index to its SearchStax twin.
 *
 * Mapping rule: <legacy_id>  ->  <legacy_id>_searchstax (matches clone-index.php)
 *
 * Drupal stores the bound index in:
 *   views.view.<id>:display.<display>.display_options.query.options.index
 *
 * Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)
 */

$config_factory = \Drupal::configFactory();
$entity_type_manager = \Drupal::entityTypeManager();

// Build legacy → new map by reading every searchstax-server-backed index.
$indexStorage = $entity_type_manager->getStorage('search_api_index');
$map = [];
foreach ($indexStorage->loadMultiple() as $idx) {
  $id = $idx->id();
  if (substr($id, -11) === '_searchstax') {
    $legacy = substr($id, 0, -11);
    $map[$legacy] = $id;
  }
}

if (!$map) {
  fwrite(STDERR, "[switch-view-index] No '*_searchstax' indexes found. Run clone-index.php first.\n");
  exit(1);
}

$changed = 0;
foreach ($config_factory->listAll('views.view.') as $name) {
  $cfg = $config_factory->getEditable($name);
  $displays = $cfg->get('display') ?: [];
  $touched = FALSE;

  foreach ($displays as $display_id => $display) {
    $bound = $display['display_options']['query']['options']['index'] ?? NULL;
    if ($bound && isset($map[$bound])) {
      $cfg->set("display.{$display_id}.display_options.query.options.index", $map[$bound]);
      $touched = TRUE;
      fwrite(STDOUT, "[switch-view-index] {$name}:{$display_id}  {$bound} -> {$map[$bound]}\n");
    }
  }

  if ($touched) {
    $cfg->save();
    $changed++;
  }
}

fwrite(STDOUT, "[switch-view-index] Updated {$changed} view config object(s).\n");
exit(0);
