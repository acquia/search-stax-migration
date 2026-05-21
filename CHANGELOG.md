# Changelog

All notable changes to `acquia/search-stax-migration` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
