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
| P2-T9 | 캐릭터 이름·외형 커스터마이징(ADR-015): 캐릭터 생성 의도, 서버 검증·저장·복제, 생성 화면. 외형 정의 데이터(`resources/definitions/appearance/`: 항목 7개, 선택지 팔레트)와 `AppearanceCatalog`, 이름 규칙(`CharacterSettings`, `CharacterNameRules`), `PlayerState.character`(플레이어 파일 스키마 v4, 마이그레이션), 접속과 월드 진입의 분리(`ServerWorld.create_character`: 캐릭터가 없는 접속자는 월드 밖), 죽은 뒤 플레이어가 만들어야 새 캐릭터 시작(`ServerSystem.new_character_block_reason`·`on_character_started`), NetModule `CharacterNet`(생성 의도와 결과, 캐릭터 행, 생성 가능 상태)과 `ClientCharacterState`, `PROTOCOL_VERSION` 7, 생성 화면(`scenes/ui/character_creation_screen.tscn`)·외형이 반영된 캡슐·이름표, 화면 없는 생성 인자 `--character-name=`. 전용 서버는 생성 필수, 조립을 직접 만드는 테스트·도구는 호환 기본값(접속 즉시 기본 캐릭터). `network_service.gd` 최소 수정(캐릭터 없는 접속자를 알리지 않음, `announce_player_entered`). 계약은 docs/09 §14.24, 임시 가정·검증하지 못한 항목·사용자 확인 항목 모음은 docs/15 §13 | `scripts/domain/player/`, `scripts/services/world/`, `scripts/domain/survival/survival_service.gd`, `scripts/services/multiplayer/character_net_module.gd`·`client_character_state.gd`·`survival_net_module.gd`·`client_survival_state.gd`·`network_service.gd`·`inventory_net_module.gd`, `scripts/services/save/save_migrations.gd`, `scripts/core/`, `scripts/presentation/`, `scenes/`, `tools/smoke_test.sh`, `tests/unit/character_*_test.gd`, `tests/integration/character_*_test.gd` | Fable | 완료 |
| P2-T10 | 수면 조정(사용자 결정 2026-11-15, ADR-016): 수면 시간 단축(피로 최대 → 0이 월드 3.2시간 = 실제 8분), 피로 범주가 조작 배율을 낮춤(`handling_multiplier` = 상처 배율 × 피로 배율, 근접 피해에 반영), 위험하면 자동으로 깸(체력 30% 이하, 허기·갈증 위험, 감염 말기. 기상 시점이 구간 적분의 경계), 같은 위험 상태에서는 눕기 거부(`cannot_rest_<위험>`), 자는 중 피격은 체력을 1 아래로 내리지 않고 깨움, 본인 이벤트의 기상 원인과 HUD 문구, `PROTOCOL_VERSION` 8(P2-T10~T12 묶음에서 한 번). 계약은 docs/09 §14.25, 임시 가정·24배속 소요 시간·사용자 확인 항목은 docs/15 §14.1·§12.4 | `scripts/domain/survival/`, `data/tuning/survival_settings.tres`, `scripts/core/build_info.gd`, `scripts/presentation/`, `tests/unit/sleep_tuning_test.gd`, `tests/integration/sleep_tuning_net_test.gd` | Fable | 완료 |
| P2-T11 | 엎드리기와 은신(사용자 결정 2026-11-15, ADR-017): 자세 모델(서 있음/엎드림/누워 잠)과 새 ServerSystem `posture`(`PostureService`: 엎드림, 서버 위치로 판정하는 "움직이는 중", 가시성 배율), `ServerSystem`·`ServerWorld` 훅 넷(가시성, 공격 차단 사유, 발소리 세기·보폭 배율)으로 좀비·발소리·전투가 자세를 모른 채 값을 묻는 구조, 좀비 시야 거리 × 가시성(엎드려 정지 0.4 < 엎드려 이동 0.6 < 누워 잠 0.8 < 서서 정지 0.9 < 서서 움직임 1.0)과 추격 중인 대상의 하한(`tracked_target_min_visibility`), 엎드린 채 이동 35%·발소리 세기 40%·근접 공격 불가·아이템 사용 가능, `SurvivalService.rest_changed` 시그널, NetModule `PostureNet`("원하는 자세" 의도와 결과, 모든 접속자에게 자세 행, 접속 조각)과 `ClientPostureState`, 기존 휴식 RPC 유지, 엎드리기 키(C)·자세 HUD·엎드린 캡슐. 자세는 저장하지 않는다. `PROTOCOL_VERSION`은 8 그대로. 계약은 docs/09 §14.26, 임시 가정·사용자 확인 항목은 docs/15 §14.2 | `scripts/domain/posture/`, `scripts/domain/zombie/`, `scripts/domain/player_noise/player_noise_service.gd`, `scripts/domain/combat/combat_service.gd`, `scripts/domain/survival/survival_service.gd`(시그널), `scripts/services/world/server_world.gd`·`server_system.gd`, `scripts/services/multiplayer/posture_net_*.gd`·`client_posture_state.gd`, `scripts/core/server_composition.gd`·`composition_config.gd`, `data/tuning/posture*.tres`, `scripts/presentation/`, `tests/unit/posture_test.gd`, `tests/integration/posture_net_test.gd` | Fable | 완료 |
| P2-T12 | 다른 플레이어 치료(사용자 결정 2026-11-15, ADR-018): 서버 규칙 `ItemConsumption.try_use_on`(사용자·아이템 → 남에게 줄 수 있는 종류인지 → 대상 존재·생존·서버 위치 기준 거리 → 대상 상태 순으로 검사, 아이템 제거와 효과 적용을 함께 확정, 자기 사용과 효과 적용부 공유), `GameplaySettings.treat_range_m`(2.5m)·`allow_feeding_others`(기본 끔), `InventoryNet`의 "다른 플레이어에게 사용" 의도와 결과·치료 알림(대상에게는 누가 무엇을 썼는지, 제3자에게는 "A가 B를 돌봤다"만: 성공과 "치료할 것이 없던 시도"를 구분하지 못하게 둘 다 보냄), 기존 소비 의도는 그대로, 클라이언트 대상 후보 선택(`TreatTargetPolicy`)·Shift+붕대/치료제 키·HUD 대상 줄·알림 문구. `PROTOCOL_VERSION`은 8 그대로. 계약은 docs/09 §14.27, 임시 가정·정보 공개 표·사용자 확인 항목은 docs/15 §14.3 | `scripts/domain/survival/item_consumption.gd`, `scripts/domain/inventory/item_definition.gd`, `scripts/core/gameplay_settings.gd`, `scripts/services/multiplayer/inventory_net_module.gd`, `scripts/presentation/`, `tests/unit/treat_other_test.gd`·`treat_target_test.gd`, `tests/integration/treat_other_net_test.gd` | Fable | 완료 |
| P2-T13 | 음식·물을 다른 플레이어에게 주기(사용자 결정 2026-11-15, ADR-019): `GameplaySettings.allow_feeding_others` 기본값을 켬(P2-T12의 "남에게 쓰기" 경로 그대로: 주는 쪽의 한 단위가 줄고 받는 쪽의 허기·갈증이 내려감), 클라이언트 Shift+음식(F)·물(G) 키와 HUD "줄 대상" 줄·결과·알림 문구, 기본 설정의 서버 규칙 테스트와 네트워크 흐름 테스트. RPC·저장 형식 변화 없음(`PROTOCOL_VERSION` 8 그대로). 계약은 docs/09 §14.27, 임시 가정은 docs/15 §14.3 P2-196·P2-200 | `scripts/core/gameplay_settings.gd`, `data/tuning/gameplay_settings.tres`, `scripts/presentation/consume_intent_policy.gd`·`client_presentation_formatter.gd`, `tests/unit/treat_other_test.gd`·`treat_target_test.gd`, `tests/integration/treat_other_net_test.gd` | 조정자 | 완료 |
| P2-T14 | 아이템 건네기(사용자 결정 2026-11-15 "건네기도 추가", ADR-020): 들고 있는 아이템을 가까운 다른 플레이어의 인벤토리로 옮김(먹여 주기와 별개, 모든 아이템). 서버 트랜잭션 `InventoryService.transfer_item`(전부 또는 전무, 받는 쪽의 같은 정의 묶음에 `max_stack`까지 합치고 남는 것은 빈 칸 하나로, 다 들어가지 않으면 전체 거부, 수량 보존, 인스턴스 ID 유일), 서버 규칙 `ServerWorld.try_hand_over_item`(건네는 쪽 상태 → 소유 → 수량 → 대상 존재·생존·서버 위치 기준 거리 → 받는 쪽 자리 순으로 검사)과 `ServerSystem.player_is_dead` 훅, `GameplaySettings.hand_over_range_m`(2.5m), `InventoryNet`의 건네기 의도와 결과·건네기 알림(받는 쪽에는 누가 무엇을 몇 개, 제3자에게는 "A가 B에게 건넸다"만)·두 소유자에게만 가는 인벤토리 복제, 내려놓기와 같은 빈도 버킷, 승인 즉시 저장, 클라이언트 Ctrl+사용 키(한 번에 한 개)·HUD 대상 줄·결과와 알림 문구, `PROTOCOL_VERSION` 9. 계약은 docs/09 §14.28, 임시 가정·사용자 확인 항목은 docs/15 §14.5 | `scripts/domain/inventory/inventory_service.gd`, `scripts/services/world/server_world.gd`·`server_system.gd`, `scripts/domain/survival/survival_service.gd`(훅)·`item_consumption.gd`(상수), `scripts/core/gameplay_settings.gd`·`build_info.gd`, `scripts/services/multiplayer/inventory_net_module.gd`·`inventory_net_settings.gd`, `scripts/presentation/`, `tests/unit/hand_over_test.gd`·`hand_over_presentation_test.gd`, `tests/integration/hand_over_net_test.gd` | Fable | 완료. **입력과 의도는 P2-T15에서 대체됨**(ADR-021: Ctrl+사용 키, 건네기 의도 RPC·알림, `try_hand_over_item`, `hand_over_range_m` 제거). 남은 것은 트랜잭션 `transfer_item`과 그 복제, `player_is_dead` 훅 |
| P2-T15 | 아이템을 바닥에 두어 옮기기(사용자 결정 2026-11-16, ADR-021): 단축키 건네기(P2-T14의 Ctrl+키, 건네기 의도 RPC 셋, `ServerWorld.try_hand_over_item`, `hand_over_range_m`)를 없앰. 내려놓기 의도에 수량(`_rpc_request_drop(request_id, item_instance_id, quantity)`, 0 = 묶음 전체. 일부를 내려놓으면 새 ID의 새 아이템, 이벤트 `item_units_dropped`), 줍기가 들고 있는 같은 종류 묶음에 합침(`GameplaySettings.merge_stacks_on_pickup`, 전부 합쳐지면 주운 인스턴스 삭제·ID 폐기, 다 들어가지 않으면 전체 거부), 합쳐진 묶음의 소유자 한정 복제와 `network_service.gd` 줍기 핸들러 세 줄 수정, 클라이언트 선택 커서(`InventorySelectionPolicy`, Z/X)·내려놓기 키(Q 한 개, Ctrl+Q 묶음 전체)·묶음별 HUD 목록·바닥 아이템 표시(`WorldItemMarkers`)·줍기 후보와 내려놓기·줍기 결과 문구, `PROTOCOL_VERSION` 10. 계약은 docs/09 §14.29, 임시 가정·검증하지 못한 항목·고친 기존 테스트는 docs/15 §14.6 | `scripts/domain/inventory/inventory_service.gd`, `scripts/services/world/server_world.gd`·`server_system.gd`(주석), `scripts/core/gameplay_settings.gd`·`build_info.gd`, `scripts/services/multiplayer/inventory_net_module.gd`·`inventory_net_settings.gd`·`network_service.gd`(세 줄), `scripts/presentation/`, `scenes/main/client_view.tscn`, `data/tuning/gameplay_settings.tres`·`client_presentation_settings.tres`, `tests/unit/ground_transfer_test.gd`·`ground_transfer_presentation_test.gd`·`item_transfer_test.gd`, `tests/integration/ground_transfer_net_test.gd`·`ground_transfer_view_test.gd` | Fable | 완료 |
| P2-T16 | 거래 요청(사용자 결정 2026-11-16, ADR-022): 요청 → 수락 → 양쪽 제안 → 양쪽 확정 → 서버가 한 번에 교환(전부 또는 전무). 교환 트랜잭션 `InventoryService.exchange_items`(나갈 것이 나간 뒤의 자리로 판정, 들어오는 수량은 같은 종류 묶음에 먼저 합침, 수량 보존, 인스턴스 ID 유일. `transfer_item`과 줍기가 쓰는 합치기 규칙을 같이 쓴다: 두 방향 교환은 `transfer_item` 두 번으로는 원자적으로 할 수 없어 한 트랜잭션을 새로 뒀다), ServerSystem `trade`(`TradeService`·`TradeSession`·`TradeSettings`: 한 플레이어 한 세션, 제안 변경 시 양쪽 확정 해제와 revision, 낡은 확정 거부, 제안이 인벤토리를 따라감, 취소 사유 열 가지와 주입된 시계의 시간 초과, 자는·죽은 플레이어에게는 요청 불가), NetModule `TradeNet`(의도 다섯·결과·당사자 전용 세션 상태·완료 알림)과 `ClientTradeState`, `InventoryNet`의 교환 복제와 `flush_pending_save`, 완료 즉시 저장 한 번, 클라이언트 거래 키(T 요청, Y 수락/확정, N 거절/취소, O/P 선택한 묶음 올리기/내리기)·`TradeIntentPolicy`·HUD 거래 블록·문구, `PROTOCOL_VERSION` 11. `network_service.gd` 수정 없음. 계약은 docs/09 §14.30, 임시 가정·검증하지 못한 항목·사용자 확인 항목은 docs/15 §14.7 | `scripts/domain/trade/`, `scripts/domain/inventory/inventory_service.gd`, `scripts/services/multiplayer/trade_net_*.gd`·`client_trade_state.gd`·`inventory_net_module.gd`, `scripts/core/server_composition.gd`·`composition_config.gd`·`build_info.gd`, `data/tuning/trade*.tres`·`client_presentation_settings.tres`, `scripts/presentation/`, `scenes/main/client_view.tscn`, `tests/unit/item_exchange_test.gd`·`trade_service_test.gd`·`trade_presentation_test.gd`, `tests/integration/trade_net_test.gd`·`trade_view_test.gd` | Fable | 완료 |

