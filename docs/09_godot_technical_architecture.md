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

채널: 0 reliable ordered, 1 unreliable ordered(플레이어 이동), 2 unreliable ordered(AI 엔티티 스냅샷, A묶음 예약). `PROTOCOL_VERSION` = 2.

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
- 아직 소음을 내는 호출자는 없다. 플레이어 이동·전투가 `emit`을 호출하는 것은 후속 티켓(C1/N1)이다.

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
