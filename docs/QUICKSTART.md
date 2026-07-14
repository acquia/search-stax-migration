# Quickstart

> **When to read this:** you are about to migrate one Drupal site from Acquia Search to Acquia Search powered by SearchStax for the first time, and you want the shortest path that still does it correctly.

## What this toolkit does

Mutating phases run against **your Acquia DEV (or STAGE) environment** via
`acli remote:drush ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} -- ...`. You run the
toolkit from your **Cloud IDE or local clone** so you can validate the
migrated search on a lower environment first. The toolkit stops at Phase
`handoff` after staging the resulting git changes locally; you commit and
deploy them to higher environments through your **normal Acquia workflow**.

```
   your laptop                   Acquia Cloud                    your CI/CD
   ───────────                   ─────────────                   ──────────
   srsx-migrate ──acli remote:drush──▶  DEV env (mutated)
                                          │
                                  acli ssh + tar pull
                                          ▼
   local repo  ◀───── config/sync YAMLs staged with `git add`
        │
   git commit + git push  ─────────────────────────────────────▶  CI/CD
                                                                   │
                                                                   ▼
                                                            STAGE → PROD
```

## Prerequisites

- A Drupal 9, 10, or 11 site on Acquia Cloud (dev + stage envs at minimum).
- `bash` 4+, `composer`, `git`, `jq`, and the **Acquia CLI** (`acli`) on PATH.
  - macOS: `brew install bash jq && brew install --cask acli`
- `acli` already authenticated: `acli auth:login`.
- A SearchStax app provisioned for you by Acquia (endpoint URL + read/write tokens). If you don't have one, file a ticket with Acquia Support.

You do **not** need a local Drupal install. Every drush call goes through `acli remote:drush`.

## 1. Install

From the root of your Drupal repository (where `composer.json` lives):

**Public repo:**

```bash
curl -fsSL https://raw.githubusercontent.com/acquia/search-stax-migration/main/install.sh | bash
cd tools/searchstax-migration
```

**Private repo** — set `GITHUB_TOKEN` (or `GH_TOKEN`) first, then fetch `install.sh` via the GitHub Contents API. The installer will automatically use the same token for all subsequent file downloads:

```bash
export GITHUB_TOKEN="ghp_..."
curl -fsSL \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/acquia/search-stax-migration/contents/install.sh?ref=main" | bash
cd tools/searchstax-migration
```

> **Token scopes required:** `repo` (classic PAT) or `Contents: Read` (fine-grained PAT). If the repository is in a GitHub organisation with SAML SSO, also click **Configure SSO → Authorize** on your token settings page.

## 2. Try it safely

```bash
./srsx-migrate --demo
```

The whole migration runs end-to-end against canned fixtures. Nothing in your real environment changes. See [DEMO.md](DEMO.md).

## 3. Run the migration

```bash
./srsx-migrate
```

That's it. On first run the wizard asks three questions:

1. **Acquia application** (alias or UUID, e.g. `mycompany.myapp`)
2. **Target environment** for this run (`dev` or `stage`)
3. **Multisite?** (single-site is the default; multisite takes a comma-separated `--uri` list)

Then it runs every phase in order, pausing at sensible points so you can read the output. If you stop and re-run, it asks whether to resume from where you left off.

When the run finishes, you'll see a handoff banner that looks like this:

```
──────────────────────────────────────────────────────────────
  Migration validated on mycompany.myapp.dev.

  The toolkit's job is done. Production is YOUR responsibility:

    1. Review the staged changes:    git diff --staged
    2. Commit:                       git commit -m "Search: migrate to SearchStax"
    3. Push to your migration branch: git push origin <branch>
    4. Promote dev → stage → prod via your normal CI/CD process.
    5. After production deploy, run your standard smoke tests.
    6. (Optional, recommended) re-run validation against prod:
         ./srsx-migrate validate --env prod
       This phase is read-only and safe to run anywhere.
──────────────────────────────────────────────────────────────
```

## 4. Validate on prod (read-only, safe)

After your CI/CD has deployed to prod:

```bash
./srsx-migrate validate --env prod
```

This phase is the **one** phase that may target a production env. It only reads (`drush search-api:server-list`, `drush search-api:status`) — never writes. (Careful readers: `sapi-i` is the *indexing action*, not a read — validate does not run it.)

## 5. If something goes wrong

The toolkit deliberately does not ship an automated rollback. Use Acquia's tooling instead:

```bash
acli pull:db ${ACQUIA_APP}.${ACQUIA_TARGET_ENV}   # restore the pre-migration DB
git revert <migration-commit> && git push          # revert the code
```

Then wait for your CI/CD to redeploy. Phase `backup` triggered an on-demand Acquia DB backup specifically so this restore is fast. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Advanced: per-phase invocation

Most users never need this. But every phase is independently runnable:

```bash
./srsx-migrate preflight     # read-only inventory
./srsx-migrate backup        # on-demand Acquia DB backup (restore point)
./srsx-migrate install       # composer require + push + drush en
./srsx-migrate provision     # create SearchStax app(s) via REST API (optional)
./srsx-migrate configure     # SearchStax credentials prompt
./srsx-migrate server
./srsx-migrate index         # baseline reindex + clone legacy indexes
./srsx-migrate views
./srsx-migrate route
./srsx-migrate validate
./srsx-migrate handoff       # pull config to local + git add
./srsx-migrate cleanup       # uninstall legacy modules
```

(This order matches the toolkit's `PHASE_ORDER`: backup runs **before**
install so the restore point predates the first mutating change.)

Add `--force` to re-run a phase that's already marked done.
For a full phase reset, run `./srsx-migrate all --force` (clears saved phase progress, then starts from `preflight`).
Run `./srsx-migrate status` at any time to see "you are at X; next: Y".

---

**Next:** [PHASES.md](PHASES.md) — what each phase does, command by command.
**Up:** [README](../README.md)

— *Maintained by Mohammad Zomorodian, Acquia Inc.*