병렬 규칙: 같은 파일을 두 담당이 동시에 고치지 않는다. 공유 조립 파일(`composition_config.gd`, `server_composition.gd`, 문서)은 조정자가 병합 때 정리한다.

## 15. Phase 3 티켓 현황 (2026-11-16 시작)

사용자 지시(2026-11-16): 결정 대기 항목의 수치·규칙 조정은 마지막에 모아서 하고, Phase 3 을 로드맵 순서대로 이어서 진행한다. 진행 방식은 §14 와 같다(티켓마다 `tools/check.sh` 통과 후 main 병합). 계약은 docs/09 §15, 임시 가정은 docs/15 §15(번호 `P3-xxx`).

| 티켓 | 핵심 목표 | 소유 영역 | 담당 | 상태 |
|---|---|---|---|---|
| P3-1 | 월드 셀 격자와 셀 생명주기(서버, ADR-023): 셀 좌표·ID, 플레이어 위치 기반 활성/사전 로딩/비활성, 엔티티의 셀 색인, 비활성 셀의 시뮬레이션 정지, 셀 단위 저장·복구 | `scripts/domain/world_cells/`, `scripts/services/world/`, `scripts/services/save/` | Fable | 완료 |
| P3-2 | 셀 기반 복제 범위: 클라이언트는 주변 셀의 월드 아이템·좀비만 받고 셀 진입·이탈 때 추가·제거, 500m × 500m 테스트 맵 바닥과 경계. 재사용할 수 있는 관심 셀 기능(`InterestSettings`·`CellInterest`·NetModule `InterestNet`: 서버 위치 기준 2칸, 유지 3칸, 메모리에 없는 셀은 제외), 접속 데이터·내려놓기·줍기·셀 얻음/잃음을 관심 셀로 거름(`InventoryNet`의 묶음 제거 RPC와 공개 함수 둘, `WorldCellNetModule`의 이름 호출 제거), 좀비의 접속자별 이벤트 흐름과 스냅샷 주기 조정(전선 이벤트 `zombie_entered`/`zombie_left`), 전투 이벤트 수신자, 관심 셀 밖 아이템에 대한 줍기 거부 사유 가리기, `network_service.gd` 최소 수정(관심 셀 조회 둘, 접속 스냅샷·줍기 제거의 범위, 거부 사유), 클라이언트가 서버에서 받은 맵 배치로 그리는 바닥·가장자리 벽·HUD 현재 셀·셀 경계 오버레이(F3), `PROTOCOL_VERSION` 13(12는 P3-4a). 플레이어 행·위치와 구조물(P3-4a)은 아직 전역. 계약은 docs/09 §15.2, 임시 가정·측정값·사용자 확인 항목은 docs/15 §15.2 | `scripts/services/multiplayer/`, `scripts/presentation/`, `scenes/main/client_view.tscn`, `scripts/core/build_info.gd`·`composition_config.gd`·`server_composition.gd`, `data/tuning/interest_settings.tres`·`client_presentation_settings.tres`, `tests/unit/cell_interest_test.gd`·`zombie_scope_events_test.gd`·`world_map_presentation_test.gd`, `tests/integration/interest_net_test.gd`·`interest_view_test.gd`·`interest_measure_test.gd` | Fable | 완료 |
| P3-3 | 건물과 보관함: 테스트 맵 건물 배치 데이터, 보관함 인벤토리, 수색·넣기·꺼내기 의도(창고를 거쳐 아이템 옮기기), 서버 시드 루팅(셀 재활성화로 다시 생기지 않음). 구현: 보관함(`ContainerService`, 내용물은 `InventoryService`의 보관함 전용 인벤토리, 넣기·꺼내기 = `transfer_item`), 열기·수색(행동 시간 1.5초)·꺼내기·넣기·닫기, 데이터 루팅 테이블과 보관함마다 기록한 시드로 한 번만 굴림, 셀 문서 저장·해제·복구, 맵 콘텐츠 데이터(`MapContentService`: 건물 8채, 구조물 370개, 보관함 21개, 월드마다 한 번, 이전 월드는 다음 시작 때 한 번, 전용 서버 기본 = 테스트 맵 / 테스트 기본 = 없음), NetModule `ContainerNet`(관심 셀 접속자에게만 존재, 연 사람에게만 내용물), 클라이언트 미러·임시 상자 표시·HUD 블록·키 H/J/K/U/I, `PROTOCOL_VERSION` 15(14는 P3-5). 계약은 docs/09 §15.3, 결정 기록 docs/00 ADR-026, 임시 가정·측정값·사용자 확인 항목은 docs/15 §15.3. 지을 수 있는 보관 상자는 P3-3b로 이어졌다 | `scripts/domain/containers/`, `scripts/domain/map_content/`, `scripts/services/world/map_content_service.gd`, `scripts/services/multiplayer/container_net_module.gd`·`container_net_settings.gd`·`client_container_state.gd`, `scripts/presentation/container_*.gd`, `resources/definitions/containers/`·`loot_tables/`·`maps/`, `data/tuning/container_settings.tres`·`container_net_settings.tres` | Fable·Opus | 완료 |
| P3-3b | 지을 수 있는 보관 상자: 청사진→자재→작업→완공 뒤 빈 보관함 생성, 구조물·보관함 양방향 저장 링크, 내용물이 있으면 철거 거부, 셀·저장 복구와 기존 관심 영역 복제, 건축 키 4 | `scripts/domain/building/`, `scripts/domain/containers/`, `scripts/presentation/`, `resources/definitions/structures/`, `resources/definitions/containers/`, 관련 단위·통합 테스트 | Codex | 완료 |
| P3-4 | 격자 구조물: 바닥·벽·문 정의, 배치 검증(격자·겹침·거리), 배치 의도, 복제·저장, 서버 이동 충돌, 문 여닫기 | `scripts/domain/building/`, `resources/definitions/structures/` | Fable·Codex·Opus | 완료 — 서버·네트워크(P3-4a)와 클라이언트 표시·건축 입력(P3-4b) |
| P3-5 | 청사진·자재·완공: 청사진 상태, 자재 투입, 작업 진행, 완공, 취소·철거 환급 (지을 수 있는 보관 상자는 보관함이 생기는 P3-3으로 옮겼다) | `scripts/domain/building/`, `scripts/domain/inventory/inventory_service.gd`(트랜잭션 둘), `scripts/services/multiplayer/structure_net_*.gd`·`client_structure_state.gd` | Fable·Opus | 서버·네트워크 완료. 계약 docs/09 §15.5, 임시 가정 docs/15 §15.5. `PROTOCOL_VERSION` 14. 구조물·작업자도 P3-2의 관심 셀로 거른다(docs/15 P3-056 해소, P3-057~P3-060). 클라이언트 표시·입력은 P3-4b |
| P3-6 | 내비게이션 갱신: 구조물·문 변화가 좀비 경로와 시야에 반영(영향 영역만 갱신) | `scripts/domain/navigation/`, `scripts/domain/zombie/` | Fable·Codex·Opus | 완료 — 서버 전용(프로토콜·저장 변경 없음). 전역 메시 없는 격자 경로 탐색(`NavigationService`, `building` 뒤 등록), 재개 가능한 검색과 결정적 노드 예산(검색당 2048, 틱당 48, 검색별 8, FIFO 라운드로빈), 완공 벽·닫힌 문이 좀비 경로·시야·근접 공격을 막음(청사진·열린 문·보관 상자는 막지 않음, 소음은 통과), 테스트 맵 건물에서 문으로 드나듦을 확인. 계약 docs/09 §15.6, 결정 기록 docs/00 ADR-027, 임시 가정·측정값 docs/15 §15.6 |
| P3-Z | Phase 3 수용 시나리오: 셀 이동·저장·복구, 두 플레이어가 같은 구조물을 봄. `tests/scenarios/phase3_acceptance_test.gd`(테스트 6개, 전용 서버와 같은 조립: 실제 파일·개발용 시드·테스트 맵): 셀 경계를 넘는 이동과 셀 활성·해제·재로딩, 청사진→자재→작업→완공을 두 클라이언트가 단계마다 같게 봄과 벽이 두 사람의 이동을 막음, 테스트 맵 문, 보관함 넣기·꺼내기와 정보 공개 범위, 닫힌 문 밖 좀비, 일부 셀이 내려간 채 저장 → 서버 재시작 → 복구(수량 보존·맵 재시드 없음·루팅 재굴림 없음), 조작된 요청. 수용 항목 대응표는 docs/12 §7, 검증하지 못한 항목은 docs/15 §15.9. 게임 코드 변경 없음 | `tests/scenarios/` | Fable | 완료 |

