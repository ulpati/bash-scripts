#!/usr/bin/env bash
#
# metadata_cleaner.sh - remove identifying metadata from files before sharing them.
#
# Repository: https://github.com/ulpati/bash-scripts
# License:    CC BY-NC-SA 4.0
#
# Design rules (see README.md and ../docs/threat-model.md):
#   * file names are always passed as arguments, never interpolated into code;
#   * symbolic links are never followed or modified;
#   * helper tools write only inside a private temporary folder, never next to the user's files;
#     the result is copied back into the original file, so permissions and hard links are kept;
#   * a file is reported as cleaned only when its content really changed;
#   * backups are copied file by file, outside the cleaned directory;
#   * reports never contain the sensitive values they flag.
#
# Needs Bash 4.4 or newer.

# Stop early with a clear message when started with sh, dash or zsh instead of Bash.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "This script needs Bash. Run it as: bash $0" >&2
    exit 2
fi

set -euo pipefail
IFS=$'\n\t'
umask 077

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="${0##*/}"
# Directory of this script, following symbolic links.
script_dir() {
    local source="${BASH_SOURCE[0]}" dir
    while [[ -L "$source" ]]; do
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" == /* ]] || source="$dir/$source"
    done
    cd -P "$(dirname "$source")" && pwd
}
SCRIPT_PATH="$(script_dir)/metadata_cleaner.sh"
readonly SCRIPT_PATH
readonly NEUTRAL_TIME="200001010000.00"

readonly E_ERROR=1 E_USAGE=2 E_CANCELLED=3 E_FINDINGS=4

readonly EXCLUDED_DIRS=".git node_modules __pycache__ .venv venv .tox .mypy_cache .pytest_cache .ruff_cache dist build"
readonly EXCLUDED_EXTENSIONS="pyc pyo so dylib dll exe o a class"
# ExifTool cleans these types without re-encoding the image, audio or video data.
readonly EXIF_EXTENSIONS="jpg jpeg png tif tiff gif webp heic heif mp4 m4v m4a mov 3gp pdf"
# -CommonIFD0= also removes the camera and software tags that -all= keeps in TIFF files, and
# -QuickTime:Time:All= sets the recording dates of videos, which cannot be deleted, to zero.
readonly -a EXIFTOOL_CLEAN=(-all= -CommonIFD0= -QuickTime:Time:All=)
# Types that only mat2 can clean.
readonly MAT2_EXTENSIONS="docx xlsx pptx odt ods odp odg epub zip torrent mp3 flac ogg opus"
readonly TEXT_EXTENSIONS="md txt csv tsv json yml yaml xml html htm svg css js mjs ts tsx jsx py sh bash zsh fish sql ini cfg conf toml r rb pl php java kt c h cc cpp hpp cs go rs swift lua env properties"
readonly CODE_EXTENSIONS="py sh bash zsh fish yml yaml toml ini cfg conf r rb pl php js mjs ts tsx jsx java kt c h cc cpp hpp cs go rs swift lua sql css properties"

# Patterns shared by aggressive redaction and the audit (Perl regular expressions).
readonly RE_SECRET='(?i)\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key|client[_-]?secret|auth[_-]?token|access[_-]?token|token)\b["'"'"']?\s*[:=]\s*(?!["'"'"']?\[REDACTED\])("[^"\n]*"|'"'"'[^'"'"'\n]*'"'"'|[^\s,;}]+)'
readonly RE_EMAIL='\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b'
readonly RE_HOME='(?:/home/|/Users/|[Cc]:\\Users\\)(?!user\b)[A-Za-z0-9._-]+'
readonly RE_PRIVATE_IP='(?<![\d.])(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(?![\d.])'
# Perl reads the patterns from the environment, so they are never inserted into its code.
export MC_RE_SECRET="$RE_SECRET" MC_RE_EMAIL="$RE_EMAIL" MC_RE_HOME="$RE_HOME" MC_RE_PRIVATE_IP="$RE_PRIVATE_IP"

