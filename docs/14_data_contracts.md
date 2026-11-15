# 14. 데이터 모델 및 시스템 간 계약

## 1. 공통 ID 규칙

- 영속 엔티티 ID는 UUID 또는 안정적인 문자열 ID.
- 정의 ID는 사람이 읽기 쉬운 snake_case.
- 런타임 인스턴스 ID와 정적 정의 ID를 구분한다.
- 삭제된 ID를 재사용하지 않는다.

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

### ItemInstance
`item_instance_id`, `definition_id`, `quantity`, `condition`, `quality`, `freshness`, `location_type`, `location_id`, `slot_id`.

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