## 16. Phase 4 티켓 계획 (2026-11-17 초안)

사용자 지시: "지금부터 쭉 작업을 진행하고 마지막에 수치랑 규칙 조정을 하자", "에이전트들 활용많이해서 빠르게 해". 그래서 Phase 4는 아래 "결정이 필요한 것"의 **임시 기본값으로 바로 시작**하고, 수치·규칙은 Phase 4가 끝난 뒤 한꺼번에 조정한다. 진행 방식은 §14·§15와 같다(한 티켓 한 핵심 목표, `tools/check.sh` 통과 후 main 병합, 공유 조립 파일과 문서는 조정자가 병합 때 정리). 근거 문서: docs/05 전체, docs/16, docs/09 §7·§8·§14.5·§15.1·§15.2·§15.6, docs/14 §3·§6, docs/00 ADR-003·005·009·023·027. 계약은 docs/09 새 절(§17 예정), 임시 가정은 docs/15 새 절(번호 `P4-xxx`)에 티켓마다 적는다.

Phase 4의 완료 기준(§6): NPC 5명이 자율적으로 먹고 마시고 쉬고 일하며, 저장 → 서버 재시작 → 복구 뒤 같은 상태로 이어 간다. 사회 행동(대화·도움·갈등·연애·범죄)은 Phase 5다. Phase 4는 감정·기억·관계를 **데이터 구조와 저장**까지만 만든다.

