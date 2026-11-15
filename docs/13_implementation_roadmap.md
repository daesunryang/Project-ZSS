# 13. 구현 로드맵 및 백로그

## 1. 진행 방식

각 Phase는 완성된 작은 수직 슬라이스를 만든다. 다음 Phase로 넘어가기 전에 현재 기능의 테스트/저장/네트워크 기준을 통과한다. 일정과 작업량은 팀 규모가 정해지지 않아 제시하지 않는다.

## 2. Phase 0 — 프로젝트 부트스트랩

- Godot 4.7.2 프로젝트 생성.
- 저장소/폴더 구조/코딩 규칙 적용.
- 클라이언트/헤드리스 서버 실행 설정.
- 자동 테스트 실행 경로 마련.
- 기본 로깅/설정/버전 정보.

완료: 빈 월드가 클라이언트와 headless server에서 실행되고 CI 또는 로컬 테스트를 통과한다.

## 3. Phase 1 — 네트워크와 플레이어 수직 슬라이스

- 서버 시작/클라이언트 접속.
- 플레이어 스폰/이동/카메라.
- 서버 권한 위치 처리.
- 인벤토리 기초.
- 플레이어 상태 저장/복구.

완료: 2개 클라이언트가 접속해 이동하고 아이템 하나를 공유 월드에서 획득/저장/복구한다.

## 4. Phase 2 — 생존/좀비/전투

- 허기/갈증/피로/건강.
- 기본 근접 무기.
- 좀비 감지/추격/공격.
- 소음 이벤트.
- 부상/감염 기초.

완료: 두 클라이언트가 동일 좀비와 전투하고 동일 결과를 확인한다.

## 5. Phase 3 — 월드 구역과 건축

- 500m × 500m 테스트 맵.
- 셀 로딩/해제.
- 건물 수색/루팅.
- 격자형 바닥/벽/문.
- 건축 청사진/자재/완공.
- 내비게이션 갱신.

완료: 셀 이동/저장/복구가 되고 두 플레이어가 같은 구조물을 본다.

## 6. Phase 4 — NPC AI 기반

- NPC 데이터와 고유 ID.
- 성격/능력/욕구.
- 욕구 충족 행동.
- 기본 업무/이동/휴식.
- 감정/기억/관계의 데이터 구조.
- AI 디버그 오버레이.

완료: NPC 5명이 자율적으로 기본 생존/업무를 하고 저장 후 복구된다.

## 7. Phase 5 — 사회/관계/사건

- NPC 간 대화/도움/갈등.
- 관계 축과 비대칭 상태.
- 기억/사건 원장.
- 연애/결혼 기본 흐름.
- 소문/목격/증거 기초.
- 절도/탈주 등 초기 범죄.

완료: 플레이어가 보지 않는 NPC-NPC 사건이 발생하고 기록/조사할 수 있다.

## 8. Phase 6 — 농업/가축/쉘터 운영

- 농장/작물 2~5종.
- 가축 닭/소 우선.
- 축사/먹이/물/건강/생산.
- NPC 농업/동물 돌봄 업무.
- 식품 가공/보관/부패.
- 쉘터 식량/물/전력 요약.

완료: 작은 쉘터가 농업과 가축으로 일부 자급자족한다.

## 9. Phase 7 — 세계 확장

- 월드 후보 크기 확장.
- 차량.
- 외부 생존 세력.
- 백신 연구/치료.
- 날씨/계절.
- 동물 감염.
- 더 복잡한 사건/정책.

## 10. Phase 8 — 성능/콘텐츠 완성

- AI/네트워크/월드 최적화.
- 장시간 서버 테스트.
- UI/아트/오디오 확장.
- 난이도/월드 생성/루팅 밸런스.
- 서버 관리와 배포.

## 11. 권장 최초 수직 슬라이스

- 플레이어 2명.
- NPC 5명.
- 좀비 10~20마리.
- 건물 5~10개.
- 구조물 10종.
- 농장 1개, 닭 3마리, 소 1마리.
- 작물 2~5종.

이 수량은 성능 보장이 아니라 최소 기능을 검증할 초기 테스트 규모다.

## 12. 작업 티켓 순서

