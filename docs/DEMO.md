# Demo mode

> **When to read this:** you want to see exactly what the toolkit will do against your real Acquia env, without touching anything real first.

`--demo` prepends `lib/demo/bin/` to `PATH`. That directory contains tiny Bash shims for `drush`, `composer`, `acli`, and `git` that emit canned fixtures from `lib/demo/fixtures/` instead of executing the real binaries. The toolkit itself doesn't know anything is fake — it parses the same JSON it would in production.

## Run it

```bash
./srsx-migrate --demo
```

You'll be walked through every phase exactly as in a real run:

- The script pauses between phases (`[demo: press Enter for next phase…]`) so you can read the output.
- `configure` will prompt you for SearchStax credentials. Type whatever you like — they're never sent anywhere in demo mode.
- `cleanup` asks before running.

The whole thing takes a minute or two if you're reading along, or about 3 seconds if you mash Enter.

When stdin isn't a TTY (e.g. CI piping or `< /dev/null`), the pauses and prompts are skipped automatically — that's how `make test` runs the same path unattended.

## Run a single phase

```bash
./srsx-migrate --demo preflight
```

Useful if you want to inspect the inventory output, or see what the install hints look like for a missing tool.

## What gets written

Demo mode writes to `artifacts/`, `logs/`, and `state/` under `tools/searchstax-migration/`, so you can inspect the JSON the toolkit would have parsed in production. It also creates a throw-away git repo under `/tmp/srsx-demo-repo.*/` to act as the "customer's repo" for Phase `handoff` — your real repo is never touched.

To clean up after a demo:

```bash
make clean
```

## What is NOT mocked

- File creation under `artifacts/` and `logs/` happens for real.
- `git` is partially shimmed (`git add`, `git status`, `git commit`, `git push` intercepted); other git calls pass through to `/usr/bin/git` so `git rev-parse` works.
- `jq` is forwarded to the real `jq` (the toolkit needs it to parse the fixture JSON).

---

**Next:** [MAPPING.md](MAPPING.md) — Acquia doc page → toolkit phase.
**Previous:** [PHASES.md](PHASES.md)
**Up:** [README](../README.md)

— *Maintained by Mohammad Zomorodian, Acquia Inc.*