### 16.1 티켓

| 티켓 | 핵심 목표 | 소유 영역 | 담당 | 상태 |
|---|---|---|---|---|
| P4-1 | NPC 정체성·정적 정의·고유 ID·셀 저장. `NpcDefinition`(Resource: 이름, 외형 선택지 ID, 나이대, 배경 태그, 성격 11축(docs/05 §3, 0~1), 능력(docs/05 §2.2), 업무 역할, 집·작업 지점 참조), 런타임 `NpcState`(`npc_<번호>`, `definition_id`, 위치·방향, `simulation_tier`, NPC별 RNG seed/state, 구성 요소 문서 슬롯), 새 ServerSystem `npc`(`NpcService`: 생성·조회·제거, `cell_index` 종류 `npc`, 셀 훅 다섯과 셀 문서 `systems.npc`, 떠돌이·월드 문서, 고유 ID 은퇴 규칙), 구성 요소 계약 `NpcComponent`(`component_id`, `to_document`/`restore_document`, `schema_version`: 뒤 티켓이 `NpcState`를 고치지 않고 파일을 더하는 자리), 개발용 NPC 5명 명단(`resources/definitions/npcs/`)과 월드마다 한 번 배치(맵 콘텐츠처럼 world_state에 기록, 테스트 조립 기본은 없음), NPC 시드 = 월드 시드 + NPC ID(엔진 전역 난수 금지). 아직 생각하지도 움직이지도 않는다 | `scripts/domain/npc/`(`npc_definition.gd`·`npc_state.gd`·`npc_service.gd`·`npc_component.gd`·`npc_settings.gd`), `resources/definitions/npcs/`, `data/tuning/npc_settings.tres`, `scripts/core/server_composition.gd`·`composition_config.gd`(등록 한 줄씩), `tests/unit/npc_state_test.gd`·`npc_cell_persistence_test.gd` | Opus(Fable 권장이나 11-18 23:00 전 착수) | 완료 대기(병합 전). 계약 docs/09 §17.1, 임시 가정 docs/15 §17.1. 계획에 없던 파일 셋(`npc_catalog.gd`·`npc_roster.gd`·`npc_stage.gd`)과 소유 영역 밖 변경 둘(`world_persistence.gd`·`game_bootstrap.gd`)이 있다 |
| P4-2 | 욕구 모델: hunger·thirst·fatigue 세 욕구의 달력 시간(ADR-006) 증가와 범주(정상/주의/위험), 활동별 변화율(쉬는 중 fatigue 감소, 일하는 중 증가 가속), 성격·능력 modifier 자리(기본 1.0), **구간 적분**(`SurvivalService`와 같은 방식: 갱신 주기가 1초든 10초든 같은 결과, 다음 범주 경계 시각을 계산해 돌려줌), 욕구 감소 API(`satisfy(kind, amount, source)`), 구성 요소 `needs` 저장. 나머지 욕구(warmth, hygiene, 사회·자율 욕구)는 정의 데이터에만 있고 변화율 0(docs/16 B에서 확정) | `scripts/domain/npc/needs/`, `data/tuning/npc_need_settings.tres`, `tests/unit/npc_needs_test.gd` | Codex | 완료 대기(병합 전). 계약 docs/09 §17.2, 임시 가정 docs/15 §17.2. P4-1 회귀 기대값 1건은 조정자 수정 필요 |
| P4-3 | AI 스케줄러: 갱신 종류별 주기 분리(CLAUDE.md §6, docs/09 §7) — 욕구 평가·행동 재평가·경로 계획·이동·복제를 서로 다른 주기와 예산으로. 기존 `BucketScheduler`로 결정 버킷(근거리·원거리 두 단계), 틱당 결정 상한, 이벤트 인터럽트 큐(긴급 사건은 주기를 기다리지 않음, 한 NPC당 틱 1회), NPC LOD 단계 판정(가까운 플레이어와의 거리, ACTIVE 셀만 시뮬레이션), **다음 결정 시각·버킷 위상을 저장**(P2-31 좀비와 달리 저장을 사이에 둔 연속 실행과 복구 실행이 같게), 진단값(틱당 결정 수, 인터럽트 수, 단계별 NPC 수, NPC 단계 처리 시간). 결정 함수 자체는 주입받는다(P4-4 전에는 "결정 없음") | `scripts/domain/npc/scheduling/`, `data/tuning/npc_schedule_settings.tres`, `tests/unit/npc_scheduler_test.gd` | Opus → Fable 권장(11-18 23:00 뒤 검토) | 완료 대기(병합 전, 2026-11-19). 계약 docs/09 §17.3, 임시 가정 docs/15 §17.3(P4-061~P4-082). 계획과 다른 점: `BucketScheduler`를 쓰지 않고 같은 분산을 단계의 정수 시계 격자로 계산한다(그 클래스는 위상을 저장·복구할 수 없다, `notes/p4-3-npc-scheduler.md`). 소유 영역 밖 변경: `npc_state_test.gd`·`npc_cell_persistence_test.gd`·`npc_mind_test.gd`의 문서 비교 세 군데(`schedule` 슬롯 제외) |
| P4-4 | 행동 선택: 하드 인터럽트 + 정규화된 Utility + 제한된 상태 머신(docs/05 §9·§10). 후보 행동 정의(Resource: 선행조건, 기본 우선순위, 욕구·성격·환경 항 가중치), 항마다 범위 [0,1] 고정과 합산식, 동점 해소(점수 → 고정 우선순위 → 행동 ID, RNG 흔들림은 NPC RNG만), 반복·진동 방지(현재 행동 유지 보너스와 최소 지속 시간), 무행동 대체(Idle 배회), 상태 Idle/Evaluate/Plan/Navigate/Perform/Interrupt/Recover와 허용 전이, 실패 사유 코드와 Recover 쿨다운, 첫 하드 인터럽트 "보이는 좀비로부터 도주"(좀비 시야와 같은 선 차단 훅 `ServerWorld.is_line_blocked`), **결정 기록 링 버퍼**(상위 후보와 항별 점수, 고른 행동, 실패 사유: 디버그 오버레이와 테스트의 근거). 관계·기억 항(`relationship_context`, `memory_context`)은 0으로 두고 자리만 둔다(Phase 5) | `scripts/domain/npc/decision/`, `resources/definitions/npc_actions/`, `data/tuning/npc_decision_settings.tres`, `tests/unit/npc_decision_test.gd` | **Fable 권장** | 완료 대기(병합 전, 2026-11-19). 계약 docs/09 §17.6(실행기 계약 포함), 임시 가정 docs/15 §17.6(P4-151~P4-171). 실행기(P4-5a)가 연결되기 전에는 기본 조립의 결정 함수가 아무것도 정하지 않는다. 계획과 다른 점: 욕구 경계 인터럽트 사유는 `need_boundary` 하나, 실패 보고 사유는 `action_failed_<code>`(인터럽트 사유는 snake_case만 된다), 결정 사이의 위협 확인용 단계 `threat_sensor`를 더함, `goal_alignment`·비용 항은 식에 없음. 소유 영역 밖 변경: `server_composition.gd`(결정 함수 조립, `NpcNetModule`에 라벨 함수 전달), `composition_config.gd`(`npc_decision`·`npc_actions`) |
| P4-5a | 행동 실행 계층: 이동 실행기(기존 `NavigationService.begin_search` 재사용, NPC 전용 FIFO와 틱 노드 예산, 경로 waypoint, 한 걸음마다 `ServerWorld.resolve_movement`), 닫힌 문 처리(경로 탐색 옵션 "문은 지나갈 수 있음"을 `GridPathSearch`에 추가하고, 문 앞에서 서버 규칙 `BuildingService.set_door_open`으로 열고 지나간 뒤 닫음), 지점 예약(침대·작업 지점·급수 지점: 한 지점 한 NPC, 예약 해제 규칙), 경로 실패·대상 사라짐·예약 충돌의 사유 코드. 진행 중 행동과 남은 waypoint는 저장(재계획 없이 이어 가기) | `scripts/domain/npc/behaviours/npc_executor.gd`·`npc_reservations.gd`, `scripts/domain/navigation/grid_path_search.gd`·`grid_path_finder.gd`(옵션 하나), `tests/unit/npc_executor_test.gd` | **Fable 권장**(경로·문·예약의 경계 사례) | 완료 대기(병합 전, 2026-11-19). 계약 docs/09 §17.7, 임시 가정 docs/15 §17.7(P4-181~P4-210). 계획과 다른 점: 실패 사유는 `action_failed_<code>`(스케줄러 사유 이름이 `:`를 받지 않는다), 검색 중이던 NPC도 복구 뒤 같은 틱에 검색이 끝난다(확장 노드 수를 저장해 다시 돌린다, D11보다 강함). 계획에 없던 파일: `npc_executor_state.gd`·`npc_executor_settings.gd`·`npc_spot_definition.gd`·`npc_spot_set.gd`, `resources/definitions/npc_spots/dev_test_map_spots.tres`(D7 지점 데이터), `tests/unit/npc_executor_search_test.gd` |
| P4-5b | 기본 행동 다섯: 먹기(지정 보관함에서 음식 한 단위를 자기 인벤토리로 `transfer_item` → 소비로 hunger 감소, 기존 아이템 정의의 소비 효과 재사용), 마시기(급수 지점 데이터, 무한), 쉬기(침대 지점 또는 제자리, 달력 시간으로 fatigue 감소, 위험하면 깸), 일하기(업무 역할·작업 지점·일과 시간대, 행동 시간 누적과 "한 일" 기록. 생산·건축 기여는 Phase 6), 이동·배회. NPC 전용 인벤토리(보관함과 같은 detached inventory, 칸 수 설정), 행동마다 시작·완료·실패 도메인 이벤트 | `scripts/domain/npc/behaviours/`(실행기 제외), `resources/definitions/npc_actions/`(P4-4와 파일 단위로 나눔), `resources/definitions/npc_spots/` 또는 맵 콘텐츠의 NPC 지점, `tests/unit/npc_behaviour_test.gd` | Codex(P4-4·P4-5a 계약 뒤) | 완료 대기(병합 전, 2026-11-19). 계약 docs/09 §17.8, 임시 가정 docs/15 §17.8(P4-211~P4-230). 결정 계층(P4-4)과 실행기(P4-5a)를 연결해 기본 조립의 NPC가 스스로 결정하고 움직인다. 계획과 다른 점: 초기 식량을 NPC 지점 데이터(`stock_item_id`·`stock_units`)에 적고 행동 계층이 월드마다 한 번 넣는다(맵 콘텐츠 형식에 초기 내용 칸이 없다), 쉬기는 P4-4의 선행조건 때문에 쪽잠이 된다(P4-219: 수치 조정 때 볼 것). 계획에 없던 파일: `npc_behaviours.gd`·`npc_behaviour_executor.gd`·`npc_behaviour_state.gd`·`npc_behaviour_settings.gd`, `tests/unit/npc_behaviour_day_test.gd`. 다른 티켓 테스트 다섯 파일의 조립에 `npc_behaviour = null`을 넣었다 |
| P4-6 | 감정·기억·관계 데이터 구조(행동은 없음): `NpcEmotions`(docs/05 §5의 13축, 시간 감쇠 반감기 설정, 지연 계산), `NpcMemoryStore`(docs/05 §6 필드: `memory_id`, `event_id`, `event_type`, 참여자와 역할, 장소·달력 시각, 관찰 신뢰도 직접/목격/전언, 중요도, 감정 강도, 반복 횟수, 해석 태그, 강도와 감쇠. NPC당 상한과 중요도 기반 축출, 장기 보호 표시, 같은 `event_id` 통합), `scripts/domain/relationships/`의 `RelationshipState`(docs/14 §3 필드, 방향성: A→B와 B→A 별도 레코드, 대상은 NPC ID 또는 `player_id`)와 `RelationshipStore`(소유 NPC 기준 저장, `status`는 저장만 하고 점수로 자동 변경하지 않음). P4-5b의 이벤트 몇 개(배고픔 해소, 도주)를 작은 기억·감정 변화로 기록해 저장 경로를 실제로 쓴다. 사건 원장(WorldEvent)은 Phase 5: P4는 `event_<번호>` ID만 발급 | `scripts/domain/npc/mind/`, `scripts/domain/relationships/`, `data/tuning/npc_mind_settings.tres`, `tests/unit/npc_mind_test.gd`·`relationship_store_test.gd` | Codex | 완료 대기(병합 전). P4-5b가 아직 없어 기록 API를 직접 호출한 셀 해제·재로딩 왕복으로 저장 경로를 검증. 계약 docs/09 §17.4, 임시 가정 docs/15 §17.4 |
| P4-7 | NPC 복제·관심 범위·정보 공개: NetModule `NpcNet`(docs/09 §15.2의 "셀을 옮겨 다니는 엔티티" 방식 = 좀비처럼 접속자별 흐름과 주기적 대조, `npc_entered`/`npc_left`), 공개 행 = ID·이름·외형·위치·방향·**관찰 가능한 행동 라벨**(걷기·먹기·자기·일하기·도주)·자세. 욕구·감정·기억·관계·성격·능력·목표는 보내지 않는다(ADR-009를 NPC에 그대로 적용), 위치 스냅샷 ch2, 이벤트 ch0, 접속 조각, 클라이언트 미러 `ClientNpcState`, 임시 캡슐 표시와 이름표(묶음 그리기, §16.2 방식), `PROTOCOL_VERSION` 올림 | `scripts/services/multiplayer/npc_net_*.gd`·`client_npc_state.gd`, `scripts/presentation/npc_*.gd`, `scripts/core/build_info.gd`, `tests/integration/npc_net_test.gd` | Codex(패턴 확정, Opus 검토) | 구현 완료·조정자 검사 대기. 계약 docs/09 §17.5, 임시 가정 docs/15 §17.5(P4-121~130), 관련 자동 테스트 10개 통과(샌드박스의 `user://`·인증서 오류로 래퍼 종료 코드는 1) |
| P4-8 | AI 디버그 오버레이(docs/05 §17): 서버 쪽 조회(`NpcDebugQuery`: 상태·목표·행동, 상위 후보와 항별 점수, 욕구·감정·관계 수치, 마지막 기억, 취소·실패 사유, 현재 경로와 목적지, LOD 단계, seed와 리플레이 식별자), **개발용 서버 설정이 켜졌을 때만** 허용된 접속자에게만 보내는 디버그 구독 RPC(기본 꺼짐: 전용 서버에서는 꺼짐, 테스트·개발 조립에서 켬. 꺼져 있으면 조회 자체를 하지 않음), 클라이언트 패널(F-키, 바라보는 NPC 선택)과 월드 위 경로선, 헤드리스 텍스트 덤프(테스트·soak 로그용) | `scripts/domain/npc/debug/`, `scripts/services/multiplayer/npc_debug_net_*.gd`, `scripts/presentation/npc_debug_*.gd`, `scenes/main/client_view.tscn`, `tests/unit/npc_debug_query_test.gd`, `tests/integration/npc_debug_net_test.gd` | Codex(서버 조회·RPC) + Antigravity/Codex(패널 UI) | 구현 완료·조정자 검사 대기. 계약 docs/09 §17.9, 임시 가정 docs/15 §17.9(P4-241~270). 전용 서버 기본 꺼짐, 권한·관심 범위 전송 격리와 꺼짐 조회 0회를 실제 ENet 테스트로 확인. 실제 창과 전체 `check.sh`는 미확인 |
| P4-Z | Phase 4 수용 시나리오: 전용 서버와 같은 조립(테스트 맵·개발용 NPC 5명·고정 seed)에서 NPC 5명이 **달력 3일**(24배속 = 실제 3시간, 헤드리스 고정 틱으로 가속) 동안 지시 없이 먹고 마시고 쉬고 일함(욕구가 위험 범주에 머무는 시간 상한, 행동 정체 없음: 같은 실패 반복 상한), 좀비를 보면 업무 중단·도주, 같은 seed 두 번 실행의 결정 기록 일치, 1.5일째 저장 → 서버 재시작 → 복구 → 이어 간 실행과 끊지 않은 실행의 최종 상태 해시 일치, 셀 해제 → 재로딩 왕복, 두 클라이언트가 같은 NPC 행을 보고 비공개 값이 전선에 없음, 측정 테스트(NPC 5/25/50명, 100명은 환경 변수로만). 장시간 soak(달력 10일)은 환경 변수로만 | `tests/scenarios/phase4_acceptance_test.gd`, `tests/unit/npc_measure_test.gd`, 시나리오에서 찾은 결함 수정만 | Fable(11-18 23:00 뒤) | 완료 대기(병합 전, 2026-11-19). 결과 수치는 docs/15 §17.10, 임시 가정 P4-172·P4-281~P4-286. 계획과 다른 점: 시나리오는 P1 단계(약 4분), 틱은 1/20초(측정만 1/60초), 측정은 25회 반복 대신 긴 실행(25명만 3회). 찾은 결함 둘을 고쳤다: 쉬기가 쪽잠만 되던 것(`runs_until_done`), 저장한 시계가 끝자리에서 틀리게 읽히던 것(`FloatBits`). 계획에 없던 파일: `tests/framework/npc_life_run.gd`, `scripts/core/float_bits.gd`. 소유 영역 밖 변경: `scripts/services/world/server_world.gd`(시계 비트 두 키), `tests/unit/npc_decision_test.gd`·`npc_save_roundtrip_test.gd`(테스트 하나씩 추가) |

