# 14. 데이터 모델 및 시스템 간 계약

## 1. 공통 ID 규칙

- 영속 엔티티 ID는 UUID 또는 안정적인 문자열 ID.
- 정의 ID는 사람이 읽기 쉬운 snake_case.
- 런타임 인스턴스 ID와 정적 정의 ID를 구분한다.
- 삭제된 ID를 재사용하지 않는다.
- `cell_id`(P3-1 임시안, docs/00 ADR-023): 월드 셀의 안정적인 ID. 형식은 `cell_<cx>_<cz>`이고 `cx`·`cz`는 셀 좌표(부호 있는 정수, 앞자리 0 없음. 예: `cell_-3_12`). 셀 좌표는 `floor(월드 좌표 / 셀 크기)`이므로 같은 셀 크기에서는 맵 경계가 바뀌어도 ID가 같다. 저장 파일 이름(`cells/<cell_id>.json`)과 월드 아이템의 `location_id`에 쓴다. 셀 크기가 바뀌면 같은 ID가 다른 영역을 가리키므로 저장을 새 격자로 다시 나눈다(docs/10 §6).
- 셀이 메모리에서 내려가도 그 안의 엔티티 ID는 은퇴(tombstone)하지 않는다: 엔티티는 저장 안에 그대로 있고, 다시 로딩되면 같은 ID로 돌아온다. ID 순번(`next_entity_sequence`)은 world_state에 있으므로 메모리에 없는 엔티티의 ID가 새로 발급되는 일은 없다.

## 2. 공통 타임스탬프

- `created_at_world_time`, `updated_at_world_time`는 월드 시간 단위.
- 운영 로그에는 UTC 실제 시간을 별도로 저장할 수 있다.
- 두 시간 체계를 혼동하지 않는다.

## 3. 핵심 엔티티 계약

### PlayerState
`player_id`, `peer_id`(런타임 연결 정보), `position`, `rotation`, `health`, `injuries`, `needs`, `infection`, `inventory_id`, `shelter_membership`, `last_saved_at`, `character_generation`(P2-T4 임시안: 같은 `player_id`의 몇 번째 캐릭터인지. 첫 캐릭터 1, 영구 사망 뒤 새 캐릭터마다 +1. docs/09 §14.19), `character`(P2-T9 임시안: 현재 캐릭터의 `CharacterProfile`, 아직 캐릭터를 만든 적이 없으면 null. null은 세대 1에서만 가능하다. 죽은 캐릭터의 값은 새 캐릭터가 만들어질 때까지 남는다. docs/09 §14.24).

플레이어 파일(players/<id>.json) 스키마는 v4다: v2 `systems`, v3 `character_generation`, v4 `character`. `character`가 null인 접속자는 월드 밖이다(다른 플레이어에게 보이지 않고 행동할 수 없다).

### CharacterProfile (동적, PlayerState의 일부)
`name`(서버가 이름 규칙으로 정리·검증한 문자열, 1~64자), `appearance`(`{slot_id: option_id}`: 외형 항목마다 고른 선택지의 안정된 ID. 색도 팔레트의 선택지 ID이며 임의 RGB는 저장하지 않는다). 다른 플레이어에게 공개되는 정보다(이름과 외형은 관찰 가능한 사실, docs/00 ADR-009).

### AppearanceSlot / AppearanceOption (정적)
`slot_id`, `display_name`, `sort_order`, `kind`(`style`/`color`/`scale`), `visual_role`(임시 캡슐에 나타나는 방식, 비어 있으면 아직 표시 불가), `default_option_id`, `options`[`option_id`, `display_name`, `color`, `scale`]. `resources/definitions/appearance/*.tres`에 항목 하나당 파일 하나. 항목과 선택지는 파일만 고쳐서 늘린다. ID는 저장과 전송에 쓰이므로 바꾸지 않는다. 없어진 ID를 가진 저장은 기본 선택지로 읽는다.

### NPCDefinition (정적)
`npc_definition_id`, 외형/초기 특성/기본 능력/시작 장비/배경 태그.

### NPCState (동적)
`npc_id`, `definition_id`, `identity`, `skills`, `personality`, `needs`, `emotions`, `health`, `memories`, `relationships`, `goals`, `job`, `knowledge`, `location`, `simulation_tier`, `rng_state`.