1. 프로젝트 부트스트랩 및 export preset.
2. 서버 권한 세션/접속.
3. 플레이어 이동/카메라/동기화.
4. 엔티티 ID/인벤토리 트랜잭션.
5. 저장/복구.
6. 월드 셀 manager.
7. 좀비 AI와 소음.
8. 생존 상태/감염.
9. 건축 MVP.
10. NPC 도메인 모델/AI scheduler.
11. 관계/이벤트.
12. 농업/가축.

## 13. Claude Code 실행 규칙

각 티켓은 한 번의 작업에서 한 개의 핵심 완료 목표를 갖는다. 변경 파일, 위험, 테스트를 먼저 계획한다. 문서와 충돌하면 구현보다 문서 불일치 보고를 우선한다.

## 14. Phase 2 티켓 현황 (2026-11-15 갱신)

Phase 2는 단일 조정자(Opus)가 티켓을 쪼개고 병합한다. 설계 난도가 높은 작업(AI, 전투·네트워크 동기화)은 Fable 에이전트, 독립적인 생존 로직은 Codex, 검토·병합·검증은 조정자가 맡는다. 모든 티켓은 `tools/check.sh` 통과 후 main 에 병합한다. 상세 가정은 `docs/15` §6.

| 티켓 | 핵심 목표 | 소유 영역 | 담당 | 상태 |
|---|---|---|---|---|
| P1-4 | 자유 회전 3인칭 카메라·입력 | `scripts/presentation/` | Codex | 완료 |
| P2-0 | ServerSystem/NetModule seam, WorldClock | `scripts/core`, `services` | (이전 세션) | 완료 |
| P2-B1 | 생존 계약(체력·상처·피해·감염 노출) | `scripts/domain/survival/` | (이전 세션) | 완료 |
| P2-B2 | 허기·갈증·피로 증가, 범주, 페널티 | `scripts/domain/survival/` | 조정자 | 완료 |
| P2-B3 | 출혈·회복·굶주림 피해·사망/리스폰 | `scripts/domain/survival/` | Codex | 완료 |
| P2-B4 | 감염 단계 진행(설정값) | `scripts/domain/survival/` | Codex | 완료 |
| P2-B5a | 생존 이동 배율을 서버 이동 계산에 연결 | `server_world.gd`, `server_system.gd` | 조정자 | 완료 |
| P2-A1 | 소음 시스템(이벤트, 감쇠, 공간 격자) | `scripts/domain/noise/` | Fable | 완료 |
| P2-A2 | 좀비 모델·AI(감지/추격/공격/수색)·저장 | `scripts/domain/zombie/` | Fable | 완료 |
| P2-A3 | 플레이어 이동 소음(발소리) | `scripts/domain/player_noise/` | Fable | 완료 |
| P2-C1 | 근접 무기 공격 판정·피해(서버 권한) | `scripts/domain/combat/` | Fable | 완료 |
| P2-N1a | 네트워크: 좀비 복제(NetModule `ZombieNet`: ch2 위치 스냅샷, ch0 이벤트, join 조각, 클라이언트 미러 `ClientZombieState`, 감염 결과 본인 한정) | `scripts/services/multiplayer/zombie_net_*.gd`, `client_zombie_state.gd` | Fable | 완료 |
| P2-N1c | 생존 상태 서버→클라이언트 복제, 공개 범위 필터, 클라이언트 미러 | `survival/`, 새 `SurvivalNetModule`·설정·테스트 | Codex | 완료 |
| P2-N1b | 네트워크: 근접 공격 의도 RPC와 전투 이벤트 복제(ch0, 모듈 `CombatNet`) | `scripts/services/multiplayer/combat_net_module.gd` 외, `tests/integration/combat_net_test.gd` | Fable | 완료 |
| P2-N2 | 클라이언트 좀비·상태 표시(임시 캡슐/HUD) | `scripts/presentation/` | Codex | 완료 |
| P2-FIX1 | 시간 기반 생존 피해 이벤트 묶기(출혈 중 틱마다 RPC·로그가 쏟아지던 문제, 수용 시나리오에서 발견) | `scripts/domain/survival/` | 조정자 | 완료 |
| P2-Z | Phase 2 수용 시나리오(두 클라이언트, 같은 좀비, 같은 결과). `tests/scenarios/phase2_acceptance_test.gd`: 발소리 → 조사 → 시야 → 추격, 좀비 공격·부상·감염과 정보 공개 범위, 두 클라이언트의 전투 결과 일치, 부상 페널티, 감염 단계 설정, 저장 → 서버 재시작 → 복구, 조작된 요청. 수용 항목 대응표는 docs/12 §6, 검증하지 못한 항목은 docs/15 §6.13. 시나리오에서 찾은 좀비 공격 간격 결함 수정 포함(`zombie_service.gd` 비교 한 줄, 재현 테스트는 `zombie_service_test.gd`) | `tests/scenarios/`, `scripts/domain/zombie/zombie_service.gd`(결함 수정만) | Fable | 완료 |

