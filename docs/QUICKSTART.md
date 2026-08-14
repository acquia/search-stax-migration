# Quickstart

> **When to read this:** you are about to migrate one Drupal site from Acquia Search to Acquia Search powered by SearchStax for the first time, and you want the shortest path that still does it correctly.

## What this toolkit does

Mutating phases run against **your Acquia DEV (or STAGE) environment** via
`acli remote:drush ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} -- ...`. You run the
toolkit from your **Acquia Cloud IDE** (recommended) or a local clone, so you
can validate the migrated search on a lower environment first. The toolkit stops
at Phase `handoff` after staging the resulting git changes; you commit and
deploy them to higher environments through your **normal Acquia workflow**.

```
   Cloud IDE                     Acquia Cloud                    your CI/CD
   ─────────                     ─────────────                   ──────────
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

### Recommended: run it from an Acquia Cloud IDE

This toolkit is designed to run in an [Acquia Cloud IDE](https://docs.acquia.com/acquia-cloud-platform/add-ons/cloud-ide), and that is the shortest path by a wide margin. A Cloud IDE already has `acli`, `git`, `composer`, `jq`, and PHP installed, and `acli` is already authenticated against the applications you have access to — so the only prerequisite left is:

- A Drupal 9, 10, or 11 site on Acquia Cloud (dev + stage envs at minimum).
- A SearchStax app — either one your Acquia TAM already provisioned (have the
  endpoint URL and read/write token ready), or none at all: the `provision`
  phase can create one for you from your SearchStax portal login.

Open the Cloud IDE for your application, clone or open your repository, and skip to [1. Install](#1-install).

### Running it locally instead

You are welcome to run it from a local clone, DDEV, or Lando — nothing in the toolkit is Cloud-IDE-specific. You just have to prepare the environment yourself:

- `bash` 4+, `git`, `composer`, `jq`, and the **Acquia CLI** (`acli`) on `PATH`.
  - macOS: `brew install bash jq && brew install --cask acli`
  - macOS ships bash 3.2; the toolkit needs 4+, which is what `brew install bash` gives you.
- `acli` authenticated: `acli auth:login`.
- Network access to Acquia Cloud (the toolkit uses `acli remote:drush` and `acli ssh`) and to the SearchStax API.

Either way, you do **not** need a local Drupal install or a local database. Every drush call runs on the Acquia environment through `acli remote:drush`.

## 1. Install

From the root of your Drupal repository (where `composer.json` lives):

```bash
curl -fsSL https://raw.githubusercontent.com/acquia/search-stax-migration/main/install.sh | bash
cd tools/searchstax-migration
```

To pin a release or install elsewhere:

```bash
curl -fsSL https://raw.githubusercontent.com/acquia/search-stax-migration/main/install.sh \
  | bash -s -- --target /path/to/repo --ref v1.0.0
```

## 2. Try it safely

```bash
./srsx-migrate --demo
```

`--demo` prepends `lib/demo/bin/` to `PATH`, where tiny Bash shims for `drush`,
`composer`, `acli`, and `git` return canned fixtures instead of calling the real
binaries. **No network calls, and nothing in your real environment changes.**
The toolkit itself cannot tell the difference — it parses the same JSON it would
in production.

You get walked through every phase exactly as in a real run. It takes a couple of
minutes if you read along, or a few seconds if you hold down Enter. Credentials
you type at the `configure` prompt go nowhere.

Demo mode still writes real files to `artifacts/`, `logs/`, and `state/` so you
can inspect what the toolkit parsed, and it creates a throw-away git repo under
`/tmp/srsx-demo-repo.*/` to stand in for your repo during `handoff`. Clean up
with `make clean`.

A single phase works too, which is handy for reading the inventory output:

```bash
./srsx-migrate --demo preflight
```

When stdin is not a TTY (CI, or `< /dev/null`), the pauses and prompts are
skipped automatically — that is how `make test` runs this same path unattended.

## 3. Run the migration

```bash
./srsx-migrate
```

That's it. On first run the wizard asks:

1. **Acquia application** (alias or UUID, e.g. `mycompany.myapp`)
2. **Target environment** for this run (`dev` or `stage`)
3. **Whether this is a Drupal multisite**, and if so the comma-separated list of
   site URIs to migrate

Then it runs every phase in order, pausing at sensible points so you can read the output. If you stop and re-run, it asks whether to resume from where you left off.

Two phases will stop and wait for you to do something outside the toolkit:
`backup` (take a DB backup in the Acquia Cloud UI) and `install` (deploy the
branch it just pushed). Neither can be automated away.

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

This phase is the **one** phase that may target a production env. It only reads (`drush sapi-s`, `drush sapi-i`) — never writes.

## 5. If something goes wrong

The toolkit deliberately does not ship an automated rollback. Use Acquia's tooling instead:

```bash
acli pull:db ${ACQUIA_APP}.${ACQUIA_TARGET_ENV}   # restore the pre-migration DB
git revert <migration-commit> && git push          # revert the code
```

Then wait for your CI/CD to redeploy. This restore is only fast if you actually
took the backup that phase `backup` asked you to confirm — the toolkit does not
take it for you. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Advanced: per-phase invocation

Most users never need this. But every phase is independently runnable, in this order:

```bash
./srsx-migrate preflight     # read-only inventory
./srsx-migrate backup        # confirm YOU took a Cloud UI DB backup
./srsx-migrate install       # composer require + git push + deploy + drush en
./srsx-migrate provision     # create the SearchStax app(s) (optional)
./srsx-migrate configure     # SearchStax credentials prompt
./srsx-migrate server        # create the search_api server
./srsx-migrate solrconfig    # make the SearchStax collection Drupal-compatible
./srsx-migrate index         # clone + reindex
./srsx-migrate views         # repoint views at the new indexes
./srsx-migrate route         # route searches through SearchStudio
./srsx-migrate validate      # read-only assertions
./srsx-migrate handoff       # pull config to local + git add
./srsx-migrate cleanup       # uninstall legacy modules
```

Add `--force` to re-run a phase that's already marked done.
For a full phase reset, run `./srsx-migrate all --force` (clears saved phase progress, then starts from `preflight`).

## When something looks wrong

```bash
./srsx-migrate status              # "you are at X; next: Y"
./srsx-migrate doctor              # read-only: what each index and view is really attached to
./srsx-migrate explain <phase>     # open the Acquia doc page a phase implements
./srsx-migrate init                # start over: re-ask app, environment, and sites
```

`doctor` is the first thing to run when a phase behaves unexpectedly. It never
changes anything.

---

**Next:** [PHASES.md](PHASES.md) — what each phase does, command by command.
**Up:** [README](../README.md)

— *Maintained by Mohammad Zomorodian, Acquia Inc.*
