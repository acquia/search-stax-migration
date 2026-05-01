---
name: Bug report
about: Report something the toolkit got wrong.
title: '[bug] '
labels: bug
assignees: ''
---

## What happened

<!-- Brief description. Was it a wrong outcome, a crash, or an unhelpful error? -->

## What you expected

## Reproduction

Steps to reproduce, ideally in `--demo` mode if it's reproducible there:

```bash
./srsx-migrate --demo …
```

## Required: status output

```text
$ ./srsx-migrate status
<paste output here>
```

## Required: drush version

```text
$ drush --version
<paste output here>
```

## Required: relevant log excerpt

```text
$ tail -200 logs/<latest>-srsx.log
<paste here; redact secrets>
```

## Environment

- OS:
- Bash version (`bash --version`):
- Drupal version:
- `drupal/searchstax` version (`composer show drupal/searchstax`):
- Multisite? (Y/N):

## Anything else
