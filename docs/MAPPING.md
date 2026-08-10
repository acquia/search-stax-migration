# Mapping — Acquia documentation → toolkit phase

> **When to read this:** you trust the Acquia documentation and you want to verify, line-by-line, that this toolkit does the same thing. Or your security review needs a paper trail.

This page tracks the [official runbook](https://docs.acquia.com/acquia-cloud-platform/migrating-acquia-search-powered-searchstax) chapter by chapter. If the docs change, this page must change too — see the docs-drift check in [.github/workflows/ci.yml](../.github/workflows/ci.yml).

| Acquia doc page                                                                                                                              | Toolkit phase     | Implementation                                                                  |
| -------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------------- |
| [Preparing for the migration](https://docs.acquia.com/acquia-cloud-platform/preparing-migration-acquia-search-powered-searchstax)             | `preflight`, `backup` | `drush status`, `sapi-s`, `sapi-i`, `pm:list`, `sql:dump`, `cex`, `acli backup` |
| [Installing the SearchStax module](https://docs.acquia.com/acquia-cloud-platform/installing-searchstax-module)                                | `install`         | `composer require drupal/searchstax`, `drush en searchstax …`                   |
| (SearchStax-side, no public Acquia doc — Studio SPA does this manually)                                                                       | `provision`       | `POST /experience-manager/v2/apps` (+ `GET /apps/<id>` for endpoint + tokens). Auto-skipped if endpoint already set or in `--demo` |
| [Enabling the module + routing through SearchStudio](https://docs.acquia.com/acquia-cloud-platform/enabling-searchstax-module-and-routing-searches-through-it) (credentials prompt) | `configure`       | Interactive prompts for endpoint URL, tokens, analytics URL/key; Key module storage |
| [Migrating the server](https://docs.acquia.com/acquia-cloud-platform/migrating-server-drupal-acquia-search-powered-searchstax)                | `server`          | Render YAML template → `drush php:eval <import-config-yaml.php>`                 |
| [Migrating the index](https://docs.acquia.com/acquia-cloud-platform/migrating-index-drupal-acquia-search-powered-searchstax)                  | `index`           | `drush php:eval <clone-index.php>` calling `solr_to_searchstax_ss_migration.utility::cloneIndex()` |
| [Migrating the views](https://docs.acquia.com/acquia-cloud-platform/migrating-views-drupal-acquia-search-powered-searchstax)                  | `views`           | `drush php:eval <switch-view-index.php>` rewrites `views.view.*` config         |
| [Enabling the module + routing through SearchStudio](https://docs.acquia.com/acquia-cloud-platform/enabling-searchstax-module-and-routing-searches-through-it) | `route`           | `drush cset searchstax.settings searches_via_searchstudio 1` (+ analytics)      |
| [Multi-site, single SearchStax app](https://docs.acquia.com/acquia-cloud-platform/multi-site-configuration-single-searchstax-app)             | (per-site iteration via `SITES` env) | All mutating phases re-run with `drush --uri=<site>` for each entry in `SITES`. Sites are mapped to one or more SearchStax apps — see [Multisite → SearchStax apps](#multisite--searchstax-apps) |
| [Validating the search page](https://docs.acquia.com/acquia-cloud-platform/validating-search-page)                                            | `validate`        | URL contains `searchstax.com`; index `count > 0`                                |
| [Committing and deploying changes](https://docs.acquia.com/acquia-cloud-platform/committing-and-deploying-changes)                            | `handoff`         | drush cex on target env via `acli ssh` + `tar` pull, then `git add` (no commit, no push) |
| [Removing legacy module + config](https://docs.acquia.com/acquia-cloud-platform/removing-legacy-search-module-and-configuration)              | `cleanup`         | `drush pmu`, `composer remove`                                                  |
| [Executing the rollback if required](https://docs.acquia.com/acquia-cloud-platform/executing-rollback-if-required)                            | (none — manual)   | Documented manual procedure: `acli pull:db` + `git revert`. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md). |

## Verified against module version

This mapping was verified against `drupal/searchstax 1.11.0`. Specifically:

- Module machine name: `searchstax` (not `searchstax_studio`)
- Submodule: `solr_to_searchstax_ss_migration`
- Service ID used by Phase `index`: `solr_to_searchstax_ss_migration.utility` → `cloneIndex()`
- Config object: `searchstax.settings`
- Config keys (from `searchstax.schema.yml`): `searches_via_searchstudio`, `configure_via_searchstudio`, `analytics_url`, `analytics_key`, `key_id`

If your installed `drupal/searchstax` is newer and the schema has changed, [tests/check-config-keys.sh](../tests/check-config-keys.sh) will tell you on `make check`.

---

## Multisite → SearchStax apps

When you tell the wizard you run a Drupal multisite (a comma-separated `SITES`
list), the toolkit maps those sites onto one or more SearchStax apps.

**Hard limit: a single SearchStax app holds at most 9 sites.** The minimum
number of apps is therefore `ceil(N / 9)`:

| Sites (N) | Minimum apps |
| --------- | ------------ |
| 1–9       | 1            |
| 10        | 2            |
| 20        | 3            |
| 99        | 11           |
| 100       | 12           |

The `provision` (or `configure`, if you already have apps) phase asks **how
many apps** you want for your sites:

- **Default — fewest apps.** Sites are packed up to 9 per app (`ceil(N/9)` apps).
  1 site → 1 app, 5 sites → 1 app, 10 sites → 2 apps. This is recommended and
  needs no per-site input.
- **More apps (optional).** Choose a larger number only when a customer wants
  finer separation (for example, one important site on its own app). You then
  assign each site to an app; every app must hold 1–9 sites.

The mapping is persisted to `migration.env` as `SEARCHSTAX_APP_COUNT` and
`SITE_APP_MAP` (e.g. `SITE_APP_MAP="https://a=1,https://b=1,https://c=2"`).
Per-app credentials are stored suffixed `_1.._K`
(`SEARCHSTAX_APP_ENDPOINT_2`, `SEARCHSTAX_READ_TOKEN_2`, …); app 1 also mirrors
the unsuffixed `SEARCHSTAX_*` vars for single-app compatibility. `migration.env`
is git-ignored, so tokens stored there are never committed.

Each per-site phase (`server`, `index`, `route`, `validate`) resolves the app
for the current `--uri` and uses that app's endpoint/tokens. Sites that **share**
an app are namespaced with a per-site `index_prefix` (via
[set-multisite-prefix.php](../lib/php-eval/set-multisite-prefix.php)) so
"results from this site only" filtering works.

> **Handoff caveat (multisite).** `handoff` currently exports config for the
> default site only. Each additional site keeps its own config and must be
> exported per `--uri` into its own config sync directory before deploy — the
> handoff summary prints the exact `drush --uri=<site> config:export` commands.
> Automating per-site export is a planned follow-up.

---

**Next:** [SECURITY.md](SECURITY.md)
**Previous:** [DEMO.md](DEMO.md)
**Up:** [README](../README.md)

— *Maintained by Mohammad Zomorodian, Acquia Inc.*
