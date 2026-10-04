#!/usr/bin/env bats
# Tests for life-game/life_game.sh. Menus are driven through standard input.
# shellcheck disable=SC2016 # single quotes keep attack strings literal on purpose

bats_require_minimum_version 1.5.0 # for "run !"

setup() {
    load test_helper
    isolate_environment
    SCRIPT="$REPO_ROOT/life-game/life_game.sh"
    export LIFE_GAME_DATA_DIR="$BATS_TEST_TMPDIR/data"
    export LIFE_GAME_POMODORO_SECONDS=1 LIFE_GAME_BREAK_SECONDS=0
    DATA="$LIFE_GAME_DATA_DIR/progress.txt"
    cd "$BATS_TEST_TMPDIR" || return 1
}

game() {
    run "$BASH_UNDER_TEST" "$SCRIPT" "$@"
}

play() {
    run "$BASH_UNDER_TEST" "$SCRIPT" <<< "$1"
}

value() { sed -n "s/^$1=//p" "$DATA"; }

@test "help, version and usage errors" {
    game --help
    [ "$status" -eq 0 ] && [[ "$output" == *"--import FILE"* ]]
    game --version
    [ "$status" -eq 0 ] && [[ "$output" == *"1.0.0"* ]]
    game --bogus
    [ "$status" -eq 2 ]
    game --import
    [ "$status" -eq 2 ]
}

@test "first run creates a private data file with the default items" {
    play $'0\n'
    [ "$status" -eq 0 ]
    [ "$(value format)" = "1" ]
    [ "$(grep -c '^item=' "$DATA")" -eq 10 ]
    perm_dir="$(stat -c '%a' "$LIFE_GAME_DATA_DIR")"
    perm_file="$(stat -c '%a' "$DATA")"
    [ "$perm_dir" = "700" ] && [ "$perm_file" = "600" ]
}

@test "completing a goal adds its points once" {
    play $'2\n1\n2\n1\n0\n'
    [ "$status" -eq 0 ]
    [ "$(value score)" = "50" ]
    grep -qx 'item=goal|50|1|Learn Bash' "$DATA"
    [[ "$output" == *"Already completed."* ]]
}

@test "numbers typed by the user are never evaluated" {
    play $'2\na[$(touch PWNED)]\n2\n99\n2\n-1\n2\n1+1\n0\n'
    [ "$status" -eq 0 ]
    [ ! -e PWNED ]
    [ "$(value score)" = "0" ]
}

@test "end of input exits cleanly from any prompt" {
    play $'10\n1\nUnfinished'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Goodbye"* ]]
    run ! grep -q "Unfinished" "$DATA"
    play $'2\n'
    [ "$status" -eq 0 ]
    [ "$(value score)" = "0" ]
}

@test "add, edit and delete items" {
    play $'10\n1\nRun a marathon\n150\n5\n0\n'
    grep -qx 'item=goal|150|0|Run a marathon' "$DATA"
    play $'10\n2\n5\nRun two marathons\n180\n5\n0\n'
    grep -qx 'item=goal|180|0|Run two marathons' "$DATA"
    play $'10\n1\nTooMany\n999\n5\n0\n'
    run ! grep -q "TooMany" "$DATA"
    play $'10\n3\n5\nno\n3\n5\nYES\n5\n0\n'
    run ! grep -q "marathons" "$DATA"
    [ "$(grep -c '^item=goal' "$DATA")" -eq 4 ]
}

@test "names with shell syntax stay plain text across restarts" {
    play $'11\n1\n$(touch PWNED) `touch PWNED2`\n20\n5\n0\n'
    play $'4\n\n0\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *'$(touch PWNED) `touch PWNED2`'* ]]
    [ ! -e PWNED ] && [ ! -e PWNED2 ]
}

@test "imports a Markdown study plan once" {
    game --import "$REPO_ROOT/life-game/example_todo.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Imported 19 task(s); 0 already present; 3 outside"* ]]
    grep -qx 'item=daily|10|1|Morning review session' "$DATA"
    grep -qx 'item=goal|100|1|Complete Chapter 1-5' "$DATA"
    grep -qx 'item=weekly|60|0|Write summary notes' "$DATA"
    grep -q '^item=goal|20|0|Week 1 Complete - All basics learned$' "$DATA"
    game --import "$REPO_ROOT/life-game/example_todo.md"
    [[ "$output" == *"Imported 0 task(s); 19 already present"* ]]
}

