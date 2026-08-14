# Phases — command by command

> **When to read this:** you want to know exactly what each phase will do to your Drupal site, in the same order it will do it, before you run it. Or you are reviewing the toolkit for security/correctness.

Every phase is implemented as a single bash function in [`srsx-migrate`](../srsx-migrate). Every drush/composer/acli call is printed (`+ command…`) before being executed. Nothing happens silently.

> **All `drush ...` lines below are executed as `acli remote:drush ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} -- ...`** — the toolkit never runs drush against your laptop. The terse form is used here to keep the docs readable.

## Which Acquia doc page each phase implements

This toolkit tracks the [official runbook](https://docs.acquia.com/acquia-cloud-platform/migrating-acquia-search-powered-searchstax) chapter by chapter. If the Acquia docs change, this table must change too.

| Acquia doc page | Phase |
| --- | --- |
| [Preparing for the migration](https://docs.acquia.com/acquia-cloud-platform/preparing-migration-acquia-search-powered-searchstax) | `preflight`, `backup` |
| [Installing the SearchStax module](https://docs.acquia.com/acquia-cloud-platform/installing-searchstax-module) | `install` |
| (SearchStax-side — no public Acquia doc; the SearchStudio UI does this by hand) | `provision` |
| [Enabling the module + routing through SearchStudio](https://docs.acquia.com/acquia-cloud-platform/enabling-searchstax-module-and-routing-searches-through-it) | `configure`, `route` |
| [Migrating the server](https://docs.acquia.com/acquia-cloud-platform/migrating-server-drupal-acquia-search-powered-searchstax) | `server` |
| (no Acquia doc — SearchStax installs the config set on the collection) | `solrconfig` |
| [Migrating the index](https://docs.acquia.com/acquia-cloud-platform/migrating-index-drupal-acquia-search-powered-searchstax) | `index` |
| [Migrating the views](https://docs.acquia.com/acquia-cloud-platform/migrating-views-drupal-acquia-search-powered-searchstax) | `views` |
| [Multi-site, single SearchStax app](https://docs.acquia.com/acquia-cloud-platform/multi-site-configuration-single-searchstax-app) | every mutating phase re-runs per `--uri`; see [Multisite → SearchStax apps](#multisite--searchstax-apps) |
| [Validating the search page](https://docs.acquia.com/acquia-cloud-platform/validating-search-page) | `validate` |
| [Committing and deploying changes](https://docs.acquia.com/acquia-cloud-platform/committing-and-deploying-changes) | `handoff` |
| [Removing legacy module + config](https://docs.acquia.com/acquia-cloud-platform/removing-legacy-search-module-and-configuration) | `cleanup` |
| [Executing the rollback if required](https://docs.acquia.com/acquia-cloud-platform/executing-rollback-if-required) | none — manual, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |

`./srsx-migrate explain <phase>` prints the matching URL from the terminal.

## `preflight`

| What                         | How                                                                |
| ---------------------------- | ------------------------------------------------------------------ |
| Check `acli`, `composer`, `jq`, `git` are present | `command -v` (with platform-specific install hint on miss) |
| Drupal/Drush version on target env | `drush status --format=json` parsed via `jq`                 |
| Search-API server inventory  | `drush sapi-s --format=json` → `artifacts/inventory-<ts>/servers.json` |
| Search-API index inventory   | `drush sapi-i --format=json` → `artifacts/inventory-<ts>/indexes.json` |
| Enabled module list          | `drush pm:list --type=module --status=enabled --format=json`       |

Exits non-zero on Drupal 7, Drush <11, or failed bootstrap.

## `install`

This phase changes your **local repository** and then waits for you to deploy it.
It is the only phase that commits and pushes code.

It first offers a skip ("the modules are already installed and deployed"), then
optionally pins `drupal/searchstax` to a version you choose:

```bash
composer require drupal/search_api:^1 drupal/search_api_solr:^4 drupal/searchstax drupal/key:^1
```

Every package is then verified individually and the phase aborts if any is
missing. Next it stages the result — `composer.json`, `composer.lock`, and the
built code directories (`vendor/`, `docroot|web/core`, `modules/contrib`,
`themes/contrib`, `profiles/contrib`, `libraries`) are force-added so the deploy
is complete via git alone — and:

```bash
git commit -m "Search: install SearchStax migration modules"
git push origin <branch-you-choose>
```

It then **stops and asks you to deploy that branch to the target environment in
the Acquia Cloud UI** (pushing a branch does not auto-deploy on ACSF), and waits
for you to confirm the deploy finished. Only then does it enable the modules,
per site:

```bash
drush updb -y
drush cr
drush en -y search_api search_api_solr searchstax solr_to_searchstax_ss_migration key
drush cr
```

If the push fails, the phase says so plainly and does not let you claim a deploy
happened. If any site fails to enable the modules, the phase is left un-done so
you can re-run it.

## `backup`

**This phase does not create a backup. You do.**

It prints instructions, then blocks on a confirmation:

```
  1. Open the Acquia Cloud UI for <app>.<env>.
  2. Trigger an on-demand backup of the <env> database and wait for it to finish.

Have you triggered an on-demand backup of the <env> DB and confirmed it finished? [y/N]
```

The toolkit runs no `acli` or `drush` command here and has no way to verify your
answer. If you answer yes without taking the backup, you have no restore point —
and every phase after this one mutates the environment.

It runs before `install` deliberately, so the snapshot predates the first change.

**There is no automated rollback.** If anything goes wrong on dev/stage, restore the DB with `acli pull:db` and `git revert` the migration commit. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the exact steps.

## `provision`

Creates the SearchStax Site Search app(s) the migration will point at, via the SearchStax REST API. **Optional** — short-circuits cleanly when any of these is true:

- `--demo` mode is active (the toolkit never touches the network in demo)
- Every app endpoint is already set in `migration.env` or the environment (e.g. your TAM already provisioned the app[s])
- You answer "no, I already have one" at the first prompt

For a multisite, the number of apps to create comes from the site→app topology (subject to the 9-sites-per-app cap) — see [Multisite → SearchStax apps](#multisite--searchstax-apps).

Otherwise the flow is:

```
POST  /api/rest/v2/obtain-auth-token/            (login; cached in state/searchstax.session, chmod 600)
GET   /api/rest/v2/account/                       (account picker)
GET   /api/rest/experience-manager/v1/plan_regions?account=…   (region picker)
POST  /api/rest/experience-manager/v2/apps?account=…           (create — one per app group)
   GET   /api/rest/experience-manager/v2/apps/<id>?account=…      (capture endpoint + tokens)
```

Every created app's endpoint URL **and** tokens (read/write/analytics) are persisted to `migration.env`, suffixed `_1.._K` per app; app 1 also mirrors the unsuffixed `SEARCHSTAX_*` vars. `migration.env` is git-ignored, so these secrets are never committed, and multi-app runs can resume across separate invocations.

Resumability: each created app id is recorded to `state/provisioned-app-id-<k>` *before* the detail-fetch, so a crash between create and detail re-uses the existing app instead of creating a duplicate on the next run.

**App naming.** Before asking for each app's name, the phase best-effort detects the site's real Acquia Search core ID(s) (`lib/php-eval/inspect-acquia-search-cores.php`, reading the `acquia_search` module's own `PreferredCoreService`/`AcquiaSearchApiClient` — no new external integration). If any are found they're shown to the operator, who picks one (or types a custom name); an exact per-site preferred match is offered as the default. If `acquia_search` is missing/disabled or no cores are reachable, this is skipped with a one-line note and naming falls back to the previous synthetic `${ACQUIA_APP}_${ACQUIA_TARGET_ENV}` default — never a hard failure.

> **Reverse-engineered.** Endpoints + body shapes were inferred from the SearchStudio SPA. The Drupal `searchstax` module does not expose app creation. If the API rev changes shape, `phase_provision` falls back to prompting the operator for the endpoint manually — same UX as before this phase existed.

## `configure`

Interactive only. For **each** SearchStax app (one for single-site; K for a multisite, labeled with the sites it serves) asks for:

- SearchStax app endpoint URL — paste the Solr URL; a trailing `/select` or `/update` is fine
- SearchStax App endpoint URL
- SearchStax read & write token (the single token used for both reading and writing)
- SearchStax analytics URL (optional)
- SearchStax analytics key (input hidden, optional)

Then a single storage choice for the analytics key: **Key module entity** (default, per Acquia docs) or plain config.

### Endpoint decomposition

`search_api_solr` does not take a URL — it wants `scheme` / `host` / `port` / `path` / `core` separately, where `host` is a **bare hostname**. The endpoint you paste is therefore split automatically, and `/select` or `/update` (Solr request handlers, which `search_api_solr` appends itself) are stripped:

```
https://searchcloud-29-us-east-1.searchstax.com/29847/appname-13912/update
  scheme https
  host   searchcloud-29-us-east-1.searchstax.com
  port   443
  path   /29847
  core   appname-13912
```

The split is printed during `configure` so a bad paste is obvious immediately. If your app's URL layout differs, override it in `migration.env` with `SEARCHSTAX_SOLR_PATH[_k]` / `SEARCHSTAX_SOLR_CORE[_k]` — no code change needed.

Values are written back to `migration.env` (with `awk`, no `sed -i` portability traps), suffixed `_1.._K` per app. Because `migration.env` is git-ignored, tokens are persisted there too so per-app credentials survive a resume. The site→app topology is captured here if `provision` didn't already establish it.

## `server`

Renders [`templates/search_api.server.searchstax.yml.tmpl`](../templates/search_api.server.searchstax.yml.tmpl) with `sed` substitution of `@@ID@@`, `@@NAME@@`, and the decomposed endpoint (`@@SCHEME@@`, `@@HOST@@`, `@@PORT@@`, `@@PATH@@`, `@@CORE@@`). Then:

```bash
drush php:eval <import-config-yaml.php>   # SRSX_YAML_CONTENT=…  SRSX_CONFIG_NAME=search_api.server.<id>
drush cr
drush config:get search_api.server.<id> --format=json  # verify
```

If verification fails, prints the manual UI fallback URL and pauses.

## `solrconfig`

Creating the Drupal-side server is only half of what the searchstax module's own migration does. The other half is [`MigrationHelper::setAppLanguages()`](https://git.drupalcode.org/project/searchstax) calling `Api::setLanguages()`, which tells SearchStax which languages the app serves — and that is what makes SearchStax provision Drupal-compatible field types on the collection. Skipping it leaves the stock `default-config` schema, which **accepts every document Drupal sends and answers no query**: indexing reports 100% while search returns nothing.

```bash
SRSX_SSX_TOKEN=… SRSX_SERVER_ID=… drush php:script <searchstax-configure-app.php>
curl -H 'Authorization: Token …' '<core>/schema/name?wt=json'
```

The helper drives the module's own API client (`searchstax.api`, present in every release) rather than reimplementing the REST calls. The auth token is written into the key-value store that client reads — the same thing `drush searchstax:set-auth-token` does on releases new enough to have it — so this works on 1.9.x, which has no such command. Account and app are resolved automatically by matching the server's `context`/`core` against each app's `update_endpoint`.

The token comes from the toolkit's own SearchStax login, which handles 2FA and caches the session, so a run that provisioned the app does not log in twice.

SearchStax rebuilds the collection asynchronously, so the phase polls `GET <core>/schema/name` for up to a minute and requires it to start with `drupal-`.

**Fallback.** Some customers have no SearchStax portal credentials — the TAM provisioned the app. If the login is declined or the API call fails, the phase exports the config set with `search_api_solr.configset_controller` to `artifacts/solr-config/<site>.zip` and **stops the run** so it can be handed to SearchStax. Re-run `./srsx-migrate solrconfig --force` afterwards to re-check and continue.

## `index`
Every index on the site is classified by `lib/php-eval/inspect-index-topology.php`, which asks Drupal's entity API directly. `drush search-api:list --format=json` cannot answer this: its default field set is `id,name,serverName,typeNames,status,limit`, so the machine-readable `server` column is omitted and only the human `serverName` label ships — which made every index look unattached.

| Class | Where the index sits | Action |
| --- | --- | --- |
| `target` | the SearchStax server | skipped, already migrated |
| `legacy` | a non-SearchStax Solr server | copied |
| `other` | a non-Solr server (`search_api_db`, …) | skipped — moving it is a product decision |
| `detached` | no server, or a server that no longer exists | skipped — it was never serving search |

`other` and `detached` indexes can be moved anyway with `SRSX_COPY_INDEXES='<id> <id>'`.

Before copying anything, the target server itself is checked. A `missing`, `not-solr` or `wrong-connector` verdict fails the site immediately with instructions to re-run `./srsx-migrate server --force` — a copy made onto a server that is not really SearchStax-backed looks like success and indexes nowhere.

For each index to copy:

```bash
SRSX_INDEX_ID=<id> SRSX_NEW_SERVER_ID=<server> drush php:script <clone-index.php>
```

The PHP helper calls `\Drupal::service('solr_to_searchstax_ss_migration.migration_helper')->createIndexCopy($index, $server_id)` — the same method behind the module's "Create copy" button and behind `drush searchstax:copy-index`. It is called directly rather than through that command because the command only exists from searchstax 1.12.0 and refuses any index whose current server is not registered in `migrated_servers`. If the submodule cannot be enabled at all, the helper falls back to the same field surgery by hand.

Re-running the phase is safe: an index already recorded in the module's `copied_indexes` map is skipped rather than copied again.

Then for each index now on the SearchStax server:

```bash
drush sapi-rt <new>    # reset tracker
drush sapi-i <new>     # index
drush sapi-s <new>     # status
```

If nothing ends up on the SearchStax server, the site is recorded as failed and the phase is left un-done. Run `./srsx-migrate doctor` to see what each index is actually attached to.

## `views`

```bash
drush php:script <list-migrated-views.php>              # which views need switching
SRSX_VIEW_ID=<view> drush php:script <switch-view-index.php>
drush cr
```

A view's index is decided by its `base_table` (`search_api_index_<id>` or `search_api_datasource_<id>_<datasource>`) and no display can override it, so `list-migrated-views.php` inventories **every** Search API view with the index, server and backend behind it, and the action it will take:

```
srsx_demo_search  index=default_index  server=acquia_search_server  backend=search_api_solr  => SWITCH -> searchstax_index
srsx_demo_media   index=media_library  server=database_server       backend=search_api_db    => leave (database search, not Acquia Search)
```

Only views on an index recorded in `copied_indexes` are switched, so database-backed search views are left alone by construction. The same inventory is printed read-only by `./srsx-migrate doctor`. Set `SRSX_SWITCH_VIEWS='<id> <id>'` to switch only some of the eligible ones.

`switch-view-index.php` prefers `MigrationHelper::switchViewToNewIndex()`, and re-saves affected facets and adapts autocomplete searches. That service only exists on newer releases — searchstax 1.9.x ships the submodule with `solr_to_searchstax_ss_migration.utility` as its only service — so the same rewrite is also implemented inline: `base_table` is repointed and every nested `table` key naming the old index is rewritten. A view that was already switched is skipped.

### Rolling a view back

```bash
SRSX_ROLLBACK_VIEWS='blog news' ./srsx-migrate views --force
```

Puts those views back on the index they were on before the migration and does nothing else. The original table comes from the module's own `original_base_tables` record, written when the view was switched, and is restored verbatim — a view built on a datasource table must not come back as an index table. A view this toolkit never switched has no record and is refused rather than guessed at. `./srsx-migrate doctor` shows the recorded original as `was=…` next to each view.

## `route`

```bash
drush cset -y searchstax.settings searches_via_searchstudio 1
drush cset -y searchstax.settings configure_via_searchstudio 0
drush cset -y searchstax.settings analytics_url <url>          # if provided
# Then, depending on SECRET_STORAGE:
#   key   →  drush php:eval <create-key-entity.php>; drush cset key_id searchstax_analytics_key
#   plain →  drush cset searchstax.settings analytics_key <value>
drush cr
```

Config keys are taken from `searchstax.schema.yml` shipped with `drupal/searchstax` 1.11.0.

## `validate`

```bash
drush sapi-s --format=json | jq '.[].backend_config.connector_config.host'   # must contain searchstax.com
drush sapi-i --format=json | jq '… select(.value.server | startswith("searchstax")) | "\(.key) \(.value.count)"'   # count > 0
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

Refuses to run without an explicit confirmation, then per site:

```bash
drush pmu -y solr_to_searchstax_ss_migration acquia_search acquia_connector
drush cex -y
composer remove drupal/acquia_search drupal/acquia_connector drupal/searchstax_solr_migration
```

If `KEEP_ACQUIA_SEARCH_IN_COMPOSER=1` is set in `migration.env`, the `composer remove` block is skipped (some customers want the package retained until a follow-up sprint).

---

## Multisite → SearchStax apps

When you tell the wizard you run a Drupal multisite (a comma-separated `SITES`
list), the toolkit maps those sites onto one or more SearchStax apps.

**Hard limit: a single SearchStax app holds at most 9 sites.** The minimum
number of apps is therefore `ceil(N / 9)` — 1–9 sites need 1 app, 10 sites need
2, 100 sites need 12.

The `provision` phase (or `configure`, if you already have apps) asks **how many
apps** you want:

- **Default — fewest apps.** Sites are packed up to 9 per app. Recommended, and
  needs no per-site input.
- **More apps (optional).** Choose a larger number only when you want finer
  separation (for example, one important site on its own app). You then assign
  each site to an app; every app must hold 1–9 sites.

The mapping is persisted to `migration.env` as `SEARCHSTAX_APP_COUNT` and
`SITE_APP_MAP` (e.g. `SITE_APP_MAP="https://a=1,https://b=1,https://c=2"`).
Per-app credentials are stored suffixed `_1.._K`
(`SEARCHSTAX_APP_ENDPOINT_2`, `SEARCHSTAX_READ_TOKEN_2`, …); app 1 also mirrors
the unsuffixed `SEARCHSTAX_*` vars for single-app compatibility. `migration.env`
is git-ignored, so tokens stored there are never committed.

Each per-site phase (`server`, `index`, `route`, `validate`) resolves the app for
the current `--uri` and uses that app's endpoint and tokens. Sites that **share**
an app are namespaced with a per-site `index_prefix` (via
[set-multisite-prefix.php](../lib/php-eval/set-multisite-prefix.php)) so
"results from this site only" filtering works.

> **Handoff caveat (multisite).** `handoff` currently exports config for the
> default site only. Each additional site keeps its own config and must be
> exported per `--uri` into its own config sync directory before deploy — the
> handoff summary prints the exact `drush --uri=<site> config:export` commands.
> Automating per-site export is a planned follow-up.

## Verified against module version

Verified against `drupal/searchstax` 1.11.0:

- Module machine name: `searchstax` (not `searchstax_studio`)
- Submodule: `solr_to_searchstax_ss_migration`
- Config object: `searchstax.settings`
- Config keys (from `searchstax.schema.yml`): `searches_via_searchstudio`,
  `configure_via_searchstudio`, `analytics_url`, `analytics_key`, `key_id`

The toolkit deliberately does **not** call `drush searchstax:*` commands: they
only exist from 1.12.0, and the 1.9.x releases many customers run ship the
submodule with `solr_to_searchstax_ss_migration.utility` as their only service.
Every helper in `lib/php-eval/` therefore prefers the module's service when it
exists and implements the same work inline when it does not.

If your installed `drupal/searchstax` is newer and the schema has changed,
[tests/check-config-keys.sh](../tests/check-config-keys.sh) will tell you on
`make check`.

---

**Previous:** [QUICKSTART.md](QUICKSTART.md)
**Next:** [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
**Up:** [README](../README.md)

— *Maintained by Mohammad Zomorodian, Acquia Inc.*
