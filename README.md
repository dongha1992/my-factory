# my-factory

GitHub Project 보드(상태 저장소) + `claude -p`(워커)로 만든 최소 소프트웨어 팩토리.
`./factory.sh`를 한 번 실행하면 다음이 일어난다.

Todo 이슈 → `claude -p`가 구현 → PR → **QA** 검증 → **AI Review** →(반려 시 **Rework** 후 QA부터 다시)→ **Review**(사람이 머지) → Done

## 준비
1. `gh auth refresh -s project` (`project` 권한 필요)
2. `cp .factory.env.example .factory.env` 후 `OWNER` 입력
3. `./setup-board.sh --new` — Project 생성, repo 연결, Status 컬럼 8개 설정, `PROJECT` 자동 기록
   (이미 있는 Project는 `PROJECT`를 적고 `./setup-board.sh`. 상태가 있는 카드가 있으면 중단하고 `--force`가 필요하다. 컬럼 교체가 카드 상태를 지우기 때문이다.)
4. 이슈를 카드로 추가해 `Todo`에 두고 `DRY_RUN=1 ./factory.sh`로 확인 → `./factory.sh` 실행

## 다른 프로젝트에 설치
```bash
./install.sh ~/path/to/project      # main 브랜치가 있는 git repo
```
`factory/`(스크립트·프롬프트), `.claude/{hooks,bin,skills,workflows}`, `settings.json` 훅 병합, `.gitignore`를 넣는다.
여러 번 실행해도 안전하고 `factory/.factory.env`와 기존 설정은 건드리지 않는다.
설치 후 안내에 따라 `.factory.env`를 채우고, **변경분을 main에 커밋·push**해야 워커 worktree가 가드 훅을 받는다.

## 구성
| 파일 | 역할 |
|---|---|
| `factory.sh` | 보드를 읽고 카드마다 워커를 실행, PR 생성, 카드 이동 |
| `prompts/*.md` | build · qa · review · rework 워커 지시문 |
| `.claude/hooks/guard-push.py` | 워커의 `git push` 차단 (push는 `factory.sh`만 한다) |
| `.claude/hooks/guard-{secrets,key-literals,delete-outside,worktree-path}.py` | 시크릿 접근·키 하드코딩·레포 밖 삭제·worktree 경로 이탈 차단 (super-board에서 이식) |
| `.claude/hooks/cleanup-wt.py` | 머지된 worktree·브랜치 정리 (SessionStart에서 자동 실행) |
| `.claude/bin/` | `super-board-pr-body.sh`(PR 본문 블록 단위 갱신), gh 한도 가드, card/env-check, 버그·리팩터 티켓 파일러 |
| `.claude/skills/` | git-sync · visual · super-build/qa/review · super-collect · ui-refine-loop + 작성 표준(`super-board/references/`) |
| `setup-board.sh` | Project 생성·연결, Status 컬럼 8개 설정 |
| `install.sh` | 다른 프로젝트에 팩토리 설치 |
| `tests/` | 가드·레인·설치 테스트 |

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
- `bash tests/test_factory.sh` — 가짜 gh/claude로 레인 이동 8개 시나리오 (`SUBDIR=1`이면 설치된 `factory/` 위치에서 실행)
- `bash tests/test_install.sh` — 설치 결과·멱등성·기존 설정 보존
- `bash tests/test_setup_board.sh` — 컬럼 설정·`--new`·카드 보호
- 전체 한 번에: `for t in tests/test_*.sh; do bash $t; done; python3 tests/test_guard.py`

## super-board에서 이식한 것
- 스킬은 사람이 세션에서 직접 쓰는 용도다(`/git-sync`, `/visual` 등). 레인 스킬(super-build/qa/review)은 super-board의 config·카드 이동을 전제하므로, 팩토리 워커는 `prompts/*.md`(핵심 규칙만 이식)를 따른다.
- 오케스트레이터(`super-board`, wave 루프)는 `factory.sh`와 역할이 겹쳐 가져오지 않았다. 스킬이 참조하는 `references/`만 둔다.
- 주의: `.worktrees/`는 `cleanup-wt.py`가 허용 경로(`.claude/worktrees/`) 밖으로 보므로, 머지된 것만 정리하고 미머지는 `--force` 없이는 건드리지 않는다.

## 다음에 추가할 것 (필요해질 때만)
병렬 wave (참고: super-board)

Built by the factory.
