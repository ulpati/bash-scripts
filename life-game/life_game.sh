#!/usr/bin/env bash
#
# life_game.sh - turn goals, daily tasks and weekly missions into a terminal game.
#
# Repository: https://github.com/ulpati/bash-scripts/tree/main/life-game
# License:    CC BY-NC-SA 4.0
#
# Design rules (see README.md and ../docs/threat-model.md):
#   * the data file is parsed line by line and never executed (no source, no eval);
#   * every number typed by the user is validated before any arithmetic;
#   * names coming from the keyboard or from Markdown files are treated as plain text;
#   * menus run in a loop, so long sessions do not grow the call stack.
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
BASE_DIR="$(script_dir)"
readonly BASE_DIR
readonly MODULES_DIR="$BASE_DIR/modules"
readonly MAX_NAME_LENGTH=120
KINDS=(goal daily weekly)

DATA_DIR="${LIFE_GAME_DATA_DIR:-$BASE_DIR/data}"
PROGRESS_FILE=""
POMODORO_LOG=""
POMODORO_SECONDS="${LIFE_GAME_POMODORO_SECONDS:-1500}"
BREAK_SECONDS="${LIFE_GAME_BREAK_SECONDS:-300}"
TODAY="$(date +%Y-%m-%d)"
WEEK="$(date +%G-W%V)"

# Game state
SCORE=0
LAST_DATE=""
LAST_WEEK=""
BADGES=(0 0 0 0 0)
ITEM_KIND=()
ITEM_NAME=()
ITEM_POINTS=()
ITEM_DONE=()
FLASHCARDS_TODAY=0
FLASHCARD_TARGET=0
STUDY_HOURS="0"
POMODOROS_TODAY=0
STUDY_DATE=""

MOTIVATION_QUOTES=(
    "Every day is a new opportunity."
    "Progress beats perfection."
    "Small steps create big change."
    "You are becoming stronger."
    "Consistency wins over intensity."
)

# ---------------------------------------------------------------- small helpers
# Replace control characters, so that values read from files can never send commands to the terminal.
printable() {
    local text="$1"
    printf '%s' "${text//[[:cntrl:]]/?}"
}

die() { printf 'Error: %s\n' "$(printable "$1")" >&2; exit "${2:-1}"; }
warn() { printf 'Warning: %s\n' "$(printable "$*")" >&2; }
usage_error() { printf '%s: %s\nTry "%s --help".\n' "$SCRIPT_NAME" "$1" "$SCRIPT_NAME" >&2; exit 2; }

cls() {
    if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then clear; fi
    return 0
}

nap() {
    if [[ -t 1 ]]; then sleep "${1:-1}"; fi
    return 0
}

# ask VAR "prompt": read one line; on end of input save and leave cleanly.
ask() {
    if ! IFS= read -r -p "$2" "$1"; then
        printf '\n'
        exit_game
    fi
}

pause() {
    local _ignored
    ask _ignored "Press ENTER to continue..."
}

is_uint() { [[ "$1" =~ ^[0-9]+$ && ${#1} -le 9 ]]; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

join_words() {
    local IFS=' '
    printf '%s' "$*"
}

# Remove control characters (C0, DEL and the UTF-8 encoded C1 range, which some terminals obey
# like escape sequences), trim blanks and limit the length of a name.
sanitize_name() {
    local name
    name="$(printf '%s' "$1" | LC_ALL=C sed 's/\xc2[\x80-\x9f]//g' | LC_ALL=C tr -d '\000-\037\177')"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    printf '%s' "${name:0:MAX_NAME_LENGTH}"
}

kind_label() {
    case "$1" in
        goal) printf 'Goal' ;;
        daily) printf 'Daily task' ;;
        weekly) printf 'Weekly mission' ;;
        *) printf 'Item' ;;
    esac
}

kind_min() { case "$1" in goal) echo 10 ;; daily) echo 5 ;; *) echo 50 ;; esac; }
kind_max() { case "$1" in goal) echo 200 ;; daily) echo 50 ;; *) echo 300 ;; esac; }

level() { echo $((SCORE / 100)); }

# ---------------------------------------------------------------- items
item_count() { echo "${#ITEM_KIND[@]}"; }

add_item() {
    ITEM_KIND+=("$1")
    ITEM_POINTS+=("$2")
    ITEM_DONE+=("$3")
    ITEM_NAME+=("$4")
}

