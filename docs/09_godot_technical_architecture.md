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
- GDScript 런타임 오류는 함수만 중단되고 예외가 없으므로, `tools/run_tests.sh`가 출력에서 `SCRIPT ERROR`/`ERROR:`/`[ERROR]`/`[FATAL]`을 발견하면 실패 처리한다.

### 14.5 Phase 2 확장 지점(P2-0)

Phase 2 기능은 아래 seam으로만 끼워 넣는다. `network_service.gd`는 P2-0 이후 기능 작업에서 수정하지 않는다(동결). `server_world.gd`는 Phase 2 동안 B묶음(생존)만 수정한다.

| 구성 요소 | 파일 | 계약 |
|---|---|---|
| `WorldClock` / `WorldClockSettings` | `scripts/core/world_clock.gd`, `world_clock_settings.gd`, `data/tuning/world_clock_settings.tres` | 서버 권한 월드 시간(초). `step(real_delta, any_online) -> world_delta`, 접속자 0명이면 일시정지(설정). world_state `world_time_sec`로 저장 |
| `BucketScheduler` | `scripts/core/bucket_scheduler.gd` | `new(period_sec, bucket_count)`, `add/remove/has/size/bucket_of`, `advance(delta) -> PackedStringArray`. 등록 순서 라운드로빈(결정론), 주기당 각 id 정확히 1회, 한 호출에서 같은 id 중복 없음 |
| `ServerSystem` | `scripts/services/world/server_system.gd` | `get_system_id()`(필수, snake_case), `seed_new_world(world)`, `step(world, real_delta, world_delta)`(매 서버 physics tick), `on_player_online/offline(world, player_id)`, `player_movement_multiplier(player_id)`(기본 1.0, 서버 이동 속도 배율: 모든 시스템 값의 곱을 0~1로 제한), `to_world_document()`/`restore_world_document(doc)`, `to_player_fragment(player_id)`/`restore_player_fragment(player_id, doc)`. 문서는 JSON-safe + `schema_version` |
| `ServerWorld` seam | `scripts/services/world/server_world.gd` | `register_system(system) -> Error`, `get_system(id)`, `system_ids()`, `clock`, `step_systems(real_delta) -> world_delta`. 저장: world_state `systems.{id}`, players/<id>.json `systems.{id}`. 저장에 없는 시스템은 기본값 유지, 등록되지 않은 시스템 데이터는 경고 후 무시 |
| `NetModule` | `scripts/services/multiplayer/net_module.gd` | `NetworkService`의 자식 노드(모든 peer에서 같은 `name`). 훅: `on_server_started(world)`, `on_player_joined/left(peer_id, player_id)`, `server_physics(delta)`, `build_join_fragment(player_id)`(서버), `apply_join_fragment(fragment)`(클라이언트). 자체 `@rpc` 메서드 사용 |
| `NetworkService` 공개 헬퍼 | `scripts/services/multiplayer/network_service.gd` | `register_module(module)`(시작 전만), `get_module(name)`, `is_server()`, `is_client()`, `is_from_server()`, `sender_player_id()`, `joined_peers()`, `peer_of_player(id)`, `player_of_peer(peer)`, `can_send_to(peer)`, `reject_intent(peer, intent, reason, player_id)`, `count_rejection(reason)`, `rejected_intent_count(reason)`, `persist(reason)`, `get_world()`, `get_settings()` |
| `ServerComposition` / `CompositionConfig` | `scripts/core/server_composition.gd`, `composition_config.gd` | 시스템/모듈 조립의 유일한 장소. `create_world(world_id, config)`, `install_net_modules(service, config)`. `WorldPersistence`, `GameBootstrap`, `NetTestCluster`가 모두 사용 |
| 저장 마이그레이션 | `scripts/services/save/save_migrations.gd` | world_state v1→v2(`world_time_sec`, `systems` 추가), player v1→v2(`systems` 추가). `SaveService` 기본 마이그레이터 |

채널: 0 reliable ordered, 1 unreliable ordered(플레이어 이동), 2 unreliable ordered(AI 엔티티 스냅샷, A묶음 예약). `PROTOCOL_VERSION` = 3(P2-0에서 2, N1 묶음 ZombieNet·SurvivalNet·CombatNet 병합 때 3).

### 14.6 생존 계약(B1, system id `survival`)

`scripts/domain/survival/`: `BodyPart`(10부위, 저장 이름), `Wound`(bruise/laceration/fracture/burn/bite/scratch, severity 0~1), `DamageInput`(서버가 만든 피해: source_id, body_part, wound_type, amount), `InfectionState`(단계 none~zombified, 노출 bite/scratch/blood), `PlayerVitals`(players/<id>.json `systems.survival`), `SurvivalSettings`(`data/tuning/survival_settings.tres`), `SurvivalService`(ServerSystem).

