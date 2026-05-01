# Contributing

Thanks for considering a contribution. This toolkit is small, opinionated, and meant to stay that way.

## Quick start

```bash
git clone https://github.com/acquia/search-stax-migration.git
cd search-stax-migration
brew install bash jq shellcheck   # macOS
make check
make test
```

## What we're looking for

- Bug fixes (with a reproduction in `--demo` mode whenever possible).
- Coverage for additional Drupal versions or Drush versions.
- Better error messages.
- Documentation improvements, especially clarifications when something tripped you up.

## What we're not looking for in v1

- Drupal 7 support (out of scope; SearchStax has its own D7 path).
- Cloud IDE auto-detection.
- Parallel multisite execution.
- A web UI.

If you want any of these, open an issue first to discuss.

## Required for any PR

- `make check` passes (lints and config-key drift check).
- `make test` passes (full demo run with scripted answers).
- New Bash code is shellcheck-clean (no new warnings).
- New phases or flags get a paragraph in [docs/PHASES.md](docs/PHASES.md).
- New external commands get a row in [docs/SECURITY.md](docs/SECURITY.md)'s "What this toolkit can do" table.
- No emojis in code, output, commit messages, or docs.

The CI workflow at [.github/workflows/ci.yml](.github/workflows/ci.yml) enforces all of the above.

## Code style

- Sentence-case for headings and prose.
- Functions are `snake_case`. Phase functions are `phase_<name>` and are dispatched by `dispatch()` only.
- Every external command goes through `run` or `run_capture` (so `--dry-run` and the audit trail keep working).
- Every drush invocation goes through `drush()` / `drush_capture()` (so `acli remote:drush` and per-site `--uri=` keep working).
- Avoid `set -x`. The audit log is the audit log; don't double-print.

## Adding a new phase

1. Pick a name and add it to `PHASE_ORDER`, `PHASE_DESC`, and `PHASE_DOC` in `srsx-migrate`.
2. Add `phase_<name>()` near the other phase functions.
3. Add the dispatch case to `dispatch()`.
4. If the phase has per-site work, factor that into a `_phase_<name>_site()` helper and use `for_each_site _phase_<name>_site`.
5. Document in `docs/PHASES.md` and add a row to `docs/MAPPING.md`.
6. Add a fixture if needed under `lib/demo/fixtures/`.
7. Add a smoke test step to `.github/workflows/ci.yml` if appropriate.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). It asks for:

- The output of `./srsx-migrate status`.
- The drush version (`drush --version`).
- The relevant section of `logs/<timestamp>-srsx.log`.
- Whether `--demo` reproduces the issue.

## Releasing (maintainers)

1. Update `CHANGELOG.md` — move "Unreleased" entries under a new version heading.
2. Update `SCRIPT_VERSION` in `srsx-migrate`.
3. Tag: `git tag -a vX.Y.Z -m "Release X.Y.Z" && git push --tags`.
4. CI builds the install one-liner. The `main` branch always points at the latest stable.

— *Maintained by Mohammad Zomorodian, Acquia Inc.*