# Global indexes of the items of one kind, one per line, in display order.
indexes_of() {
    local i n
    n=$(item_count)
    for ((i = 0; i < n; i++)); do
        if [[ "${ITEM_KIND[i]}" == "$1" ]]; then echo "$i"; fi
    done
}

count_of() {
    local kind="$1" want_done="${2:-}" i n total=0
    n=$(item_count)
    for ((i = 0; i < n; i++)); do
        [[ "${ITEM_KIND[i]}" == "$kind" ]] || continue
        if [[ -z "$want_done" || "${ITEM_DONE[i]}" == "$want_done" ]]; then total=$((total + 1)); fi
    done
    echo "$total"
}

# Global index of the N-th (1-based) item of a kind, or nothing.
nth_index() {
    local kind="$1" wanted="$2" i n seen=0
    n=$(item_count)
    for ((i = 0; i < n; i++)); do
        [[ "${ITEM_KIND[i]}" == "$kind" ]] || continue
        seen=$((seen + 1))
        if (( seen == wanted )); then
            echo "$i"
            return 0
        fi
    done
    return 1
}

find_item() {
    local kind="$1" key i n
    key="$(lower "$2")"
    n=$(item_count)
    for ((i = 0; i < n; i++)); do
        if [[ ( -z "$kind" || "${ITEM_KIND[i]}" == "$kind" ) && "$(lower "${ITEM_NAME[i]}")" == "$key" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

remove_item() {
    local remove="$1" i n
    local kinds=() names=() points=() done_flags=()
    n=$(item_count)
    for ((i = 0; i < n; i++)); do
        (( i == remove )) && continue
        kinds+=("${ITEM_KIND[i]}")
        names+=("${ITEM_NAME[i]}")
        points+=("${ITEM_POINTS[i]}")
        done_flags+=("${ITEM_DONE[i]}")
    done
    ITEM_KIND=() ITEM_NAME=() ITEM_POINTS=() ITEM_DONE=()
    n=${#kinds[@]}
    for ((i = 0; i < n; i++)); do
        add_item "${kinds[i]}" "${points[i]}" "${done_flags[i]}" "${names[i]}"
    done
}

default_items() {
    ITEM_KIND=() ITEM_NAME=() ITEM_POINTS=() ITEM_DONE=()
    add_item goal 50 0 "Learn Bash"
    add_item goal 100 0 "Write Code"
    add_item goal 30 0 "Read a Book"
    add_item goal 20 0 "Exercise"
    add_item daily 10 0 "Read a Chapter"
    add_item daily 20 0 "Meditate"
    add_item daily 30 0 "Study 1 Hour"
    add_item weekly 200 0 "Complete 10 Goals"
    add_item weekly 150 0 "Train 3 Times"
    add_item weekly 120 0 "Read 100 Pages"
}

# ---------------------------------------------------------------- persistence
save_progress() {
    local tmp i n
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR" 2>/dev/null || true
    tmp="$(mktemp "$DATA_DIR/.progress.XXXXXX")"
    n=$(item_count)
    {
        printf '# Life Game data (format 1). Plain "key=value" lines; never executed.\n'
        printf 'format=1\nscore=%s\nlast_date=%s\nlast_week=%s\n' "$SCORE" "$LAST_DATE" "$LAST_WEEK"
        printf 'badges=%s\n' "$(join_words "${BADGES[@]}")"
        printf 'flashcards_today=%s\nflashcard_target=%s\nstudy_hours_today=%s\n' \
            "$FLASHCARDS_TODAY" "$FLASHCARD_TARGET" "$STUDY_HOURS"
        printf 'pomodoros_today=%s\nstudy_date=%s\n' "$POMODOROS_TODAY" "$STUDY_DATE"
        for ((i = 0; i < n; i++)); do
            printf 'item=%s|%s|%s|%s\n' "${ITEM_KIND[i]}" "${ITEM_POINTS[i]}" "${ITEM_DONE[i]}" "${ITEM_NAME[i]}"
        done
    } > "$tmp"
    mv -f -- "$tmp" "$PROGRESS_FILE"
}

parse_item() {
    local value="$1" kind points done_flag name
    kind="${value%%|*}"; value="${value#*|}"
    points="${value%%|*}"; value="${value#*|}"
    done_flag="${value%%|*}"; name="${value#*|}"
    name="$(sanitize_name "$name")"
    case "$kind" in goal|daily|weekly) ;; *) warn "Ignoring item with unknown kind '$kind'."; return 0 ;; esac
    if ! is_uint "$points" || [[ "$done_flag" != 0 && "$done_flag" != 1 ]] || [[ -z "$name" ]]; then
        warn "Ignoring malformed item line."
        return 0
    fi
    add_item "$kind" "$((10#$points))" "$done_flag" "$name"
}

parse_badges() {
    local value="$1" re='^[01]( [01]){4}$'
    if [[ $value =~ $re ]]; then
        local IFS=' '
        # shellcheck disable=SC2206 # validated: five words, each 0 or 1
        BADGES=($value)
    else
        bad_value badges
    fi
}

load_data() {
    local line key value format=""
    local date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$' week_re='^[0-9]{4}-W[0-9]{2}$' hours_re='^[0-9]{1,4}(\.[0-9])?$'
    ITEM_KIND=() ITEM_NAME=() ITEM_POINTS=() ITEM_DONE=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            format) format="$value" ;;
            score) if is_uint "$value"; then SCORE=$((10#$value)); else bad_value "$key"; fi ;;
            last_date) if [[ "$value" =~ $date_re ]]; then LAST_DATE="$value"; else bad_value "$key"; fi ;;
            last_week) if [[ "$value" =~ $week_re ]]; then LAST_WEEK="$value"; else bad_value "$key"; fi ;;
            badges) parse_badges "$value" ;;
            item) parse_item "$value" ;;
            flashcards_today) if is_uint "$value"; then FLASHCARDS_TODAY=$((10#$value)); else bad_value "$key"; fi ;;
            flashcard_target) if is_uint "$value"; then FLASHCARD_TARGET=$((10#$value)); else bad_value "$key"; fi ;;
            pomodoros_today) if is_uint "$value"; then POMODOROS_TODAY=$((10#$value)); else bad_value "$key"; fi ;;
            study_hours_today) if [[ "$value" =~ $hours_re ]]; then STUDY_HOURS="$value"; else bad_value "$key"; fi ;;
            study_date) if [[ "$value" =~ $date_re ]]; then STUDY_DATE="$value"; else bad_value "$key"; fi ;;
            *) warn "Ignoring unknown setting '$key'." ;;
        esac
    done < "$PROGRESS_FILE"
    # Saving would replace the file, so a file that is not Life Game data is never used.
    if [[ "$format" != 1 ]]; then
        die "$PROGRESS_FILE is not a Life Game data file (format 1); it was left unchanged. Use --data-dir to choose another folder."
    fi
}