### RelationshipState
`source_entity_id`, `target_entity_id`, `trust`, `liking`, `respect`, `fear`, `resentment`, `attraction`, `jealousy`, `dependence`, `status`, `last_interaction_time`.

source/target 순서는 의미가 있다. A→B와 B→A를 별도 레코드로 저장한다.

### WorldEvent
`event_id`, `event_type`, `world_time`, `location`, `participants`, `witnesses`, `cause_event_ids`, `evidence_ids`, `visibility`, `payload`, `seed`, `sequence_number`.

### BuildingInstance
`structure_instance_id`, `definition_id`, `shelter_id`, `cell_id`, `transform`, `state`, `health`, `construction_progress`, `owner_permissions`, `connections`.

P3-4a 임시안(docs/00 ADR-024, docs/09 §15.4): 구현된 구조물 문서(`StructureInstance`)는 docs/04 §4의 필드 이름을 쓴다. 위 목록과 `schemas/building_instance.schema.json`(초안)과는 이름이 다르다(`structure_id` ↔ `structure_instance_id`, `construction_state` ↔ `state`, `owner_shelter_id` ↔ `shelter_id`, 격자 좌표 ↔ 미터 좌표). 어느 쪽을 기준으로 할지는 미결정이다(docs/15 P3-117). `construction_progress`와 `owner_permissions`는 아직 없다(P3-5, 쉘터).

구조물 하나(셀 문서와 world_state의 `systems.building.structures[]` 항목):

| 필드 | 타입 | 뜻 |
|---|---|---|
| `structure_id` | 문자열 `structure_<번호>` | 월드에서 유일하고 재사용하지 않는 ID. 철거되면 은퇴(tombstone)한다 |
| `definition_id` | snake_case 문자열 | `StructureDefinition`의 ID. 저장에 정의 Resource는 들어가지 않는다 |
| `owner_shelter_id` | 문자열 | 쉘터가 생길 때까지 `""` |
| `cell_id` | 문자열 | 저장할 때의 월드 셀. 읽을 때는 참고만 하고 자리로 다시 정한다 |
| `transform` | `{tile: [x, z], rotation: 0~3}` | 격자 좌표(정수 타일)와 1/4바퀴 회전. 미터가 아니다 |
| `construction_state` | `blueprint`/`constructing`/`completed`/`damaged`/`destroyed` | P3-4a에서는 `completed`만 생긴다(임시 규칙을 끄면 `blueprint`) |
| `health` | 0 이상, 정의의 `max_health` 이하 | |
| `material_quality` | 0 이상 | 지금은 항상 1.0 |
| `inventory_costs` | `{아이템 정의 ID: 수량(1 이상)}` | 정의의 비용을 기록한 것. 차감 여부를 뜻하지 않는다 |
| `connections` | 구조물 ID 배열 | 지금은 항상 `[]` |
| `last_modified_at` | 숫자 | 마지막으로 바뀐 달력 월드 시간(§2) |
| `placed_by` | 문자열 | 배치한 플레이어의 `player_id`, 서버 규칙이 놓았으면 `""` |
| `door_open` | bool | 문만 true가 될 수 있다 |
| `container_id` | 문자열 `container_<번호>` 또는 `""` | P3-3b: 완공 때 이 구조물이 만든 보관함. 구조물이 링크의 수명 주인이다. 청사진과 보통 구조물은 `""` |

`systems.building` 문서는 `{schema_version: 1, structures: [...]}`다. 구조물이 없으면 문서 자체가 없다. Node 참조·RID는 들어가지 않는다.

P3-5 임시안(docs/00 ADR-025, docs/09 §15.5): `systems.building` 문서의 스키마가 **2**가 됐다(`{schema_version: 2, structures: [...]}`, 셀 문서와 world_state 양쪽). 구조물 하나에 필드 둘이 늘었다. 위 목록의 `construction_progress`가 이것이고(`owner_permissions`는 여전히 없다), 위 표의 `inventory_costs`는 이제 "그 조각이 필요로 하는 자재"다.

