# 🐚 Bash Scripts Collection

Three command-line tools for privacy, publishing and productivity, written
in Bash for Linux.

[![CI](https://github.com/ulpati/bash-scripts/actions/workflows/ci.yml/badge.svg)](https://github.com/ulpati/bash-scripts/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-CC_BY--NC--SA_4.0-blue.svg)](LICENSE)
![Bash](https://img.shields.io/badge/Bash-4.4+-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

## Tools

| Tool | What it does |
|---|---|
| [🛡️ Metadata Cleaner](metadata-cleaner/) | Removes EXIF, GPS, document and notebook metadata before you share files; can redact secrets and personal data in text files; audits the result. |
| [🚀 Publish Repository](publish-repo/) | Initialises a Git repository, scans the files about to be committed for secrets, commits after confirmation and pushes to GitHub or any remote. |
| [🎮 Life Game](life-game/) | Turns goals, daily tasks and weekly missions into a terminal game, with a study mode and Markdown plan import. |

```bash
git clone https://github.com/ulpati/bash-scripts.git
cd bash-scripts

metadata-cleaner/metadata_cleaner.sh --dry-run -r ~/Pictures/trip   # preview, changes nothing
life-game/life_game.sh

# Publish Repository publishes the folder it is started from
cd ~/my-project
/path/to/bash-scripts/publish-repo/publish_repo.sh --remote git@github.com:USER/REPO.git --dry-run
```

Each tool has `--help`, a `--dry-run` or confirmation step before changing
anything, and its own README. There is no installation step: the scripts run
from the cloned folder, or from anywhere once linked into a folder on your
`PATH`. The programs they rely on are listed below.

## Requirements

| | Needed by |
|---|---|
| Linux with Bash 4.4 or newer | all tools |
| Git | Publish Repository; Metadata Cleaner with `--sanitize-git` |
| GitHub CLI (`gh`) | Publish Repository with `--create` |
| ExifTool (with Perl), qpdf | Metadata Cleaner |
| Python 3 | Metadata Cleaner, for notebooks and extended attributes |
| mat2 (optional) | Metadata Cleaner, for office documents, EPUB, ZIP and audio files |

On Debian and Ubuntu: `sudo apt install git libimage-exiftool-perl qpdf mat2`.

## Security

The tools follow a secure development life cycle. The design decisions are
in the [threat model](docs/threat-model.md), and vulnerabilities can be
reported privately as described in [SECURITY.md](SECURITY.md).

The main rules, enforced by ShellCheck and by tests:

- no `eval`, no sourcing of data files, commands run as argument arrays;
- every input is validated before use, including numbers before arithmetic;
- file names are always arguments, after `--`; symbolic links are not
  followed, and helper programs never write next to your files;
- names are printed without control characters, so a file name cannot send
  escape sequences to the terminal;
- destructive actions need confirmation, with `--dry-run` previews;
- private files are created with restrictive permissions.

## Development

```bash
sudo apt install shellcheck bats libimage-exiftool-perl qpdf mat2
shellcheck -x ./*/*.sh life-game/modules/*.sh
bats tests/                          # 87 tests
```

CI runs ShellCheck and the tests on Ubuntu for every push and pull request.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the secure coding rules.

## License

[CC BY-NC-SA 4.0](LICENSE): free for non-commercial use with attribution;
adaptations must use the same license.

## Author

[@ulpati](https://github.com/ulpati)
