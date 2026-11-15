# LAST HAVEN — Claude Code 개발 명세 패키지

**문서 버전:** 0.1.0  
**작성 기준일:** 2026-11-15  
**목적:** Claude Code가 프로젝트의 의도, 기능 요구사항, 시스템 경계, 기술 제약, 구현 순서를 일관되게 이해하도록 돕는 개발 기준 문서.

## 1. 가장 먼저 읽을 파일

1. `CLAUDE.md` — Claude Code 작업 규칙. 프로젝트 루트에 그대로 두십시오.
2. `docs/00_scope_and_decisions.md` — 확정 사항, 임시 가정, 미결정 사항.
3. `docs/01_game_design_document.md` — 전체 게임 기획.
4. `docs/09_godot_technical_architecture.md` — Godot 구현 구조.
5. `docs/13_implementation_roadmap.md` — 구현 순서와 완료 조건.
6. 나머지 문서는 각 기능 구현 전에 해당 문서를 읽으십시오.

## 2. 패키지 구성

| 경로 | 내용 |
|---|---|
| `CLAUDE.md` | Claude Code의 최상위 작업 지침 |
| `docs/00...` | 범위, 결정, 가정 및 미결정 사항 |
| `docs/01...` | 게임 전체 GDD |
| `docs/02...` | 플레이어 생존, 전투, 좀비, 감염 |
| `docs/03...` | 월드, 구역 스트리밍, 날씨, 시간 |
| `docs/04...` | 건축, 시설, 쉘터 |
| `docs/05...` | NPC AI 공통 설계 및 1차 알고리즘 명세 |
| `docs/06...` | 관계, 연애, 사건, 범죄, 증거 |
| `docs/07...` | 농업, 식품 가공, 가축 |
| `docs/08...` | 멀티플레이 및 서버 권한 |
| `docs/09...` | Godot 기술 아키텍처 |
| `docs/10...` | 저장, 복구, 데이터 버전 관리 |
| `docs/11...` | UI/UX, 그래픽, 애니메이션, 오디오 |
| `docs/12...` | 테스트 및 수용 기준 |
| `docs/13...` | 단계별 구현 로드맵 및 작업 백로그 |
| `docs/14...` | 데이터 모델과 인터페이스 계약 |
| `docs/15...` | 위험 요소 및 미결정 질문 |
| `docs/16...` | NPC AI 2차 심화 설계 과제 |
| `schemas/` | 런타임 데이터 예시용 JSON Schema |
| `templates/` | 기능 명세서 및 ADR 작성 템플릿 |

## 3. Claude Code에 권장하는 첫 요청

프로젝트 저장소에 이 패키지를 복사한 후 Claude Code에 다음과 같이 요청하십시오.

> 먼저 `CLAUDE.md`와 `docs/00_scope_and_decisions.md`, `docs/09_godot_technical_architecture.md`, `docs/13_implementation_roadmap.md`를 읽어라. 현재 저장소 상태를 조사하고, 문서와 실제 프로젝트 사이의 차이를 보고하라. 아직 대규모 기능을 한꺼번에 구현하지 말고, Phase 0의 프로젝트 부트스트랩 계획과 검증 기준만 제시하라. 문서와 충돌하거나 결정되지 않은 사항은 임의로 확정하지 말고 질문 목록으로 보고하라.

## 4. 사용 원칙

- 이 패키지는 **개발용 기준 명세**이지, 이미 구현된 게임이나 검증된 성능을 의미하지 않습니다.
- 숫자 중 `확정`이 아닌 것은 `제안`, `초기 목표`, `튜닝값`으로 취급합니다.
- 구현은 반드시 작은 수직 슬라이스(vertical slice) 단위로 진행하고, 각 단계에서 테스트를 통과해야 다음 단계로 넘어갑니다.
- 명세 변경은 관련 문서와 `00_scope_and_decisions.md`의 결정 기록을 함께 갱신합니다.
- AI가 임의로 기능 범위, 엔진 버전, 네트워크 권한 구조, 저장 형식을 변경하지 않도록 `CLAUDE.md`를 따릅니다.

## 5. 현재 엔진 기준

작성 시점 기준 Godot **4.7.2 Stable**을 기준 버전으로 제안합니다. Godot 4.8은 현재 베타이므로 프로덕션 기준으로 사용하지 않습니다. 팀이 다른 버전을 확정하면 `00_scope_and_decisions.md`, `CLAUDE.md`, CI 설정을 함께 바꾸십시오.

공식 참고 문서:
- Godot 공식 릴리스 아카이브: https://godotengine.org/download/archive/
- 고수준 멀티플레이: https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html
- NavigationServer 3D: https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_introduction_3d.html
- Resource: https://docs.godotengine.org/en/stable/classes/class_resource.html
- 전용 서버: https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html