| 필드 | 타입 | 뜻 |
|---|---|---|
| `construction_progress` | 0~1 | 작업이 된 비율. `blueprint`는 0, `constructing`은 0 초과, 서 있는 조각(`completed`, `damaged`)은 1. 짓는 중에는 투입된 자재의 비율(`delivered_materials`의 단위 수 합 ÷ `inventory_costs`의 단위 수 합)을 넘지 않는다 |
| `delivered_materials` | `{아이템 정의 ID: 수량(1 이상)}` | 플레이어가 그 조각에 넣은 자재. 키는 `inventory_costs`의 키 중 일부이고 수량은 그 값 이하다. 넣은 것이 없으면 `{}`. 취소·철거의 환급은 이 값의 일부다. 자재는 아이템 인스턴스가 아니라 수량으로만 남는다(넣은 아이템의 ID는 은퇴한다) |

스키마 1 문서(P3-4a)는 그대로 읽는다: 필드가 없는 구조물은 서 있으면 `construction_progress` 1, 아니면 0, `delivered_materials`는 `{}`로 올린다(`StructureInstance.upgrade_v1_entry`). 다음 저장부터 스키마 2로 쓴다. 스키마 2 문서에 두 필드가 없으면 깨진 문서로 보고 그 셀을 로딩하지 않는다. 상태·진행률·자재가 서로 맞지 않는 구조물(작업이 된 청사진, 진행률 0인 `constructing`, 진행률이 1이 아닌 서 있는 조각, 자재 비율보다 큰 진행률)이 든 문서도 같다. 누가 작업 중인지는 저장하지 않는다.

P3-3b의 `container_id`는 기존 스키마 2 문서와 호환되는 선택 필드다. 없으면 `""`로 읽고 다음 저장부터 쓴다. 전선 구조물 행에는 넣지 않는다.

### ContainerInstance (보관함, P3-3 임시안)
docs/00 ADR-026, docs/09 §15.3. 보관함 하나(셀 문서와 world_state의 `systems.containers.containers[]` 항목):

| 필드 | 타입 | 뜻 |
|---|---|---|
| `container_id` | 문자열 `container_<번호>` | 월드에서 유일하고 재사용하지 않는 ID |
| `definition_id` | snake_case 문자열 | `ContainerDefinition`의 ID. 저장에 정의 Resource는 들어가지 않는다 |
| `cell_id` | 문자열 | 저장할 때의 월드 셀. 읽을 때는 참고만 하고 위치로 다시 정한다 |
| `position` | `[x, y, z]` 유한한 숫자 | 월드 좌표(미터) |
| `inventory_id` | 문자열 `inventory_<번호>` | 내용물이 든 보관함 전용 인벤토리의 ID(플레이어 인벤토리 목록에는 없다) |
| `slot_count` | 1 이상의 정수 | 묶음 칸 수(만들 때의 정의 값) |
| `loot_table_id` | 문자열 | 첫 수색 때 굴릴 `LootTable`의 ID, `""` = 없음 |
| `searched` | bool | 한 번 루팅이 굴려졌으면(또는 테이블이 없으면) true. 다시 false가 되지 않는다 |
| `source_key` | 문자열 | 맵 콘텐츠가 놓았으면 `"<map_id>/<building_id>/<번호>"`, P3-3b 구조물이 만들었으면 `"structure/<structure_id>"`, 키 없는 서버 규칙이면 `""` |
| `created_at` | 숫자 | 만든 달력 월드 시간(§2) |
| `loot_seed` | 0 ~ 2^53-1 정수 | 만들 때의 월드 루팅 시드. 내용물은 이 값과 `container_id`로 정한다 |
| `structure_id` | 문자열 `structure_<번호>` 또는 `""` | P3-3b: 이 보관함을 만든 구조물의 역참조. 테스트 맵의 시드 보관함은 `""` |
| `items` | `ItemInstance` 배열 | 안에 든 아이템(칸 순서). 각 아이템의 `location_type`은 `inventory`, `location_id`는 위의 `inventory_id`, `slot_id`는 `slot_<0..slot_count-1>` |

`systems.containers` 문서는 `{schema_version: 1, containers: [...]}`다(셀 문서와 world_state가 같은 모양). 보관함이 없으면 문서 자체가 없다. 수색 중·열림 같은 세션 상태는 저장하지 않는다. 보관함 안의 아이템은 world_state의 `inventory` 스냅샷에 들어가지 않는다(한 아이템은 저장의 한 곳에만 있다).

