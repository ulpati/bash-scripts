# 🚀 Publish Repository

Initialises a Git repository if needed, shows what is about to be committed,
checks it for secrets, commits after your confirmation and pushes the current
branch to GitHub or any Git remote.

[![License](https://img.shields.io/badge/License-CC_BY--NC--SA_4.0-blue.svg)](../LICENSE)
![Bash](https://img.shields.io/badge/Bash-4.4+-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

## Requirements

- Linux with Bash 4.4 or newer, and Git
- [GitHub CLI](https://cli.github.com/) authenticated with `gh auth login`, only for `--create`

## Installation

```bash
git clone https://github.com/ulpati/bash-scripts.git
# Optional: start it from any folder as "publish-repo" (~/.local/bin must be on your PATH)
mkdir -p ~/.local/bin
ln -s "$PWD/bash-scripts/publish-repo/publish_repo.sh" ~/.local/bin/publish-repo
```

## Usage

The script publishes the repository of the folder it is started from, so go
to your project first. Without the link above, call the script by its path.

```bash
cd ~/my-project

# Preview every command without changing anything
publish-repo --remote git@github.com:USER/REPO.git --dry-run

# Commit the pending changes and push the current branch to an existing remote
publish-repo --remote git@github.com:USER/REPO.git

# Create a private GitHub repository and push to it
publish-repo --create --name my-repo

# Non-interactive use, for example in another script
publish-repo --yes --message "Update notes"
```

What happens:

1. The repository root is detected, worktrees and submodules included. The
   script refuses to run in `/` or in your home directory.
2. A new repository starts on `main`. Existing branches are never renamed.
3. Staged, modified and new files that are not ignored are listed with
   `git status`.
4. They are checked for secrets: risky file names such as `.env`, `*.pem` or
   `id_rsa`, and content such as private keys or AWS, GitHub, GitLab, Slack,
   Google, Stripe, npm and PyPI tokens. Binary files and files larger than
   1 MB are checked by name only. A finding, or a file that cannot be read,
   stops the script before anything is committed (exit code 4).
5. You confirm, then the changes are committed. Git hooks always run.
6. The remote is added, or changed after a second confirmation, and the
   current branch is pushed without `--force`.

`--dry-run` goes through the same steps, secret scan included, and prints
the commands instead of running them. In a folder that is not a repository
yet it creates nothing: a temporary Git directory outside the folder lists
the files.

## Options

| Option | Meaning |
|---|---|
| `--remote URL` | Remote for `origin`: `https://host/owner/repo.git`, `ssh://…`, `git@host:owner/repo.git` or `file:///path`. |
| `--create` | Create the repository on GitHub with `gh`. Needs `--name`. |
| `--name NAME` | Name for `--create`, as `repo` or `owner/repo`. |
| `--public` | Create a public repository. The default is private. |
| `-m`, `--message MSG` | Commit message (default "Publish repository"). |
| `-y`, `--yes` | Skip the confirmations. Needed when there is no terminal. |
| `--allow-secrets` | Commit even if files look like secrets. Not recommended. |
| `-n`, `--dry-run` | Print the commands, shell-quoted, without running them. |
| `-v`, `--verbose` | Print each command before running it. |
| `--version`, `-h`, `--help` | Show the version or the help. |

## Safety

Each point is covered by a test in
[`../tests/publish_repo.bats`](../tests/publish_repo.bats).

- Commands are argument arrays, never strings passed to `eval`. Remote URLs
  and repository names are validated first; `ext::` and other transports
  that can run commands are rejected.
- Branches are never renamed and nothing is force-pushed.
- Everything that would be committed, files staged before the run included,
  is scanned before the commit; Git hooks are never skipped.
- File names are printed without control characters, so a name cannot send
  escape sequences to the terminal.
- Any failure stops the script with a non-zero exit code.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Published, or dry run completed |
| 1 | Error |
| 2 | Invalid command line or unsafe URL or name |
| 3 | Cancelled, or confirmation needed without a terminal |
| 4 | Possible secrets found; nothing was committed |

## License

[CC BY-NC-SA 4.0](../LICENSE). Part of the
[bash-scripts](https://github.com/ulpati/bash-scripts) collection.
