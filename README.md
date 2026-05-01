# Acquia Search → SearchStax Migration Toolkit

[![CI](https://github.com/acquia/search-stax-migration/actions/workflows/ci.yml/badge.svg)](https://github.com/acquia/search-stax-migration/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Drupal 9 / 10 / 11](https://img.shields.io/badge/Drupal-9%20%7C%2010%20%7C%2011-blue.svg)](https://www.drupal.org/project/searchstax)

A scripted, auditable, idempotent runner for [Acquia's official "Migrating to Acquia Search powered by SearchStax" guide](https://docs.acquia.com/acquia-cloud-platform/migrating-acquia-search-powered-searchstax). Turns a multi-page click-through into a single command — without hiding what it does. Every step prints the underlying `drush`, `composer`, or `acli` invocation before executing.

> **Status:** v1 covers Drupal 9, 10, and 11 with Drush 11+. Drupal 7 is out of scope.

## Why this exists

The Acquia runbook is correct but long: roughly a dozen pages of UI clicks, drush commands, config edits, and view-rebinding instructions, repeated per environment and per site for multisite. Customers asked for something that:

- runs the same way every time,
- can be demoed and reviewed before production,
- backs up everything it touches,
- can be rolled back in one command,
- and never silently does something that isn't in the docs.

That's this toolkit.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/acquia/search-stax-migration/main/install.sh | bash
```

This drops a self-contained toolkit at `tools/searchstax-migration/` inside your Drupal repository (sibling of `docroot/`). Run it from your Cloud IDE, DDEV, Lando, or local clone — anywhere `composer.json` is writable.

Prefer to install at a specific path or pin to a tag:

```bash
curl -fsSL https://raw.githubusercontent.com/acquia/search-stax-migration/main/install.sh \
  | bash -s -- --target /path/to/repo --ref v1.0.0
```

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for the 60-second walkthrough.

## The three buttons

| If you want to…                          | Read                                            |
| ---------------------------------------- | ----------------------------------------------- |
| Get going fast                           | [docs/QUICKSTART.md](docs/QUICKSTART.md)        |
| See it run with no real environment      | [docs/DEMO.md](docs/DEMO.md)                    |
| Recover from a bad migration             | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |

## What it does — one phase at a time

| Phase       | Drupal/Acquia change                                                         | Acquia doc page                                                                                                                                    |
| ----------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `preflight` | Verify acli auth + Drupal/Drush on the target Acquia env, inventory Solr setup | [Preparing for migration](https://docs.acquia.com/acquia-cloud-platform/preparing-migration-acquia-search-powered-searchstax)                       |
| `install`   | `composer require drupal/searchstax`; `drush en searchstax …`                | [Installing the SearchStax module](https://docs.acquia.com/acquia-cloud-platform/installing-searchstax-module)                                      |
| `backup`    | Trigger an on-demand Acquia DB backup (your safety net)                      | [Preparing for migration](https://docs.acquia.com/acquia-cloud-platform/preparing-migration-acquia-search-powered-searchstax)                       |
| `configure` | Prompt for SearchStax credentials; store via Key module                      | [Enabling the module + routing](https://docs.acquia.com/acquia-cloud-platform/enabling-searchstax-module-and-routing-searches-through-it)           |
| `server`    | Create the SearchStax-backed `search_api` server                             | [Migrating the server](https://docs.acquia.com/acquia-cloud-platform/migrating-server-drupal-acquia-search-powered-searchstax)                      |
| `index`     | Clone each legacy index → SearchStax twin; reindex                           | [Migrating the index](https://docs.acquia.com/acquia-cloud-platform/migrating-index-drupal-acquia-search-powered-searchstax)                        |
| `views`     | Repoint every Search-API view at its new index                               | [Migrating the views](https://docs.acquia.com/acquia-cloud-platform/migrating-views-drupal-acquia-search-powered-searchstax)                        |
| `route`     | `searches_via_searchstudio = 1` + analytics URL/key                          | [Enabling the module + routing](https://docs.acquia.com/acquia-cloud-platform/enabling-searchstax-module-and-routing-searches-through-it)           |
| `validate`  | Server URL, item counts, view bindings                                       | [Validating the search page](https://docs.acquia.com/acquia-cloud-platform/validating-search-page)                                                  |
| `handoff`   | drush cex on target via `acli ssh` + tar pull → `git add` (no commit, no push) | [Committing and deploying](https://docs.acquia.com/acquia-cloud-platform/committing-and-deploying-changes)                                          |
| `cleanup`   | Uninstall migration submodule; remove `acquia_search` + `acquia_connector`   | [Removing legacy module + config](https://docs.acquia.com/acquia-cloud-platform/removing-legacy-search-module-and-configuration)                    |

Run them individually (`./srsx-migrate preflight`) or end-to-end (`./srsx-migrate all`).

## Safety

- Every phase prints the underlying command (`+ drush …`) before executing.
- `--dry-run` runs against the real environment but only prints commands.
- `--demo` runs against canned fixtures, with no real environment touched at all. PATH is shimmed with mock `drush`/`composer`/`acli`/`git`.
- Phase `backup` triggers an on-demand Acquia DB backup. If the migration goes wrong on dev/stage, restore via `acli pull:db` + `git revert` — see [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
- Secrets prompted via `read -s` are held in memory only, never written to `migration.env`.
- Secrets prompted via `read -s` are held in memory only, never written to `migration.env`.
- Recommended (and the default): store the SearchStax analytics key as a [Key module](https://www.drupal.org/project/key) entity, per the Acquia documentation.

See [docs/SECURITY.md](docs/SECURITY.md) for the full statement.

## Documentation

- [docs/QUICKSTART.md](docs/QUICKSTART.md) — install and run in five minutes.
- [docs/PHASES.md](docs/PHASES.md) — what each phase does, command-by-command.
- [docs/DEMO.md](docs/DEMO.md) — running the toolkit with no real environment.
- [docs/MAPPING.md](docs/MAPPING.md) — line-by-line: Acquia doc → toolkit phase.
- [docs/SECURITY.md](docs/SECURITY.md) — secret handling, audit log, what we don't store.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common failure modes, the fix, and how to roll back via `acli pull:db` + `git revert`.

## Maintainership and support

Maintained by **Mohammad Zomorodian, Acquia Inc.** This is an Acquia-staff-driven open source project; pull requests welcome.

| Issue type                          | Where to go                                                              |
| ----------------------------------- | ------------------------------------------------------------------------ |
| Bug in this toolkit                 | [GitHub Issues](https://github.com/acquia/search-stax-migration/issues)  |
| Production migration help           | Your Acquia TAM or Acquia Support                                        |
| SearchStax product / index issues   | [SearchStax Support](https://support.searchstax.com)                     |
| Acquia Search shutdown timeline     | Your Acquia account team                                                 |

See [AUTHORS.md](AUTHORS.md) for contributors and the support routing table.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). All PRs run shellcheck, the demo smoke test, and a docs-drift check via the [CI workflow](.github/workflows/ci.yml).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
