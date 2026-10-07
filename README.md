# my-factory

GitHub Project 보드(상태 저장소) + `claude -p`(워커)로 만든 최소 소프트웨어 팩토리.
`./factory.sh`를 한 번 실행하면 다음이 일어난다.

Todo 이슈 → `claude -p`가 구현 → PR → **QA** 검증 → **AI Review** →(반려 시 **Rework** 후 QA부터 다시)→ **Review**(사람이 머지) → Done

## 준비
1. `gh auth refresh -s project` (`project` 권한 필요)
2. repo와 Project를 만들고, 이슈를 카드로 추가해 Ready 컬럼(기본 `Todo`)에 둔다
3. `cp .factory.env.example .factory.env` 후 `OWNER`, `PROJECT` 입력
4. `DRY_RUN=1 ./factory.sh`로 카드 목록 확인 → `./factory.sh` 실행

## 구성
| 파일 | 역할 |
|---|---|
| `factory.sh` | 보드를 읽고 카드마다 워커를 실행, PR 생성, 카드 이동 |
| `prompts/*.md` | build · qa · review · rework 워커 지시문 |
| `.claude/hooks/guard-push.py` | 워커의 `git push` 차단 (push는 `factory.sh`만 한다) |
| `tests/` | 가드 테스트, 가짜 gh/claude 기반 레인 테스트 |

## 레인
| 컬럼 | 담당 | 다음 |
|---|---|---|
| Todo | build 워커가 구현, PR 생성 | QA (커밋이 없으면 Blocked) |
| QA | qa 워커(읽기 전용)가 테스트 실행·요구사항 대조 | 통과 → AI Review, 실패/판정 불가 → Blocked |
| AI Review | 리뷰 워커(읽기 전용)가 diff 품질 검토 | 승인 → Review, 수정 요청 → Rework, 판정 불가 → Blocked |
| Rework | build 워커가 같은 브랜치에서 지적 사항 수정 | QA (수정 커밋이 없으면 Blocked) |
| Review | 사람이 PR을 머지 | 머지됨 → Done |
| Blocked | 사람이 원인을 고친 뒤 Todo/QA로 되돌린다 | |

- 수정 요청은 PR당 최대 `MAX_REWORK`회(기본 2). 넘으면 Blocked.
- 판정은 마지막 줄(`QA: PASS`, `REVIEW: APPROVE`)만 인정한다. 그 외는 전부 실패다.
- 어느 컬럼이든 PR이 머지 없이 닫히거나 main과 충돌하면 Blocked.
- 한 번 실행에 `sync → rework → build → qa → ai_review` 순서로 돈다.
- 로그는 `logs/{build,qa,review,rework}-N.log`(git 제외).

## GraphQL 한도
`gh project`는 호출 한 번에 포인트를 많이 쓴다. 그래서 실행당 보드와 PR 목록을 한 번만 읽고
(이동 시 로컬 캐시를 고친다), 시작 전에 남은 포인트가 300 미만이면 종료한다(exit 75).

## 테스트 (오프라인, 네트워크 불필요)
- `python3 tests/test_guard.py` — push 가드
- `bash tests/test_factory.sh` — 가짜 gh/claude로 레인 이동 8개 시나리오

## 다음에 추가할 것 (필요해질 때만)
병렬 wave (참고: super-board)

Built by the factory.