bad_value() { warn "Ignoring an invalid value for '$1'."; }

load_progress() {
    local file
    for file in "$PROGRESS_FILE" "$POMODORO_LOG"; do
        if [[ -L "$file" ]]; then die "$file is a symbolic link; refusing to use it."; fi
    done
    if [[ ! -s "$PROGRESS_FILE" ]]; then
        default_items
        LAST_DATE="$TODAY" LAST_WEEK="$WEEK" STUDY_DATE="$TODAY"
        save_progress
        return 0
    fi
    load_data
    if (( $(item_count) == 0 )); then default_items; fi

    local i n changed=0
    n=$(item_count)
    if [[ "$LAST_DATE" != "$TODAY" ]]; then
        for ((i = 0; i < n; i++)); do
            if [[ "${ITEM_KIND[i]}" == daily ]]; then ITEM_DONE[i]=0; fi
        done
        LAST_DATE="$TODAY"
        changed=1
    fi
    if [[ "$LAST_WEEK" != "$WEEK" ]]; then
        for ((i = 0; i < n; i++)); do
            if [[ "${ITEM_KIND[i]}" == weekly ]]; then ITEM_DONE[i]=0; fi
        done
        LAST_WEEK="$WEEK"
        changed=1
    fi
    if [[ "$STUDY_DATE" != "$TODAY" ]]; then
        FLASHCARDS_TODAY=0 STUDY_HOURS="0" POMODOROS_TODAY=0 STUDY_DATE="$TODAY"
        changed=1
    fi
    if (( changed )); then save_progress; fi
    return 0
}

load_modules() {
    local module
    for module in ascii_art.sh badges.sh; do
        [[ -f "$MODULES_DIR/$module" ]] || die "Missing module $MODULES_DIR/$module. Download the whole life-game folder again."
        # shellcheck source=/dev/null # modules ship with the script and contain only function definitions
        source "$MODULES_DIR/$module"
    done
}