# Options; parallel workers receive them through MC_* environment variables.
DRY_RUN=0 RECURSIVE=0 BACKUP=0 COMPRESS=0 AGGRESSIVE=0 KEEP_OUTPUTS=0 KEEP_TIMESTAMPS=0
KEEP_COMMENTS=0 PARALLEL=0 JOBS=4 CHECKSUMS=0 STRICT=0 SANITIZE_GIT=0 ASSUME_YES=0 VERBOSE=0
BACKUP_DIR="" REPORT_FILE=""
TARGETS=()
NEW_BACKUP_DIR=""   # set when this run created the backup directory
WORK_DIR=""         # private temporary folder of this run; see main
REPORT_ABS=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' BLUE=$'\033[0;34m' NC=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" BLUE="" NC=""
fi

# Replace control characters, such as the escape sequences a hostile file name can contain, so
# that printing a name can never send commands to the terminal.
printable() {
    local text="$1"
    printf '%s' "${text//[[:cntrl:]]/?}"
}

info()    { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$(printable "$*")"; }
success() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$(printable "$*")"; }
warn()    { printf '%s[WARNING]%s %s\n' "$YELLOW" "$NC" "$(printable "$*")" >&2; }
verbose() { if (( VERBOSE )); then printf '[VERBOSE] %s\n' "$(printable "$*")" >&2; fi; }
die()     { local code="${2:-$E_ERROR}"; printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$(printable "$1")" >&2; exit "$code"; }
usage_error() { printf '%s: %s\nTry "%s --help".\n' "$SCRIPT_NAME" "$1" "$SCRIPT_NAME" >&2; exit "$E_USAGE"; }

usage() {
    cat <<EOF
$SCRIPT_NAME $VERSION - remove identifying metadata from files

Usage: $SCRIPT_NAME [OPTIONS] PATH...

Options:
  -r, --recursive        Process directories recursively
  -n, -d, --dry-run      Show what would be done without changing anything
  -b, --backup           Copy every file to a backup before changing it
      --backup-dir DIR   Backup location (default: ~/.local/state/metadata-cleaner/backup-<time>)
  -c, --compress         Store the backup as a .tar.gz archive
  -a, --aggressive       Redact secrets, e-mail addresses, home paths and private IPs in text files
      --keep-outputs     Keep Jupyter notebook outputs (execution data is still removed)
      --keep-timestamps  Do not reset modification times
      --keep-comments    Do not remove "Author:", "Date:" and similar comment lines from code
  -p, --parallel         Process 4 files at a time
  -j, --jobs N           Process N files at a time (1-64)
      --report FILE      Write a detailed report (created with permissions 600)
      --checksums        Add the SHA-256 of every cleaned file to the report
      --strict           Exit with code 4 if the audit still finds sensitive data
      --sanitize-git     Remove remotes, local identity and stored credentials from .git/config
                         of the given directories
  -y, --yes              Do not ask for confirmation (needed when not running in a terminal)
  -v, --verbose          Explain every step
      --version          Show the version
  -h, --help             Show this help

What is cleaned:
  Images, video, M4A, PDF     EXIF, XMP, IPTC, GPS, camera details and recording dates (ExifTool);
                              qpdf then rebuilds PDF files so the old values cannot be recovered
  Office, ODF, EPUB, ZIP,     metadata removed by mat2; without mat2 they are reported, not changed
  torrent, MP3, FLAC, Ogg, Opus
  Jupyter notebooks           execution counts, cell metadata, kernel details and (by default) outputs
  Code files                  comment lines such as "# Author:" or "// Date:"
  Every file                  extended attributes and, unless --keep-timestamps, modification time

Exit codes: 0 success, 1 some files failed, 2 usage error, 3 cancelled, 4 audit findings with --strict.
EOF
}

need_value() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        usage_error "option $1 requires a value"
    fi
}

# Targets that start with "-" get a "./" prefix, so no tool can read them as options.
add_target() {
    case "$1" in
        -*) TARGETS+=("./$1") ;;
        *) TARGETS+=("$1") ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--recursive) RECURSIVE=1; shift ;;
            -n|-d|--dry-run) DRY_RUN=1; shift ;;
            -b|--backup) BACKUP=1; shift ;;
            --backup-dir) need_value "$@"; BACKUP=1; BACKUP_DIR="$(safe_arg "$2")"; shift 2 ;;
            -c|--compress) COMPRESS=1; BACKUP=1; shift ;;
            -a|--aggressive) AGGRESSIVE=1; shift ;;
            --keep-outputs) KEEP_OUTPUTS=1; shift ;;
            --keep-timestamps) KEEP_TIMESTAMPS=1; shift ;;
            --keep-comments) KEEP_COMMENTS=1; shift ;;
            -p|--parallel) PARALLEL=1; shift ;;
            -j|--jobs) need_value "$@"; JOBS="$2"; PARALLEL=1; shift 2 ;;
            --report) need_value "$@"; REPORT_FILE="$(safe_arg "$2")"; shift 2 ;;
            --checksums) CHECKSUMS=1; shift ;;
            --strict) STRICT=1; shift ;;
            --sanitize-git) SANITIZE_GIT=1; shift ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            -v|--verbose) VERBOSE=1; shift ;;
            --version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            --) shift; while [[ $# -gt 0 ]]; do add_target "$1"; shift; done ;;
            -*) usage_error "unknown option: $1" ;;
            *) add_target "$1"; shift ;;
        esac
    done
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        usage_error "no path given"
    fi
    if [[ ! "$JOBS" =~ ^[0-9]+$ ]] || (( JOBS < 1 || JOBS > 64 )); then
        usage_error "--jobs must be a number between 1 and 64"
    fi
}

