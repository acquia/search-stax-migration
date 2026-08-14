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

**Run this from an [Acquia Cloud IDE](https://docs.acquia.com/acquia-cloud-platform/add-ons/cloud-ide).** That is what the toolkit is designed for: `acli`, `git`, `composer`, `jq`, and PHP are already installed and `acli` is already authenticated against your applications, so there is nothing to set up.

From the root of your Drupal repository (where `composer.json` lives):

```bash
curl -fsSL https://raw.githubusercontent.com/acquia/search-stax-migration/main/install.sh | bash
cd tools/searchstax-migration
```

This drops a self-contained toolkit at `tools/searchstax-migration/` inside your Drupal repository (sibling of `docroot/`).

Running it locally (or in DDEV/Lando) works too — nothing is Cloud-IDE-specific — but you have to prepare the environment yourself: install `bash` 4+, `git`, `composer`, `jq`, and `acli`, then run `acli auth:login`. See [docs/QUICKSTART.md](docs/QUICKSTART.md).

To install at a specific path or pin to a tag:

```bash
curl -fsSL https://raw.githubusercontent.com/acquia/search-stax-migration/main/install.sh \
  | bash -s -- --target /path/to/repo --ref v1.0.0
```

**Nervous? Start here instead** — `./srsx-migrate --demo` runs the entire
migration against canned fixtures, with no network calls and nothing in your
real environment touched. See [docs/QUICKSTART.md](docs/QUICKSTART.md).

## The three buttons

| If you want to…                          | Read                                            |
| ---------------------------------------- | ----------------------------------------------- |
| Get going fast                           | [docs/QUICKSTART.md](docs/QUICKSTART.md)        |
| Know exactly what a phase will do        | [docs/PHASES.md](docs/PHASES.md)                |
| Recover from a bad migration             | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |

## What it does — one phase at a time

| Phase       | Drupal/Acquia change                                                         | Acquia doc page                                                                                                                                    |
| ----------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `preflight` | Verify acli auth + Drupal/Drush on the target Acquia env, inventory Solr setup | [Preparing for migration](https://docs.acquia.com/acquia-cloud-platform/preparing-migration-acquia-search-powered-searchstax)                       |
| `backup`    | **Stops and makes you confirm** you took an on-demand DB backup in the Cloud UI. The toolkit does not take it for you | [Preparing for migration](https://docs.acquia.com/acquia-cloud-platform/preparing-migration-acquia-search-powered-searchstax) |
| `install`   | `composer require` search_api, search_api_solr, searchstax, key; **commits and pushes a branch**; waits for you to deploy it; then `drush en` per site | [Installing the SearchStax module](https://docs.acquia.com/acquia-cloud-platform/installing-searchstax-module)                                      |
| `provision` | Create SearchStax app(s) via REST API; auto-populates endpoint. Skipped if `SEARCHSTAX_APP_ENDPOINT` already set or in `--demo` | (SearchStax-side — no public Acquia doc)                                                                                                            |
| `configure` | Prompt for SearchStax credentials; store via Key module                      | [Enabling the module + routing](https://docs.acquia.com/acquia-cloud-platform/enabling-searchstax-module-and-routing-searches-through-it)           |
| `server`    | Create the SearchStax-backed `search_api` server                             | [Migrating the server](https://docs.acquia.com/acquia-cloud-platform/migrating-server-drupal-acquia-search-powered-searchstax)                      |
| `solrconfig`| Make the SearchStax collection run a Drupal-compatible schema, and refuse to continue until it does | (SearchStax-side — no public Acquia doc)                                                    |
| `index`     | Clone each legacy index → SearchStax twin; reindex                           | [Migrating the index](https://docs.acquia.com/acquia-cloud-platform/migrating-index-drupal-acquia-search-powered-searchstax)                        |
| `views`     | Repoint every Search-API view at its new index                               | [Migrating the views](https://docs.acquia.com/acquia-cloud-platform/migrating-views-drupal-acquia-search-powered-searchstax)                        |
| `route`     | `searches_via_searchstudio = 1` + analytics URL/key                          | [Enabling the module + routing](https://docs.acquia.com/acquia-cloud-platform/enabling-searchstax-module-and-routing-searches-through-it)           |
| `validate`  | Server URL, item counts, view bindings                                       | [Validating the search page](https://docs.acquia.com/acquia-cloud-platform/validating-search-page)                                                  |
| `handoff`   | drush cex on target via `acli ssh` + tar pull → `git add` (no commit, no push) | [Committing and deploying](https://docs.acquia.com/acquia-cloud-platform/committing-and-deploying-changes)                                          |
| `cleanup`   | Uninstall migration submodule; remove `acquia_search` + `acquia_connector`   | [Removing legacy module + config](https://docs.acquia.com/acquia-cloud-platform/removing-legacy-search-module-and-configuration)                    |

Run them individually (`./srsx-migrate preflight`) or end-to-end (`./srsx-migrate all`).

## What it does not do

- **It does not back up your database.** Phase `backup` asks you to do it and cannot verify your answer.
- **It does not deploy.** Phase `install` pushes a branch; *you* deploy it in the Acquia Cloud UI. Phase `handoff` stages config with `git add` and stops — no commit, no push.
- **It does not touch production.** Every mutating phase refuses to run against a prod-like environment. Only `validate` may target prod, and it is read-only.
- **It has no automated rollback.** Recovery is `acli pull:db` + `git revert`.
- **It does not support Drupal 7.**
- **It does not move database-backed search.** Indexes on `search_api_db` or on no server at all are left alone unless you force them.

## Useful commands

```bash
./srsx-migrate status              # "you are at X; next: Y"
./srsx-migrate doctor              # read-only: what each index and view is really attached to
./srsx-migrate explain <phase>     # open the Acquia doc page a phase implements
./srsx-migrate init                # start over: re-ask app, environment, and sites
./srsx-migrate --help              # all flags
```

`doctor` is the first thing to run when a phase behaves unexpectedly.

## Overrides

Set these in `migration.env` or the environment when the defaults are wrong:

| Variable | Effect |
| --- | --- |
| `SITES` | Comma-separated site URIs; turns on multisite mode |
| `SRSX_COPY_INDEXES='<id> <id>'` | Also copy indexes classed `other` or `detached`, which are skipped by default |
| `SRSX_SWITCH_VIEWS='<id> <id>'` | Switch only these views instead of every eligible one |
| `SRSX_ROLLBACK_VIEWS='<id> <id>'` | Put these views back on their pre-migration index |
| `SEARCHSTAX_SOLR_PATH`, `SEARCHSTAX_SOLR_CORE` | Override how the endpoint URL is split, per app with a `_<k>` suffix |
| `SEARCHSTAX_MODULE_VERSION` | Pin `drupal/searchstax` instead of taking the latest |
| `KEEP_ACQUIA_SEARCH_IN_COMPOSER=1` | Keep `acquia_search` in `composer.json` during `cleanup` |
| `NO_COLOR=1` | Disable ANSI colour (same as `--no-color`) |

## Safety

- Every phase prints the underlying command (`+ drush …`) before executing, and writes it to `logs/<timestamp>-srsx.log`.
- `--dry-run` runs against the real environment but only prints commands.
- `--demo` runs against canned fixtures, with no real environment touched at all. PATH is shimmed with mock `drush`/`composer`/`acli`/`git`.
- Mutating phases refuse to run against a production environment.
- Recommended (and the default): store the SearchStax analytics key as a [Key module](https://www.drupal.org/project/key) entity, per the Acquia documentation.

Three things worth knowing before a security review:

- Secrets you type are prompted with `read -s` and held in memory. The one
  exception is phase `provision`: tokens it receives back from the SearchStax
  API are written to `migration.env` so multi-app runs can resume. That file is
  git-ignored but plaintext — delete it when you're done.
- The PHP helpers run on the target environment by being written to
  `/tmp/srsx-<pid>/` over `acli ssh`, with values embedded as
  `putenv('KEY=' . base64_decode('…'))`. That keeps secrets off the command line
  where `ps` would expose them, but base64 is encoding, not encryption. The
  directory is deleted after each run; if a run is killed, clear it with
  `acli ssh <app>.<env> -- 'rm -rf /tmp/srsx-*'`.
- Phase `install` **commits and pushes a git branch** in your repository.

## Documentation

- [docs/QUICKSTART.md](docs/QUICKSTART.md) — install, demo, and your first real run.
- [docs/PHASES.md](docs/PHASES.md) — what each phase does, command-by-command, and which Acquia doc page it implements.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common failure modes, the fix, and how to roll back via `acli pull:db` + `git revert`.

## Maintainership and support

Maintained by **Mohammad Zomorodian, Acquia Inc.** This is an Acquia-staff-driven open source project; pull requests welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

| Issue type                          | Where to go                                                              |
| ----------------------------------- | ------------------------------------------------------------------------ |
| Bug, question, or security concern  | [GitHub Issues](https://github.com/acquia/search-stax-migration/issues)  |
| Production migration help           | Your Acquia TAM or [Acquia Support](https://docs.acquia.com/service-offerings/contacting-acquia-support) |
| SearchStax product / index issues   | [SearchStax Support](https://support.searchstax.com)                     |
| Acquia Search shutdown timeline     | Your Acquia account team                                                 |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). All PRs run shellcheck, the demo smoke test, and a docs-drift check via the [CI workflow](.github/workflows/ci.yml).

Releases follow [Semantic Versioning](https://semver.org/) and are published as git tags; see [CHANGELOG.md](CHANGELOG.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