### 16.1.1 Phase 4 완료 요약 (2026-11-19, P4-Z)

완료 기준("NPC 5명이 자율적으로 먹고 마시고 쉬고 일하며, 저장 → 서버 재시작 → 복구 뒤 같은 상태로 이어 간다")을 자동 시나리오로 확인했다(docs/15 §17.10). 전용 서버와 같은 조립의 달력 3일 동안 NPC 5명 모두 매일 먹고(1~2번) 마시고(2~3번) 끝까지 쉬고(4~5번) 일했고(18~21교대), 욕구가 위험 범주에 든 시간은 0분, 실패는 0번이었다. 1.5일째 실제 파일 저장 → 새 서버 시작 → 이어 간 실행의 최종 월드 문서 해시가 끊지 않은 실행과 같다. 같은 seed 두 번의 결정 기록이 같고, 셀 해제 → 재로딩을 넘어 하던 일을 이어 가며, 두 클라이언트가 같은 공개 행만 본다. 성능은 25명에서 NPC 단계 중앙값 0.31ms·반복 가능한 최악 1.95ms(목표 1.0 / 2.0)다.

이것은 자동 검사 통과다. NPC가 그럴듯하게 사는지(하루 16~18시간 일함, 하루 4~5번 나눠 잠, 식량 9일째 바닥, 좀비가 안 보이면 바로 일터 복귀)는 수치·규칙 조정에서 사용자가 정한다. 조정 항목은 docs/15 §17.1~§17.10의 "사용자 확인이 필요한 결정"에 있다. 실제 창에서는 아직 보지 않았다.