다른 시스템은 `world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService`로 얻어 아래만 호출한다(반환된 PlayerVitals는 읽기 전용): `is_alive`, `try_spend_stamina`, `handling_multiplier`, `movement_speed_multiplier`, `apply_damage(player_id, DamageInput) -> ActionResult`, `stop_bleeding(player_id, wound_id) -> ActionResult`, `apply_infection_exposure(player_id, InfectionState.Exposure, source_id) -> ActionResult`, `apply_infection_treatment(player_id, source_id) -> ActionResult`, `infection_stage(player_id) -> InfectionState.Stage`, `has_player`, `get_vitals`. 이벤트 형식과 실패 사유 코드는 `survival_service.gd` 상단 주석이 기준이다. B2에서 `need_category(player_id, NeedKind.Kind)`, `worst_need_category(player_id)`가 추가됐다(`NeedKind`: 허기/갈증/피로와 양호/주의/위험 범주).

B3에서 `Wound.is_bleeding`과 `PlayerVitals.died_at_world_time`을 저장 상태로 추가하고 생존 fragment 스키마를 v2로 올렸다(v1은 새 필드 기본값으로 읽음). `step`은 접속 중인 플레이어에게만 월드 시간을 적용한다. 생존 중에는 욕구 증가, 출혈 피해, 허기/갈증 최대치 피해, 조건부 체력·상처 회복을 처리하고, 사망 중에는 욕구/피해/회복을 멈춘 채 리스폰 시각만 판정한다. 모든 욕구가 `GOOD`이고 출혈이 없을 때만 체력과 상처 severity가 회복되며 severity 0 상처는 제거된다. 체력 0은 사망 시각을 남기고 `player_died`를 로그에 기록하며(`apply_damage` 결과는 B1 계약대로 `player_wounded` + `died: true`) 설정 지연 뒤 `ServerWorld.respawn_player_at_spawn`으로 설정 스폰 위치를 복원하면서 이전 이동 입력을 제거한다. 인벤토리/RNG는 유지하고 vitals·욕구·상처·감염은 설정값으로 초기화한다. 연속 구간을 욕구 임계·사망·리스폰 경계에서 적분하므로 틱 크기와 무관하다(허용 오차 1e-3). B3 임시 수치는 docs/15 P2-13~P2-17에 기록한다.

B4에서 `InfectionState.stage_elapsed_world_sec`를 추가하고 생존 fragment 스키마를 v3으로 올렸다(v1/v2는 경과 시간 0으로 읽음). 서버는 접속 중이고 생존한 플레이어의 활성 월드 시간만 누적해 `LATENT → EARLY → PROGRESSING → SEVERE → TERMINAL → ZOMBIFIED`를 진행한다. 각 단계 시간과 감염 경로별 시간 배율은 `SurvivalSettings`에서 읽으며 감염 단계 경계를 B3의 구간 적분 경계에 포함한다. `ZOMBIFIED` 진입 즉시 원인 `infection`으로 사망시키고 플레이어 좀비는 만들지 않으며, 기존 리스폰이 감염을 해제한다. 단계 변화는 `player_infection_stage_changed` 로그(`player_id`, `from`, `to`, `world_time`)로 남긴다.

단계별 스태미나 회복 배율은 기존 욕구 배율과 곱하고, 단계별 체력 감소율은 출혈·굶주림·탈수 피해와 합산한다. 양수인 감염 체력 감소가 적용되는 동안에는 자연 회복을 허용하지 않는다. 치료 seam `apply_infection_treatment(player_id, source_id)`는 설정된 최대 단계 이하에서 감염을 해제하고 `player_infection_cured`를 반환·기록하며, 아이템·품질·의료 능력 판정은 후속 티켓 소유다. 읽기 전용 `infection_stage(player_id)`는 현재 단계를 반환한다. 임시 수치는 docs/15 P2-7/P2-8/P2-18/P2-19에 기록한다. 감염 복제(B5), 섭취/수면(B6)은 아직 없다.

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
| `query_audible(position, hearing_multiplier, since_world_time) -> Array[NoisePerception]` | 지금 그 위치에서 들리는 소음을 센 순서(같으면 발생 순서)로 돌려준다. `event_time > since_world_time`인 것만 포함(`NoiseService.SINCE_ALWAYS` = 전부). 잘못된 입력(NaN, 경계 밖, 배율 0 이하)은 빈 목록. 반환된 `event`는 읽기 전용 |
| `max_audible_distance(loudness, hearing_multiplier) -> float` | 방금 난 소리가 들리는 최대 거리(음수 = 들리지 않음) |
| `purge_expired() -> int`, `active_count()`, `get_event(noise_id)`, `set_occlusion(provider)` | 만료 정리(평소에는 `step`이 호출), 진단, 차폐 구현 교체 |

