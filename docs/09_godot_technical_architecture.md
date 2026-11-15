# 09. Godot 기술 아키텍처 명세

## 1. 기준 환경

- Godot 4.7.2 Stable.
- GDScript 2.0, 정적 타입 사용.
- PC 우선.
- 서버 빌드와 클라이언트 빌드를 같은 저장소에서 export.
- 버전 업그레이드는 ADR 및 전체 회귀 테스트 후 진행.

## 2. 아키텍처 원칙

- 기능별 모듈 분리.
- 게임 규칙은 UI/씬 표현과 분리.
- 서버 권한 서비스와 클라이언트 프레젠테이션 분리.
- 데이터 정의 Resource와 런타임 상태 분리.
- 이벤트/시그널은 과도한 전역 결합 없이 명시적인 경계에서 사용.
- 도메인 규칙은 단위 테스트할 수 있도록 가능한 한 순수 로직으로 작성.

## 3. 권장 폴더 구조

```text
res://
  scenes/
    main/
    player/
    npc/
    zombie/
    world/
    building/
    farming/
    livestock/
    ui/
  scripts/
    core/
    domain/
      survival/
      combat/
      inventory/
      npc/
      relationships/
      events/
      building/
      farming/
      livestock/
      shelter/
    services/
      world/
      navigation/
      multiplayer/
      save/
      audio/
    presentation/
    debug/
  resources/
    definitions/
      items/
      structures/
      crops/
      animals/
      personalities/
      recipes/
  data/
    tuning/
  tests/
    unit/
    integration/
    scenarios/
  assets/
    models/
    materials/
    textures/
    animations/
    audio/
```

## 4. 주요 서비스

- `GameBootstrap`: 서버/클라이언트 시작 및 초기화.
- `WorldService`: 셀/청크 상태와 월드 엔티티 인덱스.
- `WorldClock`: 월드 시간 및 시간 배율.
- `WeatherService`: 서버 권한 날씨.
- `EntityRegistry`: 안정 ID와 런타임 엔티티 조회.
- `NavigationService`: 경로 요청/갱신 스케줄.
- `NpcSimulationService`: 욕구/감정/행동 틱 스케줄링.
- `EventService`: 월드 사건 기록과 구독.
- `InventoryService`: 서버 권한 아이템 트랜잭션.
- `BuildingService`: 건축 검증/커밋.
- `SaveService`: 버전 저장/복구.
- `NetworkService`: 연결, RPC, 권한 검증, 복제.

전역 Autoload는 최소화한다. 서비스는 생성/수명 주기와 의존성이 명확해야 한다.

## 5. 씬 설계

- `Main.tscn`: 진입점 및 세션 구성.
- `GameWorld.tscn`: 현재 활성 월드 셀과 서비스 노드.
- `Player.tscn`: 입력/표현/로컬 UI 연결. 서버 권한 이동 상태는 별도 컨트롤러.
- `NpcCharacter.tscn`: 모델/애니메이션/충돌/프레젠테이션.
- `ZombieCharacter.tscn`: 좀비 표현과 서버 AI 연결.
- `BuildGhost.tscn`: 클라이언트 건축 프리뷰 전용.

노드 구성은 구현에 따라 조정 가능하나 도메인 규칙을 씬 트리 깊숙이 넣지 않는다.

## 6. 데이터 구조

- 정적 정의: `Resource` 하위 클래스(.tres) 우선.
- 동적 상태: 명시적 typed model 또는 직렬화 가능한 Dictionary/DTO.
- 네트워크 DTO와 저장 DTO를 게임 도메인 객체와 분리한다.
- 저장/네트워크에서 Node 참조를 전달하지 않는다.

## 7. AI/게임 시뮬레이션 주기

프레임 기반과 시뮬레이션 기반을 구분한다.
- `_process`: UI/시각 보간 등.
- `_physics_process`: 물리/캐릭터 이동.
- Simulation Scheduler: 서버 월드 시간 기반 욕구/AI/생산 업데이트.
- Event-driven update: 긴급 사건은 예약 주기를 기다리지 않고 처리.

대량 엔티티에 개별 Timer 노드를 무분별하게 생성하지 않는다. 중앙 스케줄러/버킷 방식으로 처리한다.

## 8. 네비게이션

- `NavigationRegion3D`/`NavigationServer3D` 기반.
- 구역별 NavigationRegion을 관리한다.
- 실시간 건축 변경에 대한 전체 메시 재생성을 피한다.
- 경로 요청은 우선순위와 빈도 제한을 가진다.
- 경로 실패 시 재시도, 대체 목적지, 행동 중단을 명시한다.

## 9. 렌더링/성능

- LOD/HLOD, occlusion culling, MultiMesh 검토.
- 정적 반복 오브젝트는 배칭/멀티메시 활용.
- 동적 엔티티의 그림자/애니메이션 품질을 거리별 조절.
- 월드 스트리밍과 렌더링 visibility를 동일 개념으로 혼동하지 않는다.
- 프로파일러 측정 전 성능 향상을 단정하지 않는다.

## 10. 멀티플레이 기술

- Godot high-level multiplayer API를 초기 Godot 전용 서버/클라이언트 구간에 사용 가능.
- ENet 기반 peer 연결은 초기 후보.
- `MultiplayerSpawner`/`MultiplayerSynchronizer`는 필요한 엔티티에 선택적으로 사용한다.
- 게임플레이 권한 검증과 상태 변경은 별도 서버 서비스가 담당한다.
- Godot high-level multiplayer 프로토콜을 타 엔진/외부 서버와 직접 호환되는 일반 표준으로 가정하지 않는다.

## 11. 서버 빌드

- headless/dedicated server export를 구성한다.
- 그래픽/오디오 프레젠테이션 코드를 서버에서 실행하지 않도록 역할 분리한다.
- 서버에서 필요한 물리/내비게이션/AI/저장 기능은 유지한다.
- 클라이언트가 서버 역할을 수행할 수 있다는 전제에 의존하지 않는다.

## 12. 오류/로그

로그 레벨: DEBUG, INFO, WARNING, ERROR, FATAL. 로그는 시간, world_id, peer_id, entity_id, request_id, subsystem을 포함할 수 있어야 한다. 민감한 인증 정보는 기록하지 않는다.

## 13. 수용 기준

- 동일 코드베이스에서 클라이언트와 headless 서버 빌드를 만들 수 있다.
- 서버에서 UI/카메라/오디오 의존 없이 세계 시뮬레이션이 실행된다.
- 핵심 게임 규칙이 씬 노드 외부에서 테스트 가능하다.
- 모든 서비스의 권한과 수명 주기가 문서화되어 있다.

## 14. Phase 0~2 구현 현황 (2026-11-15)

이 절은 현재 구현을 기록한다. 위 명세와 충돌하면 위 명세가 기준이다. 임시 가정은 `docs/15` §4(PROVISIONAL)를 참조한다.

### 14.1 실행 경로

| 용도 | 명령 |
|---|---|
| 전체 로컬 검사(테스트 + 스모크) | `tools/check.sh` |
| 테스트만 | `tools/run_tests.sh [--filter=<부분문자열>]` |
| 서버/클라이언트 스모크 | `tools/smoke_test.sh` (`SMOKE_FRAMES`로 프레임 수 조정) |
| headless 전용 서버 | `tools/run_server.sh [--log-level=DEBUG] [--run-frames=N]` |
| 클라이언트(창, 디스플레이 필요) | `tools/run_client.sh` |

Godot 바이너리 경로는 환경 변수 `GODOT`로 지정한다(기본값은 개발 환경 경로). 스크립트는 4.7.2.stable이 아니면 실패한다.

게임 인자(`--` 뒤): `--server`, `--client`, `--log-level=<LEVEL>`, `--world-id=<id>`, `--run-frames=<N>`(N 프레임 후 정상 종료, 0=무한), `--run-seconds=<S>`, `--port=<N>`, `--connect=<host[:port]>`(클라이언트, `--player-key=` 필수), `--player-key=<key>`, `--save-root=user://...`(서버). 알 수 없는 인자는 오류(종료 코드 2).

예: `tools/run_server.sh --port=24680` 후 `godot --path . -- --client --connect=127.0.0.1:24680 --player-key=alice`.

### 14.2 서비스/노드 수명 주기와 권한

| 구성 요소 | 파일 | 수명 주기 | 실행 역할 |
|---|---|---|---|
| `Main` | `scenes/main/main.tscn`, `scripts/core/main.gd` | 프로세스 전체. 인자 파싱, 설정 로드, 로그 레벨 적용, 종료 코드 관리. | 공통 |
| `GameBootstrap` | `scripts/core/game_bootstrap.gd` | `Main`이 생성, `start()` 1회 호출(2회째는 `ERR_ALREADY_IN_USE`). 세션 동안 유지. | 공통 |
| `GameWorld` | `scenes/world/game_world.tscn`, `scripts/services/world/game_world.gd` | `GameBootstrap`이 `setup(world_id)` 후 트리에 추가. 현재 빈 월드(셀 0개). | 공통(서버 권한 상태는 아직 없음) |
| `ClientView` | `scenes/main/client_view.tscn`, `scripts/presentation/client_view.gd` | 클라이언트 역할에서만 지연 로드. 카메라/조명/환경/버전 라벨. | 클라이언트 전용 |
| `GameLogger`, `BuildInfo`, `LaunchConfig`, `AppSettings`, `GameplaySettings` | `scripts/core/` | 정적 유틸리티/Resource. Autoload 없음. | 공통 |
| `NetworkService` | `scripts/services/multiplayer/network_service.gd` | `GameBootstrap/NetworkService` 경로(모든 프로세스 동일, RPC 경로 일치). 서버: 항상 생성·listen. 클라이언트: `--connect`가 있을 때만. `_exit_tree`에서 서버는 저장 후 종료. | 서버: 검증/복제, 클라이언트: 의도 전송/미러 |
| `ServerWorld` | `scripts/services/world/server_world.gd` | 서버 시작 시 `WorldPersistence.load_or_create`가 생성/복구. 세션 동안 유지. 노드 없음. | 서버 전용(권한 상태: ID, 레지스트리, 인벤토리, 플레이어) |
| `InventoryService`, `EntityRegistry`, `EntityIdGenerator` | `scripts/domain/inventory/`, `scripts/domain/entity/` | `ServerWorld`가 소유. | 서버 전용 |
| `WorldPersistence`, `SaveService`, `SaveMigrator` | `scripts/services/save/` | 서버 부트스트랩이 생성해 `NetworkService`에 주입. | 서버 전용 |
| `ClientWorldState` | `scripts/services/multiplayer/client_world_state.gd` | 클라이언트 `NetworkService`가 소유. 서버가 보낸 상태의 미러(권한 없음). | 클라이언트 |

### 14.4 네트워크 메시지 (Phase 1)

| 방향 | RPC | 채널/모드 | 검증(서버) |
|---|---|---|---|
| C→S | `_rpc_request_join(protocol, game_version, player_key)` | 0 reliable | 타입, 프로토콜 일치, 키 형식/길이, 인원, 중복 키, 핸드셰이크 시간 |
| S→C | `_rpc_join_accepted(player_id, snapshot)` / `_rpc_join_rejected(reason)` | 0 reliable | — (클라이언트는 서버 발신만 수용) |
| S→C | `_rpc_player_joined` / `_rpc_player_left` | 0 reliable | — |
| C→S | `_rpc_move_intent(sequence, direction: Vector2, yaw)` | 1 unreliable_ordered | 타입, 유한값, \|direction\| ≤ 1, \|yaw\| ≤ 2π, 순번 증가, 빈도 제한, 접속 상태 |
| S→C | `_rpc_position_snapshot(tick, rows)` | 1 unreliable_ordered | — (오래된 tick 폐기) |
| C→S | `_rpc_request_pickup(request_id, item_instance_id)` | 0 reliable | 타입, ID 길이, 빈도 제한, 서버 위치 기준 거리, 아이템 위치 상태, 슬롯 |
| S→C | `_rpc_pickup_result`, `_rpc_inventory_item`(소유자), `_rpc_world_item_removed`(전체) | 0 reliable | — |

초기 상태는 `_rpc_join_accepted` 스냅샷(접속 중 플레이어, 월드 아이템, 본인 인벤토리)으로 전달하고, 이후 변경은 같은 reliable 채널로 보내 순서를 보장한다. 클라이언트는 위치/수량/결과를 보내지 않는다.

### 14.3 테스트

- `tests/run_tests.gd`: `tests/{unit,integration,scenarios}/**/*_test.gd`의 `test_*` 메서드를 실행. 단언이 없는 테스트는 실패 처리.
- 네트워크 테스트: `tests/framework/net_test_cluster.gd`가 한 프로세스 안에서 서버 1 + 클라이언트 N을 각자 `SceneMultiplayer` 서브트리로 띄워 실제 ENet(localhost)으로 통신한다. `tools/smoke_test.sh`는 별도로 서버 1 + 클라이언트 2 **프로세스** 접속을 검사한다.
- Phase 1 수용 시나리오: `tests/scenarios/phase1_acceptance_test.gd`.
- Phase 2 수용 시나리오(P2-Z): `tests/scenarios/phase2_acceptance_test.gd`. 서버 1 + 클라이언트 2(실제 ENet)가 기본 조립 그대로(이동·공격 의도 RPC, 좀비 AI, 발소리, 생존 규칙, NetModule 3개) 같은 좀비와 교전한다. 서버 쪽 직접 호출은 좀비 배치에만 쓴다. 수용 항목과 단언의 대응은 docs/12 §6, 조정한 설정값과 검증하지 못한 항목은 docs/15 §6.13.
- GDScript 런타임 오류는 함수만 중단되고 예외가 없으므로, `tools/run_tests.sh`가 출력에서 `SCRIPT ERROR`/`ERROR:`/`[ERROR]`/`[FATAL]`을 발견하면 실패 처리한다.

### 14.5 Phase 2 확장 지점(P2-0)

Phase 2 기능은 아래 seam으로만 끼워 넣는다. `network_service.gd`는 P2-0 이후 기능 작업에서 수정하지 않는다(동결). `server_world.gd`는 Phase 2 동안 B묶음(생존)만 수정한다.

