# P4-5a NPC 행동 실행 계층 작업 기록

브랜치 `p4-5a-npc-executor`, 기준 main `281d1aa`. 계약은 docs/09 §17.7, 임시 가정은 docs/15 §17.7(P4-181~P4-210).

## 2026-11-19

사용자 지시(docs/13 §16에 옮겨져 있는 원문): "지금부터 쭉 작업을 진행하고 마지막에 수치랑 규칙 조정을 하자", "에이전트들 활용많이해서 빠르게 해". 그래서 아래 수치·규칙은 전부 임시 기본값이고, 사용자가 정한 것은 아직 없다.

조정자 지시(원문 일부):

> movement executor reusing `NavigationService.begin_search` with an NPC-only FIFO and per-tick node budget, path waypoints, one `ServerWorld.resolve_movement` per step; closed doors: add a path-search option "doors are passable" to `GridPathSearch` (default off, zombies unchanged), open the door in front through `BuildingService.set_door_open` and close it after passing; spot reservations (bed, work, water: one NPC per spot, release rules on completion/failure/NPC sleep/removal); failure reason codes for path failure, target gone, reservation conflict. Save in-progress action state and remaining waypoints in your own `NpcComponent` (e.g. id `executor`) so it continues without replanning after restore.

> Report completion/failure to the decision layer with `scheduler.request_interrupt(npc_id, "action_done")` / `"action_failed:<code>"` (reason names snake_case; check `npc_scheduler.gd` for allowed characters).

이번 작업에서 정한 것:

- **실패 사유는 `action_failed_<code>`다(지시의 `action_failed:<code>`와 다르다).** 스케줄러의 사유 이름은 `NpcComponent.is_valid_id`(`^[a-z][a-z0-9_]*$`, 64자)만 받아서 `:`를 쓸 수 없다. `npc_scheduler.gd`는 P4-3 소유라 고치지 않았다. `NpcExecutor.failure_code_of(reason)`이 코드를 떼어 주고, 같은 결과가 `last_outcome`에 저장된다. 검토한 다른 길: 사유를 `action_failed` 하나로 하고 코드는 `last_outcome`으로만 읽기(결정 함수가 사유 목록만 보고는 왜 실패했는지 모른다).
- **거부와 실패를 나눴다.** `begin_*`이 바로 알 수 있는 것(모르는 NPC, 바쁨, 이미 남이 쥔 지점)은 반환값으로 거부하고 인터럽트를 내지 않는다. 결정 계층이 같은 결정 안에서 다른 후보를 고를 수 있어서다. 나중에야 알 수 있는 것(길 없음, 막힘, 대상 사라짐, 자는 동안 빼앗긴 지점)만 인터럽트다. 그래서 "예약 충돌"은 두 경로다: 시작할 때는 거부 `spot_reserved`, 깨어날 때는 `action_failed_spot_reserved`.
- **검색 옵션은 "문 질의" 콜백이다.** `GridPathSearch`에 불리언이 아니라 "이 변이 문인가"를 답하는 콜백을 받는다(없으면 꺼짐). 검색 계층은 구조물을 모르므로 문인지는 부르는 쪽이 답해야 한다. `NavigationService`(소유 영역 밖)를 고치지 않으려고, 만든 검색에 첫 조각 전에 거는 `set_door_query`를 뒀다: 실행기는 `NavigationService.begin_search`를 그대로 쓰고 그 위에 옵션만 켠다.
- **문은 열림·닫힘과 무관하게 같은 변이다.** 처음에는 "닫힌 문만 지나갈 수 있는 변"으로 하려 했는데, 그러면 열린 문은 대각선으로 모서리를 스칠 수 있고 닫힌 문은 못 해서 문 상태에 따라 경로가 달라진다. 다른 NPC가 문을 여닫는 틱에 따라 검색 결과가 달라지면 저장 복구 동일성(D11)이 문 타이밍에 묶인다. 그래서 켠 검색에서는 문 변을 항상 "직선으로만 통과"로 본다. 덤으로 문을 지나는 구간이 늘 타일 중심 → 옆 타일 중심이라 "어느 문을 열어야 하는가"가 변 하나의 조회가 됐다.
- **한 틱 한 걸음, waypoint를 넘지 않는다.** 지시의 "one `ServerWorld.resolve_movement` per step"을 틱당 한 번으로 지키려면 waypoint에서 남은 거리를 버려야 한다(P4-185).
- **시간은 정수 마이크로초의 남은 양으로 센다.** 스케줄러(P4-3)처럼 정수라 저장에서 값이 그대로다. 시계가 아니라 카운트다운인 이유: 잠든 NPC는 아무것도 바뀌지 않아야 하므로(D4) 타이머도 멈춰야 한다. 그래서 단계가 저장할 시계가 없다.
- **진행 중인 검색을 "노드 수"로 되살린다(D11보다 강하다).** D11은 검색 중이던 NPC가 복구 뒤 새로 검색해도 된다고 했다. 그런데 새로 검색하면 결과는 같아도 **끝나는 틱이 늦어져** 그 뒤의 걸음·결정이 전부 밀리고, P4-Z의 "최종 상태 해시 일치"가 깨진다. 검색 상태 전체를 저장하는 대신 확장한 노드 수와 대기열 순번만 저장하고, 복구 뒤 같은 입력으로 그만큼 한 번에 다시 돌린다. 테스트에서 이 한 줄을 빼면 저장 복구 비교가 첫 틱 근처에서 실패한다(아래).
- **대기열 순서를 순번으로 저장한다.** 끝나지 않은 검색이 뒤로 갈 때마다 새 순번을 받으므로 "순번 오름차순 = 대기열 순서"가 항상 성립하고, 복구는 깨어나는 NPC를 순번 자리에 끼워 넣는 것으로 끝난다. 단계 문서는 다음 순번 하나다.
- **NPC는 ID 순서로 처리한다.** 메모리에 올라온 순서(딕셔너리 삽입 순서)는 끊지 않은 실행과 복구한 실행에서 다르다. 걷는 순서가 문 여닫기에 영향을 주므로 정렬한다. 깨어난 NPC의 예약 되찾기·대기열 복귀도 그 틱의 첫 호출 때 ID 순서로 한꺼번에 한다(`_settle`).
- **잠든 NPC는 지점을 쥐지 않는다.** 지시의 "release … NPC sleep"을 그대로 따랐다. 다만 예약을 잊지는 않는다: 구성 요소에 남아 있다가 깨어날 때 되찾고, 그 사이 남이 가져갔으면 실패로 알린다(P4-195).
- **예약 두 종류**: 행동이 잡은 것(끝나면 풀림)과 손으로 잡은 것(`release`까지). P4-5b가 "침대로 걸어가 눕기"를 한 행동으로 하든, 자리를 먼저 맡아 두든 둘 다 되게 했다.
- **`action_arrived`를 더했다(지시에 없다).** `HOLD`로 머무는 행동은 끝이 없어서, 도착을 알리지 않으면 P4-5b가 "이제 누웠다"를 알 길이 폴링뿐이다. P4-4의 Navigate → Perform 전이와도 맞는다.
- **지점은 별도 Resource다.** D7은 "맵 콘텐츠 데이터에"라고 했고 조정자는 "map content or a separate resource under `resources/definitions/npc_spots/`"를 허락했다. 맵 정의(`MapBuildingDefinition`, P3-3 소유)를 고치지 않으려고 별도 파일로 두고 `map_id`로 묶었다. 맵 콘텐츠 파일·스크립트는 바꾸지 않았다.
- **결정 함수에 실행기를 넘기는 길**: `NpcService`에 단계를 꺼내는 함수가 없고(P4-3 메모의 같은 문제) `NpcDecider`는 P4-3 소유라, 조립에서 결정 함수에 `on_executor_attached` 메서드가 있으면 불러 준다. P4-4의 결정 함수도 이 메서드만 두면 된다.
  - **계약 변경 제안(하지 않음)**: `NpcDecider.on_executor_attached(executor)`를 기본 클래스에 빈 함수로 두면 `has_method` 없이 형이 드러난다. 또는 P4-3 메모의 `NpcService.get_stage(stage_id)`.
  - **계약 변경 제안(하지 않음)**: 스케줄러 사유에 `:`를 허용하면 지시의 `action_failed:<code>`를 그대로 쓸 수 있다(저장 키라 JSON에는 문제없다).
