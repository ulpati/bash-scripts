#!/usr/bin/env bash
#
# publish_repo.sh - Initialise a Git repository and publish it, safely.
#
# Repository: https://github.com/ulpati/bash-scripts
# License:    CC BY-NC-SA 4.0
#
# Safety rules (see README.md and ../docs/threat-model.md):
#   * commands are run as argument arrays, never through eval;
#   * remote URLs and repository names are validated before use;
#   * existing branches are never renamed and nothing is force-pushed;
#   * the files about to be committed, staged ones included, are listed and scanned for secrets;
#   * committing requires confirmation (or --yes) and Git hooks always run.
#
# Needs Bash 4.4 or newer.

# Stop early with a clear message when started with sh, dash or zsh instead of Bash.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "This script needs Bash. Run it as: bash $0" >&2
    exit 2
fi

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_BRANCH="main"
readonly MAX_SCAN_BYTES=1048576

# Exit codes
readonly E_ERROR=1 E_USAGE=2 E_CANCELLED=3 E_SECRETS=4

DRY_RUN=0
ASSUME_YES=0
CREATE=0
PUBLIC=0
VERBOSE=0
ALLOW_SECRETS=0
REMOTE_URL=""
REPO_NAME=""
MESSAGE="Publish repository"
# Git command used to read the working tree (see the dry run of a new folder in main).
GIT_READ=(git)
PREVIEW_DIR=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' BLUE=$'\033[0;34m' NC=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" BLUE="" NC=""
fi

# Replace control characters, such as escape sequences in a file name, so that printing a name
# can never send commands to the terminal.
printable() {
    local text="$1"
    printf '%s' "${text//[[:cntrl:]]/?}"
}

info()    { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$(printable "$*")"; }
success() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$(printable "$*")"; }
warn()    { printf '%s[WARNING]%s %s\n' "$YELLOW" "$NC" "$(printable "$*")" >&2; }
die()     { local code="${2:-$E_ERROR}"; printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$(printable "$1")" >&2; exit "$code"; }
usage_error() { printf '%s: %s\nTry "%s --help".\n' "$SCRIPT_NAME" "$1" "$SCRIPT_NAME" >&2; exit "$E_USAGE"; }

# Print a command with shell quoting, so the dry-run output can be copied safely.
print_cmd() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
}

# Run a command passed as separate arguments; in dry-run mode only print it.
run() {
    if (( DRY_RUN )); then
        print_cmd "$@"
        return 0
    fi
    if (( VERBOSE )); then
        print_cmd "$@" >&2
    fi
    "$@"
}

show_help() {
    cat <<EOF
$SCRIPT_NAME $VERSION - initialise a Git repository and publish it

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --remote URL       Use URL as 'origin' (https://, ssh://, git@host:path or file:///path)
  --create           Create the GitHub repository with the gh CLI (needs --name)
  --name NAME        Repository name for --create ("name" or "owner/name")
  --public           Make the repository created by --create public (default: private)
  -m, --message MSG  Commit message (default: "$MESSAGE")
  -y, --yes          Do not ask for confirmation (needed when not running in a terminal)
  --allow-secrets    Publish even if files look like they contain secrets (not recommended)
  -n, --dry-run      Print the commands without changing anything
  -v, --verbose      Print every command before running it
  --version          Show the version
  -h, --help         Show this help

Examples:
  $SCRIPT_NAME --remote git@github.com:USER/REPO.git
  $SCRIPT_NAME --create --name my-repo
  $SCRIPT_NAME --remote https://github.com/USER/REPO.git --dry-run

Exit codes: 0 success, 1 error, 2 usage error, 3 cancelled, 4 possible secrets found.
EOF
}

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "option $1 requires a value"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote) need_value "$@"; REMOTE_URL="$2"; shift 2 ;;
            --remote=*) REMOTE_URL="${1#*=}"; shift ;;
            --create) CREATE=1; shift ;;
            --name) need_value "$@"; REPO_NAME="$2"; shift 2 ;;
            --name=*) REPO_NAME="${1#*=}"; shift ;;
            --public) PUBLIC=1; shift ;;
            -m|--message) need_value "$@"; MESSAGE="$2"; shift 2 ;;
            --message=*) MESSAGE="${1#*=}"; shift ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            --allow-secrets) ALLOW_SECRETS=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -v|--verbose) VERBOSE=1; shift ;;
            --version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            -h|--help) show_help; exit 0 ;;
            *) usage_error "unknown argument: $1" ;;
        esac
    done
    if (( CREATE )) && [[ -z "$REPO_NAME" ]]; then
        usage_error "--create requires --name"
    fi
    if (( CREATE )) && [[ -n "$REMOTE_URL" ]]; then
        usage_error "use either --create or --remote, not both"
    fi
    if (( PUBLIC )) && (( ! CREATE )); then
        usage_error "--public only applies to --create"
    fi
    if [[ -z "$MESSAGE" || ${#MESSAGE} -gt 5000 ]]; then
        usage_error "the commit message must contain 1 to 5000 characters"
    fi
}

validate_remote_url() {
    local url="$1"
    local re_https='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/-]+$'
    local re_ssh='^ssh://([A-Za-z0-9._-]+@)?[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/-]+$'
    local re_scp='^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._~/-]+$'
    # Local paths may contain spaces; they are passed as one argument, never parsed by a shell.
    local re_file='^file:///[^[:cntrl:]]+$'
    if [[ ${#url} -gt 2048 ]]; then
        die "Remote URL is too long." "$E_USAGE"
    fi
    if [[ $url =~ $re_https || $url =~ $re_ssh || $url =~ $re_scp || $url =~ $re_file ]]; then
        return 0
    fi
    die "Unsupported or unsafe remote URL: '$url'. Use https://host/owner/repo.git, ssh://, git@host:owner/repo.git or file:///path." "$E_USAGE"
}

validate_repo_name() {
    local re='^([A-Za-z0-9][A-Za-z0-9-]{0,38}/)?[A-Za-z0-9_.][A-Za-z0-9_.-]{0,99}$'
    if [[ ! $REPO_NAME =~ $re || "$REPO_NAME" == *..* ]]; then
        die "Invalid repository name: '$REPO_NAME'. Use letters, digits, '.', '-', '_' and optionally 'owner/'." "$E_USAGE"
    fi
}

confirm() {
    local prompt="$1" answer=""
    if (( ASSUME_YES )); then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Confirmation needed but no terminal is attached. Re-run with --yes after reviewing the changes." "$E_CANCELLED"
    fi
    read -r -p "$prompt [y/N] " answer || true
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) die "Cancelled by the user." "$E_CANCELLED" ;;
    esac
}

# Paths that the next commit would add or change, NUL-separated: staged files, modified files and
# new files that are not ignored. Deleted files are left out: there is nothing to scan.
pending_files() {
    local -a staged=(ls-files --cached -z)
    if "${GIT_READ[@]}" rev-parse --verify --quiet HEAD >/dev/null; then
        staged=(diff --cached --name-only --no-renames --diff-filter=d -z HEAD)
    fi
    "${GIT_READ[@]}" "${staged[@]}" || return 1
    "${GIT_READ[@]}" ls-files --modified --others --exclude-standard -z
}

is_sensitive_name() {
    local base="${1##*/}"
    case "$base" in
        .env.example|.env.sample|.env.template|*.pub) return 1 ;;
        .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.kdbx|*.ovpn|*.ppk|*.tfstate|*.tfstate.backup) return 0 ;;
        id_rsa|id_rsa.*|id_dsa|id_dsa.*|id_ecdsa|id_ecdsa.*|id_ed25519|id_ed25519.*) return 0 ;;
        .npmrc|.pypirc|.netrc|.pgpass|.htpasswd|.git-credentials|credentials|credentials.json) return 0 ;;
        *) return 1 ;;
    esac
}