| 구성 요소 | 파일 | 계약 |
|---|---|---|
| `WorldClock` / `WorldClockSettings` | `scripts/core/world_clock.gd`, `world_clock_settings.gd`, `data/tuning/world_clock_settings.tres` | 서버 권한 시계. 달력 시각 `world_time_sec`(실제 초 × `time_scale`, 기본 24)와 행동 시각 `action_time_sec`(실제 초)를 함께 진행한다(§14.16). `step(real_delta, any_online) -> world_delta`, 같은 틱의 증분은 `last_world_delta`/`last_action_delta`. 접속자 0명이면 둘 다 일시정지(설정). world_state `world_time_sec`·`action_time_sec`로 저장 |
| `BucketScheduler` | `scripts/core/bucket_scheduler.gd` | `new(period_sec, bucket_count)`, `add/remove/has/size/bucket_of`, `advance(delta) -> PackedStringArray`. 등록 순서 라운드로빈(결정론), 주기당 각 id 정확히 1회, 한 호출에서 같은 id 중복 없음 |
| `ServerSystem` | `scripts/services/world/server_system.gd` | `get_system_id()`(필수, snake_case), `seed_new_world(world)`, `step(world, action_delta, world_delta)`(매 서버 physics tick. `action_delta` = 실제 초, `world_delta` = 달력 초 = `action_delta` × 배율. 일시정지 중에는 둘 다 0. P2-T1에서 두 번째 매개변수의 뜻을 `real_delta`에서 바꿨다, §14.16), `on_player_online/offline(world, player_id)`, `player_movement_multiplier(player_id)`(기본 1.0, 서버 이동 속도 배율: 모든 시스템 값의 곱을 0~1로 제한), `on_registered(world)`(등록될 때 한 번. 월드를 보관해야 하는 시스템은 약한 참조만, P2-T4), `player_action_block_reason(player_id)`(기본 `""`. 플레이어가 아이템을 줍거나 내려놓지 못하게 하는 사유 코드, 예: `player_dead`. P2-T4, §14.19), `to_world_document()`/`restore_world_document(doc)`, `to_player_fragment(player_id)`/`restore_player_fragment(player_id, doc)`. 문서는 JSON-safe + `schema_version` |
| `ServerWorld` seam | `scripts/services/world/server_world.gd` | `register_system(system) -> Error`, `get_system(id)`, `system_ids()`, `clock`, `step_systems(real_delta) -> world_delta`(시계를 진행하고 각 시스템에 두 증분을 넘긴다). 저장: world_state 스키마 v3(`world_time_sec`, `action_time_sec`), world_state `systems.{id}`, players/<id>.json 스키마 v3(`character_generation`, P2-T4)과 `systems.{id}`. 저장에 없는 시스템은 기본값 유지, 등록되지 않은 시스템 데이터는 경고 후 무시. P2-T4에서 `start_new_character(player_id)`(예전 `respawn_player_at_spawn`을 대체), `player_action_block_reason(player_id)`가 추가됐다(§14.19) |
| `NetModule` | `scripts/services/multiplayer/net_module.gd` | `NetworkService`의 자식 노드(모든 peer에서 같은 `name`). 훅: `on_server_started(world)`, `on_player_joined/left(peer_id, player_id)`, `server_physics(delta)`, `build_join_fragment(player_id)`(서버), `apply_join_fragment(fragment)`(클라이언트). 자체 `@rpc` 메서드 사용 |
| `NetworkService` 공개 헬퍼 | `scripts/services/multiplayer/network_service.gd` | `register_module(module)`(시작 전만), `get_module(name)`, `is_server()`, `is_client()`, `is_from_server()`, `sender_player_id()`, `joined_peers()`, `peer_of_player(id)`, `player_of_peer(peer)`, `can_send_to(peer)`, `reject_intent(peer, intent, reason, player_id)`, `count_rejection(reason)`, `rejected_intent_count(reason)`, `persist(reason)`, `get_world()`, `get_settings()` |
| `ServerComposition` / `CompositionConfig` | `scripts/core/server_composition.gd`, `composition_config.gd` | 시스템/모듈 조립의 유일한 장소. `create_world(world_id, config)`, `install_net_modules(service, config)`. `WorldPersistence`, `GameBootstrap`, `NetTestCluster`가 모두 사용 |
| 저장 마이그레이션 | `scripts/services/save/save_migrations.gd` | world_state v1→v2(`world_time_sec`, `systems` 추가), v2→v3(`action_time_sec` 추가, 값은 `world_time_sec`. P2-T1), player v1→v2(`systems` 추가), player v2→v3(`character_generation` 추가, 값은 1. P2-T4). `SaveService` 기본 마이그레이터 |

채널: 0 reliable ordered, 1 unreliable ordered(플레이어 이동), 2 unreliable ordered(AI 엔티티 스냅샷, A묶음 예약). `PROTOCOL_VERSION` = 5(P2-0에서 2, N1 묶음 ZombieNet·SurvivalNet·CombatNet 병합 때 3, P2-T2 InventoryNet에서 4(§14.17), P2-T3 소비 의도에서 5(§14.18)).

### 14.6 생존 계약(B1, system id `survival`)

`scripts/domain/survival/`: `BodyPart`(10부위, 저장 이름), `Wound`(bruise/laceration/fracture/burn/bite/scratch, severity 0~1), `DamageInput`(서버가 만든 피해: source_id, body_part, wound_type, amount), `InfectionState`(단계 none~zombified, 노출 bite/scratch/blood), `PlayerVitals`(players/<id>.json `systems.survival`), `SurvivalSettings`(`data/tuning/survival_settings.tres`), `SurvivalService`(ServerSystem).

다른 시스템은 `world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService`로 얻어 아래만 호출한다(반환된 PlayerVitals는 읽기 전용): `is_alive`, `try_spend_stamina`, `handling_multiplier`, `movement_speed_multiplier`, `apply_damage(player_id, DamageInput) -> ActionResult`, `stop_bleeding(player_id, wound_id) -> ActionResult`, `apply_infection_exposure(player_id, InfectionState.Exposure, source_id) -> ActionResult`, `apply_infection_treatment(player_id, source_id) -> ActionResult`, `infection_stage(player_id) -> InfectionState.Stage`, `has_player`, `get_vitals`. 이벤트 형식과 실패 사유 코드는 `survival_service.gd` 상단 주석이 기준이다. B2에서 `need_category(player_id, NeedKind.Kind)`, `worst_need_category(player_id)`가 추가됐다(`NeedKind`: 허기/갈증/피로와 양호/주의/위험 범주).

B3에서 `Wound.is_bleeding`과 `PlayerVitals.died_at_world_time`을 저장 상태로 추가하고 생존 fragment 스키마를 v2로 올렸다(v1은 새 필드 기본값으로 읽음). `step`은 접속 중인 플레이어에게만 월드 시간을 적용한다. 생존 중에는 욕구 증가, 출혈 피해, 허기/갈증 최대치 피해, 조건부 체력·상처 회복을 처리하고, 사망 중에는 욕구/피해/회복을 멈춘 채 리스폰 시각만 판정한다. 모든 욕구가 `GOOD`이고 출혈이 없을 때만 체력과 상처 severity가 회복되며 severity 0 상처는 제거된다. 체력 0은 사망 시각을 남기고 `player_died`를 로그에 기록하며(`apply_damage` 결과는 B1 계약대로 `player_wounded` + `died: true`) 설정 지연 뒤 `ServerWorld.respawn_player_at_spawn`으로 설정 스폰 위치를 복원하면서 이전 이동 입력을 제거한다. 인벤토리/RNG는 유지하고 vitals·욕구·상처·감염은 설정값으로 초기화한다. 연속 구간을 욕구 임계·사망·리스폰 경계에서 적분하므로 틱 크기와 무관하다(허용 오차 1e-3). B3 임시 수치는 docs/15 P2-13~P2-17에 기록한다.

B4에서 `InfectionState.stage_elapsed_world_sec`를 추가하고 생존 fragment 스키마를 v3으로 올렸다(v1/v2는 경과 시간 0으로 읽음). 서버는 접속 중이고 생존한 플레이어의 활성 월드 시간만 누적해 `LATENT → EARLY → PROGRESSING → SEVERE → TERMINAL → ZOMBIFIED`를 진행한다. 각 단계 시간과 감염 경로별 시간 배율은 `SurvivalSettings`에서 읽으며 감염 단계 경계를 B3의 구간 적분 경계에 포함한다. `ZOMBIFIED` 진입 즉시 원인 `infection`으로 사망시키고 플레이어 좀비는 만들지 않으며, 기존 리스폰이 감염을 해제한다. 단계 변화는 `player_infection_stage_changed` 로그(`player_id`, `from`, `to`, `world_time`)로 남긴다.

단계별 스태미나 회복 배율은 기존 욕구 배율과 곱하고, 단계별 체력 감소율은 출혈·굶주림·탈수 피해와 합산한다. 양수인 감염 체력 감소가 적용되는 동안에는 자연 회복을 허용하지 않는다. 치료 seam `apply_infection_treatment(player_id, source_id)`는 설정된 최대 단계 이하에서 감염을 해제하고 `player_infection_cured`를 반환·기록하며, 아이템·품질·의료 능력 판정은 후속 티켓 소유다. 읽기 전용 `infection_stage(player_id)`는 현재 단계를 반환한다. 임시 수치는 docs/15 P2-7/P2-8/P2-18/P2-19에 기록한다. 감염 복제는 §14.14(P2-N1c), 섭취는 §14.18(P2-T3: `reduce_needs`, `check_reduce_needs`)에서 추가됐다. 수면은 아직 없다.

P2-T1부터 이 절의 "월드 시간"은 달력 시간이고, 스태미나 회복·리스폰 대기·피해 이벤트 묶는 간격만 행동 시간(실제 초)이다. 설정 이름은 `stamina_regen_per_sec`, `respawn_delay_sec`, `survival_damage_event_interval_sec`로 바뀌었고 생존 fragment 스키마 v4가 `died_at_action_time`을 추가했다. 구간 적분이 두 축을 함께 다루는 방식은 §14.16.

P2-T4부터 위 B3·B4의 "리스폰"은 **영구 사망 뒤 새 캐릭터 시작**이다(§14.19가 우선): 사망 순간 소지품이 전부 죽은 자리에 놓이고, 대기 시간 뒤 스폰 지점에서 빈 인벤토리·다음 세대 번호로 시작한다. "인벤토리 유지"와 `ServerWorld.respawn_player_at_spawn`은 더 이상 없다(`start_new_character`). 대기 시간·초기 욕구 설정(`respawn_delay_sec`, `respawn_hunger` 등)과 이벤트 이름 `player_respawned`는 그대로 쓴다. 죽은 캐릭터는 아이템을 줍거나 내려놓을 수 없다(`player_action_block_reason`).

테스트 더블: `tests/framework/test_counter_system.gd`, `tests/framework/test_echo_module.gd`(배포 코드 아님). `NetTestCluster.extra_module_factories`로 테스트 전용 모듈을 추가할 수 있다.

### 14.7 P1-4 클라이언트 카메라/입력

- `ClientView`는 클라이언트 역할에서만 생성되며 `GameBootstrap.get_network()`의 `ClientWorldState`를 구독한다. 서버 headless 경로는 해당 신/스크립트/설정을 로드하지 않는다.
- `CameraOrbitMath`, `InputIntentMath`, `MoveIntentSender`는 노드 없는 `RefCounted`로 카메라 각도/위치, 카메라 기준 월드 XZ 방향, 입력 데드존/정규화, 전송 주기를 계산한다.
- 이동 RPC는 입력 변경 시 즉시, 유지 시 0.2초 주기, 정지 시 `Vector2.ZERO` 1회만 전송한다. 클라이언트가 전송하는 값은 월드 XZ 방향과 yaw뿐이며 위치·속도·시간은 전송하지 않는다.
- 입력 액션은 `ClientInputActions`가 코드로 등록하며, 기존 액션은 덮어쓰거나 바인딩을 중복 추가하지 않는다. 키·데드존·전송 기준은 `data/tuning/camera_settings.tres`에 있다.
- 플레이어는 `ClientWorldState.players`의 서버 위치에 캡슐로 표시하고 로컬/원격 색을 구분한다. 줍기는 로컬 위치에서 가장 가까운 미러 아이템 ID만 `request_pickup`으로 보내고 거리/획득 판정은 서버에 남겨 둔다.

### 14.8 소음 계약(P2-A1, system id `noise`)

`scripts/domain/noise/`: `NoiseEvent`(docs/02 §5.3 필드: `source_id`, `position`, `loudness`, `frequency_profile`, `event_time`, `occlusion_context` + 실행 중 전용 `noise_id`/`sequence`), `NoisePerception`(조회 결과 한 줄: `event`, `intensity`, `distance`), `NoiseOcclusion`(차폐 인터페이스, 기본은 차폐 없음), `NoiseSettings`(`data/tuning/noise_settings.tres`), `NoiseService`(ServerSystem). 네트워크 코드는 없다. 생존 다음, 좀비 앞에 등록한다.

다른 시스템은 `world.get_system(NoiseService.SYSTEM_ID) as NoiseService`로 얻어 아래를 호출한다.

| API | 계약 |
|---|---|
| `emit(source_id, position, loudness, frequency_profile, occlusion_context = {}) -> ActionResult` | 성공 이벤트 `{event_type: "noise_emitted", noise_id, source_id, position: [x, y, z], loudness, frequency_profile, event_time}`. 실패 사유: `bad_noise_source`(빈 ID), `bad_noise_position`(NaN/무한), `noise_out_of_world`(월드 경계 밖), `bad_noise_loudness`(NaN/무한/0 이하), `noise_loudness_too_high`(상한 초과), `bad_noise_profile`, `bad_noise_occlusion_context`(JSON-safe 아님). 실패하면 상태가 바뀌지 않는다 |
| `query_audible(position, hearing_multiplier, since_time) -> Array[NoisePerception]` | 지금 그 위치에서 들리는 소음을 센 순서(같으면 발생 순서)로 돌려준다. `event_time > since_time`인 것만 포함(둘 다 행동 시각, §14.16)(`NoiseService.SINCE_ALWAYS` = 전부). 잘못된 입력(NaN, 경계 밖, 배율 0 이하)은 빈 목록. 반환된 `event`는 읽기 전용 |
| `max_audible_distance(loudness, hearing_multiplier) -> float` | 방금 난 소리가 들리는 최대 거리(음수 = 들리지 않음) |
| `purge_expired() -> int`, `active_count()`, `get_event(noise_id)`, `set_occlusion(provider)` | 만료 정리(평소에는 `step`이 호출), 진단, 차폐 구현 교체 |

- 세기 모델과 수치는 docs/15 P2-20. 시간 감쇠·만료는 행동 시간(실제 초, §14.16) 기준이라 달력 배율과 무관하고, 월드 시계가 멈춘 동안(접속자 0명)에는 줄지도 사라지지도 않는다. 만료된 소음은 정리 전이라도 조회에 나오지 않는다.
- 공간 조회: 소음은 XZ 평면 해시 격자(기본 16m)의 한 칸에 들어간다. 조회는 듣는 쪽 칸에서 "지금 가장 큰 소음이 들릴 수 있는 거리"만큼의 이웃 칸만 훑고, 그 후보 목록을 (칸, 범위)별로 캐시한다. 같은 칸에 있는 다른 청취자는 소음이 추가·삭제되기 전까지 캐시를 다시 쓴다(무리 지은 좀비 N마리가 칸 훑기 1번을 공유, docs/02 §6.3). 점유 칸 수가 이웃 칸 수보다 적으면 점유 칸만 훑는다. `query_audible_brute_force`는 격자 없이 전부 검사하는 기준 구현이며 테스트가 두 결과가 같은지 비교한다.
- 저장하지 않는다(`to_world_document()`는 빈 문서). 이유와 ID 형식은 docs/15 P2-23. 다른 시스템이 저장 문서에 `noise_id`를 넣으면 안 되고, 필요하면 위치·시간을 복사해 저장한다.
- 소음을 내는 호출자: 근접 공격(`CombatService`, §14.10)이 휘두를 때마다, 플레이어 이동(`PlayerNoiseService`, §14.11)이 보폭마다 `emit`을 호출한다.

### 14.9 좀비 계약(P2-A2, system id `zombie`)

`scripts/domain/zombie/`: `ZombieState`(좀비 한 마리의 저장 가능한 상태), `ZombiePerception`(노드 없는 시야·방향 규칙), `ZombieSettings`(`data/tuning/zombie_settings.tres`), `ZombieService`(ServerSystem). 네트워크 코드는 없다. 등록 순서는 `survival` → `noise` → `zombie`이며 좀비는 앞의 둘을 `world.get_system`으로 얻어 쓴다. 임시 가정은 docs/15 P2-24~P2-32.

