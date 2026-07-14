# Phases — command by command

> **When to read this:** you want to know exactly what each phase will do to your Drupal site, in the same order it will do it, before you run it. Or you are reviewing the toolkit for security/correctness.

Every phase is implemented as a single bash function in [`srsx-migrate`](../srsx-migrate). Every drush/composer/acli call is printed (`+ command…`) before being executed. Nothing happens silently.

> **All `drush ...` lines below are executed as `acli remote:drush ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} -- ...`** — the toolkit never runs drush against your laptop. The terse form is used here to keep the docs readable.

## `preflight`

| What                         | How                                                                |
| ---------------------------- | ------------------------------------------------------------------ |
| Check `acli`, `composer`, `jq`, `git` are present | `command -v` (with platform-specific install hint on miss) |
| Drupal/Drush version on target env | `drush status --format=json` parsed via `jq`                 |
| Search-API server inventory  | `drush search-api:server-list --format=json` → `artifacts/inventory-<ts>/servers-<site>.json` |
| Search-API index inventory   | `drush search-api:status --format=json` → `artifacts/inventory-<ts>/indexes-<site>.json` |
| Enabled module list          | `drush pm:list --type=module --status=enabled --format=json`       |

Exits non-zero on Drupal 7, Drush <11, or failed bootstrap.

Preflight is strictly **read-only** — the baseline reset-tracker/reindex the runbook asks for happens at the start of phase `index`, after `backup` has secured a restore point.

## `install`

```bash
composer require drupal/searchstax:^1.11 drupal/search_api_solr:^4 drupal/key:^1
drush en -y searchstax solr_to_searchstax_ss_migration search_api_solr key
drush cr
```

Per site under multisite, the `drush` half is repeated with `--uri=…`.

## `backup`

```bash
acli api:environments:database-list ${ACQUIA_APP}.${ACQUIA_TARGET_ENV}          # resolve the DB name
acli api:environments:database-backup-create ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} <db>
acli api:environments:database-backup-list ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} <db>   # polled until completed_at
```

The phase polls (up to 15 minutes) until the newest backup reports completion. If any API step fails, it falls back to prompting you to take the backup manually in the Cloud UI. Acquia takes nightly backups already; this just adds an on-demand snapshot at exactly the pre-migration moment so you have a known-good restore point.

**There is no automated rollback.** If anything goes wrong on dev/stage, restore the DB with `acli pull:db` and `git revert` the migration commit. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the exact steps.

## `provision`

Creates the SearchStax Site Search app(s) the migration will point at, via the SearchStax REST API. **Optional** — short-circuits cleanly when any of these is true:

- `--demo` mode is active (the toolkit never touches the network in demo)
- `SEARCHSTAX_APP_ENDPOINT` is already set in `migration.env` or the environment (e.g. your TAM already provisioned an app)
- You answer "no, I already have one" at the first prompt

Otherwise the flow is:

```
POST  /api/rest/v2/obtain-auth-token/            (login; cached in state/searchstax.session, chmod 600)
GET   /api/rest/v2/account/                       (account picker)
GET   /api/rest/experience-manager/v1/plan_regions?account=…   (region picker)
POST  /api/rest/experience-manager/v2/apps?account=…           (create — one per Drupal site)
GET   /api/rest/experience-manager/v2/apps/<id>?account=…      (capture endpoint + tokens)
```

The first app's endpoint URL is written to `migration.env` as `SEARCHSTAX_APP_ENDPOINT`; tokens (read/write/analytics) are exported in-process so the next `configure` phase consumes them without re-prompting. Per the configure-phase contract, **tokens are never persisted to disk**.

Resumability: the created app id is recorded to `state/provisioned-app-id` *before* the detail-fetch, so a crash between create and detail re-uses the existing app instead of creating a duplicate on the next run.

> **Reverse-engineered.** Endpoints + body shapes were inferred from the SearchStudio SPA. The Drupal `searchstax` module does not expose app creation. If the API rev changes shape, `phase_provision` falls back to prompting the operator for the endpoint manually — same UX as before this phase existed.

## `configure`

Interactive only. Asks for:

- SearchStax app endpoint URL (e.g. `https://ss123-…-aws.searchstax.com`)
- SearchStax read token (input hidden)
- SearchStax write token (input hidden)
- SearchStax analytics URL (optional)
- SearchStax analytics key (input hidden, optional)
- Storage choice for the analytics key: **Key module entity** (default, per Acquia docs) or plain config

Non-secret values are written back to `migration.env` (with `awk`, no `sed -i` portability traps). Secrets are kept in memory for the rest of the run.

## `server`

Renders [`templates/search_api.server.searchstax.yml.tmpl`](../templates/search_api.server.searchstax.yml.tmpl) with `sed` substitution of `@@ID@@`, `@@NAME@@`, `@@ENDPOINT@@`. Then:

```bash
drush php:script lib/php-eval/import-config-yaml.php   # SRSX_YAML_FILE=…  SRSX_CONFIG_NAME=search_api.server.<id>
drush cr
drush config:get search_api.server.<id> --format=json  # verify
```

If verification fails, prints the manual UI fallback URL and pauses.

## `index`

For each Search-API index whose `server` is **not** `searchstax*`:

```bash
drush php:script /tmp/srsx-<run>/clone-index.php -- <index_id> <server_id>
```

The phase first offers a baseline reset-tracker + reindex of the legacy indexes (mutating, hence behind a confirm and the prod guard). Helpers are uploaded to the target env over `acli ssh` before execution — laptop-local paths and client environment variables do not survive the `acli remote:drush` SSH hop — and parameters travel as `php:script` arguments (drush's `$extra`).

The helper clones with `Index::createDuplicate()`, strips `acquia_search` third-party settings (so the clone survives the module's removal at cleanup), and records the pair via `\Drupal::service('solr_to_searchstax_ss_migration.utility')->addCopiedIndex()` — the same bookkeeping the module's `CloneIndexesForm` uses. Re-runs are idempotent.

Then for each new `*_searchstax` index:

```bash
drush sapi-c <new>     # clear
drush sapi-r <new>     # reset tracker
drush sapi-i <new>     # index
```

## `views`

```bash
drush php:script /tmp/srsx-<run>/switch-view-index.php
drush cr
```

A Search-API view binds to its index through the view's `base_table` (`search_api_index_<id>`) **and** a `table` key on every handler (fields, filters, sorts, arguments, relationships). The helper ports the module's `SearchViewSwitchIndexForm`: it records the original base table via `addOriginalBaseTable()` (enabling the module's rollback), sets `base_table` to the new index's table, and recursively switches every handler `table` key. The rename map comes from the module's `getCopiedIndexes()` bookkeeping, with a fallback scan for the `<id>_searchstax` naming convention. It exits non-zero if a map exists but nothing was switched.

## `route`

```bash
drush cset -y searchstax.settings searches_via_searchstudio 1
drush cset -y searchstax.settings configure_via_searchstudio 0
drush cset -y searchstax.settings analytics_url <url>          # if provided
# Then, depending on SECRET_STORAGE:
#   key   →  drush php:script /tmp/srsx-<run>/create-key-entity.php -- <value_file>; drush cset key_id searchstax_analytics_key
#            (the secret is uploaded as a file the helper deletes after reading — never argv)
#   plain →  drush cset searchstax.settings analytics_key <value>
drush cr
```

Config keys are taken from `searchstax.schema.yml` shipped with `drupal/searchstax` 1.11.0.

## `validate`

```bash
drush search-api:server-list --format=json | jq '.[].backend_config.connector_config.host'   # ≥1 host must contain searchstax.com
drush search-api:status --format=json | jq '… select(.value.server | startswith("searchstax")) | "\(.key) \(.value.count)"'   # ≥1 index, count > 0
```

Prints `[OK]` or `[WARN]` per check. Exits non-zero if any check failed.

## `handoff`

Exports config from the target Acquia env into a `/tmp` dir on that env, then
pulls the YAML files into your local repo via `acli ssh` + `tar`. Stages the
result with `git add` (composer.json/lock + your config sync dir). Does **not**
`git commit` and does **not** `git push` — those are your call so the change
lands on higher environments through your normal review and deploy process.

```bash
acli remote:drush ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} -- cex --destination=/tmp/srsx-handoff-<ts> -y
acli ssh ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} -- "cd /tmp/srsx-handoff-<ts> && tar -cf - ." \
  | tar -xf - -C ${REPO_ROOT}/<config-dir>
git add composer.json composer.lock
git add <config-dir>
git status --short
```

After this phase prints its handoff banner, the toolkit's job is done. You
review the staged changes, commit, push, and let your normal Acquia workflow
deploy the change up to dev → stage → prod.

## `cleanup`

Takes another snapshot first (`pre-cleanup`). Then:

```bash
drush pmu -y solr_to_searchstax_ss_migration acquia_search acquia_connector
drush cex -y
composer remove drupal/acquia_search drupal/acquia_connector drupal/searchstax_solr_migration
```

If `KEEP_ACQUIA_SEARCH_IN_COMPOSER=1` is set in `migration.env`, the `composer remove` block is skipped (some customers want the package retained until a follow-up sprint).

---

**Next:** [DEMO.md](DEMO.md) — running the toolkit with no real environment.
**Previous:** [QUICKSTART.md](QUICKSTART.md)
**Up:** [README](../README.md)

— *Maintained by Mohammad Zomorodian, Acquia Inc.*
