# Shared setup for the bats test suites.
# Run with another interpreter: BASH_UNDER_TEST=/path/to/bash bats tests/

BASH_UNDER_TEST="${BASH_UNDER_TEST:-bash}"
# shellcheck disable=SC2034 # used by the test files that load this helper
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

isolate_environment() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.invalid"
    export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.invalid"
    export NO_COLOR=1
    git config --global init.defaultBranch master
    git config --global protocol.file.allow always
}
