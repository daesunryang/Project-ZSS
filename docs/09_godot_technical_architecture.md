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
| `ServerSystem` | `scripts/services/world/server_system.gd` | `get_system_id()`(필수, snake_case), `seed_new_world(world)`, `step(world, real_delta, world_delta)`(매 서버 physics tick), `on_player_online/offline(world, player_id)`, `to_world_document()`/`restore_world_document(doc)`, `to_player_fragment(player_id)`/`restore_player_fragment(player_id, doc)`. 문서는 JSON-safe + `schema_version` |
| `ServerWorld` seam | `scripts/services/world/server_world.gd` | `register_system(system) -> Error`, `get_system(id)`, `system_ids()`, `clock`, `step_systems(real_delta) -> world_delta`. 저장: world_state `systems.{id}`, players/<id>.json `systems.{id}`. 저장에 없는 시스템은 기본값 유지, 등록되지 않은 시스템 데이터는 경고 후 무시 |
| `NetModule` | `scripts/services/multiplayer/net_module.gd` | `NetworkService`의 자식 노드(모든 peer에서 같은 `name`). 훅: `on_server_started(world)`, `on_player_joined/left(peer_id, player_id)`, `server_physics(delta)`, `build_join_fragment(player_id)`(서버), `apply_join_fragment(fragment)`(클라이언트). 자체 `@rpc` 메서드 사용 |
| `NetworkService` 공개 헬퍼 | `scripts/services/multiplayer/network_service.gd` | `register_module(module)`(시작 전만), `get_module(name)`, `is_server()`, `is_client()`, `is_from_server()`, `sender_player_id()`, `joined_peers()`, `peer_of_player(id)`, `player_of_peer(peer)`, `can_send_to(peer)`, `reject_intent(peer, intent, reason, player_id)`, `count_rejection(reason)`, `rejected_intent_count(reason)`, `persist(reason)`, `get_world()`, `get_settings()` |
| `ServerComposition` / `CompositionConfig` | `scripts/core/server_composition.gd`, `composition_config.gd` | 시스템/모듈 조립의 유일한 장소. `create_world(world_id, config)`, `install_net_modules(service, config)`. `WorldPersistence`, `GameBootstrap`, `NetTestCluster`가 모두 사용 |
| 저장 마이그레이션 | `scripts/services/save/save_migrations.gd` | world_state v1→v2(`world_time_sec`, `systems` 추가), player v1→v2(`systems` 추가). `SaveService` 기본 마이그레이터 |

채널: 0 reliable ordered, 1 unreliable ordered(플레이어 이동), 2 unreliable ordered(AI 엔티티 스냅샷, A묶음 예약). `PROTOCOL_VERSION` = 2.

### 14.6 생존 계약(B1, system id `survival`)

`scripts/domain/survival/`: `BodyPart`(10부위, 저장 이름), `Wound`(bruise/laceration/fracture/burn/bite/scratch, severity 0~1), `DamageInput`(서버가 만든 피해: source_id, body_part, wound_type, amount), `InfectionState`(단계 none~zombified, 노출 bite/scratch/blood), `PlayerVitals`(players/<id>.json `systems.survival`), `SurvivalSettings`(`data/tuning/survival_settings.tres`), `SurvivalService`(ServerSystem).

다른 시스템은 `world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService`로 얻어 아래만 호출한다(반환된 PlayerVitals는 읽기 전용): `is_alive`, `try_spend_stamina`, `handling_multiplier`, `movement_speed_multiplier`, `apply_damage(player_id, DamageInput) -> ActionResult`, `apply_infection_exposure(player_id, InfectionState.Exposure, source_id) -> ActionResult`, `has_player`, `get_vitals`. 이벤트 형식과 실패 사유 코드는 `survival_service.gd` 상단 주석이 기준이다. B2에서 `need_category(player_id, NeedKind.Kind)`, `worst_need_category(player_id)`가 추가됐다(`NeedKind`: 허기/갈증/피로와 양호/주의/위험 범주). `step`은 접속 중인 생존 플레이어의 욕구를 월드 시간으로 올리고, 가장 나쁜 범주가 스태미나 회복과 `movement_speed_multiplier`를 낮춘다(docs/15 P2-12). 출혈·회복·리스폰·굶주림 피해(B3), 감염 단계 진행(B4), 복제(B5), 섭취/수면(B6)은 아직 없다.

테스트 더블: `tests/framework/test_counter_system.gd`, `tests/framework/test_echo_module.gd`(배포 코드 아님). `NetTestCluster.extra_module_factories`로 테스트 전용 모듈을 추가할 수 있다.

### 14.7 P1-4 클라이언트 카메라/입력

- `ClientView`는 클라이언트 역할에서만 생성되며 `GameBootstrap.get_network()`의 `ClientWorldState`를 구독한다. 서버 headless 경로는 해당 신/스크립트/설정을 로드하지 않는다.
- `CameraOrbitMath`, `InputIntentMath`, `MoveIntentSender`는 노드 없는 `RefCounted`로 카메라 각도/위치, 카메라 기준 월드 XZ 방향, 입력 데드존/정규화, 전송 주기를 계산한다.
- 이동 RPC는 입력 변경 시 즉시, 유지 시 0.2초 주기, 정지 시 `Vector2.ZERO` 1회만 전송한다. 클라이언트가 전송하는 값은 월드 XZ 방향과 yaw뿐이며 위치·속도·시간은 전송하지 않는다.
- 입력 액션은 `ClientInputActions`가 코드로 등록하며, 기존 액션은 덮어쓰거나 바인딩을 중복 추가하지 않는다. 키·데드존·전송 기준은 `data/tuning/camera_settings.tres`에 있다.
- 플레이어는 `ClientWorldState.players`의 서버 위치에 캡슐로 표시하고 로컬/원격 색을 구분한다. 줍기는 로컬 위치에서 가장 가까운 미러 아이템 ID만 `request_pickup`으로 보내고 거리/획득 판정은 서버에 남겨 둔다.