### 14.1 사용자 결정 반영 티켓 (2026-11-15, docs/00 ADR-006~010)

| 티켓 | 핵심 목표 | 소유 영역 | 담당 | 상태 |
|---|---|---|---|---|
| P2-T1 | 달력 시간과 행동 시간 분리, 월드 시간 24배속(ADR-006). 계약은 docs/09 §14.16, 임시 가정과 24배속 소요 시간 표는 docs/15 §9 | `scripts/core/world_clock*`, 각 시스템의 시간 사용 | Fable | 완료 |
| P2-T2 | 인벤토리 변화 복제 기반: 아이템을 월드에 내려놓기·인벤토리에서 제거, 클라이언트 반영. 서버 트랜잭션 3개(`drop_item`, `drop_all_items`, `remove_item`), 내려놓기 의도 RPC, NetModule `InventoryNet`, `PROTOCOL_VERSION` 4. 계약은 docs/09 §14.17, 임시 가정은 docs/15 §10 | `scripts/domain/inventory/`, `scripts/services/multiplayer/inventory_net_*.gd`, `tests/integration/inventory_net_test.gd` | Fable | 완료 |
| P2-T3 | 먹기·마시기: 소비 의도 → 서버가 허기·갈증 감소(ADR-010). 아이템 정의의 소비 효과, `SurvivalService.reduce_needs`, 서버 규칙 `ItemConsumption`(아이템 제거와 욕구 감소를 함께 확정), `InventoryNet`의 소비 의도 RPC, 개발용 음식·물 아이템과 새 월드 배치(파이프 포함), 소비 키와 인벤토리 HUD, `PROTOCOL_VERSION` 5. 계약은 docs/09 §14.18, 임시 가정은 docs/15 §11.1 | `scripts/domain/survival/`, `scripts/domain/inventory/item_definition.gd`, `scripts/services/multiplayer/inventory_net_*.gd`, `scripts/presentation/`, `tests/integration/consume_net_test.gd` | Fable | 완료 |
| P2-T4 | 영구 사망: 사망 시 소지품 처리와 새 캐릭터 시작(ADR-007). 사망 순간 소지품을 죽은 자리에 내려놓기, 대기 시간 뒤 `ServerWorld.start_new_character`(스폰 지점·빈 인벤토리·세대 번호 +1), `PlayerState.character_generation`(플레이어 파일 스키마 v3, 마이그레이션), 죽은 캐릭터의 줍기·내려놓기 거부(`ServerSystem.player_action_block_reason`), 본인 스냅샷의 세대 번호와 HUD, 생존 fragment v1 재저장 결함 수정. 계약은 docs/09 §14.19, 임시 가정은 docs/15 §11.2 | `scripts/domain/survival/`, `scripts/domain/player/player_state.gd`, `scripts/services/world/server_world.gd`·`server_system.gd`, `scripts/services/save/save_migrations.gd`, `scripts/services/multiplayer/survival_net_module.gd`·`client_survival_state.gd`, `tests/integration/permanent_death_net_test.gd` | Fable | 완료 |
| P2-T5 | 감염으로 죽은 자리에 좀비 생성(ADR-008). `SurvivalService.player_died` 시그널과 `is_infection_death`, `ZombieService.on_player_died`(규칙 설정 `player_death_zombie_rule`, 상한이면 생략·로그), `ServerComposition`에서 연결. 복제·저장은 기존 `ZombieNet`·좀비 문서 그대로. 계약은 docs/09 §14.20, 임시 가정과 사용자 확인 항목 모음은 docs/15 §11.3·§11.4 | `scripts/domain/survival/survival_service.gd`, `scripts/domain/zombie/`, `scripts/core/server_composition.gd`, `tests/integration/player_zombie_net_test.gd` | Fable | 완료 |
| P2-T6 | 붕대: 붕대 아이템을 쓰면 출혈 중인 상처를 지혈(서버 `stop_bleeding` 연결, 사용자 결정 2026-11-15). 아이템 정의의 지혈 효과(`treat_bleeding_wound_count`), `SurvivalService.stop_worst_bleeding`(가장 심한 출혈 상처부터), `ItemConsumption`을 "아이템 사용 효과 적용"으로 일반화(출혈이 없으면 거부·보존), 기존 소비 의도 RPC 재사용(새 RPC 없음, 프로토콜 버전 그대로), 개발용 붕대와 새 월드 배치, 종류별 사용 키(음식 F·물 G·붕대 B)와 출혈·붕대 HUD. 계약은 docs/09 §14.21, 임시 가정은 docs/15 §12.1 | `scripts/domain/survival/`, `scripts/domain/inventory/item_definition.gd`, `resources/definitions/items/dev_bandage.tres`, `scripts/presentation/`, `tests/unit/bandage_test.gd`, `tests/integration/bandage_net_test.gd` | Fable | 완료 |
| P2-T7 | 치료제: 치료제 아이템을 쓰면 감염 초기 단계까지 해제(서버 `apply_infection_treatment` 연결, 사용자 결정 2026-11-15). 아이템 정의의 치료 효과(`cures_infection`), `SurvivalService.check_infection_treatment`, `ItemConsumption`의 치료 효과(감염되지 않았거나 너무 늦으면 거부·보존), 기존 소비 의도 RPC 재사용(새 RPC 없음), 개발용 치료제와 새 월드 배치, 치료제 키(V)와 감염·치료제 HUD. 계약은 docs/09 §14.22, 임시 가정은 docs/15 §12.2 | `scripts/domain/survival/`, `scripts/domain/inventory/item_definition.gd`, `resources/definitions/items/dev_cure.tres`, `scripts/presentation/`, `tests/unit/cure_test.gd`, `tests/integration/cure_net_test.gd` | Fable | 완료 |
| P2-T8 | 수면: 눕기 의도 → 쉬는 동안 피로 감소, 이동·공격 불가, 피해 시 깸(사용자 결정 2026-11-15). `SurvivalService.start_rest`/`stop_rest`/`is_resting`(쉬는 동안 피로가 달력 시간 기준으로 감소, 0 하한, 허기·갈증은 계속 증가, 피격·사망·퇴장으로 종료), 구간 적분의 음수 변화율 일반화, 이동 배율 0과 `player_action_block_reason`(`player_resting`: 줍기·내려놓기·아이템 사용·근접 공격 거부), `SurvivalNet`의 휴식 의도 RPC·결과·복제(본인 스냅샷과 공개 행의 `resting`, 공개 이벤트 2종, 스키마 3), `PROTOCOL_VERSION` 6, 휴식 키(R)·HUD·누운 캡슐. 쉬는 상태는 저장하지 않는다. 계약은 docs/09 §14.23, 임시 가정·24배속 소요 시간·사용자 확인 항목 모음은 docs/15 §12.3~§12.5 | `scripts/domain/survival/`, `scripts/domain/combat/combat_service.gd`, `scripts/services/world/server_system.gd`, `scripts/services/multiplayer/survival_net_*.gd`·`client_survival_state.gd`, `scripts/core/build_info.gd`, `scripts/presentation/`, `tests/unit/rest_test.gd`, `tests/integration/rest_net_test.gd` | Fable | 완료 |
| P2-T5b | 좀비 생성 규칙 기본값을 "감염 상태의 모든 사망"으로 변경(ADR-011) | `zombie_settings` | 조정자 | 완료 |
| P2-T9 | 캐릭터 이름·외형 커스터마이징(ADR-015): 캐릭터 생성 의도, 서버 검증·저장·복제, 생성 화면 | `scripts/domain/player/`, 새 NetModule, `scripts/presentation/` | Fable | 진행 |

병렬 규칙: 같은 파일을 두 담당이 동시에 고치지 않는다. 공유 조립 파일(`composition_config.gd`, `server_composition.gd`, 문서)은 조정자가 병합 때 정리한다.