add_score() {
    SCORE=$((SCORE + $1))
    check_badges
}

# ---------------------------------------------------------------- screens
progress_bar() {
    local progress="$1" width=30 filled empty
    (( progress > 100 )) && progress=100
    filled=$((progress * width / 100))
    empty=$((width - filled))
    printf '['
    if (( filled > 0 )); then printf '#%.0s' $(seq 1 "$filled"); fi
    if (( empty > 0 )); then printf -- '-%.0s' $(seq 1 "$empty"); fi
    printf '] %d%%\n' "$progress"
}

print_items() {
    local kind="$1" i number=0 mark
    for i in $(indexes_of "$kind"); do
        number=$((number + 1))
        mark="❌"
        [[ "${ITEM_DONE[i]}" == 1 ]] && mark="✅"
        printf '%d. %s (%s pts) %s\n' "$number" "${ITEM_NAME[i]}" "${ITEM_POINTS[i]}" "$mark"
    done
    if (( number == 0 )); then printf 'No %ss yet.\n' "$(lower "$(kind_label "$kind")")"; fi
}

show_items() {
    cls
    ascii_section "$(kind_label "$1")s"
    print_items "$1"
    pause
}

# Interactive helpers return their result in a global variable instead of printing it:
# reading input inside $(...) would run in a subshell, where end of input could not stop the game.
CHOSEN=""

# Ask for an item number of a kind; sets CHOSEN to its global index, or returns 1 (cancel or invalid).
choose_item() {
    local kind="$1" verb="$2" answer
    CHOSEN=""
    ask answer "Choose the number to $verb (0 to cancel): "
    [[ "$answer" == "0" || -z "$answer" ]] && return 1
    if ! is_uint "$answer" || ! CHOSEN="$(nth_index "$kind" "$((10#$answer))")"; then
        printf '❌ Invalid number.\n' >&2
        nap 1
        return 1
    fi
}

complete_item() {
    local kind="$1" index
    cls
    ascii_section "Complete a $(lower "$(kind_label "$kind")")"
    print_items "$kind"
    echo
    choose_item "$kind" "complete" || return 0
    index="$CHOSEN"
    if [[ "${ITEM_DONE[index]}" == 1 ]]; then
        printf 'Already completed.\n'
    else
        ITEM_DONE[index]=1
        case "$kind" in goal) ascii_trophy ;; daily) ascii_fire ;; *) printf '🏆 WEEKLY MISSION COMPLETE!\n' ;; esac
        printf 'You earned %s pts!\n' "${ITEM_POINTS[index]}"
        add_score "${ITEM_POINTS[index]}"
        save_progress
    fi
    nap 2
}