상태(`ZombieState.STATE_NAMES`, docs/02 §6.1): `idle`(대기/배회), `investigate`(소리 조사·피격 방향 확인), `chase`(시각 추적/추격), `attack`(사거리 안), `search`(대상 상실 후 수색), `dormant`(필드만), `dead`(시체, 일정 시간 뒤 제거). 흐름: idle → (소음) investigate → (도착/시간 초과) search → (시간 초과) idle, 어느 상태든 대상이 보이면 chase → 사거리 안이면 attack, 대상을 놓치면 search.

주기: 이동 적분은 살아 있는 모든 좀비에 대해 매 서버 틱, AI 판단(감지·상태 전환·공격)은 좀비마다 `ai_period_sec`에 한 번 `BucketScheduler`로 분산하고 한 틱에 `max_ai_updates_per_tick`개까지만 처리한다(나머지는 대기열에서 다음 틱으로). 피격된 좀비는 대기열 맨 앞에 들어간다. 모든 시간·속도는 행동 시간(실제 초, §14.16)이라 달력 배율과 무관하고, 시계가 멈추면 아무 일도 일어나지 않는다. 행동 시각은 틱 길이를 더해 만든 값이므로 공격 가능 시각(선딜·쿨다운)은 `ZombieService.TIME_EPSILON_SEC`(1e-6초)만큼의 허용 오차로 비교한다: 쿨다운이 판단 주기의 정수배면 실제 공격 간격이 쿨다운과 같다(P2-Z에서 고친 결함, docs/15 §6.13). yaw는 플레이어와 같은 규약(0 = −Z, 전방 = (−sin, 0, −cos), `Node3D.rotation.y`)이다.

| API | 계약 |
|---|---|
| `spawn_zombie(world, position, yaw = 0.0) -> ActionResult` | `EntityIdGenerator`로 `zombie_<순번>` 발급, `EntityRegistry`에 kind `zombie`로 등록. 위치는 월드 경계로 clamp. 실패: `bad_zombie_position`(NaN/무한), `zombie_limit`(상한), `zombie_id_failed` |
| `apply_damage_to_zombie(zombie_id, amount, source_id) -> ActionResult` | 근접 전투(C1)가 호출. 성공 이벤트 `{event_type: "zombie_damaged", zombie_id, source_id, damage, health_after, died, world_time}`. 체력 0이면 `dead`. 살아 있으면 다음 판단에서 `source_id`(접속 중인 생존 플레이어일 때)를 향해 돌아보고, 보이면 추격, 안 보이면 그 위치를 조사한다. 실패: `unknown_zombie`, `zombie_dead`, `bad_damage_amount`(NaN/무한/0 이하), `bad_damage_source`(빈 ID) |
| `snapshot_rows() -> Array[Dictionary]` | 네트워크용 읽기 전용. 스폰 순서로 `{id: String, position: Vector3, yaw: float, state: String, health_fraction: float(0~1)}`. 시체는 제거 전까지 `state: "dead"`로 포함 |
| `drain_events() -> Array[Dictionary]` | 네트워크용 읽기 전용. 지난 호출 이후 쌓인 이벤트를 오래된 순으로 돌려주고 비운다(최대 `max_pending_events`개 보관) |
| `has_zombie`, `get_zombie(id) -> ZombieState`(읽기 전용), `zombie_ids()`, `zombie_count()`, `living_count()` | 조회 |

이벤트(모두 `event_type`, `zombie_id`, `world_time` 포함, 위치는 `[x, y, z]`, JSON-safe. `world_time`은 달력 시각이다, §14.16):

| event_type | 추가 필드 |
|---|---|
| `zombie_spawned` | `position`, `yaw` |
| `zombie_detected` | `sense`(`sight`/`sound`/`damage`), `target_id`(시각·피격은 플레이어 ID, 소리는 소음의 `source_id`), `position` |
| `zombie_state_changed` | `from`, `to`, `cause`(`sight`, `in_range`, `attacked`, `noise`, `target_lost`, `investigated`, `search_timeout`), `target_id` |
| `zombie_attacked` | `target_id`, `wound_type`(`bite`/`scratch`), `body_part`, `damage`, `target_health_after`, `target_died`, `infection`(`player_infected`/`infection_exposure_resisted`/실패 사유) |
| `zombie_damaged` | `source_id`, `damage`, `health_after`, `died` |
| `zombie_died` | `source_id` |
| `zombie_removed` | — |

- 공격: 좀비는 플레이어 체력을 직접 바꾸지 않는다. 서버가 `DamageInput`(source = 좀비 ID, 부위·상처 종류·피해량은 설정과 좀비 RNG)을 만들어 `SurvivalService.apply_damage`에 넘기고, 이어서 `apply_infection_exposure`(물림 = BITE, 긁힘 = SCRATCH)를 호출한다. 대상은 접속 중이고 살아 있는 플레이어뿐이다.
- 결정론: 좀비마다 RNG(seed = hash("<rng_seed>:<zombie_id>"))를 갖고 배회·수색 지점·공격 굴림에 쓴다. 같은 seed와 같은 입력이면 좀비 문서·이벤트·플레이어 피해가 같다(테스트로 확인).
- 저장: world_state.json `systems.zombie` = `{schema_version: 1, rng_seed, rng_state, zombies: [ZombieState.to_dict()]}`(64비트 RNG 값은 문자열). 불러올 때 ID 형식·중복·tombstone·수치 범위를 검사하고 하나라도 틀리면 월드 복구를 실패시킨다. `seed_new_world`는 새 월드에만 개발용 좀비를 놓는다. 저장하지 않는 것은 docs/15 P2-31.
- 테스트: `tests/unit/zombie_perception_test.gd`, `tests/unit/zombie_service_test.gd`(고정 seed 시나리오, 시야/소리 구분, 수색 복귀, 사망·오프라인 대상 제외, 저장→재생성→로드, 결정론, 2초 틱으로 3시간 soak, 잘못된 입력).

### 14.10 근접 전투 계약(P2-C1, system id `combat`)

`scripts/domain/combat/`: `MeleeWeaponDefinition`(무기 한 종류의 정적 정의 Resource), `MeleeWeaponCatalog`(무기 ID·아이템 ID로 찾는 읽기 전용 목록, `resources/definitions/melee_weapons/*.tres`를 읽음), `MeleeHitRules`(노드 없는 판정 규칙: 호 안 여부, 대상 선택, 피해 계산), `CombatSettings`(`data/tuning/combat_settings.tres`), `CombatService`(ServerSystem). 네트워크 코드는 없다. 등록 순서는 `survival` → `noise` → `player_noise`(§14.11) → `zombie` → `combat`이며 전투는 `survival`·`noise`·`zombie`를 `world.get_system`으로 얻어 쓴다. `CompositionConfig`에 `combat`, `melee_weapons` 필드가 추가됐고 `validate()`가 무기 목록을 아이템 목록·소음 설정과 대조한다. 임시 가정은 docs/15 P2-40~P2-47.

클라이언트가 보낼 수 있는 것은 "누가(`player_id`, 네트워크 계층이 peer에서 구함) 어느 방향으로(`aim_yaw`) 휘둘렀다"뿐이다. 위치·대상·무기·피해·명중 여부·사망은 모두 서버 상태에서 정한다(docs/02 §5.2).

| API | 계약 |
|---|---|
| `request_melee_attack(world, player_id, aim_yaw) -> ActionResult` | N1의 RPC 핸들러가 부르는 진입점. 아래 순서로 검증하고 하나라도 실패하면 아무것도 바뀌지 않는다(스태미나·쿨다운·RNG·소음·이벤트 모두). 성공하면 `melee_attack` 이벤트를 돌려주고 같은 이벤트를 큐에 넣는다 |
| `weapon_for(world, player_id) -> MeleeWeaponDefinition` | 지금 공격하면 쓰일 무기(없는 플레이어는 null). 표시용 조회 |
| `cooldown_remaining(player_id) -> float` | 다음 공격까지 남은 실제 초(행동 시간, 0 = 가능) |
| `drain_events() -> Array[Dictionary]` | 네트워크용 읽기 전용. 지난 호출 이후의 이벤트를 오래된 순으로 돌려주고 비운다. 최대 `max_pending_events`(256)개 보관, 넘으면 오래된 것부터 버리고 `dropped_event_count`를 올린다(좀비 이벤트 큐와 같은 방식) |

검증 순서와 실패 사유 코드(먼저 걸린 것 하나만 반환):

| 사유 | 조건 |
|---|---|
| `combat_unavailable` | `world`가 null이거나 `survival`/`zombie` 시스템이 등록되지 않음(조립 오류) |
| `bad_aim_yaw` | NaN·무한, 또는 `\|aim_yaw\|` > `max_abs_aim_yaw`(기본 2π, 이동 의도의 yaw와 같은 범위) |
| `unknown_player` | 이 월드의 플레이어가 아님(빈 ID, 좀비 ID 포함) |
| `not_online` | 접속 중이 아님 |
| `player_dead` | 사망 상태 |
| `no_weapon` | 쓸 무기 정의가 없음(맨손 정의 누락 = 설정 오류, 시작 시 `validate()`가 먼저 잡는다) |
| `attack_on_cooldown` | 직전 공격의 쿨다운(행동 시간, 실제 초)이 남음 |
| `not_enough_stamina` | 스태미나가 무기 비용보다 적음(`SurvivalService.try_spend_stamina`가 마지막 검사이자 차감) |

승인된 공격의 처리:

- 무기: `CombatSettings.inventory_weapon_rule`에 따라 플레이어 인벤토리의 아이템 중 `MeleeWeaponDefinition.item_definition_id`와 일치하는 것을 찾는다. `HIGHEST_DAMAGE`(기본, 기본 피해가 가장 큰 무기·같으면 무기 ID가 작은 것), `FIRST_SLOT`(슬롯 번호가 가장 작은 무기 아이템), `UNARMED_ONLY`(항상 맨손). 해당 아이템이 없으면 `unarmed_weapon_id`(맨손)이다. 장비 슬롯은 아직 없다.
- 대상: 서버가 가진 플레이어 위치와 `aim_yaw`(플레이어에 저장된 `yaw`는 쓰지도 바꾸지도 않는다)를 기준으로, 무기 사거리(`range_m`) 안이고 조준 방향을 중심으로 한 호(`arc_angle_deg`, 전체 각) 안에 있는 **살아 있는 좀비 중 가장 가까운 1마리**. 거리가 같으면 좀비 ID가 작은 쪽. XZ 평면에서만 계산하며 yaw 규약은 플레이어·좀비와 같다(0 = −Z). 플레이어는 대상이 되지 않는다(PvP 비활성, docs/00).
- 피해: `무기 base_damage × SurvivalService.handling_multiplier(player) × uniform(damage_roll_min, damage_roll_max)`. 난수는 전투 RNG(seed = `CombatSettings.rng_seed`, 상태 저장)이고 **대상이 있는 공격에서만** 한 번 뽑는다. 적용은 `ZombieService.apply_damage_to_zombie(target, damage, player_id)`이므로 맞은 좀비는 좀비 계약(§14.9)대로 공격자를 인지한다.
- 빗나가도(대상 없음) 스태미나를 쓰고 쿨다운이 시작되며 소음이 난다. 소음은 `NoiseService.emit(player_id, 플레이어 위치, 무기 noise_loudness, 무기 noise_frequency_profile)`이고 `noise_loudness`가 0이면 내지 않는다.
- 쿨다운은 플레이어별 "다음 공격 가능 행동 시각"으로 기억한다(§14.16). 접속을 끊었다 다시 들어와도 초기화되지 않는다.

이벤트 `melee_attack`(`ActionResult.event`와 `drain_events()`가 같은 형식, JSON-safe):

| 필드 | 내용 |
|---|---|
| `event_type` | `"melee_attack"` |
| `attacker_id` | 공격한 플레이어 ID |
| `weapon_id` | 쓰인 무기 정의 ID(`unarmed` 등) |
| `aim_yaw` | 조준 방향, [−π, π]로 정규화한 값 |
| `position` | 공격 순간 공격자의 서버 위치 `[x, y, z]` |
| `hit` | 대상에게 피해가 들어갔는지 |
| `target_id` | 맞은 좀비 ID, 빗나가면 `""` |
| `damage` | 들어간 피해, 빗나가면 0 |
| `target_health_after` | 맞은 뒤 좀비 체력, 빗나가면 0 |
| `target_died` | 이 공격으로 좀비가 죽었는지 |
| `world_time` | 월드(달력) 시각 |

- 저장: world_state.json `systems.combat` = `{schema_version: 1, rng_seed, rng_state}`(64비트 값은 문자열). 형식이 틀리면 월드 복구를 실패시키고 아무것도 바꾸지 않는다. 쿨다운과 아직 전달하지 않은 이벤트는 저장하지 않는다(이유는 docs/15 P2-44).
- 결정론: 같은 seed와 같은 요청 순서면 이벤트가 같고, 저장→재생성→로드 뒤에도 피해 굴림이 이어진다(테스트로 확인). 전투는 `step`에서 하는 일이 없어 좀비와 달리 저장을 사이에 두어도 결과가 달라지지 않는다.
- 무기 정의 데이터: `unarmed`(맨손), `dev_melee_pipe`(둔기, 아이템 `dev_melee_pipe`가 인벤토리에 있을 때). 개발용 파이프 아이템은 정의만 있고 월드에는 놓지 않았다(docs/15 P2-47).
- 테스트: `tests/unit/combat_rules_test.gd`(순수 규칙·정의·설정 검증), `tests/unit/combat_service_test.gd`(사거리·호, 가장 가까운 대상, 쿨다운, 스태미나, 사망·오프라인·없는 플레이어, 잘못된 aim_yaw, 팔 부상 피해 감소, 연속 공격으로 좀비 사망, 인벤토리 무기 규칙, 공격 소음에 다른 좀비가 조사 상태로, 이벤트 큐 상한, 같은 seed 재현, 저장→로드 후 RNG 이어짐, 손상 문서 거부).

### 14.11 플레이어 이동 소음 계약(P2-A3, system id `player_noise`)

`scripts/domain/player_noise/`: `FootstepRules`(노드 없는 규칙: 걷는 중인지, 순간이동인지, 한 틱의 이동에서 발소리가 나는 지점), `PlayerNoiseSettings`(`data/tuning/player_noise_settings.tres`), `PlayerNoiseService`(ServerSystem). 소음 시스템(`scripts/domain/noise/`)과 소유를 나누려고 별도 디렉터리에 둔다. 네트워크 코드도, 클라이언트 입력도 없다: 유일한 근거는 서버가 플레이어를 얼마나 움직였는지다. `noise` 다음, `zombie` 앞에 등록해 발소리가 난 틱에 좀비가 들을 수 있게 한다. `CompositionConfig`에 `player_noise` 필드가 추가됐고 `validate()`가 세기·주파수 이름을 소음 설정과 대조한다. 임시 가정은 docs/15 P2-48~P2-50.

동작: 매 서버 틱(`NetworkService`가 `step_movement` 다음에 `step_systems`를 부르므로 그 틱의 이동이 반영된 뒤), 접속 중이고 살아 있는 플레이어마다 직전 틱 위치와 지금 위치의 XZ 거리를 그 플레이어의 "마지막 발소리 이후 걸은 거리"에 더한다. `stride_length_m`(2m)를 채울 때마다 `NoiseService.emit(player_id, 경로 위의 지점, footstep_loudness, footstep_frequency_profile)`을 호출한다. 한 틱에 여러 걸음이 나오면(긴 틱) 경로를 따라 나눠 놓으므로 틱 길이와 무관하게 이동 거리에 비례한다. 틱당 플레이어 한 명의 발소리는 `max_footsteps_per_tick`개까지다.

