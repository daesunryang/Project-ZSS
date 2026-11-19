# P4-1 NPC 정체성 작업 기록

브랜치 `p4-1-npc-identity`, 기준 main `5f25267`. 계약은 docs/09 §17.1, 임시 가정은 docs/15 §17.1(P4-001~P4-022).

## 2026-11-19

조정자 지시(원문):

> Do exactly the P4-1 row: NPC definitions (Resources), runtime NpcState with stable ids, the NPC ServerSystem with the component contract the plan describes (so later tickets add components without editing NpcState), dev NPCs (5, D1/D5) seeded once per world into test-map buildings, cell-document persistence (save → unload/reload → restart → identical, ids unique, no re-seeding), and no AI behaviour yet (NPCs stand still; that is P4-3/P4-4). Replication to clients is P4-7: not in this ticket.

이번 작업에서 정한 것:

- **구성 요소(`NpcComponent`)와 단계(`NpcStage`) 둘로 나눴다.** 계획(docs/13 §16.2)은 "`NpcComponent`와 `NpcService`가 받는 주입 지점(욕구 모델, 스케줄러, 결정 함수, 실행기)"이라고만 적었다. NPC 한 명과 함께 저장되는 상태는 구성 요소, 틱마다 도는 일(스케줄러·실행기)은 단계로 받는다. 결정 함수는 스케줄러(P4-3)가 주입받는 것이라 `NpcService`에는 자리를 두지 않았다. `npc_stage.gd`는 계획의 파일 목록에 없던 파일이다.
- **`npc_catalog.gd`, `npc_roster.gd`도 계획에 없던 파일이다.** 정의를 ID로 찾는 목록과 "월드마다 한 번 배치하는 명단"이 필요해서 더했다(보관함의 `ContainerCatalog`, 맵의 `MapContentDefinition`과 같은 역할). 명단은 `resources/definitions/npcs/rosters/`에 둔다: 카탈로그가 하위 폴더를 읽지 않아 정의와 섞이지 않는다.
- **집·작업 지점은 "맵 건물 ID + 건물 안 타일"로 적는다.** D7의 NPC 지점 데이터는 P4-5a·P4-5b 몫이라, 지금은 정의가 맵 건물을 직접 가리킨다. 그래서 명단은 맵 콘텐츠가 있어야 검증을 통과한다.
- **NPC는 셀 문서에 저장한다.** docs/10 §3에는 `npcs/<npc_id>.json`이 있지만, 티켓 표가 "셀 문서 `systems.npc`"라고 적었고 좀비·보관함과 같은 길이어야 셀 해제·복구가 한 규칙으로 돈다. docs/10은 고치지 않았다(조정자가 정한 문서 범위 밖). docs/15 P4-012에 적었다.
- **월드 명부(`population`)를 world_state에 둔다.** 상한(D1)을 월드 전체로 세려면 메모리에 없는 셀의 NPC 수를 알아야 한다. 수만 적으면 어긋났을 때 고칠 근거가 없어서 `npc_id -> definition_id` 표로 두었다. 셀 위치는 적지 않는다(경계를 넘을 때마다 고쳐야 하고 격자가 바뀌면 틀린다).
- **`simulation_tier`는 저장하지 않는다.** 셀 상태와 플레이어 거리에서 매번 정해지는 값이다. 저장하면 "저장 뒤 복구가 같다"(D11) 비교에서 저장 시점에 따라 달라진다.
- **`last_simulated_world_time`의 뜻**: 멈출 때의 달력 시각. 깨어 있는 NPC는 문서를 만들 때 "지금"을 적는다. 매 틱 갱신하지 않으려는 것이고(빈 틱 비용 0), 같은 달력 시각의 문서가 저장·재시작 여부와 무관하게 같아지게 하려는 것이다. 그래서 테스트의 "같다" 비교는 이 키를 빼고 하고, 이 키는 따로 검사한다.
- **등록되지 않은 구성 요소·단계의 문서는 버리지 않는다.** 2단계 티켓 넷이 따로 병합되므로, 한 브랜치의 서버로 만든 저장을 다른 브랜치의 서버가 열었다 닫아도 데이터가 남아야 한다.
- **구성 요소는 첫 NPC 전에만 등록된다.** 나중에 등록하면 이미 있는 NPC에게 그 구성 요소가 없는 상태가 생긴다. 조립 때 한 번에 하게 막았다.
- **NPC 이벤트는 큐가 아니라 시그널이다.** 소비자가 없는 큐는 쌓이기만 한다. P4-7은 좀비처럼 대조 방식으로 계획돼 있다.
- **소유 영역 밖 변경 셋**: `WorldPersistence.load_or_create`에 명단 `ensure_seeded` 호출(맵 콘텐츠와 같은 자리, 없으면 기존 저장에 NPC가 영영 생기지 않는다), `GameBootstrap`에 명단 넣기, `server_system_seam_test.gd`의 시스템 순서 목록.
- **테스트를 먼저 썼다.** `npc_state_test.gd`와 `npc_cell_persistence_test.gd`를 구현 전에 쓰고 돌려 실패를 봤다(그때의 실패는 클래스가 없어 스크립트가 로딩되지 않는 것이었다: `Could not find base class "NpcComponent"`). 구현 뒤 실패 셋은 테스트 쪽 잘못이었다(플레이어 문서를 빼고 복구함, ID 순번을 접속 전에 읽음). `WorldPersistence`의 호출을 잠깐 꺼서 "명단 전의 디스크 저장" 테스트가 실제로 실패하는 것도 확인했다.
- **재지 않은 것**: 성능(문서 생성 시간, 단계 시간). 측정 테스트는 P4-Z다.
