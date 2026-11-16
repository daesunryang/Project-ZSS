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
| P3-3 | 건물과 보관함: 테스트 맵 건물 배치 데이터, 보관함 인벤토리, 수색·넣기·꺼내기 의도(창고를 거쳐 아이템 옮기기), 서버 시드 루팅(셀 재활성화로 다시 생기지 않음). 구현: 보관함(`ContainerService`, 내용물은 `InventoryService`의 보관함 전용 인벤토리, 넣기·꺼내기 = `transfer_item`), 열기·수색(행동 시간 1.5초)·꺼내기·넣기·닫기, 데이터 루팅 테이블과 보관함마다 기록한 시드로 한 번만 굴림, 셀 문서 저장·해제·복구, 맵 콘텐츠 데이터(`MapContentService`: 건물 8채, 구조물 370개, 보관함 21개, 월드마다 한 번, 이전 월드는 다음 시작 때 한 번, 전용 서버 기본 = 테스트 맵 / 테스트 기본 = 없음), NetModule `ContainerNet`(관심 셀 접속자에게만 존재, 연 사람에게만 내용물), 클라이언트 미러·임시 상자 표시·HUD 블록·키 H/J/K/U/I, `PROTOCOL_VERSION` 15(14는 P3-5). 계약은 docs/09 §15.3, 결정 기록 docs/00 ADR-026, 임시 가정·측정값·사용자 확인 항목은 docs/15 §15.3. **지을 수 있는 보관 상자(P3-5에서 이 티켓으로 옮겨 왔다)는 P3-3b로 이어서 한다**(서버 진입점 `create_container`만 있음) | `scripts/domain/containers/`, `scripts/domain/map_content/`, `scripts/services/world/map_content_service.gd`, `scripts/services/multiplayer/container_net_module.gd`·`container_net_settings.gd`·`client_container_state.gd`, `scripts/presentation/container_*.gd`, `resources/definitions/containers/`·`loot_tables/`·`maps/`, `data/tuning/container_settings.tres`·`container_net_settings.tres` | Fable·Opus | 완료 |
| P3-4 | 격자 구조물: 바닥·벽·문 정의, 배치 검증(격자·겹침·거리), 배치 의도, 복제·저장, 서버 이동 충돌, 문 여닫기 | `scripts/domain/building/`, `resources/definitions/structures/` | Fable·Codex·Opus | 완료 — 서버·네트워크(P3-4a)와 클라이언트 표시·건축 입력(P3-4b) |
| P3-5 | 청사진·자재·완공: 청사진 상태, 자재 투입, 작업 진행, 완공, 취소·철거 환급 (지을 수 있는 보관 상자는 보관함이 생기는 P3-3으로 옮겼다) | `scripts/domain/building/`, `scripts/domain/inventory/inventory_service.gd`(트랜잭션 둘), `scripts/services/multiplayer/structure_net_*.gd`·`client_structure_state.gd` | Fable·Opus | 서버·네트워크 완료. 계약 docs/09 §15.5, 임시 가정 docs/15 §15.5. `PROTOCOL_VERSION` 14. 구조물·작업자도 P3-2의 관심 셀로 거른다(docs/15 P3-056 해소, P3-057~P3-060). 클라이언트 표시·입력은 P3-4b |
| P3-6 | 내비게이션 갱신: 구조물·문 변화가 좀비 경로와 시야에 반영(영향 영역만 갱신) | `scripts/services/navigation/`, `scripts/domain/zombie/` | Fable | 대기 |
| P3-Z | Phase 3 수용 시나리오: 셀 이동·저장·복구, 두 플레이어가 같은 구조물을 봄 | `tests/scenarios/` | Fable | 대기 |
