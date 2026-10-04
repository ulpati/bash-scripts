# Contributing

Bug reports, ideas and pull requests are welcome. This page explains how to
work on the scripts and what every change must respect.

## Contents

- [Setup](#setup)
- [Running the checks](#running-the-checks)
- [Secure coding rules](#secure-coding-rules)
- [Rules for each tool](#rules-for-each-tool)
- [Pull request checklist](#pull-request-checklist)
- [Reporting bugs and vulnerabilities](#reporting-bugs-and-vulnerabilities)

## Setup

You need Git, [ShellCheck](https://www.shellcheck.net/),
[bats-core](https://github.com/bats-core/bats-core) 1.5 or newer, ExifTool,
qpdf and mat2. Without mat2, its two tests are skipped.

```bash
# Debian/Ubuntu
sudo apt install shellcheck bats libimage-exiftool-perl qpdf mat2
```

## Running the checks

```bash
shellcheck -x ./*/*.sh life-game/modules/*.sh
shellcheck -s bash tests/*.bats tests/test_helper.bash
bats tests/
```

The scripts must keep working with Bash 4.4, the version of RHEL 8. CI runs
the suite with the Bash of Ubuntu; to test another interpreter locally:

```bash
BASH_UNDER_TEST=/path/to/bash-4.4 bats tests/
```

## Secure coding rules

- Never use `eval`, never `source` data files and never build commands as strings.
  Run commands as argument arrays: `"$@"`, `git push origin "$branch"`.
- Quote every expansion. Pass file names as arguments, never inside code
  given to `bash -c`, `perl -e`, `python -c` or `awk`; use `awk -v` for values.
- Validate input before using it: numbers with a regular expression before
  any arithmetic, URLs and names against an allow-list pattern.
- End option parsing with `--` before file names, and prefix relative paths
  that may start with `-` with `./`.
- Do not follow symbolic links when modifying files. Let helper programs
  write into a private folder made with `mktemp -d`, never next to the user's
  files, and copy the result back into the original file.
- Print names that come from files or from the file system through
  `printable`, so control characters cannot reach the terminal.
- Ask for confirmation before destructive actions and require `--yes` when
  there is no terminal. Offer `--dry-run`.
- Create private files with `umask 077`. Never print or log secrets.
- Keep `set -euo pipefail` and handle the errors you expect explicitly.
- Run `awk` and other number formatting with `LC_ALL=C`.

## Rules for each tool

- **Metadata Cleaner**: workers receive file names as arguments through
  `xargs -0`; never build code from a file name. Helpers write their result
  into the private folder of the file and only `copy_back` changes the
  original. Count a file as cleaned only when its content changed.
- **Publish Repository**: every command that changes the repository or the
  remote goes through `run` as separate arguments, so `--dry-run` prints it,
  shell-quoted, instead of executing it. The secret scan covers staged,
  modified and new files and stops the script when it cannot run. New secret
  patterns need a test that builds the fake secret at run time, so the test
  file never contains one.
- **Life Game**: keep the data file plain text, with its `format=1` line.
  Never `source` or `eval` it; add new settings to the `case` in `load_data`
  with a validation rule. Validate every number typed by the user with
  `is_uint` before arithmetic. Interactive helpers must not run inside
  `$(...)`; they return values through `CHOSEN`, so the end of input can stop
  the game.

## Pull request checklist

- [ ] ShellCheck reports nothing.
- [ ] `bats tests/` passes, also with `BASH_UNDER_TEST` set to Bash 4.4.
- [ ] New behaviour and every security check have a test.
- [ ] README, help text and CHANGELOG are updated.

## Reporting bugs and vulnerabilities

Open an issue with the command you ran, the output and your Linux
distribution. Report security problems privately as described in
[SECURITY.md](SECURITY.md).