# Private keys (PEM, OpenSSH, PGP) and tokens of AWS, GitHub, GitLab, Slack, Google, Stripe, npm,
# PyPI and services whose keys start with "sk-".
readonly SECRET_PATTERN='-----BEGIN ([A-Z]+ )*PRIVATE KEY( BLOCK)?-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|glpat-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|[rs]k_live_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{36}|pypi-AgE[A-Za-z0-9_-]{50,}|sk-[A-Za-z0-9_-]{32,}'

# Read NUL-separated paths and print those that look like secrets, one per line. Files that
# cannot be read are reported too, because they cannot be checked.
find_secrets() {
    local file
    while IFS= read -r -d '' file; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        if is_sensitive_name "$file"; then
            printf '  %s (file name)\n' "$(printable "$file")"
        elif [[ ! -r "$file" ]]; then
            printf '  %s (cannot be read, so it was not checked)\n' "$(printable "$file")"
        elif (( $(stat -c %s -- "$file") <= MAX_SCAN_BYTES )) && grep -I -q -E -e "$SECRET_PATTERN" -- "$file"; then
            printf '  %s (content)\n' "$(printable "$file")"
        fi
    done
    return 0
}

main() {
    parse_args "$@"
    command -v git >/dev/null 2>&1 || die "git is not installed."
    if [[ -n "$REMOTE_URL" ]]; then
        validate_remote_url "$REMOTE_URL"
    fi
    if (( CREATE )); then
        validate_repo_name
        command -v gh >/dev/null 2>&1 || die "GitHub CLI 'gh' not found. Install it from https://cli.github.com/"
        if (( ! DRY_RUN )) && ! gh auth status >/dev/null 2>&1; then
            die "GitHub CLI is not authenticated. Run: gh auth login"
        fi
    fi

    # A repository is recognised by Git itself, so worktrees and submodules (where .git is a file) count too.
    local root in_repo=0
    if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        cd "$root"
        in_repo=1
    else
        root="$(pwd -P)"
    fi
    if [[ "$root" == "/" || "$root" == "$(cd "${HOME:-/}" && pwd -P)" ]]; then
        die "Refusing to publish '$root': it is the root or your home directory."
    fi
    info "Repository directory: $root"

    local branch="$DEFAULT_BRANCH"
    if (( ! in_repo )); then
        info "Initialising a new repository on branch '$DEFAULT_BRANCH'."
        run git init --quiet
        run git symbolic-ref HEAD "refs/heads/$DEFAULT_BRANCH"
        if (( DRY_RUN )); then
            # Nothing may be created here, so a throw-away Git directory outside the folder lists
            # what would be committed, with the same ignore rules.
            PREVIEW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/publish-preview.XXXXXX")"
            trap 'rm -rf -- "$PREVIEW_DIR"' EXIT
            git init --quiet "$PREVIEW_DIR"
            GIT_READ=(git "--git-dir=$PREVIEW_DIR/.git" "--work-tree=$root")
        fi
    else
        branch="$(git symbolic-ref --quiet --short HEAD)" || die "HEAD is detached. Check out a branch first."
    fi

    local findings
    if [[ -n "$("${GIT_READ[@]}" status --porcelain --untracked-files=all)" ]]; then
        info "Changes that will be committed on '$branch':"
        "${GIT_READ[@]}" status --short --untracked-files=all
        # A failure here stops the script: committing files that were never scanned is not an option.
        findings="$(pending_files | sort -zu | find_secrets)" || die "Cannot list the files that would be committed."
        if [[ -n "$findings" ]]; then
            warn "These files look like they contain secrets:"
            printf '%s\n' "$findings" >&2
            if (( ! ALLOW_SECRETS )); then
                die "Nothing was committed. Remove them, add them to .gitignore, or use --allow-secrets." "$E_SECRETS"
            fi
            warn "--allow-secrets given: continuing anyway."
        fi
        if (( ! DRY_RUN )); then
            confirm "Commit these changes and publish them?"
        fi
        run git add --all
        run git commit --quiet -m "$MESSAGE"
    elif ! "${GIT_READ[@]}" rev-parse --verify --quiet HEAD >/dev/null; then
        die "Nothing to publish: the directory has no files to commit."
    else
        info "No uncommitted changes."
    fi

    if (( CREATE )); then
        if git remote get-url origin >/dev/null 2>&1; then
            die "A remote named 'origin' already exists. Use --remote to change it."
        fi
        local visibility="--private"
        (( PUBLIC )) && visibility="--public"
        info "Creating GitHub repository '$REPO_NAME' (${visibility#--})."
        run gh repo create "$REPO_NAME" "$visibility" --source . --remote origin --push
        success "Repository created and '$branch' pushed."
        return 0
    fi

    if [[ -n "$REMOTE_URL" ]]; then
        local current=""
        current="$(git remote get-url origin 2>/dev/null || true)"
        if [[ -z "$current" ]]; then
            run git remote add origin "$REMOTE_URL"
        elif [[ "$current" != "$REMOTE_URL" ]]; then
            warn "'origin' currently points to: $current"
            (( DRY_RUN )) || confirm "Change 'origin' to $REMOTE_URL?"
            run git remote set-url origin "$REMOTE_URL"
        fi
    elif ! git remote get-url origin >/dev/null 2>&1; then
        die "No 'origin' remote. Use --remote URL or --create --name NAME."
    fi

    run git push --set-upstream origin "$branch"
    if (( DRY_RUN )); then
        success "Dry run complete: nothing was changed."
    else
        success "Published '$branch' to origin."
    fi
}

main "$@"