# Ask for points within the range of a kind; sets CHOSEN ("" when empty input is allowed).
read_points() {
    local kind="$1" prompt="$2" allow_empty="${3:-0}" value min max
    CHOSEN=""
    min=$(kind_min "$kind")
    max=$(kind_max "$kind")
    ask value "$prompt ($min-$max): "
    if [[ -z "$value" && "$allow_empty" == 1 ]]; then return 0; fi
    if ! is_uint "$value" || (( 10#$value < min || 10#$value > max )); then
        printf '❌ Points must be a number between %s and %s.\n' "$min" "$max" >&2
        nap 2
        return 1
    fi
    CHOSEN="$((10#$value))"
}

create_item() {
    local kind="$1" name points
    cls
    ascii_section "Add a $(lower "$(kind_label "$kind")")"
    ask name "Name: "
    name="$(sanitize_name "$name")"
    if [[ -z "$name" ]]; then printf '❌ The name cannot be empty.\n'; nap 2; return 0; fi
    if find_item "$kind" "$name" >/dev/null; then printf '❌ "%s" already exists.\n' "$name"; nap 2; return 0; fi
    read_points "$kind" "Points" || return 0
    points="$CHOSEN"
    add_item "$kind" "$points" 0 "$name"
    save_progress
    printf '✅ Added "%s" (%s pts).\n' "$name" "$points"
    nap 2
}

edit_item() {
    local kind="$1" index name points
    cls
    ascii_section "Edit a $(lower "$(kind_label "$kind")")"
    print_items "$kind"
    echo
    choose_item "$kind" "edit" || return 0
    index="$CHOSEN"
    printf 'Current: %s (%s pts)\n' "${ITEM_NAME[index]}" "${ITEM_POINTS[index]}"
    ask name "New name (empty keeps the current one): "
    name="$(sanitize_name "$name")"
    read_points "$kind" "New points, empty keeps the current value" 1 || return 0
    points="$CHOSEN"
    [[ -n "$name" ]] && ITEM_NAME[index]="$name"
    [[ -n "$points" ]] && ITEM_POINTS[index]="$points"
    save_progress
    printf '✅ Updated.\n'
    nap 2
}

delete_item() {
    local kind="$1" index confirm
    cls
    ascii_section "Delete a $(lower "$(kind_label "$kind")")"
    print_items "$kind"
    echo
    choose_item "$kind" "delete" || return 0
    index="$CHOSEN"
    ask confirm "Delete \"${ITEM_NAME[index]}\"? Type YES to confirm: "
    if [[ "$confirm" == "YES" ]]; then
        remove_item "$index"
        save_progress
        printf '✅ Deleted.\n'
    else
        printf 'Deletion cancelled.\n'
    fi
    nap 2
}

manage_menu() {
    local kind="$1" choice label
    label="$(kind_label "$kind")"
    while true; do
        cls
        ascii_section "Manage ${label}s"
        printf '1. Add\n2. Edit\n3. Delete\n4. View all\n5. Back\n\n'
        ask choice "Select (1-5): "
        case "$choice" in
            1) create_item "$kind" ;;
            2) edit_item "$kind" ;;
            3) delete_item "$kind" ;;
            4) show_items "$kind" ;;
            5) return 0 ;;
            *) printf 'Invalid option.\n'; nap 1 ;;
        esac
    done
}

show_score() {
    cls
    ascii_section "Score"
    printf 'Score: %s\nLevel: %s\n' "$SCORE" "$(level)"
    progress_bar $((SCORE % 100))
    echo
    printf '%s\n' "${MOTIVATION_QUOTES[RANDOM % ${#MOTIVATION_QUOTES[@]}]}"
    pause
}

show_badges() {
    cls
    ascii_section "Badges"
    show_badge_list
    pause
}

show_stats() {
    local kind earned=0 i
    cls
    ascii_section "Statistics"
    for kind in "${KINDS[@]}"; do
        printf '%-16s %s/%s completed\n' "$(kind_label "$kind")s:" "$(count_of "$kind" 1)" "$(count_of "$kind")"
    done
    for i in 0 1 2 3 4; do earned=$((earned + BADGES[i])); done
    printf 'Badges:          %s/5\nScore:           %s\nLevel:           %s\n' "$earned" "$SCORE" "$(level)"
    pause
}

# ---------------------------------------------------------------- Markdown import and sync
# Normalise a Markdown task: drop emphasis and the "(2h)" / "(30min)" suffix.
# Prints "name<TAB>minutes" (minutes is empty when no duration was given).
parse_task_text() {
    local text="$1" minutes="" value unit re
    text="${text//\*\*/}"
    text="${text//__/}"
    re='^(.*[^[:space:]])[[:space:]]*\(([0-9]{1,4}(\.[0-9]{1,2})?)[[:space:]]*(h|min)\)[[:space:]]*$'
    if [[ $text =~ $re ]]; then
        text="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        unit="${BASH_REMATCH[4]}"
        if [[ "$unit" == "h" ]]; then
            minutes="$(LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v * 60 }')"
        else
            minutes="$(LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v }')"
        fi
    fi
    printf '%s\t%s' "$(sanitize_name "$text")" "$minutes"
}

points_for() {
    local kind="$1" minutes="$2" points min max
    if [[ -z "$minutes" ]]; then
        points=20
    else
        points=$((minutes / 3))
    fi
    [[ "$kind" == weekly ]] && points=$((points * 2))
    min=$(kind_min "$kind")
    max=$(kind_max "$kind")
    (( points < min )) && points=$min
    (( points > max )) && points=$max
    echo "$points"
}

readonly RE_TASK='^[[:space:]]*[-*][[:space:]]+\[([ xX]|✅)\][[:space:]]+(.+)$'
readonly RE_SECTION='^#{2,3}[[:space:]]+(.*)$'

section_kind() {
    local title
    title="$(lower "$1")"
    case "$title" in
        *daily*) echo daily ;;
        *weekly*) echo weekly ;;
        *goal*|*milestone*) echo goal ;;
        *) echo "" ;;
    esac
}