- **테스트를 먼저 썼다.** API만 있고 아무것도 하지 않는 실행기로 돌려 실패를 봤다(`RESULT: 7 passed, 9 failed`: 통과한 일곱은 이미 구현한 검색 옵션 넷과 데이터 검증·기본 조립 셋이고, 실패는 `expected <["action_arrived", "action_failed_spot_reserved"]> but got <[]>` 같은 단언 실패였다. 다섯 군데는 단언 실패 뒤 빈 결과를 인덱싱하다 스크립트 오류로 끝났다). 검색 옵션 테스트는 옵션을 구현한 뒤에 썼다(먼저 쓰지 않았다).
- **구현 뒤 실패한 것은 테스트 쪽 잘못 넷이었다**: 궤적 비교에 `yaw`를 온전한 자릿수로 찍은 것(이 테스트의 JSON 왕복이 64비트 float의 끝자리와 0의 부호를 바꾼다. `yaw`는 P4-1의 값이고 실행기는 읽지 않는다, P4-210), 문까지 걸어갈 틱 수를 잘못 센 것, 앞 구간의 `action_done` 기록을 지우지 않은 것, 대본에서 "길 없음"이 2048노드 한도 때문에 대본 길이 안에 끝나지 않던 것(대본만 한도 160).
- **테스트가 실제로 잡는지 확인했다.** 구현을 한 줄씩 망가뜨려 돌렸다. 잡힌 것: 복구 때 검색을 이어 돌리지 않기, 문 앞 대기 시간을 저장하지 않기, 잠든 NPC가 지점을 계속 쥐기, 검색별 틱 조각 무시, 문을 열지 않기, 실패한 행동이 예약을 풀지 않기. 처음에는 넷(복구 때 대기열 자리를 잃음, 문 너머에서 닫지 않음, 깨어난 순서대로 정리, 열린 문의 모서리로 대각선 진입)이 통과해 버려서 테스트를 보강했다: 대기열이 붐빌 때의 저장 복구 비교, 문이 닫힌 위치와 그때 아직 걷는 중인지, 같은 틱에 깨어난 두 쌍의 지점 다툼(거울 배치), 열린 문·닫힌 문 양쪽의 대각선 진입. 보강 뒤 넷 다 잡힌다. 깨어난 순서 건은 실제로 차이가 났다(이 테스트에서 셀이 깨어나는 순서가 ID 순서와 달랐다): 정렬이 없으면 결과가 메모리에 올라온 순서에 좌우된다.
- **재지 않은 것**: 성능 전부(P4-Z). docs/15 §17.7 "확인하지 못한 것".
