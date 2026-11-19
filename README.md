# LAST HAVEN

좀비 아포칼립스 생존 시뮬레이션 (Godot 4.7.2 Stable, 정적 타입 GDScript, 전용 서버 권한 협동 멀티플레이).

현재 상태: **Phase 2 — 생존/좀비/전투 완료 + 사용자 결정 반영 중** (2026-11-15). Phase 1(전용 서버 접속, 서버 권한 이동/복제, 아이템 줍기, 원자적 저장/복구, 3인칭 카메라·입력)에 더해 생존 상태(욕구·출혈·회복·감염 단계), 소음, 좀비 AI, 근접 전투, 네트워크 복제, 임시 클라이언트 표시가 들어갔다. 사용자 결정(docs/00 ADR-006~010): 월드 시간 24배속(달력 시간만), 영구 사망, 감염 사망 자리의 좀비, 먹기·마시기, 아이템 내려놓기. 24배속에서 드러난 위협에 대한 대응 수단(2026-11-15 결정, P2-T6~T8): 붕대(지혈), 치료제(감염 초기 치료), 수면(누워 쉬면 피로 감소). 캐릭터 이름·외형 생성(ADR-015)과 붕대·치료제·수면(ADR-014)도 들어갔다. 전용 서버는 캐릭터 생성이 필수이며, 화면 없는 클라이언트는 `--character-name=<이름>`으로 자동 생성한다. 티켓 현황은 `docs/13` §14, 임시 가정과 확인하지 못한 항목은 `docs/15`. 검증: `GODOT=<Godot 4.7.2 실행 파일> tools/check.sh`.

## 빠른 시작

```bash
export GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64   # 선택(기본 경로가 있음)
tools/check.sh          # 테스트 + 서버/클라이언트 스모크 (로컬 CI)
tools/run_server.sh     # headless 전용 서버, 빈 월드
tools/run_client.sh     # 클라이언트 창(디스플레이 필요), 접속: --connect=127.0.0.1:24680 --player-key=alice
```

자세한 실행 경로와 구조는 `docs/09_godot_technical_architecture.md` §14를 참조한다.

## 문서

- `AGENTS.md` — 개발 작업 규칙 (`CLAUDE.md`는 이 파일을 불러오는 한 줄)
- `docs/00_scope_and_decisions.md` — 범위/결정/ADR (최우선 기준)
- `docs/13_implementation_roadmap.md` — Phase별 로드맵
- `docs/15_risks_and_open_questions.md` — 위험 요소, 미결정 사항, Phase 0 임시 가정
- `docs/spec_package/` — 원본 명세 패키지 README/manifest (v0.1.0)
