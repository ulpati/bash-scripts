#!/usr/bin/env bats
# Tests for publish-repo/publish_repo.sh
# shellcheck disable=SC2016 # single quotes keep attack strings literal on purpose

bats_require_minimum_version 1.5.0 # for "run !"

setup() {
    load test_helper
    isolate_environment
    SCRIPT="$REPO_ROOT/publish-repo/publish_repo.sh"
    WORK="$BATS_TEST_TMPDIR/work"
    REMOTE="$BATS_TEST_TMPDIR/remote.git"
    mkdir -p "$WORK"
    git init --quiet --bare "$REMOTE"
    cd "$WORK" || return 1
}

publish() {
    run "$BASH_UNDER_TEST" "$SCRIPT" "$@"
}

remote_files() {
    git --git-dir="$REMOTE" ls-tree -r --name-only "$1"
}

@test "help and version" {
    publish --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    publish --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0.0"* ]]
}

@test "usage errors exit with code 2" {
    for args in "--bogus" "--remote" "--create" "--public" "--create --name x --remote https://github.com/a/b.git" \
                "--message"; do
        IFS=' ' read -r -a argv <<< "$args"
        publish "${argv[@]}"
        [ "$status" -eq 2 ]
    done
}

@test "unsafe remote URLs are rejected before anything runs" {
    for url in 'ext::sh -c touch% PWNED' 'https://github.com/a/b.git;touch PWNED' '$(touch PWNED)' \
               'http://github.com/a/b.git' '-uhttps://x' 'https://github.com/a/b .git' "file://relative"; do
        publish --yes --remote="$url"
        [ "$status" -eq 2 ]
    done
    [ ! -e PWNED ]
    [ ! -d .git ]
}

@test "local remotes may contain spaces but not control characters" {
    git init --quiet --bare "$BATS_TEST_TMPDIR/my backups.git"
    echo "hello" > README.md
    publish --remote "file://$BATS_TEST_TMPDIR/my backups.git" --yes
    [ "$status" -eq 0 ]
    publish --remote "file://$BATS_TEST_TMPDIR/x"$'\n'"y.git" --yes
    [ "$status" -eq 2 ]
}

@test "publishes a new directory on main after --yes" {
    echo "hello" > README.md
    publish --remote "file://$REMOTE" --yes --message "First version"
    [ "$status" -eq 0 ]
    [ "$(git symbolic-ref --short HEAD)" = "main" ]
    [ "$(remote_files main)" = "README.md" ]
    [ "$(git --git-dir="$REMOTE" log -1 --format=%s main)" = "First version" ]
}

@test "short options, --message= and --verbose" {
    echo "hello" > README.md
    publish --remote "file://$REMOTE" -n
    [ "$status" -eq 0 ] && [[ "$output" == *"+ git push --set-upstream origin main"* ]]
    [ ! -e .git ]
    publish --remote "file://$REMOTE" -y -v -m "First version"
    [ "$status" -eq 0 ]
    [[ "$output" == *"+ git add --all"*"+ git push --set-upstream origin main"* ]]
    echo "more" >> README.md
    publish -y --message="Second version"
    [ "$status" -eq 0 ]
    [ "$(git --git-dir="$REMOTE" log --format=%s main | tr '\n' '|')" = "Second version|First version|" ]
}

@test "refuses to commit without confirmation when no terminal is attached" {
    echo "hello" > README.md
    publish --remote "file://$REMOTE"
    [ "$status" -eq 3 ]
    [[ "$output" == *"--yes"* ]]
    run ! git rev-parse --verify --quiet HEAD
    [ -z "$(git --git-dir="$REMOTE" branch --list)" ]
}

@test "secret files block the commit" {
    echo "hello" > README.md
    echo "TOKEN=abc" > .env
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 4 ]
    [[ "$output" == *".env (file name)"* ]]
    run ! git rev-parse --verify --quiet HEAD
}

@test "secret contents block the commit" {
    # Built at run time so that this test file does not itself look like a secret.
    printf -- '-----BEGIN OPENSSH %s KEY-----\nabc\n' "PRIVATE" > notes.txt
    printf 'aws = %s%s\n' "AKIA" "ABCDEFGHIJKLMNOP" > config.ini
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 4 ]
    [[ "$output" == *"notes.txt (content)"* ]]
    [[ "$output" == *"config.ini (content)"* ]]
}

@test "files staged before the run are scanned too" {
    git init --quiet
    echo "hello" > README.md && git add README.md && git commit --quiet -m one
    echo "TOKEN=abc" > .env
    git add .env
    echo "more" >> README.md
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 4 ]
    [[ "$output" == *".env (file name)"* ]]
    [ "$(git rev-list --count HEAD)" -eq 1 ]
    [ -z "$(git --git-dir="$REMOTE" branch --list)" ]
}

@test "a repository without commits has its staged files scanned" {
    git init --quiet
    printf 'aws = %s%s\n' "AKIA" "ABCDEFGHIJKLMNOP" > config.ini
    git add config.ini
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 4 ]
    [[ "$output" == *"config.ini (content)"* ]]
}

@test "every supported kind of token is detected" {
    # Each fake secret is assembled at run time, so this file never contains one.
    local name i=0
    for token in "-----BEGIN PGP PRIVATE KEY BLOCK""-----" "glpat-""ABCDEFGHIJKLMNOPQRST" \
                 "sk_live_""ABCDEFGHIJKLMNOPQRSTUVWX" "npm_""ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" \
                 "pypi-AgE""IcHlwaS5vcmcCJDAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMA" \
                 "ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" "xoxb-""1234567890-abcdef"; do
        i=$((i + 1))
        rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK" || return 1
        printf 'value = %s\n' "$token" > "settings$i.txt"
        publish --remote "file://$REMOTE" --dry-run
        [ "$status" -eq 4 ]
        [[ "$output" == *"settings$i.txt (content)"* ]]
    done
}

