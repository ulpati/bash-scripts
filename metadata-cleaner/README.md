# 🛡️ Metadata Cleaner

Removes identifying metadata from files before you share them: EXIF and GPS
data in photos, document properties, Jupyter execution data, author comments
in code, extended attributes and modification times. An optional aggressive
mode also redacts secrets, e-mail addresses, home paths and private IP
addresses in text files. A final audit tells you what may still be there.

[![License](https://img.shields.io/badge/License-CC_BY--NC--SA_4.0-blue.svg)](../LICENSE)
![Bash](https://img.shields.io/badge/Bash-4.4+-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

## Contents

- [Installation](#installation)
- [Usage](#usage)
- [Options](#options)
- [What is cleaned](#what-is-cleaned)
- [Safety](#safety)
- [Limits](#limits)
- [Exit codes](#exit-codes)

## Installation

| Program | Needed for | Install on Debian/Ubuntu |
|---|---|---|
| Bash 4.4 or newer, coreutils, findutils | everything | preinstalled |
| ExifTool (includes Perl) | images, video, PDF, text processing | `sudo apt install libimage-exiftool-perl` |
| qpdf | PDF: removes the old values that ExifTool can only hide | `sudo apt install qpdf` |
| Python 3 | notebooks, extended attributes | preinstalled |
| mat2 (optional) | office documents, EPUB, ZIP, torrent and audio files | `sudo apt install mat2` |

```bash
git clone https://github.com/ulpati/bash-scripts.git
cd bash-scripts/metadata-cleaner
./metadata_cleaner.sh --help
```

## Usage

```bash
# Always preview first
./metadata_cleaner.sh --dry-run -r ~/Pictures/trip

# Clean a folder, keeping a backup of every file that is changed
./metadata_cleaner.sh -r --backup ~/Pictures/trip

# Prepare a project for publication: redact secrets and write a report
./metadata_cleaner.sh -r --aggressive --backup --report report.txt ./my-project

# In scripts there is no terminal to confirm, so pass --yes
./metadata_cleaner.sh -r --yes --strict ./dataset
```

The script counts the files, asks for confirmation, cleans them and prints a
summary such as `Cleaned: 12  Attributes only: 3  Skipped: 1  Failed: 0`.
"Attributes only" means that only the timestamp or extended attributes
changed: the file had no embedded metadata, or it is of a type the tool
cannot clean, which the summary points out. Warnings follow when something
could not be fully cleaned. A dry run or a cancelled run changes nothing, not
even the backup folder, and cleaning the same files again changes nothing.

## Options

| Option | Meaning |
|---|---|
| `-r`, `--recursive` | Process directories recursively. |
| `-n`, `-d`, `--dry-run` | Show what would be done without changing anything. |
| `-b`, `--backup` | Copy each file before changing it, mirroring its full path, to `~/.local/state/metadata-cleaner/backup-<time>`. |
| `--backup-dir DIR` | Use another backup directory. It must be outside the cleaned directory. |
| `-c`, `--compress` | Store the backup as a `.tar.gz` archive. |
| `-a`, `--aggressive` | Redact secrets, e-mails, home paths and private IPs in text files. |
| `--keep-outputs` | Keep notebook outputs; execution counts and metadata are still removed. |
| `--keep-timestamps` | Do not reset modification times to 1 January 2000. |
| `--keep-comments` | Do not remove `# Author:`, `// Date:` and similar comment lines. |
| `-p`, `--parallel` | Process 4 files at a time. |
| `-j`, `--jobs N` | Process N files at a time (1 to 64). |
| `--report FILE` | Write a detailed report, readable only by you. |
| `--checksums` | Add the SHA-256 of each cleaned file to the report. |
| `--strict` | Exit with code 4 when the audit still finds sensitive data. |
| `--sanitize-git` | Remove remotes, the local user name, e-mail and signing key, and stored credentials or authorization headers from `.git/config`. The old file is kept in the backup directory. |
| `-y`, `--yes` | Do not ask for confirmation. |
| `-v`, `--verbose` | Explain every step. |
| `--version`, `-h`, `--help` | Show the version or the help. |

## What is cleaned

| Files | How |
|---|---|
| JPEG, PNG, TIFF, GIF, WebP, HEIC | ExifTool removes EXIF, XMP, IPTC, GPS, ICC and camera tags; the image itself is not re-encoded |
| MP4, MOV, M4V, M4A, 3GP | ExifTool removes the metadata and sets the recording dates, which these formats require, to zero |
| PDF | ExifTool removes the document properties and XMP; qpdf then rebuilds the file without the old revision. Text, links and bookmarks are kept |
| Word, Excel, PowerPoint, OpenDocument, EPUB, ZIP, torrent, MP3, FLAC, Ogg, Opus | mat2; without it these files are left unchanged and a warning says so |
| Jupyter notebooks | outputs, execution counts, cell metadata and kernel details removed; the notebook stays valid |
| Code and configuration files | comment lines with author, creation or modification details removed |
| Text files with `--aggressive` | `password = "x"` becomes `password = "[REDACTED]"`, e-mails become `[EMAIL_REDACTED]`, `/home/name` becomes `/home/user`, private IPv4 addresses become `[PRIVATE_IP]` |
| Every file | extended attributes removed; modification time set to 2000-01-01 |

Other types, such as camera RAW files or `.doc`, only get the last row; the
summary counts them. Aggressive mode changes values, not lines, so code and
JSON stay valid. Review the result anyway: it cannot tell a real password
from a variable that happens to be called `token`.

After cleaning, an audit scans text files for secrets, e-mails, home paths
and private IPs. The report lists the file and the kind of finding, never the
value itself.

## Safety

Each point below is covered by a test in
[`../tests/metadata_cleaner.bats`](../tests/metadata_cleaner.bats).

- File names are passed to workers as arguments, never inserted into code, so
  a file called `photo$(rm -rf ~).jpg` is just a file name.
- Paths that start with `-` are passed as `./-name`, and `--` ends the options
  of every tool, so a file cannot inject command-line options.
- Symbolic links are never followed or modified.
- ExifTool, qpdf and mat2 write only inside a private temporary folder, never
  next to your files, so a link hidden in a downloaded folder cannot redirect
  what they write. The result is copied back into the original file:
  permissions are kept and every hard link to the file is cleaned too.
- Names are printed without control characters, so a file name cannot send
  escape sequences to your terminal or into the report.
- Only exact directory names are skipped (`.git`, `node_modules`, `build`…):
  a folder called `environment_photos` is cleaned.
- The backup directory may not be inside the cleaned directory. The report
  and new backup directories are accessible only to your user.
- The tool refuses to clean `/` and, without `--yes`, your whole home directory.

## Limits

- Removing metadata does not anonymise content: faces, text inside images,
  file names and the data itself are not changed.
- In PDF files only the document properties and XMP are removed. Photos
  embedded in a PDF keep their own EXIF data, so clean them before you put
  them in a document.
- Without qpdf, ExifTool's PDF changes are reversible: the old values stay in
  the file. The summary warns you when this happens.
- Camera RAW files are not changed, because removing their maker notes can
  make them unreadable.
- Files are cleaned through a private folder in `$TMPDIR` (`/tmp` by
  default), which needs as much free space as the largest file.
- `--sanitize-git` does not rewrite history; commit authors are still there.
  Use `git filter-repo` for that.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | At least one file could not be cleaned, or another error |
| 2 | Invalid command line |
| 3 | Cancelled, or confirmation needed without a terminal |
| 4 | `--strict` and the audit found sensitive data |

## License

[CC BY-NC-SA 4.0](../LICENSE). Part of the
[bash-scripts](https://github.com/ulpati/bash-scripts) collection.
