#!/usr/bin/env bash
#
# Badge system for Life Game. Sourced by life_game.sh; uses its game state.
# License: CC BY-NC-SA 4.0

BADGE_NAMES=("Newbie" "Disciplined" "Code Master" "Book Worm" "Wellness Guru")
BADGE_ART=(
    "🏅 Newbie: reach 100 points"
    "🥇 Disciplined: reach 300 points"
    "💻 Code Master: complete 4 goals"
    "📚 Book Worm: reach level 5"
    "💪 Wellness Guru: complete 3 weekly missions in a week"
)

badge_earned() {
    case "$1" in
        0) (( SCORE >= 100 )) ;;
        1) (( SCORE >= 300 )) ;;
        2) (( $(count_of goal 1) >= 4 )) ;;
        3) (( $(level) >= 5 )) ;;
        4) (( $(count_of weekly 1) >= 3 )) ;;
        *) return 1 ;;
    esac
}

check_badges() {
    local i
    for i in 0 1 2 3 4; do
        if [[ "${BADGES[i]}" == 0 ]] && badge_earned "$i"; then
            BADGES[i]=1
            printf '\n🏆 BADGE UNLOCKED: %s\n\n' "${BADGE_ART[i]}"
        fi
    done
}

show_badge_list() {
    local i
    for i in 0 1 2 3 4; do
        if [[ "${BADGES[i]}" == 1 ]]; then
            printf '✅ %s\n' "${BADGE_ART[i]}"
        else
            printf '🔒 %s\n' "${BADGE_NAMES[i]}"
        fi
    done
}
