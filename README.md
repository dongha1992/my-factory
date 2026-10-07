# my-factory (factory-issue-7)

GitHub Project 보드(상태 저장소) + `claude -p`(워커)로 만든 최소 소프트웨어 팩토리.
`./factory.sh`를 한 번 실행하면 다음이 일어난다.

Todo 이슈 → `claude -p`가 구현 → PR → **QA** 워커가 검증 → **Review**(사람이 머지) → Done

## 준비
1. `gh auth refresh -s project` (`project` 권한 필요)
2. repo와 Project를 만들고, 이슈를 카드로 추가해 Ready 컬럼(기본 `Todo`)에 둔다
3. `cp .factory.env.example .factory.env` 후 `OWNER`, `PROJECT` 입력
4. `DRY_RUN=1 ./factory.sh`로 카드 목록 확인 → `./factory.sh` 실행

## 구성
| 파일 | 역할 |
|---|---|
| `factory.sh` | 보드를 읽고 카드마다 워커를 실행, PR 생성, 카드 이동 |
| `prompts/build.md`, `prompts/qa.md` | build / qa 워커 지시문 |
| `.claude/hooks/guard-push.py` | 워커의 `git push` 차단 (push는 `factory.sh`만 한다) |
| `tests/test_guard.py` | 가드 정규식 테스트 (`python3 tests/test_guard.py`) |

## 레인
| 컬럼 | 담당 | 다음 |
|---|---|---|
| Todo | build 워커가 구현, PR 생성 | QA (커밋이 없으면 Blocked) |
| QA | qa 워커가 PR을 읽기 전용으로 검증, PR에 결과 코멘트 | 통과 → Review, 실패/판정 불가 → Blocked |
| Review | 사람이 PR을 머지 | 머지됨 → Done, 머지 없이 닫힘 → Blocked |

- QA는 마지막 줄이 `QA: PASS`일 때만 통과한다. 그 외는 전부 실패로 처리한다.
- Blocked 카드는 사람이 이슈나 PR을 고친 뒤 Todo/QA로 되돌려야 재시도된다.
- 로그는 `logs/build-N.log`, `logs/qa-N.log`에 남는다(git 제외).
- 한 번 실행에 `sync → build → qa` 순서로 돈다.

## 다음에 추가할 것 (필요해질 때만)
리뷰 레인(AI), 반려(send-back) 루프, 충돌한 PR 감지, 병렬 wave (참고: super-board)

Built by the factory.
