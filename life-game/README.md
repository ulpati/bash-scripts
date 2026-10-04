# 🎮 Life Game

A terminal game for your habits. Long-term goals, daily tasks and weekly
missions give points; points give levels and badges. A study mode adds a
Pomodoro timer, flashcard and study-hour tracking, and import of study plans
written in Markdown.

[![License](https://img.shields.io/badge/License-CC_BY--NC--SA_4.0-blue.svg)](../LICENSE)
![Bash](https://img.shields.io/badge/Bash-4.4+-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

## Contents

- [Installation](#installation)
- [Playing](#playing)
- [Rules](#rules)
- [Study mode and Markdown plans](#study-mode-and-markdown-plans)
- [Command-line options](#command-line-options)
- [Data file](#data-file)
- [Security](#security)

## Installation

Requirements: Linux with Bash 4.4 or newer. The other commands it uses,
such as `awk`, `sed` and `date`, are part of every Linux system, so nothing
needs to be installed.

```bash
git clone https://github.com/ulpati/bash-scripts.git
cd bash-scripts/life-game
./life_game.sh
```

The first start creates `data/`, readable only by you, next to the script.
Git ignores it. To start the game from anywhere, link it into a folder on
your `PATH`, for example with `mkdir -p ~/.local/bin` and
`ln -s "$PWD/life_game.sh" ~/.local/bin/life-game`.

## Playing

Choose a number from the main menu and press ENTER. Every change is saved
immediately, so you can quit at any time with `0` or Ctrl-D.

```text
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
```

Options 10 to 12 add, rename, re-score or delete items. Deleting asks you to
type `YES`.

## Rules

| Item | Points | Resets |
|---|---|---|
| Goal | 10–200 | never |
| Daily task | 5–50 | every day |
| Weekly mission | 50–300 | every ISO week |
| Pomodoro (25 min) | 25 | |
| Flashcard | 2 each | |
| Study hour | 30 per hour | |

Every 100 points is one level. Badges:

| Badge | How to earn it |
|---|---|
| 🏅 Newbie | reach 100 points |
| 🥇 Disciplined | reach 300 points |
| 💻 Code Master | complete 4 goals |
| 📚 Book Worm | reach level 5 |
| 💪 Wellness Guru | complete 3 weekly missions in the same week |

## Study mode and Markdown plans

Option 13 opens the study mode: a Pomodoro timer with breaks, flashcard and
study-hour logging with a daily flashcard target, a dashboard, and import and
sync of Markdown plans.

A plan is a Markdown file with task lists under these headings:

```markdown
## Daily Tasks
- [ ] Practice exercises (45min)
- [x] Morning review (30min)

## Goals
- [ ] **Master subnetting** (3h)

## Weekly Missions
- [ ] Finish 3 practice labs (3h)

## Milestones
- [ ] Week 1 complete
```

- Durations set the points: one point every 3 minutes, or 20 points without
  a duration; doubled for weekly missions; always within the range of each
  kind.
- `**bold**` markers and durations are removed from the names.
- Tasks already checked (`[x]` or `[✅]`) are imported as completed without points.
- Importing the same file again adds only new tasks.
- Tasks under other headings are ignored and counted in the summary.

Sync reads the tasks checked in a plan and completes the matching items
that are still open, awarding their points. To try both, import
[example_todo.md](example_todo.md), mark one of its open tasks with `[x]`,
then sync the file.

## Command-line options

| Option | Meaning |
|---|---|
| `--import FILE` | Import a Markdown plan and exit. |
| `--sync FILE` | Complete the items checked in a Markdown plan and exit. |
| `--data-dir DIR` | Use another data folder, for example one per person. `LIFE_GAME_DATA_DIR` does the same. |
| `--reset` | Start again from the default items. Asks for confirmation; `--yes` skips it. A backup is kept. |
| `-v`, `--version` | Show the version. |
| `-h`, `--help` | Show the help. |

`LIFE_GAME_POMODORO_SECONDS` and `LIFE_GAME_BREAK_SECONDS` change the length
of a Pomodoro and of its break (1500 and 300 seconds by default).

## Data file

Progress is stored in `data/progress.txt`, readable only by you, and
completed Pomodoros in `data/pomodoro_log.txt`. Each line is `key=value`,
starting with `format=1`, and items look like `item=goal|50|0|Learn Bash`
(kind, points, completed, name). The file is parsed as plain text and never
executed. Lines that do not make sense are skipped with a warning. A
`progress.txt` without the `format=1` line is not Life Game data: the game
stops and leaves it unchanged.

## Security

Plans downloaded from others are untrusted input, so a task such as
`Study $(rm -rf ~)` must stay text. The game makes sure of it:

- the data file is parsed line by line, never sourced or evaluated;
- menu numbers are validated before any arithmetic, which in Bash could
  otherwise run commands hidden in array subscripts;
- names are plain text: control characters, which could send escape
  sequences to the terminal, are removed and length is limited;
- symbolic links as data file or Pomodoro log are refused;
- menus run in a loop, so long sessions do not exhaust the call stack.

The tests in [`../tests/life_game.bats`](../tests/life_game.bats) cover these
cases.

## License

[CC BY-NC-SA 4.0](../LICENSE). Part of the
[bash-scripts](https://github.com/ulpati/bash-scripts) collection.