@test "imported text is never executed, even after a restart" {
    printf '## Goals\n- [ ] Study $(touch PWNED) now (1h)\n- [ ] **Bold** task `touch PWNED2`\n' > plan.md
    game --import plan.md
    [ "$status" -eq 0 ]
    play $'1\n\n0\n'
    [[ "$output" == *'Study $(touch PWNED) now'* ]]
    [ ! -e PWNED ] && [ ! -e PWNED2 ]
}

@test "control characters never reach the data file or the terminal" {
    printf '## Goals\n- [ ] Red\033[31m alert\n- [ ] CSI\302\233 trick\n' > plan.md
    game --import plan.md
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\e'* ]]
    grep -qx 'item=goal|20|0|Red\[31m alert' "$DATA"
    grep -qx 'item=goal|20|0|CSI trick' "$DATA"
}

@test "plans can be read through a symbolic link" {
    printf '## Goals\n- [ ] Linked goal\n' > plan.md
    ln -s plan.md link.md
    game --import link.md
    [ "$status" -eq 0 ]
    grep -qx 'item=goal|20|0|Linked goal' "$DATA"
    game --import missing.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot read the file"* ]]
}

@test "sync marks checked tasks, including bold names, and awards points" {
    printf '## Daily Tasks\n- [ ] Practice exercises (45min)\n- [ ] **Read chapter** (1h)\n' > plan.md
    game --import plan.md
    printf -- '- [x] Practice exercises (45min)\n- [✅] **Read chapter** (1h)\n- [x] Unknown task\n' > done.md
    game --sync done.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"Synced 2 completed task(s)."* ]]
    [ "$(value score)" = "35" ]
    game --sync done.md
    [[ "$output" == *"Synced 0 completed task(s)."* ]]
}

@test "daily and weekly items reset when the day or week changes" {
    play $'0\n'
    sed -i.tmp -e 's/^last_date=.*/last_date=2000-01-01/' -e 's/^last_week=.*/last_week=2000-W01/' \
        -e 's/^item=daily|10|0|/item=daily|10|1|/' -e 's/^item=weekly|200|0|/item=weekly|200|1|/' \
        -e 's/^item=goal|50|0|/item=goal|50|1|/' "$DATA"
    play $'0\n'
    grep -qx 'item=daily|10|0|Read a Chapter' "$DATA"
    grep -qx 'item=weekly|200|0|Complete 10 Goals' "$DATA"
    grep -qx 'item=goal|50|1|Learn Bash' "$DATA"
}

@test "malformed data lines are ignored with a warning" {
    mkdir -p "$LIFE_GAME_DATA_DIR"
    printf 'format=1\nscore=12;rm -rf x\nitem=evil|5|0|x\nitem=goal|abc|0|y\nitem=goal|40|0|Valid\nmystery=1\n' > "$DATA"
    printf 'badges=1 1 $(id)\nlast_date=yesterday\n' >> "$DATA"
    play $'0\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown setting 'mystery'"* ]]
    [[ "$output" == *"invalid value for 'score'"*"invalid value for 'badges'"*"invalid value for 'last_date'"* ]]
    [ "$(value score)" = "0" ]
    [ "$(grep -c '^item=' "$DATA")" -eq 1 ]
}

@test "pomodoro, flashcards and study hours award XP" {
    play $'13\n1\n\n0\n\n2\n1\n10\n2\n30\n3\n1.5\n1\nabc\n3\n99\n5\n6\n0\n'
    [ "$status" -eq 0 ]
    [ "$(value score)" = "90" ]
    [ "$(value pomodoros_today)" = "1" ]
    [ "$(value flashcards_today)" = "10" ]
    [ "$(value flashcard_target)" = "30" ]
    [ "$(value study_hours_today)" = "1.5" ]
    grep -q "Pomodoro #1" "$LIFE_GAME_DATA_DIR/pomodoro_log.txt"
}

@test "badges unlock from the score, the level and completed goals" {
    play $'2\n1\n2\n2\n0\n'
    [[ "$output" == *"BADGE UNLOCKED: 🏅 Newbie"* ]]
    sed -i.tmp 's/^score=.*/score=499/' "$DATA"
    play $'2\n3\n0\n'
    [[ "$output" == *"Book Worm"* ]]
    play $'2\n4\n0\n'
    [[ "$output" == *"Code Master"* ]]
}