- 세기 모델과 수치는 docs/15 P2-20. 시간 감쇠·만료는 월드 시간 기준이라 월드 시계가 멈춘 동안(접속자 0명)에는 줄지도 사라지지도 않는다. 만료된 소음은 정리 전이라도 조회에 나오지 않는다.
- 공간 조회: 소음은 XZ 평면 해시 격자(기본 16m)의 한 칸에 들어간다. 조회는 듣는 쪽 칸에서 "지금 가장 큰 소음이 들릴 수 있는 거리"만큼의 이웃 칸만 훑고, 그 후보 목록을 (칸, 범위)별로 캐시한다. 같은 칸에 있는 다른 청취자는 소음이 추가·삭제되기 전까지 캐시를 다시 쓴다(무리 지은 좀비 N마리가 칸 훑기 1번을 공유, docs/02 §6.3). 점유 칸 수가 이웃 칸 수보다 적으면 점유 칸만 훑는다. `query_audible_brute_force`는 격자 없이 전부 검사하는 기준 구현이며 테스트가 두 결과가 같은지 비교한다.
- 저장하지 않는다(`to_world_document()`는 빈 문서). 이유와 ID 형식은 docs/15 P2-23. 다른 시스템이 저장 문서에 `noise_id`를 넣으면 안 되고, 필요하면 위치·시간을 복사해 저장한다.
- 소음을 내는 호출자: 근접 공격(`CombatService`, §14.10)이 휘두를 때마다, 플레이어 이동(`PlayerNoiseService`, §14.11)이 보폭마다 `emit`을 호출한다.

### 14.9 좀비 계약(P2-A2, system id `zombie`)

`scripts/domain/zombie/`: `ZombieState`(좀비 한 마리의 저장 가능한 상태), `ZombiePerception`(노드 없는 시야·방향 규칙), `ZombieSettings`(`data/tuning/zombie_settings.tres`), `ZombieService`(ServerSystem). 네트워크 코드는 없다. 등록 순서는 `survival` → `noise` → `zombie`이며 좀비는 앞의 둘을 `world.get_system`으로 얻어 쓴다. 임시 가정은 docs/15 P2-24~P2-32.

상태(`ZombieState.STATE_NAMES`, docs/02 §6.1): `idle`(대기/배회), `investigate`(소리 조사·피격 방향 확인), `chase`(시각 추적/추격), `attack`(사거리 안), `search`(대상 상실 후 수색), `dormant`(필드만), `dead`(시체, 일정 시간 뒤 제거). 흐름: idle → (소음) investigate → (도착/시간 초과) search → (시간 초과) idle, 어느 상태든 대상이 보이면 chase → 사거리 안이면 attack, 대상을 놓치면 search.

주기: 이동 적분은 살아 있는 모든 좀비에 대해 매 서버 틱, AI 판단(감지·상태 전환·공격)은 좀비마다 `ai_period_sec`에 한 번 `BucketScheduler`로 분산하고 한 틱에 `max_ai_updates_per_tick`개까지만 처리한다(나머지는 대기열에서 다음 틱으로). 피격된 좀비는 대기열 맨 앞에 들어간다. 모든 시간은 월드 시간이라 시계가 멈추면 아무 일도 일어나지 않는다. yaw는 플레이어와 같은 규약(0 = −Z, 전방 = (−sin, 0, −cos), `Node3D.rotation.y`)이다.