import_markdown() {
    local file="$1" line kind="" parsed name minutes mark imported=0 skipped=0 ignored=0
    [[ -f "$file" && -r "$file" ]] || die "Cannot read the file: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ $line =~ $RE_SECTION ]]; then
            kind="$(section_kind "${BASH_REMATCH[1]}")"
            continue
        fi
        [[ $line =~ $RE_TASK ]] || continue
        mark="${BASH_REMATCH[1]}"
        parsed="$(parse_task_text "${BASH_REMATCH[2]}")"
        name="${parsed%%$'\t'*}"
        minutes="${parsed#*$'\t'}"
        if [[ -z "$kind" || -z "$name" ]]; then ignored=$((ignored + 1)); continue; fi
        if find_item "$kind" "$name" >/dev/null; then skipped=$((skipped + 1)); continue; fi
        add_item "$kind" "$(points_for "$kind" "$minutes")" "$([[ "$mark" == " " ]] && echo 0 || echo 1)" "$name"
        imported=$((imported + 1))
        printf '  + %s: %s\n' "$(kind_label "$kind")" "$name"
    done < "$file"
    save_progress
    printf 'Imported %d task(s); %d already present; %d outside the Daily, Goals, Milestones or Weekly sections.\n' \
        "$imported" "$skipped" "$ignored"
}

sync_markdown() {
    local file="$1" line parsed name index synced=0
    [[ -f "$file" && -r "$file" ]] || die "Cannot read the file: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ $line =~ $RE_TASK ]] || continue
        [[ "${BASH_REMATCH[1]}" == " " ]] && continue
        parsed="$(parse_task_text "${BASH_REMATCH[2]}")"
        name="${parsed%%$'\t'*}"
        index="$(find_item "" "$name")" || continue
        if [[ "${ITEM_DONE[index]}" == 0 ]]; then
            ITEM_DONE[index]=1
            SCORE=$((SCORE + ITEM_POINTS[index]))
            synced=$((synced + 1))
            printf '  ✅ %s (+%s pts)\n' "${ITEM_NAME[index]}" "${ITEM_POINTS[index]}"
        fi
    done < "$file"
    check_badges
    save_progress
    printf 'Synced %d completed task(s).\n' "$synced"
}

# Sets CHOSEN to an existing Markdown file, or returns 1.
ask_markdown_path() {
    local path
    CHOSEN=""
    ask path "Path to the Markdown file (0 to cancel): "
    [[ "$path" == "0" || -z "$path" ]] && return 1
    if [[ ! -f "$path" || ! -r "$path" ]]; then
        printf '❌ Cannot read the file: %s\n' "$(printable "$path")" >&2
        nap 2
        return 1
    fi
    CHOSEN="$path"
}

# ---------------------------------------------------------------- study mode
countdown() {
    local seconds="$1" label="$2"
    while (( seconds > 0 )); do
        printf '\r%s %02d:%02d ' "$label" $((seconds / 60)) $((seconds % 60))
        sleep 1
        seconds=$((seconds - 1))
    done
    printf '\n'
}

pomodoro() {
    local answer
    cls
    ascii_section "Pomodoro timer 🍅"
    printf 'Focus for %d minutes, then take a short break. Pomodoros today: %d\n\n' \
        $((POMODORO_SECONDS / 60)) "$POMODOROS_TODAY"
    ask answer "Press ENTER to start (0 to cancel): "
    [[ "$answer" == "0" ]] && return 0
    countdown "$POMODORO_SECONDS" "⏱️  Focus:"
    POMODOROS_TODAY=$((POMODOROS_TODAY + 1))
    printf '%s Pomodoro #%d\n' "$(date '+%Y-%m-%d %H:%M')" "$POMODOROS_TODAY" >> "$POMODORO_LOG"
    printf '🎉 Pomodoro completed! +25 XP\n'
    add_score 25
    save_progress
    if (( POMODOROS_TODAY % 4 == 0 )); then
        printf '🎊 Four pomodoros done: take a long break (15-30 min).\n'
    else
        ask answer "Press ENTER for the break timer (0 to skip): "
        [[ "$answer" == "0" ]] || countdown "$BREAK_SECONDS" "☕ Break:"
    fi
    pause
}