P3-3b의 `structure_id`는 기존 스키마 1 문서와 호환되는 선택 필드다. 없으면 `""`로 읽고 다음 저장부터 쓴다. 공개 보관함 행에는 넣지 않는다.

맵 시드 기록(world_state `systems.map_content`): `{schema_version: 1, maps: {<map_id>: {content_version: 정수, buildings: [놓은 building_id...], complete: bool}}}`. 시드한 적이 없으면 문서가 없다.

### ItemInstance
`item_instance_id`, `definition_id`, `quantity`, `condition`, `quality`, `freshness`, `location_type`, `location_id`, `slot_id`.

P3-1 임시안: `location_type`이 `world`인 아이템의 `location_id`는 그 아이템이 놓인 위치의 `cell_id`다(P3-1 전에는 모든 아이템이 `cell_0_0`이었고, 그런 저장은 읽을 때 위치로 다시 정한다). 월드 아이템은 world_state.json이 아니라 그 셀의 문서에 저장된다.

### WorldCellDocument (cells/<cell_id>.json, P3-1 임시안)
`schema_version`(1), `cell_id`, `world_items`(`items`: 그 셀에 놓인 ItemInstance 배열, `world_item_positions`: `{item_instance_id: [x, y, z]}`. 없으면 `{}`), `systems`(`{system_id: 그 시스템의 셀 문서}`. 지금은 `zombie`: `{schema_version: 1, zombies: [ZombieState]}`와 P3-4a의 `building`: `{schema_version: 1, structures: [BuildingInstance 절의 구조물 문서]}`, P3-3의 `containers`: `{schema_version: 1, containers: [ContainerInstance 절의 보관함 문서]}`). 플레이어는 셀 문서에 들어가지 않는다. 시스템이 셀에 두는 엔티티(보관함, 구조물)는 `systems` 아래에 같은 방식으로 더한다(docs/09 §15.1).

### CropInstance
`crop_instance_id`, `crop_definition_id`, `plot_id`, `growth_progress`, `water_level`, `health`, `planted_at`, `harvest_state`.

### AnimalState
`animal_id`, `species_id`, `age`, `health`, `needs`, `stress`, `infection`, `relationship_scores`, `pen_id`, `production_state`, `rng_state`.

## 4. 이벤트 계약

이벤트는 과거형이며 불변 기록으로 취급한다. 예: `item_stolen`, `npc_rescued`, `relationship_changed`, `npc_infected`, `animal_attacked`, `building_destroyed`.

이벤트 핸들러는 중복 수신에 안전하도록 `event_id` 또는 sequence 기반 idempotency를 구현한다.

## 5. 명령/이벤트 분리

- Command: 요청/의도. 예: `RequestBuild`, `RequestPickupItem`, `AssignNpcJob`.
- Event: 서버가 성공적으로 발생시킨 사실. 예: `BuildingPlaced`, `ItemPickedUp`, `NpcJobAssigned`.
- Command는 실패할 수 있다. Event는 이미 승인된 사실이다.

## 6. 서비스 책임 경계

| 서비스 | 소유하는 상태 | 주요 입력 | 주요 출력 |
|---|---|---|---|
| InventoryService | 인벤토리/아이템 위치 | pickup/use/transfer/craft | ItemMoved/Consumed |
| BuildingService | 구조물/건설 | place/build/repair/destroy | BuildingChanged |
| NpcSimulationService | NPC AI 실행 상태 | tick/event/goal | NpcAction/StateChanged |
| RelationshipService | 관계 축/단계 | social interaction | RelationshipChanged |
| EventService | 사건 원장 | domain events | persisted events |
| WorldService | 셀/시간/환경 | streaming/time | cell/world state |
| SaveService | 저장 스냅샷 | save/load request | persistence result |
| NetworkService | 연결/권한/복제 | client intents | validated replication |

## 7. 설정 값

밸런스 수치는 코드에 하드코딩하지 않는다. 가능한 경우 Resource/config로 분리하고, 변수 이름/단위/범위/기본값/설명/튜닝 담당을 문서화한다.