| API | 계약 |
|---|---|
| `spawn_zombie(world, position, yaw = 0.0) -> ActionResult` | `EntityIdGenerator`로 `zombie_<순번>` 발급, `EntityRegistry`에 kind `zombie`로 등록. 위치는 월드 경계로 clamp. 실패: `bad_zombie_position`(NaN/무한), `zombie_limit`(상한), `zombie_id_failed` |
| `apply_damage_to_zombie(zombie_id, amount, source_id) -> ActionResult` | 근접 전투(C1)가 호출. 성공 이벤트 `{event_type: "zombie_damaged", zombie_id, source_id, damage, health_after, died, world_time}`. 체력 0이면 `dead`. 살아 있으면 다음 판단에서 `source_id`(접속 중인 생존 플레이어일 때)를 향해 돌아보고, 보이면 추격, 안 보이면 그 위치를 조사한다. 실패: `unknown_zombie`, `zombie_dead`, `bad_damage_amount`(NaN/무한/0 이하), `bad_damage_source`(빈 ID) |
| `snapshot_rows() -> Array[Dictionary]` | 네트워크용 읽기 전용. 스폰 순서로 `{id: String, position: Vector3, yaw: float, state: String, health_fraction: float(0~1)}`. 시체는 제거 전까지 `state: "dead"`로 포함 |
| `drain_events() -> Array[Dictionary]` | 네트워크용 읽기 전용. 지난 호출 이후 쌓인 이벤트를 오래된 순으로 돌려주고 비운다(최대 `max_pending_events`개 보관) |
| `has_zombie`, `get_zombie(id) -> ZombieState`(읽기 전용), `zombie_ids()`, `zombie_count()`, `living_count()` | 조회 |

이벤트(모두 `event_type`, `zombie_id`, `world_time` 포함, 위치는 `[x, y, z]`, JSON-safe):

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
- 테스트: `tests/unit/zombie_perception_test.gd`, `tests/unit/zombie_service_test.gd`(고정 seed 시나리오, 시야/소리 구분, 수색 복귀, 사망·오프라인 대상 제외, 저장→재생성→로드, 결정론, 월드 3시간 가속 soak, 잘못된 입력).

### 14.10 근접 전투 계약(P2-C1, system id `combat`)

`scripts/domain/combat/`: `MeleeWeaponDefinition`(무기 한 종류의 정적 정의 Resource), `MeleeWeaponCatalog`(무기 ID·아이템 ID로 찾는 읽기 전용 목록, `resources/definitions/melee_weapons/*.tres`를 읽음), `MeleeHitRules`(노드 없는 판정 규칙: 호 안 여부, 대상 선택, 피해 계산), `CombatSettings`(`data/tuning/combat_settings.tres`), `CombatService`(ServerSystem). 네트워크 코드는 없다. 등록 순서는 `survival` → `noise` → `player_noise`(§14.11) → `zombie` → `combat`이며 전투는 `survival`·`noise`·`zombie`를 `world.get_system`으로 얻어 쓴다. `CompositionConfig`에 `combat`, `melee_weapons` 필드가 추가됐고 `validate()`가 무기 목록을 아이템 목록·소음 설정과 대조한다. 임시 가정은 docs/15 P2-40~P2-47.

클라이언트가 보낼 수 있는 것은 "누가(`player_id`, 네트워크 계층이 peer에서 구함) 어느 방향으로(`aim_yaw`) 휘둘렀다"뿐이다. 위치·대상·무기·피해·명중 여부·사망은 모두 서버 상태에서 정한다(docs/02 §5.2).

| API | 계약 |
|---|---|
| `request_melee_attack(world, player_id, aim_yaw) -> ActionResult` | N1의 RPC 핸들러가 부르는 진입점. 아래 순서로 검증하고 하나라도 실패하면 아무것도 바뀌지 않는다(스태미나·쿨다운·RNG·소음·이벤트 모두). 성공하면 `melee_attack` 이벤트를 돌려주고 같은 이벤트를 큐에 넣는다 |
| `weapon_for(world, player_id) -> MeleeWeaponDefinition` | 지금 공격하면 쓰일 무기(없는 플레이어는 null). 표시용 조회 |
| `cooldown_remaining(player_id) -> float` | 다음 공격까지 남은 월드초(0 = 가능) |
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
| `attack_on_cooldown` | 직전 공격의 쿨다운(월드 시간)이 남음 |
| `not_enough_stamina` | 스태미나가 무기 비용보다 적음(`SurvivalService.try_spend_stamina`가 마지막 검사이자 차감) |

승인된 공격의 처리:

