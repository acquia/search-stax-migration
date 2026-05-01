<!-- Thanks for contributing. Please complete every checkbox before requesting review. -->

## What this changes

## Why

## Checklist

- [ ] `make check` passes locally (lint + config-key drift check)
- [ ] `make test` passes locally (full demo run)
- [ ] No new shellcheck warnings
- [ ] If a new phase or flag was added: documented in `docs/PHASES.md` and `docs/MAPPING.md`
- [ ] If a new external command is invoked: row added to `docs/SECURITY.md` table
- [ ] Updated `CHANGELOG.md` under "Unreleased"
- [ ] No emojis added to code, output, or docs

## Demo mode reproduction

If this is a bug fix, paste the `--demo` invocation that reproduces the issue (and now passes):

```bash
./srsx-migrate --demo …
```

## Linked issues

Closes #
