# Changelog

All notable changes to `acquia/search-stax-migration` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `install.sh` — five runtime files were missing from the `FILES` manifest
  (`lib/php-eval/import-config-yaml.php`, `lib/php-eval/create-key-entity.php`,
  `lib/demo/bin/curl`, `lib/demo/bin/jq`, `.gitignore`), so real installs
  lacked the implementation of phase `server`, the default key-storage path of
  phase `route`, the demo network tripwire, and the ignore rules protecting
  `logs/`/`state/`/`migration.env`. A new manifest↔git drift test guards the list.
- PHP helpers are now uploaded to the target env (`/tmp/srsx-<run>/`) and
  receive parameters as `php:script` arguments. The previous laptop-local
  paths and `SRSX_*` environment variables never survive the
  `acli remote:drush` SSH hop, so phases `server`/`index`/`views`/`route`
  could not work against a real environment.
- `clone-index.php` called `UtilityService::cloneIndex()`, which does not
  exist in `drupal/searchstax` — the primary path fataled and the fallback was
  unreachable. It now uses `Index::createDuplicate()`, strips `acquia_search`
  third-party settings, records the pair via `addCopiedIndex()`, and is
  idempotent on re-runs.
- `switch-view-index.php` rewrote `display.*.query.options.index`, a key most
  Search-API views do not have, and reported success having changed nothing.
  It now ports the module's `SearchViewSwitchIndexForm`: switches the view's
  `base_table`, recursively switches every handler `table` key, records the
  original base table for rollback, and exits non-zero on a silent no-op.
- All PHP helpers called `exit()`, which `drush php:script` treats as abnormal
  termination — successful runs returned nonzero exit codes. Failures now
  throw; success paths return.
- Server template produced a non-functional server: `standard` connector (no
  SearchStax auth), the full endpoint URL in the `host` field, empty `core`,
  and the write token collected but never written anywhere. Now renders the
  `searchstax` connector with host/context/core parsed from the update
  endpoint (same regex the connector validates with) and `update_token` set.
  `sed` substitution (corrupted by `&`/`|` in values) replaced with pure-bash
  literal rendering.
- Preflight no longer mutates the environment. It ran `sapi-rt` + `sapi-i`
  while documented as read-only, before `backup` created a restore point, and
  without the prod guard. The baseline reindex moved to the start of phase
  `index`, behind the guard and an explicit confirm.
- `validate` no longer passes on empty data: a missing server list or zero
  SearchStax-backed indexes now fail. jq parse errors abort loudly instead of
  reading as "nothing to clone".
- `--dry-run` completes end-to-end (previously died in preflight on the empty
  command capture).
- Cleanup's `drush cex` wrote into the deployed (read-only) code tree; it now
  uses the same export-to-`/tmp` → tar-pull → `git add` flow as handoff.
- Cleanup referenced the nonexistent package `drupal/searchstax_solr_migration`
  (the migration submodule ships inside `drupal/searchstax`).
- Phase `install` now stages the new module code (not just
  `composer.json`/`lock`) on repos that track dependency code in git —
  classic Acquia deploys do not run `composer install`, so those repos
  deployed without the modules and the post-deploy `drush en` failed.
- Demo mode: the drush shim's cross-phase state moved out of
  `lib/demo/fixtures/` (which leaked state across runs) into the throwaway
  demo home; the index phase now exercises the real clone flow; the acli
  shim's backup handler matches the real command name
  (`database-backup-list`); resume hints no longer print `--demo` for real
  runs (`${DEMO:+...}` expands for `DEMO=0` too).
- `docs/QUICKSTART.md`: per-phase list matches `PHASE_ORDER` (`provision` was
  missing, backup/install order was flipped); validate's read-only claim
  names the actual read commands (`sapi-i` is the indexing action, not a
  read); wizard question count corrected.

- `install.sh` — `lib/searchstax_api.sh` was missing from the `FILES` list,
  causing `./srsx-migrate` to fail with `No such file or directory` on line 729.
- `install.sh` — file downloads now use the authenticated GitHub Contents API
  when `GITHUB_TOKEN` or `GH_TOKEN` is set, enabling installation from
  **private repositories** without manual steps. Public-repo installs are
  unaffected (token not set → falls back to `raw.githubusercontent.com`).
- `install.sh` — corrected two invalid fixture paths in the `FILES` list:
  `drush-sapi-i-progress.txt` (never existed) and `drush-config-get-views.json`
  (renamed to `drush-config-get.json`) were replaced with the actual filenames.

### Security
- Known secret values (tokens, analytics key, SearchStax password, session
  token) are redacted from all audit/dim output before it reaches the screen
  or the tee'd log; previously `drush cset … analytics_key <secret>` landed
  in `logs/*.log` in plaintext.
- `migration.env` is created with mode 600.
- SearchStax API request bodies (login password, app passwords) moved from
  curl argv — visible to `ps` — to stdin.
- The analytics key travels to the env as an uploaded file the PHP helper
  deletes after reading, never as a command-line argument.

### Added
- Phase `backup` now triggers the on-demand backup itself via
  `api:environments:database-list` + `database-backup-create`, polls
  `database-backup-list` until the newest backup completes (15-minute cap),
  and falls back to the manual Cloud-UI prompt if the API path fails.
- Production detection consults the Cloud API (`flags.production`) and
  recognizes ACSF `NNlive` environment names, on top of the existing name
  list.
- `REMOVE_ACQUIA_CONNECTOR` knob (default `0`): cleanup keeps
  `acquia_connector` unless explicitly opted in, since it serves Acquia
  products beyond Search.
- Regression tests: install-manifest drift, remote-transport contract,
  safety guards (read-only preflight, dry-run, ACSF names), and secret
  redaction.
- `provision` phase — creates SearchStax Site Search app(s) via the SearchStax REST API, then auto-populates `SEARCHSTAX_APP_ENDPOINT` for the `configure` phase. Auto-skipped in `--demo` mode or when an endpoint is already set. Session token cached in `state/searchstax.session` (chmod 600) to avoid burning a fresh 2FA TOTP on retries. Supersedes the standalone `create_apps.sh` proposal.
- Initial v1 release of the migration toolkit.
- `install.sh` — `curl | bash` installer that drops the toolkit into an Acquia repo.
- `srsx-migrate` — single-file Bash entry point with phases A–N.
- Demo mode (`--demo`) — PATH-shimmed mocks of `drush`/`composer`/`acli`/`git`
  with canned fixtures for safe team / management walkthroughs.
- Dry-run mode (`--dry-run`) — prints commands without executing.
- Semantic colour scheme (cyan / green / yellow / red / magenta / dim grey)
  with `NO_COLOR` and `--no-color` honoured.
- PHP-eval helpers for index cloning and view switching, calling the installed
  `solr_to_searchstax_ss_migration` module's `UtilityService` directly.
- Documentation set: README, QUICKSTART, PHASES, DEMO, SECURITY,
  TROUBLESHOOTING, ROLLBACK, MULTISITE, MAPPING.
- GitHub issue / PR templates and a CI workflow running `bash -n` + `shellcheck`.

[Unreleased]: https://github.com/acquia/search-stax-migration/compare/HEAD...HEAD