flashcards_menu() {
    local choice value points
    while true; do
        cls
        ascii_section "Flashcards and study hours 🎴"
        printf 'Flashcards today: %d' "$FLASHCARDS_TODAY"
        (( FLASHCARD_TARGET > 0 )) && printf ' / target %d' "$FLASHCARD_TARGET"
        printf '\nStudy hours today: %s\n\n' "$STUDY_HOURS"
        printf '1. Add flashcards\n2. Set daily flashcard target\n3. Log study hours\n4. Pomodoro history\n5. Back\n\n'
        ask choice "Select (1-5): "
        case "$choice" in
            1)
                ask value "How many flashcards did you create? "
                if is_uint "$value" && (( 10#$value > 0 && 10#$value <= 10000 )); then
                    FLASHCARDS_TODAY=$((FLASHCARDS_TODAY + 10#$value))
                    points=$((10#$value * 2))
                    add_score "$points"
                    save_progress
                    printf '✅ +%d XP\n' "$points"
                else
                    printf '❌ Enter a number between 1 and 10000.\n'
                fi
                nap 2 ;;
            2)
                ask value "Daily flashcard target (0 removes it): "
                if is_uint "$value" && (( 10#$value <= 10000 )); then
                    FLASHCARD_TARGET=$((10#$value))
                    save_progress
                    printf '✅ Target saved.\n'
                else
                    printf '❌ Enter a number between 0 and 10000.\n'
                fi
                nap 2 ;;
            3)
                ask value "Hours studied (for example 1.5): "
                if [[ "$value" =~ ^[0-9]{1,2}(\.[0-9])?$ ]] && LC_ALL=C awk -v v="$value" 'BEGIN { exit !(v > 0 && v <= 24) }'; then
                    STUDY_HOURS="$(LC_ALL=C awk -v a="$STUDY_HOURS" -v b="$value" 'BEGIN { printf "%.1f", a + b }')"
                    points="$(LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v * 30 }')"
                    add_score "$points"
                    save_progress
                    printf '✅ +%d XP\n' "$points"
                else
                    printf '❌ Enter hours between 0.1 and 24, with at most one decimal.\n'
                fi
                nap 2 ;;
            4)
                if [[ -s "$POMODORO_LOG" ]]; then tail -n 10 -- "$POMODORO_LOG"; else printf 'No pomodoros yet.\n'; fi
                pause ;;
            5) return 0 ;;
            *) printf 'Invalid option.\n'; nap 1 ;;
        esac
    done
}

percent() {
    if (( $2 > 0 )); then echo $(( $1 * 100 / $2 )); else echo 0; fi
}

study_dashboard() {
    local kind done_count total earned=0 i
    cls
    ascii_section "Study dashboard 📊"
    printf 'Date: %s\n\n🍅 Pomodoros: %d\n🎴 Flashcards: %d' "$TODAY" "$POMODOROS_TODAY" "$FLASHCARDS_TODAY"
    if (( FLASHCARD_TARGET > 0 )); then
        printf ' / %d\n' "$FLASHCARD_TARGET"
        progress_bar "$(percent "$FLASHCARDS_TODAY" "$FLASHCARD_TARGET")"
    else
        printf '\n'
    fi
    printf '⏱️  Study hours: %s\n\n' "$STUDY_HOURS"
    for kind in "${KINDS[@]}"; do
        done_count=$(count_of "$kind" 1)
        total=$(count_of "$kind")
        printf '%s: %d/%d\n' "$(kind_label "$kind")s" "$done_count" "$total"
        progress_bar "$(percent "$done_count" "$total")"
    done
    for i in 0 1 2 3 4; do earned=$((earned + BADGES[i])); done
    printf '\n🌟 XP: %d   📊 Level: %d   🏆 Badges: %d/5\n' "$SCORE" "$(level)" "$earned"
    pause
}

study_menu() {
    local choice
    while true; do
        cls
        ascii_section "Study mode 📚"
        printf '1. Pomodoro timer\n2. Flashcards and study hours\n3. Study dashboard\n'
        printf '4. Import a study plan (Markdown)\n5. Sync completed tasks (Markdown)\n6. Back\n\n'
        ask choice "Select (1-6): "
        case "$choice" in
            1) pomodoro ;;
            2) flashcards_menu ;;
            3) study_dashboard ;;
            4) if ask_markdown_path; then import_markdown "$CHOSEN"; pause; fi ;;
            5) if ask_markdown_path; then sync_markdown "$CHOSEN"; pause; fi ;;
            6) return 0 ;;
            *) printf 'Invalid option.\n'; nap 1 ;;
        esac
    done
}