발소리가 나지 않는 경우:

| 경우 | 처리 |
|---|---|
| 정지, 또는 `min_speed_mps`(0.5m/s)보다 느린 이동 | 소음 없음, 걸은 거리에도 더하지 않는다 |
| 사망한 플레이어 | 소음 없음. 걸은 거리 기록을 지우므로 리스폰 뒤에는 새로 센다 |
| 오프라인 플레이어 | 추적하지 않는다(`on_player_offline`에서 기록 삭제). 다시 접속한 뒤 첫 틱의 위치가 기준점이 된다 |
| 월드 시계 정지(`action_delta` = 0) | 소음 없음. 정지 중에 움직인 거리는 나중에도 세지 않는다 |
| 순간이동: `teleport_speed_mps`(15m/s)보다 빠른 위치 변화(리스폰, 관리자 이동 등) | 소음 없음, 걸은 거리를 0으로 되돌린다 |
| `footstep_loudness` = 0, 또는 소음 시스템 미등록 | 전체 비활성 |

- 속도는 `action_delta`(실제 초)로 계산한다(`ServerWorld.step_movement`가 실제 초 단위로 이동을 적분하기 때문). 소음의 시각·감쇠도 소음 시스템대로 행동 시간이다(§14.8).
- 플레이어를 처음 보는 것은 `step`이다. 그래서 접속 직후부터 첫 틱까지의 위치 변화는 발소리가 되지 않는다(첫 틱의 이동 최대 한 번이 빠진다).
- 한 틱의 발소리는 플레이어 ID 순서로 낸다(결정론). 난수는 쓰지 않는다.
- 저장하지 않는다(`to_world_document()`·`to_player_fragment()` 모두 빈 문서). 상태가 "보폭 하나보다 짧은 걸은 거리"뿐이고, 재시작 뒤에는 모두 오프라인이라 어차피 0에서 시작한다(docs/15 P2-50).
- 진단: `last_footstep_count`(이번 틱), `total_footstep_count`.
- 테스트: `tests/unit/player_noise_test.gd`(순수 규칙, 이동 거리에 비례한 발소리 수와 위치, 긴 틱, 정지·저속·사망·리스폰·오프라인·순간이동·시계 정지 무소음, 소음 만료, 저장 없음, 등 뒤를 걷는 플레이어를 좀비가 소리로 조사하는 통합 시나리오와 발소리를 끈 대조 시나리오).
### 14.12 좀비 네트워크 복제(P2-N1a, NetModule `ZombieNet`)

서버의 좀비 상태와 좀비 이벤트를 접속한 모든 클라이언트가 같은 내용으로 관찰하게 한다. 서버 → 클라이언트 전용이며 이 모듈에는 클라이언트 → 서버 RPC가 없다. `network_service.gd`는 고치지 않았고 §14.5의 공개 헬퍼만 쓴다. 임시 가정은 docs/15 P2-80~P2-87.

| 구성 요소 | 파일 | 역할 |
|---|---|---|
| `ZombieNetModule` | `scripts/services/multiplayer/zombie_net_module.gd` | NetModule(노드 이름 `ZombieNet`, 모든 peer 동일). 서버: 스냅샷·이벤트 전송, join 조각. 클라이언트: 수신해 미러에 적용. `ServerComposition.install_net_modules`에서만 조립 |
| `ZombieNetProtocol` | `scripts/services/multiplayer/zombie_net_protocol.gd` | wire 형식. 서버 인코딩(보낼 필드 화이트리스트)과 클라이언트 검증을 같은 표로 처리하는 정적 함수 |
| `ClientZombieState` | `scripts/services/multiplayer/client_zombie_state.gd` | 클라이언트 미러(권한 없음, 서버로 돌려보내지 않음). `module.client_state` |
| `ZombieNetSettings` | `scripts/services/multiplayer/zombie_net_settings.gd`, `data/tuning/zombie_net_settings.tres` | 스냅샷 주기, 메시지 분할 크기, 미러 한도. `CompositionConfig.zombie_net`(서버·클라이언트 공통) |

메시지:

| 방향 | RPC / 조각 | 채널/모드 | 내용 |
|---|---|---|---|
| S→C | join 조각 `snapshot["modules"]["ZombieNet"]` = `{tick: int, event_sequence: int, rows: Array}` | 0 reliable(`_rpc_join_accepted` 안) | 지금 있는 모든 좀비(시체 포함)의 행. `event_sequence`는 이 행들에 이미 반영된 마지막 이벤트 순번. 좀비 시스템이 없는 월드는 `{}` |
| S→C | `_rpc_zombie_snapshot(tick: int, rows: Array)` | 2 unreliable_ordered | 모든 좀비의 행을 `snapshot_rate_hz`(기본 10Hz)마다 전송. `snapshot_rows_per_message`(기본 12)행씩 나눠 같은 tick으로 보낸다. 좀비가 없으면 보내지 않는다 |
| S→C | `_rpc_zombie_events(tick: int, first_sequence: int, events: Array)` | 0 reliable | 매 서버 틱 `ZombieService.drain_events()`를 비워 발생 순서대로 전송. `events[i]`의 순번은 `first_sequence + i`. `events_per_message`(기본 32)개씩 나눈다 |

- 행: `[zombie_id: String, position: Vector3, yaw: float, state: int, health_fraction: float]`. `state`는 `ZombieState.STATE_NAMES`의 번호(0 idle, 1 investigate, 2 chase, 3 attack, 4 search, 5 dormant, 6 dead), `health_fraction`은 0~1. 순서는 서버 스폰 순서.
- 이벤트: §14.9의 좀비 이벤트 Dictionary 그대로(`event_type`, `zombie_id`, `world_time` + 종류별 필드). 서버는 `ZombieNetProtocol.EVENT_FIELDS`에 적힌 필드만 복사해 보내므로 좀비 서비스에 필드가 늘어도 표에 올리기 전에는 전송되지 않는다. 정수는 실수로 바꿔 보낸다.
- 정보 공개(docs/15 P2-9, P2-85): `zombie_attacked`의 `infection`(감염 판정 결과)과 `target_health_after`(정확한 체력)는 `target_id` 플레이어에게 보내는 사본에만 들어 있다. 다른 클라이언트는 그 두 필드가 없는 같은 이벤트(대상, `wound_type`, `body_part`, `damage`, `target_died`)를 같은 순번으로 받는다.
- tick: 이 모듈의 서버 physics 틱 번호. 한 틱 안에서 이벤트를 먼저 보내고 스냅샷을 나중에 만들므로 tick T 스냅샷은 tick T 이하 이벤트를 모두 반영한다.
- 순번: 서버 시작 후 1부터 증가(저장하지 않음). join 조각을 만들 때 좀비 서비스에 남아 있던 이벤트도 먼저 비워 순번을 매기고 다음 틱에 보내며, 새로 접속한 클라이언트는 `event_sequence` 이하 순번을 건너뛴다. 그래서 join 조각과 이후 이벤트 사이에 빠지거나 두 번 적용되는 이벤트가 없다.
- 이 모듈이 `drain_events()`의 유일한 소비자다. 서버 쪽 다른 코드가 좀비 이벤트를 받아야 하면 `ZombieNetModule.server_events_drained(events: Array[Dictionary])` 시그널(서버 전용, 걸러지지 않은 원본 이벤트)을 쓴다.

클라이언트 미러 `ClientZombieState`(`(network.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule).client_state`):

| API | 계약 |
|---|---|
| `zombies: Dictionary[String, Dictionary]`, `get_zombie(id) -> Dictionary`, `has_zombie(id)`, `zombie_ids() -> PackedStringArray`, `zombie_count()` | `zombie_id → {position: Vector3, yaw: float, state: String(STATE_NAMES 이름), health_fraction: float}`. 서버 스폰 순서. 모르는 ID는 `{}`. 읽기 전용 |
| 시그널 `changed`, `zombie_added(zombie_id)`, `zombie_removed(zombie_id)`, `event_received(event)` | `changed`는 미러 값이 실제로 바뀐 메시지마다 한 번. `event_received`는 검증을 통과한 이벤트마다 서버 순서대로, 미러를 고친 뒤에 발생 |
| `recent_events() -> Array[Dictionary]`, `events_after(sequence) -> Array[Dictionary]` | 최근 이벤트(기본 256개)를 오래된 순으로. 각 이벤트에 `sequence`가 붙는다. 폴링하는 쪽은 처리한 마지막 순번을 기억했다가 `events_after`로 나머지를 받는다 |
| `last_snapshot_tick`, `last_event_sequence`, `rejected_payload_count`, `stale_snapshot_count`, `event_gap_count` | 진단값 |
| `apply_join(fragment)`, `apply_snapshot(tick, rows)`, `apply_events(tick, first_sequence, events)` → `""` 또는 사유 코드 | 모듈이 호출한다. 표시 계층은 호출하지 않는다 |

미러 규칙:

- 좀비의 생성·제거는 reliable 경로(join 조각, `zombie_spawned`, `zombie_removed`)로만 일어난다. 스냅샷은 이미 있는 좀비만 고치므로 늦게 온 스냅샷이 제거된 좀비를 되살리지 못한다.
- 위치·방향·체력 비율은 가장 새 스냅샷을 따른다(tick이 더 오래된 스냅샷은 버림, 같은 tick은 분할 메시지라 허용). `zombie_died`는 상태를 `dead`, 체력 비율을 0으로 바로 바꾼다. `zombie_damaged`는 미러를 고치지 않고 체력 비율은 다음 스냅샷에서 갱신된다.
- 상태는 `zombie_state_changed`/`zombie_died` 이벤트로 즉시, 그 밖에는 스냅샷으로 갱신된다. 채널 0과 2는 서로 순서가 보장되지 않으므로, 어떤 좀비에 마지막으로 적용한 이벤트의 tick보다 오래된 스냅샷은 그 좀비의 위치·방향만 고치고 상태·체력 비율은 되돌리지 못한다.
- 검증: 클라이언트는 서버가 보낸 RPC만 받는다(`is_from_server()`, 아니면 무시하고 경고 로그). 받은 값은 타입, 길이(ID·문자열 64자, 메시지당 행 64개·이벤트 64개, 미러 1024마리), 유한값, 범위(|yaw| ≤ 2π, 체력 비율 0~1, 상태 번호)를 검사한다. 스냅샷은 한 행이라도 틀리면 메시지 전체를, 이벤트는 틀린 이벤트만 버린다(순번은 소모). 버린 페이로드는 경고 로그와 `rejected_payload_count`에 남고 미러는 바뀌지 않는다.
- 보간·예측은 없다. 움직이는 좀비의 미러는 `속도 × (스냅샷 주기 + 전달 지연)`만큼 뒤처질 수 있다(테스트 허용 오차: 추격 속도 × 스냅샷 2주기 = 0.64m, 멈춘 좀비는 서버 값과 같음. docs/15 P2-84).

프로토콜: RPC 2개와 join 조각이 추가됐지만 N1 묶음(N1a·N1b·N1c)을 병합하면서 `BuildInfo.PROTOCOL_VERSION`을 3으로 올렸다.

테스트: `tests/integration/zombie_net_test.gd`(서버 1 + 클라이언트 1~2, 실제 localhost ENet: 추격·공격 중 미러 수렴과 이벤트 순서, 늦은 접속, 개발용 좀비 12마리 join, 비공개 필드, 사망·제거, 오래된/위조/잘못된 페이로드, RPC 채널 설정), `tests/integration/zombie_net_state_test.gd`(네트워크 없이 미러·wire 형식: join 조각, tick 폐기, 이벤트 적용, 순번, 잘못된 페이로드, 한도, 메시지 크기).

### 14.14 생존 상태 네트워크 복제(P2-N1c)

`SurvivalNetModule`(노드 이름 `SurvivalNet`)은 `ServerComposition.install_net_modules`에서 서버와 모든 클라이언트에 같은 이름으로 설치한다. `NetworkService`는 수정하지 않으며 공개 seam만 쓴다. 방향은 서버→클라이언트뿐이고 세 RPC 모두 채널 0 reliable ordered다. 클라이언트 핸들러는 먼저 `network.is_from_server()`를 확인하며, 발신·타입·범위·공개 범위가 잘못된 DTO는 상태를 바꾸지 않고 경고 로그만 남긴다.

| RPC | 수신자 | 페이로드 |
|---|---|---|
| `_rpc_survival_owner_snapshot(snapshot)` | 해당 플레이어 본인 | 아래 owner snapshot. 설정 주기마다 비교하고 변경된 경우에만 전송 |
| `_rpc_survival_status(status)` | 접속 중 클라이언트 | `{player_id: String, alive: bool}`. 새 플레이어 접속 시 기존 미러 보강 |
| `_rpc_survival_events(events)` | 이벤트 공개 범위에 따른 본인/타인 | 검증된 이벤트 Dictionary 배열. 한 서버 틱에 peer별로 묶어 전송 |

접속 조각(`snapshot.modules.SurvivalNet`)과 본인 스냅샷의 스키마 버전은 2다(P2-T4에서 `character_generation`을 추가하며 1 → 2. 이전 형식은 클라이언트가 버린다).

```text
{
  schema_version: 2,
  self: <owner snapshot>,
  players: [{player_id: String, alive: bool}, ...]  # 접속 중인 전 플레이어
}

owner snapshot = {
  schema_version: 2, player_id: String, alive: bool,
  health: float, stamina: float,
  needs: {hunger: "good|caution|danger", thirst: ..., fatigue: ...},
  wounds: [Wound.to_dict(), ...],
  infection_stage: "none|latent|early|progressing|severe|terminal|zombified",
  character_generation: int >= 1   # 그 플레이어의 몇 번째 캐릭터인지(§14.19). 본인만 받는다
}
```

공개 범위는 docs/15 P2-9를 따른다. `scope: "owner"` 이벤트는 대상 본인에게만 가며 체력 변화, 상처 상세, 지혈, 생존 피해, 욕구 범주, 감염/저항/단계 변화/치료를 포함할 수 있다. `scope: "public"`은 타인에게만 가며 아래 세 종류뿐이다.

| 공개 이벤트 | 필드(`scope`, `event_type`, `player_id` 공통) |
|---|---|
| `player_wounded` | `body_part`, `wound_type`, `died`, `world_time` |
| `player_died` | `world_time`(원인 제외: 감염 사망 노출 방지) |
| `player_respawned` | `position: [x,y,z]`, `world_time` |

타인용 DTO에는 체력·피해 수치, wound 상세/심각도, 욕구, 감염 여부·단계·노출·원인을 넣지 않는다. `SurvivalService.drain_events()`는 JSON-safe 이벤트를 발생 순서로 반환하고 비우며, 설정 상한을 넘으면 좀비/전투 큐와 같이 가장 오래된 것부터 버리고 `dropped_event_count`를 올린다. `apply_damage`의 기존 `player_wounded` ActionResult 계약은 유지한다.

`ClientSurvivalState`는 권한 없는 순수 미러다. 공개 API는 `health()`, `stamina()`, `need_category(kind)`, `wounds()`, `infection_stage()`, `character_generation()`(P2-T4), `has_player(id)`, `is_alive(id)`, `last_respawn_position(id)`, `recent_events()`이며 변경 알림은 `changed`, `own_vitals_changed`, `player_alive_changed`, `event_received`, `player_respawned` 시그널이다. 최근 이벤트 목록은 설정된 개수만 보관한다. 수치는 `data/tuning/survival_net_settings.tres`와 `survival_settings.tres`에 있고 임시 결정은 docs/15 P2-70~P2-74다.