@test "names with control characters are scanned and printed safely" {
    name=$'notes\e[31m.txt'
    printf 'aws = %s%s\n' "AKIA" "ABCDEFGHIJKLMNOP" > "$name"
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 4 ]
    [[ "$output" == *"notes?[31m.txt (content)"* ]]
    [[ "$output" != *$'\e'* ]]
}

@test "files that cannot be read block the commit" {
    [ "$(id -u)" -ne 0 ] || skip "root can read every file"
    echo "hello" > README.md
    echo "data" > locked.txt
    chmod 000 locked.txt
    publish --remote "file://$REMOTE" --yes
    chmod 600 locked.txt
    [ "$status" -eq 4 ]
    [[ "$output" == *"locked.txt (cannot be read"* ]]
}

@test "ignored and example files are not flagged; --allow-secrets overrides" {
    echo ".env" > .gitignore
    echo "TOKEN=abc" > .env
    echo "TOKEN=" > .env.example
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 0 ]
    remote_files main > "$BATS_TEST_TMPDIR/files"
    run ! grep -qx '.env' "$BATS_TEST_TMPDIR/files"
    grep -qx '.env.example' "$BATS_TEST_TMPDIR/files"
    echo "key" > server.pem
    publish --yes --allow-secrets
    [ "$status" -eq 0 ]
    [[ "$(remote_files main)" == *"server.pem"* ]]
}

@test "existing branches are never renamed" {
    git init --quiet
    echo a > a.txt && git add a.txt && git commit --quiet -m "on master"
    git checkout --quiet -b feature
    echo b > b.txt
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 0 ]
    [ "$(git log -1 --format=%s master)" = "on master" ]
    [ "$(git symbolic-ref --short HEAD)" = "feature" ]
    git --git-dir="$REMOTE" rev-parse --verify --quiet refs/heads/feature
    run ! git --git-dir="$REMOTE" rev-parse --verify --quiet refs/heads/master
}

@test "dry run prints quoted commands and changes nothing" {
    echo "hello" > README.md
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    publish --remote "file://$REMOTE" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"+ git init --quiet"* ]]
    [[ "$output" == *"?? README.md"* ]]
    [[ "$output" == *"+ git add --all"*'+ git commit --quiet -m Publish\ repository'* ]]
    [[ "$output" == *"+ git push --set-upstream origin main"* ]]
    [ ! -e .git ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "the dry run of a new folder already finds secrets" {
    echo "hello" > README.md
    printf 'TOKEN=x\n' > .env
    publish --remote "file://$REMOTE" --dry-run
    [ "$status" -eq 4 ]
    [[ "$output" == *".env (file name)"* ]]
    [ ! -e .git ]
}

@test "a worktree is published as it is, never initialised again" {
    git init --quiet "$BATS_TEST_TMPDIR/main"
    git -C "$BATS_TEST_TMPDIR/main" commit --quiet --allow-empty -m "first"
    git -C "$BATS_TEST_TMPDIR/main" worktree add --quiet -b feature "$WORK/wt"
    cd "$WORK/wt" || return 1
    echo "change" > new.txt
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 0 ]
    [[ "$output" != *"Initialising"* ]]
    [ "$(remote_files feature)" = "new.txt" ]
}

@test "refuses to publish the home directory or the file system root" {
    export HOME="$WORK"
    echo "x" > file.txt
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"home directory"* ]]
    cd / || return 1
    publish --remote "file://$REMOTE" --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing to publish '/'"* ]]
}

@test "changing an existing origin needs confirmation" {
    git init --quiet && echo a > a.txt && git add a.txt && git commit --quiet -m one
    git remote add origin "file://$BATS_TEST_TMPDIR/old.git"
    publish --remote "file://$REMOTE"
    [ "$status" -eq 3 ]
    [ "$(git remote get-url origin)" = "file://$BATS_TEST_TMPDIR/old.git" ]
    publish --remote "file://$REMOTE" --yes
    [ "$status" -eq 0 ]
    [ "$(git remote get-url origin)" = "file://$REMOTE" ]
}

@test "git hooks are not bypassed" {
    git init --quiet
    printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    echo a > a.txt
    publish --remote "file://$REMOTE" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"hook says no"* ]]
    [ -z "$(git --git-dir="$REMOTE" branch --list)" ]
}

@test "--create calls gh with validated arguments" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export GH_LOG="$BATS_TEST_TMPDIR/gh.log" PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    echo a > a.txt
    publish --create --name "my-repo" --public --yes
    [ "$status" -eq 0 ]
    grep -qx "repo create my-repo --public --source . --remote origin --push" "$GH_LOG"
    publish --create --name 'bad;name' --yes
    [ "$status" -eq 2 ]
    [ "$(grep -c 'repo create' "$GH_LOG")" -eq 1 ]
}

@test "errors without origin or files" {
    publish --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"Nothing to publish"* ]]
    echo a > a.txt
    publish --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"No 'origin' remote"* ]]
}

@test "a clear message when started with a non-Bash shell" {
    command -v dash >/dev/null 2>&1 || skip "dash is not installed"
    for script in publish-repo/publish_repo.sh metadata-cleaner/metadata_cleaner.sh life-game/life_game.sh; do
        run dash "$REPO_ROOT/$script" --version
        [ "$status" -eq 2 ]
        [[ "$output" == *"needs Bash"* ]]
    done
}