- 무기: `CombatSettings.inventory_weapon_rule`에 따라 플레이어 인벤토리의 아이템 중 `MeleeWeaponDefinition.item_definition_id`와 일치하는 것을 찾는다. `HIGHEST_DAMAGE`(기본, 기본 피해가 가장 큰 무기·같으면 무기 ID가 작은 것), `FIRST_SLOT`(슬롯 번호가 가장 작은 무기 아이템), `UNARMED_ONLY`(항상 맨손). 해당 아이템이 없으면 `unarmed_weapon_id`(맨손)이다. 장비 슬롯은 아직 없다.
- 대상: 서버가 가진 플레이어 위치와 `aim_yaw`(플레이어에 저장된 `yaw`는 쓰지도 바꾸지도 않는다)를 기준으로, 무기 사거리(`range_m`) 안이고 조준 방향을 중심으로 한 호(`arc_angle_deg`, 전체 각) 안에 있는 **살아 있는 좀비 중 가장 가까운 1마리**. 거리가 같으면 좀비 ID가 작은 쪽. XZ 평면에서만 계산하며 yaw 규약은 플레이어·좀비와 같다(0 = −Z). 플레이어는 대상이 되지 않는다(PvP 비활성, docs/00).
- 피해: `무기 base_damage × SurvivalService.handling_multiplier(player) × uniform(damage_roll_min, damage_roll_max)`. 난수는 전투 RNG(seed = `CombatSettings.rng_seed`, 상태 저장)이고 **대상이 있는 공격에서만** 한 번 뽑는다. 적용은 `ZombieService.apply_damage_to_zombie(target, damage, player_id)`이므로 맞은 좀비는 좀비 계약(§14.9)대로 공격자를 인지한다.
- 빗나가도(대상 없음) 스태미나를 쓰고 쿨다운이 시작되며 소음이 난다. 소음은 `NoiseService.emit(player_id, 플레이어 위치, 무기 noise_loudness, 무기 noise_frequency_profile)`이고 `noise_loudness`가 0이면 내지 않는다.
- 쿨다운은 플레이어별 "다음 공격 가능 월드 시각"으로 기억한다. 접속을 끊었다 다시 들어와도 초기화되지 않는다.

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
| `world_time` | 월드 시각 |

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
| 월드 시계 정지(`world_delta` = 0) | 소음 없음. 정지 중에 움직인 거리는 나중에도 세지 않는다 |
| 순간이동: `teleport_speed_mps`(15m/s)보다 빠른 위치 변화(리스폰, 관리자 이동 등) | 소음 없음, 걸은 거리를 0으로 되돌린다 |
| `footstep_loudness` = 0, 또는 소음 시스템 미등록 | 전체 비활성 |

- 속도는 `real_delta`로 계산한다(`ServerWorld.step_movement`가 실제 초 단위로 이동을 적분하기 때문). 소음의 시각·감쇠는 소음 시스템대로 월드 시간이다.
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

접속 조각(`snapshot.modules.SurvivalNet`) 스키마 버전은 1이다.

```text
{
  schema_version: 1,
  self: <owner snapshot>,
  players: [{player_id: String, alive: bool}, ...]  # 접속 중인 전 플레이어
}

owner snapshot = {
  schema_version: 1, player_id: String, alive: bool,
  health: float, stamina: float,
  needs: {hunger: "good|caution|danger", thirst: ..., fatigue: ...},
  wounds: [Wound.to_dict(), ...],
  infection_stage: "none|latent|early|progressing|severe|terminal|zombified"
}
```

공개 범위는 docs/15 P2-9를 따른다. `scope: "owner"` 이벤트는 대상 본인에게만 가며 체력 변화, 상처 상세, 지혈, 생존 피해, 욕구 범주, 감염/저항/단계 변화/치료를 포함할 수 있다. `scope: "public"`은 타인에게만 가며 아래 세 종류뿐이다.

| 공개 이벤트 | 필드(`scope`, `event_type`, `player_id` 공통) |
|---|---|
| `player_wounded` | `body_part`, `wound_type`, `died`, `world_time` |
| `player_died` | `world_time`(원인 제외: 감염 사망 노출 방지) |
| `player_respawned` | `position: [x,y,z]`, `world_time` |

타인용 DTO에는 체력·피해 수치, wound 상세/심각도, 욕구, 감염 여부·단계·노출·원인을 넣지 않는다. `SurvivalService.drain_events()`는 JSON-safe 이벤트를 발생 순서로 반환하고 비우며, 설정 상한을 넘으면 좀비/전투 큐와 같이 가장 오래된 것부터 버리고 `dropped_event_count`를 올린다. `apply_damage`의 기존 `player_wounded` ActionResult 계약은 유지한다.

`ClientSurvivalState`는 권한 없는 순수 미러다. 공개 API는 `health()`, `stamina()`, `need_category(kind)`, `wounds()`, `infection_stage()`, `has_player(id)`, `is_alive(id)`, `last_respawn_position(id)`, `recent_events()`이며 변경 알림은 `changed`, `own_vitals_changed`, `player_alive_changed`, `event_received`, `player_respawned` 시그널이다. 최근 이벤트 목록은 설정된 개수만 보관한다. 수치는 `data/tuning/survival_net_settings.tres`와 `survival_settings.tres`에 있고 임시 결정은 docs/15 P2-70~P2-74다.

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
