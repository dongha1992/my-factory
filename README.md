# my-factory

GitHub Project board (state) + `claude -p` (worker). `./factory.sh` = one pass:
Ready issue -> worktree -> `claude -p` builds -> PR -> Done.

## Setup
1. `gh auth refresh -s project` (needs the `project` scope)
2. Create a repo + Project (board layout), add issues as cards in the Ready column (`Todo` by default)
3. `cp .factory.env.example .factory.env` and fill in OWNER / PROJECT
4. `DRY_RUN=1 ./factory.sh` to list cards, then `./factory.sh`

Test: `python3 tests/test_guard.py`

## Next (only when needed)
QA lane, review lane, Blocked column, parallel waves (see super-board).

Built by the factory.
