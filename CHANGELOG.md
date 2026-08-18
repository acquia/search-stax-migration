# Changelog

All notable changes to `acquia/search-stax-migration` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Multisite installs were not isolated from each other. The server's "Retrieve
  results for this site only" option (`site_hash`) was never turned on, and the
  per-site `index_prefix` was written to the index's options bag instead of
  `third_party_settings.search_api_solr.advanced`, where `search_api_solr`
  actually reads it — so the prefix silently had no effect. Both now apply to
  every site in a multisite run. `site_hash` is only ever written to turn the
  option **on**, so a value set by hand in the UI survives a re-run.
- `_ssx_site_prefix()` now derives the prefix from the site's first hostname
  label (e.g. `dmv` for `dmv.dev-nhdoit.acsitefactory.com`) instead of
  slugifying the entire host. If any two sites would reduce to the same label,
  every site falls back to the full-host prefix and the run warns — a shared
  prefix would silently undo the separation the prefix exists to provide.

### Changed
- Copied indexes on sites that **share** a SearchStax app now have "Index items
  immediately" (`index_directly`) turned off, batching indexing to cron so
  concurrent per-save writes from sibling sites don't pile onto one app. This
  delays when saved content becomes searchable; set `SRSX_KEEP_INDEX_DIRECTLY=1`
  to opt out. Sites with a dedicated app are left alone.

### Upgrade notes
- Already-migrated sites: `clone-index.php` skips indexes it has already copied,
  so re-running `index` will not apply the `index_directly` change to them — set
  it in the UI if you want it. Re-running does rewrite `index_prefix`, and
  because the derivation changed the new prefix will differ from the old one;
  documents indexed under the previous prefix are orphaned until you reindex.
- **Documentation claimed the `backup` phase created a database backup. It does
  not** — it prints instructions and blocks on a confirmation it cannot verify.
  README, QUICKSTART, PHASES, and SECURITY all said otherwise. Corrected
  everywhere; this was the most dangerous inaccuracy in the docs.
- `install` was documented as `composer require drupal/searchstax` plus
  `drush en`. It actually requires four packages, **commits and pushes a git
  branch**, and waits for you to deploy it in the Acquia Cloud UI. Documented.
- The `solrconfig` phase was missing from the README phase table entirely, and
  the table listed `install` before `backup` while the code runs `backup` first.
- `cleanup` was documented as taking a `pre-cleanup` snapshot. It does not.
- `SECURITY.md` claimed secrets are never written to disk. Corrected: phase
  `provision` persists app tokens to `migration.env`, and remote PHP helpers
  transit a short-lived file under `/tmp/srsx-<pid>/` on the target environment.
  These caveats now live in the README "Safety" section.
- Removed a non-existent security contact address. Report security concerns as
  GitHub issues.
- Removed a duplicated bullet from the README safety list.

### Changed
- Documentation consolidated. `docs/` is now QUICKSTART, PHASES, and
  TROUBLESHOOTING; the repository root is README, CHANGELOG, CONTRIBUTING,
  LICENSE. `docs/DEMO.md` folded into `docs/QUICKSTART.md`, `docs/MAPPING.md`
  into `docs/PHASES.md`, `AUTHORS.md` and `docs/SECURITY.md` into `README.md`,
  and `DEVELOPMENT.md` into `CONTRIBUTING.md`.
- The private-repository install instructions were removed from the docs now
  that the repository is public. `install.sh` still honours `GITHUB_TOKEN`.
- `tests/generate-docs.sh` now also enforces that every phase appears in the
  README table **in execution order** and in the QUICKSTART phase list, that
  every dispatchable subcommand is documented, and that every relative markdown
  link resolves. It runs on `make check`, not just in CI.

### Fixed (earlier)
- `install.sh` — `lib/searchstax_api.sh` was missing from the `FILES` list,
  causing `./srsx-migrate` to fail with `No such file or directory` on line 729.
- `install.sh` — file downloads now use the authenticated GitHub Contents API
  when `GITHUB_TOKEN` or `GH_TOKEN` is set, enabling installation from
  **private repositories** without manual steps. Public-repo installs are
  unaffected (token not set → falls back to `raw.githubusercontent.com`).
- `install.sh` — corrected two invalid fixture paths in the `FILES` list:
  `drush-sapi-i-progress.txt` (never existed) and `drush-config-get-views.json`
  (renamed to `drush-config-get.json`) were replaced with the actual filenames.

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
- PHP-eval helpers for index cloning and view switching, driving the installed
  `solr_to_searchstax_ss_migration` module's own service where it exists and
  performing the same work inline on releases that do not ship it.
- Documentation set: README, QUICKSTART, PHASES, SECURITY, TROUBLESHOOTING.
- GitHub issue / PR templates and a CI workflow running `bash -n` + `shellcheck`.

[Unreleased]: https://github.com/acquia/search-stax-migration/compare/HEAD...HEAD
