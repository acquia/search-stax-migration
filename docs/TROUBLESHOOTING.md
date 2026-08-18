# Troubleshooting

> **When to read this:** a phase failed and you want a known-good fix before opening a ticket.

The toolkit's preflight phase verifies every required tool (`acli`, `composer`, `jq`, `git`) up front and prints platform-specific install hints if anything is missing. So the most common "I forgot to install X" cases are handled by the script itself — there's nothing to look up here.

## If something goes wrong on dev/stage

This toolkit deliberately does not ship an automated rollback. The Acquia-native way is strictly safer and shorter:

1. Restore the pre-migration database that Phase `backup` triggered:
   ```bash
   acli pull:db ${ACQUIA_APP}.${ACQUIA_TARGET_ENV}
   ```
2. Revert the migration commit and push:
   ```bash
   git revert <migration-commit>
   git push
   ```
3. Wait for your normal CI/CD to redeploy. You're back to the pre-migration state.

That's it. Acquia keeps nightly backups in addition to the on-demand backup Phase `backup` requested, so you have multiple recovery points.

## "acli auth:login required" / `drush status` returns nothing on the target env

The toolkit can't reach Drupal on the target Acquia env. In order:

1. Run `acli auth:login` and follow the browser flow.
2. Confirm `ACQUIA_APP` and `ACQUIA_TARGET_ENV` are correct in `migration.env` (or re-run `./srsx-migrate init`).
3. Check standalone: `acli remote:drush ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} -- status`. If that fails, it's an Acquia/Drupal config issue — fix that before re-running the toolkit.

## Phase `preflight` reports a search health problem

This toolkit migrates an existing, working Search API setup. The preflight check confirms that each site's current search server resolves to a URL, answers, and has at least one index attached. What each result means:

| Reported | Meaning | Where to look |
| --- | --- | --- |
| `no Search API server exists` | This site has no search server configured, so there is nothing to migrate. | Confirm the site belongs in `SITES`. |
| `resolves to no server URL` | The server has no core assigned, so search on this site is not currently working. | Acquia Search subscription status, and `/admin/config/search/search-api` — does the server show a core? |
| `server URL does not answer` | A core is assigned but the endpoint did not respond. | The URL is printed above; verify network access and subscription status. |
| `reachable but holds no index` | The server responds but no index is attached to it. | `./srsx-migrate doctor` reports what each index is attached to. |

Resolve the search configuration on the affected site(s), then re-run:

```bash
./srsx-migrate preflight --force
```

You can continue past this warning, but later phases assume a working source search, so the run is likely to stop once it reaches `solrconfig`.

## Phase `server` says "Server config did not import cleanly"

The script offers a manual UI fallback. Visit `/admin/config/search/solr-to-searchstax-ss-migration` on the target env and complete the [Migrating the server](https://docs.acquia.com/acquia-cloud-platform/migrating-server-drupal-acquia-search-powered-searchstax) page by hand. Then continue with `./srsx-migrate index --force` (the `--force` re-runs `server` past its done marker if needed).

## Multisite: content isn't searchable until cron runs

Expected on sites that **share** a SearchStax app. The `index` phase turns off
"Index items immediately" (`index_directly`) on their copied indexes so sibling
sites don't send concurrent per-save writes to the same app; indexing happens on
cron instead. Sites with a dedicated app are not touched.

If a site needs a saved node to be searchable at once, re-run with the override:

```bash
SRSX_KEEP_INDEX_DIRECTLY=1 ./srsx-migrate index --force
```

Or tick "Index items immediately" on the index at
`/admin/config/search/search-api/index/<id>/edit`. Indexes copied by an earlier
run are skipped by the copy step, so whatever is set there already stands.

## Phase `validate` fails with "Index ${id}: 0 items"

Indexing hasn't completed yet on the target env. Wait a minute, then re-run:

```bash
./srsx-migrate validate
```

If it stays at 0 after several minutes, check the SearchStax Studio dashboard for the collection name — a mismatch between your `search_api.server.<id>.backend_config.connector_config.solr_dir` and what SearchStax provisioned will prevent items from landing.

---

**Up:** [README](../README.md)

— *Maintained by Mohammad Zomorodian, Acquia Inc.*