main_menu() {
    local choice
    while true; do
        cls
        ascii_banner
        cat <<'EOF'
━━━━━━━━━━━━━ MAIN MENU ━━━━━━━━━━━━━
  GAMEPLAY
  1. View goals             2. Complete a goal
  3. Score and level        4. Daily tasks
  5. Complete a daily task  6. Weekly missions
  7. Complete a mission     8. Badges
  9. Statistics
  CUSTOMISATION
  10. Manage goals   11. Manage daily tasks   12. Manage weekly missions
  STUDY MODE
  13. Pomodoro, flashcards, import and sync
  0. Exit
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ask choice "Select (0-13): "
        case "$choice" in
            1) show_items goal ;;
            2) complete_item goal ;;
            3) show_score ;;
            4) show_items daily ;;
            5) complete_item daily ;;
            6) show_items weekly ;;
            7) complete_item weekly ;;
            8) show_badges ;;
            9) show_stats ;;
            10) manage_menu goal ;;
            11) manage_menu daily ;;
            12) manage_menu weekly ;;
            13) study_menu ;;
            0) exit_game ;;
            *) printf 'Invalid option.\n'; nap 1 ;;
        esac
    done
}

exit_game() {
    cls
    ascii_exit
    printf 'Progress saved. Goodbye!\n'
    exit 0
}

usage() {
    cat <<EOF
Life Game $VERSION - gamified tracker for goals, daily tasks and weekly missions

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --import FILE      Import tasks from a Markdown study plan (duplicates are skipped)
  --sync FILE        Mark tasks checked in a Markdown file ([x] or [✅]) as completed
  --data-dir DIR     Keep the data in DIR (default: $BASE_DIR/data, or \$LIFE_GAME_DATA_DIR)
  --reset            Start again from the default items (asks for confirmation)
  -y, --yes          Do not ask for confirmation
  -v, --version      Show the version
  -h, --help         Show this help

Markdown format: tasks such as "- [ ] Read chapter 3 (1h)" under "## Daily Tasks",
"## Goals", "## Milestones" or "## Weekly Missions". Durations set the points.
EOF
}

main() {
    local action="play" action_file="" assume_yes=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -v|--version) printf 'Life Game %s\n' "$VERSION"; exit 0 ;;
            --import|--sync)
                [[ $# -ge 2 && -n "$2" ]] || usage_error "$1 requires a file"
                action="${1#--}"; action_file="$2"; shift 2 ;;
            --data-dir)
                [[ $# -ge 2 && -n "$2" ]] || usage_error "--data-dir requires a directory"
                DATA_DIR="$2"; shift 2 ;;
            --reset) action="reset"; shift ;;
            -y|--yes) assume_yes=1; shift ;;
            *) usage_error "unknown option: $1" ;;
        esac
    done
    # A folder name starting with "-" must never be read as an option by mkdir, mktemp or mv.
    [[ "$DATA_DIR" != -* ]] || DATA_DIR="./$DATA_DIR"
    is_uint "$POMODORO_SECONDS" || die "LIFE_GAME_POMODORO_SECONDS must be a whole number."
    is_uint "$BREAK_SECONDS" || die "LIFE_GAME_BREAK_SECONDS must be a whole number."
    PROGRESS_FILE="$DATA_DIR/progress.txt"
    POMODORO_LOG="$DATA_DIR/pomodoro_log.txt"
    mkdir -p "$DATA_DIR"

    load_modules
    case "$action" in
        reset)
            if (( ! assume_yes )); then
                local answer=""
                [[ -t 0 ]] || die "Confirmation needed: re-run with --yes." 3
                read -r -p "Delete all progress in $DATA_DIR? Type YES to confirm: " answer || true
                [[ "$answer" == "YES" ]] || die "Reset cancelled." 3
            fi
            if [[ -f "$PROGRESS_FILE" ]]; then mv -f -- "$PROGRESS_FILE" "$PROGRESS_FILE.$(date +%Y%m%d%H%M%S).bak"; fi
            load_progress
            printf 'Progress reset. A backup of the old data was kept next to it.\n' ;;
        import) load_progress; import_markdown "$action_file" ;;
        sync) load_progress; sync_markdown "$action_file" ;;
        *) load_progress; main_menu ;;
    esac
}

main "$@"