@test "reset needs confirmation and keeps a backup" {
    play $'2\n1\n0\n'
    game --reset
    [ "$status" -eq 3 ]
    game --reset --yes
    [ "$status" -eq 0 ]
    [ "$(value score)" = "0" ]
    ls "$LIFE_GAME_DATA_DIR"/progress.txt.*.bak
}

@test "a file that is not Life Game data is never overwritten" {
    mkdir -p "$LIFE_GAME_DATA_DIR"
    printf 'My important notes\nline two\n' > "$DATA"
    cp "$DATA" before.txt
    play $'0\n'
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a Life Game data file"* ]]
    cmp -s "$DATA" before.txt
    printf 'format=2\nscore=5\n' > "$DATA"
    play $'0\n'
    [ "$status" -eq 1 ]
    [ "$(value score)" = "5" ]
}

@test "separate profiles with --data-dir; symbolic links are refused" {
    run "$BASH_UNDER_TEST" "$SCRIPT" --data-dir "$BATS_TEST_TMPDIR/other" <<< $'2\n1\n0\n'
    [ "$status" -eq 0 ]
    grep -qx 'score=50' "$BATS_TEST_TMPDIR/other/progress.txt"
    mkdir -p "$LIFE_GAME_DATA_DIR"
    ln -s "$BATS_TEST_TMPDIR/other/progress.txt" "$DATA"
    play $'0\n'
    [ "$status" -eq 1 ]
    [[ "$output" == *"symbolic link"* ]]
    rm "$DATA"
    ln -s "$BATS_TEST_TMPDIR/elsewhere.txt" "$LIFE_GAME_DATA_DIR/pomodoro_log.txt"
    play $'0\n'
    [ "$status" -eq 1 ]
    [[ "$output" == *"pomodoro_log.txt is a symbolic link"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/elsewhere.txt" ]
}

@test "a data folder whose name starts with a dash is a folder, not an option" {
    run "$BASH_UNDER_TEST" "$SCRIPT" --data-dir -profile <<< $'2\n1\n0\n'
    [ "$status" -eq 0 ]
    grep -qx 'score=50' "$BATS_TEST_TMPDIR/-profile/progress.txt"
}

@test "every menu option works in one session" {
    printf '## Goals\n- [ ] Menu goal (30min)\n' > plan.md
    printf -- '- [x] Menu goal (30min)\n' > done.md
    play $'3\n\n5\n1\n6\n\n7\n1\n9\n\n12\n4\n\n9\n5\n99\n13\n1\n0\n3\n\n2\n4\n\n9\n5\n4\nplan.md\n\n5\ndone.md\n\n7\n6\n0\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Score: 0"*"Level: 0"* ]]
    [[ "$output" == *"You earned 10 pts!"* ]]
    [[ "$output" == *"WEEKLY MISSION COMPLETE!"*"You earned 200 pts!"*"BADGE UNLOCKED: 🏅 Newbie"* ]]
    [[ "$output" == *"Daily tasks:     1/3 completed"*"Weekly missions: 1/3 completed"* ]]
    [[ "$output" == *"Manage Weekly missions"*"1. Complete 10 Goals (200 pts) ✅"* ]]
    [[ "$output" == *"Invalid option."* ]]
    [[ "$output" == *"Study dashboard"*"No pomodoros yet."* ]]
    [[ "$output" == *"Imported 1 task(s)"*"Synced 1 completed task(s)."*"Goodbye"* ]]
    [ "$(value score)" = "220" ]
    [ "$(value pomodoros_today)" = "0" ]
}

@test "long sessions do not grow the call stack" {
    input=""
    for _ in $(seq 1 1500); do input+=$'8\n\n'; done
    play "${input}0"$'\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Goodbye"* ]]
}

@test "works when started through a symbolic link" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    ln -s "$SCRIPT" "$BATS_TEST_TMPDIR/bin/life-game"
    run "$BASH_UNDER_TEST" "$BATS_TEST_TMPDIR/bin/life-game" <<< $'2\n1\n0\n'
    [ "$status" -eq 0 ]
    [ "$(value score)" = "50" ]
}
