# Threat model

This document records the threats considered for each tool, as part of the
design phase of a secure development life cycle. All three tools run locally
with the privileges of the user who starts them, so the main risks are
untrusted input turning into commands and accidental damage to the user's own
files or repositories.

## Metadata Cleaner

**Assets**: the user's files and their privacy. **Untrusted input**: file
names and file contents, which often come from downloads or third parties.

| # | STRIDE | Threat | Mitigation |
|---|---|---|---|
| M1 | Elevation of privilege | A file name such as `x$(cmd).jpg` runs a command. | Names are passed to workers as arguments through `xargs -0`; no code is built from data. The internal worker mode needs an environment variable, so a file called `--worker` is only an unknown option. |
| M2 | Tampering | A name starting with `-` is read as an option by ExifTool, qpdf or mat2. | Paths are passed as `./name` and after `--`. |
| M3 | Tampering | A symbolic link makes the tool write outside the target: the file itself is a link, or a link waits at the name a helper writes to (`NAME_exiftool_tmp` for ExifTool, `NAME.cleaned.EXT` for mat2). | Symbolic links are skipped and `find` does not follow them. Helpers write only inside a private temporary folder (mode 700), and the result is copied back into the original file. |
| M4 | Information disclosure | Metadata survives and the user believes it was removed. | A file counts as cleaned only when its content changed. PDF files are rebuilt by qpdf, so hidden revisions are dropped. Missing helpers, unsupported types and recoverable PDF edits are reported on screen. Hard links are cleaned too. A final audit checks text files. |
| M5 | Information disclosure | The report copies the secrets it found. | The report names the file and the kind of finding only. It is created with mode 600 and may not be a symbolic link; new backup folders are private. |
| M6 | Denial of service / data loss | A mistaken target such as `/` or the home folder, a backup inside the target, or an interrupted write that truncates a file. | `/` is refused, the home folder needs `--yes`, the backup must be outside the target, confirmation is required, `--dry-run` previews. Ctrl-C and termination signals are ignored while a cleaned file is copied back; read-only files are reported, not forced. |
| M7 | Tampering | Aggressive mode corrupts files. | Only values are redacted; the substitution is idempotent and keeps JSON valid. Backups are available. |
| M8 | Tampering | `--sanitize-git` on a folder whose `.git` is broken makes Git search the parent folders and change another repository. | Git runs with `--git-dir` pinned to the selected folder; an invalid `.git` is skipped with a warning. |
| M9 | Information disclosure | Credentials in `.git/config`, such as tokens in remote URLs or CI authorization headers, are shared with the folder. | `--sanitize-git` removes remotes, `credential.*` settings and `http.*.extraheader`; the old file is kept in the backup folder. |
| M10 | Tampering | A file name with escape sequences changes the terminal or the report when printed. | Control characters are replaced with `?` before anything is printed. |

## Publish Repository

**Assets**: the local repository, its branches and anything that must stay
private. **Untrusted input**: command-line arguments, which may come from
copied instructions or other scripts, and the names of the files in the
project.

| # | STRIDE | Threat | Mitigation |
|---|---|---|---|
| P1 | Elevation of privilege | A crafted `--remote` or `--name` runs commands. | No `eval`; commands are argument arrays; URLs and names must match allow-list patterns; `ext::` and other transports are rejected. |
| P2 | Information disclosure | Secrets such as `.env`, private keys or tokens are published, including files staged before the run. | Staged, modified and new files are listed and scanned by name and content. The commit stops on findings, on files that cannot be read and when the list cannot be built. Git hooks run; confirmation is required. |
| P3 | Tampering | Local work is lost because a branch is renamed or overwritten. | Branches are never renamed; pushes never use `--force`. |
| P4 | Spoofing | The remote is silently changed to another repository. | Changing an existing `origin` shows the old URL and asks for confirmation. |
| P5 | Denial of service | Publishing the home folder or `/` by mistake. | Both are refused. |
| P6 | Tampering | A file name with escape sequences changes the terminal when printed. | Control characters are replaced with `?`. |

## Life Game

**Assets**: the user's account (code execution) and the progress data.
**Untrusted input**: Markdown plans downloaded from others, the data file,
keyboard input.

| # | STRIDE | Threat | Mitigation |
|---|---|---|---|
| L1 | Elevation of privilege | Text like `$(cmd)` in a task runs when the data file is loaded. | The data file is parsed line by line with an allow-list of keys; it is never sourced or evaluated. |
| L2 | Elevation of privilege | Arithmetic on raw input such as `a[$(cmd)]` runs a command. | Numbers are validated with a regular expression before arithmetic. |
| L3 | Elevation of privilege | Values interpolated into `awk` code. | Values are passed with `awk -v`. |
| L4 | Tampering | A symbolic link redirects writes to another file. | A symbolic link as data file or Pomodoro log is refused; the data file is written through a temporary file and `mv`. |
| L5 | Denial of service | Very long sessions exhaust the stack through recursive menus. | Menus are loops. |
| L6 | Information disclosure | Other users read the progress data. | Data folder 700 and files 600. |
| L7 | Tampering | A mistaken `--data-dir` makes the game overwrite a `progress.txt` that is not its own. | A file without the `format=1` line is refused and left unchanged. |
| L8 | Tampering | Escape sequences in an imported plan change the terminal. | Control characters, including the C1 range, are removed from names. |

## Residual risks

- Aggressive redaction relies on patterns and can miss secrets or change
  harmless values. Always review the result before publishing.
- The secret scan in Publish Repository is a safety net, not a replacement for
  a dedicated scanner such as gitleaks in a pre-commit hook.
- Removing metadata does not anonymise the content of files, and images
  embedded in a PDF keep their own metadata.
- Another local user who can write to the cleaned folder while the cleaner
  runs could replace a file with a symbolic link between the check and the
  copy back. Clean folders that only you can write to.