### 16.2 병렬 계획과 담당

파일 소유가 겹치지 않도록 NPC 도메인을 하위 폴더로 나눈다(`npc/` 루트 = P4-1, `needs/` = P4-2, `scheduling/` = P4-3, `decision/` = P4-4, `behaviours/` = P4-5a·P4-5b(파일 단위), `mind/`·`relationships/` = P4-6, `debug/` = P4-8). `NpcState`·`NpcService`는 P4-1만 고치고, 뒤 티켓은 `NpcComponent`와 `NpcService`가 받는 주입 지점(욕구 모델, 스케줄러, 결정 함수, 실행기)에 **파일을 더한다**. `server_composition.gd`·`composition_config.gd`·`build_info.gd`와 문서는 조정자가 병합 때 정리한다(§14 병렬 규칙).

| 단계 | 동시에 진행 | 선행 조건 |
|---|---|---|
| 1 | P4-1 | 없음. 첫날 `NpcState`·`NpcComponent`·`NpcService` 주입 지점의 계약(docs/09 초안)만 먼저 병합하면 2단계가 바로 시작된다 |
| 2 | P4-2, P4-3, P4-6, P4-7 | P4-1 계약. P4-7은 행동 라벨을 "idle" 고정으로 시작하고 P4-4 뒤 값만 채운다 |
| 3 | P4-4, P4-5a | P4-2(욕구 범주·경계 시각), P4-3(주기·인터럽트). P4-5a는 P4-3만 있으면 되고 P4-4와 동시에 간다 |
| 4 | P4-5b, P4-8 | P4-4의 후보 행동 계약과 P4-5a의 실행기. P4-8의 패널 UI는 P4-4 결정 기록 형식만 정해지면 가짜 데이터로 먼저 만든다 |
| 5 | P4-Z | 전부 |