### 14.13 전투 네트워크 계약(P2-N1b, 모듈 `CombatNet`)

`scripts/services/multiplayer/`: `CombatNetModule`(NetModule, 노드 이름 `CombatNet`: 근접 공격 의도 RPC, 결과 응답, 전투 이벤트 복제, 클라이언트 표면), `ClientCombatState`(공개 전투 이벤트의 형식·검증과 최근 이벤트 목록. 클라이언트에서는 서버가 보낸 것의 미러, 서버 모듈에서는 자신이 보낸 것의 기록이며 어느 쪽도 권한이 없다), `CombatNetSettings`(`data/tuning/combat_net_settings.tres`). 조립은 `ServerComposition.install_net_modules`에서만 하고 `CompositionConfig`에 `combat_net` 필드가 추가됐다(`validate()`에 포함). `network_service.gd`는 수정하지 않았고 §14.5의 공개 헬퍼만 쓴다. 게임 규칙은 전부 `CombatService`(§14.10)에 있고 이 모듈은 전송·검증만 한다. 임시 가정은 docs/15 P2-60~P2-65.

**프로토콜 변경 있음**: 아래 RPC 3개와 join 스냅샷의 `modules.CombatNet` 조각이 새로 생겼다. N1 묶음을 병합하면서 `BuildInfo.PROTOCOL_VERSION`을 3으로 올렸다.

| 방향 | RPC | 채널/모드 | 받는 쪽 검증 |
|---|---|---|---|
| C→S | `_rpc_request_melee_attack(request_id: int, aim_yaw: float)` | 0 reliable | 아래 "요청 검증" 표 |
| S→요청자 | `_rpc_melee_result(request_id: int, ok: bool, reason: String)` | 0 reliable | 서버 발신만 수용, 타입, `request_id` ≥ 0, `reason` 길이 ≤ 64, `ok`일 때만 `reason`이 빈 문자열 |
| S→전체 | `_rpc_combat_events(events: Array[Dictionary])` | 0 reliable | 서버 발신만 수용, 배열·항목 수 ≤ 64, 항목마다 아래 "공개 이벤트" 형식 검증과 순번 증가 |

