# my-factory

GitHub Project 보드(상태 저장소) + `claude -p`(워커)로 만든 최소 소프트웨어 팩토리.
`./factory.sh`를 한 번 실행하면 다음이 일어난다.

Ready 이슈 → worktree 생성 → `claude -p`가 구현 → PR 생성 → 카드 Done

## 준비
1. `gh auth refresh -s project` (`project` 권한 필요)
2. repo와 Project를 만들고, 이슈를 카드로 추가해 Ready 컬럼(기본 `Todo`)에 둔다
3. `cp .factory.env.example .factory.env` 후 `OWNER`, `PROJECT` 입력
4. `DRY_RUN=1 ./factory.sh`로 카드 목록 확인 → `./factory.sh` 실행

## 구성
| 파일 | 역할 |
|---|---|
| `factory.sh` | 보드를 읽고 카드마다 워커를 실행, PR 생성, 카드 이동 |
| `prompts/build.md` | build 워커 지시문 |
| `.claude/hooks/guard-push.py` | 워커의 `git push` 차단 (push는 `factory.sh`만 한다) |
| `tests/test_guard.py` | 가드 정규식 테스트 (`python3 tests/test_guard.py`) |

## 동작 규칙
- 워커가 커밋을 만들면 PR을 열고 카드를 Done으로 옮긴다.
- 커밋이 없으면 이슈에 코멘트를 남기고 카드를 Ready로 되돌린다.
- 로그는 `logs/issue-N.log`에 남는다(git 제외).

## 다음에 추가할 것 (필요해질 때만)
QA 레인, 리뷰 레인, Blocked 컬럼, 병렬 wave (참고: super-board)