모델 배정(사용자 규칙: 설계가 무거운 일은 Fable, Fable은 2026-11-18 23:00부터 다시 사용 가능):

- **Fable 권장**: P4-4(행동 선택 수식·상태 머신·결정론), P4-5a(경로·문·예약의 경계 사례), P4-3 검토(주기·저장 위상), P4-Z. Fable이 돌아오기 전에는 P4-4의 후보 행동 표와 정규화 규칙 초안만 Opus가 docs/09에 쓰고, 구현은 Fable에 넘긴다.
- **11-18 23:00 전에 진행**: P4-1(Opus), P4-2·P4-6·P4-7(Codex, 각자 계약이 docs/05·docs/14·docs/09 §15.2에 이미 있다), P4-3(Opus 구현, 뒤에 Fable 검토).
- **Codex 단독 가능**(계약이 정해져 있고 파일이 닫혀 있음): P4-2, P4-6, P4-7, P4-5b, P4-8 서버 쪽. P4-8 패널은 UI 담당(Antigravity) 가능.

### 16.3 결정이 필요한 것 (임시 기본값으로 시작)

아래는 문서가 열어 둔 것 중 Phase 4를 막거나 모양을 바꾸는 것이다. 사용자 지시대로 기본값으로 진행하고, 끝난 뒤 수치·규칙 조정 때 한꺼번에 묻는다. 티켓 착수 때 docs/15 `P4-xxx` 항목으로 옮긴다. NPC AI 심화 영역과의 대응은 docs/16 §6.