# ---------------------------------------------------------------- helpers
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Lower-case extension; for dotfiles without another dot (".env") the name itself.
extension_of() {
    local base="${1##*/}" name
    name="${base#.}"
    if [[ "$name" == *.* ]]; then
        lower "${name##*.}"
    elif [[ "$base" == .* ]]; then
        lower "$name"
    fi
}

# in_list WORD "space separated list"
in_list() {
    local needle="$1" item IFS=' '
    for item in $2; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Absolute, physical path of an existing file or directory.
abs_path() {
    if [[ -d "$1" ]]; then
        (cd -- "$1" && pwd -P)
    else
        printf '%s/%s\n' "$(cd -- "$(dirname -- "$1")" && pwd -P)" "$(basename -- "$1")"
    fi
}

# Make a path safe to hand to tools that parse options: never let it start with "-".
safe_arg() {
    case "$1" in
        -*) printf './%s' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

sha256_of() {
    sha256sum -- "$1" | cut -d' ' -f1
}

is_text_file() {
    [[ -s "$1" ]] && grep -Iq . -- "$1" 2>/dev/null
}

# End the run on Ctrl-C or a termination request; the EXIT trap of the main process then removes
# the temporary folder.
set_signal_handlers() {
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
}

# Copy a cleaned result back into the original file. The file keeps its inode, so its
# permissions, owner and every hard link to it stay as they are. Signals are ignored meanwhile,
# because an interrupted copy would leave a truncated file. Redirections apply from left to
# right: the result is opened first, so the original is never emptied when it cannot be read.
copy_back() {
    local status=0
    trap '' INT TERM HUP
    cat < "$1" > "$2" || status=$?
    set_signal_handlers
    return "$status"
}

# Rewrite a PDF with qpdf, which writes only the objects still in use. Exit code 3 means
# "succeeded with warnings", for example after repairing a damaged cross-reference table.
qpdf_rewrite() {
    local status=0
    qpdf --deterministic-id -- "$1" "$2" >/dev/null 2>&1 || status=$?
    (( status == 0 || status == 3 )) && [[ -s "$2" ]]
}

# Rebuild a PDF so the old values that ExifTool merely hid in an earlier revision are dropped.
# --deterministic-id makes the result depend only on the content. A file without a document ID
# gets its final ID on the second rewrite, so two passes make a second cleaning change nothing.
rebuild_pdf() {
    qpdf_rewrite "$1" "$2.first" && qpdf_rewrite "$2.first" "$2"
}

# mat2 writes "NAME.cleaned.EXT" next to the file it cleans, so it cleans a copy inside the
# private work folder. Prints the path of the cleaned copy.
mat2_clean() {
    local file="$1" ext="$2" work="$3"
    cp -- "$file" "$work/input.$ext" || return 1
    mat2 -- "$work/input.$ext" >/dev/null 2>&1 || return 1
    [[ -s "$work/input.cleaned.$ext" ]] || return 1
    printf '%s' "$work/input.cleaned.$ext"
}

strip_comment_metadata() {
    perl -ne 'print unless /^\s*(?:#|\/\/|--|;)\s*(?:author|created(?:\s+(?:on|at|by))?|date|modified(?:\s+(?:on|at|by))?|last[\s-]*modified|maintainer)\s*:/i'
}

redact_sensitive() {
    perl -pe '
        s/$ENV{MC_RE_SECRET}/my ($all, $v) = ($&, $1); my $q = substr($v, 0, 1); $q = chr(34) unless $q eq chr(34) || $q eq chr(39); substr($all, 0, length($all) - length($v)) . $q . "[REDACTED]" . $q/ge;
        s/$ENV{MC_RE_EMAIL}/[EMAIL_REDACTED]/g;
        s{(/home/|/Users/|[Cc]:\\Users\\)(?!user\b)[A-Za-z0-9._-]+}{${1}user}g;
        s/$ENV{MC_RE_PRIVATE_IP}/[PRIVATE_IP]/g;
    '
}

# Print the notebook without execution data and private metadata; the file itself is not changed.
clean_notebook() {
    python3 - "$1" "$KEEP_OUTPUTS" <<'PY'
import json, sys

path, keep_outputs = sys.argv[1], sys.argv[2] == "1"
with open(path, encoding="utf-8") as handle:
    notebook = json.load(handle)
if not isinstance(notebook, dict) or not isinstance(notebook.get("cells"), list):
    sys.exit("not a Jupyter notebook")
language = (notebook.get("metadata", {}).get("language_info") or {}).get("name", "python")
notebook["metadata"] = {"language_info": {"name": language}}
for cell in notebook["cells"]:
    cell["metadata"] = {}
    if cell.get("cell_type") == "code":
        cell["execution_count"] = None
        if keep_outputs:
            for output in cell.get("outputs", []):
                if "execution_count" in output:
                    output["execution_count"] = None
                if "metadata" in output:
                    output["metadata"] = {}
        else:
            cell["outputs"] = []
sys.stdout.buffer.write((json.dumps(notebook, indent=1, ensure_ascii=False) + "\n").encode("utf-8"))
PY
}

remove_xattrs() {
    local file="$1"
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$file" <<'PY'
import os, sys
path = sys.argv[1]
names = [n for n in os.listxattr(path, follow_symlinks=False) if not n.startswith("security.")]
for name in names:
    os.removexattr(path, name, follow_symlinks=False)
if names:
    sys.stdout.write("changed")
PY
}

# Copy a file into the backup directory, mirroring its absolute path so names never collide.
backup_file() {
    local dest
    dest="$BACKUP_DIR$(abs_path "$1")"
    [[ -e "$dest" ]] && return 0
    mkdir -p -- "$(dirname -- "$dest")"
    cp -p -- "$1" "$dest"
}

# How a file is cleaned: notebook, exiftool, mat2, needs-mat2, text, or nothing (attributes only).
plan_for() {
    local ext="$1"
    [[ -n "$ext" ]] || return 0
    if [[ "$ext" == "ipynb" ]]; then echo notebook
    elif in_list "$ext" "$EXIF_EXTENSIONS"; then echo exiftool
    elif in_list "$ext" "$MAT2_EXTENSIONS"; then
        if command -v mat2 >/dev/null 2>&1; then echo mat2; else echo needs-mat2; fi
    elif in_list "$ext" "$TEXT_EXTENSIONS"; then echo text
    fi
    return 0
}

# ---------------------------------------------------------------- per-file worker
# Prints one NUL-terminated record: STATUS <TAB> DETAILS <TAB> PATH
#   STATUS is cleaned, attributes (only timestamps/xattrs), skipped, failed or planned (dry run).
emit() { printf '%s\t%s\t%s\0' "$1" "$2" "$3"; }

clean_one() {
    local file="$1" abs ext arg plan steps="" note="" attr_steps="" failed="" content=0 attrs=0
    local work result="" current out
    if [[ -L "$file" ]]; then emit skipped "symbolic link" "$file"; return 0; fi
    if [[ ! -f "$file" ]]; then emit skipped "not a regular file" "$file"; return 0; fi
    abs="$(abs_path "$file")"
    if [[ -n "$REPORT_ABS" && "$abs" == "$REPORT_ABS" ]]; then
        emit skipped "report file" "$file"; return 0
    fi
    if [[ "$abs" == "$WORK_DIR"/* ]]; then emit skipped "temporary file of this run" "$file"; return 0; fi
    ext="$(extension_of "$file")"
    if [[ -n "$ext" ]] && in_list "$ext" "$EXCLUDED_EXTENSIONS"; then
        emit skipped "excluded type" "$file"; return 0
    fi
    arg="$(safe_arg "$file")"
    plan="$(plan_for "$ext")"

    if (( DRY_RUN )); then
        emit planned "${plan:-attributes only}" "$file"; return 0
    fi
    if (( BACKUP )); then
        backup_file "$file" || { emit failed "backup failed" "$file"; return 0; }
    fi

    # Every helper writes its result into this private folder; only copy_back touches the file.
    work="$(mktemp -d "$WORK_DIR/file.XXXXXX")" || { emit failed "no temporary folder" "$file"; return 0; }
    case "$plan" in
        notebook)
            if clean_notebook "$file" > "$work/clean.ipynb" 2>/dev/null; then
                result="$work/clean.ipynb"; steps="notebook"
            else
                failed="notebook"
            fi ;;
        exiftool)
            if exiftool "${EXIFTOOL_CLEAN[@]}" -o "$work/clean.$ext" -- "$arg" >/dev/null 2>&1; then
                result="$work/clean.$ext"; steps="exiftool"
                if [[ "$ext" == "pdf" ]]; then
                    if ! command -v qpdf >/dev/null 2>&1; then
                        note="old PDF metadata recoverable: install qpdf"
                    elif rebuild_pdf "$result" "$work/rebuilt.pdf"; then
                        result="$work/rebuilt.pdf"; steps="exiftool+qpdf"
                    else
                        note="old PDF metadata recoverable: qpdf could not rebuild the file"
                    fi
                fi
            else
                failed="exiftool"
            fi ;;
        mat2)
            if out="$(mat2_clean "$file" "$ext" "$work")"; then result="$out"; steps="mat2"; else failed="mat2"; fi ;;
        needs-mat2)
            note="metadata kept: install mat2 for this type" ;;
        text)
            if is_text_file "$file"; then
                current="$file"
                if (( ! KEEP_COMMENTS )) && in_list "$ext" "$CODE_EXTENSIONS"; then
                    if strip_comment_metadata < "$file" > "$work/comments"; then
                        cmp -s -- "$file" "$work/comments" || steps="comments"
                        current="$work/comments"
                    else
                        failed="comments"
                    fi
                fi
                if (( AGGRESSIVE )) && [[ -z "$failed" ]]; then
                    if redact_sensitive < "$current" > "$work/redacted"; then
                        cmp -s -- "$current" "$work/redacted" || steps="${steps:+$steps+}redacted"
                        current="$work/redacted"
                    else
                        failed="redaction"
                    fi
                fi
                [[ "$current" == "$file" ]] || result="$current"
            fi ;;
        *)
            if [[ -s "$file" ]] && ! is_text_file "$file"; then note="type not supported"; fi ;;
    esac

    if [[ -n "$result" && -z "$failed" ]]; then
        if cmp -s -- "$file" "$result"; then
            steps="" note="nothing to remove"
        elif [[ ! -w "$file" ]]; then
            failed="read-only file"
        elif copy_back "$result" "$file"; then
            content=1
        else
            failed="could not write the file"
        fi
    fi
    rm -rf -- "$work"

    if out="$(remove_xattrs "$file" 2>/dev/null)"; then
        [[ "$out" == "changed" ]] && { attrs=1; attr_steps="xattrs"; }
    fi
    if (( ! KEEP_TIMESTAMPS )); then
        if touch -t "$NEUTRAL_TIME" -- "$file" 2>/dev/null; then
            attrs=1; attr_steps="${attr_steps:+$attr_steps+}timestamp"
        else
            failed="${failed:+$failed+}timestamp"
        fi
    fi

    if [[ -n "$failed" ]]; then
        if (( content )); then failed="$failed (content cleaned: $steps)"; fi
        emit failed "$failed" "$file"
    elif (( content )); then
        emit cleaned "$steps${note:+; $note}" "$file"
    elif (( attrs )); then
        emit attributes "$attr_steps${note:+; $note}" "$file"
    else
        emit skipped "${note:-nothing to clean}" "$file"
    fi
}

# ---------------------------------------------------------------- orchestration
list_files() {
    local target="$1" name ext IFS=' '
    if [[ -L "$target" ]]; then
        printf '%s\0' "$target"
        return 0
    fi
    if [[ -f "$target" ]]; then
        printf '%s\0' "$target"
        return 0
    fi
    local prune=() first=1
    for name in $EXCLUDED_DIRS; do
        if (( first )); then prune+=(-name "$name"); first=0; else prune+=(-o -name "$name"); fi
    done
    local skip=()
    for ext in $EXCLUDED_EXTENSIONS; do
        skip+=(! -name "*.$ext")
    done
    if (( RECURSIVE )); then
        find "$(safe_arg "$target")" -mindepth 1 \( -type d \( "${prune[@]}" \) -prune \) -o \( -type f "${skip[@]}" -print0 \)
    else
        find "$(safe_arg "$target")" -mindepth 1 -maxdepth 1 -type f "${skip[@]}" -print0
    fi
}

audit_file() {
    perl -ne '
        $f{secret} = 1 if /$ENV{MC_RE_SECRET}/;
        $f{email} = 1 if /$ENV{MC_RE_EMAIL}/;
        $f{home_path} = 1 if /$ENV{MC_RE_HOME}/;
        $f{private_ip} = 1 if /$ENV{MC_RE_PRIVATE_IP}/;
        END { print join(",", sort keys %f) }
    ' -- "$1" 2>/dev/null
}

sanitize_git_dir() {
    local dir="$1" remote
    [[ -d "$dir/.git" && ! -L "$dir/.git" ]] || return 0
    # --git-dir pins Git to this repository: with "git -C", a broken .git would make Git
    # search the parent folders and change the configuration of another repository.
    local -a repo_git=(git "--git-dir=$dir/.git")
    if ! "${repo_git[@]}" rev-parse --git-dir >/dev/null 2>&1; then
        warn "$dir/.git is not a valid Git repository; its configuration was not changed."
        return 0
    fi
    info "Sanitising Git configuration in $dir"
    if (( DRY_RUN )); then
        printf '  would remove remotes, local user.name, user.email, user.signingkey and stored credentials\n'
        return 0
    fi
    # The backup mirrors the absolute path, so two repositories with the same name never collide.
    local backup key
    backup="$BACKUP_DIR$(abs_path "$dir")/.git/config"
    mkdir -p -- "$(dirname -- "$backup")"
    cp -p -- "$dir/.git/config" "$backup"
    for remote in $("${repo_git[@]}" remote); do
        "${repo_git[@]}" remote remove "$remote"
    done
    "${repo_git[@]}" config --local --unset-all user.name 2>/dev/null || true
    "${repo_git[@]}" config --local --unset-all user.email 2>/dev/null || true
    "${repo_git[@]}" config --local --unset-all user.signingkey 2>/dev/null || true
    # Credential settings and authorization headers, such as the token that CI checkouts store in
    # http.<url>.extraheader.
    for key in $("${repo_git[@]}" config --local --name-only --get-regexp '^(credential\..*|http\..*extraheader)$' 2>/dev/null | sort -u); do
        "${repo_git[@]}" config --local --unset-all "$key" 2>/dev/null || true
    done
    warn "Commit history still contains author names and e-mails; rewrite it with git filter-repo if needed."
}

report() {
    [[ -n "$REPORT_FILE" ]] && printf '%s\n' "$(printable "$*")" >> "$REPORT_FILE"
    return 0
}

# True when the backup holds something: a compressed archive or a non-empty directory.
backup_used() {
    [[ -f "$BACKUP_DIR" ]] || { [[ -d "$BACKUP_DIR" ]] && [[ -n "$(ls -A -- "$BACKUP_DIR")" ]]; }
}

# On exit, remove the private temporary folder and a backup directory that this run created but
# never used (dry run, cancelled run, refused target). rmdir only removes empty directories.
cleanup() {
    if [[ -n "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi
    if [[ -n "$NEW_BACKUP_DIR" && -d "$NEW_BACKUP_DIR" ]]; then rmdir -- "$NEW_BACKUP_DIR" 2>/dev/null || true; fi
}

main() {
    # Parallel workers are this script started by xargs. The environment variable set by the main
    # process is required too, so a file called "--worker" in "metadata_cleaner.sh *" is only an
    # unknown option.
    if [[ "${1:-}" == "--worker" && -n "${MC_WORK_DIR:-}" ]]; then
        shift
        load_worker_options
        set_signal_handlers
        local file
        for file in "$@"; do clean_one "$file"; done
        return 0
    fi
    parse_args "$@"

    command -v perl >/dev/null 2>&1 || die "perl is required (it is installed together with ExifTool)."
    command -v exiftool >/dev/null 2>&1 || die "exiftool is required. Install it with: sudo apt install libimage-exiftool-perl"
    command -v mat2 >/dev/null 2>&1 || verbose "mat2 not found: office documents and audio files will keep their metadata."

    local target abs
    for target in "${TARGETS[@]}"; do
        [[ -e "$target" || -L "$target" ]] || die "Path does not exist: $target"
        if [[ -d "$target" && ! -L "$target" ]]; then
            abs="$(abs_path "$target")"
            [[ "$abs" == "/" ]] && die "Refusing to clean the whole file system."
            [[ "$abs" == "$(cd "${HOME:-/}" && pwd -P)" ]] && (( ! ASSUME_YES )) && \
                die "Refusing to clean your whole home directory without --yes."
        fi
    done

    trap cleanup EXIT
    set_signal_handlers
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    if (( BACKUP || SANITIZE_GIT )) && [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="${XDG_STATE_HOME:-${HOME:-.}/.local/state}/metadata-cleaner/backup-$stamp"
    fi
    if [[ -n "$BACKUP_DIR" ]]; then
        local created=0
        [[ -e "$BACKUP_DIR" ]] || created=1
        mkdir -p -- "$BACKUP_DIR" || die "Cannot create the backup directory $BACKUP_DIR"
        # Compare real paths, so symbolic links or ".." cannot place the backup inside a target.
        BACKUP_DIR="$(abs_path "$BACKUP_DIR")"
        if (( created )); then NEW_BACKUP_DIR="$BACKUP_DIR"; fi
        for target in "${TARGETS[@]}"; do
            if [[ -d "$target" ]]; then
                abs="$(abs_path "$target")"
                case "$BACKUP_DIR/" in
                    "$abs"/*) die "The backup directory must be outside the target '$target'." ;;
                    *) ;;
                esac
            fi
        done
    fi

    if [[ -n "$REPORT_FILE" ]]; then
        [[ ! -L "$REPORT_FILE" ]] || die "The report file may not be a symbolic link: $REPORT_FILE"
        { : > "$REPORT_FILE" && chmod 600 -- "$REPORT_FILE"; } 2>/dev/null || die "Cannot write the report to $REPORT_FILE"
        REPORT_ABS="$(abs_path "$REPORT_FILE")"
    fi

    # Private temporary folder (mode 700) for the file lists and for every cleaned copy.
    WORK_DIR="$(mktemp -d -- "${TMPDIR:-/tmp}/metadata-cleaner.XXXXXX")" || die "Cannot create a temporary folder."
    WORK_DIR="$(abs_path "$WORK_DIR")"
    local list="$WORK_DIR/files" results="$WORK_DIR/results"
    : > "$list"
    : > "$results"
    for target in "${TARGETS[@]}"; do
        list_files "$target" >> "$list"
    done
    local total
    total="$(tr -cd '\0' < "$list" | wc -c | tr -d ' ')"
    info "Files to process: $total"
    if (( DRY_RUN )); then
        warn "Dry run: nothing will be changed."
    elif (( total > 0 && ! ASSUME_YES )); then
        if [[ ! -t 0 ]]; then
            die "Confirmation needed but no terminal is attached. Re-run with --yes." "$E_CANCELLED"
        fi
        local answer="" note=" without backup"
        (( BACKUP )) && note=" with backup"
        read -r -p "Modify $total file(s) in place$note? [y/N] " answer || true
        case "$answer" in y|Y|yes|YES) ;; *) die "Cancelled by the user." "$E_CANCELLED" ;; esac
    fi

    if (( PARALLEL && total > 1 )); then
        verbose "Parallel mode: $JOBS workers"
        export_worker_options
        xargs -0 -n 16 -P "$JOBS" "$BASH" "$SCRIPT_PATH" --worker < "$list" >> "$results"
    else
        local file
        while IFS= read -r -d '' file; do
            clean_one "$file" >> "$results"
        done < "$list"
    fi

    if (( SANITIZE_GIT )); then
        for target in "${TARGETS[@]}"; do
            [[ -d "$target" ]] && sanitize_git_dir "$target"
        done
    fi

    summarize "$results" "$list"
}

# Options are handed to the parallel workers through MC_* environment variables.
export_worker_options() {
    export MC_DRY_RUN="$DRY_RUN" MC_BACKUP="$BACKUP" MC_BACKUP_DIR="$BACKUP_DIR" MC_AGGRESSIVE="$AGGRESSIVE"
    export MC_KEEP_OUTPUTS="$KEEP_OUTPUTS" MC_KEEP_TIMESTAMPS="$KEEP_TIMESTAMPS" MC_KEEP_COMMENTS="$KEEP_COMMENTS"
    export MC_WORK_DIR="$WORK_DIR" MC_REPORT_ABS="$REPORT_ABS"
}

load_worker_options() {
    DRY_RUN="${MC_DRY_RUN:-0}" BACKUP="${MC_BACKUP:-0}" BACKUP_DIR="${MC_BACKUP_DIR:-}"
    AGGRESSIVE="${MC_AGGRESSIVE:-0}" KEEP_OUTPUTS="${MC_KEEP_OUTPUTS:-0}" KEEP_TIMESTAMPS="${MC_KEEP_TIMESTAMPS:-0}"
    KEEP_COMMENTS="${MC_KEEP_COMMENTS:-0}" WORK_DIR="${MC_WORK_DIR:-}" REPORT_ABS="${MC_REPORT_ABS:-}"
}

summarize() {
    local results="$1" status details path
    local cleaned=0 attributes=0 skipped=0 failed=0 planned=0 recoverable=0 needs_mat2=0 unsupported=0
    report "Metadata Cleaner $VERSION report - $(date '+%Y-%m-%d %H:%M:%S')"
    report "Targets: $(printf '%s ' "${TARGETS[@]}")"
    report "Mode: $( (( DRY_RUN )) && echo "dry run" || echo "live" ), aggressive: $AGGRESSIVE, backup: ${BACKUP_DIR:-none}"
    report ""
    while IFS=$'\t' read -r -d '' status details path; do
        case "$status" in
            cleaned) cleaned=$((cleaned + 1)) ;;
            attributes) attributes=$((attributes + 1)) ;;
            skipped) skipped=$((skipped + 1)) ;;
            failed) failed=$((failed + 1)); warn "Failed: $path ($details)" ;;
            planned) planned=$((planned + 1)); printf '  would clean: %s [%s]\n' "$(printable "$path")" "$details" ;;
            *) ;;
        esac
        case "$details" in
            *recoverable*) recoverable=$((recoverable + 1)) ;;
            *"install mat2"*) needs_mat2=$((needs_mat2 + 1)) ;;
            *"type not supported"*) unsupported=$((unsupported + 1)) ;;
            *) ;;
        esac
        verbose "$status: $path ($details)"
        report "$(printf '%-10s %s [%s]' "$status" "$path" "$details")"
        if (( CHECKSUMS )) && [[ "$status" == "cleaned" ]]; then
            report "           sha256 $(sha256_of "$path")"
        fi
    done < "$results"

    local findings=0
    if (( ! DRY_RUN )); then
        report ""
        report "Post-cleaning audit (values are never copied into this report):"
        local file ext found
        while IFS= read -r -d '' file; do
            [[ -f "$file" && ! -L "$file" ]] || continue
            ext="$(extension_of "$file")"
            { [[ -n "$ext" ]] && in_list "$ext" "$TEXT_EXTENSIONS ipynb"; } || continue
            is_text_file "$file" || continue
            found="$(audit_file "$file")"
            if [[ -n "$found" ]]; then
                findings=$((findings + 1))
                report "  $file: $found"
                verbose "audit: $file contains $found"
            fi
        done < "$2"
        if (( findings == 0 )); then report "  nothing found"; fi
    fi

    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] && (( COMPRESS && ! DRY_RUN )) && backup_used; then
        tar -czf "$BACKUP_DIR.tar.gz" -C "$(dirname -- "$BACKUP_DIR")" "./$(basename -- "$BACKUP_DIR")" && rm -rf -- "$BACKUP_DIR"
        BACKUP_DIR="$BACKUP_DIR.tar.gz"
    fi

    printf '\n'
    if (( DRY_RUN )); then
        info "Dry run: $planned file(s) would be processed."
    else
        info "Cleaned: $cleaned  Attributes only: $attributes  Skipped: $skipped  Failed: $failed"
        if (( findings > 0 )); then
            local hint=" Use --aggressive to redact them."
            (( AGGRESSIVE )) && hint=" Check the report for details."
            warn "Audit: $findings text file(s) still contain e-mails, secrets, home paths or private IPs.$hint"
        else
            success "Audit: no sensitive patterns found in text files."
        fi
        if (( recoverable > 0 )); then
            warn "$recoverable PDF file(s) were cleaned by ExifTool alone, so the old values can still be recovered from them. Install qpdf and run again on the same files; the report gives the reason for each file."
        fi
        if (( needs_mat2 > 0 )); then
            warn "$needs_mat2 file(s) kept their metadata because their type needs mat2. Install mat2 and run again."
        fi
        if (( unsupported > 0 )); then
            warn "$unsupported file(s) have a type this tool cannot clean, so only their timestamps and attributes changed. --verbose or --report lists them."
        fi
        if [[ -n "$BACKUP_DIR" ]] && backup_used; then info "Backup: $BACKUP_DIR"; fi
    fi
    if [[ -n "$REPORT_FILE" ]]; then info "Report: $REPORT_FILE"; fi

    if (( failed > 0 )); then exit "$E_ERROR"; fi
    if (( STRICT && findings > 0 )); then exit "$E_FINDINGS"; fi
    return 0
}

main "$@"