요청: 클라이언트는 의도만 보낸다(자신이 붙인 요청 번호와 조준 방향). 플레이어·위치·대상·무기·피해 인자는 없다. 공격자는 보낸 peer의 플레이어(`NetworkService.sender_player_id()`)이고 나머지는 `CombatService.request_melee_attack(world, player_id, aim_yaw)`이 서버 상태에서 정한다. 다른 플레이어를 사칭할 수단이 없다는 것(인자가 둘뿐이고, 인자를 더 붙여 보내면 핸들러가 호출되지 않는다)은 테스트로 고정했다.

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 아무것도 바뀌지 않고 `NetworkService.rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드 | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | `request_id`가 int가 아니거나 `aim_yaw`가 float가 아님(int·문자열·벡터·null 등) | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `bad_aim_yaw` | NaN·무한 또는 `\|aim_yaw\|` > `CombatSettings.max_abs_aim_yaw`(전투 규칙과 같은 값) | 보냄 |
| 5 | `rate_limited` | peer별 토큰 버킷(`CombatNetSettings.melee_intent_rate_per_sec`/`melee_intent_burst`, 기본 4/s·버스트 4) 초과. 형식이 틀린 요청은 토큰을 쓰지 않는다(줍기와 같은 순서) | 보냄 |
| 6 | `combat_unavailable` | 월드에 전투 시스템이 없음(조립 오류) | 보냄 |
| 7 | `CombatService`의 사유(§14.10: `player_dead`, `attack_on_cooldown`, `not_enough_stamina` 등) | 전투 규칙이 거부. 정상 플레이에서 흔하므로 횟수만 세고 경고 로그는 남기지 않는다(`count_rejection`) | 보냄 |

결과는 요청자에게만 간다. 승인되면 `(request_id, true, "")`, 거부되면 `(request_id, false, 사유 코드)`. 결과에는 명중 여부가 없고, 명중·피해는 뒤이어 오는 이벤트로 안다.

전투 이벤트: 모듈은 매 서버 틱(`server_physics`) `CombatService.drain_events()`를 비운다. **이 모듈이 전투 이벤트 큐의 유일한 소비자다**(좀비 이벤트 큐는 건드리지 않는다). 각 이벤트를 공개 형식으로 바꿔 서버 세션 순번(`sequence`, 1부터 1씩 증가, 저장하지 않으며 서버를 다시 시작하면 1부터)을 붙이고, join을 마친 모든 peer에게 같은 내용을 같은 순서로 보낸다. 한 메시지에 `max_events_per_message`(기본 32, 프로토콜 상한 `CombatNetModule.MAX_EVENTS_PER_MESSAGE` = 64)개까지 담고 넘으면 여러 메시지로 나눈다. 서버는 보내기 전에 자기 이벤트를 클라이언트와 같은 검증(`ClientCombatState.validate_event`)에 통과시키며, 통과하지 못하거나 모듈이 모르는 이벤트 종류는 보내지 않고 오류 로그를 남긴다.

공개 이벤트 `melee_attack`(Dictionary, 문자열 키. 모든 클라이언트가 같은 값을 받는다):

| 필드 | 타입/범위 | 내용 |
|---|---|---|
| `sequence` | int ≥ 1 | 서버 세션 순번 |
| `event_type` | `"melee_attack"` | 다른 값은 클라이언트가 버린다 |
| `attacker_id` | String 1~64자 | 공격한 플레이어 ID |
| `weapon_id` | String 1~64자 | 무기 정의 ID |
| `aim_yaw` | float, [−π, π] | 조준 방향 |
| `position` | Vector3(유한값) | 공격 순간 공격자의 서버 위치(서버 이벤트의 `[x, y, z]`를 Vector3로 바꿔 보낸다) |
| `hit` | bool | 명중 여부 |
| `target_id` | String ≤ 64자 | 맞은 좀비 ID. `hit`이 false일 때만 `""` |
| `target_died` | bool | 이 공격으로 좀비가 죽었는지(`hit`이 false면 항상 false) |
| `world_time` | float ≥ 0 | 서버 월드 시각 |
| `damage`, `target_health_after` | float ≥ 0 | 들어간 피해와 맞은 뒤 좀비 체력. 둘은 항상 함께 있거나 함께 없다(`CombatNetSettings.broadcast_damage_numbers`, 기본 true) |

- 정보 공개(docs/15 P2-9, P2-62): `melee_attack`에는 플레이어의 비공개 상태(체력·스태미나·상처·감염)가 없다. 공격자 위치는 위치 스냅샷으로, 좀비 체력 비율은 좀비 스냅샷으로 이미 모두에게 가는 값이라 기본값은 전 필드 공개다. 피해 수치만 감추고 싶으면 `broadcast_damage_numbers`를 끈다(공격자 본인에게도 가지 않는다). 서버 이벤트에 필드가 추가되어도 위 표에 없는 필드는 전송되지 않는다(허용 목록 방식).
- 순서 보장: 모두 채널 0(reliable ordered)이므로 (1) 한 요청의 결과는 그 공격의 이벤트보다 먼저 도착하고, (2) 이벤트는 서버가 판정한 순서로 모든 클라이언트에 같은 순서로 도착하며, (3) join 스냅샷보다 뒤에 온다. 이벤트에는 요청 번호가 없다. 자기 공격의 이벤트는 `attacker_id`가 자기 ID인 것이고, 승인된 요청 순서와 같은 순서로 온다.
- 늦게 접속한 클라이언트: 지난 이벤트를 다시 보내지 않는다. join 스냅샷의 `modules.CombatNet` = `{last_sequence: int}`(이미 보낸 가장 새 순번)를 기준으로 그 뒤 순번부터 받는다. 클라이언트는 순번이 마지막으로 받은 것보다 크지 않은 이벤트를 버린다.
- 거리 필터가 없다: 접속 중인 모든 클라이언트가 월드 어디서 난 전투 이벤트든 받는다(docs/15 P2-62).

클라이언트 표면(`network.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule`, 프레젠테이션이 사용):

| API | 계약 |
|---|---|
| `request_melee_attack(aim_yaw: float) -> int` | 요청을 보내고 요청 번호(1부터)를 돌려준다. join 전이거나 클라이언트가 아니면 아무것도 보내지 않고 `CombatNetModule.NO_REQUEST`(0). 쿨다운·스태미나를 클라이언트에서 미리 판단하지 않는다 |
| `signal melee_result(request_id: int, ok: bool, reason: String)` | 자기 요청의 결과 |
| `signal combat_event(event: Dictionary)` | 검증을 통과한 공개 이벤트(사본), 서버 순서대로 |
| `recent_events() -> Array[Dictionary]`, `last_event_sequence() -> int` | 최근 이벤트(사본, 오래된 순, `recent_event_capacity` 기본 64개)와 가장 새 순번. 미러이며 권한이 없다 |
| `events: ClientCombatState`(`changed` 시그널), `rejected_event_count` | 미러 객체, 형식이 틀려 버린 페이로드 수(진단) |
| `send_raw_melee_request(request_id, aim_yaw)` | 클라이언트 쪽 검사 없이 그대로 보낸다(테스트 전용: 조작된 요청을 실제 RPC 경로로) |

- 서버 전용 RPC를 클라이언트가 보내는 경우: 결과·이벤트 RPC는 `@rpc("authority")`라 엔진이 서버 아닌 발신자를 거부하고, 핸들러도 `network.is_from_server()`를 다시 확인한다. 클라이언트끼리는 직접 닿지 않는다(서버 relay 비활성). 요청 RPC 핸들러는 서버가 아니면 아무것도 하지 않는다.
- 테스트: `tests/integration/combat_net_test.gd`(서버 1 + 클라이언트 2~3, 실제 ENet. 공격 → 서버 좀비 체력 감소·요청자만 결과·두 클라이언트와 서버 기록이 같은 이벤트, 좀비가 죽을 때까지의 이벤트 열 일치, 쿨다운·스태미나·사망 거부, 조작된 요청 13종과 거부 카운터·서버 상태 불변, join 전 요청, 빈도 초과와 peer별 버킷, 클라이언트가 보낸 서버 전용 RPC 무시, 사칭 불가, 늦은 접속, 한 틱의 이벤트 분할 전송과 피해 수치 비공개 설정, 서버가 보낸 형식 오류 페이로드를 클라이언트가 버림, 기본 설정·조립·RPC 설정, 공개 형식 변환과 검증 규칙).

### 14.15 클라이언트 좀비·생존 표시와 공격 입력(P2-N2)

`ClientView`는 클라이언트 역할에서만 지연 로드되는 `client_view.tscn` 안에서 실행된다. 서버 bootstrap은 이 씬과 `scripts/presentation/**`, `ClientPresentationSettings`를 로드하지 않는다. 오프라인 클라이언트에서는 `GameBootstrap.get_network()`가 null이므로 빈 월드와 버전 라벨만 표시하며 미러 접근이나 RPC를 하지 않는다.

표시 계층은 `NetworkService.get_module()` 공개 seam으로 다음 읽기/전송 표면만 연결한다.

| 모듈/미러 | 사용 표면 | 클라이언트 동작 |
|---|---|---|
| `ZombieNetModule.client_state` | `zombie_added`, `zombie_removed`, `changed`, `event_received`, `zombie_ids/get_zombie/recent_events` | 캡슐 생성·제거·위치/yaw/상태 색 갱신, 좀비 공격 로그 |
| `SurvivalNetModule.client_state` | `changed`, `health/stamina/need_category/wounds/infection_stage/is_alive` | 플레이어 생존/사망 캡슐과 본인 HUD 갱신 |
| `CombatNetModule` / `ClientCombatState` | `request_melee_attack`, `melee_result`, `combat_event`, `recent_events` | 카메라 yaw 의도 전송, 서버 결과와 공개 전투 이벤트 표시 |

좀비와 플레이어 캡슐은 미러의 가장 최근 위치를 그대로 사용한다. 프레젠테이션 보간·외삽·예측은 없고, 시체는 X축으로 기울여 눕힌다. 좀비의 `idle/investigate/chase/attack/search/dormant/dead` 색과 임시 크기, 사망 플레이어 색은 `data/tuning/client_presentation_settings.tres`에 있다. 플레이어의 살아 있는 로컬/원격 색과 크기는 기존 `camera_settings.tres`를 유지한다.

HUD는 owner 미러가 존재할 때만 체력·스태미나 수치, 세 욕구 범주, 감염 단계, 상처 수/출혈, 사망 문구를 만든다. P2-T4부터 첫 줄에 "캐릭터 #N"(본인 미러의 세대 번호)이 붙고 사망 문구는 영구 사망 안내다(§14.19). 다른 플레이어의 owner 상태를 추론하거나 표시하지 않는다. 최근 이벤트 로그는 `ClientCombatState`와 `ClientZombieState`가 보관한 서버 이벤트만 사용하며, 좀비 공격의 `infection`은 `target_id == local_player_id`이고 해당 필드가 있을 때만 문자열로 만든다.

`ClientInputActions`는 공격 액션을 중복 없이 등록한다. `AttackIntentPolicy`는 연결된 클라이언트에서 설정된 최소 간격만 지났는지 판단하는 노드 없는 로컬 flood guard이며, 쿨다운·스태미나·명중·피해는 판단하지 않는다. 통과하면 `CombatNetModule.request_melee_attack(_yaw)`만 호출한다(yaw 0 = −Z). 마지막 `melee_result`의 승인 또는 서버 사유 코드를 설정 시간 동안 HUD에 표시한다.

`ClientPresentationFormatter`, `AttackIntentPolicy`는 노드 없는 `RefCounted`이며 상태→색, 생존 HUD 문구, 공개 이벤트/공격 결과 문구, 최소 전송 간격을 단위 테스트한다. 임시 결정은 docs/15 §8 P2-90~P2-93에 기록한다.

### 14.16 달력 시간과 행동 시간(P2-T1, docs/00 ADR-006)

서버 시간은 두 축이다. 둘 다 `WorldClock`(`ServerWorld.clock`) 하나가 진행하고 저장한다. 이 절이 §14.6·§14.8~§14.11의 시간 단위 서술보다 우선한다. 임시 가정은 docs/15 §9(P2-100~P2-109).

| 축 | 시각(`WorldClock`) | 틱 증분 | 단위 | 이 축을 쓰는 것 |
|---|---|---|---|---|
| 달력 시간 | `world_time_sec` | `world_delta` = 실제 초 × `time_scale` | 월드초. 기본 배율 24(실제 1시간 = 월드 하루, `data/tuning/world_clock_settings.tres`) | 허기·갈증·피로 증가, 감염 단계 지속 시간과 단계별 체력 감소, 출혈, 자연 체력·상처 회복, 굶주림·탈수 피해. 모든 시스템 이벤트의 `world_time`, 상처·감염의 `*_world_time` 필드 |
| 행동 시간 | `action_time_sec` | `action_delta` = 실제 초 | 실제 초(배율과 무관) | 좀비의 모든 시간·속도(AI 주기, 이동, 공격 선딜·쿨다운, 조사·수색, 배회 대기, 시체 제거), 소음 수명·시간 감쇠, 근접 공격 쿨다운, 발소리의 속도 판정, 스태미나 회복, 리스폰 대기, 생존 피해 이벤트를 묶는 간격(P2-88) |

- 일시정지: 접속자가 0명이고 `pause_when_empty`이면 두 시각이 함께 멈추고 두 증분 모두 0이다. 그 밖에는 `world_delta` = `action_delta` × `time_scale`이다. `WorldClock.step(real_delta, any_online)`은 예전처럼 달력 증분을 돌려주고, 같은 틱의 두 증분은 `last_world_delta`/`last_action_delta`로 읽는다. `WorldClock.new()`는 배율 1인 시계이고(테스트용 기본), 게임 시계는 `WorldClockSettings.create_clock()`이 만든다(스크립트 기본값도 24).
- `ServerSystem.step` 계약 결정: 매개변수를 늘리지 않고 두 번째 매개변수의 뜻을 바꿨다. `step(world, action_delta, world_delta)`. 예전의 `real_delta`는 일시정지 중에도 실제 틱 길이였는데, 이제 `action_delta`는 일시정지 중 0이다. 이유: (1) 오버라이드의 매개변수 수가 그대로라 기존 시스템·테스트 더블·다른 브랜치에서 추가되는 시스템이 수정 없이 컴파일된다(GDScript는 매개변수 수가 다른 오버라이드를 오류로 처리한다). (2) 증분을 시계의 상태가 아니라 인자로 받으므로 `step`을 직접 부르는 단위 테스트가 입력만으로 결정된다. (3) 멈춘 월드에서 시스템이 실제 시간을 쓰는 길이 없어진다(일시정지 중 실제 틱 길이를 쓰던 시스템은 없었다). 기한·타임스탬프는 시스템이 생성자에서 받은 `WorldClock`의 `action_time_sec`/`world_time_sec`로 읽는다. 일시정지와 무관한 벽시계 시간이 필요한 일(자동 저장, 스냅샷 주기, 요청 빈도 제한, 입력 타임아웃)은 지금처럼 `NetModule.server_physics(delta)`와 `NetworkService`가 맡는다. `ServerWorld.step_systems(real_delta)`의 반환값은 그대로 달력 증분이다.
- 이벤트의 `world_time`: 생존·좀비·전투 이벤트 모두 달력 시각(`world_time_sec`)이다. 필드 이름과 RPC 페이로드 형식은 바뀌지 않았고, 서로 다른 시스템의 이벤트를 같은 축에서 순서대로 놓을 수 있다. 두 시각은 같은 틱에 함께 늘어나므로 어느 쪽으로도 순서는 같다. 행동 시간 시스템의 간격을 이벤트로 재려면 `world_time` 차이를 배율로 나누거나 서버의 `action_time_sec`를 읽는다. 소음의 `event_time`과 `query_audible(position, hearing_multiplier, since_time)`의 `since_time`은 행동 시각이다(소음은 복제하지 않는다).

시스템별 내부 시각:

| 시스템 | 행동 시각으로 두는 값 | 달력 시각으로 두는 값 |
|---|---|---|
| `survival` | `PlayerVitals.died_at_action_time`(저장, 리스폰 기한의 기준), 아직 내보내지 않은 피해의 시작 시각(저장 안 함) | 이벤트 `world_time`, `PlayerVitals.died_at_world_time`, `Wound.created_at_world_time`, `InfectionState.infected_at_world_time`·`stage_entered_at_world_time`·`stage_elapsed_world_sec` |
| `noise` | `NoiseEvent.event_time`, 수명·감쇠 | 없음 |
| `player_noise` | 속도 판정에 쓰는 틱 길이 | 없음 |
| `zombie` | `ZombieState.state_until`·`attack_ready_at`·`next_wander_at`·`last_noise_time`·`died_at`(모두 저장), AI 스케줄러 | 이벤트 `world_time` |
| `combat` | 플레이어별 다음 공격 가능 시각(저장 안 함), `cooldown_remaining`의 반환값(실제 초) | 이벤트 `world_time` |

- 생존의 구간 적분: `_advance_player`는 그대로 한 틱의 달력 구간을 욕구 임계·감염 단계·사망·리스폰 경계에서 나눠 적분한다. 한 틱 안에서는 두 시각이 직선으로 함께 늘어나므로(행동 = 틱 시작 행동 시각 + (달력 − 틱 시작 달력 시각) × `action_delta / world_delta`) 행동 시간 항목을 그 비율로 바꿔 넣는다. 스태미나 회복량 = 초당 회복 × 욕구·감염 배율 × 구간의 행동 시간, 리스폰 시각 = `died_at_action_time + respawn_delay_sec`에 해당하는 달력 시각, 피해 이벤트는 행동 시간으로 `survival_damage_event_interval_sec`가 지나면 낸다. 그래서 배율이 1이 아니어도 틱 크기와 무관하다(허용 오차 1e-3, 배율 24에서 틱 1/60초~25초 비교 테스트). 리스폰 기한을 행동 시각으로 저장하므로 배율 설정이 바뀌어도 대기 시간이 달라지지 않는다.
- 저장: world_state.json 스키마 v3이 `action_time_sec`를 추가한다. v2 → v3 마이그레이션은 `action_time_sec = world_time_sec`로 둔다(P2-T1 전에는 시계가 하나였고 배율 1이었으므로, 그 시계로 저장된 좀비 기한이 그대로 맞는다. docs/15 P2-102). 현재 스키마 문서에 `action_time_sec`가 없거나 음수·비수치면 월드 복구를 실패시킨다. 생존 fragment 스키마 v4가 `died_at_action_time`을 추가한다. v1~v3 fragment는 그대로 읽고, 그 안의 사망한 플레이어는 다음 접속 순간부터 리스폰 대기를 새로 센다. 좀비·전투 문서의 스키마 버전은 그대로다(필드와 단위가 같고 기준 시계만 바뀌었으며 마이그레이션이 두 시계를 같은 값에서 시작시킨다).
- 설정 이름: 뜻이 실제 초로 바뀐 세 항목의 이름을 바꿨다. `stamina_regen_per_world_sec` → `stamina_regen_per_sec`, `respawn_delay_world_sec` → `respawn_delay_sec`, `survival_damage_event_interval_world_sec` → `survival_damage_event_interval_sec`. `SurvivalSettings`에서 `world_sec`·`hours`가 든 이름은 달력 시간, `_sec`로만 끝나는 이름은 실제 초다. 좀비·소음·전투·발소리 설정은 이름이 원래 `_sec`·`_mps`라 그대로이고 주석의 단위만 고쳤다.
- 테스트: `tests/unit/time_axes_test.gd`. 같은 실제 시간을 배율 1과 24로 돌려 행동 시간 결과(좀비 이동 거리·공격 틱·조사/수색 전환·시체 제거, 발소리 수, 소음 만료 틱, 근접 공격 승인 틱, 스태미나, 리스폰 틱, 피해 이벤트 수)는 같고 달력 시간 결과(욕구, 감염 경과, 출혈 피해, 체력·상처 회복)는 24배임을 비교한다. 접속자 0명일 때 두 시각 정지, 이벤트 `world_time`이 달력 시각임, 두 시각의 저장 → 재생성 → 로드, 저장된 좀비 공격 기한과 리스폰 기한이 재시작 뒤에도 남은 시간만큼 흐르는지, P2-T1 이전 저장(월드 v2, 생존 fragment v3)의 마이그레이션, 배율 24에서의 생존 구간 적분을 포함한다. Phase 2 수용 시나리오는 기본 배율 24로 실행된다.
### 14.17 인벤토리 변화 복제 기반(P2-T2, 모듈 `InventoryNet`)

Phase 1에는 "월드 아이템을 줍는다" 한 방향만 있었다. 이 절은 반대 방향(아이템이 인벤토리에서 월드로 가거나 인벤토리에서 없어지는 변화)의 서버 트랜잭션과 복제를 정한다. 먹기(P2-T3, §14.18)와 영구 사망(P2-T4, §14.19)은 이 절의 서버 API를 호출하는 후속 티켓이다. 임시 가정은 docs/15 §10 P2-110~P2-119.

구성: `InventoryService`(트랜잭션 3개와 `transaction_committed` 시그널 추가), `ServerWorld`(줍기 옆의 래퍼 3개), `InventoryNetModule`(NetModule, 노드 이름 `InventoryNet`: 내려놓기 의도 RPC, 결과 응답, 변화 복제, 클라이언트 표면), `InventoryNetSettings`(`data/tuning/inventory_net_settings.tres`), `ClientWorldState`(미러 적용 메서드 추가). 조립은 `ServerComposition.install_net_modules`에서만 하고 `CompositionConfig`에 `inventory_net` 필드가 추가됐다(`validate()`에 포함). `network_service.gd`는 수정하지 않았고 §14.5의 공개 헬퍼만 쓴다.

**프로토콜 변경 있음**: 아래 RPC 5개가 새로 생겨 `BuildInfo.PROTOCOL_VERSION`을 4로 올렸다. join 스냅샷 형식은 그대로다(`modules.InventoryNet` 조각은 빈 객체).

#### 서버 트랜잭션(`InventoryService`, 서버 전용)

모두 `ActionResult`를 돌려준다. 실패하면 사유 코드만 있고 상태는 아무것도 바뀌지 않는다(검사를 전부 마친 뒤에만 반영). 성공하면 `event`에 확정된 사실이 들어 있다.

| 메서드 | 동작 | 성공 이벤트(`event`) | 실패 사유 |
|---|---|---|---|
| `drop_item(inventory_id, item_instance_id, cell_id, position: Vector3)` | 들고 있는 아이템 하나(스택 전체)를 월드의 `position`에 놓는다. `location_type` = `world`, `location_id` = `cell_id`, `slot_id` 비움 | `items_dropped` | `unknown_inventory`, `unknown_item`, `item_not_in_inventory`, `bad_cell`, `bad_position` |
| `drop_all_items(inventory_id, cell_id, position: Vector3)` | 그 인벤토리의 모든 아이템을 한 위치에 놓는다(전부 또는 전무). 빈 인벤토리는 성공이고 이벤트 목록이 비며 시그널을 내지 않는다 | `items_dropped` | `unknown_inventory`, `bad_cell`, `bad_position` |
| `remove_item(inventory_id, item_instance_id, quantity: int)` | 들고 있는 아이템에서 `quantity`개를 게임에서 없앤다. 남으면 수량만 줄고, 0이 되면 인스턴스를 지우고 `EntityRegistry.remove`로 ID를 tombstone 처리한다(재사용 불가, docs/14 §1) | `item_removed` | `unknown_inventory`, `unknown_item`, `item_not_in_inventory`, `bad_quantity` |

- `item_not_in_inventory`: 아이템은 있지만 그 인벤토리에 들어 있지 않다(월드에 놓여 있거나 다른 인벤토리에 있다). `bad_quantity`: 1 미만이거나 스택 수량 초과. `bad_position`: 유한값이 아니거나 `|x|`, `|z|`가 월드 반폭을 넘는다(반폭은 생성자 5번째 인자 `world_half_extent_m`, 기본값 무제한. `ServerWorld`가 `GameplaySettings.world_half_extent_m`을 넘긴다). `bad_cell`: 빈 셀 ID.
- 이벤트 형식(JSON-safe): `items_dropped` = `{event_type, inventory_id, item_instance_ids: Array[String](슬롯 순서), cell_id, position: [x, y, z]}`, `item_removed` = `{event_type, inventory_id, item_instance_id, definition_id, removed_quantity, remaining_quantity}`(`remaining_quantity` 0 = 인스턴스 삭제됨).
- `signal transaction_committed(event: Dictionary)`: 확정된 트랜잭션마다(줍기 `item_picked_up` 포함) 상태 반영이 끝난 직후, 확정 순서대로, 동기적으로 한 번 나온다. 인자는 이벤트의 사본이다. 실패한 요청은 내지 않는다.
- 보조: `item_count()`(존재하는 인스턴스 수). 저장 형식은 바뀌지 않았다: 내려놓은 아이템의 좌표는 기존대로 world_state `inventory.world_item_positions`(docs/15 P1-7)에, 삭제된 ID는 world_state `tombstones`에, 다음 순번은 `next_entity_sequence`에 들어간다.

`ServerWorld` 래퍼(위치·셀·인벤토리 ID는 서버 상태에서 채운다. 셀은 `DevWorldSeed.DEV_CELL_ID`, 위치는 `clamp_to_world(플레이어 위치)`):

| 메서드 | 대상 | 추가 실패 사유 |
|---|---|---|
| `try_drop_item(player_id, item_instance_id)` | 접속 중인 플레이어(의도 처리용) | `not_online`, 시스템이 막는 사유(`player_dead`, P2-T4 §14.19. `try_pickup`도 같다) |
| `drop_all_player_items(player_id)` | 알려진 플레이어(오프라인 포함, 서버 규칙용) | `unknown_player` |
| `remove_player_item(player_id, item_instance_id, quantity)` | 알려진 플레이어(오프라인 포함, 서버 규칙용) | `unknown_player` |

#### 네트워크 메시지

| 방향 | RPC | 채널/모드 | 받는 쪽 검증 |
|---|---|---|---|
| C→S | `_rpc_request_drop(request_id: int, item_instance_id: String)` | 0 reliable | 아래 "요청 검증" 표 |
| S→요청자 | `_rpc_drop_result(request_id: int, ok: bool, reason: String)` | 0 reliable | 서버 발신만 수용, 타입, `request_id` ≥ 0, `reason` 길이 ≤ 64, `ok`일 때만 `reason`이 빈 문자열 |
| S→전체 | `_rpc_world_items_added(items: Array[Dictionary])` | 0 reliable | 서버 발신만 수용, 배열·항목 수 ≤ 64, 항목마다 `{item_instance_id: String 1~64자, definition_id: snake_case String ≤ 64자, quantity: int ≥ 1, position: Vector3(유한값)}`(join 스냅샷 `world_items` 항목과 같은 형식) |
| S→소유자 | `_rpc_inventory_items_removed(item_instance_ids: Array[String])` | 0 reliable | 서버 발신만 수용, 배열·항목 수 ≤ 64, 항목마다 String 1~64자 |
| S→소유자 | `_rpc_inventory_item_changed(item: Dictionary)` | 0 reliable | 서버 발신만 수용, `ItemInstance.validate_dict` 통과, ID ≤ 64자, `location_type` = `inventory` |

요청: 클라이언트는 의도만 보낸다(자신이 붙인 요청 번호와 아이템 인스턴스 ID). 위치·소유자·수량 인자는 없다. 행위자는 보낸 peer의 플레이어(`NetworkService.sender_player_id()`)이고 놓이는 위치는 서버가 아는 그 플레이어의 위치다. 인자를 더 붙여 보낸 호출은 엔진이 거부해 핸들러에 닿지 않는다(테스트로 고정).

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 아무것도 바뀌지 않고 `NetworkService.rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드(카운터) | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | `request_id`가 int가 아니거나 `item_instance_id`가 String이 아님 | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `bad_item_id` | ID가 비었거나 64자 초과(줍기와 같은 규칙, `IntentValidator.validate_pickup`) | 보냄 |
| 5 | `rate_limited` | peer별 토큰 버킷(`InventoryNetSettings.drop_intent_rate_per_sec`/`drop_intent_burst`, 기본 4/s·버스트 4) 초과. 형식이 틀린 요청은 토큰을 쓰지 않는다 | 보냄 |
| 6 | `player_dead` | 생존 시스템이 있고 요청자가 살아 있지 않음(`SurvivalService.is_alive`). 생존 시스템이 없는 월드에서는 검사하지 않는다 | 보냄 |
| 7 | 트랜잭션 사유(`item_not_in_inventory`, `unknown_item`, `not_online`, `bad_position` 등) | `ServerWorld.try_drop_item`이 거부 | 보냄. 단 `unknown_item`은 요청자에게 `item_not_in_inventory`로 알린다 |

- 1~5는 `reject_intent`(횟수 + 경고 로그), 6~7은 정상 플레이에서 생길 수 있어 `count_rejection`(횟수만)으로 기록한다. 카운터에는 서버 내부 사유(`unknown_item` 포함)가 그대로 남는다.
- 정보 공개: 요청자는 자기가 들고 있지 않은 ID에 대해 "없는 ID"와 "남이 들고 있거나 월드에 있는 ID"를 구별할 수 없다(`InventoryNetModule.public_reason`).
- 결과는 요청자에게만 간다. 승인되면 `(request_id, true, "")`, 거부되면 `(request_id, false, 사유 코드)`.

복제: 모듈은 서버에서 `InventoryService.transaction_committed`를 듣고 **확정되는 그 자리에서** 보낸다(큐에 모았다가 틱 끝에 보내지 않는다). 그래서 이 모듈의 메시지와 `NetworkService`가 직접 보내는 줍기 메시지(`_rpc_world_item_removed`, `_rpc_inventory_item`)가 같은 채널 0에서 서버가 확정한 순서 그대로 나간다. A가 내려놓은 아이템을 B가 같은 틱에 주워도 모든 클라이언트는 "월드에 추가 → 월드에서 제거" 순서로 받는다. 누가 트랜잭션을 불렀는지는 상관없다: 이 모듈의 내려놓기 의도, 서버 규칙이 부른 `ServerWorld.drop_all_player_items`/`remove_player_item`, `InventoryService` 직접 호출이 모두 같은 경로로 복제된다.

| 서버에서 확정된 사실 | 소유자(그 인벤토리의 접속 중인 플레이어)에게 | 접속 중인 모든 peer에게 |
|---|---|---|
| `items_dropped` | `_rpc_inventory_items_removed`(빠진 ID) 먼저 | 이어서 `_rpc_world_items_added`(정의 ID, 수량, 위치) |
| `item_removed`, 수량이 남음 | `_rpc_inventory_item_changed`(줄어든 `ItemInstance`) | 보내지 않음 |
| `item_removed`, 0이 됨 | `_rpc_inventory_items_removed`(그 ID) | 보내지 않음 |
| `item_picked_up` | (이 모듈은 보내지 않는다. RPC 줍기는 `NetworkService`가 복제한다) | — |

- 다른 플레이어의 인벤토리 내용은 어떤 메시지로도 가지 않는다. 월드 아이템 메시지에는 누가 내려놓았는지가 없다.
- 소유자가 접속 중이 아니면 소유자 메시지는 없다(다음 join 스냅샷의 `inventory`가 최신 상태다). join 도중에 일어난 변화는 join 스냅샷에 들어가므로 따로 보내지 않는다.
- 한 메시지에 `max_items_per_message`(기본 32, 프로토콜 상한 `InventoryNetModule.MAX_ITEMS_PER_MESSAGE` = 64)개까지 담고 넘으면 순서대로 여러 메시지로 나눈다. 서버는 보내기 전에 자기 항목을 클라이언트와 같은 검증에 통과시킨다.
- 늦게 접속한 클라이언트: 내려놓인 아이템은 일반 월드 아이템이므로 기존 join 스냅샷(`world_items`, 본인 `inventory`)으로 충분하다. 모듈의 join 조각은 없다.
- 거리 필터가 없다: 접속 중인 모든 클라이언트가 월드 어디에 놓인 아이템이든 받는다(줍기와 같다).

저장: 내려놓기 의도가 승인되면 결과를 보내기 전에 월드 전체를 저장한다(줍기와 같은 "주요 트랜잭션", docs/10 §5). 서버 규칙이 부른 변화는 그 서버 틱의 끝(`server_physics`)에 한 번 저장한다. 예외는 소비 의도(P2-T3)가 일으킨 제거로, 따로 저장하지 않고 다음 저장에 맡긴다(§14.18).

클라이언트 표면(`network.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule`):

| API | 계약 |
|---|---|
| `request_drop(item_instance_id: String) -> int` | 요청을 보내고 요청 번호(1부터)를 돌려준다. join 전이거나 클라이언트가 아니면 아무것도 보내지 않고 `InventoryNetModule.NO_REQUEST`(0). 클라이언트에서 미리 판단하지 않는다 |
| `signal drop_result(request_id: int, ok: bool, reason: String)` | 자기 요청의 결과 |
| `signal world_items_added(item_instance_ids: PackedStringArray)` | 월드에 아이템이 놓였다(미러 반영 뒤) |
| `signal inventory_items_removed(item_instance_ids: PackedStringArray)` | 자기 인벤토리에서 빠졌다(미러 반영 뒤) |
| `signal inventory_item_changed(item_instance_id: String)` | 자기 인벤토리의 아이템이 추가되거나 바뀌었다(수량) |
| `rejected_payload_count`, `owner_message_count` | 형식이 틀려 버린 서버 페이로드 수, 받은 소유자 전용 메시지 수(진단) |
| `send_raw_drop_request(request_id, item_instance_id)` | 클라이언트 쪽 검사 없이 그대로 보낸다(테스트 전용) |

미러(`NetworkService.client_state`, `ClientWorldState`에 추가된 것. 권한 없음):

| API | 계약 |
|---|---|
| `apply_world_item_added(entry: Dictionary) -> bool` | 검증 뒤 `world_items[id]`를 추가/교체한다(아는 필드 4개만 보관). 형식이 틀리면 false이고 바뀌지 않는다 |
| `static is_valid_world_item(entry: Variant) -> bool` | 위 표의 월드 아이템 형식 검사 |
| `apply_inventory_item_removed(item_instance_id: String) -> bool` | `inventory`에서 그 항목을 지운다. 없으면 false이고 바뀌지 않는다 |
| `get_inventory_item(item_instance_id: String) -> Dictionary` | 미러의 인벤토리 항목(`ItemInstance` 사전)의 사본 또는 `{}` |
| `apply_inventory_item(item)`(기존) | 수량이 바뀐 항목의 교체에도 쓴다 |

- 서버 전용 RPC를 클라이언트가 보내는 경우: 결과·복제 RPC 4개는 `@rpc("authority")`라 엔진이 서버 아닌 발신자를 거부하고, 핸들러도 `network.is_from_server()`를 다시 확인한다. 요청 RPC 핸들러는 서버가 아니면 아무것도 하지 않는다.
- 알려진 한계: 서버 코드가 `ServerWorld.try_pickup`을 직접 부르면(줍기 RPC를 거치지 않으면) 복제되지 않는다. 줍기 복제는 동결된 `NetworkService`의 RPC 핸들러 안에만 있기 때문이다. 아이템을 인벤토리에 바로 만들어 주는 트랜잭션(지급)도 아직 없다(docs/15 P2-119).
- 클라이언트 표시(`scripts/presentation/**`)는 이 티켓에서 바꾸지 않았다. 내려놓기 입력은 없다. 인벤토리 요약 HUD는 P2-T3에서 생겼다(§14.18).
- 테스트: `tests/unit/inventory_transactions_test.gd`(트랜잭션 3개의 성공·실패·원자성, 시그널, ID 미재사용, `ServerWorld` 래퍼와 저장 문서 왕복, 미러 메서드), `tests/integration/inventory_net_test.gd`(서버 1 + 클라이언트 2~3, 실제 ENet: 줍기 → 내려놓기 → 다른 플레이어가 줍기와 총수 보존, 한 번의 서버 poll 안에서 처리되는 내려놓기·줍기·중복 내려놓기, 조작된 요청과 거부 카운터, join 전 요청, 빈도 초과, 죽은 플레이어, 클라이언트가 보낸 서버 전용 RPC, 서버가 보낸 형식 오류 페이로드, 늦은 접속, 서버 직접 호출의 제거·전부 내려놓기와 메시지 분할·소유자 한정, 저장 → 서버 재시작 → 재접속, 기본 설정·조립·RPC 설정).

### 14.18 먹기·마시기(P2-T3, docs/00 ADR-010)

플레이어가 들고 있는 음식·물 아이템 한 단위를 소비하면 서버가 그 플레이어의 허기·갈증을 낮춘다. 임시 가정은 docs/15 §11 P2-120~P2-125.

구성: `ItemDefinition`(소비 효과 필드), `SurvivalService.reduce_needs`(욕구를 낮추는 서버 전용 API), `ItemConsumption`(아이템 제거와 욕구 감소를 하나로 묶는 서버 규칙, `scripts/domain/survival/item_consumption.gd`), `InventoryNetModule`(소비 의도 RPC와 결과 응답 추가, §14.17), `DevWorldSeed`(수량 필드), 개발용 아이템 정의 2개, 클라이언트 소비 키와 인벤토리 HUD. `network_service.gd`는 수정하지 않았다.

**프로토콜 변경 있음**: RPC 2개(`_rpc_request_consume`, `_rpc_consume_result`)가 새로 생겨 `BuildInfo.PROTOCOL_VERSION`을 5로 올렸다. join 스냅샷 형식은 그대로다.

#### 데이터

- `ItemDefinition.consume_hunger_reduction`, `consume_thirst_reduction`: 한 단위를 소비했을 때 줄어드는 허기·갈증(`SurvivalSettings.need_max`와 같은 단위, 0 이상의 유한값). 둘 다 0이면 소비할 수 없는 아이템이다(`is_consumable()`). 정적 Resource이며 저장 데이터에는 들어가지 않는다(docs/02 §4.2, ADR-005).
- 개발용 정의: `dev_food_ration`(허기 −40, 최대 스택 5), `dev_water_bottle`(갈증 −50, 최대 스택 5). `resources/definitions/items/`.
- 개발용 월드(`data/tuning/dev_world_seed.tres`): 새 월드에 `dev_test_item` 1개(6, 0, 0), `dev_food_ration` 3개 묶음 2개((2, 0, 2), (2, 0, −2)), `dev_water_bottle` 3개 묶음 2개((−2, 0, 2), (−2, 0, −2)), `dev_melee_pipe` 1개(0, 0, 3)를 놓는다. `DevWorldSeed.item_quantities`가 묶음 수량이다(비어 있으면 모두 1, 아니면 아이템 수와 같은 길이·각 1 이상. 정의의 최대 스택을 넘으면 월드 생성이 실패한다).

#### 서버 규칙

`SurvivalService`(§14.6에 추가):

| API | 계약 |
|---|---|
| `reduce_needs(player_id, hunger_amount, thirst_amount, source_id) -> ActionResult` | 허기·갈증을 그만큼 낮춘다(0 미만으로 내려가지 않음, 피로는 건드리지 않음). 성공 이벤트 `{event_type: "player_needs_reduced", player_id, source_id, hunger_reduced, thirst_reduced(실제로 줄어든 양), hunger_after, thirst_after, world_time}`를 돌려주고 이벤트 큐와 로그에 남긴다. 범주가 바뀐 욕구마다 기존 `need_category_changed`가 뒤따른다. 실패 사유: `bad_need_amount`(유한값이 아니거나 음수, 또는 둘 다 0), `unknown_player`, `player_dead`. 실패하면 아무것도 바뀌지 않는다 |
| `check_reduce_needs(player_id, hunger_amount, thirst_amount) -> String` | 같은 인자의 `reduce_needs`가 지금 성공하면 `""`, 아니면 그 실패 사유. 상태를 바꾸지 않는다(다른 변경과 함께 확정해야 하는 호출자의 사전 검사) |

`ItemConsumption.try_consume(world, player_id, item_instance_id) -> ActionResult`(정적 함수, 상태 없음, 네트워크 없음):

- 검사 순서(먼저 걸린 것 하나): `not_online` → `consumption_unavailable`(월드에 생존 시스템이 없음) → `unknown_player`/`player_dead` → `unknown_item` → `item_not_in_inventory`(그 플레이어의 인벤토리에 들어 있지 않음: 월드에 있거나 남의 것) → `not_consumable` → `bad_need_amount`. 소유 검사가 정의 검사보다 앞이라, 자기 것이 아닌 아이템에 대해서는 종류를 알 수 없다.
- 원자성: 두 쪽의 조건을 전부 검사한 뒤에만 확정한다. 확정은 `ServerWorld.remove_player_item(player_id, item_instance_id, 1)`(§14.17 트랜잭션, `InventoryNet`이 복제) 다음 `SurvivalService.reduce_needs`다. 거부된 요청은 아이템도 욕구도 바꾸지 않는다. 사전 검사와 실제 호출이 같은 조건을 쓰고 그 사이에 다른 코드가 실행되지 않으므로 한쪽만 반영되는 경로가 없다(단위 테스트로 거부 경우마다 양쪽이 그대로임을 확인).
- 효과의 크기는 서버의 아이템 정의에서만 온다. 한 번에 한 단위(`ItemConsumption.CONSUMED_QUANTITY`)다.
- 성공 이벤트: `{event_type: "item_consumed", player_id, item_instance_id, definition_id, remaining_quantity(0 = 인스턴스 삭제됨), hunger_reduced, thirst_reduced, world_time}`. 반환값과 로그로만 쓰이고 복제되지 않는다.

#### 네트워크 메시지(`InventoryNetModule`에 추가)

| 방향 | RPC | 채널/모드 | 받는 쪽 검증 |
|---|---|---|---|
| C→S | `_rpc_request_consume(request_id: int, item_instance_id: String)` | 0 reliable | 아래 "요청 검증" |
| S→요청자 | `_rpc_consume_result(request_id: int, ok: bool, reason: String)` | 0 reliable | 서버 발신만 수용, 타입, `request_id` ≥ 0, `reason` 길이 ≤ 64, `ok`일 때만 `reason`이 빈 문자열 |

요청: 클라이언트는 의도만 보낸다(자신이 붙인 요청 번호와 아이템 인스턴스 ID). 대상 플레이어·수량·효과 인자는 없다. 행위자는 보낸 peer의 플레이어다. 인자를 더 붙인 호출은 엔진이 거부한다(테스트로 고정).

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 바뀌지 않고 `rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드(카운터) | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | `request_id`가 int가 아니거나 `item_instance_id`가 String이 아님 | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `bad_item_id` | ID가 비었거나 64자 초과 | 보냄 |
| 5 | `rate_limited` | peer별 토큰 버킷(`InventoryNetSettings.consume_intent_rate_per_sec`/`consume_intent_burst`, 기본 4/s·버스트 4. 내려놓기 버킷과 별개) 초과. 형식이 틀린 요청은 토큰을 쓰지 않는다 | 보냄 |
| 6 | `ItemConsumption`의 사유(`player_dead`, `item_not_in_inventory`, `unknown_item`, `not_consumable` 등) | 규칙이 거부 | 보냄. 단 `unknown_item`은 요청자에게 `item_not_in_inventory`로 알린다(§14.17 `public_reason`) |

- 1~5와 `consumption_unavailable`은 `reject_intent`(횟수 + 경고 로그), 나머지 6은 `count_rejection`(횟수만)이다.
- 결과는 요청자에게만 간다. 승인되면 `(request_id, true, "")`.
- 복제: 인벤토리 변화는 §14.17의 기존 경로로 소유자에게만 간다(수량이 남으면 `_rpc_inventory_item_changed`, 0이 되면 `_rpc_inventory_items_removed`). 같은 채널이라 그 메시지가 결과보다 먼저 도착한다. 욕구 변화는 §14.14의 본인 생존 경로로 간다: 범주가 바뀌면 다음 서버 틱의 `need_category_changed` 이벤트로, 그 밖에는 본인 스냅샷(2Hz, 범주만)으로. 그래서 본인 미러의 욕구 범주는 결과보다 한 틱쯤 늦게 바뀔 수 있다. `player_needs_reduced`와 `item_consumed`는 어떤 클라이언트에도 보내지 않는다.
- 정보 공개(ADR-009): 다른 플레이어는 누가 무엇을 먹었는지, 누구의 욕구가 어떤지 어떤 메시지로도 받지 않는다(테스트: 다른 클라이언트의 결과·인벤토리 메시지·생존 이벤트가 0개).

저장: 승인된 소비는 그것만으로 저장하지 않는다(`InventoryNetSettings.save_after_consume` 기본 false). 다음에 일어나는 저장(60초 자동 저장, 플레이어 퇴장, 서버 종료, 줍기·내려놓기)에 함께 들어간다. 저장은 항상 월드 전체(아이템과 플레이어 상태)를 한 번에 쓰므로, 서버가 비정상 종료하면 마지막 저장 뒤의 소비는 "아이템도 돌아오고 욕구도 돌아온" 상태로 복구된다(한쪽만 반영된 저장은 없다). 잃을 수 있는 범위는 마지막 저장 이후의 소비, 기본 설정에서 최대 60초 분량이다. `save_after_consume`을 켜면 내려놓기처럼 결과를 보내기 전에 저장한다. `ServerWorld.remove_player_item`을 서버 규칙이 직접 부른 경우의 "그 틱 끝에 저장"(§14.17)은 그대로다.

클라이언트 표면(`InventoryNetModule`): `request_consume(item_instance_id) -> int`(요청 번호, 1부터. join 전이면 `NO_REQUEST`), `signal consume_result(request_id, ok, reason)`, `send_raw_consume_request(request_id, item_instance_id)`(테스트 전용).

클라이언트 표시(`scripts/presentation/`): 소비 키(`ClientPresentationSettings.consume_key`, 기본 F)를 누르면 `ConsumeIntentPolicy.first_consumable_item_id`가 인벤토리 미러에서 첫 소비 가능 아이템(미러 순서, 정적 아이템 카탈로그로 판단)을 골라 그 ID만 `request_consume`으로 보낸다. 없으면 보내지 않고 안내 문구만 띄운다. 요청 사이 최소 간격(`consume_min_interval_sec`)은 공격 입력과 같은 로컬 flood guard(`AttackIntentPolicy`)다. HUD에 인벤토리 요약(`ClientPresentationFormatter.build_inventory_lines`: 묶음 수, 종류별 이름·합계 수량, 설정된 줄 수까지)과 마지막 소비 결과(승인 또는 서버 사유 코드, 설정 시간 동안)를 표시한다. 월드에 놓인 아이템은 여전히 화면에 그려지지 않는다.

테스트: `tests/unit/item_consumption_test.gd`(욕구 감소·하한·사망자와 잘못된 양 거부, 소비의 성공·수량 감소·삭제, 거부 경우마다 아이템과 욕구가 그대로임, 생존 시스템 없는 월드, 정의 데이터, 기본 개발용 월드, seed 수량, 저장 → 재생성 → 로드), `tests/integration/consume_net_test.gd`(서버 1 + 클라이언트 2, 실제 ENet: 주워서 먹고 마시면 서버와 본인 미러의 욕구 범주·인벤토리가 일치하고 다른 클라이언트는 아무것도 받지 않음, 조작된 요청 13종, join 전 요청, 빈도 초과와 버킷 분리, 죽은 플레이어, 클라이언트가 보낸 결과 RPC, 소비 저장 방침과 재시작, 즉시 저장 설정, 설정·검증 규칙), `tests/unit/client_presentation_test.gd`(첫 소비 가능 아이템 선택, 인벤토리 요약, 결과 문구, 소비 키 등록·설정 검증).

### 14.19 영구 사망(P2-T4, docs/00 ADR-007)

캐릭터가 죽으면 그 캐릭터는 끝난다. 소지품은 죽은 자리의 월드에 남고, 플레이어는 설정된 대기 시간 뒤 새 캐릭터로 시작한다. Phase 2의 개발용 리스폰(인벤토리 유지, §14.6의 B3 서술)을 대체하며 이 절이 §14.6보다 우선한다. 임시 가정은 docs/15 §11.2 P2-126~P2-131.

구성: `SurvivalService`(사망 시 소지품 내려놓기, 새 캐릭터 시작), `ServerWorld.start_new_character`·`player_action_block_reason`, `ServerSystem.on_registered`·`player_action_block_reason`(새 훅 2개), `PlayerState.character_generation`(플레이어 파일 스키마 v3), `SurvivalNetModule`/`ClientSurvivalState`(본인 스냅샷에 세대 번호), HUD. `network_service.gd`는 수정하지 않았다. 새 RPC는 없다. 본인 스냅샷과 접속 조각의 형식이 바뀌었고(아래), 프로토콜 버전은 P2-T3에서 올린 5를 그대로 쓴다(같은 브랜치에서 한 번만 올림).

#### 사망 순간

`SurvivalService._mark_dead`(전투 피해 `apply_damage`, 생존 규칙의 시간 피해, 감염 좀비화 모두 이 한 곳을 지난다)가 순서대로 한다: 체력 0과 사망 시각(달력·행동) 기록 → 아직 내보내지 않은 시간 피해 이벤트 → **소지품 전부를 그 플레이어의 서버 위치에 내려놓기**(`ServerWorld.drop_all_player_items`, §14.17의 `drop_all_items` 트랜잭션 한 번) → `player_died` 이벤트.

- 내려놓는 시점은 **사망 즉시**다(새 캐릭터가 시작될 때가 아니다). 이유: (1) 대기 시간 동안에도 다른 플레이어가 그 자리의 아이템을 보고 주울 수 있다. (2) "죽은 캐릭터는 아무것도 들고 있지 않다"가 사망 순간부터 성립하므로, 죽은 채 접속을 끊거나 서버가 저장·재시작되어도 소지품이 두 번 떨어지거나 사라질 중간 상태가 없다.
- 위치는 `clamp_to_world(플레이어 위치)`, 셀은 `DevWorldSeed.DEV_CELL_ID`(§14.17과 같다). 한 점에 겹쳐 놓인다. 묶음은 나뉘지 않고, 아이템 수는 보존된다(생성·삭제 없음).
- 복제와 저장은 `InventoryNet`이 한다(§14.17): 트랜잭션이 확정되는 자리에서 소유자에게 `_rpc_inventory_items_removed`, 이어서 모든 peer에게 `_rpc_world_items_added`를 보내고, 그 서버 틱 끝에 월드를 저장한다. 생존 이벤트(`player_wounded`, `player_died`)는 그 틱의 `server_physics`에서 나가므로 클라이언트는 "인벤토리 비워짐 → 월드 아이템 → 사망" 순서로 받는다. 빈손으로 죽으면 트랜잭션이 없어 그 틱에 저장되지 않는다(사망 상태는 다음 저장에 들어간다).
- 오프라인 플레이어가 서버 규칙으로 죽어도(`apply_damage`는 접속 여부를 보지 않는다) 똑같이 내려놓는다.
- `apply_damage`에는 월드 인자가 없으므로 `SurvivalService`는 등록될 때(`ServerSystem.on_registered(world)`, `ServerWorld.register_system`이 호출) 월드의 **약한 참조**를 보관한다(월드가 시스템을 소유하므로 강한 참조는 순환이 된다). 월드에 등록되지 않은 채 쓰이면 내려놓지 못하고 오류 로그를 남기며, 그 경우에도 아래 "새 캐릭터 시작"이 한 번 더 내려놓는다.

#### 죽어 있는 동안

- 죽은 캐릭터는 아이템을 줍거나 내려놓을 수 없다. `ServerSystem.player_action_block_reason(player_id) -> String`(기본 `""`)을 `SurvivalService`가 구현해 죽은 플레이어에게 `player_dead`를 돌려주고, `ServerWorld.try_pickup`/`try_drop_item`이 모든 시스템에 물어 첫 사유로 거부한다(`ServerWorld.player_action_block_reason`). 그래서 줍기 RPC의 결과 사유에 `player_dead`가 추가됐다(Phase 1 줍기 계약의 확장. `network_service.gd`는 그대로이고 `try_pickup`의 반환 사유를 그대로 전한다). 소비 의도는 `ItemConsumption`이, 내려놓기 의도는 `InventoryNetModule`이 먼저 같은 사유로 거부한다(§14.17, §14.18). 서버 규칙용 래퍼(`drop_all_player_items`, `remove_player_item`)는 이 검사를 하지 않는다.
- 이동 배율 0, 욕구·피해·회복 정지(§14.6)는 그대로다. 위치는 죽은 자리에 남는다.
- 대기 시간은 `SurvivalSettings.respawn_delay_sec`(행동 시간, 기본 10초)이고 기한은 `died_at_action_time + respawn_delay_sec`다(§14.16). 시간 규칙은 접속 중인 플레이어에게만 돌므로, 죽은 채 접속을 끊으면 아무 일도 일어나지 않고 기한이 지난 뒤 다시 접속하면 접속 직후 첫 서버 틱에 새 캐릭터가 시작된다(접속 스냅샷에는 아직 죽은 상태로 들어간다).

#### 새 캐릭터 시작

`SurvivalService._start_new_character`가 `ServerWorld.start_new_character(player_id) -> ActionResult`를 부른 뒤 생존 상태를 초기화한다.

| 단계 | 내용 |
|---|---|
| `ServerWorld.start_new_character` | (1) 아직 들고 있는 것이 있으면 지금 위치(죽은 자리)에 전부 내려놓는다. 보통은 없다. P2-T4 이전 규칙으로 저장된 "소지품을 든 죽은 플레이어"와 내려놓기가 실패한 경우를 위한 안전망이며, 그래서 새 캐릭터는 항상 빈 인벤토리로 시작한다. (2) 위치를 `clamp_to_world(GameplaySettings.player_spawn_position)`으로, (3) 이전 이동 입력을 버리고, (4) `PlayerState.character_generation`을 1 올린다. 성공 이벤트 `{event_type: "character_started", player_id, character_generation, position: [x, y, z], dropped_item_instance_ids}`. 실패: `unknown_player`, 내려놓기 실패 사유(아무것도 바뀌지 않음). 예전의 `respawn_player_at_spawn`을 대체한다 |
| 생존 상태 | 체력·스태미나 최대, 허기·갈증·피로는 `respawn_hunger`/`respawn_thirst`/`respawn_fatigue`(기본 0), 상처 전부 제거, 감염 없음, 사망 시각 해제. 플레이어별 감염 RNG는 이어진다 |
| 이벤트 | `player_respawned`(이름과 복제 형식은 그대로, §14.14) + 서버 쪽 필드 `character_generation`. 이 필드는 복제 DTO에 없다(허용 목록 방식이라 타인·본인 이벤트 어느 쪽에도 나가지 않는다) |

- 시작 소지품은 없다(아이템을 인벤토리에 바로 만들어 주는 트랜잭션이 없다, docs/15 P2-119).
- 새 캐릭터 시작은 그것만으로 저장하지 않는다. 다음 저장에 들어간다. 그 전에 서버가 비정상 종료하면 "죽은 상태"로 복구되고 남은 대기 시간 뒤 같은 세대 번호로 다시 시작한다(소지품은 사망 때 이미 월드에 저장됐다).

#### 캐릭터 식별

- `player_id`는 접속 신원이고 죽어도 바뀌지 않는다. 인벤토리 컨테이너(`inventory_id`)도 그대로 쓴다.
- `PlayerState.character_generation`(정수, 첫 캐릭터 1, 새 캐릭터마다 +1)이 "그 플레이어의 몇 번째 캐릭터인지"다. `(player_id, character_generation)`이 캐릭터 하나를 가리킨다. 이후 NPC 관계 등이 캐릭터 단위로 붙을 수 있게 하는 최소 장치이며 임시안이다(docs/15 P2-128).
- 저장: players/<id>.json 스키마 v3이 `character_generation`을 추가한다. v2 → v3 마이그레이션은 1을 넣는다(`SaveMigrations.player_v2_to_v3`). 현재 스키마 문서에 이 값이 없거나 1 미만·정수가 아니면 그 플레이어 문서는 거부된다.
- 복제: 본인 스냅샷(§14.14의 owner snapshot)에 `character_generation: int ≥ 1`이 추가됐고 접속 조각과 본인 스냅샷의 `schema_version`이 2가 됐다. 이 값이 없거나 형식이 틀린 스냅샷은 클라이언트가 통째로 버린다. `ClientSurvivalState.character_generation() -> int`(아직 받은 것이 없으면 0). 다른 플레이어에게는 보내지 않는다: 다른 클라이언트는 기존대로 `player_died`(원인 없음)와 `player_respawned`(위치)만 받는다.

#### 저장과 이전 저장

- 사망 대기 중 저장 → 재시작: 죽은 플레이어(체력 0, 사망 시각), 빈 인벤토리, 월드에 놓인 소지품, 세대 번호가 그대로 복구되고, 다시 접속하면 남은 대기 시간이 흐른 뒤 새 캐릭터가 시작된다(행동 시각 기한, §14.16).
- P2-T4 이전 저장의 죽은 플레이어(인벤토리를 들고 있음): 그대로 로드되고, 접속 뒤 새 캐릭터가 시작될 때 소지품이 그 자리에 한 번 떨어진다.
- 결함 수정(P2-T1 보고의 추정 결함, 실제 결함으로 확인): 생존 fragment v1(B3 이전)에는 사망 시각이 없다. 그런 죽은 플레이어를 로드한 뒤 그 플레이어가 한 번도 접속하지 않은 채 월드를 다시 저장하면 "체력 0 + 사망 시각 없음"인 현재 버전 fragment가 쓰였고, 다음 로드가 `health/death timestamp mismatch`로 월드 복구를 거부했다. `SurvivalService.restore_player_fragment`가 사망 시각 없는 죽은 플레이어에게 복구된 달력 시각을 넣도록 고쳤다(행동 사망 시각은 비워 두어 대기 시간은 다음 접속 순간부터 센다, §14.16과 같다). 재현 테스트: `permanent_death_test.gd::test_a_dead_player_of_a_v1_fragment_can_be_saved_again_before_logging_in`.

클라이언트 표시: 생존 HUD 첫 줄에 "캐릭터 #N"(본인 미러가 세대 번호를 받은 뒤에만), 사망 안내 문구를 "캐릭터가 끝났고 새 캐릭터로 시작한다"는 내용으로 바꿨다(`ClientPresentationSettings.death_message`).

테스트: `tests/unit/permanent_death_test.gd`(사망 즉시 소지품이 죽은 위치에·총수 보존·한 트랜잭션, 생존 규칙 사망과 오프라인 사망, 월드 경계, 새 캐릭터의 위치·빈 인벤토리·초기 상태·세대 증가·이벤트, 죽은 캐릭터의 줍기·내려놓기 거부와 다른 플레이어의 줍기, 사망 중 퇴장·재접속, 사망 대기 중 저장 → 재시작, 이전 규칙 저장, 세대 번호 저장·마이그레이션·검증, v1 fragment 결함, 본인 미러의 세대 번호), `tests/integration/permanent_death_net_test.gd`(서버 1 + 클라이언트 2, 실제 ENet: 사망 → 두 클라이언트가 같은 위치의 월드 아이템을 봄·소유자만 인벤토리 메시지를 받음·죽은 플레이어의 줍기 거부 → 새 캐릭터(본인만 세대 2를 앎) → 다른 플레이어와 새 캐릭터가 각각 줍기, 사망 중 퇴장 → 재접속, 사망 상태 저장 → 서버 재시작 → 재접속), `tests/unit/client_presentation_test.gd`(HUD 세대 줄과 사망 안내).
