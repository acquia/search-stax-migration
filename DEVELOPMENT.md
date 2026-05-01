# Development guide

## Prerequisites

Bash 4.3+, [shellcheck](https://github.com/koalaman/shellcheck), [jq](https://stedolan.github.io/jq/) 1.6+, Git 2.x+. No Node/Python/Ruby needed.

```bash
brew install bash jq shellcheck   # macOS
```

## Setup

We use two remotes:

| Remote       | Points to                                          |
| ------------ | -------------------------------------------------- |
| `origin`     | your fork (`git@github.com:<you>/search-stax-migration.git`) |
| `upstream`   | the main repo (`git@github.com:acquia/search-stax-migration.git`) |

```bash
# 1. Fork on GitHub, then clone your fork
git clone git@github.com:<your-username>/search-stax-migration.git
cd search-stax-migration

# 2. Add the main repo as upstream
git remote add upstream git@github.com:acquia/search-stax-migration.git
```

## Workflow

```bash
git checkout main && git pull upstream main   # sync with upstream
git checkout -b feat/my-change                # branch off main
# ... make changes ...
make check && make test                       # lint + smoke test
git push origin feat/my-change                # push to your fork
```

Then open a pull request from `origin/feat/my-change` to `upstream/main` on GitHub. Fill out the [PR template](.github/PULL_REQUEST_TEMPLATE.md). Once CI passes and a maintainer approves, you are welcome to merge it yourself.

We squash-merge by default. Mention in the PR if you want to preserve intermediate commits.

## Make targets

| Command        | What it does                                                    |
| -------------- | --------------------------------------------------------------- |
| `make lint`    | `bash -n` + shellcheck on all shell files                       |
| `make check`   | lint + config-key drift check against the schema fixture        |
| `make test`    | full `--demo` end-to-end with scripted answers                  |
| `make demo`    | interactive demo mode (mock environment, nothing real touched)  |
| `make docs`    | regenerate auto-generated doc sections                          |
| `make clean`   | remove `artifacts/`, `logs/`, `state/`                          |

## Code rules

- See [CONTRIBUTING.md](CONTRIBUTING.md) for the full list.
- External commands go through `run` / `run_capture`. Drush calls go through `drush()` / `drush_capture()`.
- Functions are `snake_case`. Phase functions are `phase_<name>`.
- No emojis anywhere.

## CI

GitHub Actions ([ci.yml](.github/workflows/ci.yml)) runs on every push and PR to `main`: lint, config-key drift check, demo end-to-end, and docs drift check. Failed runs upload `srsx-logs` as an artifact.

## Reporting issues

Use the [bug report](.github/ISSUE_TEMPLATE/bug_report.md) or [feature request](.github/ISSUE_TEMPLATE/feature_request.md) templates on GitHub.
