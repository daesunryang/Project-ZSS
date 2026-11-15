# LAST HAVEN

좀비 아포칼립스 생존 시뮬레이션 (Godot 4.7.2 Stable, 정적 타입 GDScript, 전용 서버 권한 협동 멀티플레이).

현재 상태: **Phase 1 — 네트워크와 플레이어 수직 슬라이스** (전용 서버 접속 핸드셰이크, 서버 권한 이동/복제, 아이템 줍기 트랜잭션, 원자적 저장/복구). 3인칭 카메라/입력 매핑(P1-4)은 미구현.

## 빠른 시작

```bash
export GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64   # 선택(기본 경로가 있음)
tools/check.sh          # 테스트 + 서버/클라이언트 스모크 (로컬 CI)
tools/run_server.sh     # headless 전용 서버, 빈 월드
tools/run_client.sh     # 클라이언트 창(디스플레이 필요), 접속: --connect=127.0.0.1:24680 --player-key=alice
```

자세한 실행 경로와 구조는 `docs/09_godot_technical_architecture.md` §14를 참조한다.

## 문서

- `CLAUDE.md` — 개발 작업 규칙
- `docs/00_scope_and_decisions.md` — 범위/결정/ADR (최우선 기준)
- `docs/13_implementation_roadmap.md` — Phase별 로드맵
- `docs/15_risks_and_open_questions.md` — 위험 요소, 미결정 사항, Phase 0 임시 가정
- `docs/spec_package/` — 원본 명세 패키지 README/manifest (v0.1.0)