| # | 질문 | 임시 기본값 | 바꾸면 영향받는 티켓 |
|---|---|---|---|
| D1 | 서버당 NPC 수(docs/00 §8 "NPC 최대 인구") | 기능 목표 5명(**2026-11-23 사용자 "npc 최소 10명까지 늘려줘": 개발용 명단 10명**), 예산 설계 기준 25명, 설정 상한 50명(넘는 스폰은 거부·로그). 100명은 측정만 | P4-1, P4-3, P4-Z |
| D2 | NPC가 아이템을 줍거나 소유하는가 | 소유한다: NPC마다 작은 전용 인벤토리(보관함과 같은 detached inventory). 먹을 것은 **지정된 보관함**에서 `transfer_item`으로 가져와 바로 소비한다. 바닥 아이템 줍기·남의 것 가져가기·플레이어와의 거래는 없음(절도는 Phase 5) | P4-5b, P4-6 |
| D3 | NPC가 죽거나 감염·좀비화하는가 | (**2026-11-23 F-25로 바뀜**: NPC는 다치고 감염되고 죽고 좀비가 된다, docs/09 §17.12. 아래는 Phase 4 당시의 값) Phase 4에서는 **죽지 않는다**: 좀비는 NPC를 목표로 삼지 않고(좀비 코드 변경 없음), 욕구가 최대여도 체력 피해 없이 행동 페널티(업무 거부)만 생긴다. NPC는 보이는 좀비로부터 도주한다(인터럽트 경로 검증용). 부상·감염·사망·좀비화는 별도 티켓(Phase 5 또는 7) | P4-4, P4-5b |
| D4 | 원거리·오프라인 시뮬레이션(CLAUDE.md §6, docs/16 K) | ACTIVE 셀의 NPC만 시뮬레이션하고 나머지는 좀비처럼 그대로 멈춘다(ADR-023과 같다). `last_simulated_world_time`을 저장해 두고 요약 따라잡기는 docs/16 K 설계 뒤 별도 티켓. 접속자 0명이면 시계가 멈춘다(기존) | P4-1, P4-3 |
| D5 | NPC는 어디서 오는가 | 개발용 명단 5명을 월드마다 한 번, 테스트 맵 건물 안 지점에 배치(맵 콘텐츠와 같은 방식, world_state에 기록). 모집·이주·출생 없음 | P4-1 |
| D6 | 플레이어가 NPC에게 업무를 지시하는가 | Phase 4에서는 없다. 업무 역할·작업 지점·일과는 정의 데이터. 지시 의도(`AssignNpcJob`, docs/14 §5)는 쉘터와 함께 Phase 6 | P4-5b |
| D7 | 쉘터가 없는데 "집·식량 창고·작업장"은 무엇인가 | 맵 콘텐츠 데이터에 NPC 지점(침대, 작업, 급수)과 식량 보관함 ID를 둔다. 소유권·배급 규칙 없음 | P4-1, P4-5a, P4-5b |
| D8 | NPC가 문을 여닫는가 | 연다: 경로 탐색은 문을 지나갈 수 있는 변으로 보고, 문 앞에서 서버 규칙으로 열고 지나간 뒤 닫는다(좀비 차단 유지). 문 상태 변화는 플레이어가 연 것과 같이 공개 | P4-5a |
| D9 | 다른 플레이어에게 보이는 NPC 정보 | ADR-009를 NPC에 그대로: 이름·외형·위치·자세·관찰 가능한 행동 라벨만. 욕구·감정·기억·관계·성격은 아무에게도 보내지 않고, 디버그 오버레이는 개발 설정이 켜진 서버의 허용된 접속자에게만 | P4-7, P4-8 |
| D10 | NPC 시간 기준 | ADR-006대로: 욕구 변화·수면 회복·일과 시간대는 달력 시간(하루 = 실제 1시간), 걷기·먹는 동작·작업 진행·재계획 간격은 행동 시간(실제 초) | P4-2, P4-3, P4-5b |
| D11 | "저장 후 복구가 같다"의 강도 | 강한 동일성: 다음 결정 시각, 진행 중 행동, 남은 waypoint, 예약, NPC RNG 상태를 저장해 "끊지 않은 실행"과 "1.5일째 저장 → 재시작 → 이어 간 실행"의 최종 상태가 같다. 진행 중이던 경로 **검색**만은 저장하지 않으므로, 저장 시점에 검색 중이던 NPC는 복구 뒤 새로 검색한다(같은 입력이면 같은 결과라 상태는 같다) | P4-3, P4-5a, P4-Z |
| D12 | NPC와 몸 충돌 | 지금의 플레이어·좀비와 같이 점으로 움직이고 서로 통과한다. 구조물 충돌만 적용 | P4-5a |
| D13 | 욕구 목록 | hunger·thirst·fatigue만 변화. 안전은 저장하지 않는 파생 값(보이는 위협). 나머지 욕구는 데이터에만 있고 변화율 0 | P4-2, P4-4 |

### 16.4 성능 예산 제안 (측정 전 목표, 보장값 아님)

기준: 서버 물리 틱 60Hz(16.7ms). 지금 측정된 비용(docs/15 §15.6·§16): 40m 벽 앞 추격 좀비 100마리의 서버 틱 전체 중앙값 3.6ms·최악 6.1ms(경로 계획 1.7ms, 틱 48노드), 좀비 복제는 스냅샷 틱(10Hz)마다 1.5ms, 관심 셀 갱신은 틱의 0.2%, 저장 요청의 메인 스레드 문서 생성 22~27ms(구조물 370개). 즉 좀비 100마리 기준으로 틱의 절반 이상이 남아 있다. NPC는 다음 안에 들어오게 만든다.

| 항목 | 주기/예산(설정값) | 근거 |
|---|---|---|
| NPC 단계 전체 | NPC 25명에서 틱당 중앙값 ≤ 1.0ms, 최악 ≤ 2.0ms. 5명에서 중앙값 ≤ 0.3ms | 좀비 100마리 최악 6.1ms + 좀비 복제 1.5ms + NPC 2ms가 틱의 60% 안 |
| 이동 | 매 틱, waypoint가 있는 NPC만. 걸음마다 `resolve_movement` 한 번 | 좀비와 같은 비용(걸음당 수 µs) |
| 욕구 평가 | 매 틱 하지 않는다. 결정 틱에 구간 적분으로 따라잡고, 다음 범주 경계 시각을 인터럽트 큐에 예약 | 주기와 무관한 결과(P4-2), 빈 틱 비용 0 |
| 행동 재평가 | 근거리(가장 가까운 플레이어 30m 이내) 2초, 원거리 10초, 버킷 10개, 틱당 결정 상한 2. 현재 행동 완료·실패·인터럽트 때는 다음 틱에 즉시(상한 안에서) | docs/05 §11의 1~3초 / 5~15초 |
| 경로 계획 | NPC 전용 FIFO, 틱 전체 24노드, 검색별 틱 8노드, 틱당 계획 4개, 검색당 누적 2048노드·반경 60m(좀비 설정 재사용), NPC별 최소 재계획 간격 1초 | 좀비 48노드와 합쳐 72노드: 측정된 48노드 ≈ 1.7ms 비율로 계획 합계 ≈ 2.6ms 이하 |
| 감정·기억 감쇠 | 저장된 시각에서 지연 계산(조회·결정 때만). 기억 NPC당 64개 상한 | 매 틱 비용 0 |
| 복제 | NPC 위치 스냅샷 5Hz(ch2), 행동 라벨 변화는 이벤트(ch0), 관심 셀 대조는 스냅샷 틱에만 | 좀비 10Hz의 절반. NPC는 좀비보다 느리고 적다 |
| 디버그 오버레이 | 꺼져 있으면 0. 켜져 있으면 구독한 NPC 하나를 2Hz | 개발 전용 |
| 저장 | 25명의 NPC 문서 생성 ≤ 2ms(메인 스레드), 파일 쓰기는 PERF-1 워커 | 현재 저장 요청 22~27ms에 10% 이하 추가 |

측정은 P4-Z의 `npc_measure_test.gd`(5/25/50명, 같은 맵, 25회 중앙값/최악)와 진단값(`last_npc_step_msec`, 틱당 결정 수, 계획 노드 수)으로 한다. 전용 서버 성능 모니터(`server/npc_step_time_ms`)를 더하려면 `network_service.gd`의 모니터 등록을 고쳐야 하므로(PERF-1) 조정자가 P4-Z 때 결정한다. 예산을 넘으면 먼저 원거리 재평가 주기와 틱당 결정 상한을 늘리고, 그래도 넘으면 docs/16 L로 올린다.

## 17. 새 기능 티켓 계획 (2026-11-20 초안)

수치·규칙 조정(docs/17)에서 사용자가 값 대신 새 기능으로 답한 것을 티켓 F-1~F-27과 수용 시나리오 F-Z로 나눴다. 사용자 지시 원문: "기능 계획 세우기". 티켓 표·순서(기능별 네 갈래 + 2단계, 2026-11-22 고침)·기본값 결정(FD-1~FD-11, 같은 날 사용자 답)은 `notes/feature-plan-2026-11-20.md`에 있다. 진행 방식은 §16과 같고, 주요 값은 사용자가 착수 전에 정했다.
