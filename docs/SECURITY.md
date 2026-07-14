# Security

> **When to read this:** you are a security reviewer, a TAM, or a customer doing due diligence before running this toolkit against your Acquia environment.

## What this toolkit can do

It can:

- Modify `composer.json` and `composer.lock` (Phase `install`, Phase `cleanup`).
- Commit and push the install-phase changes to your git remote — only after an explicit confirmation prompt (Phase `install`). On repos that track dependency code in git it also stages `vendor/` and `modules/contrib/`, since classic Acquia deploys do not run `composer install`.
- Enable, configure, and uninstall Drupal modules on the target Acquia env (Phases `install`, `route`, `cleanup`).
- Create, modify, and delete Drupal configuration entities on the target env (Phases `server`, `index`, `views`, `route`, `cleanup`).
- Trigger an Acquia Cloud on-demand database backup and poll it to completion, via `acli api:environments:database-list`, `database-backup-create`, and `database-backup-list` (Phase `backup`).
- Query the environment's production flag via `acli api:environments:find` (prod guard for every mutating phase).
- Upload the PHP helpers in `lib/php-eval/` (and the rendered server YAML / analytics-key file) to a per-run `/tmp/srsx-<pid>` directory on the target env over `acli ssh`, and remove that directory when the run ends (Phases `server`, `index`, `views`, `route`).
- Stage files in git (Phase `handoff`, Phase `cleanup`). Those phases do **not** commit or push.

It cannot:

- Edit or delete arbitrary files in your repository.
- Reach out to the network for anything except (a) the SearchStax endpoint you supplied, via Drupal's normal Search-API traffic, (b) `acli`'s normal Acquia Cloud API traffic, and (c) the SearchStax REST API via `curl` in the optional `provision` phase.
- Run anything outside of `drush`, `composer`, `acli`, `git`, `curl`, `sed`, `awk`, `jq`, `tar/gzip`, `mkdir`, and the PHP helpers in `lib/php-eval/`.

## Audit log

Every external command is printed (`+ command…`) to stdout *before* execution, and to a per-run log file at `logs/<timestamp>-srsx.log`. The log captures both stdout and stderr via `tee`, so you have a record of what ran, in what order, and what it returned — with one deliberate exception: known secret values (SearchStax tokens, analytics key, passwords, session token) are replaced with `[redacted]` in the audit lines before they reach the screen or the log.

## Secret handling

The SearchStax read token, write token, and analytics key are prompted via `read -s` (echo disabled) and held in process memory only. They are **never** written to `migration.env`. `migration.env` is also in `.gitignore` and created with mode 600. When the analytics key must reach the target env, it travels as an uploaded file (mode 077 umask) that the PHP helper deletes immediately after reading — never as a command-line argument, which would be visible to `ps` and the audit log. SearchStax API request bodies (login password) are fed to `curl` via stdin for the same reason.

The recommended (and default) place for the analytics key, per the [Acquia documentation](https://docs.acquia.com/acquia-cloud-platform/enabling-searchstax-module-and-routing-searches-through-it), is a [Key module](https://www.drupal.org/project/key) entity. The toolkit creates one named `searchstax_analytics_key` and points `searchstax.settings.key_id` at it. The Key module entity is itself stored in active Drupal config — which means it ends up in `config/sync/key.key.searchstax_analytics_key.yml` if you don't override the provider.

If your environment requires that secrets never sit in active config, change `SECRET_STORAGE=key` to a custom value and write your own [Key module provider](https://www.drupal.org/docs/contributed-modules/key) (e.g. environment variable, file, AWS Secrets Manager). The toolkit will not overwrite an existing key entity's provider settings beyond the value field.

## What is read from / written to the filesystem

| Path                                       | Read | Write | Notes                                            |
| ------------------------------------------ | :--: | :---: | ------------------------------------------------ |
| `<repo>/composer.json`, `composer.lock`    |   ✓  |   ✓   | Via `composer require`, `composer remove`        |
| `<repo>/<config-sync-dir>/`                |   ✓  |   ✓   | Phase `handoff` writes exported YAML, then `git add` |
| `tools/searchstax-migration/migration.env` |   ✓  |   ✓   | Non-secret values only                           |
| `tools/searchstax-migration/artifacts/`    |      |   ✓   | Inventory JSON, rendered YAML templates          |
| `tools/searchstax-migration/logs/`         |      |   ✓   | Per-run audit log                                |
| `tools/searchstax-migration/state/`        |   ✓  |   ✓   | Phase progress markers for resume/idempotency    |

All four `tools/searchstax-migration/` write paths are in [.gitignore](../.gitignore).

## Dry-run

`--dry-run` makes the toolkit print every command it would run without actually running anything. Use this to review a phase before the first live run.

## Demo mode

`--demo` does not touch the real environment at all — it shims `drush`/`composer`/`acli`/`git` with mock binaries that read canned JSON. See [DEMO.md](DEMO.md).

## OWASP Top 10 self-check

- **Injection:** Every external argument is passed as an array element to bash (`run "${cmd[@]}"`), never interpolated into a shell-string. Secrets are passed via environment variables to PHP helpers (`SRSX_KEY_VALUE=…`), not as command-line args, so they never appear in `ps`.
- **Broken access control:** The toolkit does whatever the calling user can do via `drush`. It does not elevate privileges.
- **Cryptographic failures:** Secrets are not stored on disk by this toolkit. The default analytics-key path uses Drupal's Key module.
- **Vulnerable dependencies:** The PHP helpers use only Drupal core APIs and the `solr_to_searchstax_ss_migration` service. No third-party PHP code is added.
- **Logging and monitoring:** Every command is logged. Logs are local files; you decide when to ship them.

## Reporting a vulnerability

Please email `searchstax-migration-security@acquia.com` (or your Acquia TAM) with reproduction steps. Do **not** open a public GitHub issue for security reports.

---

**Next:** [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
**Up:** [README](../README.md)

— *Maintained by Mohammad Zomorodian, Acquia Inc.*
