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

게임 인자(`--` 뒤): `--server`, `--client`, `--log-level=<LEVEL>`, `--world-id=<id>`, `--run-frames=<N>`(N 프레임 후 정상 종료, 0=무한), `--run-seconds=<S>`, `--port=<N>`, `--connect=<host[:port]>`(클라이언트, `--player-key=` 필수), `--player-key=<key>`, `--save-root=user://...`(서버), `--character-name=<이름>`(클라이언트, P2-T9: 생성 화면 없이 그 이름과 기본 외형으로 캐릭터를 만든다. 1~64자, 이름 규칙은 서버가 검사한다, §14.24). 알 수 없는 인자는 오류(종료 코드 2).

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

초기 상태는 `_rpc_join_accepted` 스냅샷(접속 중 플레이어, 월드 아이템, 본인 인벤토리)으로 전달하고, 이후 변경은 같은 reliable 채널로 보내 순서를 보장한다. 클라이언트는 위치/수량/결과를 보내지 않는다. P2-T9부터 캐릭터가 없는 접속자(§14.24)는 접속 스냅샷의 플레이어 목록과 위치 스냅샷에 없고, 그 플레이어의 `_rpc_player_joined`는 접속 때가 아니라 첫 캐릭터가 만들어질 때 나가며(본인 peer에게도 보낸다), 캐릭터 없이 나가면 `_rpc_player_left`를 보내지 않는다. 이동·줍기 의도는 `not_online`으로 거부된다.

### 14.3 테스트

- `tests/run_tests.gd`: `tests/{unit,integration,scenarios}/**/*_test.gd`의 `test_*` 메서드를 실행. 단언이 없는 테스트는 실패 처리.
- 네트워크 테스트: `tests/framework/net_test_cluster.gd`가 한 프로세스 안에서 서버 1 + 클라이언트 N을 각자 `SceneMultiplayer` 서브트리로 띄워 실제 ENet(localhost)으로 통신한다. `tools/smoke_test.sh`는 별도로 서버 1 + 클라이언트 2 **프로세스** 접속을 검사한다.
- Phase 1 수용 시나리오: `tests/scenarios/phase1_acceptance_test.gd`.
- Phase 2 수용 시나리오(P2-Z): `tests/scenarios/phase2_acceptance_test.gd`. 서버 1 + 클라이언트 2(실제 ENet)가 기본 조립 그대로(이동·공격 의도 RPC, 좀비 AI, 발소리, 생존 규칙, NetModule 3개) 같은 좀비와 교전한다. 서버 쪽 직접 호출은 좀비 배치에만 쓴다. 수용 항목과 단언의 대응은 docs/12 §6, 조정한 설정값과 검증하지 못한 항목은 docs/15 §6.13.
- GDScript 런타임 오류는 함수만 중단되고 예외가 없으므로, `tools/run_tests.sh`가 출력에서 `SCRIPT ERROR`/`ERROR:`/`[ERROR]`/`[FATAL]`을 발견하면 실패 처리한다.

### 14.5 Phase 2 확장 지점(P2-0)

Phase 2 기능은 아래 seam으로만 끼워 넣는다. `network_service.gd`는 P2-0 이후 기능 작업에서 수정하지 않는다(동결. 예외는 P2-T9 한 번: 캐릭터 없는 접속자를 알리지 않는 조건과 `announce_player_entered`, §14.24). `server_world.gd`는 Phase 2 동안 B묶음(생존)만 수정한다.

| 구성 요소 | 파일 | 계약 |
|---|---|---|
| `WorldClock` / `WorldClockSettings` | `scripts/core/world_clock.gd`, `world_clock_settings.gd`, `data/tuning/world_clock_settings.tres` | 서버 권한 시계. 달력 시각 `world_time_sec`(실제 초 × `time_scale`, 기본 24)와 행동 시각 `action_time_sec`(실제 초)를 함께 진행한다(§14.16). `step(real_delta, any_online) -> world_delta`, 같은 틱의 증분은 `last_world_delta`/`last_action_delta`. 접속자 0명이면 둘 다 일시정지(설정). world_state `world_time_sec`·`action_time_sec`로 저장 |
| `BucketScheduler` | `scripts/core/bucket_scheduler.gd` | `new(period_sec, bucket_count)`, `add/remove/has/size/bucket_of`, `advance(delta) -> PackedStringArray`. 등록 순서 라운드로빈(결정론), 주기당 각 id 정확히 1회, 한 호출에서 같은 id 중복 없음 |
| `ServerSystem` | `scripts/services/world/server_system.gd` | `get_system_id()`(필수, snake_case), `seed_new_world(world)`, `step(world, action_delta, world_delta)`(매 서버 physics tick. `action_delta` = 실제 초, `world_delta` = 달력 초 = `action_delta` × 배율. 일시정지 중에는 둘 다 0. P2-T1에서 두 번째 매개변수의 뜻을 `real_delta`에서 바꿨다, §14.16), `on_player_online/offline(world, player_id)`, `player_movement_multiplier(player_id)`(기본 1.0, 서버 이동 속도 배율: 모든 시스템 값의 곱을 0~1로 제한), `on_registered(world)`(등록될 때 한 번. 월드를 보관해야 하는 시스템은 약한 참조만, P2-T4), `player_action_block_reason(player_id)`(기본 `""`. 플레이어의 행동(아이템 줍기·내려놓기·사용, 근접 공격)을 막는 사유 코드, 예: `player_dead`(P2-T4, §14.19), `player_resting`(P2-T8, §14.23). 이동은 이 훅이 아니라 `player_movement_multiplier`로 막는다), `to_world_document()`/`restore_world_document(doc)`, `to_player_fragment(player_id)`/`restore_player_fragment(player_id, doc)`. 문서는 JSON-safe + `schema_version`. P2-T9에서 `new_character_block_reason(player_id)`(기본 `""`. 캐릭터가 있는 플레이어가 새 캐릭터를 만들어도 되는지: `character_alive`, `respawn_wait`)와 `on_character_started(world, player_id)`(`start_new_character`가 끝에 부른다)가 추가됐다(§14.24) |
| `ServerWorld` seam | `scripts/services/world/server_world.gd` | `register_system(system) -> Error`, `get_system(id)`, `system_ids()`, `clock`, `step_systems(real_delta) -> world_delta`(시계를 진행하고 각 시스템에 두 증분을 넘긴다). 저장: world_state 스키마 v3(`world_time_sec`, `action_time_sec`), world_state `systems.{id}`, players/<id>.json 스키마 v3(`character_generation`, P2-T4)과 `systems.{id}`. 저장에 없는 시스템은 기본값 유지, 등록되지 않은 시스템 데이터는 경고 후 무시. P2-T4에서 `start_new_character(player_id)`(예전 `respawn_player_at_spawn`을 대체), `player_action_block_reason(player_id)`가 추가됐다(§14.19). P2-T9에서 접속과 월드 진입이 나뉘었다(§14.24): `require_character_creation`, `character_rules`, `create_character(player_id, raw_name, raw_appearance)`, `character_creation_block_reason(player_id)`, `is_player_connected`, `has_character`, `connected_player_ids`, `start_new_character(player_id, profile = null)`. `is_online`·`online_player_ids`는 "캐릭터를 가지고 월드 안에 있는 플레이어"이고 플레이어 파일 스키마는 v4(`character`)다 |
| `NetModule` | `scripts/services/multiplayer/net_module.gd` | `NetworkService`의 자식 노드(모든 peer에서 같은 `name`). 훅: `on_server_started(world)`, `on_player_joined/left(peer_id, player_id)`, `server_physics(delta)`, `build_join_fragment(player_id)`(서버), `apply_join_fragment(fragment)`(클라이언트). 자체 `@rpc` 메서드 사용. P2-T9부터 `on_player_joined`는 "플레이어가 월드에 들어왔다"는 뜻이다: 캐릭터가 있는 플레이어는 핸드셰이크 직후, 캐릭터가 없던 접속자는 첫 캐릭터를 만든 순간 불린다(§14.24). `on_player_left`는 모든 접속자의 퇴장에서 불린다 |
| `NetworkService` 공개 헬퍼 | `scripts/services/multiplayer/network_service.gd` | `register_module(module)`(시작 전만), `get_module(name)`, `is_server()`, `is_client()`, `is_from_server()`, `sender_player_id()`, `joined_peers()`, `peer_of_player(id)`, `player_of_peer(peer)`, `can_send_to(peer)`, `reject_intent(peer, intent, reason, player_id)`, `count_rejection(reason)`, `rejected_intent_count(reason)`, `persist(reason)`, `get_world()`, `get_settings()`, `announce_player_entered(player_id)`(P2-T9: 접속해 있던 플레이어가 첫 캐릭터로 월드에 들어왔음을 알린다, §14.24) |
| `ServerComposition` / `CompositionConfig` | `scripts/core/server_composition.gd`, `composition_config.gd` | 시스템/모듈 조립의 유일한 장소. `create_world(world_id, config)`, `install_net_modules(service, config)`. 시스템 사이의 시그널 연결도 여기서 한다(P2-T5: `SurvivalService.player_died` → `ZombieService.on_player_died`, §14.20). `WorldPersistence`, `GameBootstrap`, `NetTestCluster`가 모두 사용 |
| 저장 마이그레이션 | `scripts/services/save/save_migrations.gd` | world_state v1→v2(`world_time_sec`, `systems` 추가), v2→v3(`action_time_sec` 추가, 값은 `world_time_sec`. P2-T1), player v1→v2(`systems` 추가), player v2→v3(`character_generation` 추가, 값은 1. P2-T4), player v3→v4(`character` 추가, 값은 기본 이름과 빈 외형. P2-T9, §14.24). `SaveService` 기본 마이그레이터 |

채널: 0 reliable ordered, 1 unreliable ordered(플레이어 이동), 2 unreliable ordered(AI 엔티티 스냅샷, A묶음 예약). `PROTOCOL_VERSION` = 13(P2-0에서 2, N1 묶음 ZombieNet·SurvivalNet·CombatNet 병합 때 3, P2-T2 InventoryNet에서 4(§14.17), P2-T3 소비 의도에서 5(§14.18), P2-T6~T8 묶음에서 6: 휴식 의도 RPC와 생존 스냅샷 형식 3(§14.23), P2-T9에서 7: `CharacterNet` 모듈(캐릭터 생성 의도, 캐릭터 행, 생성 가능 상태)과 캐릭터 없는 접속자(§14.24), P2-T10~T12 묶음에서 8: 기상 원인(§14.25), `PostureNet` 모듈(§14.26), 다른 플레이어 치료(§14.27), P2-T14에서 9: 건네기 의도와 건네기 알림(§14.28), P2-T15에서 10: 건네기 RPC 삭제와 내려놓기 수량(§14.29), P2-T16에서 11: `TradeNet` 모듈(§14.30), P3-4a에서 12: `StructureNet` 모듈(§15.4), P3-2에서 13: 셀 기반 복제 범위(§15.2)). 버전별 메시지 목록은 `scripts/core/build_info.gd`의 주석에 있다.

P2-T11에서 `ServerSystem`에 훅 넷이 추가됐다(모두 기본값은 "영향 없음"이고 `ServerWorld`의 같은 이름 함수가 모든 시스템의 값을 모은다, §14.26): `player_attack_block_reason(player_id)`(공격만 막는 사유. `ServerWorld.player_attack_block_reason`은 행동 전체를 막는 사유를 먼저 본다), `player_visibility_multiplier(player_id)`(좀비 시야 거리에 곱하는 가시성, 곱을 0~1로 제한), `player_footstep_loudness_multiplier(player_id)`·`player_footstep_stride_multiplier(player_id)`(발소리 세기·보폭 배율, 곱). 잘못된 값(NaN·무한·음수)은 오류 로그를 남기고 무시한다(1.0으로 취급: 고장 난 시스템이 누구도 숨기지 못한다). 조립에 시그널 연결 둘이 늘었다: `SurvivalService.rest_changed`·`player_died` → `PostureService.on_rest_changed`·`on_player_died`.

P2-T14에서 `ServerSystem`에 훅 하나가 추가됐다(§14.28): `player_is_dead(player_id)`(기본 false. 그 플레이어의 현재 캐릭터가 죽었는지. `ServerWorld.is_player_dead`는 어느 한 시스템이라도 true면 true다). 행동을 **받는** 쪽의 생사를 묻는 훅이다: `player_action_block_reason`은 자는 플레이어도 막으므로 "죽었는가"만 따로 물을 수 없다. `SurvivalService`가 죽은 캐릭터에 대해 true를 돌려준다. `ServerWorld`에는 `try_hand_over_item`이 추가됐다.

### 14.6 생존 계약(B1, system id `survival`)

`scripts/domain/survival/`: `BodyPart`(10부위, 저장 이름), `Wound`(bruise/laceration/fracture/burn/bite/scratch, severity 0~1), `DamageInput`(서버가 만든 피해: source_id, body_part, wound_type, amount), `InfectionState`(단계 none~zombified, 노출 bite/scratch/blood), `PlayerVitals`(players/<id>.json `systems.survival`), `SurvivalSettings`(`data/tuning/survival_settings.tres`), `SurvivalService`(ServerSystem).

다른 시스템은 `world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService`로 얻어 아래만 호출한다(반환된 PlayerVitals는 읽기 전용): `is_alive`, `try_spend_stamina`, `handling_multiplier`, `movement_speed_multiplier`, `apply_damage(player_id, DamageInput) -> ActionResult`, `stop_bleeding(player_id, wound_id) -> ActionResult`, `apply_infection_exposure(player_id, InfectionState.Exposure, source_id) -> ActionResult`, `apply_infection_treatment(player_id, source_id) -> ActionResult`, `infection_stage(player_id) -> InfectionState.Stage`, `has_player`, `get_vitals`. 이벤트 형식과 실패 사유 코드는 `survival_service.gd` 상단 주석이 기준이다. B2에서 `need_category(player_id, NeedKind.Kind)`, `worst_need_category(player_id)`가 추가됐다(`NeedKind`: 허기/갈증/피로와 양호/주의/위험 범주).

B3에서 `Wound.is_bleeding`과 `PlayerVitals.died_at_world_time`을 저장 상태로 추가하고 생존 fragment 스키마를 v2로 올렸다(v1은 새 필드 기본값으로 읽음). `step`은 접속 중인 플레이어에게만 월드 시간을 적용한다. 생존 중에는 욕구 증가, 출혈 피해, 허기/갈증 최대치 피해, 조건부 체력·상처 회복을 처리하고, 사망 중에는 욕구/피해/회복을 멈춘 채 리스폰 시각만 판정한다. 모든 욕구가 `GOOD`이고 출혈이 없을 때만 체력과 상처 severity가 회복되며 severity 0 상처는 제거된다. 체력 0은 사망 시각을 남기고 `player_died`를 로그에 기록하며(`apply_damage` 결과는 B1 계약대로 `player_wounded` + `died: true`) 설정 지연 뒤 `ServerWorld.respawn_player_at_spawn`으로 설정 스폰 위치를 복원하면서 이전 이동 입력을 제거한다. 인벤토리/RNG는 유지하고 vitals·욕구·상처·감염은 설정값으로 초기화한다. 연속 구간을 욕구 임계·사망·리스폰 경계에서 적분하므로 틱 크기와 무관하다(허용 오차 1e-3). B3 임시 수치는 docs/15 P2-13~P2-17에 기록한다.

B4에서 `InfectionState.stage_elapsed_world_sec`를 추가하고 생존 fragment 스키마를 v3으로 올렸다(v1/v2는 경과 시간 0으로 읽음). 서버는 접속 중이고 생존한 플레이어의 활성 월드 시간만 누적해 `LATENT → EARLY → PROGRESSING → SEVERE → TERMINAL → ZOMBIFIED`를 진행한다. 각 단계 시간과 감염 경로별 시간 배율은 `SurvivalSettings`에서 읽으며 감염 단계 경계를 B3의 구간 적분 경계에 포함한다. `ZOMBIFIED` 진입 즉시 원인 `infection`으로 사망시키고 플레이어 좀비는 만들지 않으며, 기존 리스폰이 감염을 해제한다(P2-T5부터는 감염으로 죽은 자리에 좀비가 생긴다, §14.20. 새 캐릭터는 감염 없이 시작한다, §14.19). 단계 변화는 `player_infection_stage_changed` 로그(`player_id`, `from`, `to`, `world_time`)로 남긴다.

단계별 스태미나 회복 배율은 기존 욕구 배율과 곱하고, 단계별 체력 감소율은 출혈·굶주림·탈수 피해와 합산한다. 양수인 감염 체력 감소가 적용되는 동안에는 자연 회복을 허용하지 않는다. 치료 seam `apply_infection_treatment(player_id, source_id)`는 설정된 최대 단계 이하에서 감염을 해제하고 `player_infection_cured`를 반환·기록하며, 아이템·품질·의료 능력 판정은 후속 티켓 소유다. 읽기 전용 `infection_stage(player_id)`는 현재 단계를 반환한다. 임시 수치는 docs/15 P2-7/P2-8/P2-18/P2-19에 기록한다. 감염 복제는 §14.14(P2-N1c), 섭취는 §14.18(P2-T3: `reduce_needs`, `check_reduce_needs`), 붕대는 §14.21(P2-T6: `bleeding_wound_ids`, `check_stop_worst_bleeding`, `stop_worst_bleeding`. 지혈 seam `stop_bleeding`이 아이템과 연결됐다), 치료제는 §14.22(P2-T7: `check_infection_treatment`. 치료 seam `apply_infection_treatment`이 아이템과 연결됐다. 품질·의료 능력 판정은 여전히 없다), 수면(휴식)은 §14.23(P2-T8: `is_resting`, `start_rest`, `stop_rest`. 쉬는 동안 피로가 줄고, 이 절의 "욕구 증가"는 쉬는 플레이어의 피로에는 적용되지 않는다)에서 추가됐다.

P2-T1부터 이 절의 "월드 시간"은 달력 시간이고, 스태미나 회복·리스폰 대기·피해 이벤트 묶는 간격만 행동 시간(실제 초)이다. 설정 이름은 `stamina_regen_per_sec`, `respawn_delay_sec`, `survival_damage_event_interval_sec`로 바뀌었고 생존 fragment 스키마 v4가 `died_at_action_time`을 추가했다. 구간 적분이 두 축을 함께 다루는 방식은 §14.16.

P2-T4부터 위 B3·B4의 "리스폰"은 **영구 사망 뒤 새 캐릭터 시작**이다(§14.19가 우선): 사망 순간 소지품이 전부 죽은 자리에 놓이고, 대기 시간 뒤 스폰 지점에서 빈 인벤토리·다음 세대 번호로 시작한다. "인벤토리 유지"와 `ServerWorld.respawn_player_at_spawn`은 더 이상 없다(`start_new_character`). 대기 시간·초기 욕구 설정(`respawn_delay_sec`, `respawn_hunger` 등)과 이벤트 이름 `player_respawned`는 그대로 쓴다. 죽은 캐릭터는 아이템을 줍거나 내려놓을 수 없다(`player_action_block_reason`).

P2-T9부터 전용 서버에서는 새 캐릭터가 저절로 시작하지 않는다(§14.24가 우선): 대기 시간이 지난 뒤 플레이어가 이름과 외형을 정해 새 캐릭터를 만들어야 시작하고, 그때까지 죽은 상태가 유지된다. 생존 상태 초기화는 `ServerSystem.on_character_started` 훅으로 옮겨져 자동 시작과 요청에 의한 시작이 같은 코드를 지난다. 접속했지만 캐릭터가 없는 플레이어는 생존 상태 자체가 없다(`has_player`가 false).

P2-T10부터(§14.25가 우선) `handling_multiplier`는 팔·손 상처 배율에 **피로 범주의 배율**을 곱한 값이다(작업 능력: 근접 피해에 쓰이고, 이후의 제작·건축도 이 값을 써야 한다). `rest_danger(player_id)`가 추가됐고, 자는 플레이어에 대한 `apply_damage`는 체력을 설정 하한 아래로 내리지 않는다(이벤트 계약 `player_wounded` + `died`는 그대로이고 그 경우 `died`가 false다).

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
| `on_player_died(world, player_id, cause, infection_stage)` | `SurvivalService.player_died` 시그널의 수신부(P2-T5, §14.20). 설정된 규칙에 맞는 사망이면 그 플레이어의 위치·방향에 좀비 하나를 `spawn_zombie`로 만든다. 상한이면 생략하고 경고 로그와 `skipped_player_zombie_count`를 남긴다 |

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

- 시야와 가시성(P2-T11, §14.26이 우선): 좀비가 플레이어를 볼 수 있는 거리는 `sight_range_m × light_sight_multiplier × 그 플레이어의 가시성`이다. 가시성은 `ServerWorld.player_visibility_multiplier(player_id)`로 묻는 0~1의 값이고(자세와 움직임에서 나온다: 서서 움직임 1.0, 서서 정지 0.9, 누워 잠 0.8, 엎드려 이동 0.6, 엎드려 정지 0.4), 좀비 시스템은 자세·수면·이동을 알지 못한다. 시야각 규칙은 그대로다. 지금 추격·공격 중이고 직전 판단에서 보였던 대상의 가시성은 `tracked_target_min_visibility`(기본 1.0)보다 낮아지지 않는다: 이미 보고 있는 좀비 앞에서 엎드려도 추격은 끊기지 않고, 전체 시야 거리나 시야각 밖으로 벗어나야 놓친다. 놓친 뒤(수색 중)에는 일반 배율이 적용된다.
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
| `player_resting` | 누워 쉬는 중(P2-T8, §14.23). `ServerWorld.player_action_block_reason`이 돌려주는 사유를 그대로 쓰므로 다른 시스템이 행동을 막는 사유가 생기면 이 자리에서 함께 거부된다 |
| `player_prone` | 엎드린 채로는 공격할 수 없다(P2-T11, §14.26). 전투는 `ServerWorld.player_attack_block_reason`을 묻고, 그 함수가 행동 전체를 막는 사유(위 둘)를 먼저, 공격만 막는 사유를 다음에 돌려준다 |
| `no_weapon` | 쓸 무기 정의가 없음(맨손 정의 누락 = 설정 오류, 시작 시 `validate()`가 먼저 잡는다) |
| `attack_on_cooldown` | 직전 공격의 쿨다운(행동 시간, 실제 초)이 남음 |
| `not_enough_stamina` | 스태미나가 무기 비용보다 적음(`SurvivalService.try_spend_stamina`가 마지막 검사이자 차감) |

승인된 공격의 처리:

- 무기: `CombatSettings.inventory_weapon_rule`에 따라 플레이어 인벤토리의 아이템 중 `MeleeWeaponDefinition.item_definition_id`와 일치하는 것을 찾는다. `HIGHEST_DAMAGE`(기본, 기본 피해가 가장 큰 무기·같으면 무기 ID가 작은 것), `FIRST_SLOT`(슬롯 번호가 가장 작은 무기 아이템), `UNARMED_ONLY`(항상 맨손). 해당 아이템이 없으면 `unarmed_weapon_id`(맨손)이다. 장비 슬롯은 아직 없다.
- 대상: 서버가 가진 플레이어 위치와 `aim_yaw`(플레이어에 저장된 `yaw`는 쓰지도 바꾸지도 않는다)를 기준으로, 무기 사거리(`range_m`) 안이고 조준 방향을 중심으로 한 호(`arc_angle_deg`, 전체 각) 안에 있는 **살아 있는 좀비 중 가장 가까운 1마리**. 거리가 같으면 좀비 ID가 작은 쪽. XZ 평면에서만 계산하며 yaw 규약은 플레이어·좀비와 같다(0 = −Z). 플레이어는 대상이 되지 않는다(PvP 비활성, docs/00).
- 피해: `무기 base_damage × SurvivalService.handling_multiplier(player) × uniform(damage_roll_min, damage_roll_max)`. `handling_multiplier`는 P2-T10부터 팔·손 상처 배율 × 피로 배율이라(§14.25) 피로가 주의·위험이면 전투 코드 변경 없이 근접 피해가 줄어든다. 난수는 전투 RNG(seed = `CombatSettings.rng_seed`, 상태 저장)이고 **대상이 있는 공격에서만** 한 번 뽑는다. 적용은 `ZombieService.apply_damage_to_zombie(target, damage, player_id)`이므로 맞은 좀비는 좀비 계약(§14.9)대로 공격자를 인지한다.
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

자세에 따른 발소리(P2-T11, §14.26): 발소리의 세기와 보폭은 설정값에 `ServerWorld.player_footstep_loudness_multiplier(player_id)`·`player_footstep_stride_multiplier(player_id)`를 곱한 값이다(기본 1.0). 엎드린 플레이어는 세기 ×0.4, 보폭 ×0.5라서 발소리 하나가 들리는 거리가 7m에서 2.2m로 줄어든다(기본 소음 설정). 세기 배율이 0이면 그 플레이어는 소리를 내지 않는다. 이 시스템은 자세를 알지 못한다. "걷는 중인지"의 기준 속도(`min_speed_mps`)는 그대로라 엎드려 기는 속도(1.4m/s)도 발소리를 낸다.

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

`SurvivalNetModule`(노드 이름 `SurvivalNet`)은 `ServerComposition.install_net_modules`에서 서버와 모든 클라이언트에 같은 이름으로 설치한다. `NetworkService`는 수정하지 않으며 공개 seam만 쓴다. 이 절의 세 RPC는 서버→클라이언트이고 모두 채널 0 reliable ordered다(P2-T8에서 이 모듈에 클라이언트→서버 휴식 의도 RPC와 그 결과 RPC가 추가됐다, §14.23). 클라이언트 핸들러는 먼저 `network.is_from_server()`를 확인하며, 발신·타입·범위·공개 범위가 잘못된 DTO는 상태를 바꾸지 않고 경고 로그만 남긴다.

| RPC | 수신자 | 페이로드 |
|---|---|---|
| `_rpc_survival_owner_snapshot(snapshot)` | 해당 플레이어 본인 | 아래 owner snapshot. 설정 주기마다 비교하고 변경된 경우에만 전송 |
| `_rpc_survival_status(status)` | 접속 중 클라이언트 | `{player_id: String, alive: bool, resting: bool}`. 새 플레이어 접속 시 기존 미러 보강 |
| `_rpc_survival_events(events)` | 이벤트 공개 범위에 따른 본인/타인 | 검증된 이벤트 Dictionary 배열. 한 서버 틱에 peer별로 묶어 전송 |

접속 조각(`snapshot.modules.SurvivalNet`)과 본인 스냅샷의 스키마 버전은 3이다(P2-T4에서 `character_generation`을 추가하며 1 → 2, P2-T8에서 `resting`을 추가하며 2 → 3. 이전 형식은 클라이언트가 버린다). P2-T9부터 캐릭터가 없는 접속자(§14.24)의 접속 조각에는 `self`가 없다(`{schema_version, players}`). 미러는 이 형식을 받아 다른 플레이어의 공개 행만 채우고, 본인의 공개 행과 본인 스냅샷은 캐릭터가 생긴 뒤에 받는다.

```text
{
  schema_version: 3,
  self: <owner snapshot>,
  players: [{player_id: String, alive: bool, resting: bool}, ...]  # 접속 중인 전 플레이어
}

owner snapshot = {
  schema_version: 3, player_id: String, alive: bool,
  health: float, stamina: float,
  needs: {hunger: "good|caution|danger", thirst: ..., fatigue: ...},
  wounds: [Wound.to_dict(), ...],
  infection_stage: "none|latent|early|progressing|severe|terminal|zombified",
  character_generation: int >= 1,  # 그 플레이어의 몇 번째 캐릭터인지(§14.19). 본인만 받는다
  resting: bool                    # 누워 쉬는 중(§14.23). 같은 값이 공개 행에도 있다. 죽은 캐릭터는 항상 false
}
```

공개 범위는 docs/15 P2-9를 따른다. `scope: "owner"` 이벤트는 대상 본인에게만 가며 체력 변화, 상처 상세, 지혈, 생존 피해, 욕구 범주, 감염/저항/단계 변화/치료, 눕기·일어나기(일어난 원인 포함)를 포함할 수 있다. `scope: "public"`은 타인에게만 가며 아래 다섯 종류뿐이다(P2-T8에서 뒤의 둘이 추가됐다).

| 공개 이벤트 | 필드(`scope`, `event_type`, `player_id` 공통) |
|---|---|
| `player_wounded` | `body_part`, `wound_type`, `died`, `world_time` |
| `player_died` | `world_time`(원인 제외: 감염 사망 노출 방지) |
| `player_respawned` | `position: [x,y,z]`, `world_time` |
| `player_rest_started` | `world_time`(누웠다) |
| `player_rest_ended` | `world_time`(일어났다. 원인 제외) |

타인용 DTO에는 체력·피해 수치, wound 상세/심각도, 욕구, 감염 여부·단계·노출·원인을 넣지 않는다. `SurvivalService.drain_events()`는 JSON-safe 이벤트를 발생 순서로 반환하고 비우며, 설정 상한을 넘으면 좀비/전투 큐와 같이 가장 오래된 것부터 버리고 `dropped_event_count`를 올린다. `apply_damage`의 기존 `player_wounded` ActionResult 계약은 유지한다.

`ClientSurvivalState`는 권한 없는 순수 미러다. 공개 API는 `health()`, `stamina()`, `need_category(kind)`, `wounds()`, `infection_stage()`, `character_generation()`(P2-T4), `has_player(id)`, `is_alive(id)`, `is_resting(id)`(P2-T8, 본인과 다른 플레이어 모두), `last_respawn_position(id)`, `recent_events()`이며 변경 알림은 `changed`, `own_vitals_changed`, `player_alive_changed`, `player_resting_changed`(P2-T8), `event_received`, `player_respawned` 시그널이다. 최근 이벤트 목록은 설정된 개수만 보관한다. 수치는 `data/tuning/survival_net_settings.tres`와 `survival_settings.tres`에 있고 임시 결정은 docs/15 P2-70~P2-74다.

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

좀비와 플레이어 캡슐은 미러의 가장 최근 위치를 그대로 사용한다. 프레젠테이션 보간·외삽·예측은 없고, 시체는 X축으로 기울여 눕힌다. 좀비의 `idle/investigate/chase/attack/search/dormant/dead` 색과 임시 크기, 사망 플레이어 색은 `data/tuning/client_presentation_settings.tres`에 있다. 플레이어의 살아 있는 로컬/원격 색과 크기는 기존 `camera_settings.tres`를 유지한다. P2-T9부터 플레이어 캡슐의 색과 크기는 캐릭터의 외형(상의 색, 키, 체형)에서 오고 캡슐 위에 이름표가 붙는다(§14.24). `camera_settings.tres`의 색과 크기는 캐릭터 행이 없는 플레이어의 기본 캡슐과 배율의 기준값으로 쓰인다.

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
- P2-T14에서 네 번째 트랜잭션 `transfer_item`(한 인벤토리에서 다른 인벤토리로, 이벤트 `item_transferred`)이 추가됐다. 계약과 복제는 §14.28.
- **P2-T15에서 바뀐 것(§14.29가 우선한다)**: `drop_item`에 수량 인자가 붙어 묶음의 일부를 내려놓을 수 있고(새 이벤트 `item_units_dropped`), `try_pickup`은 주운 수량을 들고 있는 같은 종류 묶음에 먼저 합치며(`item_picked_up` 이벤트에 `definition_id`, `quantity`, `merged` 추가), 내려놓기 의도 RPC는 `_rpc_request_drop(request_id, item_instance_id, quantity)`가 됐다. 이 절의 표와 "수량 인자는 없다"는 설명은 P2-T2 시점의 것이다.
- P2-T16에서 다섯 번째 트랜잭션 `exchange_items`(두 인벤토리가 서로 아이템을 주는 교환, 이벤트 `items_exchanged`)와 `InventoryNetModule.flush_pending_save`가 추가됐다. 계약과 복제는 §14.30.
- 보조: `item_count()`(존재하는 인스턴스 수). 저장 형식은 바뀌지 않았다: 내려놓은 아이템의 좌표는 기존대로 world_state `inventory.world_item_positions`(docs/15 P1-7)에, 삭제된 ID는 world_state `tombstones`에, 다음 순번은 `next_entity_sequence`에 들어간다.

`ServerWorld` 래퍼(위치·셀·인벤토리 ID는 서버 상태에서 채운다. 셀은 놓이는 위치의 셀(`ServerWorld.cell_id_at`. P3-1 전에는 모든 아이템이 `DevWorldSeed.DEV_CELL_ID`였다, §15.1), 위치는 `clamp_to_world(플레이어 위치)`):

| 메서드 | 대상 | 추가 실패 사유 |
|---|---|---|
| `try_drop_item(player_id, item_instance_id)` | 접속 중인 플레이어(의도 처리용) | `not_online`, 시스템이 막는 사유(`player_dead`, P2-T4 §14.19. `player_resting`, P2-T8 §14.23. `try_pickup`도 같다) |
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

P2-T6부터 `ItemConsumption`은 아이템 정의의 사용 효과 전부를 적용하는 일반 규칙이다(§14.21: 지혈 효과, 사유 `not_bleeding`, 이벤트 필드 `bleeding_stopped_wound_ids`. §14.22: 치료 효과, 사유 `not_infected`·`too_late`, 이벤트 필드 `infection_cured_from`). 이 절의 먹기·마시기 규칙·검증·저장은 그대로이고, 아래 "클라이언트 표시"의 소비 키 하나는 종류별 키(음식 F, 물 G, 붕대 B, 치료제 V)로 바뀌었다(§14.21·§14.22가 우선).

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

요청: 클라이언트는 의도만 보낸다(자신이 붙인 요청 번호와 아이템 인스턴스 ID). 대상 플레이어·수량·효과 인자는 없다. 행위자는 보낸 peer의 플레이어다. 인자를 더 붙인 호출은 엔진이 거부한다(테스트로 고정). P2-T12에서 이 모듈에 "다른 플레이어에게 사용" 의도(`_rpc_request_use_on`, 대상 플레이어 ID 인자 하나 추가)와 그 결과, 치료 알림 RPC가 추가됐다(§14.27). 이 소비 의도는 바뀌지 않았다.

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

캐릭터가 죽으면 그 캐릭터는 끝난다. 소지품은 죽은 자리의 월드에 남고, 플레이어는 설정된 대기 시간 뒤 새 캐릭터로 시작한다. Phase 2의 개발용 리스폰(인벤토리 유지, §14.6의 B3 서술)을 대체하며 이 절이 §14.6보다 우선한다. 임시 가정은 docs/15 §11.2 P2-126~P2-131. P2-T9부터 전용 서버에서는 "대기 시간 뒤 저절로 새 캐릭터가 시작한다"가 "대기 시간 뒤 플레이어가 새 캐릭터를 만들면 시작한다"로 바뀌었고 그 부분은 §14.24가 우선한다. 이 절의 자동 시작은 캐릭터 생성이 필요 없는 조립(테스트·도구의 호환 기본값)에 그대로 적용된다.

구성: `SurvivalService`(사망 시 소지품 내려놓기, 새 캐릭터 시작), `ServerWorld.start_new_character`·`player_action_block_reason`, `ServerSystem.on_registered`·`player_action_block_reason`(새 훅 2개), `PlayerState.character_generation`(플레이어 파일 스키마 v3), `SurvivalNetModule`/`ClientSurvivalState`(본인 스냅샷에 세대 번호), HUD. `network_service.gd`는 수정하지 않았다. 새 RPC는 없다. 본인 스냅샷과 접속 조각의 형식이 바뀌었고(아래), 프로토콜 버전은 P2-T3에서 올린 5를 그대로 쓴다(같은 브랜치에서 한 번만 올림).

#### 사망 순간

`SurvivalService._mark_dead`(전투 피해 `apply_damage`, 생존 규칙의 시간 피해, 감염 좀비화 모두 이 한 곳을 지난다)가 순서대로 한다: 체력 0과 사망 시각(달력·행동) 기록 → 아직 내보내지 않은 시간 피해 이벤트 → **소지품 전부를 그 플레이어의 서버 위치에 내려놓기**(`ServerWorld.drop_all_player_items`, §14.17의 `drop_all_items` 트랜잭션 한 번) → `player_died` 이벤트 → 다른 시스템용 시그널 `player_died`(P2-T5, §14.20).

- 내려놓는 시점은 **사망 즉시**다(새 캐릭터가 시작될 때가 아니다). 이유: (1) 대기 시간 동안에도 다른 플레이어가 그 자리의 아이템을 보고 주울 수 있다. (2) "죽은 캐릭터는 아무것도 들고 있지 않다"가 사망 순간부터 성립하므로, 죽은 채 접속을 끊거나 서버가 저장·재시작되어도 소지품이 두 번 떨어지거나 사라질 중간 상태가 없다.
- 위치는 `clamp_to_world(플레이어 위치)`, 셀은 그 위치의 셀(`ServerWorld.cell_id_at`, §14.17과 같다. P3-1 전에는 `DevWorldSeed.DEV_CELL_ID`였다). 한 점에 겹쳐 놓인다. 묶음은 나뉘지 않고, 아이템 수는 보존된다(생성·삭제 없음).
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

### 14.20 감염 사망 자리의 좀비(P2-T5, docs/00 ADR-008)

감염으로 죽은 플레이어의 자리에 좀비가 하나 생긴다. 좀비를 만들지 않던 임시안(§14.6의 B4 서술, docs/15 P2-8)을 대체한다. 임시 가정은 docs/15 §11.3 P2-132~P2-136.

구성: `SurvivalService`(시그널 `player_died`, 정적 함수 `is_infection_death`), `ZombieService.on_player_died`(규칙 판단과 생성), `ZombieSettings.player_death_zombie_rule`, `ServerComposition.create_world`(둘을 연결). 새 RPC·새 저장 필드·프로토콜 변경은 없다. `network_service.gd`는 수정하지 않았다.

#### 결합 방식

- `SurvivalService`는 좀비 시스템을 모른다. 사망을 알리는 시그널만 낸다: `signal player_died(world: ServerWorld, player_id: String, cause: String, infection_stage: InfectionState.Stage)`. 모든 사망 경로가 지나는 `_mark_dead`에서, 소지품을 내려놓고(§14.19) `player_died` 이벤트를 큐에 넣은 직후, 사망마다 한 번, 동기적으로 낸다. `cause`는 그 이벤트의 원인 문자열, `infection_stage`는 사망 순간의 단계(`NONE` = 비감염), `world`는 그 시스템이 등록된 월드다(플레이어 위치는 아직 죽은 자리). 월드에 등록되지 않은 시스템은 내지 않는다.
- `ServerComposition.create_world`가 `survival.player_died.connect(zombies.on_player_died)`로 잇는다(조립의 유일한 장소, §14.5). 월드가 두 시스템을 소유하고 연결은 어느 쪽도 참조로 붙잡지 않는다. 좀비 시스템이 없는 월드에서는 아무도 듣지 않을 뿐이다.
- 좀비 쪽이 읽는 것은 원인 문자열과 감염 단계뿐이다(`ZombieService`는 이미 `SurvivalService`의 피해·감염 API를 쓰고 있어 새 의존 방향이 생기지 않는다).

#### 규칙

`ZombieService.on_player_died(world, player_id, cause, infection_stage)`가 `ZombieSettings.player_death_zombie_rule`에 따라 판단한다.

| 값(`ZombieSettings.PlayerDeathZombieRule`) | 좀비가 생기는 사망 |
|---|---|
| `NEVER`(0) | 없음 |
| `INFECTION_DEATH`(1) | 감염이 사망 원인인 경우: `SurvivalService.is_infection_death(cause)`가 참. 말기가 끝나 `ZOMBIFIED`가 된 사망(원인 `infection`)과, 감염 단계의 체력 감소로 죽은 사망(원인 `infection`, 또는 출혈·굶주림·탈수와 함께 죽어 원인이 `..._infection`으로 끝나는 경우)이다 |
| `INFECTED_AT_DEATH`(2, 기본: 사용자 결정 2026-11-15, docs/00 ADR-011) | 위에 더해, 감염된 상태(단계가 `NONE`이 아님)에서 일어난 모든 사망(전투 피해 포함) |

- 기본 규칙에서 전투 피해(`combat`), 출혈, 굶주림, 탈수만으로 죽으면 감염된 플레이어라도 좀비가 생기지 않는다. 물려서 그 자리에서 죽은 비감염 플레이어도 마찬가지다(치명타에는 감염 판정이 적용되지 않는다, §14.9).
- 생성: 기존 `spawn_zombie(world, 플레이어 위치, 플레이어 yaw)` 그대로다. 일반 좀비와 같은 ID 계열·체력·AI·수치이고 상태는 `idle`, 배회 기준점은 죽은 자리다. 좀비 상태에도 이벤트에도 어느 플레이어였는지는 없다(서버 로그 `player zombie spawned`에만 `player_id`가 남는다).
- 상한: 좀비 수가 `max_active_zombies`(시체 포함)에 이르렀으면 생성하지 않는다. `spawn_zombie`가 `zombie_limit`로 거부하고, 경고 로그(`player zombie not spawned`, `player_id`, 사유)와 `skipped_player_zombie_count`를 남긴다. 나중에 자리가 나도 다시 시도하지 않는다. 플레이어의 사망 처리 자체는 영향받지 않는다.
- 시점: 사망과 같은 서버 틱이다. 생존 규칙의 사망(좀비화, 감염 체력 감소)은 생존 시스템의 `step` 안에서 일어나고 좀비 시스템이 그 뒤에 도므로 즉시 생성된다. 좀비 시스템이 자기 `step`을 도는 중에 알림이 오면(좀비의 공격으로 플레이어가 죽는 경우, `INFECTED_AT_DEATH`에서만 해당) 요청을 모아 두었다가 그 `step`이 끝날 때 생성한다(처리 중인 좀비 집합을 바꾸지 않기 위해서다).
- 진단: `ZombieService.player_zombie_count`, `skipped_player_zombie_count`(서버 시작 후 누계, 저장하지 않음).
- 새 캐릭터(§14.19)는 감염이 없는 상태로 시작하므로 같은 사망이 좀비를 두 번 만들지 않는다. 죽은 채 저장된 플레이어를 다시 로드하거나 그 플레이어가 다시 접속해도 사망이 다시 일어나지 않는다.

#### 복제와 저장

- 복제: 기존 `ZombieNet`(§14.12)이 그대로 한다. 생성 틱의 `zombie_spawned` 이벤트(채널 0)로 모든 클라이언트 미러에 추가되고 이후 스냅샷으로 갱신되며, 늦게 접속한 클라이언트는 접속 조각으로 받는다. 이벤트·행 형식은 바뀌지 않았다.
- 정보 공개(ADR-009): 다른 플레이어가 받는 것은 기존 그대로 `player_died`(원인 없음)와 좀비의 등장뿐이다. "이 좀비가 누구였는지"를 알리는 필드는 어디에도 없다. 다만 죽은 플레이어의 캡슐이 있는 자리에 같은 틱에 좀비가 나타나므로, 그 자리를 보고 있는 플레이어는 그 죽음이 감염 때문이었음을 알 수 있다. ADR-008이 요구하는 관찰 가능한 사실로 보고 숨기지 않았다(docs/15 P2-135).
- 저장: 일반 좀비와 같이 world_state `systems.zombie`에 들어간다(스키마 변경 없음). 죽은 플레이어가 소지품을 들고 있었으면 그 틱 끝의 저장(§14.19)에 좀비도 함께 들어가고, 빈손이었으면 다음 저장에 들어간다. 그 전에 서버가 비정상 종료하면 플레이어는 감염된 채 살아 있던 마지막 저장으로 돌아가 다시 죽고 좀비도 다시 생긴다(하나).

테스트: `tests/unit/player_zombie_test.gd`(감염 사망 → 그 위치·방향에 좀비 1마리와 이벤트 형식, 새 캐릭터가 좀비를 더 만들지 않음, 전투·감염자의 전투 사망·탈수·출혈은 생성 없음, 원인 문자열 판정, 감염 체력 감소 사망, 규칙 설정 3값과 검증, 상한에서 생략·로그·재시도 없음, 좀비 `step` 안에서 일어난 사망, 좀비 시스템 없는 월드, 저장 → 재생성 → 로드), `tests/integration/player_zombie_net_test.gd`(서버 1 + 클라이언트 2~3, 실제 ENet: 두 클라이언트 미러에 같은 ID의 좀비가 죽은 위치·방향으로 나타남, 같은 이벤트·순번, 이벤트와 미러에 플레이어 ID 없음, 다른 플레이어는 사망 원인을 받지 않음, 새 캐릭터와 감염 아닌 사망은 좀비를 늘리지 않음, 늦은 접속, 저장 → 서버 재시작 → 재접속).

### 14.21 붕대(P2-T6, 사용자 결정 2026-11-15)

플레이어가 들고 있는 붕대 한 단위를 쓰면 서버가 그 플레이어의 출혈 중인 상처를 지혈한다. §14.6의 서버 seam `stop_bleeding`을 아이템과 연결한 것이다. 임시 가정은 docs/15 §12.1 P2-140~P2-145.

구성: `ItemDefinition`(지혈 효과 필드), `SurvivalService`(가장 심한 출혈 상처를 고르는 API 3개), `ItemConsumption`(먹기·마시기 규칙을 "아이템 사용 효과 적용"으로 일반화), 개발용 아이템 정의 `dev_bandage`, 개발용 월드 배치, 클라이언트의 종류별 사용 키와 HUD. `network_service.gd`와 `inventory_net_module.gd`의 코드는 바뀌지 않았다(주석만).

**새 RPC 없음, 메시지 형식 변경 없음.** §14.18의 소비 의도(`_rpc_request_consume(request_id, item_instance_id)`)를 그대로 쓴다. 달라진 것은 서버가 그 아이템으로 하는 일과 결과 사유 코드 하나(`not_bleeding`)뿐이라 P2-T6만으로는 `PROTOCOL_VERSION`을 올리지 않았다(이 브랜치에서는 새 RPC가 생기는 P2-T8에서 한 번 올린다, docs/15 P2-145).

#### 데이터

- `ItemDefinition.treat_bleeding_wound_count`(정수, 0 이상): 한 단위가 지혈하는 출혈 상처 수. 0이면 지혈 효과가 없다(`stops_bleeding()`). `SurvivalSettings.max_wounds_per_player`(기본 64) 이상이면 사실상 "출혈 상처 전부"다. 음수는 정의 검증 오류다.
- `ItemDefinition.is_consumable()`의 뜻이 "사용 효과가 하나라도 있다"로 넓어졌다(먹기·마시기 효과만 묻는 것은 `lowers_needs()`). 효과가 없는 아이템의 사유 코드는 그대로 `not_consumable`이다.
- 개발용 정의 `dev_bandage`: 지혈 1곳, 최대 스택 5. 개발용 월드(`data/tuning/dev_world_seed.tres`)에 3개 묶음 하나를 (0, 0, −3)에 놓는다(§14.18의 목록에 추가).

#### 서버 규칙

`SurvivalService`(§14.6에 추가):

| API | 계약 |
|---|---|
| `bleeding_wound_ids(player_id) -> PackedStringArray` | 살아 있는 플레이어의 출혈 중인 상처 ID, **심한 순서**. 심한 정도 = 그 상처가 초당 깎는 체력 = 종류별 출혈 배율 × severity(§14.6의 출혈 피해식과 같은 값). 같으면 먼저 생긴 상처가 앞이다. 모르는 플레이어·죽은 플레이어는 빈 배열 |
| `check_stop_worst_bleeding(player_id, wound_count) -> String` | 같은 인자의 `stop_worst_bleeding`이 지금 성공하면 `""`, 아니면 그 실패 사유. 상태를 바꾸지 않는다 |
| `stop_worst_bleeding(player_id, wound_count, source_id) -> ActionResult` | 심한 순서로 최대 `wound_count`개의 출혈을 멈춘다(상처마다 기존 `stop_bleeding`을 호출: 상처는 남고 `is_bleeding`만 false가 되며, 상처마다 기존 이벤트 `player_bleeding_stopped`가 큐와 로그에 남는다). 성공 이벤트 `{event_type: "player_bleeding_treated", player_id, source_id, wound_ids: [String](심한 순서), remaining_bleeding_wounds: int, world_time}`는 반환값과 로그로만 쓰인다. 실패 사유: `bad_wound_count`(1 미만), `unknown_player`, `player_dead`, `not_bleeding`(출혈 중인 상처가 없음). 실패하면 아무것도 바뀌지 않는다 |

`ItemConsumption.try_consume`(§14.18)의 일반화:

- 아이템 정의의 사용 효과마다 "지금 적용되는가"를 본다. 먹기·마시기 효과는 조건 없이 적용된다(욕구가 0이어도 소비됨, P2-122 그대로). 지혈 효과는 출혈 중인 상처가 하나라도 있을 때만 적용된다.
- **적용되는 효과가 하나라도 있으면 승인**하고, 적용되지 않는 효과는 건너뛴다. 하나도 없으면 거부하고 아이템을 소비하지 않는다. 그래서 붕대만 있는 아이템은 출혈이 없을 때 `not_bleeding`으로 거부되고 그대로 남는다(먹기와 다른 규칙: 치료품은 낭비되지 않는다, docs/15 P2-141). 음식이면서 지혈도 하는 아이템(지금은 테스트용 정의뿐)은 출혈이 없어도 음식으로 소비된다.
- 검사 순서에 `not_bleeding`이 마지막으로 추가됐다: `not_online` → `consumption_unavailable` → `unknown_player`/`player_dead` → `unknown_item` → `item_not_in_inventory` → `not_consumable` → `bad_need_amount` → `not_bleeding`. 소유 검사가 여전히 정의 검사보다 앞이다.
- 원자성은 §14.18과 같다: 모든 조건을 먼저 검사한 뒤 `remove_player_item`(한 단위) → 적용되는 효과들(`reduce_needs`, `stop_worst_bleeding`) 순서로 확정한다. 거부된 요청은 아이템도 상처도 바꾸지 않는다.
- 대상은 항상 아이템을 쓰는 플레이어 자신이다. 요청에는 대상 플레이어·상처를 지정할 인자가 없다(어느 상처를 멈출지는 서버가 심한 순서로 정한다). P2-T12부터 가까이 있는 다른 플레이어에게도 쓸 수 있다: 이 소비 의도는 그대로 자기 자신만 치료하고, 남을 치료하는 것은 대상 인자가 있는 별도 의도다(§14.27). 상처는 여전히 고를 수 없다.
- 성공 이벤트 `item_consumed`에 `bleeding_stopped_wound_ids: [String]`(심한 순서, 없으면 빈 배열)가 추가됐다. 복제되지 않는다.

#### 복제·정보 공개·저장

- 복제는 기존 경로 그대로다. 줄어든 묶음·없어진 아이템은 `InventoryNet`이 소유자에게만 보낸다(§14.17). 지혈은 §14.14의 본인 전용 이벤트 `player_bleeding_stopped`(`wound_id`)와 본인 스냅샷(`wounds[].is_bleeding`)으로 간다. 결과(`_rpc_consume_result`)는 요청자에게만 간다.
- 정보 공개(ADR-009): 다른 플레이어는 누가 붕대를 썼는지, 누구의 상처가 출혈 중인지·지혈됐는지 어떤 메시지로도 받지 않는다. 다른 플레이어가 상처에 대해 받는 것은 여전히 피격 순간의 공개 `player_wounded`(부위·종류)뿐이다(테스트: 다른 클라이언트의 생존 이벤트·결과·인벤토리 메시지 0개, 공개 피격 이벤트의 키 목록 고정).
- 저장: 먹기와 같다(§14.18). 붕대 사용만으로는 저장하지 않고 다음 저장에 들어가며, `InventoryNetSettings.save_after_consume`을 켜면 결과 전송 전에 저장한다. 지혈 상태는 기존 `Wound.is_bleeding`(생존 fragment)이라 스키마 변경이 없다. 비정상 종료 뒤에는 "붕대도 돌아오고 출혈도 돌아온" 마지막 저장으로 복구된다.

클라이언트 표시(`scripts/presentation/`): 사용 키가 종류별로 나뉘었다. `ConsumeIntentPolicy.Kind`(FOOD/DRINK/BANDAGE)와 `first_item_id_of_kind(inventory, catalog, kind)`가 인벤토리 미러에서 그 종류의 첫 아이템을 고르고(P2-T3의 `first_consumable_item_id`를 대체), `count_of_kind`가 보유 수를 센다. 키는 `ClientPresentationSettings.consume_key`(음식, 기본 F. 이름은 P2-T3 그대로), `drink_key`(물, 기본 G), `bandage_key`(붕대, 기본 B)이고 `ClientInputActions.USE_ACTION_KINDS`가 액션과 종류를 잇는다. 세 키는 서로 달라야 한다(설정 검증). 생존 HUD 끝에 `ClientPresentationFormatter.build_treatment_lines`의 줄 "출혈 중 (N곳) | 붕대 M개 [B]"(출혈이 없으면 "출혈 없음")이 붙는다. 결과 문구는 "아이템 사용 승인/거부: 사유"로 바뀌었다.

테스트: `tests/unit/bandage_test.gd`(심한 순서와 동률 규칙, `stop_worst_bleeding`의 성공·이벤트·거부 사유, 붕대 사용 뒤 출혈 피해가 멈춤, 정의의 상처 수만큼 지혈, 출혈이 없으면 거부되고 묶음이 그대로임, 죽은 플레이어 거부, 음식+붕대 효과 아이템, 정의 데이터와 검증, 기본 개발용 월드의 붕대, 저장 → 재생성 → 로드), `tests/integration/bandage_net_test.gd`(서버 1 + 클라이언트 2, 실제 ENet: 붕대를 쓰면 서버와 본인 미러의 상처 출혈 상태·인벤토리가 일치하고 다른 클라이언트는 아무것도 받지 않음, 출혈이 없을 때의 거부, 조작된 요청 13종(남의 붕대, 상처 ID를 아이템 ID로 보냄, 형식 오류)과 인자를 더 붙인 호출, 죽은 플레이어, 저장 방침과 서버 재시작), `tests/unit/client_presentation_test.gd`(종류별 첫 아이템 선택과 보유 수, 키 등록·검증, 출혈·붕대 HUD 줄).

### 14.22 치료제(P2-T7, 사용자 결정 2026-11-15)

플레이어가 들고 있는 치료제 한 단위를 쓰면 서버가 그 플레이어의 감염을 해제한다. 치료 가능한 단계까지만이다. §14.6의 서버 seam `apply_infection_treatment`을 아이템과 연결한 것이며 치료 규칙 자체(설정된 최대 단계까지 성공, `not_infected`, `too_late`)는 바꾸지 않았다. 임시 가정은 docs/15 §12.2 P2-146~P2-149.

구성: `ItemDefinition.cures_infection`, `SurvivalService.check_infection_treatment`(사전 검사), `ItemConsumption`의 치료 효과(§14.21의 일반 규칙에 효과 하나 추가), 개발용 아이템 정의 `dev_cure`, 개발용 월드 배치, 클라이언트 치료제 키와 HUD 줄. **새 RPC 없음, 메시지 형식 변경 없음**(§14.18의 소비 의도 그대로. 결과 사유 코드 `not_infected`, `too_late`가 소비 결과에도 나올 수 있게 됐다).

#### 데이터

- `ItemDefinition.cures_infection`(bool, 기본 false): 한 단위가 감염을 해제하는 아이템. **어느 단계까지 듣는지는 아이템 데이터가 아니라 서버 규칙**(`SurvivalSettings.infection_treatment_max_stage`, 기본 `EARLY`)이다. 치료제마다 다른 단계·품질은 없다(docs/15 P2-146).
- `is_consumable()`에 포함된다. 개발용 정의 `dev_cure`: 최대 스택 3. 개발용 월드에 2개 묶음 하나를 (−4, 0, 0)에 놓는다.

#### 서버 규칙

- `SurvivalService.check_infection_treatment(player_id) -> String`: `apply_infection_treatment`이 지금 성공하면 `""`, 아니면 그 실패 사유(`unknown_player`, `player_dead`, `not_infected`, `too_late`). 상태를 바꾸지 않는다. `apply_infection_treatment`은 이 검사를 쓰도록 정리했고 동작·이벤트(`player_infection_cured`: `player_id`, `source_id`, `from`, `world_time`)는 그대로다. 아이템이 일으킨 치료의 `source_id`는 그 아이템 인스턴스 ID다.
- `ItemConsumption.try_consume`: 치료 효과는 "감염돼 있고 치료 가능한 단계"일 때만 적용된다. §14.21의 일반 규칙(적용되는 효과가 하나라도 있으면 승인, 없으면 거부·보존) 그대로라서, 치료제만 있는 아이템은 **감염되지 않았으면 `not_infected`, 단계가 지났으면 `too_late`로 거부되고 소비되지 않는다**. 검사 순서의 끝에 `not_infected`/`too_late`가 추가됐다(지혈과 치료 효과가 모두 있고 둘 다 적용되지 않으면 지혈 쪽 사유 `not_bleeding`이 먼저다).
- 원자성은 §14.18·§14.21과 같다: 모든 조건을 먼저 검사한 뒤 `remove_player_item`(한 단위) → 적용되는 효과 순서로 확정한다. 거부된 요청은 아이템도 감염 상태도 바꾸지 않는다(단위 테스트: 거부 경우마다 인벤토리 스냅샷과 생존 fragment가 그대로이고 트랜잭션·이벤트가 0개).
- 해제는 기존 규칙대로 감염 상태를 통째로 초기화한다(단계·경과 시간·노출 경로·감염원 모두). 면역은 없다: 다시 노출되면 다시 감염될 수 있고 단계 시계는 처음부터다. 이미 받은 감염 체력 감소는 돌려주지 않는다.
- 대상은 항상 아이템을 쓰는 플레이어 자신이다(요청에 대상 인자가 없다). P2-T12부터 다른 플레이어에게도 쓸 수 있다(대상 인자가 있는 별도 의도, §14.27). 그 경우 결과 사유(`not_infected`, `too_late`, 승인)로 상대의 감염 여부가 치료하는 쪽에 드러난다: 사용자가 감수하기로 한 범위이고 그 밖의 정보는 드러나지 않는다.
- 성공 이벤트 `item_consumed`에 `infection_cured_from: String`(해제된 단계 이름, 치료가 없었으면 `""`)이 추가됐다. 복제되지 않는다.

#### 복제·정보 공개·저장

- 복제는 기존 경로 그대로다. 인벤토리 변화는 `InventoryNet`이 소유자에게만(§14.17), 치료는 §14.14의 본인 전용 이벤트 `player_infection_cured`와 본인 스냅샷(`infection_stage: "none"`)으로 간다. 결과는 요청자에게만 간다.
- 정보 공개(ADR-009): 감염 여부와 단계는 본인만 안다. 다른 플레이어는 감염도, 치료제 사용도, 거부 사유도 받지 않는다(테스트: 감염 → 치료 → 거부가 일어나는 동안 다른 클라이언트의 생존 이벤트 0개·생존 미러 변경 알림 0회·결과 0개·인벤토리 메시지 0개, 이벤트 기록에 감염 관련 단어 없음).
- 거부 사유와 정보: 요청자가 거부 사유로 알게 되는 것은 **자기 자신의** 감염 상태뿐이고, 그것은 이미 본인 HUD에 나오는 정보다(잠복기에도 본인은 감염 단계를 받는다, §14.14). 그래서 지금 설계에서는 "감염되지 않았으면 소비 없이 거부"가 새 정보를 주지 않는다. 다만 이후 "잠복기에는 본인도 감염 여부를 모른다"로 바뀐다면, 이 규칙은 치료제를 눌러 보는 것만으로 감염 여부를 알아내는 수단이 된다(거부 = 비감염). 그때는 "감염과 무관하게 소비된다"로 바꿔야 한다. 제품 결정이라 docs/15 P2-147에 [사용자 확인 필요]로 적었다.
- 저장: 먹기·붕대와 같다(§14.18). 사용만으로는 저장하지 않고 다음 저장에 들어간다. 감염 상태는 기존 생존 fragment라 스키마 변경이 없다.

클라이언트 표시: `ConsumeIntentPolicy.Kind.CURE`, 키 `ClientPresentationSettings.cure_key`(기본 V), 액션 `ClientInputActions.USE_CURE`. 사용 키 넷(음식·물·붕대·치료제)은 서로 달라야 한다. 생존 HUD의 치료 줄이 둘이 됐다: "출혈 … | 붕대 M개 [B]"와 "감염: 단계 | 치료제 M개 [V]"(감염이 없으면 "감염 없음"). HUD는 "지금 치료가 듣는 단계인가"를 판단하지 않는다(서버 규칙이고 거부 사유 `too_late`로 알린다).

테스트: `tests/unit/cure_test.gd`(사전 검사와 치료 규칙의 일치, 잠복·초기 단계에서 해제와 이벤트·한 트랜잭션·이후 진행 없음, 진행·중증·말기에서 거부되고 묶음과 감염이 그대로임, 비감염·남의 것·월드의 것·오프라인·죽은 플레이어 거부, 치료 가능 단계가 설정에서 옴, 재감염과 재치료, 지혈+치료 효과 아이템의 네 경우, 정의 데이터, 기본 개발용 월드의 치료제, 저장 → 재생성 → 로드), `tests/integration/cure_net_test.gd`(서버 1 + 클라이언트 2, 실제 ENet: 감염 → 치료제 → 서버와 본인 미러의 감염 단계가 none이고 다른 클라이언트는 아무것도 받지 않음, 비감염 거부, 남을 치료할 수 없음(남의 치료제, 플레이어 ID를 아이템 ID로 보냄, 인자를 더 붙인 호출), 너무 늦은 단계의 거부와 초기 단계의 승인, 저장 방침과 서버 재시작), `tests/unit/client_presentation_test.gd`(치료제 선택·키·검증, 감염·치료제 HUD 줄).

### 14.23 수면(P2-T8, 사용자 결정 2026-11-15)

플레이어가 "눕기"와 "일어나기" 의도를 보내면 서버가 쉬는 동안 그 플레이어의 피로를 낮춘다. 이 절이 §14.6의 "피로는 시간에 따라 증가한다"보다 우선한다(쉬는 플레이어의 피로는 줄어든다). 임시 가정은 docs/15 §12.3 P2-150~P2-158.

**P2-T10에서 바뀐 것(§14.25가 우선)**: 회복 속도(월드 8시간 → 3.2시간), 위험할 때 저절로 깸(시간 피해로 누운 채 죽지 않음), 위험할 때 눕기 거부, 자는 중 피격은 죽이지 않음. 아래 본문에서 해당하는 곳에 표시했다.

**P2-T11에서 바뀐 것(§14.26)**: 자는 것은 자세 모델(서 있음/엎드림/누워 잠)의 한 상태가 됐다. 눕기·일어나기는 이 절의 휴식 RPC로도, `PostureNet`의 "원하는 자세" 의도(`resting`/`standing`)로도 요청할 수 있고 둘 다 `SurvivalService.start_rest`/`stop_rest`로 끝나 규칙이 같다(이 절의 RPC·형식·테스트는 그대로다). 엎드린 채 누우면 엎드림이 끝나고, 깨면 서 있는 자세다. 자는 플레이어는 좀비에게 조금 덜 보인다(가시성 0.8).

구성: `SurvivalSettings`(휴식 수치 2개), `SurvivalService`(휴식 상태와 규칙), `ServerSystem.player_action_block_reason`의 뜻 확장, `CombatService`·`ItemConsumption`(휴식 중 거부), `SurvivalNetModule`(휴식 의도 RPC와 결과, 복제), `SurvivalNetSettings`(요청 빈도), `ClientSurvivalState`(누가 누워 있는지), 클라이언트 휴식 키·HUD·누운 캡슐. `network_service.gd`는 수정하지 않았다.

**프로토콜 변경 있음**: RPC 2개(`_rpc_request_rest`, `_rpc_rest_result`)가 새로 생기고, 생존 본인 스냅샷·공개 행·접속 조각에 `resting`이 추가됐으며(스키마 3, §14.14), 공개·본인 이벤트 `player_rest_started`/`player_rest_ended`가 생겼다. `BuildInfo.PROTOCOL_VERSION`을 6으로 올렸다(P2-T6~T8 묶음에서 한 번).

#### 데이터

`SurvivalSettings`(`data/tuning/survival_settings.tres`):

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `rest_fatigue_hours_from_max` | 3.2(P2-T10 전에는 8.0) | 쉬어서 피로가 최대(100)에서 0이 되는 데 걸리는 **월드 시간(달력 시간)**. 24배속에서 실제 8분(전에는 20분). 쉬는 동안의 피로 변화율은 `−need_max / (이 값 × 3600)` 월드초당이고, 쉬는 동안 피로는 오르지 않는다 |
| `rest_hunger_thirst_rate_multiplier` | 1.0 | 쉬는 동안 허기·갈증 증가율에 곱하는 값. 1 = 깨어 있을 때와 같다(계속 오른다). 0이면 쉬는 동안 오르지 않는다 |

둘 다 유한값이어야 하고 첫째는 0보다 커야 하며 둘째는 0 이상이어야 한다(`validate()`).

#### 서버 규칙(`SurvivalService`, §14.6에 추가)

| API | 계약 |
|---|---|
| `is_resting(player_id) -> bool` | 누워 쉬는 중인지. 모르는 플레이어는 false |
| `start_rest(player_id) -> ActionResult` | 눕는다. 성공 이벤트 `{event_type: "player_rest_started", player_id, world_time}`를 돌려주고 큐·로그에 남긴다. 실패 사유(순서대로): `unknown_player`, `player_dead`, `not_online`, `already_resting`, `cannot_rest_<위험>`(P2-T10, §14.25). 실패하면 아무것도 바뀌지 않는다. 피로가 0이어도, 출혈·감염 중이어도 누울 수 있다. 단 P2-T10부터 깨는 조건에 이미 해당하면(체력 30% 이하, 허기·갈증 위험, 감염 말기) 누울 수 없다 |
| `stop_rest(player_id) -> ActionResult` | 일어난다. 성공 이벤트 `{event_type: "player_rest_ended", player_id, cause: "requested", world_time}`. 실패 사유: `unknown_player`, `not_resting` |

쉬는 동안:

- **피로**: 설정 속도로 줄고 0 아래로 내려가지 않는다. 0이 돼도 일어나지 않는다(일어나기 의도, 피격, 사망, 퇴장으로만 끝난다). 범주가 바뀌면 기존 `need_category_changed` 이벤트가 나간다.
- **허기·갈증**: 계속 오른다(설정 배율). P2-T8에서는 쉬는 중에도 굶주림·탈수로 죽을 수 있었으나, P2-T10부터 허기나 갈증이 위험 범주에 닿는 순간 깬다(§14.25).
- **이동 불가**: `player_movement_multiplier`가 0을 돌려준다. `ServerWorld.step_movement`가 그 플레이어를 건너뛰므로 이동 의도는 받아들여지지만(요청 자체를 거부하지는 않는다) 위치가 바뀌지 않는다. 이동 의도로는 깨지 않는다. 의도에 실린 yaw는 반영된다(누운 채 방향만 바뀐다). 발소리는 이동 거리로만 생기므로(§14.11) 나지 않는다.
- **공격·아이템 행동 불가**: `player_action_block_reason`이 `player_resting`을 돌려준다(죽은 플레이어의 `player_dead`가 먼저다). 이 훅을 묻는 곳이 모두 거부한다: 줍기·내려놓기(`ServerWorld.try_pickup`/`try_drop_item`, §14.19와 같은 경로), 근접 공격(`CombatService.request_melee_attack`: `player_dead` 다음에 추가, 스태미나·쿨다운·소음·이벤트 없음, §14.10), 아이템 사용(`ItemConsumption.try_consume`: `player_dead` 다음에 추가). 누운 채로는 먹거나 붕대를 감을 수 없고 먼저 일어나야 한다. 거부된 요청은 플레이어를 깨우지 않는다. 훅의 뜻이 "아이템을 다룰 수 있는가"에서 "행동할 수 있는가"로 넓어졌다(docs/15 P2-129에서 예고한 통합).
- **피해**: 출혈·굶주림·탈수·감염의 시간 피해는 계속 적용된다. 피해 자체는 깨우지 않지만, P2-T10부터 그 피해로 체력이 기준(최대의 30%) 이하가 되는 순간 깬다(§14.25: 누운 채 죽지 않는다). 자연 회복도 조건(모든 욕구 양호, 출혈·감염 체력 감소 없음)이 맞으면 쉬는 중에 그대로 일어난다. 피로가 주의 이상이던 플레이어는 쉬어서 피로가 양호가 되는 순간부터 회복이 시작된다.

휴식이 끝나는 경우:

| 원인 | 이벤트 `player_rest_ended`의 `cause` | 설명 |
|---|---|---|
| 일어나기 의도 | `requested` | `stop_rest` |
| 피격 | `damaged` | `apply_damage`가 성공하면 그 자리에서 깬다(좀비 공격 포함). P2-T10부터 자는 중의 피격은 죽이지 않으므로(§14.25) 항상 깬다. 이벤트 순서는 `player_wounded` → `player_rest_ended` |
| 위험(P2-T10) | `low_health`, `thirst`, `hunger`, `infection` | 체력이 기준 이하, 갈증·허기가 위험 범주, 감염이 설정 단계에 도달한 순간(§14.25) |
| 사망 | `died` | 순서는 (시간 피해 묶음) → `player_rest_ended` → `player_died`. 새 캐릭터는 서서 시작한다. P2-T10부터 누운 채 죽는 경우는 감염 기상 단계를 끈 설정에서의 좀비화뿐이다 |
| 퇴장 | 이벤트 없음 | `on_player_offline`에서 조용히 해제한다. 다른 클라이언트는 그 플레이어 자체를 지운다. 다시 접속하면 서 있다 |

구간 적분(§14.6, §14.16): 쉬는 플레이어의 욕구 변화율만 다르다. `_advance_player`가 구간마다 그 플레이어가 쉬는 중인지 읽어 욕구 변화율(`SurvivalSettings.resting_need_rate_per_world_sec`: 피로는 음수)을 고른다. 음수 변화율에 맞춰 세 곳을 일반화했다: (1) 자연 회복 구간은 "모든 욕구가 양호한 시간"인데, 내려가는 욕구가 주의 임계를 지나는 시각부터 열리고 올라가는 욕구가 임계에 닿는 시각에 닫힌다. (2) 스태미나 회복의 욕구 배율 경계는 양방향 임계 통과를 모두 센다. (3) 욕구 값은 0~최대로 자른다. 그래서 큰 틱 하나와 60Hz 틱 여러 개의 결과가 같다(배율 24에서 피로·허기·갈증·체력·스태미나를 비교하는 테스트, 허용 오차 0.01). 한 틱 안에서 휴식이 끝나는 경우는 사망과, P2-T10부터의 위험 기상이다(§14.25: 기상 시점이 구간 경계이고 그 뒤는 깨어 있는 변화율을 쓴다). 틱 도중에 시작되지는 않는다(시작은 틱 사이의 요청이다).

좀비: 규칙을 바꾸지 않았다. 쉬는 플레이어도 살아 있고 접속 중인 플레이어라서 지금까지와 똑같이 시야에 들면 추격·공격 대상이다. 덜 보이지도 더 잘 보이지도 않고, 소리를 내지 않는다는 것만 다르다(발소리가 없으므로 소리로는 찾아오지 않는다). 첫 공격이 플레이어를 깨운다(docs/15 P2-156). P2-T10부터 그 첫 공격은 체력을 1 아래로 내리지 못한다(§14.25). 자는 플레이어가 덜 보이게 되는 것은 P2-T11(§14.26)이다.

저장: 쉬는 상태는 **저장하지 않는다**. 생존 fragment(스키마 v4)와 world_state는 그대로다. 근거: 퇴장하면 해제되므로 정상 종료(서버가 플레이어를 내보낸 뒤 저장)로는 "쉬는 중"이 저장될 일이 없고, 자동 저장 직후 비정상 종료한 경우에도 재시작 뒤에는 접속자가 없어 쉬는 사람이 있을 수 없다. 낮아진 피로는 기존 필드 `fatigue`로 저장된다. 눕기·일어나기는 그것만으로 저장을 일으키지 않는다.

#### 네트워크 메시지(`SurvivalNetModule`에 추가)

| 방향 | RPC | 채널/모드 | 받는 쪽 검증 |
|---|---|---|---|
| C→S | `_rpc_request_rest(request_id: int, lie_down: bool)` | 0 reliable | 아래 "요청 검증" |
| S→요청자 | `_rpc_rest_result(request_id: int, ok: bool, reason: String)` | 0 reliable | 서버 발신만 수용, 타입, `request_id` ≥ 0, `reason` 길이 ≤ 64, `ok`일 때만 `reason`이 빈 문자열 |

의도 설계: 토글이 아니라 **원하는 상태**를 보낸다(`lie_down`: true = 눕기, false = 일어나기). 이유: 클라이언트 미러가 한 박자 늦을 때(예: 방금 피격으로 깼는데 일어나기 키를 누름) 토글은 반대 동작(다시 눕기)이 되지만, 원하는 상태를 보내면 `not_resting`으로 거부될 뿐이다. 대상 플레이어 인자는 없다: 행위자는 보낸 peer의 플레이어이고, 다른 플레이어를 눕히거나 깨울 수 없다. 인자를 더 붙인 호출은 엔진이 거부한다(테스트로 고정).

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 바뀌지 않고 `rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드 | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | `request_id`가 int가 아니거나 `lie_down`이 bool이 아님(정수 1, 문자열, null, 배열 모두 거부) | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `rate_limited` | peer별 토큰 버킷(`SurvivalNetSettings.rest_intent_rate_per_sec`/`rest_intent_burst`, 기본 4/s·버스트 4). 형식이 틀린 요청은 토큰을 쓰지 않는다 | 보냄 |
| 5 | `rest_unavailable` | 월드에 생존 시스템이 없음(조립 오류) | 보냄 |
| 6 | `SurvivalService`의 사유(`player_dead`, `already_resting`, `not_resting` 등) | 규칙이 거부. 정상 플레이에서 흔하므로 횟수만 센다 | 보냄 |

승인되면 서버는 그 자리에서 대기 중인 생존 이벤트를 내보낸 뒤 결과 `(request_id, true, "")`를 보낸다. 같은 채널이라 요청자는 자기 상태 변화(본인 이벤트)를 결과보다 먼저 받는다.

복제와 정보 공개(ADR-009):

| 받는 쪽 | 받는 것 |
|---|---|
| 본인 | 본인 스냅샷의 `resting`, 이벤트 `player_rest_started`(`world_time`), `player_rest_ended`(`cause`, `world_time`), 그리고 기존대로 자기 피로 범주(`need_category_changed`, 본인 스냅샷) |
| 다른 플레이어 | 공개 이벤트 `player_rest_started`/`player_rest_ended`(`scope`, `event_type`, `player_id`, `world_time`뿐), 접속 조각과 새 접속자 알림의 공개 행 `{player_id, alive, resting}` |

"누워 있음"은 옆에서 보면 보이는 사실이라 공개한다(피격 부위, 사망과 같은 부류). 다른 플레이어가 받지 않는 것: 피로를 비롯한 욕구의 수치와 범주, 일어난 원인(`cause`), 쉬어서 무엇이 회복됐는지. 원인 중 `damaged`와 `died`는 같은 순간의 공개 `player_wounded`/`player_died`로 짐작할 수 있다. 거리·시야 제한은 없다(다른 공개 이벤트와 같다, P2-115). 늦게 접속한 플레이어는 접속 조각으로 누가 누워 있는지 받는다.

`ClientSurvivalState`: `is_resting(player_id) -> bool`(본인과 다른 플레이어 모두), 시그널 `player_resting_changed(player_id, resting)`. 본인 스냅샷과 공개 행에 `resting`이 없거나 bool이 아니면, 또는 죽었는데 `resting`이 true이면 그 페이로드를 통째로 버린다. 사망·새 캐릭터 이벤트는 그 플레이어의 `resting`을 false로 둔다.

클라이언트 표면(`SurvivalNetModule`): `request_rest(lie_down: bool) -> int`(요청 번호, 1부터. join 전이면 `NO_REQUEST`), `signal rest_result(request_id, ok, reason)`, `send_raw_rest_request(request_id, lie_down)`(테스트 전용).

클라이언트 표시(`scripts/presentation/`): 휴식 키(`ClientPresentationSettings.rest_key`, 기본 R)를 누르면 본인 미러가 누워 있으면 "일어나기", 아니면 "눕기"를 보낸다(요청 사이 최소 간격 `rest_min_interval_sec`). 휴식 키는 사용 키 넷과 달라야 한다. 생존 HUD 끝에 "눕기 [R]" 또는 "휴식 중 (피로 회복) | 일어나기 [R]" 줄이 붙는다(죽은 캐릭터에게는 없다). 누워 있는 플레이어의 캡슐은 본인 것이든 남의 것이든 `rest_tilt_rad`만큼 기울여 바닥에 눕히고 색은 살아 있는 색 그대로다(죽은 캡슐은 어두운 색). 결과는 사용 결과와 같은 자리에 "휴식 요청 승인/거부: 사유"로 표시한다.

테스트: `tests/unit/rest_test.gd`(설정 기본값·검증, 눕기·일어나기의 이벤트와 거부 사유, 피로 감소 속도와 깨어 있는 플레이어와의 비교, 0 하한과 범주 이벤트, 허기·갈증 배율 설정, 틱 크기 무관(1틱·1500틱·7틱), 달력 시간 배율(1배와 24배), 이동 불가, 공격·줍기·내려놓기·아이템 사용 거부, 피격 시 깸과 이벤트 순서, 사망·퇴장 해제와 새 캐릭터, 시간 피해로는 깨지 않고 죽을 수 있음, 저장에 들어가지 않음과 재시작), `tests/integration/rest_net_test.gd`(서버 1 + 클라이언트 2~3, 실제 ENet: 눕기 → 서버·본인 미러·다른 클라이언트 미러 일치, 이동 의도 무시, 피로 범주가 본인 미러에만 반영, 다른 클라이언트가 받는 이벤트의 키 목록 고정, 일어나기 뒤 이동 재개, 좀비 공격으로 깸과 양쪽 이벤트, 휴식 중 공격·줍기 거부, 휴식 중 사망, 조작된 요청 8종과 잘못된 상태·남을 깨우려는 요청·인자를 더 붙인 호출·클라이언트가 보낸 서버 메시지, join 전 요청, 빈도 초과, 늦은 접속과 누운 채 퇴장·재접속, 저장되지 않음과 서버 재시작, 설정·검증 규칙과 RPC 구성, 미러의 페이로드 검증), `tests/unit/client_presentation_test.gd`(휴식 키 등록·검증, HUD 줄, 결과 문구, 캡슐 자세).
### 14.24 캐릭터 이름·외형 커스터마이징(P2-T9, docs/00 ADR-015)

플레이어는 캐릭터를 만들 때 이름과 외형을 정한다. 서버가 검증하고 저장하며, 월드에 있는 모든 캐릭터의 이름과 외형을 모든 접속자에게 복제한다. 캐릭터가 아직 없는 접속자는 월드에 존재하지 않는다. 영구 사망(§14.19) 뒤의 새 캐릭터는 대기 시간이 지난 뒤 **플레이어가 만들어야** 시작한다. 전용 서버에서는 이 절이 §14.19의 "대기 시간 뒤 새 캐릭터가 저절로 시작한다"보다 우선한다. 임시 가정은 docs/15 §13 P2-160~P2-179.

구성: 외형 정의 `AppearanceOption`·`AppearanceSlot`(정적 Resource)과 `AppearanceCatalog`, `CharacterSettings`(이름 규칙 등), `CharacterNameRules`, `CharacterProfile`(런타임 상태), `CharacterRules`(모두 `scripts/domain/player/`), `PlayerState.character`(플레이어 파일 스키마 v4), `ServerWorld`(접속과 월드 진입의 분리, `create_character`), `ServerSystem` 훅 2개, `SurvivalService`(생성 필수일 때 자동 시작하지 않음), NetModule `CharacterNetModule`과 미러 `ClientCharacterState`, `SurvivalNetModule`·`ClientSurvivalState`(캐릭터 없는 접속자의 접속 조각), 클라이언트 생성 화면·캡슐 외형·이름표, 실행 인자 `--character-name=`.

**프로토콜 변경 있음**: 새 모듈 `CharacterNet`(RPC 4개와 접속 조각), 캐릭터가 없는 접속자라는 새 상태(누구의 스냅샷에도 없고, `_rpc_player_joined`는 첫 캐릭터가 생길 때 나간다), `SurvivalNet` 접속 조각의 `self` 생략 형식. `BuildInfo.PROTOCOL_VERSION`을 7로 올렸다.

**`network_service.gd`를 수정했다**(P2-0 동결 이후 처음, 아래 "접속과 월드 진입" 참조). 접속 핸드셰이크의 인자와 응답 형식은 그대로이고, "캐릭터 없는 접속자를 다른 peer에게 알리지 않는다"는 조건과 공개 헬퍼 `announce_player_entered(player_id)` 하나가 추가됐다.

#### 실제 서버에 적용되는 기본 동작

| 실행 방식 | 캐릭터 생성 | 어디서 정해지나 |
|---|---|---|
| 전용 서버(`tools/run_server.sh`, `--server`, 서버 빌드) | **필수**. 처음 접속한 플레이어는 캐릭터를 만들기 전까지 월드 밖이고, 죽은 뒤에는 대기 시간이 지나고 플레이어가 새 캐릭터를 만들어야 시작한다 | `data/tuning/character_settings.tres`의 `server_requires_character_creation`(기본 true). `GameBootstrap`이 서버를 시작할 때 이 값을 `CompositionConfig.require_character_creation`에 넣는다 |
| 조립을 직접 만드는 코드(`CompositionConfig.from_defaults()`를 쓰는 테스트·도구, `ServerWorld.new()`) | **불필요(호환 기본값)**. `ServerWorld.join()`이 캐릭터 없는 플레이어에게 기본 캐릭터(기본 이름 + 항목별 기본 선택지)를 바로 주고, 죽은 뒤에는 P2-T4처럼 대기 시간 뒤 저절로 다음 캐릭터가 시작한다(이름·외형은 그대로) | `CompositionConfig.require_character_creation`의 기본값 false, `ServerWorld.require_character_creation`의 기본값 false |

호환 기본값을 둔 이유: P2-T9 이전의 단위·통합 테스트 수백 개가 "`world.join()` 직후 플레이어가 월드에 있다"를 전제로 한다. 생성 필수 동작은 새 테스트(`character_creation_test`, `character_net_test`, `character_creation_screen_test`)와 프로세스 3개 스모크가 확인한다. Phase 1·2 수용 시나리오는 호환 기본값으로 실행된다.

화면 없이 만드는 경로(헤드리스·자동 클라이언트): 클라이언트 실행 인자 `--character-name=<이름>`. 서버가 "만들 수 있다"고 알릴 때마다(접속 직후, 죽은 뒤 대기 시간이 지났을 때) 그 이름과 기본 외형으로 생성 의도를 자동으로 보낸다. 서버가 거부하면(예: 이름 규칙 위반) 오류 로그를 남기고 자동 경로를 끈다(요청 반복 없음). 이 인자가 없으면 생성 화면이 뜬다. `tools/smoke_test.sh`의 두 클라이언트가 이 인자를 쓴다. 코드에서는 `CharacterNetModule.set_auto_create(name, appearance = {})`.

#### 데이터: 외형 정의

`resources/definitions/appearance/*.tres`에 항목(`AppearanceSlot`) 하나당 파일 하나. 선택지(`AppearanceOption`)는 그 파일의 하위 Resource다. `AppearanceCatalog.load_directory()`가 폴더의 모든 파일을 읽고 `sort_order`(같으면 ID) 순으로 정렬한다. **항목이나 선택지를 늘리려면 파일만 고치면 된다**: 서버 검증, 저장, 복제, 생성 화면이 모두 카탈로그에서 읽는다(생성 화면에 새 항목 행이 생기는 것을 테스트로 고정).

| `AppearanceSlot` 필드 | 뜻 |
|---|---|
| `slot_id` | 안정된 snake_case ID(저장·전송에 쓰인다. 이름을 바꾸지 않는다) |
| `display_name` | 생성 화면에 표시하는 문구 |
| `sort_order` | 생성 화면에서의 순서 |
| `kind` | `style`(이름만 있는 모양), `color`(선택지의 `color`), `scale`(선택지의 `scale`) |
| `visual_role` | 임시 캡슐에 나타나는 방식: `""`(아직 표시 불가), `capsule_color`(`color` 항목만), `capsule_height`·`capsule_radius`(`scale` 항목만). 역할 하나에 항목 하나 |
| `options` | `AppearanceOption` 목록: `option_id`(안정된 ID), `display_name`, `color`, `scale` |
| `default_option_id` | 고르지 않았을 때의 선택지(이전 저장, 화면 없는 클라이언트, 나중에 추가된 항목) |

검증(`AppearanceSlot.validate`, `AppearanceCatalog.add`): ID 형식과 길이(64자 이하), 중복 선택지 ID, 기본값이 선택지에 있는지, 종류·역할 값, 역할과 종류의 짝, `scale` 범위(0.25~4), 표시 문구 유무, 중복 항목 ID, 같은 역할의 항목 둘, 항목 수 상한 64.

기본 데이터(수량과 값은 PROVISIONAL, docs/15 P2-163):

| 항목 ID | 표시 | 종류 | 선택지 수 | 기본값 | 캡슐 표시 |
|---|---|---|---|---|---|
| `body_type` | 체형 | scale | 6(0.85~1.25) | `average` | 반지름 |
| `height` | 키 | scale | 7(0.88~1.12) | `average` | 높이 |
| `skin_tone` | 피부색 | color | 8 | `tone_3` | 표시 불가 |
| `hair_style` | 머리 모양 | style | 9 | `short` | 표시 불가 |
| `hair_color` | 머리색 | color | 9 | `black` | 표시 불가 |
| `top_color` | 상의 색 | color | 12 | `blue` | 캡슐 색 |
| `bottom_color` | 하의 색 | color | 10 | `denim` | 표시 불가 |

색은 **선택지 팔레트**다. 클라이언트는 색 값이 아니라 선택지 ID만 보내고, 서버는 그 ID가 정의에 있는지만 확인한다. 임의 RGB는 받지 않는다(docs/15 P2-161).

선택(`{항목 ID: 선택지 ID}`, 둘 다 문자열)을 다루는 세 규칙:

| 함수 | 쓰는 곳 | 규칙 |
|---|---|---|
| `check_selection(raw)` | 클라이언트가 보낸 요청 | Dictionary가 아니거나 키·값이 문자열이 아니면 `bad_type`, 항목 수보다 많으면 `appearance_too_large`(순회 전에 판정), 없는 항목 `unknown_appearance_slot`, 없는 선택지 `unknown_appearance_option`. **빠진 항목은 그 항목의 기본값으로 채운다**(거부하지 않는다, docs/15 P2-162) |
| `restore_selection(saved)` | 저장을 읽을 때 | 실패하지 않는다. 없어진 항목은 버리고, 없어진 선택지와 새로 생긴 항목은 기본값. 데이터를 고쳤다고 저장이 안 읽히는 일이 없게 한다 |
| `is_complete_selection(selection)` | 클라이언트 미러 | 모든 항목이 있고 그 밖의 키가 없으며 선택지가 모두 유효 |

#### 데이터: 이름 규칙

`CharacterSettings`(`data/tuning/character_settings.tres`). 모든 값이 PROVISIONAL이다.

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `server_requires_character_creation` | true | 전용 서버가 캐릭터 생성을 요구하는지(위 표) |
| `name_min_length` / `name_max_length` | 2 / 16 | 정리한 뒤의 글자 수(유니코드 코드 포인트. 한글 한 글자 = 1). 상한은 프로토콜 한계 64 이하 |
| `allowed_codepoint_ranges` | 공백, 0-9, A-Z, a-z, 한글 음절(가-힣) | 허용 문자를 `[처음, 끝]` 코드 포인트 쌍으로 적는다. 쌍을 추가하면 다른 문자도 허용된다. 제어 문자가 든 범위는 설정 검증에서 거부한다 |
| `banned_words` | 빈 목록 | 금칙어(대소문자 무시, 글자 사이 공백 무시). 지금은 seam만 있다 |
| `allow_duplicate_names` | true | false면 다른 플레이어의 현재 캐릭터와 같은 이름(대소문자 무시)을 `name_taken`으로 거부한다. 접속하지 않은 플레이어의 캐릭터도 포함한다 |
| `default_name` | `생존자` | 이름을 정한 적 없는 캐릭터의 이름(P2-T9 이전 저장, 호환 기본값의 기본 캐릭터). 이름 규칙을 통과해야 한다 |
| `share_character_generation` | false | 다른 플레이어에게 세대 번호를 알릴지(아래 "복제와 정보 공개") |
| `create_intent_rate_per_sec` / `create_intent_burst` | 1 / 3 | 생성 의도 빈도 제한(peer별 토큰 버킷) |
| `save_after_create` | true | 캐릭터가 만들어지면 결과를 보내기 전에 월드를 저장 |
| `max_player_id_length` | 128 | 클라이언트 미러의 방어용 길이 한계 |

`CharacterNameRules`(순수 함수. 생성 화면과 서버가 같은 코드를 쓰고 서버의 판정이 최종이다):

1. 원문이 64자를 넘으면 처리하기 전에 `name_too_long`.
2. 정리: 앞뒤의 공백·탭·줄바꿈·제어 문자를 잘라내고, 이름 안의 연속된 공백을 하나로 줄인다. **그 밖의 문자는 지우거나 바꾸지 않는다.**
3. 검사(순서대로): 빈 이름 `name_empty`, 짧음 `name_too_short`, 김 `name_too_long`, 허용 범위 밖 문자(이름 안의 제어 문자·탭·줄바꿈, 문장 부호, 한글 자모, 한자·가나, 전각 공백, 이모지 등) `name_bad_characters`, 금칙어 `name_banned`.

서버가 저장하고 복제하는 이름은 정리된 이름이다. 유니코드 정규화는 하지 않는다(분해된 자모로 들어온 한글은 허용 범위 밖이라 거부된다, docs/15 P2-177).

#### 상태 모델

`PlayerState.character: CharacterProfile`(이름 + 외형 선택). null이면 아직 캐릭터를 만든 적이 없다. `character_generation`(§14.19)은 그대로 1부터이고, 캐릭터가 없을 수 있는 것은 세대 1뿐이다(저장 검증).

`ServerWorld`는 **접속**과 **월드 진입**을 나눈다.

| 상태 | `is_player_connected` | `is_online` | 뜻 |
|---|---|---|---|
| 접속하지 않음 | false | false | |
| 접속했고 캐릭터 없음 | true | false | 월드 밖. 생성 필수일 때만 있는 상태 |
| 접속했고 캐릭터 있음(살았거나 죽음) | true | true | 월드 안 |

기존 규칙은 전부 `is_online()`·`online_player_ids()`·`on_player_online()`으로 플레이어를 본다. 그래서 캐릭터가 없는 접속자는 다른 코드 수정 없이: 이동 의도가 `not_online`으로 거부되고, 줍기·내려놓기·아이템 사용·근접 공격이 `not_online`으로 거부되며, 생존 상태(욕구·체력)가 없어 욕구가 오르지 않고 눕기도 거부되고(`unknown_player`), 좀비의 시야·공격 대상이 아니며, 발소리를 내지 않고, 위치 스냅샷과 접속 스냅샷에 없다. 좀비·소음·전투 코드는 수정하지 않았다. 월드 시계는 "월드 안에 누가 있는가"로 일시정지를 판단하므로, 캐릭터 없는 접속자만 있으면 멈춘다.

흐름:

| 순간 | 서버 동작 |
|---|---|
| 처음 접속(생성 필수) | `join()`이 플레이어를 만들고 접속 상태로만 둔다. `character_creation_block_reason` = `""`(만들 수 있음) |
| 첫 캐릭터 생성 | `create_character()` 성공 → 이름·외형 저장, 세대 1, 스폰 지점, 월드 진입(`on_player_online`: 생존 상태가 새로 만들어진다). `player_respawned` 이벤트는 없다 |
| 살아 있는 동안 | 생성 요청은 `character_alive`로 거부. 이름·외형 변경 기능은 없다(docs/15 P2-166) |
| 사망 | §14.19 그대로(소지품이 죽은 자리에 놓이고 죽은 캐릭터는 월드에 남는다). 이름·외형은 죽은 캐릭터의 것으로 남는다 |
| 대기 시간 동안 | 생성 요청은 `respawn_wait`로 거부 |
| 대기 시간 뒤(생성 필수) | **아무 일도 일어나지 않는다.** 플레이어가 만들 때까지 죽은 상태다(시간 제한 없음). 요청이 오면 `start_new_character(player_id, profile)`: 스폰 지점, 빈 인벤토리, 세대 +1, 새 이름·외형, 생존 상태 초기화, `player_respawned` 이벤트 |
| 대기 시간 뒤(호환 기본값) | P2-T4처럼 그 틱에 저절로 시작. 이름·외형은 이전 캐릭터의 것을 이어 쓴다 |
| 캐릭터 없이 퇴장 → 재접속 | 다시 "접속했고 캐릭터 없음" |
| 캐릭터를 가진 채 퇴장 → 재접속 | 접속 즉시 월드 안(생성 불필요). 죽은 캐릭터면 죽은 채로 들어오고, 대기 시간이 지났으면 바로 만들 수 있다 |

#### 서버 API

| API | 계약 |
|---|---|
| `ServerWorld.create_character(player_id, raw_name, raw_appearance) -> ActionResult` | 인자는 신뢰하지 않는 값(Variant). 검사 순서: 플레이어 상태(`character_creation_block_reason`) → 요청(`CharacterRules.check_request`: 타입, 이름, 외형) → 이름 중복. 성공 이벤트 `{event_type: "character_created", player_id, character_generation, name, appearance, position: [x, y, z], first_character: bool, dropped_item_instance_ids}`. 거부되면 아무것도 바뀌지 않는다 |
| `ServerWorld.character_creation_block_reason(player_id) -> String` | `""`이면 지금 만들 수 있다. 사유: `unknown_player`, `not_connected`, 캐릭터가 있는 플레이어에 대해 시스템이 답한 사유(`character_alive`, `respawn_wait`) |
| `ServerWorld.is_player_connected`, `has_character`, `connected_player_ids` | 조회 |
| `ServerWorld.start_new_character(player_id, profile = null)` | §14.19의 것에 `profile` 인자가 생겼다(없으면 이전 이름·외형 유지). 끝에 모든 시스템의 `on_character_started`를 부른다 |
| `ServerSystem.new_character_block_reason(player_id) -> String` | 새 훅(기본 `""`). 캐릭터가 있는 플레이어가 새 캐릭터를 만들어도 되는지. `SurvivalService`: 살아 있으면 `character_alive`, 죽었고 `died_at_action_time + respawn_delay_sec`이 지나지 않았으면 `respawn_wait` |
| `ServerSystem.on_character_started(world, player_id)` | 새 훅(기본 no-op). `start_new_character`가 월드 쪽 변경을 마친 뒤 부른다. `SurvivalService`가 여기서 생존 상태를 초기화하고 `player_respawned`를 낸다(예전에는 `SurvivalService`가 직접 했다. 자동 시작과 요청에 의한 시작이 같은 코드를 지난다) |
| `CharacterRules(settings, catalog)` | `check_request(raw_name, raw_appearance)`, `default_profile()`, `restore_profile(saved)`. `ServerWorld.character_rules`에 들어 있고 생성 화면도 같은 것을 쓴다 |

#### 접속과 월드 진입(`network_service.gd`의 변경)

P2-0 이후 동결된 `NetworkService`는 접속 핸드셰이크가 끝나면 무조건 다른 모든 peer에게 `_rpc_player_joined`를 보내고 모든 모듈의 `on_player_joined`를 불렀다. 캐릭터가 없는 접속자를 숨기려면 이 자리를 고칠 수밖에 없어 최소한으로 고쳤다.

| 변경 | 내용 |
|---|---|
| 핸드셰이크 끝 | 접속 스냅샷(`_rpc_join_accepted`)은 그대로 보낸다. `_rpc_player_joined` 방송, 모듈 `on_player_joined`, `player_joined` 시그널은 그 플레이어가 월드 안(`ServerWorld.is_online`)일 때만 한다 |
| 새 공개 헬퍼 `announce_player_entered(player_id)` | 접속해 있던 플레이어가 월드에 들어왔을 때(첫 캐릭터 생성) `CharacterNetModule`이 부른다. 핸드셰이크가 건너뛴 일을 한다: 모든 peer에게 `_rpc_player_joined`(본인 peer 포함. 본인의 접속 스냅샷에는 자기가 없었다), 모듈 `on_player_joined`, `player_joined` 시그널 |
| 퇴장 | 월드 안에 있던 플레이어의 퇴장만 다른 peer에게 `_rpc_player_left`로 알리고 서버의 `player_left` 시그널을 낸다. 모듈 `on_player_left`와 저장은 모든 퇴장에서 그대로 한다 |

모든 플레이어가 접속 순간 캐릭터를 갖는 호환 기본값에서는 동작이 달라지지 않는다. `NetModule.on_player_joined`의 뜻은 "peer가 핸드셰이크를 마쳤다"에서 "플레이어가 월드에 들어왔다"로 바뀌었다.

캐릭터 없는 접속자도 접속 스냅샷과 그 뒤의 방송(다른 플레이어의 위치, 좀비, 월드 아이템, 공개 이벤트)은 받는다. 만드는 즉시 월드가 보이게 하기 위해서이고, 받는 정보는 월드 안의 플레이어가 받는 공개 정보와 같다(docs/15 P2-169).

#### 네트워크 메시지(`CharacterNetModule`, 노드 이름 `CharacterNet`)

| 방향 | RPC | 채널/모드 | 받는 쪽 검증 |
|---|---|---|---|
| C→S | `_rpc_request_create_character(request_id: int, name: String, appearance: Dictionary)` | 0 reliable | 아래 "요청 검증" |
| S→요청자 | `_rpc_create_result(request_id: int, ok: bool, reason: String)` | 0 reliable | 서버 발신만 수용, 타입, `request_id` ≥ 0, `reason` 길이 ≤ 64, `ok`일 때만 `reason`이 빈 문자열 |
| S→접속자 | `_rpc_character_rows(rows: Array)` | 0 reliable | 서버 발신만 수용. 행 256개 초과면 통째로 버리고, 행은 하나씩 검증해 잘못된 행만 버린다 |
| S→본인 | `_rpc_creation_state(can_create: bool, reason: String)` | 0 reliable | 서버 발신만 수용, 타입, `reason` 길이, `can_create`일 때만 `reason`이 빈 문자열 |

요청에는 대상 플레이어 인자가 없다. 행위자는 보낸 peer의 플레이어다. 인자를 더 붙인 호출은 엔진이 거부한다(테스트로 고정).

```text
접속 조각(snapshot.modules.CharacterNet) = {
  schema_version: 1,
  characters: [row, ...],          # 월드 안의 모든 플레이어(본인이 월드 안이면 본인 포함)
  self: {can_create: bool, reason: String}   # 본인이 지금 캐릭터를 만들 수 있는지
}
row = {
  player_id: String,
  name: String,                    # 정리된 이름
  appearance: {slot_id: option_id},  # 모든 항목
  character_generation: int        # 본인에게는 실제 값, 다른 사람에게는 0(설정으로 공개 가능)
}
```

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 바뀌지 않고 `rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드 | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | `request_id`가 int가 아님, `name`이 String이 아님, `appearance`가 Dictionary가 아니거나 키·값이 String이 아님(색 값, 숫자, null, 배열 모두 거부) | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `payload_too_large` | 이름이 64자 초과, 외형 항목이 64개 초과, 항목·선택지 ID가 64자 초과. 규칙 코드에 닿기 전에 걸러낸다 | 보냄 |
| 5 | `rate_limited` | peer별 토큰 버킷. 형식이 틀린 요청은 토큰을 쓰지 않는다 | 보냄 |
| 6 | `character_alive`, `respawn_wait` | 지금 만들 수 없는 상태 | 보냄 |
| 7 | `name_empty`, `name_too_short`, `name_too_long`, `name_bad_characters`, `name_banned` | 이름 규칙 | 보냄 |
| 8 | `appearance_too_large`, `unknown_appearance_slot`, `unknown_appearance_option` | 외형 선택 | 보냄 |
| 9 | `name_taken` | 중복을 허용하지 않을 때 | 보냄 |

6~9는 정상 플레이에서도 생기므로 경고 로그 없이 횟수만 센다. 승인되면 서버는 복제를 먼저 하고 결과를 나중에 보낸다(같은 채널): 캐릭터 행 → 요청자의 생성 가능 상태 → 저장(`save_after_create`) → 결과 `(request_id, true, "")`. 첫 캐릭터면 행 앞에 `_rpc_player_joined`와 생존 공개 행(`SurvivalNet`)이 나간다. 죽은 뒤의 새 캐릭터면 생존 쪽 변화(`player_respawned`, 다시 살아남)는 `SurvivalNet`의 다음 틱에 나가므로 결과보다 한 틱 늦을 수 있다.

#### 복제와 정보 공개(ADR-009)

| 받는 쪽 | 받는 것 |
|---|---|
| 모든 접속자(캐릭터가 없는 접속자 포함) | 월드 안의 모든 플레이어의 캐릭터 행: 접속 조각, 플레이어가 월드에 들어올 때, 다음 캐릭터가 시작될 때(요청으로 만들었든 호환 기본값에서 저절로 시작했든. 모듈이 서버 틱마다 세대 번호를 비교한다) |
| 본인 | 자기 행의 실제 `character_generation`, 자기가 지금 만들 수 있는지와 그 사유(`_rpc_creation_state`: 접속 조각, 그리고 바뀔 때마다. 대기 시간의 끝은 시간으로 오므로 서버 틱마다 확인한다), 자기 요청의 결과 |
| 아무도 받지 않는 것 | 캐릭터가 없는 접속자의 존재(접속·퇴장 알림, 위치, 생존 행, 캐릭터 행 어디에도 없다) |

판단:

- **이름과 외형은 공개한다.** 캐릭터를 보면 보이는 것이므로 ADR-009의 "관찰 가능한 사실"이다. 거리·시야 제한은 없다(다른 공개 정보와 같다, P2-115).
- **세대 번호는 기본값에서 본인에게만 알린다**(`share_character_generation` false, 다른 사람의 행에는 0). "이 플레이어가 지금까지 몇 번 죽었는가"는 캐릭터를 봐서 알 수 있는 사실이 아니고, P2-T4의 결정(docs/15 P2-130)과 같다. 다른 플레이어는 같은 `player_id`의 이름·외형이 바뀌고 `player_respawned`가 오는 것으로 새 캐릭터임을 안다. 설정을 켜면 모든 접속자가 받는다. **[사용자 확인 필요]**(docs/15 P2-168. 작업 지시에는 "이름·외형·세대를 모든 접속자에게"와 "세대 공개 여부를 정하라"가 함께 있었다)
- 죽은 캐릭터의 이름은 새 캐릭터가 만들어질 때까지 그대로 보인다.

`ClientCharacterState`(권한 없는 미러): `has_character(id)`, `character_name(id)`, `appearance(id)`(사본), `character_generation(id)`(0 = 모름·비공개), `player_ids()`, `can_create_character()`, `creation_block_reason()`(접속 전에는 `not_joined`). 시그널 `changed`, `character_changed(player_id)`, `character_removed(player_id)`, `creation_state_changed(can_create, reason)`. 행 검증: 키 네 개가 정확히 있고, `player_id` 길이, 이름(1~64자, 앞뒤 공백·연속 공백·제어 문자 없음), 외형이 **이 클라이언트의 외형 데이터**로 완전한 선택인지, 세대 ≥ 0. 이름의 허용 문자 범위는 클라이언트가 다시 검사하지 않는다(서버 설정이 기준). 서버와 클라이언트의 외형 데이터가 다르면 그 행은 버려진다(docs/15 P2-176).

#### `SurvivalNet`의 변경(§14.14)

캐릭터 없는 접속자의 접속 조각은 `{schema_version: 3, players: [...]}`로 `self`가 없다(예전에는 생존 상태가 없으면 빈 조각이었다). `ClientSurvivalState.apply_join`은 이 형식을 받아 다른 플레이어의 공개 행만 채우며, 그 목록에 본인이 있으면 거부한다. 본인의 공개 행과 본인 스냅샷은 캐릭터가 생긴 뒤에 온다(`on_player_joined`의 공개 행 방송, 주기적인 본인 스냅샷 비교). 스키마 버전은 3 그대로다(`self`가 있는 형식은 바뀌지 않았다).

#### 저장

- players/<id>.json 스키마 v4가 `character`를 추가한다: `null` 또는 `{name: String, appearance: {slot_id: option_id}}`. 현재 스키마 문서에 이 키가 없거나 형식이 틀리면(이름이 비었거나 64자 초과, 외형이 문자열 → 문자열 맵이 아님, 64개 초과) 그 플레이어 문서는 거부된다. 세대가 2 이상인데 `character`가 null이어도 거부된다.
- v3 → v4 마이그레이션(`SaveMigrations.player_v3_to_v4`): P2-T9 이전에 저장된 플레이어는 모두 월드에 캐릭터가 있었으므로 `{name: "생존자", appearance: {}}`를 넣는다. 빈 외형은 월드를 읽을 때 `CharacterRules.restore_profile`이 항목별 기본값으로 채운다. 그래서 이전 저장의 플레이어는 생성 화면 없이 바로 월드에 들어온다.
- 저장된 이름은 이름 규칙이 나중에 바뀌어도 그대로 읽는다(저장을 못 읽게 만들지 않는다). 저장된 외형은 위 `restore_selection` 규칙으로 고친다.
- 캐릭터 생성은 결과를 보내기 전에 저장한다(`save_after_create`). P2-T4의 "새 캐릭터 시작은 다음 저장에 들어간다"는 요청으로 만든 캐릭터에는 해당하지 않는다(호환 기본값의 자동 시작은 그대로다).
- 캐릭터를 만들지 않고 나간 플레이어는 `character: null`로 저장되고, 다시 접속하면 생성부터 한다. 죽은 캐릭터로 저장된 플레이어는 재시작 뒤 남은 대기 시간이 지나야 만들 수 있다(§14.16의 행동 시각 기한).

#### 클라이언트(`scripts/presentation/`, `scenes/ui/character_creation_screen.tscn`)

- **생성 화면**(`CharacterCreationScreen`, Control): 이름 입력, 항목마다 한 줄(항목 이름, 이전 ◀, 색 견본(색 항목만), 선택지 이름, 다음 ▶), 무작위 버튼, 만들기 버튼, 거부 사유 줄. 줄은 `CharacterNetModule.character_rules()`의 카탈로그에서 만들고 항목·선택지 문구는 데이터의 `display_name`이다. 확인하면 서버와 같은 `CharacterRules`로 먼저 검사해 틀린 이름은 보내지 않고 사유를 표시하며, 통과하면 `create_requested(이름, 외형 선택)` 시그널만 낸다. 화면은 아무것도 결정하지 않는다.
- **언제 뜨나**: `ClientView`가 미러의 `can_create_character()`를 보고 연다(`CharacterCreationScreen.should_open`). 처음 접속했을 때와, 죽은 뒤 서버가 만들 수 있다고 알렸을 때다. 서버가 요청을 승인하면 함께 온 생성 가능 상태(false)로 닫힌다. `--character-name=`으로 시작한 세션에서는 뜨지 않는다. 다시 열릴 때 지난번의 이름과 선택이 남아 있다.
- **입력**: 화면이 떠 있는 동안 마우스 캡처를 풀고(`MOUSE_MODE_VISIBLE`), 이동·공격·사용·휴식·줍기 입력을 보내지 않는다(`ClientView.is_game_input_enabled()`).
- **월드 표시**: 플레이어마다 노드 `Player_<id>`(위치·방향) 아래에 `Body`(캡슐)와 `NameTag`(Label3D, 빌보드)를 둔다. `CharacterCapsuleLook.build`(순수 함수)가 외형 선택을 캡슐로 바꾼다: `capsule_color` 항목(상의 색) → 캡슐 색, `capsule_height` 항목(키) → 높이 배율, `capsule_radius` 항목(체형) → 반지름 배율, 높이는 반지름의 2배 이상으로 보정. **피부색·머리 모양·머리색·하의 색은 저장·복제까지만 되고 지금은 보이지 않는다**(캐릭터 모델이 들어오면 연결). 이름은 캡슐 위에 표시하고 본인·다른 플레이어·죽은 캐릭터의 색이 다르다. 죽은 캡슐은 기존대로 어두운 색으로 눕고 이름은 남는다. 누워 쉬는 캡슐은 자기 색 그대로 눕는다. 캐릭터 행이 아직 없는 플레이어는 예전의 기본 캡슐(본인/타인 색)로 이름 없이 표시한다.
- 생존 HUD 첫 줄이 "이름 | 캐릭터 #N"이 됐다(이름을 모르면 예전대로 "캐릭터 #N").

#### 테스트

`tests/unit/character_rules_test.gd`(이름 정리·검증: 길이 경계, 글자 수 단위, 허용·금지 문자, 한글, 앞뒤·연속 공백, 이름 안의 제어 문자, 빈 이름, 거대한 이름, 허용 범위 설정, 금칙어 seam / 외형 정의 검증: 중복 ID, 기본값이 선택지에 없음, 종류·역할, 카탈로그의 중복·순서 / 선택 검증: 없는 항목·선택지, 빠진 항목, 타입 오류, 과도한 크기, 무작위 선택, 저장 복구 / 프로필 문서 / 기본 데이터와 설정 파일), `tests/unit/character_creation_test.gd`(서버 상태 모델: 호환 기본값과 생성 필수의 접속, 캐릭터 없는 플레이어의 이동·줍기·내려놓기·공격·소비·휴식 거부, 욕구, 월드 시계, 좀비, 발소리, 첫 캐릭터, 살아 있는 캐릭터의 거부, 거부된 요청 14종의 상태 불변, 사망 → 대기 전 거부 → 대기 뒤에도 자동 시작 없음 → 생성과 세대 증가, 사망 중 퇴장·재접속, 호환 기본값의 자동 시작과 프로필 유지, 이름 중복 설정, 캐릭터 없는 퇴장·재접속, 저장 → 재시작(`WorldPersistence`), 죽은 채 저장, 플레이어 파일 v4와 마이그레이션, 데이터가 바뀐 저장의 복구, 훅 기본값과 조립 없는 월드), `tests/integration/character_net_test.gd`(서버 1 + 클라이언트 2~3, 실제 ENet: 만들기 전에는 서로 보이지 않음 → 생성 뒤 서버·본인·상대가 같은 이름·외형, 늦게 접속한 클라이언트와 캐릭터 없는 퇴장·재접속, 사망 → 대기 → 다른 이름·외형으로 생성 → 모두에게 반영, 조작된 요청 20종과 인자를 더 붙인 호출·살아 있는 캐릭터·클라이언트가 보낸 서버 메시지, join 전 요청, 빈도 초과, 캐릭터 없는 플레이어의 이동·줍기·공격·휴식·내려놓기·소비, 저장 → 서버 재시작 → 재접속, 호환 기본값, 세대 공개 설정, 이름 중복 거부, 화면 없는 자동 생성과 거부 시 중단, RPC 구성, 미러의 페이로드 검증), `tests/unit/character_presentation_test.gd`(외형 → 캡슐, 생성 화면의 선택 모델, 거부 사유 문구, 화면이 뜨는 조건, HUD 이름 줄, 이름표 설정, `--character-name=` 인자), `tests/integration/character_creation_screen_test.gd`(headless: 생성 화면 씬 인스턴스화, 데이터에서 만든 항목 줄, 데이터에 추가한 항목의 줄, 이전·다음·무작위, 확인 시 페이로드, 틀린 이름은 나가지 않음, 서버 사유 표시 / 실제 클라이언트 세션(`GameBootstrap` + `ClientView`)과 실제 서버: 접속 뒤 화면이 뜨고 입력이 꺼짐 → 화면의 위젯으로 생성 → 캡슐 색·크기와 이름표 → 사망 뒤 화면이 다시 뜸 → 두 번째 캐릭터, `--character-name=` 세션), `tools/smoke_test.sh`(서버 1 + 클라이언트 2 프로세스: 두 플레이어가 캐릭터 없이 접속하고 `--character-name=`으로 만든다. 한 이름은 한글).

### 14.25 수면 조정(P2-T10, docs/00 ADR-016)

사용자 결정(2026-11-15): "수면시간 좀 줄이자 피로도 높으면 작업도 능력치가 떨어지고", "자는 중 사망은 빼고 위험지수일 때 깨도록, 공격받으면 데미지 입지만, 즉사는 아니에". 이 절이 §14.23(수면)과 §14.6(생존 계약)의 해당 부분보다 우선한다. 임시 가정은 docs/15 §14.1 P2-180~P2-186.

구성: `SurvivalSettings`(값 7개), `SurvivalService`(조작 배율, 위험 기상, 눕기 거부, 자는 중 피격 하한), `BuildInfo.PROTOCOL_VERSION` 8, 클라이언트 HUD 문구. **새 RPC도 메시지 형식 변경도 없다.** 바뀐 것은 본인 이벤트 `player_rest_ended`의 `cause`가 가질 수 있는 값과 휴식 결과의 사유 코드뿐인데, 프로토콜 7 클라이언트는 모르는 `cause`의 이벤트를 버리므로 버전을 올렸다(P2-T10~T12 묶음에서 한 번). `network_service.gd`, `survival_net_module.gd`, `client_survival_state.gd`의 코드는 바뀌지 않았다(원인 목록은 `SurvivalService.REST_END_CAUSES`를 함께 쓴다).

#### 데이터(`SurvivalSettings`, `data/tuning/survival_settings.tres`)

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `rest_fatigue_hours_from_max` | 3.2(전에는 8.0) | 쉬어서 피로가 최대에서 0이 되는 **월드 시간(달력 시간)**. 24배속에서 실제 8분 |
| `fatigue_caution_handling_multiplier` | 0.85 | 피로 범주가 주의일 때 조작 배율에 곱하는 값 |
| `fatigue_danger_handling_multiplier` | 0.6 | 피로 범주가 위험일 때. 주의 값보다 클 수 없다 |
| `rest_wake_on_need_danger` | true | 허기 또는 갈증이 위험 범주가 되면 깬다 |
| `rest_wake_health_fraction` | 0.3 | 체력이 최대 체력 × 이 값 **이하**가 되면 깬다. (0, 1) 안의 값만 허용한다: 0은 "누운 채 죽을 수 있음"이라 사용자 결정과 어긋나 설정 검증에서 막는다 |
| `rest_wake_infection_stage` | 5(말기) | 감염이 이 단계에 도달하면 깬다. 0 = 감염으로는 깨지 않는다(그러면 자다가 좀비화할 수 있다) |
| `rest_hit_min_health` | 1.0 | 자는 중에 맞은 한 대가 남기는 최소 체력(체력 단위). (0, 최대 체력] |

#### 작업 능력(조작 배율)

`SurvivalService.handling_multiplier(player_id)` = `clamp(팔·손 상처 배율 × 피로 배율, min_handling_multiplier, 1)`. 죽은 플레이어는 0, 모르는 플레이어는 1이다.

- 피로 배율은 **피로 욕구의 범주만** 본다: 양호 1.0, 주의 0.85, 위험 0.6. 허기·갈증은 조작 배율에 영향을 주지 않는다(이동 속도·스태미나 회복 페널티는 기존대로 세 욕구 중 가장 나쁜 범주를 쓴다).
- 상처 배율(§14.6: `1 − handling_penalty_per_severity × 팔·손 상처 severity 합`)과 **곱**이고, 하한은 기존 `min_handling_multiplier`(0.25) 하나를 함께 쓴다. 이동 배율(상처 × 욕구, 하한 하나)과 같은 방식이다.
- 근접 전투(§14.10)는 이미 이 값을 피해에 곱하므로 전투 코드는 바뀌지 않았다. 피로 위험이면 맨손·파이프 피해가 60%가 된다.
- **이후 제작·건축·수리 등 "작업"을 추가할 때는 속도나 품질에 `handling_multiplier`를 그대로 곱한다.** 작업 종류별 배율이 따로 필요하면 이 값에 곱하는 형태로 추가한다(피로를 다시 읽지 않는다).
- 범주가 바뀌면 기존 `need_category_changed` 이벤트가 본인에게 가고, 클라이언트 HUD가 그 범주로 문구를 만든다. 배율 수치는 복제하지 않는다.

#### 위험할 때 깸

자는 플레이어는 아래 "위험" 중 하나가 생기는 **그 순간** 깬다. `SurvivalService.rest_danger(player_id) -> String`이 지금의 위험을 돌려준다(없으면 `""`, 모르는·죽은 플레이어도 `""`). 여러 개가 겹치면 표의 순서대로 첫 번째다.

| 위험(= `player_rest_ended`의 `cause`) | 조건 |
|---|---|
| `low_health` | 체력 ≤ `max_health × rest_wake_health_fraction`(기본 30) |
| `thirst` | 갈증이 위험 범주(≥ `need_danger_threshold`, 기본 75). `rest_wake_on_need_danger`가 켜져 있을 때 |
| `hunger` | 허기가 위험 범주. 같은 설정 |
| `infection` | 감염 단계 ≥ `rest_wake_infection_stage`(기본 말기). 0이면 해당 없음 |

- 피로는 위험이 아니다: 아무리 피곤해도 잘 수 있다.
- 시간 피해(출혈·굶주림·탈수·감염 체력 감소)는 여전히 자는 동안 적용되고 그 자체로는 깨우지 않는다. 그 피해로 체력이 기준에 닿는 순간 `low_health`로 깬다. 그래서 **자는 상태에서 시간 피해만으로 체력이 0이 되는 경로가 없다**: 깬 뒤에도 피해가 계속되면 깨어 있는 상태에서 죽는다(이벤트 순서 `player_rest_ended(low_health)` → … → `player_died`).
- 굶주림·탈수 피해는 욕구가 최대(100)일 때만 생기고 위험 범주(75)에서 먼저 깨므로, 기본 설정에서는 자는 동안 그 피해가 시작되지도 않는다.
- 구간 적분(§14.6, §14.16, §14.23): 기상 시점이 구간 경계다. `_advance_player`가 쉬는 구간마다 `_rest_wake_offset`으로 "이 구간 안에서 위험이 시작되는 시점"을 구해, 거기까지만 쉬는 변화율로 적분하고 깨운 뒤 나머지를 깨어 있는 변화율로 적분한다. 욕구는 선형이라 해석적으로, 체력은 사망 시점과 같은 이분법(자연 회복 구간이 지난 뒤 자는 플레이어의 체력은 오르지 않는다)으로 구한다. 감염 단계는 기존의 단계 경계에서 판정한다. 큰 틱 하나와 60Hz 틱의 기상 시각·이후 상태가 같다(배율 24, 1틱·3600틱·7틱 비교 테스트, 허용 오차 0.05).
- 적분은 경계에 반올림 오차만큼 못 미쳐 끝날 수 있어서, 깨울 때 그 값을 경계에 맞춘다(갈증·허기는 위험 임계 이상으로, 체력은 기준 이하로). 그래야 깬 직후의 눕기 요청이 "승인됐다가 다음 틱에 다시 깸"이 아니라 거부된다. 욕구 범주가 그 보정으로 바뀌면 `need_category_changed`를 낸다.
- 이벤트: 본인 `player_rest_ended`의 `cause`가 위 넷 중 하나다. 다른 플레이어에게는 기존 공개 이벤트(`cause` 없음)만 간다: "일어났다"는 사실만 안다. `world_time`은 틱 안의 정확한 기상 시각이다.

**감염 말기와 좀비화**: 좀비화(말기 끝의 사망)는 체력과 무관해서 위 체력 기준으로는 막을 수 없다(기본 수치에서 체력 100으로 감염된 채 계속 자면 말기 끝의 체력이 약 31이라 체력 기준에 닿지 않는다). 그래서 **말기에 들어서는 순간 깨우고, 말기에는 누울 수 없게** 했다(기본값). 이러면 기본 설정에서 누운 채 죽는 경로가 하나도 없다. 좀비화 자체는 자는지와 무관하게 그대로 일어난다(깨어 있는 상태에서 죽는다). `rest_wake_infection_stage`를 0으로 두면 자다가 좀비화할 수 있고 그때는 기존대로 `player_rest_ended(died)` → `player_died`다. 제품 결정이라 docs/15 P2-184에 [사용자 확인 필요]로 적었다.

#### 눕기 거부

`start_rest`는 기존 검사(`unknown_player`, `player_dead`, `not_online`, `already_resting`) 다음에 `rest_danger`를 보고, 위험이 있으면 `cannot_rest_<위험>`(`cannot_rest_low_health`, `cannot_rest_thirst`, `cannot_rest_hunger`, `cannot_rest_infection`)으로 거부한다. 깨는 조건과 눕기 거부 조건이 **같은 함수**라서 "누웠다가 다음 틱에 깨는" 진동이 없다(깬 직후 10틱 동안 매번 거부되는 테스트, 실제 ENet에서 3회 연속 거부 테스트). 위험을 없애면(물을 마심, 체력 회복) 다시 누울 수 있다. 위험 직전(예: 갈증 74)에서는 누울 수 있고 곧 깬다: 진동이 아니라 짧은 잠이다.

#### 자는 중 피격

`apply_damage`가 자는 플레이어에게 적용될 때: 체력 = `max(체력 − 피해, min(rest_hit_min_health, 맞기 전 체력))`. 즉 피해는 그대로 들어가되 그 한 대로 체력이 하한(기본 1) 아래로 내려가지 않고, 이미 하한보다 낮았다면 올려 주지도 않는다. 그리고 깬다(`player_rest_ended`, `cause: "damaged"`).

- 이벤트 계약은 그대로다: `player_wounded`의 `damage`는 들어온 피해량, `health_after`는 실제 남은 체력, `died`는 false. 상처는 평소대로 기록되고 감염 노출 판정도 평소대로다.
- 깬 뒤의 공격은 같은 틱의 것이라도 평소 규칙이다(두 번째 호출은 깨어 있는 플레이어에게 적용된다). 좀비 한 마리의 연속 공격(쿨다운 1.5초)에서 첫 대는 살고 둘째 대에 죽는 것을 단위 테스트로 고정했다.
- 기본 수치에서는 이 하한이 실제로 걸리지 않는다: 자는 플레이어의 체력은 30을 넘고(그 이하면 깨어 있다) 좀비의 한 대는 최대 15다. 큰 피해원이 생겼을 때를 위한 규칙이다.
- 하한까지 내려간 뒤에는 출혈이 있으면 곧 죽을 수 있다(체력 1, 물림 출혈이면 24배속에서 수 초~수십 초). "그 한 대로 즉사하지 않는다"까지가 이 규칙이다(docs/15 P2-185).

#### 복제·정보 공개·저장

- 복제 경로는 §14.14·§14.23 그대로다. 본인: `player_rest_ended`(새 원인 포함), `need_category_changed`, 휴식 결과의 `cannot_rest_<위험>`. 다른 플레이어: 공개 `player_rest_ended`(`cause` 없음)와 공개 `player_wounded`(`died: false`)뿐이다. 무엇이 위험했는지(체력·욕구·감염)는 다른 플레이어에게 가지 않는다(ADR-009). 다만 "스스로 일어났다"는 것과 직전의 공개 피격 유무로 "공격이 아닌 다른 이유로 깼다" 정도는 짐작할 수 있다.
- 저장: 변화 없음. 쉬는 상태는 여전히 저장하지 않고 생존 fragment 스키마(v4)도 그대로다. 새 설정값은 설정 Resource에만 있다.

클라이언트 표시(`scripts/presentation/`): `ClientPresentationFormatter.build_rest_lines`가 휴식 줄 아래에 피로 문구(`fatigue_work_text`: "피로로 작업 능력 저하 (주의)" / "피로로 작업 능력 크게 저하 (위험)")를 붙인다. `format_rest_result`가 `cannot_rest_<위험>`을 문장으로 바꾸고, `format_rest_ended`/`format_survival_notice`가 본인 기상 이벤트를 "…잠에서 깼습니다" 문구로 바꾼다(`ClientView`가 생존 미러의 `event_received`에 연결해 사용 결과 자리에 표시). 화면 설명은 docs/11 §2.9.

테스트: `tests/unit/sleep_tuning_test.gd`(기본값이 실제 8분인지와 설정 검증 11종, 피로 범주별 조작 배율·허기와 갈증은 무관·상처와의 곱·하한·사망, 피로에 따른 근접 피해, 갈증·허기 위험 기상과 틱 안의 기상 시각, 설정을 끈 경우, 출혈 중인 플레이어가 기준 체력에서 깨고 누운 채 죽지 않음(큰 틱 하나), 틱 크기 무관, 말기 기상과 기상 단계를 끈 경우의 좀비화, 위험별 눕기 거부와 우선순위, 깬 직후 재눕기 거부(진동 없음), 자는 중 치명적 피격의 생존·이벤트·다음 피격의 사망, 가벼운 피격과 하한보다 낮은 체력, 좀비 연속 공격), `tests/integration/sleep_tuning_net_test.gd`(서버 1 + 클라이언트 2, 실제 ENet: A가 자다가 갈증 위험으로 깨면 A는 원인을 받고 B는 공개 이벤트 둘만 받음(키 목록 고정, 사적 단어 없음), 깬 뒤 3회 연속 눕기 거부와 거부 횟수, B는 누울 수 있음 / 치명적 피해의 좀비가 자는 A를 공격하면 A가 체력 1로 살아서 깨고 양쪽 미러가 일치, 이후 피격으로 사망), `tests/unit/client_presentation_test.gd`(피로 문구, 거부 문장, 기상 문구, 본인 이벤트만 알림). 뜻이 바뀌어 고친 기존 테스트: `tests/unit/rest_test.gd`의 "누운 채 시간 피해로 죽을 수 있다"(→ 죽기 전에 깬다)와 "사망이 휴식을 끝낸다"(치명적 피격 대신 기상 단계를 끈 좀비화로), `tests/integration/rest_net_test.gd`의 휴식 중 사망(첫 피격은 깨우고 둘째가 죽인다).

### 14.26 자세와 은신(P2-T11, docs/00 ADR-017)

사용자 결정(2026-11-15): "엎드리면 은신효과는 있지만, 자는건 없게, 그래도 움직이는것보다는 적게". 플레이어가 엎드릴 수 있고, 좀비의 시각 감지가 플레이어의 자세와 움직임에 따라 달라진다. 순서는 **엎드림 < 누워 잠 < 움직임**(오른쪽일수록 잘 보인다)이고, 자는 것에는 엎드리기 같은 은신 효과가 없다. 임시 가정은 docs/15 §14.2 P2-189~P2-194.

구성: 새 도메인 `scripts/domain/posture/`(`PlayerPosture`, `PostureSettings`, `PostureService` = ServerSystem `posture`), `ServerSystem`·`ServerWorld`의 훅 넷(§14.5), `ZombieService`(시야 거리에 가시성 곱), `ZombieSettings.tracked_target_min_visibility`, `PlayerNoiseService`(발소리 배율), `CombatService`(공격 차단 사유), `SurvivalService.rest_changed` 시그널, 새 NetModule `PostureNet`(`PostureNetModule`, `PostureNetSettings`, `ClientPostureState`), 클라이언트 엎드리기 키·HUD·엎드린 캡슐. `network_service.gd`는 수정하지 않았다. `PROTOCOL_VERSION`은 P2-T10에서 올린 8 그대로다(묶음에서 한 번).

#### 결합 방식

좀비·발소리·전투는 자세를 모른다. 각자 `ServerWorld`에 "이 플레이어의 가시성 / 발소리 배율 / 공격 차단 사유"를 묻고, `ServerWorld`가 모든 시스템의 훅 값을 모은다. 자세 시스템은 그 훅에 답할 뿐이다. 자세 시스템이 아는 다른 시스템은 생존 하나이고(`is_resting`, `start_rest`, `stop_rest`, `is_alive`: 공개 API만), 생존은 자세 시스템을 모른다: 휴식의 시작·끝과 사망을 시그널로 알릴 뿐이고 연결은 `ServerComposition`이 한다(§14.20과 같은 방식). 등록 순서는 `survival` → `posture` → `noise` → `player_noise` → `zombie` → `combat`이라 발소리와 좀비가 같은 틱의 자세·이동을 본다.

#### 자세 모델

`PlayerPosture.Kind`: `STANDING`(서 있음), `PRONE`(엎드림), `RESTING`(누워 잠). 네트워크·이벤트 이름은 `standing`, `prone`, `resting`. 한 플레이어는 항상 셋 중 하나다.

- "누워 잠"은 §14.23의 휴식 그 자체다(`SurvivalService`가 소유). 자세 시스템은 "엎드림"만 소유하고 셋을 하나의 자세로 보고한다: `posture_of` = 쉬는 중이면 `RESTING`, 아니고 엎드림 표시가 있으면 `PRONE`, 아니면 `STANDING`.
- 엎드린 채 누우면(어느 의도로든) 엎드림이 끝난다. 잠에서 깨면(일어나기, 피격, 위험 기상) 서 있는 자세다. 엎드린 자세로 되돌아가지 않는다.
- 죽으면 엎드림이 끝난다(죽은 캐릭터에게는 자세가 없다: `STANDING`으로 보고). 퇴장하면 조용히 끝나고 재접속하면 서 있다. 새 캐릭터는 서서 시작한다.
- 자세 전환에는 시간이 걸리지 않는다(요청이 승인되는 틱에 바뀐다, docs/15 P2-190).

#### 데이터(`PostureSettings`, `data/tuning/posture_settings.tres`)

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `standing_moving_visibility` | 1.0 | 서서 움직이는 플레이어의 가시성(기준) |
| `standing_still_visibility` | 0.9 | 서서 가만히 있는 플레이어 |
| `resting_visibility` | 0.8 | 누워 자는 플레이어 |
| `prone_moving_visibility` | 0.6 | 엎드려 기는 플레이어 |
| `prone_still_visibility` | 0.4 | 엎드려 가만히 있는 플레이어 |
| `moving_min_speed_mps` | 0.5 | 한 틱에 서버가 이만큼 이상의 속도로 움직였으면 "움직이는 중" |
| `moving_memory_sec` | 0.5 | 마지막으로 움직인 틱 뒤 이 시간(실제 초) 동안은 계속 "움직이는 중" |
| `prone_movement_multiplier` | 0.35 | 엎드린 플레이어의 이동 속도 배율(4m/s → 1.4m/s) |
| `prone_footstep_loudness_multiplier` | 0.4 | 엎드린 플레이어의 발소리 세기 배율 |
| `prone_footstep_stride_multiplier` | 0.5 | 엎드린 플레이어의 보폭 배율(2m → 1m마다 발소리) |
| `prone_blocks_attack` | true | 엎드린 채 근접 공격 불가 |
| `max_pending_events` | 256 | 네트워크 계층이 가져가기 전까지 보관하는 이벤트 수 |

검증(`validate()`): 가시성은 모두 0~1이고, 사용자가 정한 순서를 설정 오류로 막는다: 엎드려 정지 ≤ 엎드려 이동 < 누워 잠 < 서서 움직임, 서서 정지 ≤ 서서 움직임. 그래서 "자는 것이 엎드린 것보다 잘 숨는" 설정이나 "자는 것이 움직이는 것만큼 잘 보이는" 설정은 서버가 시작하지 않는다.

#### 서버 규칙(`PostureService`)

| API | 계약 |
|---|---|
| `posture_of(player_id) -> PlayerPosture.Kind` | 현재 자세. 모르는·오프라인·죽은 플레이어는 `STANDING` |
| `is_prone(player_id) -> bool` | 엎드려 있는지 |
| `is_moving(player_id) -> bool` | 서버가 최근에 움직였는지(아래 "움직이는 중") |
| `visibility_multiplier(player_id) -> float` | `PostureSettings.visibility(자세, 움직이는 중)`. 이 시스템이 아직 추적하지 않는 플레이어(월드에 없거나 접속 뒤 첫 틱 전)는 1.0 |
| `request_posture(world, player_id, wanted) -> ActionResult` | 원하는 자세로 바꾼다. 성공 이벤트는 아래 `player_posture_changed`. 실패 사유(순서대로): `posture_unavailable`(월드나 생존 시스템 없음), `bad_posture`(자세 값이 아님), `not_online`(오프라인, 캐릭터 없는 접속자, 모르는 플레이어), `unknown_player`(생존 상태 없음), `player_dead`, `already_in_posture`, 또는 `SurvivalService.start_rest`/`stop_rest`의 사유(`already_resting`, `cannot_rest_<위험>` 등). 실패하면 아무것도 바뀌지 않는다 |
| `drain_events() -> Array[Dictionary]` | 네트워크용 읽기 전용. 지난 호출 이후의 이벤트 |

`request_posture`의 전환: `resting` 요청은 `start_rest`(§14.23·§14.25의 규칙과 거부 사유 그대로), 누워 자는 중의 `standing` 요청은 `stop_rest`, 엎드린 중의 `standing` 요청은 엎드림 해제, `prone` 요청은 서 있으면 바로 엎드리고 자는 중이면 깨운 뒤 엎드린다(이벤트 둘: `standing`, `prone`).

이벤트(JSON-safe, 변화마다 하나): `{event_type: "player_posture_changed", player_id, posture: "standing"|"prone"|"resting", previous: 같은 이름들, world_time}`. 휴식의 시작·끝도(어느 경로로 일어났든 `rest_changed` 시그널을 받아) 이 이벤트로 기록된다. 퇴장과 새 캐릭터 시작은 이벤트가 없다.

**엎드림의 효과**(모두 훅을 통해서다):

- 이동: `player_movement_multiplier`가 0.35를 돌려준다. `ServerWorld`가 다른 시스템의 배율(상처·욕구)과 곱한다. 클라이언트가 보내는 것은 기존 이동 의도 그대로이고 속도는 서버가 정한다.
- 공격: `player_attack_block_reason`이 `player_prone`을 돌려준다(`prone_blocks_attack`). 근접 공격이 거부되고 스태미나·쿨다운·소음·이벤트가 없다(§14.10). **아이템은 다룰 수 있다**: 줍기·내려놓기·먹기·붕대·치료제는 엎드린 채로 된다(`player_action_block_reason`에는 답하지 않는다). 어떤 행동도 자세를 바꾸지 않는다.
- 발소리: 세기 ×0.4, 보폭 ×0.5(§14.11). 청각 규칙 자체는 그대로다.
- 피격·시간 피해는 자세와 무관하고 자세를 바꾸지 않는다.

**움직이는 중**: 자세 시스템이 매 틱(`step`: 같은 틱의 `step_movement` 뒤) 접속 중인 플레이어의 이전 서버 위치와 지금 서버 위치를 비교한다. XZ 이동 속도가 `moving_min_speed_mps` 이상이면 그 행동 시각을 기록하고, 그 뒤 `moving_memory_sec` 동안 "움직이는 중"이다(좀비는 0.5초마다 판단하고 플레이어는 매 틱 움직이므로, 잠깐 멈춘 것은 숨은 것이 아니다). 근거는 서버 위치뿐이다: 이동 의도가 왔어도 위치가 바뀌지 않았으면(자는 플레이어) 움직임이 아니고, 클라이언트가 자기 움직임에 대해 보내는 값은 없다. 리스폰처럼 위치가 건너뛰는 경우도 한 번의 움직임으로 센다(새 캐릭터 시작은 추적을 새로 시작해 예외).

#### 좀비 시야(§14.9에 추가)

좀비가 플레이어를 볼 수 있는 거리 = `sight_range_m × light_sight_multiplier × 가시성`. 기본 수치(시야 25m)에서: 서서 움직임 25m, 서서 정지 22.5m, 누워 잠 20m, 엎드려 이동 15m, 엎드려 정지 10m. 시야각(좌우 60도)은 그대로다. 가시성 0이면 바로 앞에서도 보이지 않는다(기본값에는 0이 없다).

**이미 추격 중인 좀비**: 추격·공격 중이고 직전 판단에서 보였던 그 대상에게는 가시성의 하한 `ZombieSettings.tracked_target_min_visibility`(기본 1.0)가 적용된다. 기본값에서는 **좀비가 보고 있는 앞에서 엎드려도 추격이 끊기지 않는다**. 전체 시야 거리나 시야각 밖으로 벗어나 한 번 놓치면(수색 상태) 그때부터는 일반 가시성이 적용되어, 엎드려 가만히 있으면 10m 밖에서는 다시 발견되지 않는다. 이 값을 0으로 두면 추격 중인 대상도 엎드리는 즉시 일반 가시성으로 판정된다(엎드려서 추격을 끊을 수 있다). 다른 좀비(그 플레이어를 보고 있지 않던 좀비)에게는 항상 일반 가시성이다. 제품 결정이라 docs/15 P2-192에 [사용자 확인 필요]로 적었다.

청각: 규칙을 바꾸지 않았다. 엎드린 플레이어의 발소리가 작을 뿐이다. 근접 공격 소음, 다른 소음원은 자세와 무관하다.

#### 네트워크 메시지(`PostureNetModule`, 노드 이름 `PostureNet`)

| 방향 | RPC | 채널/모드 | 받는 쪽 검증 |
|---|---|---|---|
| C→S | `_rpc_request_posture(request_id: int, posture: String)` | 0 reliable | 아래 "요청 검증" |
| S→요청자 | `_rpc_posture_result(request_id: int, ok: bool, reason: String)` | 0 reliable | 서버 발신만 수용, 타입, `request_id` ≥ 0, `reason` 길이 ≤ 64, `ok`일 때만 `reason`이 빈 문자열 |
| S→모든 접속자 | `_rpc_posture_rows(rows: Array)` | 0 reliable | 서버 발신만 수용, 배열, 행마다 `{player_id: String, posture: String}`의 키가 정확히 둘이고 자세 이름이 셋 중 하나. 틀린 행만 버린다. 최대 256행 |

의도 설계: 토글이 아니라 **원하는 자세**(`standing`, `prone`, `resting`)를 보낸다(§14.23의 휴식 의도와 같은 이유: 미러가 한 박자 늦어도 반대 동작이 되지 않고 거부될 뿐이다). 대상 플레이어 인자가 없다(행위자는 보낸 peer의 플레이어). 위치·속도·"숨었다" 같은 인자도 없다: 엎드렸는지, 얼마나 느린지, 얼마나 보이는지는 모두 서버가 정한다. 인자를 더 붙인 호출은 엔진이 거부한다(테스트로 고정).

**기존 휴식 RPC와의 관계**: `SurvivalNet`의 `_rpc_request_rest(request_id, lie_down)`(§14.23)는 그대로 둔다. 새 의도의 `resting`/`standing`(자는 중)은 같은 서버 규칙(`start_rest`/`stop_rest`)으로 가는 다른 입구이고, 어느 쪽으로 눕든 자세 모델은 일관된다(엎드림 해제, 자세 행 복제, 생존 미러의 `resting`). 기존 클라이언트 API(`SurvivalNetModule.request_rest`)와 그 테스트를 깨지 않으려고 하나로 합쳐 지우지 않았다. 기본 클라이언트는 휴식 키에 기존 휴식 의도를, 엎드리기 키에 새 의도를 쓴다. 휴식 RPC를 없애고 자세 의도로 통합할지는 docs/15 P2-193.

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 바뀌지 않고 `rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드 | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | `request_id`가 int가 아니거나 `posture`가 String이 아님 | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `bad_posture` | 자세 이름이 셋 중 하나가 아님(대소문자 구분, 16자 초과 포함) | 보냄 |
| 5 | `rate_limited` | peer별 토큰 버킷(`PostureNetSettings.posture_intent_rate_per_sec`/`posture_intent_burst`, 기본 4/s·버스트 4) | 보냄 |
| 6 | `posture_unavailable` | 월드에 자세 시스템이 없음(조립 오류) | 보냄 |
| 7 | `PostureService`의 사유(`not_online`, `player_dead`, `already_in_posture`, `already_resting`, `cannot_rest_<위험>` 등) | 규칙이 거부. 횟수만 센다 | 보냄 |

승인되면 서버는 그 자리에서 자세 행을 모든 접속자에게 보낸 뒤 결과를 보낸다(같은 채널이라 요청자는 자기 자세 변화를 결과보다 먼저 받는다). 요청 없이 일어난 변화(피격으로 깸, 사망, 휴식 RPC)는 다음 서버 틱에 보낸다.

접속 조각(`snapshot.modules.PostureNet`): `{schema_version: 1, players: [{player_id, posture}, ...]}`(월드에 있는 전 플레이어). 캐릭터 없는 접속자도 받는다(자신의 행은 없다). 행이 없는 플레이어는 서 있는 것으로 본다.

복제와 정보 공개(ADR-009): 자세는 옆에서 보면 보이는 사실이라 **모든 접속자에게** 보낸다(누워 있음과 같은 부류, §14.23). 행에는 플레이어와 자세뿐이다. 보내지 않는 것: 왜 바뀌었는지, 이전 자세, 가시성 수치, 움직이는 중인지, 어느 좀비가 그 플레이어를 보는지. 거리·시야 제한은 없다(다른 공개 사실과 같다).

`ClientPostureState`: `posture_of(player_id) -> PlayerPosture.Kind`(본인과 다른 플레이어 모두, 모르면 `STANDING`), `is_prone`, 시그널 `posture_changed(player_id, posture)`·`changed`. 접속 조각이 틀리면 통째로 버리고(전원 서 있음), 퇴장한 플레이어의 행은 지운다.

클라이언트 표면(`PostureNetModule`): `request_posture(posture: PlayerPosture.Kind) -> int`(요청 번호, join 전이면 `NO_REQUEST`), `signal posture_result(request_id, ok, reason)`, `send_raw_posture_request(request_id, posture)`(테스트 전용).

#### 저장

자세는 **저장하지 않는다**(쉬는 상태와 같은 세션 상태, §14.23). `to_world_document()`·`to_player_fragment()` 모두 빈 문서이고 저장 스키마는 바뀌지 않았다. 퇴장하면 해제되고 재시작 뒤에는 접속자가 없어 엎드린 사람이 있을 수 없다. 자세 변경만으로는 저장이 일어나지 않는다.

클라이언트 표시(`scripts/presentation/`): 엎드리기 키(`ClientPresentationSettings.prone_key`, 기본 C)를 누르면 본인이 엎드려 있으면 `standing`, 아니면 `prone`을 요청한다(자는 중이면 서버가 깨운 뒤 엎드린다). 요청 간격은 휴식 키의 값을 함께 쓴다. 생존 HUD 끝에 자세 줄: "자세: 서 있음 | 엎드리기 [C]", "자세: 엎드림 (은신 중) | 일어서기 [C]", "자세: 누워 잠 | 엎드리기 [C]". 엎드린 캡슐은 앞으로 기울여(`prone_tilt_rad`, 기본 1.25rad) 바닥에 붙인다: 뒤로 완전히 누운 자는 캡슐(`rest_tilt_rad` = π/2)이나 어두운 색의 죽은 캡슐과 구분된다. 엎드린 채 공격하면 "엎드린 채로는 공격할 수 없습니다"를 표시한다. 화면 설명은 docs/11 §2.10.

테스트: `tests/unit/posture_test.gd`(기본값과 설정 검증 10종·자세 이름·가시성 표, 조립 순서와 저장 없음, 엎드리기·일어서기의 이벤트와 거부 사유, 캐릭터 없는 접속자, 엎드림과 수면이 하나의 자세 모델(양쪽 경로, 깨면 서 있음, 자는 중 → 엎드림, 위험 시 거부), 사망·퇴장·새 캐릭터, 엎드려 이동 속도와 상처 배율과의 곱, 엎드린 채 공격 거부와 줍기·먹기·내려놓기 허용, 발소리 수·세기·들리는 거리, 움직이는 중 판정과 기억 시간·이동 의도만으로는 움직임이 아님, 같은 거리에서 서 있으면 보이고 엎드리면 안 보임, 자세별 시야 거리 경계(±0.5m)와 "자는 플레이어는 움직이는 플레이어보다 덜 보이고 엎드린 플레이어보다 잘 보임", 추격 중 엎드려도 추격 유지(하한 1.0)와 하한 0에서 놓침, 놓친 뒤 엎드리면 재발견되지 않고 일어서면 발견됨, 월드 훅의 곱·제한·잘못된 값 무시·공격 차단 순서), `tests/integration/posture_net_test.gd`(서버 1 + 클라이언트 2~3, 실제 ENet: A가 엎드리면 서버·A·B·늦게 온 C의 미러 일치, 같은 이동 의도에서 A의 이동 거리가 B의 약 0.35배, 일어서기, B가 받은 변화 2개와 생존 이벤트 0개, 엎드린 채 퇴장·재접속 / 같은 거리의 서 있는 B는 좀비가 보고 엎드린 A는 못 봄, 양쪽 좀비 미러의 추격 / 휴식 RPC와 자세 의도를 섞어 쓴 흐름, 엎드린 채 공격 거부, 사망 / 조작된 요청 11종과 인자를 더 붙인 호출·잘못된 상태·남의 자세를 바꾸려는 요청·클라이언트가 보낸 서버 메시지 / join 전 요청과 캐릭터 없는 접속자 / 빈도 초과 / 설정·RPC 구성·요청 검증 규칙 / 미러의 페이로드 검증), `tests/unit/client_presentation_test.gd`(엎드리기 키 등록·검증, 자세 HUD 줄, 결과 문구, 엎드린 캡슐의 기울기와 높이). 고친 기존 테스트: `tests/unit/server_system_seam_test.gd`의 시스템 등록 순서 목록에 `posture` 추가.

### 14.27 다른 플레이어 치료(P2-T12, docs/00 ADR-018)

사용자 결정(2026-11-15): "남 치료도 가능하게". 붕대와 치료제를 가까이 있는 다른 플레이어에게 쓸 수 있다. 클라이언트는 아이템과 대상 플레이어만 지정하고, 거리·대상 상태·효과는 서버가 판정한다. 이 절이 §14.21·§14.22의 "대상은 항상 아이템을 쓰는 플레이어 자신이다"보다 우선한다(자기 사용 경로는 그대로다). 임시 가정은 docs/15 §14.3 P2-195~P2-199.

구성: `ItemConsumption.try_use_on`(서버 규칙, `try_consume`과 효과 적용부를 함께 쓴다), `ItemDefinition.is_treatment()`, `GameplaySettings.treat_range_m`·`allow_feeding_others`, `InventoryNetModule`(새 의도 RPC와 결과, 치료 알림), 클라이언트 `TreatTargetPolicy`(대상 후보 선택)·남에게 쓰기 키 조합·HUD. `network_service.gd`, `survival_service.gd`, `survival_net_module.gd`는 수정하지 않았다. `PROTOCOL_VERSION`은 P2-T10에서 올린 8 그대로다(묶음에서 한 번).

#### 데이터

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `GameplaySettings.treat_range_m` | 2.5 | 치료하는 플레이어와 대상 사이의 최대 거리(m). 서버가 가진 두 위치 사이의 거리이고 줍기 사거리와 같은 방식(3차원 거리, 경계 포함)이다 |
| `GameplaySettings.allow_feeding_others` | true (P2-T13, ADR-019. P2-T12에서는 false) | 켜면 음식·물도 남에게 줄 수 있다(대상의 허기·갈증이 준다). 끄면 치료 효과(붕대·치료제)만 남에게 쓸 수 있다 |

`ItemDefinition.is_treatment()`: 지혈 효과나 치료 효과가 있는 아이템(붕대, 치료제). `allow_feeding_others`가 꺼져 있을 때 남에게 쓸 수 있는 종류의 기준이다. 아이템 정의 데이터는 바뀌지 않았다.

**음식·물을 남에게 주기(P2-T13, docs/00 ADR-019).** 사용자 결정(2026-11-15): "음식 물은 아이템 형식이라 남에게 줄 수 있게". 기본값을 켰을 뿐 서버 규칙·RPC·알림 형식은 P2-T12 그대로다(`PROTOCOL_VERSION` 8 유지). 주는 쪽의 한 단위가 줄고(`remove_player_item`) 받는 쪽의 허기·갈증이 `reduce_needs(target)`로 내려간다: 아이템이 받는 쪽 인벤토리로 옮겨 가지는 않는다(옮겨 가는 "건네기"는 P2-T14, §14.28). 검사 순서는 아래 표와 같고, 음식·물에는 대상 상태에 따른 거부(표의 12)가 없다: 자기가 먹을 때처럼 받는 쪽의 허기·갈증이 0이어도 수락되고 소비된다(§14.18, ADR-013). 그래서 음식·물로는 대상에 대해 알아낼 수 있는 것이 없다. 알림은 치료와 같다: 받는 쪽은 `{scope: "target", user_id, definition_id, ok: true, ...}`, 다른 접속자는 `{scope: "public", user_id, target_id, world_time}`(무엇을 줬는지 없음). 받는 쪽의 욕구 변화는 본인의 기존 생존 스냅샷으로만 간다. 테스트: `treat_other_test.gd::test_by_default_food_is_given_to_another_player_close_by`, `treat_other_net_test.gd::test_a_client_gives_food_and_water_to_another_player`.

#### 서버 규칙(`ItemConsumption.try_use_on(world, user_id, item_instance_id, target_id) -> ActionResult`)

`target_id`가 빈 문자열이거나 사용자 자신의 ID면 **자기 사용**이다: `try_consume`을 그대로 부르고 이벤트(`item_consumed`)와 사유도 그것이다. 그 밖에는 아래 순서로 검사하고, 하나라도 걸리면 아무것도 바뀌지 않는다(아이템·두 플레이어의 생존 상태·이벤트·트랜잭션 모두).

| 순서 | 사유 코드 | 조건 |
|---|---|---|
| 1 | `not_online` | 사용자가 월드에 없음(오프라인, 캐릭터 없는 접속자, 모르는 플레이어) |
| 2 | `consumption_unavailable` | 생존 시스템 없음(조립 오류) |
| 3 | `unknown_player` / `player_dead` | 사용자의 생존 상태가 없음 / 사용자가 죽음 |
| 4 | `player_resting` 등 | 사용자가 행동할 수 없음(`player_action_block_reason`: 자는 플레이어는 먼저 일어나야 한다). 엎드린 사용자는 쓸 수 있다 |
| 5 | `unknown_item` / `item_not_in_inventory` | 그 아이템이 없음 / 사용자가 들고 있지 않음(남의 것, 월드의 것). 네트워크 계층은 둘을 `item_not_in_inventory` 하나로 알린다 |
| 6 | `not_consumable` | 사용 효과가 없는 아이템 |
| 7 | `not_usable_on_others` | 남에게 줄 수 있는 효과가 없음(`allow_feeding_others`를 끈 서버의 음식·물. 기본 설정에서는 사용 효과가 있는 아이템이면 모두 통과한다) |
| 8 | `target_unavailable` | 대상이 월드에 없음: 모르는 ID, 오프라인, 캐릭터 없는 접속자. **셋을 한 사유로 합쳤다**(플레이어 ID가 존재하는지 떠볼 수 없게) |
| 9 | `target_dead` | 대상이 죽음 |
| 10 | `target_too_far` | 서버 위치 기준 거리 > `treat_range_m` |
| 11 | `bad_need_amount` | (음식을 남에게 주는 설정에서) 정의의 수치가 잘못됨 |
| 12 | `not_bleeding`, `not_infected` / `too_late` | 대상에게 치료할 것이 없음(§14.21·§14.22의 규칙을 대상에게 적용). 지혈·치료 효과가 모두 있는 아이템은 적용되는 것만 적용하고, 둘 다 적용되지 않으면 지혈 쪽 사유가 먼저다 |

순서의 뜻: 사용자가 쓸 수 있는 아이템을 들고 있기 전에는 대상에 대해 아무것도 보지 않는다(5~7이 8보다 앞). 대상의 상태(12)는 가장 마지막, 곧 대상 바로 옆에서 치료를 시도한 경우에만 본다(10이 12보다 앞): 멀리 있는 플레이어에게 치료제를 "써 봐서" 감염 여부를 알아낼 수 없다. 죽음(9)과 거리(10)는 이미 공개된 사실이다.

- **원자성**: 모든 조건을 먼저 검사한 뒤 사용자의 인벤토리에서 한 단위를 빼고(`remove_player_item`, 트랜잭션 하나) 대상에게 효과를 적용한다. 거부되면 아이템은 그대로 남는다(치료품은 낭비되지 않는다, §14.21과 같다).
- **효과는 대상의 것, 아이템은 사용자의 것**: 붕대는 대상의 가장 심한 출혈 상처부터 지혈하고(`stop_worst_bleeding(target)`), 치료제는 대상의 감염을 해제한다(`apply_infection_treatment(target)`, 치료 가능 단계는 §14.22 그대로). 사용자 자신의 상처·감염은 건드리지 않는다. 남에게 쓸 때 먹기·마시기 효과는 `allow_feeding_others`가 켜져 있을 때만(기본 켬, P2-T13) 적용되고, 그때는 대상의 허기·갈증이 내려간다.
- **대상의 동의는 없다**: 대상은 거부할 수 없다. 남에게 줄 수 있는 효과가 모두 이로운 것(지혈, 감염 해제, 설정 시 식사)뿐이라는 전제다(PvP 비활성, docs/00). 대상에게서 빼앗는 것은 없다(docs/15 P2-197).
- **자는·엎드린 대상**: 치료할 수 있고, 치료받아도 깨지 않는다(자는 동료에게 붕대를 감아 줄 수 있다). 자세도 바뀌지 않는다.
- **죽은 대상, 오프라인 대상, 캐릭터 없는 접속자**: 대상이 될 수 없다(`target_dead`, `target_unavailable`). 캐릭터 없는 접속자는 사용자도 될 수 없다(`not_online`).
- 성공 이벤트 `{event_type: "item_used_on_player", player_id(사용자), target_id, item_instance_id, definition_id, remaining_quantity, hunger_reduced, thirst_reduced, bleeding_stopped_wound_ids, infection_cured_from, world_time}`. 서버 로그와 반환값으로만 쓰이고 그대로 복제되지 않는다.
- `ItemConsumption.is_target_state_refusal(reason)`: 사유가 대상의 상태(12)에 관한 것인지. 네트워크 계층이 "치료를 시도했다"는 알림을 보낼지 정하는 데 쓴다.

#### 네트워크 메시지(`InventoryNetModule`에 추가, §14.17·§14.18)

| 방향 | RPC | 채널/모드 | 받는 쪽 검증 |
|---|---|---|---|
| C→S | `_rpc_request_use_on(request_id: int, item_instance_id: String, target_player_id: String)` | 0 reliable | 아래 "요청 검증" |
| S→요청자 | `_rpc_use_on_result(request_id: int, ok: bool, reason: String)` | 0 reliable | 서버 발신만 수용, 타입, `request_id` ≥ 0, `reason` 길이 ≤ 64, `ok`일 때만 `reason`이 빈 문자열 |
| S→대상·제3자 | `_rpc_treatment_notice(notice: Dictionary)` | 0 reliable | 서버 발신만 수용, `InventoryNetModule.is_valid_treatment_notice`: scope별 정확한 키, 서로 다른 두 플레이어 ID, 받는 쪽이 맞는지(대상 알림은 대상만, 공개 알림은 사용자도 대상도 아닌 쪽만) |

기존 소비 의도(`_rpc_request_consume(request_id, item_instance_id)`)는 **그대로다**: 인자가 둘이고 항상 자기 자신에게 쓴다. 새 의도는 대상 인자가 하나 더 있는 별도 RPC이고, 대상이 비어 있으면 소비 의도와 같은 결과를 낸다(자기 사용 경로와의 호환). 그래서 §14.21·§14.22의 "소비 의도로는 남을 치료할 수 없다"는 테스트는 그대로 통과한다. 위치·거리·효과·대상의 상태를 싣는 인자는 없고, 인자를 더 붙인 호출은 엔진이 거부한다(테스트로 고정).

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 바뀌지 않고 `rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드 | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | `request_id`가 int가 아님, 아이템 ID나 대상 ID가 String이 아님 | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `bad_item_id` | 아이템 ID가 비었거나 64자 초과 | 보냄 |
| 5 | `bad_target_id` | 대상 ID가 64자 초과(빈 문자열은 "자기 자신"이라 허용) | 보냄 |
| 6 | `rate_limited` | peer별 토큰 버킷. **소비 의도와 같은 버킷**(`consume_intent_rate_per_sec`/`consume_intent_burst`)을 쓴다: 남에게 쓰는 것도 사용이다 | 보냄 |
| 7 | 서버 규칙의 사유(위 표) | `unknown_item`은 `item_not_in_inventory`로 바꿔 알린다 | 보냄 |

**결과와 정보 공개**(ADR-009, ADR-018). 누가 무엇을 받는가:

| 받는 쪽 | 받는 것 | 그것으로 알게 되는 것 |
|---|---|---|
| 사용자(요청자) | 결과 `(ok, reason)`와 자기 인벤토리 변화(줄어든 묶음) | 아래 표. 그 밖의 것은 받지 않는다: 대상의 체력, 상처 목록·부위, 지혈된 상처 ID, 남은 출혈 수, 감염 단계 이름, 대상의 생존 이벤트 |
| 대상 | 자기 생존 이벤트·스냅샷(§14.14: `player_bleeding_stopped`, `player_infection_cured`)과 대상 알림 `{scope: "target", user_id, target_id, definition_id, ok, reason, world_time}` | 누가 무엇을 자기에게 썼고 효과가 있었는지. 효과가 없었던 시도(`ok: false`)도 받는다(예: 치료제를 놓으려 했다) |
| 제3자(다른 접속자 전부) | 공개 알림 `{scope: "public", user_id, target_id, world_time}` | "A가 B를 돌봤다"는 사실뿐. 어떤 아이템인지, 성공했는지, B의 상처·감염은 받지 않는다 |

사용자가 결과 사유로 알게 되는 것(사용자가 감수하기로 한 범위):

| 아이템 | 결과 | 드러나는 것 |
|---|---|---|
| 붕대 | 승인 | 대상에게 출혈 중인 상처가 있었다(적어도 한 곳이 지혈됐다). 몇 곳이 더 출혈 중인지는 모른다 |
| 붕대 | `not_bleeding` | 대상에게 출혈 중인 상처가 없다 |
| 치료제 | 승인 | 대상이 감염돼 있었고 치료 가능한 단계(잠복·초기)였다. 지금은 감염이 없다 |
| 치료제 | `not_infected` | 대상이 감염되지 않았다 |
| 치료제 | `too_late` | 대상이 감염돼 있고 치료 가능 단계를 지났다(진행·중증·말기 중 어느 것인지는 모른다) |
| 모든 아이템 | `target_dead`, `target_too_far`, `target_unavailable` | 이미 공개된 사실(생사, 위치, 접속)뿐 |

공개 알림은 **성공한 사용과, 대상의 상태 때문에 거부된 시도(`not_bleeding`, `not_infected`, `too_late`) 모두에** 보낸다. 제3자에게는 둘이 똑같이 보이므로, 옆에서 본 사람은 "치료가 필요했는지"를 알 수 없다(치료제 사용의 성공만 알리면 대상의 감염이 제3자에게 드러난다). 그보다 앞에서 거부된 요청(남의 아이템, 음식, 없는 대상, 죽은 대상, 먼 대상)과 자기 사용은 아무에게도 알리지 않는다. 대상과 제3자에게 보내는 알림에 거리·시야 제한은 없다(다른 공개 사실과 같다).

저장: 먹기·붕대·치료제와 같다(§14.18). 남에게 쓴 것만으로는 저장하지 않고 다음 저장에 들어가며, `save_after_consume`을 켜면 결과 전송 전에 저장한다. 저장 스키마는 바뀌지 않았다.

클라이언트 표면(`InventoryNetModule`): `request_use_on(item_instance_id, target_player_id) -> int`(요청 번호, join 전이면 `NO_REQUEST`), `signal use_on_result(request_id, ok, reason)`, `signal treatment_seen(notice)`, `recent_treatment_notices()`(최근 16개), `send_raw_use_on_request(...)`(테스트 전용).

클라이언트 표시(`scripts/presentation/`): `TreatTargetPolicy.pick_target(local_player_id, players, excluded_ids, facing_yaw, range_m, half_angle_rad)`가 미러의 위치에서 "카메라가 바라보는 방향의 가장 가까운 다른 플레이어"를 고른다(XZ 평면, 사거리 `treat_target_range_m` 2.5m, 반각 `treat_target_half_angle_deg` 60도, 죽은 플레이어 제외, 거리가 같으면 ID가 작은 쪽). 순수 함수이고 고른 ID를 보낼 뿐이다: 실제로 치료할 수 있는지는 서버가 정한다. 남에게 쓰기는 **보조 키(`treat_other_modifier_key`, 기본 Shift)를 누른 채 붕대 키(B)나 치료제 키(V)**다. 보조 키 없이 누르면 지금까지처럼 자기에게 쓴다. P2-T13부터 음식 키(F)·물 키(G)도 보조 키와 함께 누르면 남에게 준다(`ConsumeIntentPolicy.is_usable_on_others`가 네 종류 모두 true). 생존 HUD 끝에 "줄 대상: 이름 | 음식 [Shift+F] 물 [Shift+G] 붕대 [Shift+B] 치료제 [Shift+V]" 또는 "줄 대상: 없음 (가까이서 바라보기)"가 붙는다(매 물리 프레임 후보를 다시 고르고 바뀌면 HUD를 갱신한다). 결과는 사용 결과 자리에 문장으로 표시하고("남에게 사용 승인", "남에게 사용 거부: 상대에게 출혈이 없습니다" 등), 대상·제3자가 받는 알림은 이벤트 로그에 한 줄로 남긴다("영희이(가) 나에게 붕대 사용", "영희 → 민수 돌봄"). 화면 설명은 docs/11 §2.11.

테스트: `tests/unit/treat_other_test.gd`(설정·아이템 종류·대상 상태 사유 분류, 붕대로 남의 가장 심한 출혈을 지혈하고 자기 상처는 그대로임·이벤트·한 트랜잭션, 치료제의 성공·`not_infected`·`too_late`, 지혈+치료 아이템, 대상 검증(없는 ID, 좀비 ID, 오프라인, 사망), 캐릭터 없는 접속자는 대상도 사용자도 아님, 사거리 경계(정확히 사거리는 승인, 0.01m 밖은 거부)와 설정, 자는·엎드린 대상과 깨우지 않음·엎드린 사용자·자는 사용자, 사용자와 아이템 검증(남의 것, 월드의 것, 없는 ID, 플레이어 ID, 효과 없는 아이템, 오프라인·사망 사용자), 음식 불가와 설정 시 허용, 자기 사용과의 호환, 검사 순서, 거부마다 인벤토리 스냅샷·두 사람의 생존 fragment 불변과 트랜잭션·이벤트 0개), `tests/integration/treat_other_net_test.gd`(서버 1 + 클라이언트 3, 실제 ENet: A가 B에게 붕대 → 서버와 B 미러의 출혈 상태 일치, A 인벤토리 감소, A는 결과만(알림·생존 이벤트 0개), B는 대상 알림과 본인 지혈 이벤트, C는 공개 알림만(키 목록 고정, 사적 단어 없음, 생존 이벤트 0개) / 출혈이 없을 때의 거부와 보존, 그때도 B·C가 같은 알림을 받음 / 비감염 B에게 치료제 → `not_infected`·보존, 감염된 B → 완치, 너무 늦은 단계 → `too_late`, C의 미러 불변 / 자기 사용 / 남의 아이템·없는 아이템·음식·없는 대상·먼 대상·죽은 대상·오프라인 대상·죽은 사용자 / 조작된 요청 11종과 인자를 더 붙인 호출·클라이언트가 보낸 서버 메시지 / join 전 요청·빈도 초과(소비 의도와 버킷 공유) / RPC 구성·요청 검증·알림 검증 규칙), `tests/unit/treat_target_test.gd`(대상 후보 선택: 가장 가까운 플레이어, 사거리, 바라보는 방향과 원뿔 경계, 제외 목록, 동률, 잘못된 미러 행과 인자 / 키 등록·설정 검증 / HUD 줄, 결과 문장, 알림 문구). 고친 기존 테스트: `tests/integration/inventory_net_test.gd`의 RPC 목록에 새 RPC 셋 추가.

### 14.28 아이템 건네기(P2-T14, docs/00 ADR-020)

> **P2-T15에서 철회됨(사용자 결정 2026-11-16, docs/00 ADR-021, §14.29).** 이 절은 기록으로 남긴다. 지금의 코드와 다른 부분은 다음과 같다.
> - **없어진 것**: 서버 규칙 `ServerWorld.try_hand_over_item`과 이벤트 `item_handed_over`, 사유 코드 `target_is_self`·`target_inventory_full`, 설정 `GameplaySettings.hand_over_range_m`, RPC 셋(`_rpc_request_hand_over`, `_rpc_hand_over_result`, `_rpc_hand_over_notice`)과 `InventoryNetModule`의 건네기 API(`request_hand_over`, `hand_over_result`, `hand_over_seen`, `validate_hand_over_request`, `is_valid_hand_over_notice`), 클라이언트의 건네기 보조 키·수량 설정(`hand_over_modifier_key`, `hand_over_quantity`)·`UseMode.HAND_OVER`·HUD 대상 줄의 "건네기 [Ctrl+…]"·결과와 알림 문구, 테스트 `hand_over_net_test.gd`·`hand_over_presentation_test.gd`와 `hand_over_test.gd`의 규칙 부분.
> - **남은 것**: 트랜잭션 `InventoryService.transfer_item`(아래 "서버 트랜잭션" 항 그대로)과 그 복제(`item_transferred` → 두 소유자에게만), 훅 `ServerSystem.player_is_dead`·`ServerWorld.is_player_dead`, 대상 사유 코드 셋(`target_unavailable`, `target_dead`, `target_too_far`: 치료·먹여 주기가 쓴다). `transfer_item`을 부르는 플레이어 의도는 없다: 서버 규칙용 진입점으로만 남았다. 단위 테스트는 `tests/unit/item_transfer_test.gd`(`hand_over_test.gd`의 트랜잭션 부분), 복제 테스트는 `ground_transfer_net_test.gd::test_a_server_rule_that_transfers_reaches_both_owners_only`.

사용자 결정(2026-11-15): "건네기도 추가". 들고 있는 아이템을 가까이 있는 다른 플레이어에게 건네면 그 아이템이 받는 쪽 인벤토리로 옮겨 가고, 받는 쪽은 그것을 보관했다가 나중에 쓴다. 먹여 주기(§14.27, ADR-019: 받는 쪽의 허기·갈증이 바로 내려가고 아이템은 없어진다)는 그대로이고, 건네기는 그것과 별개의 경로다: 건네기로는 누구의 허기·갈증·상처·감염도 바뀌지 않는다. 클라이언트는 아이템·대상 플레이어·수량만 지정하고 나머지는 모두 서버 상태에서 판정한다. 임시 가정은 docs/15 §14.5 P2-205~P2-212.

구성: `InventoryService.transfer_item`(트랜잭션), `ServerWorld.try_hand_over_item`(서버 규칙)과 `is_player_dead`, `ServerSystem.player_is_dead`(새 훅, `SurvivalService`가 구현, §14.5), `GameplaySettings.hand_over_range_m`, `InventoryNetModule`(건네기 의도 RPC와 결과, 건네기 알림, `item_transferred` 복제), 클라이언트 건네기 보조 키·HUD·문구. `network_service.gd`는 수정하지 않았다. `ItemConsumption`은 대상 사유 상수 셋(`target_unavailable`, `target_dead`, `target_too_far`)이 `ServerWorld`의 같은 상수를 가리키게 했을 뿐 동작은 그대로다(같은 뜻의 사유는 같은 코드 하나를 쓴다).

**프로토콜 변경 있음**: RPC 3개(`_rpc_request_hand_over`, `_rpc_hand_over_result`, `_rpc_hand_over_notice`)가 새로 생겨 `BuildInfo.PROTOCOL_VERSION`을 9로 올렸다. 기존 RPC와 메시지 형식, join 스냅샷 형식, 저장 스키마는 바뀌지 않았다.

#### 데이터

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `GameplaySettings.hand_over_range_m` | 2.5 | 건네는 플레이어와 받는 플레이어 사이의 최대 거리(m). 서버가 가진 두 위치 사이의 3차원 거리이고 경계(정확히 2.5m)는 허용한다. 치료 사거리(`treat_range_m`)와 값은 같지만 별도 설정이다 |
| `InventoryNetSettings.drop_intent_rate_per_sec` / `drop_intent_burst` | 4/s / 4 | 건네기 의도의 빈도 제한. **내려놓기 의도와 같은 버킷**을 쓴다(아래 "요청 검증") |
| `ClientPresentationSettings.hand_over_modifier_key` | Ctrl | 건네기 보조 키(클라이언트 전용) |
| `ClientPresentationSettings.hand_over_quantity` | 1 | 키를 한 번 누를 때 건네는 수량(클라이언트 전용. 서버는 1..묶음 수량이면 어떤 수량이든 받는다) |

아이템 정의는 바뀌지 않았다. 건넬 수 있는 종류를 제한하는 데이터는 없다: 모든 아이템을 건넬 수 있다.

#### 서버 트랜잭션(`InventoryService.transfer_item(from_inventory_id, item_instance_id, to_inventory_id, quantity) -> ActionResult`)

§14.17의 트랜잭션과 같은 규칙이다: 검사를 전부 마친 뒤에만 반영하고, 실패하면 사유 코드만 있고 아무것도 바뀌지 않으며, 성공하면 `transaction_committed`가 한 번 나온다.

- 실패 사유(검사 순서): `unknown_inventory`(주는 쪽) → `unknown_item` → `item_not_in_inventory` → `bad_quantity`(1 미만이거나 묶음 수량 초과) → `unknown_inventory`(받는 쪽) → `same_inventory`(주는 쪽과 받는 쪽이 같음) → `inventory_full`(받는 쪽에 전부 들어가지 않음) → `id_unavailable`(새 아이템 ID를 등록할 수 없음. 일어나지 않아야 하는 경우의 방어이고 오류 로그를 남긴다).
- **받는 쪽에서 들어가는 자리**:
  1. 받는 쪽이 가진 **같은 정의·같은 `condition`·같은 `quality`**의 묶음을 슬롯 번호가 작은 것부터 `max_stack`까지 채운다(`items_in_inventory`의 글자 순서가 아니라 숫자 순서: `slot_2`가 `slot_10`보다 먼저다).
  2. 그러고도 남은 수량은 받는 쪽의 첫 빈 슬롯에 **한 묶음**으로 들어간다(건넨 수량 ≤ 원래 묶음 ≤ `max_stack`이라 빈 칸은 하나면 된다).
  3. 남은 수량이 있는데 빈 슬롯이 없으면 **요청 전체를 거부**한다(`inventory_full`). 들어가는 만큼만 옮기는 일은 없다. 반대로 전부가 기존 묶음에 합쳐지면 빈 슬롯이 없어도 승인된다.
- **보존**: 주는 쪽에서 빠진 수량과 받는 쪽에 늘어난 수량이 항상 같다. 정의별 총수량은 어떤 경우에도(일부 건네기, 합치기, 넘침, 거부) 변하지 않는다. `condition`·`quality`가 다른 묶음끼리는 합치지 않으므로 단위의 상태가 평균되어 사라지지도 않는다.
- **아이템 인스턴스 ID**(docs/14 §1: 유일하고 재사용하지 않는다):

| 경우 | 받는 쪽에 생기는 것 | 주는 쪽 인스턴스 |
|---|---|---|
| 건넨 수량이 전부 기존 묶음에 합쳐짐, 주는 쪽에 남는 수량 있음 | 새 인스턴스 없음(받는 쪽 묶음의 수량만 증가) | 수량만 줄어듦 |
| 전부 합쳐짐, 주는 쪽 묶음이 0이 됨 | 새 인스턴스 없음 | 삭제되고 ID는 tombstone 처리(재사용 불가) |
| 남은 수량이 빈 슬롯으로, 주는 쪽 묶음이 0이 됨(묶음 전체를 건넴) | **주는 쪽 인스턴스가 그 ID 그대로** 받는 쪽으로 옮겨 감(수량 = 남은 수량) | 받는 쪽 것이 됨 |
| 남은 수량이 빈 슬롯으로, 주는 쪽에 남는 수량 있음(묶음의 일부를 건넴) | **새 ID의 새 인스턴스**(수량 = 남은 수량, `condition`·`quality`는 원래 묶음의 것) | 수량만 줄어듦 |

  두 묶음이 같은 ID를 갖는 경우는 없다. 새 ID는 상태를 바꾸기 전에 발급·등록한다.
- 성공 이벤트(JSON-safe) `item_transferred` = `{event_type, from_inventory_id, to_inventory_id, item_instance_id(주는 쪽 묶음), definition_id, quantity(옮긴 수량), remaining_quantity(주는 쪽 묶음에 남은 수량. 0 = 그 인스턴스가 주는 쪽 인벤토리를 떠남), received: [{item_instance_id, quantity}](받는 쪽에서 수량이 늘었거나 새로 들어온 인스턴스와 늘어난 수량. 위 1 → 2의 순서)}`.

#### 서버 규칙(`ServerWorld.try_hand_over_item(player_id, item_instance_id, target_player_id, quantity) -> ActionResult`)

줍기·내려놓기 래퍼(`try_pickup`, `try_drop_item`) 옆의 진입점이다. 아래 순서로 검사하고, 하나라도 걸리면 아무것도 바뀌지 않는다(아이템, 두 플레이어, 모든 시스템의 상태, ID 순번, tombstone, 트랜잭션·이벤트 모두).

| 순서 | 사유 코드 | 조건 |
|---|---|---|
| 1 | `not_online` | 건네는 쪽이 월드에 없음(모르는 플레이어, 오프라인, 캐릭터 없는 접속자) |
| 2 | `player_dead`, `player_resting` 등 | 건네는 쪽이 행동할 수 없음(`player_action_block_reason`: 죽은 캐릭터, 자는 플레이어는 먼저 일어나야 한다). 엎드린 채로는 건넬 수 있다 |
| 3 | `unknown_item` / `item_not_in_inventory` | 그 아이템이 없음 / 건네는 쪽이 들고 있지 않음(남의 것, 월드의 것). 네트워크 계층은 둘을 `item_not_in_inventory` 하나로 알린다 |
| 4 | `bad_quantity` | 수량이 1 미만이거나 그 묶음의 수량보다 많음 |
| 5 | `target_is_self` | 대상이 건네는 쪽 자신 |
| 6 | `target_unavailable` | 대상이 월드에 없음: 모르는 ID, 플레이어가 아닌 ID, 오프라인, 캐릭터 없는 접속자. **한 사유로 합쳤다**(§14.27과 같은 코드, 플레이어 ID가 존재하는지 떠볼 수 없게) |
| 7 | `target_dead` | 대상이 죽음(`ServerWorld.is_player_dead`) |
| 8 | `target_too_far` | 서버 위치 기준 거리 > `hand_over_range_m` |
| 9 | `target_inventory_full` | 받는 쪽 인벤토리에 전부 들어가지 않음(트랜잭션의 `inventory_full`. 요청자 자신의 인벤토리가 찼다는 줍기의 `inventory_full`과 구분하려고 코드를 따로 뒀다) |

순서의 뜻: 건네는 쪽이 그 아이템을 들고 있고 가진 만큼의 수량을 요청하기 전에는 대상에 대해 아무것도 보지 않는다(3·4가 5~9보다 앞). 소유 검사가 수량 검사보다 앞이라 남의 묶음에 몇 개가 있는지도 알 수 없다. 받는 쪽 인벤토리(9)는 가장 마지막, 곧 대상 바로 옆에서 건네려 한 경우에만 본다(8이 9보다 앞): 멀리 있는 플레이어의 인벤토리가 찼는지를 떠볼 수 없다. 접속 여부(6), 죽음(7), 거리(8)는 이미 공개된 사실이다.

- **모든 아이템**: 음식·물·붕대·치료제만이 아니라 사용 효과가 없는 아이템과 무기도 건넬 수 있다. 정의의 종류는 보지 않는다.
- **원자성**: 조건을 모두 검사한 뒤 `transfer_item` 한 번으로 확정한다. 트랜잭션이 아이템·수량 조건을 다시 검사하고 자리가 있는지를 정한다.
- **대상의 동의는 없다**: 받는 쪽은 거부할 수 없다. 자는·엎드린 대상도 받고, 받아도 깨지 않으며 자세가 바뀌지 않는다.
- **죽은 대상, 오프라인 대상, 캐릭터 없는 접속자**는 받을 수 없다. 죽은 캐릭터와 자는 플레이어, 캐릭터 없는 접속자는 건넬 수도 없다.
- 성공 이벤트 `{event_type: "item_handed_over", player_id(건넨 쪽), target_id, item_instance_id, definition_id, quantity, remaining_quantity, received, world_time}`. 서버 로그와 반환값으로만 쓰이고 그대로 복제되지 않는다.
- 생존 시스템이 없는 월드에서도 동작한다(그 월드에는 죽은 플레이어가 없다). `player_is_dead` 훅 덕분에 `ServerWorld`는 생존 시스템을 직접 알지 않는다.

#### 네트워크 메시지(`InventoryNetModule`에 추가, §14.17)

| 방향 | RPC | 채널/모드 | 받는 쪽 검증 |
|---|---|---|---|
| C→S | `_rpc_request_hand_over(request_id: int, item_instance_id: String, target_player_id: String, quantity: int)` | 0 reliable | 아래 "요청 검증" |
| S→요청자 | `_rpc_hand_over_result(request_id: int, ok: bool, reason: String)` | 0 reliable | 서버 발신만 수용, 타입, `request_id` ≥ 0, `reason` 길이 ≤ 64, `ok`일 때만 `reason`이 빈 문자열 |
| S→받는 쪽·제3자 | `_rpc_hand_over_notice(notice: Dictionary)` | 0 reliable | 서버 발신만 수용, `InventoryNetModule.is_valid_hand_over_notice`: scope별 정확한 키, 서로 다른 두 플레이어 ID, 받는 쪽이 맞는지(대상 알림은 받는 플레이어만, 공개 알림은 건넨 쪽도 받는 쪽도 아닌 플레이어만), 대상 알림의 `definition_id`(snake_case, ≤ 64자)와 `quantity`(int ≥ 1) |

요청: 클라이언트는 의도만 보낸다(요청 번호, 들고 있는 아이템의 ID, 대상 플레이어 ID, 수량). 위치·거리·소유자·받는 쪽 슬롯을 싣는 인자는 없고, 건네는 쪽은 보낸 peer의 플레이어다. 인자를 더 붙인 호출은 엔진이 거부한다(테스트로 고정).

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 바뀌지 않고 `rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드 | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | `request_id`·`quantity`가 int가 아님, 아이템 ID나 대상 ID가 String이 아님 | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `bad_item_id` | 아이템 ID가 비었거나 64자 초과 | 보냄 |
| 5 | `bad_target_id` | 대상 ID가 비었거나 64자 초과(§14.27과 달리 빈 문자열은 허용하지 않는다: "자기 자신"이라는 뜻이 없다) | 보냄 |
| 6 | `bad_quantity` | `quantity` < 1 | 보냄 |
| 7 | `rate_limited` | peer별 토큰 버킷. **내려놓기 의도와 같은 버킷**(`drop_intent_rate_per_sec`/`drop_intent_burst`)을 쓴다: 둘 다 아이템을 인벤토리에서 내보내고 승인되면 바로 저장하므로, 한 peer가 일으킬 수 있는 저장 횟수를 한 허용량으로 묶는다. 소비·남에게 쓰기 버킷과는 별개다. 형식이 틀린 요청은 토큰을 쓰지 않는다 | 보냄 |
| 8 | 서버 규칙의 사유(위 표) | `unknown_item`은 `item_not_in_inventory`로 바꿔 알린다(§14.17 `public_reason`). 묶음 수량을 넘는 수량도 여기서 `bad_quantity`다 | 보냄 |

- 1~7은 `reject_intent`(횟수 + 경고 로그), 8은 정상 플레이에서 생길 수 있어 `count_rejection`(횟수만)이다.

**복제와 정보 공개**(ADR-009, ADR-020). 누가 무엇을 받는가:

| 받는 쪽 | 받는 것 | 그것으로 알게 되는 것 |
|---|---|---|
| 건넨 쪽(요청자) | 자기 인벤토리 변화: 묶음이 남으면 `_rpc_inventory_item_changed`(줄어든 묶음), 묶음이 떠났으면 `_rpc_inventory_items_removed`(그 ID). 이어서 결과 `(ok, reason)` | 건네졌는지. 받는 쪽 인벤토리의 내용은 받지 않는다(받는 쪽 묶음의 ID·수량·슬롯 모두). 단 `target_inventory_full`은 "상대가 이것을 이만큼 받을 자리가 없다"를, 승인은 "자리가 있었다"를 알려 준다(아래) |
| 받는 쪽 | 자기 인벤토리 변화: 수량이 늘었거나 새로 들어온 묶음마다 `_rpc_inventory_item_changed`(기존 소유자 전용 메시지를 그대로 쓴다. 미러는 같은 ID면 교체, 없으면 추가). 이어서 대상 알림 `{scope: "target", giver_id, receiver_id, definition_id, quantity, world_time}` | 누가 무엇을 몇 개 건넸는지(`quantity`는 건넨 수량이고 어느 묶음에 어떻게 나뉘었는지는 인벤토리 메시지에 있다) |
| 제3자(다른 접속자 전부) | 공개 알림 `{scope: "public", giver_id, receiver_id, world_time}` | "A가 B에게 무언가를 건넸다"는 사실뿐. 어떤 아이템인지, 몇 개인지, 두 사람의 인벤토리는 받지 않는다 |

- 인벤토리 메시지는 §14.17과 같이 트랜잭션이 확정되는 그 자리에서 나가고(건넨 쪽 것 먼저, 받는 쪽 것 다음), 그 뒤에 저장, 알림, 결과 순이다. 같은 채널이라 건넨 쪽은 결과보다 자기 인벤토리 변화를 먼저 받는다.
- 다른 플레이어의 인벤토리는 여전히 어떤 메시지로도 가지 않는다(§14.17). 각 소유자에게는 "지금 그 인벤토리에 있는" 인스턴스만 보낸다.
- 알림은 **확정된 건네기에만** 보낸다. 거부된 요청은 요청자 말고는 누구에게도 알리지 않는다(받는 쪽도 "누가 건네려다 실패했다"를 받지 않는다). 건넨 쪽은 알림을 받지 않는다(결과만). 알림에 거리·시야 제한은 없다(치료 알림과 같다).
- 치료 알림(`_rpc_treatment_notice`)을 재사용하지 않고 형제 RPC를 둔 이유: 제3자에게 "돌봤다"와 "건넸다"는 눈으로 구분되는 서로 다른 사실이고, 받는 쪽 알림의 필드가 다르며(`quantity`가 있고 `ok`·`reason`이 없다), 기존 알림의 형식과 엄격한 검증(정확한 키 목록)을 건드리지 않기 위해서다. 클라이언트 검증의 엄격함은 `is_valid_treatment_notice`와 같다.
- **남는 정보 경로**(사용자 확인 필요, docs/15 P2-210): 건네는 쪽은 결과로 받는 쪽 인벤토리에 대해 한 가지를 알게 된다: 그 아이템을 그 수량만큼 받을 자리가 있는지. 바로 옆(사거리 안)에서만 물을 수 있고, 승인되면 실제로 아이템이 넘어간다.

저장: 줍기·내려놓기와 같은 "주요 트랜잭션"이다(§14.17, docs/10 §5). 승인되면 결과를 보내기 전에 월드 전체를 저장한다. 저장은 항상 월드 전체를 한 번에 쓰므로 두 인벤토리 중 한쪽만 반영된 저장은 없다. 거부된 요청은 저장하지 않는다. 저장 스키마는 바뀌지 않았다: 옮겨 간 인스턴스는 `location_id`·`slot_id`만 다르고, 합쳐져 없어진 ID는 world_state `tombstones`에, 새 ID의 다음 순번은 `next_entity_sequence`에 들어간다.

클라이언트 표면(`InventoryNetModule`): `request_hand_over(item_instance_id, target_player_id, quantity) -> int`(요청 번호, 1부터. join 전이면 `NO_REQUEST`. 클라이언트에서 미리 판단하지 않는다), `signal hand_over_result(request_id, ok, reason)`, `signal hand_over_seen(notice)`(검증을 통과한 건네기 알림), `send_raw_hand_over_request(request_id, item_instance_id, target_player_id, quantity)`(테스트 전용), 순수 함수 `validate_hand_over_request`·`is_valid_hand_over_notice`. 받는 쪽 인벤토리 미러는 기존 `inventory_item_changed` 시그널로 바뀐다. 미러에는 권한이 없다.

클라이언트 표시(`scripts/presentation/`): **건네기 보조 키(`hand_over_modifier_key`, 기본 Ctrl)를 누른 채 사용 키(음식 F, 물 G, 붕대 B, 치료제 V)**를 누르면, 미러 인벤토리에서 그 종류의 첫 아이템을 `hand_over_quantity`개(기본 1. 미러의 묶음 수량보다 많이는 요청하지 않는다: `ConsumeIntentPolicy.hand_over_quantity`) "남에게 쓰기"와 같은 대상 후보(`TreatTargetPolicy`, §14.27)에게 건네 달라는 의도를 보낸다. 보조 키 둘의 뜻은 순수 함수 `ConsumeIntentPolicy.use_mode(kind, treat_other_held, hand_over_held)`가 정한다: 아무것도 누르지 않으면 자기 사용, Shift면 남에게 쓰기, Ctrl이면 건네기, **둘 다 누르면 건네기**(아무것도 소비하지 않는 쪽). 네 종류 어디에도 속하지 않는 아이템(개발용 `dev_test_item`, `dev_melee_pipe`)은 서버 규칙으로는 건넬 수 있지만 **클라이언트 입력이 아직 없다**(docs/15 P2-211). HUD의 대상 줄 끝에 건네기 키가 붙는다: "줄 대상: 이름 | 음식 [Shift+F] 물 [Shift+G] 붕대 [Shift+B] 치료제 [Shift+V] | 건네기 [Ctrl+F/G/B/V]". 결과는 사용 결과 자리에 문장으로 표시하고("건네기 승인", "건네기 거부: 상대의 소지품이 가득 찼습니다" 등), 받는 쪽·제3자가 받는 알림은 이벤트 로그에 한 줄로 남긴다("영희이(가) 나에게 Development Ration x2 건넴": 아이템 이름은 정의의 표시 이름이다. "영희 → 민수 물건 건넴"). 화면 설명은 docs/11 §2.12.

테스트: `tests/unit/hand_over_test.gd`(트랜잭션: 묶음 전체가 ID 그대로 옮겨 감, 일부는 새 ID의 새 인스턴스, 같은 정의 묶음에 합치기와 합쳐져 없어진 ID의 tombstone, `max_stack` 넘침이 빈 슬롯으로 가는 두 경우, 묶음을 슬롯 번호 순으로 채움, 자리가 없으면 전체 거부와 불변, `condition`·`quality`가 다른 묶음은 합치지 않음, 실패 사유마다 불변, 고정 seed로 300회 주고받으며 정의별 총수량 보존·슬롯·묶음 크기 불변식 / 규칙: 설정과 사유 코드, 일부 건네기와 그 뒤 받은 쪽이 먹기, 사용 효과가 없는 아이템·무기·치료제 건네기(건네받은 파이프가 받은 쪽의 근접 무기가 됨), 건네는 쪽과 아이템 검증(남의 것, 월드의 것, 없는 ID, 플레이어 ID, 수량 0·음수·초과·아주 큰 값, 모르는·오프라인·자는·죽은 건네는 쪽, 엎드린 건네는 쪽), 대상 검증(자기 자신, 없는 ID, 빈 ID, 좀비 ID, 인벤토리 ID, 오프라인, 사거리 경계와 설정, 사망), 캐릭터 없는 접속자, 자는·엎드린 대상과 깨우지 않음, 받는 쪽이 가득 찬 경우와 자리를 비운 뒤, 검사 순서, 거부마다 저장 문서 전체(`to_documents()`)가 그대로이고 트랜잭션·생존 이벤트 0개, 저장 → 재생성 → 로드 뒤 두 인벤토리·ID·tombstone과 이어서 건네기), `tests/integration/hand_over_net_test.gd`(서버 1 + 클라이언트 3, 실제 ENet: A가 B에게 음식 2개 → 서버와 세 미러의 인벤토리 일치, A는 자기 묶음 변화와 결과만, B는 자기 새 묶음과 대상 알림(키 목록 고정), C는 공개 알림만(키 목록 고정, 아이템·수량 단어 없음)이고 인벤토리·소유자 전용 메시지 0개, 치료 알림·생존 이벤트 0개, B가 받은 것을 먹음, 마지막 한 개가 B의 묶음에 합쳐지고 A는 묶음 삭제를 받음 / 묶음 전체·단일 아이템·넘침과 자는 받는 쪽 / 거부 11종과 불변, 알림·인벤토리 메시지 0개, 죽은 건네는 쪽 / 형식이 틀린 요청 17종과 인자를 더 붙인 호출, 형식은 맞지만 거짓인 요청(남의 아이템을 자기나 제3자에게, 다른 종류의 ID, 아주 큰 수량), 클라이언트가 보낸 서버 메시지 / join 전 요청, 빈도 초과와 내려놓기 버킷 공유·소비 버킷과의 분리 / 건네기 직후 저장, 거부는 저장하지 않음, 서버 재시작 → 재접속 뒤 두 미러 / RPC 구성·요청 검증·알림 검증 규칙), `tests/unit/hand_over_presentation_test.gd`(건네기 보조 키의 기본값·액션 등록·설정 검증(다른 모든 키와 달라야 함), 보조 키 조합의 뜻, 요청 수량, HUD 대상 줄, 결과 문장, 알림 문구). 고친 기존 테스트: 프로토콜 버전을 단언하는 통합 테스트 여섯(8 → 9), `tests/integration/inventory_net_test.gd`의 RPC 목록에 새 RPC 셋 추가, `tests/unit/treat_target_test.gd`의 HUD 대상 줄 기대값(건네기 키가 붙음. 설정을 바꿔 보는 경우의 보조 키는 Ctrl 대신 Alt).

### 14.29 아이템을 바닥에 두어 옮기기(P2-T15, docs/00 ADR-021)

사용자 결정(2026-11-16, 원문): "아이템을 단축키 눌러서 건네는 방식보다는 트레이드를 거는 방식이나 아이템을 땅이나 창고에 넣어서 옮기는 방식을 채택하고 지금부터 쭉 작업을 진행하고 마지막에 수치랑 규칙 조정을 하자". 한쪽이 단축키로 상대 인벤토리에 아이템을 넣던 건네기(§14.28)를 없애고, 아이템은 바닥에 내려놓고 줍는 것으로 옮긴다(거래는 §14.30, 보관함은 Phase 3). 이 티켓 뒤로는 어떤 클라이언트 요청도 받는 쪽의 동의 없이 다른 플레이어의 인벤토리에 아이템을 넣지 못한다. 먹여 주기·치료(§14.27)는 그대로다. 임시 가정은 docs/15 §14.6 P2-213~P2-225.

구성: `InventoryService`(`drop_item`의 수량, `try_pickup`의 합치기), `ServerWorld.try_drop_item`(수량 인자), `GameplaySettings.merge_stacks_on_pickup`, `InventoryNetModule`(내려놓기 의도의 수량, 일부 내려놓기와 합쳐진 줍기의 복제, 건네기 RPC 제거), `network_service.gd`(줍기 핸들러 세 줄, 아래 "줍기 복제"), 클라이언트 `InventorySelectionPolicy`(선택 커서와 내려놓을 수량), `WorldItemMarkers`(바닥 아이템 표시), `ClientView`·`ClientPresentationFormatter`·`ClientPresentationSettings`·`ClientInputActions`·`InputIntentMath`(키, HUD, 줍기 후보). 저장 스키마는 바뀌지 않았다.

**프로토콜 변경 있음**: 건네기 RPC 셋이 없어지고 내려놓기 의도에 인자가 하나 늘어 `BuildInfo.PROTOCOL_VERSION`을 10으로 올렸다. 서버→클라이언트 메시지 형식과 join 스냅샷 형식은 그대로다.

#### 데이터

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `GameplaySettings.merge_stacks_on_pickup` | true | 주운 아이템을 들고 있는 같은 종류 묶음에 먼저 합친다. false면 P2-T15 이전처럼 주운 아이템마다 빈 칸 하나를 쓴다 |
| `InventoryNetSettings.drop_intent_rate_per_sec` / `drop_intent_burst` | 4/s / 4 | 내려놓기 의도의 빈도 제한(값은 그대로, 건네기와 함께 쓰던 버킷이 내려놓기 전용이 됐다) |
| `ClientPresentationSettings.select_previous_key` / `select_next_key` | Z / X | 소지품 선택 커서를 앞·뒤 묶음으로(클라이언트 전용, 아무것도 보내지 않는다) |
| `ClientPresentationSettings.drop_key` / `drop_quantity` | Q / 1 | 선택한 묶음에서 한 번에 내려놓는 수량 |
| `ClientPresentationSettings.drop_stack_modifier_key` | Ctrl | 누른 채 내려놓기 키 = 선택한 묶음 전체 |
| `ClientPresentationSettings.drop_min_interval_sec` | 0.25 | 내려놓기 요청 사이의 클라이언트 쪽 최소 간격 |
| `ClientPresentationSettings.pickup_candidate_range_m` | 2.5 | HUD에 표시하고 줍기 키가 고르는 후보의 거리(미러 기준 제안. 서버는 `pickup_range_m`으로 따로 판정) |
| `ClientPresentationSettings.world_item_marker_*`, `world_item_label_*` | 상자 0.25m 등 | 바닥 아이템 임시 표시의 크기·색·라벨 |

아이템 정의는 바뀌지 않았다. 없어진 설정: `GameplaySettings.hand_over_range_m`, `ClientPresentationSettings.hand_over_modifier_key`·`hand_over_quantity`.

#### 서버 트랜잭션(`InventoryService`)

§14.17의 규칙 그대로다: 검사를 전부 마친 뒤에만 반영하고, 실패하면 사유 코드만 있고 아무것도 바뀌지 않으며, 성공하면 `transaction_committed`가 한 번 나온다.

**내려놓기** `drop_item(inventory_id, item_instance_id, cell_id, position, quantity = InventoryService.WHOLE_STACK)`:

| `quantity` | 동작 | 이벤트 |
|---|---|---|
| `WHOLE_STACK`(0, 기본값) 또는 묶음 수량과 같음 | 인스턴스 자체가 그 ID 그대로 월드로 간다(P2-T2와 같다) | `items_dropped`(형식 그대로) |
| 1 ≤ 수량 < 묶음 수량 | 들고 있는 묶음은 수량만 줄고, 내려놓은 수량이 **새 ID의 새 인스턴스**로 월드에 생긴다(`condition`·`quality`는 원래 묶음의 것). 두 묶음이 같은 ID를 갖는 경우는 없다 | `item_units_dropped` = `{event_type, inventory_id, item_instance_id(들고 있는 묶음), definition_id, quantity, remaining_quantity, world_item_instance_id(바닥의 새 인스턴스), cell_id, position: [x, y, z]}` |
| 그 밖(음수, 묶음 수량 초과) | 거부 | `bad_quantity` |

검사 순서: `unknown_inventory` → `unknown_item` → `item_not_in_inventory` → `bad_quantity` → `bad_cell`/`bad_position` → `id_unavailable`(새 ID를 등록할 수 없음. 일어나지 않아야 하는 경우의 방어). 소유 검사가 수량 검사보다 앞이라 남의 묶음에 몇 개가 있는지는 알 수 없다. 새 ID는 상태를 바꾸기 전에 발급·등록한다. 월드 셀(P3-1, §15.1): `ServerWorld.try_drop_item`은 `cell_id`로 놓는 위치의 셀(`cell_id_at`)을 넘기고, 일부를 내려놓아 생긴 새 인스턴스도 묶음 전체와 똑같이 그 셀의 색인(`WorldCellIndex`)과 그 셀의 저장 문서에 들어간다.

**줍기** `try_pickup(inventory_id, item_instance_id, actor_position)`(검사는 그대로: 인벤토리, 아이템, 월드에 있음, 사거리, 자리):

1. `merge_on_pickup`이 켜져 있으면 주운 수량을 들고 있는 **같은 정의·같은 `condition`·같은 `quality`** 묶음에 슬롯 번호가 작은 것부터 `max_stack`까지 채운다(`transfer_item`과 같은 규칙, 같은 계획 함수 `_plan_fills`).
2. 남은 수량이 있으면 **주운 인스턴스 자체가 그 ID 그대로** 첫 빈 슬롯에 남은 수량으로 들어간다.
3. 남은 수량이 있는데 빈 슬롯이 없으면 **전체를 거부**한다(`inventory_full`). 들어가는 만큼만 줍는 일은 없고, 바닥의 아이템은 그대로다. 반대로 전부가 기존 묶음에 합쳐지면 빈 슬롯이 없어도 승인된다.
4. 남은 수량이 0이면 주운 인스턴스는 삭제되고 그 ID는 tombstone 처리된다(재사용 불가).

- 이벤트 `item_picked_up` = `{event_type, item_instance_id(바닥에 있던 아이템), inventory_id, slot_id(그 인스턴스가 들어간 슬롯. **빈 문자열 = 전부 합쳐져 없어짐**), from_cell_id, definition_id, quantity(주운 수량), merged: [{item_instance_id, quantity}](수량이 늘어난 묶음과 늘어난 수량, 채운 순서)}`. 앞의 다섯 키는 Phase 1 그대로이고 뒤의 셋이 추가됐다.
- **보존**: 내려놓기·줍기 어느 경우에도(일부 내려놓기, 합치기, 넘침, 거부) 정의별 총수량은 변하지 않는다. `condition`·`quality`가 다른 묶음끼리는 합치지 않는다. 테스트는 고정 seed로 내려놓기·줍기 300회를 섞어 총수량·ID·슬롯·묶음 크기 불변식을 확인한다.
- 합치기를 줍기에 넣은 이유(P2-T14의 `transfer_item`만 합치던 것과 달라진 점): 아이템이 바닥을 거쳐 옮겨 가게 되면서 한 개씩 내려놓은 것을 한 개씩 주우면 칸이 낱개로 찬다. 합치지 않으면 "한 개 내려놓기"가 받는 쪽의 20칸을 금방 채운다. 그래서 기본값을 켰고, 끌 수 있게 설정으로 뒀다(docs/15 P2-216).

`ServerWorld.try_drop_item(player_id, item_instance_id, quantity = WHOLE_STACK)`: 검사는 그대로(접속 → 행동 가능: `player_dead`·`player_resting` → 트랜잭션)이고 수량만 넘긴다. 엎드린 채로는 내려놓을 수 있고 자는 플레이어는 먼저 일어나야 한다. `ServerWorld` 생성자가 `GameplaySettings.merge_stacks_on_pickup`을 `inventory.merge_on_pickup`에 넣는다.

#### 네트워크 메시지

| 방향 | RPC | 채널/모드 | 받는 쪽 검증 |
|---|---|---|---|
| C→S | `_rpc_request_drop(request_id: int, item_instance_id: String, quantity: int)` | 0 reliable | 아래 "요청 검증" |

그 밖의 RPC(결과, 월드 아이템 추가, 소유자 인벤토리 메시지 둘, 줍기)는 형식이 그대로다. 없어진 RPC: `_rpc_request_hand_over`, `_rpc_hand_over_result`, `_rpc_hand_over_notice`. `InventoryNetModule`의 RPC는 열 개다(테스트가 목록 전체를 고정한다): 내려놓기·소비·남에게 쓰기의 요청과 결과 여섯, 치료 알림, 월드 아이템 추가, 소유자 인벤토리 메시지 둘.

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 바뀌지 않고 `rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드 | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | `request_id`·`quantity`가 int가 아니거나 아이템 ID가 String이 아님 | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `bad_item_id` | 아이템 ID가 비었거나 64자 초과 | 보냄 |
| 5 | `bad_quantity` | `quantity` < 0(0은 "묶음 전체") | 보냄 |
| 6 | `rate_limited` | peer별 토큰 버킷(내려놓기 버킷) | 보냄 |
| 7 | `player_dead` | 요청자가 살아 있지 않음 | 보냄 |
| 8 | 트랜잭션·규칙의 사유(`item_not_in_inventory`, `bad_quantity`(묶음 수량 초과), `player_resting`, `not_online` 등) | `unknown_item`은 `item_not_in_inventory`로 바꿔 알린다 | 보냄 |

위치·소유자·받을 사람을 싣는 인자는 없고, 인자를 더 붙인 호출은 엔진이 거부한다(테스트로 고정). 예전 프로토콜의 건네기 RPC를 보내는 호출도 엔진이 거부한다(테스트로 고정).

**복제와 정보 공개**(ADR-009):

| 서버에서 확정된 사실 | 소유자에게 | 접속 중인 모든 peer에게 |
|---|---|---|
| `items_dropped`(묶음 전체) | `_rpc_inventory_items_removed`(§14.17 그대로) | `_rpc_world_items_added` |
| `item_units_dropped`(묶음의 일부) | `_rpc_inventory_item_changed`(줄어든 묶음) 먼저 | 이어서 `_rpc_world_items_added`(새 아이템: 정의 ID, 수량, 위치) |
| `item_picked_up`, 합쳐진 묶음 있음 | 늘어난 묶음마다 `_rpc_inventory_item_changed`(`InventoryNet`). 이어서 `NetworkService`의 기존 메시지 | `_rpc_world_item_removed`(`NetworkService`, 그대로) |

- **줍기 복제**: 줍기 RPC와 그 복제는 동결된 `network_service.gd` 안에 있다(§14.17). 합쳐져 없어진 인스턴스에는 `_rpc_inventory_item`으로 보낼 것이 없으므로, 핸들러가 "그 아이템이 아직 있을 때만" 보내게 **세 줄을 고쳤다**(동결 이후 두 번째 수정. 메시지 형식·순서·저장 시점은 그대로다). 늘어난 묶음은 `InventoryNet`이 `transaction_committed`를 듣고 그 자리에서 소유자에게 보내므로 `NetworkService`의 메시지보다 먼저 도착한다. 클라이언트 미러에는 합쳐져 없어진 아이템이 들어오지 않는다.
- 바닥의 아이템은 접속 중인 모든 클라이언트가 거리·시야 제한 없이 받는다(정의 ID, 수량, 위치). 누가 내려놓았는지는 없다. 인벤토리 변화는 소유자에게만 간다. 건네기에 있던 "A가 B에게 물건을 건넸다" 알림은 없어졌고, 내려놓기·줍기에는 알림이 없다(바닥에 생기고 없어지는 것이 곧 모두가 보는 사실이다).
- **누구나 줍는다**: 바닥에 놓인 아이템은 받을 사람이 정해져 있지 않다. 사거리 안의 누구든 먼저 요청한 쪽이 줍는다. 받을 사람을 보장하려면 거래(§14.30)를 쓴다.

저장: 내려놓기 의도는 승인되면 결과를 보내기 전에 월드 전체를 저장한다(§14.17 그대로, 한 개씩 내려놓아도 매번). 줍기도 그대로다. 저장 스키마는 바뀌지 않았다: 새 인스턴스는 일반 아이템이고, 합쳐져 없어진 ID는 world_state `tombstones`에, 새 ID의 다음 순번은 `next_entity_sequence`에 들어간다.

클라이언트 표면(`InventoryNetModule`): `request_drop(item_instance_id, quantity = InventoryService.WHOLE_STACK) -> int`, `send_raw_drop_request(request_id, item_instance_id, quantity = WHOLE_STACK)`(테스트 전용), `validate_drop_request(request_id, item_instance_id, quantity = WHOLE_STACK)`. 시그널은 그대로다.

#### 클라이언트 표시(`scripts/presentation/`)

- **선택 커서**(`InventorySelectionPolicy`, 순수 함수): 미러 인벤토리의 묶음을 슬롯 번호 순으로 놓고(미러 자체는 도착 순서다) 커서가 그중 하나를 가리킨다. `step`(앞·뒤, 양끝에서 돈다), `resolve`(미러가 바뀐 뒤: 가리키던 묶음이 남아 있으면 그대로, 없어졌으면 같은 자리의 묶음, 아무것도 없으면 선택 없음), `drop_quantity`(보조 키가 눌렸으면 `WHOLE_STACK`, 아니면 `drop_quantity`와 미러 수량 중 작은 값, 보낼 것이 없으면 `NOTHING_TO_DROP`). 커서는 클라이언트에만 있고 서버에는 "선택" 개념이 없다.
- **입력**: 선택 키(Z/X)는 커서만 옮긴다. 내려놓기 키(Q)는 선택한 묶음의 ID와 수량을 보낸다(Ctrl을 누르고 있으면 묶음 전체). 선택한 것이 없으면 요청 없이 "내려놓을 아이템이 없습니다"를 표시한다. 줍기 키(E)는 HUD에 표시된 후보를 요청하고, 후보가 없으면 요청 없이 "가까이에 주울 것이 없습니다"를 표시한다(이전에는 거리와 무관하게 가장 가까운 아이템을 요청했다). 내려놓기·줍기의 서버 결과를 사용 결과 자리에 문장으로 표시한다.
- **HUD 소지품 목록**(`build_inventory_lines`): 종류별 합계 대신 묶음마다 한 줄이다. 첫 줄 "소지품 (N) | 선택 [Z/X] 내려놓기 [Q] 묶음째 [Ctrl+Q]", 이어서 "> 이름 x수량"(선택된 묶음) 또는 "  이름 x수량". 줄 수(`hud_inventory_line_count`, 6)를 넘으면 커서 주변만 보이고 "... 위 N개"·"... 아래 N개"가 붙는다. 마지막 줄은 줍기 후보 "줍기 [E]: 이름 x수량" 또는 "줍기 [E]: 가까이에 없음".
- **바닥 아이템 표시**(`WorldItemMarkers`): 미러의 월드 아이템마다 임시 상자 하나와 그 위의 라벨(표시 이름 x수량, 카메라를 향한다)을 둔다. 미러가 바뀌면 만들고, 고치고, 없앤다. 거리 제한·가림 처리·겹침 정리는 없다.
- **줍기 후보**(`InputIntentMath.nearest_world_item_id(origin, world_items, max_distance_m)`): 미러에서 본인 위치로부터 `pickup_candidate_range_m` 안의 가장 가까운 아이템. 제안일 뿐이고 서버가 자기 위치로 다시 판정한다.
- **키 겹침 검사**: `ClientPresentationSettings.validate()`가 이 Resource의 키 열한 개가 서로 다른지 검사하고, `keys_shared_with(camera)`가 이동·줍기 키(`CameraSettings`)와 겹치는 설정 이름을 돌려준다(`ClientView`가 시작할 때 오류 로그로 남긴다).

화면 설명은 docs/11 §2.13.

테스트: `tests/unit/ground_transfer_test.gd`(일부 내려놓기의 새 인스턴스·ID·이벤트·보존, 묶음 전체 세 가지 표현, 거부 사유와 불변, 줍기 합치기·넘침·가득 참·`condition`/`quality`·끄기 설정, 고정 seed 300회, A가 한 개씩 내려놓고 B가 주워 한 묶음이 됨, 누가 무엇을 내려놓을 수 있는지, 건네기 규칙·설정이 없음, 저장 → 재생성 → 로드), `tests/unit/item_transfer_test.gd`(`transfer_item` 트랜잭션: P2-T14의 것을 옮겼다), `tests/integration/ground_transfer_net_test.gd`(서버 1 + 클라이언트 3, 실제 ENet: 한 개 내려놓기 → 세 미러의 월드 아이템과 소유자 한정 인벤토리 메시지, 줍기 합치기와 미러, 넘침, 제3자는 인벤토리 메시지 0개 / 조작된 수량 10종·거짓 요청 7종·인자를 더 붙인 호출·자는·죽은 요청자 / 건네기 RPC가 없고 보내도 아무 일도 없음, 먹여 주기와 내려놓기는 남의 인벤토리에 넣지 않음 / 서버 규칙의 `transfer_item` 복제 / 저장·서버 재시작·재접속 / RPC 목록과 요청 검증), `tests/integration/ground_transfer_view_test.gd`(실제 클라이언트 세션의 `ClientView`: 바닥 아이템 표시와 미러 추종, HUD 목록·커서·줍기 후보, 실제 입력 액션으로 선택·내려놓기(한 개/묶음 전체)·줍기), `tests/unit/ground_transfer_presentation_test.gd`(커서 순서·이동·유지, 내려놓을 수량, 키 설정·액션·검증·겹침, HUD 목록과 창, 줍기 후보와 문구, 결과 문장, 표시 노드). 고친 기존 테스트는 docs/15 §14.6에 적었다.

### 14.30 거래 요청(P2-T16, docs/00 ADR-022)

사용자 결정(2026-11-16): 아이템을 넘기는 방법의 하나로 "트레이드를 거는 방식"을 채택한다. 가까이 있는 두 플레이어가 요청 → 수락 → 제안 → 양쪽 확정을 거쳐 아이템을 교환하고, 양쪽이 확정하기 전에는 아무것도 옮겨 가지 않는다. 클라이언트는 의도만 보내고(상대 ID, 세션 ID, 자기 소지품의 묶음 ID와 수량, 자기가 본 제안의 revision), 거리·상태·소유·자리는 모두 서버 상태에서 판정한다. 임시 가정은 docs/15 §14.7 P2-226~P2-245.

구성: `scripts/domain/trade/`(`TradeService`: ServerSystem `trade`, `TradeSession`: 세션 상태, `TradeSettings`: `data/tuning/trade_settings.tres`), `InventoryService.exchange_items`(교환 트랜잭션), `TradeNetModule`(NetModule, 노드 이름 `TradeNet`: 의도 RPC 다섯, 결과, 세션 상태, 완료 알림)와 `TradeNetSettings`(`data/tuning/trade_net_settings.tres`), `ClientTradeState`(클라이언트 미러), `InventoryNetModule`(교환의 소유자 한정 복제 `_replicate_exchanged`, `flush_pending_save`), 클라이언트 `TradeIntentPolicy`·거래 키·HUD 블록·문구. 조립은 `ServerComposition`에서만 한다: `create_world`가 `TradeService`를 마지막 시스템으로 등록하고 `InventoryService.transaction_committed`를 `TradeService.on_inventory_transaction`에 연결하며, `install_net_modules`가 `TradeNetModule`을 마지막 모듈로 넣는다. `CompositionConfig`에 `trade`, `trade_net` 필드가 추가됐다(`validate()`에 포함). **`network_service.gd`는 수정하지 않았다**(§14.5의 공개 헬퍼만 쓴다). 저장 스키마는 바뀌지 않았다.

**프로토콜 변경 있음**: RPC 여덟 개가 새로 생겨 `BuildInfo.PROTOCOL_VERSION`을 11로 올렸다. 기존 RPC와 메시지 형식은 그대로다(join 스냅샷의 `modules.TradeNet` 조각은 빈 객체).

#### 데이터

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `TradeSettings.request_range_m` | 2.5 | 거래를 요청할 수 있는 최대 거리(m). 서버가 가진 두 위치 사이의 3차원 거리, 경계 포함 |
| `TradeSettings.session_range_m` | 4.0 | 대기 중인 요청과 열린 세션이 유지되는 최대 거리. 이보다 멀어지면 취소된다. `request_range_m` 이상이어야 한다(한 걸음 움직였다고 세션이 끊기지 않게 한 여유) |
| `TradeSettings.request_timeout_sec` | 20 | 응답 없는 요청이 취소되는 시간(행동 시간 = 실제 초, §14.16) |
| `TradeSettings.session_idle_timeout_sec` | 120 | 열린 세션에서 승인된 동작(제안 변경, 확정, 확정 취소)이 없으면 취소되는 시간 |
| `TradeSettings.max_offer_entries` | 8 | 한쪽 제안에 올릴 수 있는 묶음 수(프로토콜 상한 `ClientTradeState.MAX_OFFER_ENTRIES` = 32) |
| `TradeSettings.max_pending_events` | 256 | 네트워크 모듈이 가져가기 전까지 쌓아 두는 세션 이벤트 수 |
| `TradeNetSettings.trade_intent_rate_per_sec` / `trade_intent_burst` | 8/s / 8 | 거래 의도 다섯 종류가 함께 쓰는 peer별 토큰 버킷 |
| `ClientPresentationSettings.trade_request_key` 등 | T, Y, N, O, P | 거래 키(클라이언트 전용, 아래 "클라이언트 표시") |

#### 교환 트랜잭션(`InventoryService.exchange_items(first_inventory_id, first_gives, second_inventory_id, second_gives) -> ActionResult`)

두 인벤토리가 서로 아이템을 주는 **하나의** 트랜잭션이다. `first_gives`·`second_gives`는 `[{item_instance_id: String, quantity: int}]`(주는 인벤토리가 들고 있는 묶음과 1..묶음 수량). 한쪽이 빈 배열이면 선물이고, 둘 다 비면 거부한다. §14.17의 규칙 그대로 검사를 전부 마치고 계획을 세운 뒤에만 반영하며, 실패하면 사유 코드만 있고 아무것도 바뀌지 않는다(아이템, ID 순번, tombstone, 시그널 모두).

- **보존**: 한쪽에서 나간 수량이 그대로 다른 쪽에 들어간다. 정의별 총수량은 어떤 경우에도 변하지 않는다.
- **자리 판정은 "나갈 것이 나간 뒤"**: 묶음 전체를 내주면 그 칸이 비고, 들어오는 묶음이 그 칸을 쓸 수 있다. 그래서 칸이 꽉 찬 두 인벤토리도 묶음 전체끼리는 맞바꿀 수 있다. 한쪽이라도 들어올 것을 다 받지 못하면 교환 전체를 거부한다(`first_inventory_full` / `second_inventory_full`: 어느 쪽인지가 사유에 있다).
- **들어오는 수량이 가는 자리**(`transfer_item`·`try_pickup`과 같은 규칙): 받는 쪽의 같은 정의·같은 `condition`·같은 `quality` 묶음을 슬롯 번호 순으로 `max_stack`까지 채운다(자기가 일부를 내준 묶음의 남은 부분, 이 교환에서 먼저 들어온 묶음도 포함). 남은 수량은 가장 낮은 빈 칸에 한 묶음으로 들어간다.
- **아이템 인스턴스 ID**(제안에 올린 묶음마다):

| 경우 | 받는 쪽에 생기는 것 | 주는 쪽 인스턴스 |
|---|---|---|
| 전부 기존 묶음에 합쳐짐, 주는 쪽에 남는 수량 있음 | 새 인스턴스 없음 | 수량만 줄어듦 |
| 전부 합쳐짐, 묶음 전체를 내줌 | 새 인스턴스 없음 | 삭제되고 ID는 tombstone 처리 |
| 남은 수량이 빈 칸으로, 묶음 전체를 내줌 | 주는 쪽 인스턴스가 그 ID 그대로 옮겨 감 | 받는 쪽 것이 됨 |
| 남은 수량이 빈 칸으로, 주는 쪽에 남는 수량 있음 | 새 ID의 새 인스턴스(`condition`·`quality`는 원래 묶음의 것) | 수량만 줄어듦 |

  새 ID는 상태를 바꾸기 전에 모두 발급·등록한다. 두 묶음이 같은 ID를 갖는 경우는 없다.
- 실패 사유(검사 순서): `unknown_inventory` → `same_inventory` → 제안 항목마다(첫 제안, 이어서 둘째 제안) `bad_offer`(항목 형식) → `unknown_item` → `item_not_in_inventory` → `bad_quantity` → `duplicate_item`(한 제안에 같은 묶음이 두 번) → `nothing_to_exchange` → `first_inventory_full` / `second_inventory_full` → `id_unavailable`. 소유 검사가 수량 검사보다 앞이다.
- 성공 이벤트(JSON-safe, `transaction_committed`로 **한 번**) `items_exchanged` = `{event_type, sides: [첫째, 둘째]}`, 각 side = `{inventory_id, gave: [{item_instance_id, definition_id, quantity}], removed_item_instance_ids: [그 인벤토리에 있다가 없어진 ID], changed_item_instance_ids: [지금 그 인벤토리에 있고 전에 없었거나 수량이 달라진 ID, 슬롯 순서]}`.

#### 거래 규칙(`TradeService`, system id `trade`)

세션(`TradeSession`): `session_id`(서버 실행 중 1부터 증가, 재사용하지 않음), `requester_id`·`target_id`, `phase`(`requested` → `open` → `closed`), `revision`(어느 쪽이든 제안이 바뀔 때마다 +1), 양쪽 `offers`(`[{item_instance_id, definition_id, quantity}]`)와 `confirmed`, 끝났을 때 `outcome`(`completed` / `cancelled`)·`cause`·`by_player_id`. 저장하지 않는다.

공개 API(모두 `ActionResult`, 성공 `event`는 세션 사전 `TradeSession.to_dict()`):

| 메서드 | 동작 |
|---|---|
| `request_trade(world, requester_id, target_id)` | 요청을 만든다(아래 "요청 검사") |
| `accept(world, player_id, session_id)` | 요청받은 쪽이 수락해 세션을 연다. 실패 `no_such_request`(그 ID의 대기 중인 요청이 자기에게 온 것이 아님. 요청한 쪽·제3자·이미 열린 세션 포함) |
| `cancel(world, player_id, session_id)` | 당사자가 물러난다: 요청받은 쪽이면 거절(`declined`), 요청한 쪽이면 철회(`withdrawn`), 열린 세션이면 취소(`cancelled`). 당사자의 상태와 무관하게 항상 된다. 실패 `not_in_session` |
| `set_offer(world, player_id, session_id, item_instance_id, quantity)` | 자기 제안에 묶음을 올리거나 수량을 바꾸거나(1..묶음 수량) 뺀다(0). 누구의 제안인지는 인자가 아니다: 항상 호출한 쪽의 것이다 |
| `set_confirmed(world, player_id, session_id, revision, wanted)` | 지금 제안(`revision`)을 확정하거나 확정을 푼다. 양쪽이 확정되면 그 자리에서 교환한다 |
| `session_of(player_id)`, `session_count()`, `drain_events()` | 조회와 네트워크 읽기 표면 |

요청 검사(순서대로, 먼저 걸린 것 하나. 거부되면 아무것도 바뀌지 않는다):

| 순서 | 사유 코드 | 조건 |
|---|---|---|
| 1 | `not_online` | 요청하는 쪽이 월드에 없음(모르는 플레이어, 오프라인, 캐릭터 없는 접속자) |
| 2 | `player_dead`, `player_resting` | 요청하는 쪽이 행동할 수 없음 |
| 3 | `already_trading` | 요청하는 쪽이 이미 요청·세션에 있음. 단 **자기에게 요청한 상대에게 요청하면 그 요청의 수락으로 처리한다** |
| 4 | `target_is_self` | 자기 자신 |
| 5 | `target_unavailable` | 대상이 월드에 없음(모르는 ID, 플레이어가 아닌 ID, 오프라인, 캐릭터 없는 접속자: 한 사유) |
| 6 | `target_dead` | 대상이 죽음 |
| 7 | `target_too_far` | 서버 위치 기준 거리 > `request_range_m` |
| 8 | `target_resting` | 대상이 자는 중(행동할 수 없음). 자는 플레이어는 응답할 수 없으므로 요청받지 않는다 |
| 9 | `target_busy` | 대상이 다른 요청·세션에 있음 |

순서의 뜻: 누가 자는지·거래 중인지는 사거리 안에서만 알 수 있다(7이 8·9보다 앞). 엎드린 플레이어는 요청할 수도 받을 수도 있다.

제안 검사(`set_offer`): 당사자인지(`not_in_session`) → 세션이 열렸는지(`session_not_open`) → 양쪽 상태(아래 "취소", 걸리면 세션을 취소하고 `session_cancelled`) → 수량 0이면 자기 제안에 그 묶음이 있는지(`not_in_offer`) / 아니면 아이템 존재(`unknown_item`) → 자기가 들고 있는지(`item_not_in_inventory`) → 1 ≤ 수량 ≤ 묶음(`bad_quantity`) → 바뀌는 것이 있는지(`offer_unchanged`) → 새 묶음이면 `max_offer_entries` 이내인지(`offer_full`). 승인되면 `revision` +1, **양쪽 확정 해제**. 상대의 묶음 ID를 넣어 "빼기"를 보내도 `not_in_offer`일 뿐 상대의 제안은 바뀌지 않는다.

확정 검사(`set_confirmed`, `wanted` = true): 당사자·열린 세션·양쪽 상태 → `revision`이 세션의 것과 같은지(`stale_offer`: 자기가 보지 못한 제안은 확정되지 않는다) → 이미 확정했는지(`already_confirmed`) → 양쪽 제안이 모두 비었는지(`nothing_offered`) → 올린 묶음이 아직 다 있는지(없으면 제안을 고치고 `offer_changed`). 확정을 푸는 쪽(`wanted` = false)은 `not_confirmed`만 본다. 상대의 확정을 대신 하는 인자는 없다.

교환: 양쪽이 확정된 그 호출 안에서 `exchange_items`를 한 번 부른다(요청한 쪽이 첫째 인벤토리).

| 결과 | 세션 | 호출한 쪽이 받는 것 |
|---|---|---|
| 성공 | `closed`, `outcome` = `completed` | 성공(닫힌 세션) |
| 한쪽이 받을 자리가 없음 | **열린 채로 남는다.** 양쪽 확정 해제, `revision` 그대로. 이벤트 `exchange_failed`(`cause` = `inventory_full`, `by_player_id` = 자리가 없는 쪽) | `inventory_full`(자기 쪽) 또는 `other_inventory_full`(상대 쪽) |

**제안은 인벤토리를 따라간다**: 제안에 올려도 아이템은 잠기지 않는다(먹거나 내려놓을 수 있다). 인벤토리 트랜잭션이 확정될 때마다(`on_inventory_transaction`) 열린 세션의 제안을 다시 맞춘다: 올린 묶음이 인벤토리를 떠났으면 제안에서 빼고, 수량이 줄었으면 제안 수량을 낮추고, 그때 `revision` +1·양쪽 확정 해제·이벤트 `offer_adjusted`. 묶음이 늘기만 한 경우는 건드리지 않는다.

**취소**(아무것도 옮기지 않고, 양쪽에 `cause`와 `by_player_id`를 알린다). 상태 검사는 매 서버 틱(`step`)과 모든 의도 처리 직전에 한다:

| `cause` | 조건 | `by_player_id` |
|---|---|---|
| `declined` / `withdrawn` / `cancelled` | 당사자의 `cancel`(요청받은 쪽 / 요청한 쪽 / 열린 세션) | 그 플레이어 |
| `too_far` | 두 위치 사이 거리 > `session_range_m` | "" |
| `player_dead` | 한쪽이 죽음(`ServerWorld.is_player_dead`) | 죽은 쪽 |
| `player_resting` | 한쪽이 자는 중(행동 차단 사유 코드 그대로: 다른 차단 사유가 생기면 그 코드가 `cause`가 된다) | 그 플레이어 |
| `disconnected` | 한쪽이 월드를 떠남(`on_player_offline` 훅에서 즉시, 틱을 기다리지 않는다) | 떠난 쪽 |
| `new_character` | 한쪽의 새 캐릭터가 시작됨(`on_character_started` 훅) | 그 플레이어 |
| `request_timeout` | 요청 후 `request_timeout_sec`가 지남 | "" |
| `idle_timeout` | 마지막 승인된 동작 후 `session_idle_timeout_sec`가 지남(거부된 요청은 시간을 되돌리지 않는다) | "" |

죽은 캐릭터의 소지품은 기존 규칙대로 죽은 자리에 떨어진다(ADR-012). 상대에게 넘어가지 않는다.

이벤트(`drain_events`, JSON-safe): `{event_type: "trade_session_changed", change, session, world_time}`. `change`는 `requested`, `opened`, `offer_changed`, `offer_adjusted`, `confirmed`, `unconfirmed`, `exchange_failed`, `closed` 중 하나다. 완료를 일으킨 확정은 `confirmed` 없이 `closed` 하나만 낸다.

#### 네트워크 메시지(`TradeNetModule`, 모두 채널 0 reliable)

| 방향 | RPC | 받는 쪽 검증 |
|---|---|---|
| C→S | `_rpc_request_trade(request_id: int, target_player_id: String)` | 아래 "요청 검증" |
| C→S | `_rpc_request_trade_accept(request_id: int, session_id: int)` | 〃 |
| C→S | `_rpc_request_trade_cancel(request_id: int, session_id: int)` | 〃 |
| C→S | `_rpc_request_trade_offer(request_id: int, session_id: int, item_instance_id: String, quantity: int)` | 〃 |
| C→S | `_rpc_request_trade_confirm(request_id: int, session_id: int, revision: int, confirmed: bool)` | 〃 |
| S→요청자 | `_rpc_trade_result(request_id: int, ok: bool, reason: String)` | 서버 발신만 수용, 타입, `request_id` ≥ 0, `reason` 길이 ≤ 64, `ok`일 때만 `reason`이 빈 문자열 |
| S→당사자 | `_rpc_trade_state(state: Dictionary)` | 서버 발신만 수용, `ClientTradeState.is_valid_state`(정확한 키, 받는 쪽이 두 당사자 중 하나) |
| S→제3자 | `_rpc_trade_notice(notice: Dictionary)` | 서버 발신만 수용, `ClientTradeState.is_valid_notice`(정확한 키, 받는 쪽이 당사자가 아님) |

의도에는 세션 ID가 실린다: 끝난 세션을 향해 늦게 도착한 의도가 그 플레이어의 다음 세션에 적용되지 않게 하기 위해서다. 행위자는 항상 보낸 peer의 플레이어이고, "누구의 제안·확정인지"나 위치·거리·인벤토리 내용을 싣는 인자는 없다. 인자를 더 붙인 호출은 엔진이 거부한다(테스트로 고정).

요청 검증(순서대로, 먼저 걸린 것 하나. 거부되면 서버 상태는 바뀌지 않고 `rejected_intent_count(reason)`이 1 오른다):

| 순서 | 사유 코드 | 조건 | 요청자에게 결과 전송 |
|---|---|---|---|
| 1 | `not_joined` | join 핸드셰이크를 마치지 않은 peer | 보내지 않음 |
| 2 | `bad_type` | 인자 타입이 틀림(`request_id`·`session_id`·`quantity`·`revision`은 int, ID는 String, `confirmed`는 bool) | `request_id`가 0 이상 int일 때만 |
| 3 | `bad_sequence` | `request_id` < 0 | 보내지 않음 |
| 4 | `bad_target_id` / `bad_session_id` / `bad_item_id` / `bad_quantity` / `bad_revision` | 대상 ID가 비었거나 64자 초과 / `session_id` < 1 / 아이템 ID가 비었거나 64자 초과 / `quantity` < 0 / `revision` < 0 | 보냄 |
| 5 | `rate_limited` | peer별 토큰 버킷(다섯 의도 공용) | 보냄 |
| 6 | 규칙의 사유(위 표들) | `unknown_item`은 `item_not_in_inventory`로 바꿔 알린다 | 보냄 |

1~5는 `reject_intent`(횟수 + 경고 로그), 6은 정상 플레이에서 생길 수 있어 `count_rejection`(횟수만)이다.

**복제와 정보 공개**(ADR-009, ADR-022). 누가 무엇을 받는가:

| 받는 쪽 | 받는 것 | 받지 않는 것 |
|---|---|---|
| 두 당사자 | 세션이 바뀔 때마다 **자기 쪽에서 본** 세션 상태: `{session_id, phase, requester_id, target_id, revision, my_offer: [{item_instance_id, definition_id, quantity}], their_offer: [{definition_id, quantity}], my_confirmed, their_confirmed, change, outcome, cause, by_player_id, world_time}`. 교환이 일어나면 그보다 먼저 자기 인벤토리 변화(`InventoryNet`의 소유자 전용 메시지: 빠진 ID, 이어서 들어오거나 달라진 묶음) | 상대 묶음의 인스턴스 ID·슬롯, 상대 인벤토리의 다른 내용. 단 `other_inventory_full`은 "상대가 이것을 받을 자리가 없다"를 알려 준다 |
| 제3자(다른 접속자 전부) | 거래가 **완료됐을 때에만** 알림 `{player_ids: [a, b](ID 순), world_time}` | 요청·수락·거절·제안·확정·취소와 그 사유, 무엇을 얼마나 교환했는지, 누가 요청했는지. 세션 상태 메시지는 한 번도 가지 않는다 |

- 서버는 보내기 전에 자기 메시지를 클라이언트와 같은 검증에 통과시킨다(당사자가 아닌 플레이어용 상태는 검증에서 걸려 전송되지 않는다).
- 순서: 한 의도가 일으킨 변화는 (교환이면 인벤토리 메시지 →) 저장 → 세션 상태 → 알림 → 결과 순으로 나간다. 같은 채널이라 요청자는 결과보다 새 상태를 먼저 받는다. 시스템이 스스로 일으킨 변화(시간 초과, 사망, 수면, 거리)는 그 서버 틱의 끝(`server_physics`)에, 접속 종료로 인한 취소는 `on_player_left`에서 바로 나간다.
- 알림과 상태에 거리·시야 제한은 없다.
- 늦게 접속한 클라이언트: 세션은 접속 종료로 취소되므로 다시 접속한 플레이어에게는 세션이 없다(join 조각 없음, 미러 초기화).

저장: 완료된 거래는 세션 상태와 결과를 보내기 전에 월드 전체를 **한 번** 저장한다(줍기·내려놓기와 같은 "주요 트랜잭션"). `InventoryNet`이 교환 트랜잭션으로 세운 "저장 대기"를 `TradeNet`이 `InventoryNetModule.flush_pending_save`로 그 자리에서 내보내므로 틱 끝에 다시 저장하지 않는다. 요청·제안·확정·취소는 저장하지 않는다. 세션은 서버 재시작 뒤에 남지 않는다.

클라이언트 표면(`network.get_module(TradeNetModule.MODULE_NAME) as TradeNetModule`): `request_trade(target_player_id)`, `request_accept(session_id)`, `request_cancel(session_id)`, `request_offer(session_id, item_instance_id, quantity)`, `request_confirm(session_id, revision, confirmed)`(모두 요청 번호를 돌려주고 join 전이면 `NO_REQUEST`. 클라이언트에서 미리 판단하지 않는다), `signal trade_result(request_id, ok, reason)`, `send_raw_*`(테스트 전용), 순수 함수 `validate_trade_request`·`validate_session_request`·`validate_offer_request`·`validate_confirm_request`·`party_state`·`public_notice`. 미러 `client_state`(`ClientTradeState`): `has_session()`, `session()`, `phase()`, `session_id()`, `partner_id()`, `is_requester()`, `revision()`, `my_offer()`, `their_offer()`, `my_confirmed()`, `their_confirmed()`, `last_closed()`, `recent_notices()`(최근 16개), 시그널 `changed`·`session_closed(state)`·`notice_received(notice)`. 미러에는 권한이 없다.

#### 클라이언트 표시(`scripts/presentation/`)

- **키와 뜻**(`TradeIntentPolicy`, 순수 함수): 요청 키(T)는 세션이 없을 때만 "바라보는 상대"(§14.27의 대상 후보 `TreatTargetPolicy`)에게 요청한다. 수락 키(Y)는 상태에 따라 뜻이 다르다: 자기에게 온 요청이면 수락, 열린 세션이면 확정(미러가 보여 주는 `revision`을 실어 보낸다), 이미 확정했으면 확정 취소. 자기가 건 요청에는 아무 일도 하지 않는다. 거절 키(N)는 거절·철회·취소다(서버 의도는 `cancel` 하나). 올리기·내리기 키(O/P)는 **선택 커서(§14.29)가 가리키는 묶음**의 제안 수량을 `trade_offer_step`(1)만큼 늘리거나 줄인다: 미러의 자기 제안 수량에 더하고 0..미러 묶음 수량으로 자른 값을 보내며(`offer_quantity_after`), 바뀌는 것이 없으면 보내지 않는다.
- **HUD 거래 블록**(`build_trade_lines`, 소지품 목록 아래): 세션이 없으면 "거래 요청 [T]: 이름" 또는 "거래 요청 [T]: 상대 없음 (가까이서 바라보기)", 요청 대기 중이면 "거래 요청 중: 이름 | 취소 [N]" 또는 "이름의 거래 요청 | 수락 [Y] 거절 [N]", 열린 세션이면 네 줄("거래 중: 이름", "내 제안 (확정/미확정): …", "상대 제안 (확정/미확정): …", 키 안내).
- **문구**: 거부된 요청은 사용 결과 자리에 문장으로(`format_trade_result`, 승인은 HUD 블록이 바뀌는 것으로 충분해 문구가 없다), 세션이 끝나면 "거래 완료: 이름" 또는 취소 사유 문장(`format_trade_closed`), 자기가 요청하지 않은 세션 안의 변화(교환 실패, 서버가 제안을 고침)는 안내 문장(`format_trade_change`), 다른 두 플레이어의 거래는 이벤트 로그 한 줄 "이름 ↔ 이름 거래"(`format_trade_notice`).
- 키 다섯 개는 `ClientPresentationSettings`에 있고, 설정 검증이 이 Resource의 키 열여섯 개가 서로 다른지, `keys_shared_with`가 이동·줍기 키와 겹치는지 본다(§14.29).

화면 설명은 docs/11 §2.14.

테스트: `tests/unit/item_exchange_test.gd`(묶음 전체 맞바꾸기와 ID 유지·이벤트, 일부 교환의 새 인스턴스와 보존, 합치기와 합쳐져 없어진 ID, 선물과 빈 제안, 꽉 찬 인벤토리끼리의 맞바꾸기, 한쪽이 못 받으면 전무(네 경우)와 불변, 잘못된 제안 사유와 불변, `condition`/`quality`, 고정 seed 300회 교환의 보존·ID·슬롯 불변식, 스냅샷 왕복), `tests/unit/trade_service_test.gd`(설정·조립·저장 문서 없음, 전체 흐름과 한 트랜잭션, 선물, 제안 변경이 양쪽 확정을 푸는 것과 낡은 확정 거부, 누가 누구에게 요청할 수 있는지와 검사 순서·서로 요청, 캐릭터 없는 접속자, 거절·철회·요청 시간 초과(주입된 시계), 세션 취소 사유 일곱 가지와 불변, 의도 직전의 상태 검사, 남의 묶음·수량 초과·상대 제안 건드리기·제3자의 의도·다른 세션 ID·제안 묶음 수 상한, 제안이 인벤토리를 따라감, 자리가 없을 때 세션 유지, 저장 → 재생성 → 로드), `tests/integration/trade_net_test.gd`(서버 1 + 클라이언트 3, 실제 ENet: 전체 흐름에서 두 당사자의 미러와 제3자가 받은 것(상태 0개, 알림 1개의 키 목록, 인벤토리 메시지 0개), 선물 / 거절·철회·시간 초과와 대기 중의 `target_busy` / 거리·수면·무동작·접속 종료·사망으로 인한 취소 / 형식이 틀린 요청 24종·인자를 더 붙인 호출·거짓 요청(남의 묶음, 수량 초과, 상대 제안 빼기, 낡은 revision, 다른 세션 ID, 자기 자신, 제3자의 의도)·클라이언트가 보낸 서버 메시지·끝난 세션에 대한 의도 / join 전 요청과 빈도 초과 / 완료 직후 저장 한 번, 서버 재시작 → 재접속 / RPC 구성·요청 검증·상태와 알림 검증 규칙), `tests/integration/trade_view_test.gd`(실제 클라이언트 세션의 `ClientView`: 실제 입력 액션으로 요청·올리기·내리기·확정·확정 취소·거절·수락·취소, HUD 블록과 결과 문구, 제3자의 이벤트 로그 한 줄), `tests/unit/trade_presentation_test.gd`(키 설정·액션·검증·겹침, 키의 뜻, 올릴 수량, HUD 블록, 결과·종료·변화 문구, 제3자 문구). 고친 기존 테스트: 프로토콜 버전을 단언하는 통합 테스트 일곱(10 → 11).

## 15. Phase 3 구현 현황

Phase 3(docs/13 §5, §15) 티켓의 계약을 티켓마다 한 절씩 적는다. 결정 기록은 docs/00, 임시 수치와 확인하지 못한 것은 docs/15 §15.

### 15.1 월드 셀 격자와 셀 생명주기(P3-1, docs/00 ADR-023, system id `world_cells`)

서버 쪽 기반이다. 클라이언트별 복제 범위(P3-2), 건물·보관함(P3-3), 구조물(P3-4~)은 이 절의 seam을 쓴다. `PROTOCOL_VERSION`은 바꾸지 않았다(새 RPC·새 메시지 형식이 없다).

**순수 도메인(`scripts/domain/world_cells/`, 노드 없음)**

| 구성 요소 | 계약 |
|---|---|
| `WorldCellSettings` (`data/tuning/world_cell_settings.tres`) | `cell_size_m`(50), `bounds_min_m`·`bounds_max_m`(x·z, ±250 = 500m × 500m), `active_radius_cells`(2), `preload_radius_cells`(3, 활성 반경보다 커야 한다), `preload_lookahead_sec`(4), `deactivate_delay_sec`(5), `unload_delay_sec`(20), `refresh_period_sec`(0.25), `max_preload_loads_per_refresh`(4), `retry_delay_sec`(5). `validate()`, `validate_play_area(world_half_extent_m)`(플레이 영역이 경계 안에 있어야 한다. `CompositionConfig.validate`가 부른다). 시간은 모두 행동 시간(실제 초) |
| `WorldCellGrid` | `cell_of(position) -> Vector2i`(높이 무시, 음수는 내림, 경계 위·밖은 가장자리 셀, 유한하지 않은 좌표는 0으로 본다), `cell_id_at(position)`, `id_of(cell)`/`parse_id(id)`(`cell_<cx>_<cz>`, 정확히 그 형식만), `is_valid_cell_id`, `contains_cell`, `contains_position`, `cell_min_corner`/`cell_center`, `cells_within(center, radius)`(체비쇼프 거리의 정사각형, 맵 안만, x·z 순), `ring`, `neighbours`, `distance`, `cell_count`, `min_cell`/`max_cell`, `signature()`(셀 크기와 경계: 저장이 어떤 격자로 나뉘었는지) |
| `WorldCellLifecycle` | 상태 `UNLOADED, LOADING, PRELOADED, ACTIVE, SAVING, UNLOADING`. 허용 전이: `UNLOADED→LOADING`, `LOADING→PRELOADED`(성공)·`UNLOADED`(실패), `PRELOADED⇄ACTIVE`, `PRELOADED→SAVING`, `SAVING→UNLOADING`(성공)·`PRELOADED`(실패), `UNLOADING→UNLOADED`. `can_transition`, `is_loaded`(PRELOADED·ACTIVE·SAVING), `is_simulated`(ACTIVE만) |
| `WorldCellIndex` | 메모리에 있는 월드 엔티티가 어느 셀에 있는지. `put(entity_id, kind, cell_id) -> 이전 셀`(이동 포함), `remove`, `remove_kind`, `cell_of`, `kind_of`, `entities_in_cell(cell_id, kind = "")`(정렬), `count_in_cell`, `occupied_cell_ids`. 종류는 지금 `item`(월드 아이템)과 `zombie` |
| `WorldCellDocument` | 셀 저장 문서의 틀: `{schema_version: 1, cell_id, world_items, systems}`. `create`, `is_empty`, `validate` |

**`ServerWorld`가 가진 것과 시스템이 묻는 창구**: `cell_grid`, `cell_index`(월드마다 하나), `cell_id_at(position)`, `cell_coords_at(position)`·`cell_id_of(cell)`(매 틱 경계 통과를 확인하는 쪽이 문자열을 만들지 않게), `is_cell_simulated(cell_id)`·`is_simulated_at(position)`(ACTIVE인가), `is_cell_loaded(cell_id)`(메모리에 있는가), `saves_cell_document(cell_id)`(지금 저장하면 그 셀의 엔티티가 셀 문서로 가는가), `cell_document(cell_id)`, `restore_cell_document(cell_id, document)`, `release_cell(cell_id)`, `notify_cell_active(cell_id, active)`, `repartition_from(cell_documents)`. 시스템은 셀 계산을 직접 하지 않고 이 함수들만 쓴다. 셀 서비스가 없는 월드(직접 만든 `ServerWorld`)는 모든 셀이 시뮬레이션되고 메모리에 있는 것으로 답하므로 P3-1 전과 같이 동작한다.

**`ServerSystem` 훅 다섯(기본은 아무것도 하지 않음)**: `on_cell_activated(world, cell_id)`, `on_cell_deactivated(world, cell_id)`, `to_cell_document(cell_id) -> Dictionary`(없으면 `{}`, `schema_version` 포함), `restore_cell_document(world, cell_id, document) -> 오류`(먼저 전부 검증하고 오류가 있으면 아무것도 바꾸지 않는다), `release_cell(world, cell_id)`(ID는 `EntityRegistry.release`로 내려놓는다: tombstone 아님). 셀에 엔티티를 두는 시스템은 `cell_index`를 갱신하고 이 다섯을 구현한다. 지금 구현한 것은 `ZombieService`이고 월드 아이템은 `InventoryService`의 `cell_snapshot`/`restore_cell_snapshot`/`release_cell`/`world_item_ids_in_cell`/`reassign_world_item_cells`를 `ServerWorld`가 같은 자리에서 부른다. `EntityRegistry.release(id)`가 새로 생겼다.

**`WorldCellService`(`scripts/services/world/world_cell_service.gd`)**: `ServerComposition`이 **가장 먼저** 등록한다(같은 틱의 다른 시스템이 이번 틱의 셀 상태를 보고, 플레이어가 월드에 들어올 때 다른 시스템보다 먼저 셀을 로딩한다).

- 입력은 `ServerWorld.online_player_ids()`와 그 플레이어들의 서버 위치뿐이다. 클라이언트가 보낸 값은 쓰지 않는다. 접속만 하고 캐릭터가 없는 플레이어, 오프라인 플레이어는 셀을 깨우지 않는다.
- 살펴보기(`refresh`): `refresh_period_sec`마다, 그리고 플레이어가 월드에 들어오거나 새 캐릭터를 시작할 때 즉시. 플레이어 셀에서 활성 반경 안은 ACTIVE, 사전 로딩 반경 안과 미리보기 위치 주변은 메모리에 둔다. 플레이어에게 지금 필요한 셀(활성 영역과 그 바깥 한 줄)은 그 자리에서 로딩하고, 그 밖의 원하는 셀(더 바깥 줄, 미리보기 위치 주변)은 한 번에 `max_preload_loads_per_refresh`개씩 가까운 것부터 로딩한다. 기본값(활성 2, 사전 로딩 3)에서는 필요한 셀이 사전 로딩 영역 전체다.
- 히스테리시스: 원하지 않게 된 ACTIVE 셀은 `deactivate_delay_sec` 뒤에 PRELOADED가 되고, 원하지 않게 된 PRELOADED 셀은 `unload_delay_sec` 뒤에 해제된다. 그 사이에 다시 원하게 되면 기다림은 취소된다. ACTIVE 셀과 맞닿은 셀은 해제하지 않는다.
- 해제는 `WorldCellStore.save_cells`가 성공한 뒤에만 한다(SAVING → UNLOADING). 실패하면 PRELOADED로 돌아가고 `retry_delay_sec` 뒤에 다시 시도한다. 저장소가 없으면 해제하지 않는다. 엔티티도 저장 문서도 없는 셀만 내릴 때는 저장소를 부르지 않는다.
- 로딩 실패: 그 셀은 UNLOADED로 남고(활성화되지 않는다) 셀 ID와 사유를 오류 로그에 남기며 `retry_delay_sec` 뒤에 다시 시도한다. 다른 셀과 플레이어는 영향을 받지 않는다.
- 떠돌이: 로딩되지 않은 셀에 메모리 엔티티가 있으면(P3-1 전 저장, 새 월드의 시드, 플레이어에게서 먼 스폰) 다음 살펴보기와 모든 저장 직전에 그 셀을 로딩해(저장돼 있던 내용과 합쳐서) 정상 상태로 만든다.
- 월드 시계가 멈춰 있으면(접속자 0명) 아무 셀도 바뀌지 않는다.
- 시그널: `cell_state_changed(cell_id, from, to)`, `cell_loaded(cell_id)`, `cell_unloading(cell_id)`(저장은 끝났고 엔티티는 아직 읽을 수 있다), `cell_unloaded(cell_id)`. 조회: `state_of`, `is_loaded`, `is_simulated`, `loaded_cell_ids`, `active_cell_ids`. 도구·테스트: `load_all_saved_cells(world)`. 진단: `load_count`, `unload_count`, `failed_load_count`, `failed_save_count`, `refresh_count`.

**`WorldCellStore`(해제한 셀을 두는 곳)**: `load_cell(cell_id) -> {error, document}`(문서가 비어 있으면 "저장된 것이 없는 셀"), `save_cells(world, cell_ids) -> Error`, `saved_cell_ids()`, `document_of`, `saves_loaded_cells()`. 기본 클래스는 메모리에 문서를 두는 구현(테스트·도구용, JSON 왕복 후 보관)이고, 전용 서버는 `SaveWorldCellStore`(`scripts/services/save/`)를 쓴다. `WorldPersistence.load_or_create`가 붙인다. `ServerComposition.create_world`만으로 만든 월드에는 저장소가 없어 셀을 해제하지 않는다(시뮬레이션 정지만 한다).

**시뮬레이션 정지(좀비)**: `ZombieService`는 ACTIVE 셀의 좀비만 "깨어 있는" 목록에 두고, 틱마다 그 목록만 이동·AI 판단(시야·청각·공격)·시체 제거를 처리한다(`simulated_count()`). 다른 셀의 좀비는 상태·타이머·RNG까지 그대로 멈춘다.

- 활성 셀에서 사전 로딩 셀로 걸어 들어간 좀비는 경계를 넘은 틱에 색인이 새 셀로 바뀌고 멈춘다. 그 셀이 활성화되면 하던 일을 이어 간다. 메모리에 없는 셀로는 들어가지 못한다(그 걸음을 되돌린다, `blocked_move_count`).
- 소음은 깨어 있는 좀비만 듣는다. 깨어나는 좀비는 그 전에 난 소음을 듣지 못한다(아직 남아 있는 소음이어도). 즉 비활성 셀까지 닿은 소음은 거기서 버려진다. 기본 수치에서는 가장 큰 소음이 들리는 거리(99m)가 항상 시뮬레이션되는 거리(100m)보다 짧다.
- 멈춘 좀비도 서버 규칙으로 피해를 받을 수 있고, 깨어날 때 공격자를 알아챈다.
- 지나간 시각(행동 시각 기준의 탐색 종료, 시체 제거 시각)은 깨어난 뒤 첫 처리에서 한꺼번에 적용된다.
- 플레이어는 셀과 함께 내려가지 않는다. 플레이어 이동의 맵 경계 제한은 예전부터 있던 `GameplaySettings.world_half_extent_m` clamp 그대로다(새 코드 없음).

**저장 배치**(docs/10 §3·§4·§6): `cells/<cell_id>.json`(WorldCellDocument, docs/14 §3), world_state.json 스키마 4, world_state `systems.world_cells = {schema_version: 1, grid: WorldCellGrid.signature()}`.

- 엔티티는 셀 문서와 월드 문서 중 한 곳에만 있다. 저장된 월드(`SaveWorldCellStore`)에서는 메모리에 있는 셀의 엔티티가 전부 그 셀 문서로 가고, world_state에는 로딩되지 못한 셀의 떠돌이만 남는다(보통 없음). 메모리 저장소·저장소 없음에서는 메모리에 있는 엔티티가 world_state에 남는다(P3-1 전과 같은 모양). `ServerWorld.to_documents()`는 `{world_state, players, cells, replace_cells}`를 돌려주고 `restore_documents(world_state, players, cells = {})`의 `cells`는 메모리 저장소로 만든 문서에만 쓴다.
- `SaveService.save_world(world_id, world_state, players, cells = {}, replace_cells = false)`, `load_cell(world_id, cell_id) -> {error, document, warnings}`, `saved_cell_ids(world_id)`, `load_world`의 결과에 `cell_ids`. 엔티티가 없는 셀 문서는 파일을 만들지 않고 있던 파일을 없앤다.
- 셀 해제 = `WorldPersistence.save(world)` = 한 세대 전체 저장. 서버 시작은 셀을 하나도 메모리에 올리지 않는다.
- 셀을 로딩할 때 저장본보다 메모리가 우선이다: 이미 메모리에 있는 ID(주운 아이템 등)와 은퇴한 ID(다 쓴 아이템, 치운 시체)는 건너뛰고 경고를 남긴다. 그래서 셀 파일이 오래된 백업에서 복구돼도 아이템이 둘이 되거나 되살아나지 않는다.
- 격자가 바뀐 저장(`systems.world_cells.grid`가 지금 설정과 다름): `WorldPersistence`가 셀 파일을 전부 읽어 `ServerWorld.repartition_from`으로 메모리에 올리고 위치로 셀을 다시 정한 뒤, 셀 파일 전체를 한 세대에 바꿔 쓴다. 읽지 못하는 셀 파일이 있으면 시작을 거부하고 저장은 그대로 둔다.

**클라이언트 복제**(새 RPC 없음): 서버 메모리에 있는 셀(ACTIVE와 PRELOADED)의 월드 아이템·좀비가 접속자 전원에게 간다.

- 월드 아이템: 새 모듈 `WorldCellNetModule`(`WorldCellNet`, 자체 RPC 없음)이 `cell_loaded`에서 그 셀의 아이템을 기존 `InventoryNet._rpc_world_items_added`로, `cell_unloading`에서 아이템마다 기존 `NetworkService._rpc_world_item_removed`로 보낸다. 두 파일을 고치지 않으려고(하나는 동결, 하나는 다른 티켓 소유) 메시지를 이름으로 부른다.
- 좀비: `ZombieNetModule`이 같은 두 시그널에서 그 셀의 좀비마다 기존 `zombie_spawned`/`zombie_removed` 전선 이벤트를 번호가 이어지는 이벤트 흐름에 넣는다. 월드에서 실제로 생기거나 없어진 것이 아니므로 `ZombieService`의 도메인 이벤트와 `server_events_drained`에는 들어가지 않는다. 이렇게 나타난 좀비는 다음 스냅샷(0.1초 이내)이 올 때까지 미러에서 idle·체력 100%로 보인다.
- 나중에 접속한 클라이언트의 join 스냅샷에는 그 순간 메모리에 있는 것만 들어간다.

**아이템 이동(P2-T15·T16, §14.29·§14.30)과 셀**: 세 규칙이 지켜진다. 새 RPC·새 저장 형식은 없다.

- 내려놓기: 묶음 전체든 일부든, 월드에 놓이는 인스턴스는 놓인 위치의 셀 ID를 `location_id`로 갖고 셀 색인에 들어간다(`InventoryService._move_to_world`). 일부 내려놓기로 생기는 새 ID의 인스턴스도 같다. 그래서 그 셀이 해제될 때 셀 문서로 저장되고, 다시 로딩될 때 같은 ID·수량·위치로 돌아온다.
- 줍기: 주운 인스턴스는 합쳐지든 아니든 셀 색인에서 빠진다. 일부만 합쳐진 것은 ID를 지닌 채 인벤토리에 있고(들고 있는 아이템은 셀과 함께 내려가지 않는다), **전부 합쳐져 없어진 것은 ID가 은퇴(tombstone)한다**. 셀을 로딩할 때 메모리에 있는 ID와 은퇴한 ID는 건너뛰므로, 그 셀의 저장본이 나머지 저장보다 오래됐어도(백업에서 복구) 합쳐진 수량이 다시 생기지 않는다. 일부만 합쳐진 것의 옛 수량도 되살아나지 않는다(메모리의 수량이 우선).
- 거래(`exchange_items`)와 `transfer_item`은 들고 있는 아이템만 다룬다: 셀 색인을 건드리지 않고, 없어진 묶음의 ID는 은퇴한다. `TradeService`는 셀에 두는 엔티티가 없어 셀 훅을 구현하지 않고, 두 플레이어의 서버 위치 사이 거리만 본다.
- 한계: 셀 파일이 백업에서 복구되면 그 백업 뒤에 그 셀에 내려놓은 것은 사라진다(묶음 전체든 일부든 같다). 복제는 되지 않지만 수량은 줄 수 있다(docs/15 §14.6 "확인하지 못한 것").

**테스트**: `tests/unit/world_cell_grid_test.gd`(좌표·ID·음수·정확한 경계·이웃·전이 표·색인), `world_cell_service_test.gd`(서버 위치 기반 활성화, 전이 순서, 히스테리시스, 미리보기, 로딩 예산, 로딩 실패·저장 실패, 저장소 없음, 떠돌이, 해제→재로딩 동일성), `world_cell_gating_test.gd`(비활성 셀의 좀비는 이동·감지·공격하지 않고 같은 조건의 활성 셀 좀비는 한다, 소음, 경계, 처리량), `world_cell_save_test.gd`(셀 파일, v3→v4, 빈 셀, 백업, 바뀌지 않은 파일), `world_cell_measure_test.gd`(측정값 출력), `tests/integration/world_cell_persistence_test.gd`(저장→재시작→복구, 구버전 저장, 시드 아이템 재생성 없음, 해제 세대의 일관성, 격자 변경, 손상된 셀 파일), `world_cell_net_test.gd`(두 클라이언트 미러의 제거·추가·일치). 아이템 이동과 셀: `tests/unit/item_moves_in_cells_test.gd`(일부 내려놓기의 셀·색인·셀 문서, 합쳐진 줍기의 색인 제거와 ID 은퇴, 일부 내려놓기·합쳐진 줍기 뒤 해제→재로딩의 수량 보존과 ID 유일, 줍기 전의 셀 문서가 돌아와도 합쳐진 수량이 되살아나지 않음, 내려놓기·합쳐진 줍기·완료된 거래 뒤 해제된 셀이 있는 월드 문서 왕복), `tests/integration/item_moves_cell_persistence_test.gd`(같은 흐름의 저장→재시작→복구를 실제 파일로 두 번, 디스크의 world_state와 셀 파일 전체에서 수량 보존·ID 유일·은퇴 ID 없음, 줍기 전 백업 셀 파일로 복구된 재시작).

**P3-2가 알아야 할 것**: (1) 클라이언트별 범위는 `WorldCellNetModule`과 `ZombieNetModule`의 `cell_loaded`/`cell_unloading` 처리와 `NetworkService._build_join_snapshot`·`ZombieNetModule.build_join_fragment`·좀비 스냅샷 전송 세 곳을 "그 접속자의 관심 셀"로 거르면 된다. 관심 셀 계산에는 `WorldCellGrid.cells_within`과 `ServerWorld.cell_index.entities_in_cell`을 쓸 수 있다. (2) 지금은 PRELOADED 셀의 엔티티도 전송된다. (3) 아이템 제거는 아이템마다 메시지 하나다. (4) `InventoryNetModule`과 `NetworkService`에 공개 함수를 두면 이름으로 RPC를 부르는 부분을 없앨 수 있다. (5) 직접 `inventory.spawn_world_item`을 부르는 서버 코드는 여전히 복제되지 않는다(docs/15 P2-119). (6) 클라이언트 쪽 바닥·경계 표시는 서버의 `WorldCellSettings.bounds`와 `world_half_extent_m`이 같은 사각형임을 전제로 하면 된다.

### 15.2 셀 기반 복제 범위와 클라이언트 테스트 맵(P3-2)

접속자마다 **자기 플레이어 주변 셀**의 월드 아이템과 좀비만 받는다. 이 절이 §14.12·§14.13·§14.17·§14.29·§15.1의 "접속 중인 모든 클라이언트에게 보낸다", "거리 필터가 없다"는 서술보다 우선한다(플레이어 자신에 관한 것은 예외: 아래 "플레이어는 전역"). 클라이언트는 서버가 알려 준 맵 배치로 500m × 500m 테스트 맵의 바닥·가장자리·셀 경계를 그린다. 임시 수치·결정·측정값은 docs/15 §15.2(P3-031~P3-055).

**프로토콜 변경 있음**: `BuildInfo.PROTOCOL_VERSION` 12 → 13(12는 먼저 병합된 P3-4a 구조물 메시지다, §15.4). 새 RPC 하나, 새 전선 이벤트 둘, 새 접속 조각 둘, 그리고 기존 메시지 몇 개의 뜻이 바뀌었다(아래 "메시지"). 기존 RPC의 서명은 바뀌지 않았다.

#### 관심 셀 기능(재사용 가능, 아이템·좀비를 모른다)

| 구성 요소 | 파일 | 계약 |
|---|---|---|
| `InterestSettings` | `scripts/services/multiplayer/interest_settings.gd`, `data/tuning/interest_settings.tres` | `interest_radius_cells`(2): 플레이어가 있는 셀에서 이만큼 안의 셀(정사각형, 체비쇼프 거리)이 관심 셀이 된다. `keep_margin_cells`(1): 한번 관심 셀이 된 셀은 `반경 + 여유`칸(`keep_radius_cells()` = 3)보다 멀어져야 빠진다. `validate()`, `validate_against(world_cells)`: `반경 + 여유 ≤ WorldCellSettings.preload_radius_cells`(서버가 그 플레이어 주변에 메모리로 두는 범위를 넘지 못한다). `CompositionConfig.interest`, `CompositionConfig.validate()`가 둘 다 부른다 |
| `CellInterest` | `scripts/services/multiplayer/cell_interest.gd` | 노드 없는 순수 장부. 접속자(peer)별 관심 셀 집합. 아래 표 |
| `InterestNetModule` | `scripts/services/multiplayer/interest_net_module.gd` | NetModule `InterestNet`, **RPC 없음**, 서버에서만 동작. `CellInterest`를 만들어 `NetworkService.cell_interest`에 걸고 서버 위치로 갱신한다. `ServerComposition.install_net_modules`가 **가장 먼저** 등록한다 |

`CellInterest` API(`network.cell_interest`, 서버 전용. 클라이언트와 모듈 없는 조립에서는 null):

| API | 계약 |
|---|---|
| `signal cell_gained(peer_id, cell_id)` | 그 접속자에게 그 셀에 지금 있는 것을 전부 알려라 |
| `signal cell_lost(peer_id, cell_id)` | 그 접속자에게서 그 셀의 것을 전부 치워라(엔티티는 아직 읽을 수 있다) |
| `is_interested(peer_id, cell_id) -> bool`, `peers_for_cell(cell_id) -> PackedInt32Array`(정렬) | 엔티티가 생기거나 바뀌거나 없어질 때 누구에게 보낼지 |
| `cells_of(peer_id) -> PackedStringArray`(x, z 순), `cell_count_of`, `has_peer`, `peer_ids` | 조회 |
| `begin_peer(peer_id, in_world, position)` | 접속하는 peer의 첫 셀을 **시그널 없이** 정한다: 그 셀의 내용은 접속 스냅샷으로 간다 |
| `update_peer(peer_id, in_world, position)` | 다시 살펴보고 바뀐 만큼 `cell_lost`(먼저) → `cell_gained`를 낸다. 셀이 그대로면 아무 일도 하지 않는다 |
| `remove_peer(peer_id)` | 나간 peer를 잊는다(시그널 없음) |
| `notify_cell_loaded(cell_id)` / `notify_cell_unloading(cell_id)` | 셀이 서버 메모리에 들어옴 / 나가려 함 |
| `update_count`, `recompute_count`, `gained_count`, `lost_count` | 진단값 |

규칙:

- 입력은 **서버가 가진 플레이어 위치**뿐이다. 클라이언트가 보낸 값은 쓰지 않는다.
- 영역은 플레이어 **위치**가 아니라 플레이어가 있는 **셀** 기준의 정사각형이고 맵 밖 셀은 없다(`WorldCellGrid.cells_within`). 음수 좌표는 격자와 같이 내림한다.
- **히스테리시스는 공간 여유뿐이다(시계 없음)**: 관심 셀은 `interest_radius_cells` 안에 들어와야 생기고 `keep_radius_cells()` 밖으로 나가야 없어진다. 여유가 1칸 이상이면 한 경계를 왔다 갔다 해도 첫 통과 뒤로는 아무것도 바뀌지 않는다. 그래서 같은 자리에 서 있어도 **걸어온 길에 따라** 바깥 고리 한 줄이 다를 수 있다(접속한 사람은 정사각형만, 걸어온 사람은 지나온 쪽 한 줄을 더 갖는다).
- **월드에 캐릭터가 없는 접속자**(P2-T9: 접속했지만 캐릭터를 만들기 전)는 관심 셀이 없다. 캐릭터가 월드에 들어오는 순간(`on_player_joined`) 한꺼번에 얻는다. **죽은 캐릭터**는 월드에 있으므로(`ServerWorld.is_online`) 몸이 있는 자리 주변을 계속 본다(셀 생명주기와 같은 기준, docs/15 P3-029).
- **서버 메모리에 없는 셀은 누구의 관심 셀도 아니다**: "peer P가 셀 C에 관심 있다" = "P는 지금 C의 내용을 받고 있다". 셀이 메모리에 들어오면 그 셀을 원하는 peer가 얻고(`cell_gained`), 나가려 하면 가진 peer가 잃는다(`cell_lost`). 그래서 §15.1의 `cell_loaded`/`cell_unloading`을 각 모듈이 따로 들을 필요가 없다. 셀 서비스가 없는 월드는 모든 셀이 메모리에 있는 것으로 본다.
- 갱신: `InterestNetModule.server_physics`가 **매 서버 틱** 모든 접속자를 살핀다(다른 모듈보다 먼저). 플레이어가 월드에 들어올 때는 그 자리에서. 서버 코드가 위치를 직접 옮기면 다음 틱에 반영된다.

#### `network_service.gd`의 변경(동결 이후 세 번째, 이 티켓에서 바꾼 전부)

1. `var cell_interest: CellInterest = null`(공개. `InterestNetModule`이 서버 시작 때 넣는다).
2. 공개 함수 둘: `is_cell_of_interest(peer_id, cell_id) -> bool`, `peers_interested_in(cell_id) -> PackedInt32Array`. `cell_interest`가 null이면 각각 `true`, `joined_peers()`(= P3-2 전의 동작).
3. `_build_join_snapshot`: 모듈 조각을 **먼저** 만들고(관심 모듈의 조각이 그 접속자의 셀을 정한다) `world_items`에는 `is_cell_of_interest(peer, cell_index.cell_of(item))`인 것만 넣는다. 스냅샷의 형식과 키는 그대로다.
4. `_rpc_request_pickup`: 성공했을 때 `_rpc_world_item_removed`를 모든 접속자가 아니라 `peers_interested_in(result.event.from_cell_id)`에게 보낸다. 거부했을 때 요청자에게 보내는 사유를 `_public_pickup_reason`으로 거른다(아래 "클라이언트를 믿지 않는다").
5. 새 private 함수 `_public_pickup_reason(peer_id, item_id, reason)`.

RPC 서명·채널·순서·저장 시점은 바뀌지 않았다. 플레이어에 관한 것(`_rpc_player_joined`/`_rpc_player_left`/`_rpc_position_snapshot`, 스냅샷의 `players`)은 건드리지 않았다.

#### 무엇을 누가 받는가

| 서버에서 일어난 일 | 보내는 곳 | 받는 접속자 |
|---|---|---|
| 접속(join) | `NetworkService` 스냅샷 `world_items`, `ZombieNet` 조각 `rows` | 그 접속자의 관심 셀에 있는 것만 |
| 접속자가 셀을 얻음(걸어감, 월드 진입, 셀이 메모리에 들어옴) | `WorldCellNetModule` → `InventoryNetModule.send_world_items_added(peer, entries)` / `ZombieNetModule`의 조정(아래) | 그 접속자 |
| 접속자가 셀을 잃음(걸어 나감, 셀이 메모리에서 나감) | `WorldCellNetModule` → `InventoryNetModule.send_world_items_removed(peer, ids)` / `ZombieNetModule`의 조정 | 그 접속자 |
| 아이템을 내려놓음(묶음 전체·일부, 사망 시 전부 내려놓기) | `InventoryNetModule._rpc_world_items_added` | 놓인 셀(이벤트의 `cell_id`)에 관심 있는 접속자. 소지품 변화는 그대로 소유자에게만 |
| 아이템을 주움(합쳐진 경우 포함) | `NetworkService._rpc_world_item_removed` | 놓여 있던 셀(`from_cell_id`)에 관심 있는 접속자. 결과와 소지품 변화는 그대로 요청자에게만 |
| 좀비 생성(`zombie_spawned`) | `ZombieNetModule._rpc_zombie_events` | 그 좀비의 셀에 관심 있는 접속자(그때부터 그 좀비를 "안다") |
| 그 밖의 좀비 이벤트(감지, 상태 변화, 공격, 피해, 사망, 제거) | 같음 | 그 좀비를 아는 접속자. `zombie_attacked`의 비공개 필드는 그대로 맞은 플레이어에게만 |
| 좀비 위치 스냅샷 | `ZombieNetModule._rpc_zombie_snapshot` | 접속자마다 자기가 아는 좀비의 행만 |
| 근접 공격 이벤트(`melee_attack`) | `CombatNetModule._rpc_combat_events` | 공격자 본인(항상), 맞은 좀비를 아는 접속자, 빗나간 공격은 공격자의 셀에 관심 있는 접속자 |
| 플레이어에 관한 것(위치, 생존 공개 이벤트, 자세, 캐릭터 행, 거래·치료 알림) | 기존 그대로 | **모든 접속자**(이 티켓에서 범위를 두지 않았다) |
| 구조물(§15.4: 접속 조각, 배치·철거·문, 셀 로딩·해제) | `StructureNetModule` 그대로 | **모든 접속자**, 서버 메모리에 있는 모든 셀(아직 범위를 두지 않았다, docs/15 P3-056) |

요청자에게 가는 결과(`_rpc_pickup_result`, `_rpc_drop_result`, `_rpc_melee_result` 등)와 소유자 전용 메시지는 관심 셀과 무관하게 항상 간다. 요청자의 미러는 다음 불변식으로 일관된다: **미러에 있는 월드 아이템·좀비 = 지금 관심 셀에 있는 것**. 내려놓은 아이템의 셀이 (아주 드물게) 아직 요청자의 관심 셀이 아니면 추가는 가지 않고, 다음 틱에 그 셀을 얻을 때 함께 간다.

#### 메시지

| 방향 | RPC / 조각 | 채널/모드 | 내용 |
|---|---|---|---|
| S→C | `InventoryNet._rpc_world_items_removed(item_instance_ids: Array[String])` **(새 RPC)** | 0 reliable | 더는 관심 없는 셀의 월드 아이템을 미러에서 뺀다. 한 메시지에 `max_items_per_message`(32, 상한 64)개까지. 미러에 없는 ID는 조용히 건너뛴다(방금 누가 주웠을 수 있다). 아이템은 월드에 그대로 있다 |
| S→C | `InventoryNet._rpc_world_items_added(items)` (기존) | 0 reliable | 형식 그대로. 받는 사람만 달라졌다 |
| S→C | `NetworkService._rpc_world_item_removed(item_instance_id)` (기존) | 0 reliable | 형식 그대로. 줍기로 없어진 아이템 하나. 받는 사람만 달라졌다 |
| S→C | `ZombieNet._rpc_zombie_events(tick, first_sequence, events)` (기존 RPC) | 0 reliable | **순번이 클라이언트별**이다: 그 클라이언트에게 보낸 이벤트만 1부터 센다(구멍 없음). 새 전선 이벤트 둘이 실린다(아래) |
| S→C | `ZombieNet._rpc_zombie_snapshot(tick, rows)` (기존 RPC) | 2 unreliable_ordered | 형식 그대로. 그 클라이언트가 아는 좀비의 행만 |
| S→C | `CombatNet._rpc_combat_events(events)` (기존 RPC) | 0 reliable | 형식 그대로. 순번은 서버 전체의 것이라 멀리 있는 클라이언트에게는 **구멍**이 보인다(뒤로 가지는 않는다) |
| S→C | 접속 조각 `modules.WorldCellNet` = `{cell_size_m: float, bounds_min_m: [x, z], bounds_max_m: [x, z]}` **(새 조각)** | 0 reliable(`_rpc_join_accepted` 안) | 서버의 `WorldCellGrid.signature()`. 캐릭터가 없는 접속자에게도 간다 |
| S→C | 접속 조각 `modules.InterestNet` = `{}` **(새 조각, 비어 있음)** | 같음 | 만드는 과정에서 그 접속자의 첫 관심 셀이 정해진다 |
| S→C | 접속 조각 `modules.ZombieNet` (기존) | 같음 | `rows`는 관심 셀의 좀비만, `event_sequence`는 그 클라이언트 자신의 흐름이 시작하는 번호(새 접속자는 0) |

새 전선 이벤트(`ZombieNetProtocol`, `ZombieService`는 만들지 않는다):

| 이벤트 | 필드(`event_type`, `zombie_id`, `world_time` 공통) | 뜻 |
|---|---|---|
| `zombie_entered` | `position: [x, y, z]`, `yaw`, `state`(`ZombieState.STATE_NAMES`), `health_fraction`(0~1) | 그 좀비가 이 클라이언트의 관심 셀에 들어왔다. 스냅샷 행과 같은 내용이라 **있는 그대로**(상태·체력·시체 여부) 나타난다. docs/15 P3-015("로딩된 좀비가 잠깐 idle·체력 100%로 보인다")는 해소됐다 |
| `zombie_left` | 없음 | 그 좀비가 관심 셀에서 나갔다. 좀비는 월드에 그대로 있다 |

클라이언트 미러(`ClientZombieState`)는 `zombie_entered`를 "추가 또는 최신으로 교체"(이미 있으면 `zombie_added`를 다시 내지 않는다), `zombie_left`를 `zombie_removed`와 같이 처리한다. 표시 계층은 "생김/치워짐"(`zombie_spawned`/`zombie_removed`)과 "시야에 들어옴/나감"을 이벤트 종류로 구분할 수 있다.

#### 좀비: 접속자별 흐름과 조정

`ZombieNetModule`은 접속자마다 흐름 하나(`PeerStream`: 아는 좀비 집합, 자기 순번, 보낼 이벤트)를 둔다. 흐름은 그 접속자의 접속 조각을 만들 때 시작하고 나가면 없어진다.

- **조정(reconcile)**: 스냅샷을 보내는 틱마다(기본 10Hz) 메모리의 모든 좀비를 각 접속자의 관심 셀과 대조한다. 알아야 하는데 모르는 좀비는 `zombie_entered`, 알고 있는데 관심 셀에 없는(또는 메모리에서 나간) 좀비는 `zombie_left`를 그 접속자의 흐름에 넣는다. 좀비가 관심 영역 경계를 걸어서 넘는 것, 접속자가 걷는 것, 월드 진입, 셀의 로딩·해제가 모두 이 한 번의 대조로 처리된다. 그래서 **나타나고 사라지는 시점은 최대 스냅샷 한 주기(0.1초) 늦을 수 있다**. 한 틱 안의 순서는 이벤트 수집 → 조정 → 이벤트 전송 → 스냅샷 전송이라, 나타난 좀비는 같은 틱의 스냅샷 행보다 먼저 미러에 있다.
- 조정 사이에 난 이벤트는 "아는 접속자"에게만 가므로, 아직 `zombie_entered`를 받지 않은 접속자는 그 이벤트를 받지 않는다. 상태와 체력은 `zombie_entered`가 최신 값으로 전한다.
- 유령·중복이 없다: 미러의 구성원은 reliable 이벤트(`zombie_spawned`/`zombie_entered`/`zombie_removed`/`zombie_left`)로만 바뀌고, 늦게 온 스냅샷은 없는 좀비를 만들지 않는다.
- `server_events_drained`는 그대로 모든 도메인 이벤트를 낸다(누가 받았는지와 무관). 조정이 만든 두 이벤트는 들어 있지 않다.
- 서버 공개 함수(다른 모듈용): `knows_zombie(peer_id, zombie_id) -> bool`, `ensure_known(peer_id, zombie_id) -> bool`(모르는 좀비면 `zombie_entered`를 그 자리에서 보낸 뒤 true. 좀비가 없거나 흐름이 없으면 false).
- `build_join_fragment`는 접속당 한 번 불린다는 전제로 흐름을 시작한다. 이미 흐름이 있는 peer에 대해 부르면(도구·테스트) 흐름을 건드리지 않고 "지금 접속하면 받을 것"만 돌려준다.

#### 좀비에 딸린 다른 것들(각 결정은 docs/15 §15.2)

- **전투 이벤트**(`CombatNetModule._is_for`): 공격자 본인은 항상 받는다(자기 행동의 결과). 명중한 공격은 맞은 좀비를 아는 접속자에게, 빗나간 공격(좀비를 지목하지 않음)은 공격자가 서 있는 셀에 관심 있는 접속자에게 간다. 공격자가 맞힌 좀비를 모르는 경우(근접 사거리에서는 설정이 맞으면 일어나지 않는다)에는 먼저 `ensure_known`으로 알려 준다. 그래서 "모르는 좀비에 관한 이벤트"는 누구에게도 가지 않는다.
- **좀비의 공격**(`zombie_attacked`): 맞은 플레이어는 그 좀비를 모르더라도 이벤트를 받는다(자기 감염 판정이 들어 있다). 이때도 먼저 `zombie_entered`로 알려 주고(`forced_known_count`), 그 좀비가 관심 셀 밖이면 다음 조정에서 `zombie_left`로 다시 빠진다. 본인의 상처·감염은 이와 별개로 `SurvivalNet`의 본인 이벤트·스냅샷으로 항상 간다.
- **소음**: 소음은 클라이언트에 복제되지 않는다(P2-A1부터). 소음에 반응한 `zombie_detected`(감각 종류, 소음 위치)는 그 좀비를 아는 접속자에게만 간다.
- **생존 공개 이벤트**(`player_wounded` 등): 플레이어에 관한 것이라 모든 접속자에게 간다(어느 좀비가 물었는지는 들어 있지 않다).

#### 플레이어는 전역(임시, docs/15 P3-041)

플레이어 행·위치 스냅샷·플레이어에 딸린 공개 사실(생존 공개 이벤트, 자세 행, 캐릭터 행, 거래 완료·치료 알림)은 이 티켓에서 범위를 두지 않았다. 위치 스냅샷과 접속·퇴장 알림은 동결된 `network_service.gd`가 보내고, 플레이어를 키로 쓰는 미러가 다섯 모듈에 있어(`SurvivalNet`, `PostureNet`, `CharacterNet`, `TradeNet`, `InventoryNet`의 알림) 범위를 두려면 "플레이어가 시야에 들어옴/나감"을 그 전부에 넣어야 한다. 별도 티켓으로 둔다.

#### 클라이언트를 믿지 않는다

줍기 판정은 그대로 서버의 사거리 검사뿐이다: 관심 셀 밖의 아이템 ID를 보내도 서버 위치에서 사거리 안이면 줍고, 아니면 거부한다. 달라진 것은 **거부 사유를 알려 주는 방식**이다(`NetworkService._public_pickup_reason`, ADR-009):

| 서버 내부 사유 | 요청자에게 가는 사유 |
|---|---|
| `unknown_item`(없는 ID) | `item_not_in_world` |
| `item_not_in_world`(누가 들고 있음) | `item_not_in_world` |
| `too_far`·`inventory_full`, 그 아이템의 셀이 요청자의 관심 셀이 **아님** | `item_not_in_world` |
| `too_far`·`inventory_full`, 관심 셀임(미러에 있는 아이템) | 그대로 |
| 요청자 자신에 관한 사유(`player_dead`, `player_resting`, `not_online`), 형식·빈도 사유 | 그대로 |

즉 자기가 받지 않은 아이템에 대해서는 "없는 ID", "남이 들고 있는 것", "먼 곳에 놓인 것"을 구별할 수 없다. 거부 카운터(`rejected_intent_count`)와 로그에는 서버 내부 사유가 남는다. 내려놓기·소비·거래의 사유 가리기(`InventoryNetModule.public_reason` 등)는 그대로다.

#### P3-030 정리(이름으로 부르던 RPC)

`WorldCellNetModule`은 더 이상 다른 노드의 RPC를 메서드 이름으로 부르지 않는다. `InventoryNetModule`에 서버 공개 함수 둘이 생겼다: `send_world_items_added(peer_id, entries) -> int`, `send_world_items_removed(peer_id, item_instance_ids) -> int`(보낸 개수. 형식이 맞지 않는 항목은 오류 로그 후 뺀다. 메시지 분할 포함). `NetworkService._rpc_world_item_removed`는 줍기 전용으로 남았고 `WorldCellNetModule`은 쓰지 않는다. `WorldCellNetModule`은 `cell_interest`의 `cell_gained`/`cell_lost`만 듣는다(§15.1의 `cell_loaded`/`cell_unloading`을 직접 듣지 않는다). 생성자 인자(`InventoryNetSettings`)는 없어졌다.

#### 클라이언트 맵(`scripts/presentation/`, `scenes/main/client_view.tscn`)

- **맵 배치는 서버에서 온다**: `ClientWorldMap`(`scripts/services/multiplayer/client_world_map.gd`, `WorldCellNetModule.client_map`)이 접속 조각을 검증해(유한값, 크기 > 0, 최대 > 최소, 한 축의 셀 수 ≤ 100000, 키 정확히 셋) 보관하고, 같은 값으로 `WorldCellGrid`를 만들어 서버와 **같은 셀 계산**을 쓴다(`cell_id_at`). 클라이언트는 자기 `world_cell_settings.tres`를 읽지 않는다(테스트: 서버가 25m·20m 셀의 다른 맵을 돌려도 클라이언트가 그 맵을 그린다). 검증에 실패하면 맵은 "모름" 상태이고 아무것도 그리지 않는다.
- **순수 계산** `WorldMapPresentation`: `ground(bounds_min, bounds_max)`(중심과 크기), `edge_boxes(...)`(가장자리 벽 넷: 안쪽 면이 맵 경계, 맵 **바깥**에 선다), `overlay_cells`, `cell_border_segments(...)`(플레이어 셀 주변 셀들의 경계선, 한 번씩, 맵 경계에서 자름), `cell_labels(...)`(셀마다 ID와 위치). HUD 문구는 `ClientPresentationFormatter.build_map_lines(cell_id, position, overlay_visible, settings)`.
- **노드** `WorldMapVisuals`(`%WorldMap` 아래): `Ground`(PlaneMesh, 맵 크기), `Edges`(벽 넷), `CellOverlay`(`Borders`: 선 메시, `Labels`: 셀 ID 라벨). 배치가 바뀔 때만 다시 만든다. 오버레이는 켜져 있을 때 플레이어가 셀을 옮기면 다시 만든다.
- **HUD**: 오른쪽 아래 `MapLabel`에 "셀 cell_0_0 | 위치 x 12, z -3 | 셀 경계 [F3] 꺼짐". 현재 셀은 미러의 본인 위치와 서버의 배치로 계산한다(`ClientView.current_cell_id()`). 맵을 모르거나 월드에 없으면 숨는다.
- **디버그 키**: `ClientPresentationSettings.cell_overlay_key`(기본 F3, 액션 `toggle_cell_overlay`)가 셀 경계 오버레이를 켜고 끈다(로컬 전용, 아무것도 보내지 않는다). `cell_overlay_radius_cells`(3), `cell_overlay_initially_visible`(false). 키 겹침 검사(`assigned_keys`, `keys_shared_with`)에 포함된다: 이 Resource의 키는 열일곱 개가 됐다.
- **미러를 따라가는 표시**: 바닥 아이템 표시(`WorldItemMarkers`)와 좀비 캡슐은 기존대로 미러의 변화(`changed`, `zombie_added`/`zombie_removed`)를 따른다. 범위 밖으로 나간 것은 미러에서 빠지므로 표시도 없어진다. 이벤트 로그는 `zombie_entered`/`zombie_left`를 적지 않는다.
- 새 설정(모두 `ClientPresentationSettings`, 임시): `map_ground_color`, `map_edge_color`, `map_edge_height_m`(3), `map_edge_thickness_m`(0.5), `cell_overlay_key`, `cell_overlay_initially_visible`, `cell_overlay_radius_cells`, `cell_overlay_color`, `cell_overlay_height_m`(0.05), `cell_overlay_label_height_m`(2.5), `cell_overlay_label_pixel_size`, `cell_overlay_label_font_size`. 화면 설명은 docs/11 §2.15.

#### 테스트

`tests/unit/cell_interest_test.gd`(반경·맵 가장자리·음수 좌표, 시그널 순서, 히스테리시스(걸음 수로), 캐릭터 없는 접속자, 여러 접속자, 메모리에 없는 셀, 설정 검증과 조립 검증), `zombie_scope_events_test.gd`(두 전선 이벤트의 형식·검증과 미러 처리), `world_map_presentation_test.gd`(서버 배치의 수용·거부, 바닥·벽·경계선·라벨 계산, HUD 문구, 키), `tests/integration/interest_net_test.gd`(실제 ENet, 500m 맵에 멀리 떨어진 클라이언트 셋: 아이템이 가까운 접속자에게만 있고 걸어 들어오면 생기고 나가면 없어짐 / 늦은 접속자의 접속 데이터 / 일부·전체 내려놓기와 합쳐진 줍기 / 사망 시 내려놓기 / 좀비 이벤트·스냅샷 / 관심 경계를 넘는 좀비가 한 번 나타나고 한 번 사라짐 / 관심 셀 밖 아이템에 대한 조작된 줍기 / 함께 선 두 클라이언트의 일치 / 전투 이벤트 수신자 / `ensure_known` 뒤 조정 / 캐릭터 없는 접속자 / 서버에서 온 맵 배치), `interest_view_test.gd`(실제 클라이언트 세션: 서버 맵 크기의 바닥과 벽, HUD 셀, 걸을 때 표시가 미러를 따라감, 실제 입력 액션으로 오버레이), `interest_measure_test.gd`(측정값 출력, docs/15 §15.2). 고친 기존 테스트는 docs/15 §15.2에 적었다.

#### 다음 티켓(P3-3 보관함, P3-4 구조물)이 알아야 할 것

**구조물은 아직 범위 밖이다(임시, docs/15 P3-056)**: 이 절과 따로 병합된 `StructureNetModule`(§15.4)은 관심 셀을 쓰지 않는다. 셀 서비스의 `cell_loaded`/`cell_unloading`을 직접 듣고 `joined_peers()` 전원에게 보내며, 접속 조각에는 메모리의 모든 구조물이 들어 있다. 이 티켓의 변경(접속 스냅샷에서 모듈 조각을 먼저 만드는 순서, 관심 모듈이 첫 번째)과는 서로 영향을 주지 않는다: 그 모듈은 `cell_interest`와 월드 아이템 목록을 읽지 않는다. P3-5가 병합된 뒤 아래 순서대로 범위를 둔다.

셀에 사는 엔티티를 복제하는 모듈은 다음 넷만 하면 된다.

1. 접속 조각(`build_join_fragment(player_id)`)에는 `network.is_cell_of_interest(network.peer_of_player(player_id), cell_id)`인 것만 넣는다(이 시점에 그 접속자의 첫 셀은 이미 정해져 있다: 관심 모듈이 먼저 등록돼 있어야 한다).
2. `on_server_started`에서 `network.cell_interest`(null일 수 있다)의 `cell_gained(peer_id, cell_id)`에 그 셀의 엔티티 전부를 보내는 처리를, `cell_lost`에 전부 빼는 처리를 건다. 셀의 엔티티는 `ServerWorld.cell_index.entities_in_cell(cell_id, kind)`로 얻는다. `_exit_tree`에서 끊는다.
3. 엔티티가 생기거나 바뀌거나 없어질 때는 `network.peers_interested_in(cell_id)`에게만 보낸다(`can_send_to` 확인은 그대로).
4. 엔티티가 셀을 옮겨 다니면(좀비처럼) 2 대신 주기적으로 대조하는 방식을 쓴다(`ZombieNetModule._reconcile`).

요청자에게 주는 결과에는 관심 셀 밖 엔티티의 존재가 드러나지 않게 한다(줍기의 사유 가리기와 같은 규칙).

### 15.4 격자 구조물: 바닥·벽·문(P3-4a, docs/00 ADR-024, system id `building`, 모듈 `StructureNet`)

서버·네트워크·클라이언트 미러까지다. 구조물을 화면에 그리는 것과 건축 모드 입력은 P3-4b, 청사진·자재·작업 진행은 P3-5, 길찾기와 시야 차단은 P3-6이다. **프로토콜 변경 있음**: RPC 여섯 개와 접속 스냅샷의 `modules.StructureNet` 조각이 새로 생겨 `BuildInfo.PROTOCOL_VERSION`을 12로 올렸다(11은 P2-T16의 거래, §14.30). 기존 RPC와 메시지 형식은 그대로다.

**정의와 설정**

| 구성 요소 | 계약 |
|---|---|
| `StructureDefinition` (`resources/definitions/structures/*.tres`) | `definition_id`(snake_case), `display_name`, `placement`(`TILE` 타일을 채움 / `EDGE` 타일의 변에 섬), `blocks_movement`(변 조각만 가능), `is_door`(변 조각만 가능), `max_health`, `build_costs`(`{아이템 정의 ID: 수량}`, P3-4a에서는 기록만). 지금 있는 것: `dev_floor`(타일), `dev_wall`(변, 막음), `dev_door`(변, 막음, 문). 개발용 자리 표시이고 비용은 비어 있다 |
| `StructureCatalog` | `ItemCatalog`와 같은 모양: `load_directory()`, `add`, `has`, `get_definition`, `definition_ids()`, `validate_against(item_catalog)`(비용에 적힌 아이템이 있어야 한다). 서버 규칙과 클라이언트 미러가 같이 쓴다 |
| `BuildingSettings` (`data/tuning/building_settings.tres`) | `grid_module_m`(1.0), `placement_range_m`(4.0), `demolish_range_m`(4.0), `door_interact_range_m`(2.5), `instant_completion`(true: 임시 규칙), `door_starts_open`(false), `blocker_clearance_m`(0.3), `max_structures_per_cell`(4000), `default_material_quality`(1.0), `collision_skin_m`(0.05, 모듈의 절반보다 작아야 한다), `sliding_mover_kinds`(`["player"]`), `max_pending_events`(4096). `validate()` |
| `StructureNetSettings` (`data/tuning/structure_net_settings.tres`) | 의도별 빈도(배치 4/s·버스트 8, 철거 4/s·8, 문 4/s·4), `rows_per_message`(64), `removals_per_message`(128), `max_mirror_structures`(200000), `persist_on_place_and_demolish`(true), `persist_on_door_change`(false) |
| `CompositionConfig` | 필드 셋이 늘었다: `building`, `structures`, `structure_net`. `validate()`가 셋을 검사한다 |

**격자(`StructureGrid`, 순수 수학, 노드 없음)**

- 타일 `(tx, tz)` = `[tx·m, (tx+1)·m)`. `tile_of(position)`, `tile_center(tile)`.
- 자리(slot)는 `Vector3i(x, z, layer)`다. `TILE`: 타일 `(x, z)` 자체. `EDGE_LOW_X`: 타일 `(x, z)`의 x가 작은 쪽 변(선분 `x = x·m`, `z ∈ [z·m, (z+1)·m]`). `EDGE_LOW_Z`: z가 작은 쪽 변. 두 타일 사이의 변은 좌표가 큰 타일의 "낮은 쪽 변" 하나로만 표현되므로 변 하나에 자리 하나다.
- `slot_of(placement, tile, rotation)`: 변 조각은 회전 0 = -Z 변, 1 = +X 변, 2 = +Z 변, 3 = -X 변(`SIDE_DIRECTIONS`). `slot_key(slot)`(정수 키), `slot_anchor(slot)`(타일 중심 또는 변의 중점: 거리 판정의 기준점), `slot_home(slot)`(자리 이름이 된 타일의 중심: 어느 월드 셀에 속하는지 정한다), `edge_ends`, `distance_to_edge`, `is_tile_inside(tile, half_extent)`, `MAX_TILE_COORD`(±1,000,000).
- `resolve_step(from, to, blocking, skin_m, slide) -> Vector3`: 막는 변 집합을 넘지 못하는 걸음의 끝점. 걸음이 지나는 타일만 따라가며(타일을 하나 넘을 때마다 사전 조회 한 번) 처음 만나는 막힌 변 앞 `skin_m` 지점에서 멈춘다. 이미 그보다 가까우면 제자리다(뒤로 밀지 않는다: 밀면 변 가까이에서 멈춘 걸음이 다음 틱에 튄다). `slide`면 남은 걸음 중 변과 나란한 성분으로 한 번 더 나아간다. 격자 꼭짓점을 정확히 지나는 걸음은 꼭짓점을 도는 두 길이 모두 막혔을 때만 막힌다. 선 위의 점은 좌표가 큰 쪽 타일에 있다. 막는 변이 하나도 없으면 `to`를 그대로 돌려준다. 계산은 64비트로 하고, 32비트로 저장될 끝점을 다시 따라가 확인한다(반올림으로 막힌 변을 넘게 되면 움직이지 않는다).

**런타임 모델(`StructureInstance`)**: docs/04 §4의 필수 필드 그대로다. `structure_id`(`structure_<번호>`, 월드의 `EntityIdGenerator`·`EntityRegistry`, 종류 `structure`), `definition_id`, `owner_shelter_id`(지금은 항상 `""`), `cell_id`, 변환 = `tile`(Vector2i) + `rotation`(0~3), `construction_state`(`blueprint`, `constructing`, `completed`, `damaged`, `destroyed`), `health`, `material_quality`, `inventory_costs`, `connections`(지금은 항상 빈 배열), `last_modified_at`(달력 월드 시간), 그리고 `placed_by`(배치한 플레이어 ID, 서버 규칙이 놓았으면 `""`), `door_open`. `is_standing()` = completed 또는 damaged. `to_dict()`/`from_dict()`(모양만 검사한다. 정의 존재·체력 상한·자리는 서비스가 검사한다).

**`BuildingService`(`scripts/domain/building/building_service.gd`)**: `ServerComposition`이 좀비 뒤, 전투 앞에 등록한다. `step()`은 없다(요청에만 반응한다).

- 플레이어 요청: `try_place(world, player_id, definition_id, tile, rotation)`, `try_demolish(world, player_id, structure_id)`, `try_set_door(world, player_id, structure_id, open)`. 서버 규칙(행위자·사거리 없음): `place_structure(world, definition_id, tile, rotation, placed_by = "")`, `remove_structure(world, structure_id)`, `set_door_open(world, structure_id, open)`.
- 배치 검사 순서(먼저 걸린 것이 사유, 거부되면 아무것도 바뀌지 않는다): `not_online` → `player_dead`/`player_resting`(`ServerWorld.player_action_block_reason`) → `unknown_structure_definition` → `bad_rotation` → `out_of_bounds`(타일 전체가 플레이 영역 안) → `too_far`(플레이어의 **서버 위치**에서 기준점까지) → `cell_not_loaded` → `slot_occupied` → `blocked_by_entity`(막는 조각의 변에서 `blocker_clearance_m` 안에 살아 있는 플레이어나 살아 있는 좀비) → `structure_limit`. 좌표가 정수 타일이라 "격자에서 벗어난 요청"은 표현할 수 없다(네트워크에서는 정수가 아니면 `bad_type`). 같은 자리의 요청 둘은 서버 처리 순서대로 하나만 통과하고 다른 하나는 `slot_occupied`다(docs/04 §10).
- 철거: `not_online` → 행동 차단 → `unknown_structure`(메모리에 없는 셀의 구조물 포함) → `not_owner` → `too_far`. 철거된 ID는 은퇴한다(tombstone).
- 문: `not_online` → 행동 차단 → `unknown_structure` → `not_a_door` → `too_far` → `structure_not_usable`(서 있지 않음) → `door_already_in_state` → `blocked_by_entity`(닫을 때만). 요청은 토글이 아니라 원하는 상태다.
- 조회: `has_structure`, `get_structure`, `structure_ids`, `structure_count`, `structure_id_at(slot)`, `is_edge_blocked(slot)`, `blocking_edge_count`, `slot_of_structure`, `public_row(structure)`, `rows()`, `rows_in_cell(world, cell_id)`, `structure_ids_in_cell`, `grid`, `drain_events()`.
- 이벤트(`drain_events`, JSON-safe): `structure_placed`, `structure_changed`(`cause: "door"`), `structure_removed`. 모두 `event_type`, `world_time`, `player_id`(서버 규칙이면 `""`), `cell_id`와 공개 행(`structure_id`, `definition_id`, `x`, `z`, `rotation`, `state`, `door_open`, `health_fraction`)을 가진다. 셀 로딩·해제는 이벤트를 남기지 않는다.
- 막는 변 집합: 정의가 `blocks_movement`이고 `is_standing()`이며 (문이면) 닫혀 있는 구조물의 변. 청사진은 자리만 차지한다.

**이동 충돌 seam**(티켓 밖의 구조 변경): `ServerSystem`에 훅 둘이 추가됐다.

- `constrains_movement() -> bool`(기본 false): 등록할 때 한 번 묻는다. true인 시스템만 걸음마다 불린다.
- `resolve_movement_step(mover_kind, from, to) -> Vector3`(기본 `to`): 그 시스템의 장애물 때문에 걸음이 끝나는 곳.
- `ServerWorld.resolve_movement(mover_kind, from, to) -> Vector3`: 걸음을 막는 시스템들을 등록 순서대로 거친다. 엔티티를 움직이는 쪽은 이것만 부르고 구조물을 모른다. `ServerWorld.step_movement`(플레이어, `ENTITY_KIND_PLAYER`)와 `ZombieService._move`(좀비, `ENTITY_KIND_ZOMBIE`)가 부른다. 걸음을 막는 시스템이 없거나 막는 변이 없으면 결과는 이 티켓 전과 비트 단위로 같다.
- 좀비: 막힌 걸음은 `obstructed_move_count`(새 진단 값)에 세고 로그를 남기지 않는다. 배회·수색 중이던 좀비는 그 목표를 버린다(다음 목표를 기다린다). 추격·조사 중인 좀비는 벽 앞에 서서 계속 민다(틱당 타일 한두 칸 조회). 좀비의 시야와 근접 공격은 아직 구조물에 막히지 않는다(P3-6).

**월드 셀**(§15.1의 훅 그대로): 구조물은 `ServerWorld.cell_index`에 종류 `structure`로, `slot_home`이 속한 셀 아래에 들어간다(셀 경계 위의 변은 좌표가 큰 쪽 셀: 자리 하나는 항상 셀 하나에 속한다). `to_cell_document`/`restore_cell_document`/`release_cell`을 구현한다. 활성·비활성 훅은 쓰지 않는다(구조물은 시뮬레이션되지 않는다). 메모리에 없는 셀에는 지을 수 없다(`cell_not_loaded`: 그 셀의 점유 상태를 모른다).

- 복구는 먼저 전부 검증한다: 스키마 버전, 각 구조물의 모양, 정의 존재, 체력 ≤ 정의의 최대 체력, 문이 아닌데 열려 있지 않은지, 문서 안의 ID·자리 중복. 하나라도 틀리면 아무것도 바꾸지 않고 오류를 돌려준다(그 셀은 로딩되지 않는다).
- 셀 문서에서는 이미 메모리에 있는 ID, 은퇴한 ID, 메모리의 다른 구조물이 차지한 자리의 구조물을 건너뛰고 경고를 남긴다(오래된 셀 파일이 복구된 경우). 월드 문서에서는 같은 경우가 오류다.
- 구조물의 셀은 저장된 `cell_id`가 아니라 자리로 다시 정하므로, 다른 격자로 나뉜 문서도 그대로 읽힌다(`ServerWorld.repartition_from`).

**저장 배치**: 셀 문서 `systems.building = {schema_version: 1, structures: [StructureInstance]}`(docs/14 §3). 셀 문서에 저장되지 않는 구조물(저장소 없는 월드, 메모리 저장소의 메모리에 있는 셀)은 world_state `systems.building`에 같은 모양으로 들어간다. 구조물이 하나도 없으면 두 곳 모두 키 자체가 없다: P3-4a 전의 저장과 같은 모양이고, 그런 저장은 그대로 읽힌다. world_state 스키마(4)와 셀 문서 스키마(1)는 바꾸지 않았다(시스템 문서가 하나 늘었을 뿐이다). 이벤트는 저장하지 않는다.

**네트워크(`StructureNetModule`, 노드 이름 `StructureNet`)**: 채널 0(`CHANNEL_RELIABLE`), reliable ordered. 구조물은 월드 상태이고 추가·변경·제거가 서버 순서대로 도착해야 하기 때문이다.

| 방향 | RPC | 채널/모드 | 내용 |
|---|---|---|---|
| C→S | `_rpc_request_place(request_id:int, definition_id:String, x:int, z:int, rotation:int)` | 0 reliable | 배치 의도 |
| C→S | `_rpc_request_demolish(request_id:int, structure_id:String)` | 0 reliable | 철거 의도 |
| C→S | `_rpc_request_door(request_id:int, structure_id:String, open:bool)` | 0 reliable | 문을 열어 달라/닫아 달라(원하는 상태) |
| S→요청자 | `_rpc_structure_result(request_id:int, ok:bool, reason:String, structure_id:String)` | 0 reliable | `reason`은 승인일 때만 `""`, `structure_id`는 승인일 때만 채워진다 |
| S→전체 | `_rpc_structure_rows(rows:Array)` | 0 reliable | 생기거나 바뀐 구조물의 행(미러가 ID로 추가와 변경을 구분한다) |
| S→전체 | `_rpc_structures_removed(structure_ids:Array)` | 0 reliable | 철거됐거나 메모리에서 내려간 구조물 |

- 행(wire row): `[structure_id, definition_id, x, z, rotation, state, door_open, health_fraction]`. 접속 조각: `{schema_version: 1, structures: [행, ...]}`(서버 메모리에 있는 구조물 전부, 건축 시스템이 없으면 `{}`).
- 의도 검증 순서: 접속(`not_joined`) → 인자 타입(`bad_type`) → 요청 번호 ≥ 0(`bad_sequence`) → ID·숫자의 모양(`bad_definition_id`, `bad_structure_id`, `out_of_bounds`(좌표 ±1,000,000 밖), `bad_rotation`) → 의도별 빈도(`rate_limited`) → 규칙(`BuildingService`: 사거리·겹침·권한·상태). 행위자는 보낸 peer의 플레이어이고 인자에 없다. 위치·소유자·비용·결과는 클라이언트가 보내지 않는다. 모든 거부는 `NetworkService.rejected_intent_count`에 세고, 요청 번호를 쓸 수 있으면 요청자에게 결과를 보낸다.
- 승인된 요청은 먼저 전체에 복제하고 그다음 요청자에게 결과를 보낸다(같은 순서 채널). 서버 규칙이 직접 만든 변화는 다음 서버 틱에 복제된다. 이 모듈이 `BuildingService.drain_events()`의 유일한 소비자다.
- 셀: `WorldCellService.cell_loaded`에서 그 셀의 구조물을 행으로, `cell_unloading`에서 ID 묶음으로 보낸다(P3-1의 아이템·좀비와 같은 방식).
- 범위: 서버 메모리에 있는 구조물 전부를 접속자 전원에게 보낸다(클라이언트별 범위는 P3-2).
- 저장: 배치·철거가 승인되면 바로 월드를 저장한다(`persist_on_place_and_demolish`). 문 여닫기는 바로 저장하지 않는다(자동 저장·셀 해제·종료 저장에 들어간다).

**클라이언트 미러(`ClientStructureState`, `StructureNetModule.client_state`)**: 권한 없음. `structures`(`structure_id -> {definition_id, tile: Vector2i, rotation, state, door_open, health_fraction}`), `structure_ids()`, `has_structure`, `get_structure`, `structure_count`, `slot_of(id)`, `structure_id_at(slot)`, 시그널 `changed`, `structure_added(id)`, `structure_changed(id)`, `structure_removed(id)`. 모든 payload를 검증한다(행 길이와 타입, ID 형식과 길이, 클라이언트가 가진 정의인지, 좌표·회전 범위, 상태 이름, 문이 아닌데 열려 있지 않은지, 체력 비율 0~1, 메시지당 행 256개·ID 256개, 미러 상한). 틀린 행은 세고(`rejected_payload_count`) 건너뛴다. 틀린 접속 조각은 통째로 버리고 미러를 비운다. 모르는 ID의 제거는 오류가 아니다(`unknown_removal_count`). 클라이언트 API: `request_place(definition_id, tile, rotation)`, `request_demolish(structure_id)`, `request_door(structure_id, open)`(요청 번호를 돌려준다), 시그널 `structure_result(request_id, ok, reason, structure_id)`.

**테스트**: `tests/unit/structure_grid_test.gd`(타일·자리·회전·거리, 걸음 추적: 양쪽에서 막힘, 긴 걸음, 꼭짓점 대각선, 미끄러짐, 무작위 걸음 4000개), `building_service_test.gd`(정의·설정, 필수 필드, 거부 사유 전부, 한 자리 두 요청, 청사진 규칙, 문, 철거, 플레이어·좀비 이동), `building_cell_test.gd`(셀 색인, 해제 → 재로딩 동일성, 월드 문서 왕복, 복구 검증, 격자 변경, 구조물 한 개의 저장 형식), `structure_net_state_test.gd`(미러 검증), `building_measure_test.gd`(측정값 출력), `tests/integration/structure_net_test.gd`(두 클라이언트가 같은 구조물을 봄, 문, 한 자리 요청 셋, 위조 요청, 빈도 제한, 늦은 접속, 셀 해제·재로딩, 저장 → 재시작 → 복구), `building_persistence_test.gd`(실제 파일: 메모리에 있는 셀과 해제된 셀, 구조물 없는 저장, 격자 변경).

**P3-4b(클라이언트 표시·건축 모드 입력)가 알아야 할 것**: (1) 읽을 곳은 `StructureNetModule.client_state`와 그 시그널 넷, 보낼 곳은 `request_place`/`request_demolish`/`request_door`, 답은 `structure_result`다. (2) 월드 위치는 `StructureGrid`로 구한다: 타일 조각은 `tile_center(tile)`, 변 조각은 `slot_anchor(slot_of(id))`와 회전(0 = -Z 변 … 3 = -X 변). 클라이언트에는 `BuildingSettings`가 없으므로 모듈 크기를 `CompositionConfig.building.grid_module_m`에서 받아 `StructureGrid`를 만들어야 한다(서버와 같은 리소스 파일). (3) 미리보기의 유효·무효 표시는 클라이언트가 추정하고 확정은 서버 결과로 한다(사유 코드는 위 목록). (4) 미러에는 누가 지었는지가 없다: 철거 가능 여부는 요청해서 `not_owner`를 받아야 안다. 필요하면 행에 필드를 더한다(프로토콜 변경). (5) 서버 충돌은 점 대 선분이고 캐릭터 반지름이 없다: 캡슐이 벽에 반쯤 묻혀 보일 수 있다. (6) 클라이언트 이동 예측을 넣는다면 `StructureGrid.resolve_step`과 미러의 자리 표(`structure_id_at`)로 같은 계산을 할 수 있다. (7) 구조물 정의에는 아직 모델·재질 정보가 없다.

**P3-5(청사진·자재·완공)가 알아야 할 것**: (1) `BuildingSettings.instant_completion`을 끄면 배치가 `blueprint`(체력 0)를 만든다: 자리를 차지하고 아무것도 막지 않으며 문으로 쓸 수 없다(테스트 있음). 완공으로 바꾸는 함수는 아직 없다: 상태를 바꾼 뒤 `_refresh_blocking`을 불러 막는 변 집합을 갱신하고 `structure_changed` 이벤트를 남기면 복제는 이미 된다(행에 `state`가 있다). (2) 완공 순간에는 배치 때 건너뛴 "사람·좀비가 변 가까이에 있는가" 검사를 다시 해야 한다. (3) `inventory_costs`는 배치 때 정의의 `build_costs`를 복사해 둔 것이다. 투입한 자재·진행률 필드는 없다: 더하면 `StructureInstance.to_dict`/`from_dict`와 셀 문서 스키마 버전(`CELL_SCHEMA_VERSION`, `SCHEMA_VERSION`)을 올리고 구버전 문서를 읽는 경로를 넣는다. (4) 배치·철거와 인벤토리 차감을 한 트랜잭션으로 묶어야 한다: 저장 한 번이 월드 전체라서 둘은 항상 같은 세대에 들어간다. (5) 철거 환급 규칙은 정의에 넣기로 돼 있다(docs/04 §5). (6) 메모리에 없는 셀에는 서버 규칙도 지을 수 없다: 시드로 건물을 놓으려면 그 셀을 먼저 로딩해야 한다.

### 15.5 건축 흐름: 청사진·자재·작업·완공(P3-5, docs/00 ADR-025, system id `building`, 모듈 `StructureNet`)

서버·네트워크·클라이언트 미러까지다. 청사진을 화면에 그리는 것과 건축 모드 입력은 P3-4b다. 보관 상자는 P3-3으로 옮겼다(docs/13 §15). **프로토콜 변경 있음**: RPC 넷이 새로 생기고 구조물 행과 접속 조각의 형식이 바뀌었다. 이 브랜치에서는 `BuildInfo.PROTOCOL_VERSION`(12)을 올리지 않았다(다른 티켓이 `build_info.gd`를 고치고 있다): **병합할 때 13으로 올려야 한다.** 올리기 전의 12 클라이언트는 새 서버의 행(값 11개)을 전부 거부한다.

**정의와 설정**

| 구성 요소 | 계약 |
|---|---|
| `StructureDefinition` | 필드 셋이 늘었다. `build_work_sec`(조작 배율 1인 한 사람이 처음부터 완공까지 걸리는 행동 시간, 0보다 커야 한다), `cancel_refund_percent`·`demolish_refund_percent`(0~100 정수: 짓는 중 취소 / 완공 후 철거 때 **투입된 자재** 중 돌려주는 비율). `build_costs`는 이제 실제 요구량이다(종류 최대 `MAX_COST_KINDS` 8, 종류당 수량 1~`MAX_COST_QUANTITY` 10000). `refund_of(delivered, percent)`: 종류별로 `수량 × 비율 ÷ 100`을 정수로 내림, 0이 되는 종류는 뺀다(100이면 정확히 투입한 만큼). 개발용 정의: `dev_floor` 목재 2·4초, `dev_wall` 목재 4·못 2·8초, `dev_door` 목재 3·못 2·6초, 셋 다 취소 100%·철거 50% |
| 아이템 정의 | `dev_wood`(묶음 20), `dev_nails`(묶음 50). 사용 효과가 없는 일반 아이템이다. 새 월드 시드(`data/tuning/dev_world_seed.tres`)에 목재 20개 묶음 둘과 못 30개가 스폰 지점 근처에 놓인다 |
| `BuildingSettings` | `instant_completion` 기본값이 **false**가 됐다(스크립트 기본값과 `.tres` 모두). 새 값: `deliver_range_m`(2.5), `work_range_m`(2.5), `max_workers_per_structure`(4), `progress_event_step`(0.05: 진행률 이벤트를 남기는 간격), `completion_retry_interval_sec`(0.25: 완공 대기 중인 조각을 다시 보는 주기, 행동 시간) |
| `StructureNetSettings` | 새 값: 배달 빈도(8/s·버스트 16), 작업 빈도(4/s·버스트 8), `persist_on_delivery`(false), `persist_on_completion`(true). 취소는 철거의 빈도 버킷을 같이 쓴다 |

**런타임 모델(`StructureInstance`)**: `construction_progress`(0~1)와 `delivered_materials`(`{아이템 정의 ID: 수량}`)가 늘었다. `inventory_costs`는 "필요한 자재"다. 도우미: `is_under_construction()`(blueprint 또는 constructing), `missing_materials()`, `missing_units(id)`, `material_share()`(투입 단위 수 ÷ 필요 단위 수, 종류 구분 없음, 필요 자재가 없으면 1). 불변식: blueprint는 진행률 0, constructing은 0 초과, 서 있는 조각은 1, 짓는 중의 진행률 ≤ `material_share()`. 서 있는 조각의 `delivered_materials`는 `inventory_costs`보다 적을 수 있다(즉시 완공 스위치나 서버 규칙으로 완공된 조각: 낸 것이 없으니 돌려받을 것도 없다).

**`BuildingService`의 새 요청**(모두 `ActionResult`, 거부되면 아무것도 바뀌지 않는다)

| 요청 | 검사 순서(먼저 걸린 것이 사유) | 성공 이벤트 |
|---|---|---|
| `try_deliver(world, player_id, structure_id, item_instance_id = "", quantity = 0)` | `not_online` → `player_dead`/`player_resting` → `unknown_structure` → `structure_not_under_construction` → `too_far`(서버 위치, `deliver_range_m`) → `materials_complete`(모자란 자재 없음) → 아이템: `item_not_in_inventory`(없는 ID, 바닥의 아이템, 남의 아이템을 한 사유로: ID를 떠볼 수 없게) → `bad_quantity`(0 미만, 묶음보다 많음) → `material_not_needed`(그 종류는 필요 없거나 이미 다 참). `item_instance_id`가 `""`이면 들고 있는 묶음 가운데 필요한 종류를 칸 순서대로 쓴다(`quantity`는 0이어야 하고, 쓸 것이 없으면 `no_materials_carried`) | `structure_changed` `{cause: "materials", delivered_now: {종류: 가져간 수량}}` |
| `try_set_work(world, player_id, structure_id, working)` | 시작: `not_online` → 행동 차단 → `unknown_structure` → `structure_not_under_construction` → `too_far`(`work_range_m`) → `already_working` → `blocked_by_entity`(진행률 100%로 자리가 비기를 기다리는 조각) → `materials_missing`(진행률이 이미 자재 비율에 닿음) → `too_many_workers`. 다른 조각에서 일하던 플레이어는 그 작업을 멈추고 옮긴다(`switched`). 중지: `not_online` → `not_working`(**그 조각에서** 일하고 있지 않음). 요청은 토글이 아니라 원하는 상태다 | `structure_work_started` / `structure_work_stopped {reason: "stopped"}` |
| `try_cancel(world, player_id, structure_id)` | `not_online` → 행동 차단 → `unknown_structure` → `structure_not_under_construction` → `not_owner` → `too_far`(`demolish_range_m`) → `refund_failed` | `structure_removed {cause: "cancelled", refund, refund_item_instance_ids}` |
| `try_demolish`(P3-4a, 바뀜) | `unknown_structure` 다음에 `structure_under_construction`이 들어갔다: 짓는 중인 조각은 철거가 아니라 취소한다. 환급이 붙었다 | `structure_removed {cause: "demolished", refund, ...}` |

- `quantity` 0(`AS_MUCH_AS_NEEDED`)은 "모자란 만큼", `""`(`ANY_CARRIED_ITEM`)은 "들고 있는 것 아무거나"다. 어느 경우에도 **모자란 수량보다 많이 가져가지 않는다.**
- 자재를 넣어도 상태는 `blueprint` 그대로다. 첫 작업 틱에 `constructing`이 된다.
- 취소와 철거를 다른 의도로 나눈 이유: 한 박자 늦은 클라이언트가 "청사진 취소"를 보냈는데 그 사이 완공됐다면 완공된 벽을 반값에 허물게 된다. 문 요청이 토글이 아닌 것과 같은 이유다.
- 서버 규칙(행위자·사거리 없음): `complete_structure(world, structure_id)`(자재·작업과 무관하게 완공, 전부 또는 전무: 변에 누가 있으면 `blocked_by_entity`로 거부하고 그대로 둔다. 건물 시드와 테스트용), `remove_structure(world, structure_id, refund_percent = 0)`, `stop_work(player_id, reason)`.
- 조회: `work_of(player_id)`, `workers_of(structure_id)`(복사본), `worker_rows()`(`[[player_id, structure_id], ...]`, 시작한 순서), `worker_count()`, `awaiting_clearance_count()`.

**작업(`step`)**: `BuildingService`에 `step()`이 생겼다. 행동 시간만 쓴다(`action_delta`, ADR-006: 달력 배율이 1이든 24든 같은 속도이고, 접속자가 없어 시계가 멈추면 아무것도 진행하지 않는다).

- 틱마다, 작업자가 있는 조각마다: 작업자 각각이 계속 일할 수 있는지 본다(월드에 있음 → `player_action_block_reason`이 비어 있음 → 서버 위치가 `work_range_m` 안). 안 되면 그 사유로 그 작업자만 멈춘다. 남은 작업자의 `action_delta × handling_multiplier`(`SurvivalService`, 생존 시스템이 없으면 1)를 더해 `build_work_sec`로 나눈 만큼 진행률을 올린다.
- 진행률은 `material_share()`에서 잘린다. 거기에 닿았는데 100%가 아니면 그 조각의 작업자 전원이 `materials_missing`으로 멈춘다(자재가 들어와도 저절로 다시 시작하지 않는다: 작업 의도를 다시 보내야 한다).
- 100%가 되면 작업자 전원이 `work_finished`로 멈추고 완공을 시도한다.
- 작업자가 멈추는 사유(`structure_work_stopped.reason`): `stopped`(요청), `switched`(다른 조각으로), `too_far`, `player_dead`, `player_resting`, `not_online`(접속 종료: `on_player_offline`에서 즉시), `materials_missing`, `work_finished`, `structure_removed`(취소·철거), `structure_unloaded`(셀 해제), 서버 규칙이 준 사유. 새 캐릭터가 시작돼도 멈춘다(`on_character_started`).
- 작업 중인 플레이어는 움직이거나 다른 행동을 해도 된다(사거리 안에 있는 한 계속 일한다). 엎드린 채로도 일한다. 한 플레이어는 한 번에 한 조각에서만 일한다.
- 진행률 이벤트(`structure_changed {cause: "progress"}`)는 틱마다 남기지 않는다: `constructing`이 된 틱, 마지막으로 남긴 값에서 `progress_event_step` 이상 올랐을 때, 자재가 떨어져 멈출 때, **마지막 작업자가 떠날 때**(그 순간의 정확한 값), 100%인데 완공을 기다리게 될 때. 완공은 `cause: "completed"`로 그 틱에 남긴다.

**완공**: 상태 `completed`, 진행률 1, 체력 = 정의의 `max_health`, 막는 변 집합 갱신. 막는 조각(벽, 닫힌 채로 시작하는 문)은 그 변에서 `blocker_clearance_m` 안에 살아 있는 플레이어나 살아 있는 좀비가 있으면 완공하지 않는다: `constructing`·진행률 1인 채로 남고(`awaiting_clearance_count`), `completion_retry_interval_sec`마다 다시 보아 자리가 비면 저절로 완공된다. 그동안 그 조각에는 작업을 시작할 수 없고(`blocked_by_entity`) 아무것도 막지 않는다. 셀이 내려갔다 올라오거나 서버가 재시작해도 기다리는 상태는 이어진다(저장된 "짓는 중·진행률 1"에서 다시 만든다). 바닥처럼 막지 않는 조각은 기다리지 않는다.

**환급**: `StructureDefinition.refund_of(delivered_materials, percent)`만큼을 `InventoryService.place_world_items`로 **그 조각의 자리 이름이 된 타일의 중심**(`StructureGrid.slot_home`: 항상 그 조각의 셀 안)에 놓는다. 종류마다 `max_stack`을 넘지 않게 여러 묶음으로 나눈다. 환급을 먼저 만들고 그다음에 조각을 없앤다: 환급이 실패하면(`refund_failed`) 아무것도 바뀌지 않는다. 환급된 아이템은 보통의 월드 아이템이다: 셀 색인에 들어가고, 누구나 주울 수 있고, 셀과 함께 저장된다.

**인벤토리 트랜잭션 둘**(티켓 밖의 구조 변경, `InventoryService`):

- `take_items(inventory_id, takes) -> ActionResult`: `takes`는 `[{item_instance_id, quantity}]`. 한 인벤토리의 여러 묶음에서 단위를 한 번에 뺀다(전부 또는 전무). 비워진 묶음은 삭제되고 ID가 은퇴한다. 이벤트 `items_taken {inventory_id, taken: [{item_instance_id, definition_id, quantity, remaining_quantity}]}`. 빠진 단위는 더는 아이템이 아니다: 부른 쪽이 수량을 기억한다. `InventoryNetModule`은 이 이벤트를 모른다(복제도 저장 예약도 하지 않는다): `StructureNetModule`이 소유자에게 알린다.
- `place_world_items(quantities, cell_id, position) -> ActionResult`: 인벤토리에서 나오지 않은 새 아이템을 월드에 놓는다(`{정의 ID: 수량}`, 정의 ID 순, 묶음 크기대로 나눔, 전부 또는 전무). 이벤트는 `items_dropped`이고 `inventory_id`가 `""`이며 `placed: [{item_instance_id, definition_id, quantity}]`가 더 붙는다. 그래서 `InventoryNetModule`이 수정 없이 내려놓은 아이템과 똑같이 모든 접속자에게 알린다.
- 두 트랜잭션 모두 `transaction_committed`로 나가므로 `TradeService`의 제안 재조정(§14.30)이 불린다. 거래 중에 제안에 올린 묶음을 청사진에 넣는 경우는 시험하지 않았다(docs/15 §15.5).

**월드 셀과 저장 배치**: 문서 스키마 2(`SCHEMA_VERSION`, `CELL_SCHEMA_VERSION`), 구조물 문서의 새 필드는 docs/14 §3. 스키마 1(`SCHEMA_VERSION_P3_4A`) 문서는 읽을 때 올린다. 복구 검증에 "상태·진행률·자재가 서로 맞는가"가 더해졌다(틀리면 그 문서 전체를 거부). 셀이 내려갈 때 그 셀의 조각에서 일하던 작업자는 멈춘다(실제로는 그 전에 `too_far`로 멈춘다: 작업 사거리 2.5m, 셀 해제는 플레이어에게서 먼 셀). 누가 일하는지는 어디에도 저장하지 않는다.

**저장 시점과 서버가 죽었을 때**(docs/00 ADR-025)

| 일 | 저장 |
|---|---|
| 배치, 취소, 철거 | 승인 즉시(`persist_on_place_and_demolish`). 환급이 있으면 `InventoryNetModule`이 예약한 저장을 당겨 써서 한 번만 쓴다 |
| 완공 | 그 틱의 끝에 한 번(`persist_on_completion`) |
| 자재 배달 | 따로 저장하지 않는다(`persist_on_delivery` 기본 false) |
| 작업 시작·중지, 진행률 | 저장하지 않는다(설정도 없다) |

- 저장 한 번은 월드 전체 한 세대다(world_state, 플레이어 전원, 메모리에 있는 셀 전부). 배달은 한 호출 안에서 인벤토리와 구조물을 같이 바꾸고 그 사이에 저장이 끼어들 수 없으므로, **어떤 세대에도 자재가 두 곳에 다 있거나 어느 쪽에도 없는 일이 없다.**
- 저장 사이에 서버가 죽으면: 그 사이의 배달은 없던 일이 되고(자재는 인벤토리에 있다), 그 사이의 진행률은 사라지고, 그 사이에 시작된 완공 대기는 "100%가 되기 전"으로 돌아간다. 배치·취소·철거·완공 자체는 저장된 뒤라 남는다.
- 환급된 자재는 "아이템 내려놓기"와 같은 이벤트라서 `InventoryNetModule`이 그 틱의 끝에 저장한다. `persist_on_place_and_demolish`를 꺼도 환급이 있는 취소·철거는 저장된다.

**네트워크(`StructureNetModule`)**: 전부 채널 0(`CHANNEL_RELIABLE`), reliable ordered(§15.4와 같은 이유).

| 방향 | RPC | 내용 |
|---|---|---|
| C→S | `_rpc_request_deliver(request_id:int, structure_id:String, item_instance_id:String, quantity:int)` | 자재 배달 의도. `item_instance_id` `""` = 들고 있는 것 중 필요한 것 전부, `quantity` 0 = 모자란 만큼 |
| C→S | `_rpc_request_work(request_id:int, structure_id:String, working:bool)` | 그 조각에서 일하겠다(true) / 그만두겠다(false) |
| C→S | `_rpc_request_cancel(request_id:int, structure_id:String)` | 짓는 중인 조각 취소 |
| S→전체 | `_rpc_work_changed(player_id:String, structure_id:String, working:bool, reason:String)` | 누가 어느 조각에서 일하기 시작했다 / 멈췄다. `reason`은 시작일 때만 `""` |
| S→요청자 | `_rpc_structure_result`(P3-4a 그대로) | 새 의도 셋의 답도 이것으로 간다. `structure_id`는 승인일 때 그 조각 |
| S→전체 | `_rpc_structure_rows`(**형식 바뀜**) | 행이 값 11개가 됐다 |

- 행: `[structure_id, definition_id, x, z, rotation, state, door_open, health_fraction, progress:float, delivered:Dictionary, required:Dictionary]`. `required`는 `{아이템 정의 ID: 수량 1~10000}`(최대 8종류), `delivered`는 그 일부(같은 키 또는 더 적은 키, 수량은 `required` 이하).
- 접속 조각: `{schema_version: 2, structures: [행, ...], workers: [[player_id, structure_id], ...]}`. 작업자는 조각에 든 구조물만 가리킨다.
- 의도 검증: §15.4의 순서 그대로이고 모양 검사에 `bad_item_id`(아이템 ID 64자 초과), `bad_quantity`(0 미만 또는 10000 초과: 64비트 수로 비교한 뒤에 규칙에 넘긴다)가 더해졌다. 빈도는 배달·작업이 각자의 버킷, 취소는 철거 버킷이다.
- 진행률은 틱마다 보내지 않는다: `BuildingService`가 남긴 이벤트 하나가 행 하나다(위 "작업"의 진행률 이벤트 규칙). 완공과 상태 변화는 그 틱에 간다. 작업자가 남아 있는 동안 미러의 진행률은 최대 한 단계(5%)만큼 서버보다 뒤처질 수 있고, 마지막 작업자가 멈추면 정확한 값이 간다.
- 자재를 넣은 플레이어의 인벤토리: 서버가 `InventoryService.transaction_committed`의 `items_taken`을 듣고, **그 인벤토리의 주인에게만** `InventoryNetModule`의 기존 메시지(`_rpc_inventory_item_changed`, `_rpc_inventory_items_removed`)를 보낸다. 다른 접속자는 남의 인벤토리에 대해 아무것도 받지 않는다(구조물 행의 `delivered`만 본다). 두 메시지는 이름으로 부른다(`inventory_net_module.gd`가 다른 티켓 소유라서: `WorldCellNetModule`과 같은 방식). 순서는 인벤토리 변화 → 구조물 행 → 요청 결과다.
- 환급된 아이템: `InventoryNetModule`이 기존 `_rpc_world_items_added`로 모든 접속자에게 보낸다(이 모듈은 아무것도 하지 않는다).
- 셀이 내려갈 때는 그 셀의 조각에서 일하던 작업자의 중지를 먼저 보내고 그다음에 제거를 보낸다.
- 진단 값: `sent_work_change_count`, `sent_message_count`(행·제거·작업 변화 메시지 수, 받는 사람 수와 무관하게 메시지 하나를 한 번 센다).

**정보 공개**(ADR-009): 모든 접속자가 받는 것은 상태, 진행률, 투입된 자재와 필요한 자재, 누가 그 조각에서 일하는지와 왜 멈췄는지다. 보내지 않는 것은 누가 배치했는지(P3-4a 그대로), 누가 무엇을 얼마나 넣었는지, 남의 인벤토리다.

**클라이언트 미러(`ClientStructureState`)**: 항목에 `progress`, `delivered`, `required`가 늘었다. `workers`(`player_id -> structure_id`), `work_of(player_id)`, `workers_of(structure_id)`, 시그널 `work_changed(player_id, structure_id, working, reason)`, `apply_work_change(...)`. 검증: 진행률 0~1의 유한한 float, 자재 사전의 키·값·개수·`delivered ⊆ required`, 작업 변화의 ID 형식과 "시작이면 사유 없음"·"시작은 미러에 있는 구조물에만". 미러에 없는 작업자에 대한 중지는 오류가 아니다(`unknown_work_stop_count`). 구조물이 제거되면 그 작업자도 미러에서 빠진다(`reason: "structure_removed"`). 클라이언트 API: `request_deliver(structure_id, item_instance_id = "", quantity = 0)`, `request_work(structure_id, working)`, `request_cancel(structure_id)`(요청 번호를 돌려준다. 답은 `structure_result`).

**테스트**: `tests/unit/building_construction_test.gd`(정의의 비용·작업량·환급 검증, 개발용 정의와 새 월드의 자재, 청사진, 배달: 필요한 만큼만·한 번에 전부·거부 사유 전부·여러 사람, 진행률 상한, 행동 시간·조작 배율·작업자 합산, 작업 거부 사유, 작업이 멈추는 모든 사유, 여러 작업자가 한 틱에 멈춤, 상태 전이와 이벤트 수, 변에 누가 서 있을 때의 완공, 취소·철거 환급과 수량 보존, 즉시 완공 스위치, 서버 규칙), `building_construction_save_test.gd`(새 필드의 저장 형식, P3-4a 문서 올리기, 짓는 중에 셀 해제 → 재로딩, 월드 문서 왕복, 복구 검증), `structure_construction_state_test.gd`(미러 검증), `construction_measure_test.gd`(측정값 출력), `tests/integration/construction_net_test.gd`(한 사람이 놓고 다른 사람이 자재를 넣고 둘이 지어 두 미러가 같은 벽을 봄, 위조 요청, 빈도 제한, 늦은 접속, 짓는 중 셀 해제·재로딩, 실제 파일로 저장 → 재시작 → 복구와 "지금 죽으면 디스크에 남는 것", 환급 아이템이 클라이언트에 나타남). 지원 코드: `tests/framework/construction_test_kit.gd`(테스트 전용 자재·구조물 정의: 개발용 수치를 조정해도 테스트 기대값이 바뀌지 않게).

**P3-4b(클라이언트 표시·건축 모드 입력)가 알아야 할 것**

1. 청사진·짓는 중·완공은 미러 항목의 `state`로 구분한다. 진행 표시줄은 `progress`, 자재 표시는 `required`와 `delivered`(모자란 것 = 차이), "자재 대기 중"은 `state`가 `blueprint`/`constructing`이고 `progress`가 `delivered` 합 ÷ `required` 합과 같을 때, "누가 서 있어서 완공 대기 중"은 `constructing`인데 `progress`가 1일 때다. 값이 바뀌면 `structure_changed(id)`가 온다.
2. 진행률은 5% 단계로 온다(작업자가 없으면 정확한 값). 부드럽게 보이려면 화면에서 보간한다.
3. 보낼 것: 자재 넣기는 `request_deliver(id)` 하나면 된다(들고 있는 것 중 필요한 것을 서버가 고른다). 묶음을 골라 넣으려면 `request_deliver(id, item_instance_id, quantity)`. 작업은 `request_work(id, true)` 한 번이고 서버가 멈출 때까지 이어진다(키를 누르고 있을 필요가 없다. 누르고 있는 동안만 일하게 하려면 뗄 때 `request_work(id, false)`를 보낸다). 취소는 `request_cancel(id)`, 완공된 조각은 `request_demolish(id)`: 서로 바꿔 보내면 `structure_not_under_construction`/`structure_under_construction`으로 거부된다.
4. 내 작업 상태는 `client_state.work_of(내 player_id)`와 `work_changed`로 안다. 멈춘 사유(`reason`)를 HUD에 보여 줄 수 있다. 다른 플레이어의 작업 모션도 같은 정보로 그린다.
5. 내 인벤토리는 평소대로 `NetworkService.client_state.inventory`가 갱신된다(`InventoryNetModule.inventory_item_changed`/`inventory_items_removed`). 환급된 자재는 `world_items`에 나타난다(P2-T15의 바닥 아이템 표시가 그대로 그린다).
6. 미러에는 여전히 누가 놓았는지가 없다: 취소·철거가 되는지는 요청해서 `not_owner`를 받아야 안다(§15.4와 같다).
7. 사거리는 서버 값이다(자재·작업 2.5m, 취소·철거 4m). 클라이언트 표시는 `CompositionConfig.building`의 같은 리소스에서 읽으면 된다. 기준점은 §15.4의 `slot_anchor`다.
8. 개발용 정의에는 아직 모델·재질이 없다(§15.4와 같다). 청사진을 반투명으로 그리는 것 등은 표시 쪽이 정한다.
