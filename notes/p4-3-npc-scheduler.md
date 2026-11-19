# P4-3 NPC AI 스케줄러 작업 기록

브랜치 `p4-3-npc-scheduler`, 기준 main `fff46b4`. 계약은 docs/09 §17.3, 임시 가정은 docs/15 §17.3(P4-061~P4-082).

## 2026-11-19

사용자 지시(docs/13 §16에 옮겨져 있는 원문): "지금부터 쭉 작업을 진행하고 마지막에 수치랑 규칙 조정을 하자", "에이전트들 활용많이해서 빠르게 해". 그래서 아래 수치·규칙은 전부 임시 기본값이고, 사용자가 정한 것은 아직 없다.

조정자 지시(원문 일부):

> Use the existing `BucketScheduler` for decision buckets with two tiers (near / far), a per-tick decision cap, an event interrupt queue (urgent events don't wait for the period; at most one interrupt per NPC per tick), NPC LOD tier selection (distance to nearest player; only ACTIVE cells simulate; use `NpcService.set_simulation_tier`), and SAVE the next-decision time per NPC (as an `NpcComponent`) and the bucket phase (stage world document `systems.npc.stages.<id>`), so a continuous run and a save→restart→restore run make the same decisions (D11).

이번 작업에서 정한 것:

- **`BucketScheduler`를 쓰지 않았다(지시와 다르다).** 그 클래스의 위상은 비공개 float 누적 셋(`_elapsed`, `_cursor`, `_next_bucket`)이고 읽거나 되돌려 넣는 함수가 없다. `scripts/core/bucket_scheduler.gd`는 내 수정 범위 밖이다. 같은 지시의 뒷부분("버킷 위상을 저장해 연속 실행과 복구 실행이 같게")을 지키려면 위상을 정확히 저장해야 하므로, 버킷의 뜻(주기를 칸으로 나눠 NPC마다 다른 칸에 차례를 준다, 한 번에 한 차례)만 가져와 단계가 가진 **정수 시계의 격자**로 계산했다. 검토한 다른 길:
  - 하위 클래스로 비공개 변수를 읽고 쓰기: 동작은 하지만 core 클래스의 내부에 묶이고, 상한에 밀린 대기열·버킷 소속·단계 이동까지 따로 저장해야 해서 저장 상태가 세 곳으로 늘어난다.
  - `BucketScheduler`에 정수 값만 먹여 위상을 한 번의 `advance`로 되살리기: 그 클래스의 여유값(`SLOT_EPSILON_RATIO`)이 칸 1초 이상에서 1µs를 넘어 정확하지 않다.
  - **계약 변경 제안(하지 않음)**: `BucketScheduler`에 `phase_document()`/`restore_phase()`/`add_to_bucket(id, bucket)`를 더하면 좀비(P2-31)도 저장을 넘겨 같은 차례를 가질 수 있다. 필요하면 별도 티켓.
- **NPC별 "다음 결정 시각"이 유일한 근거다.** 주기적 차례, 상한에 밀린 대기, 잠들었다 깬 뒤의 밀린 차례가 전부 "다음 결정 시각 ≤ 지금"이라는 한 조건이다. 그래서 따로 저장할 대기열이 없고, 복구는 구성 요소를 읽는 것으로 끝난다.
- **시계를 정수 마이크로초로 따로 둔다.** `WorldClock.action_time_sec`은 float이고, 테스트의 저장 왕복(`JSON.stringify` 기본 정밀도)에서는 마지막 자리가 달라진다. 경계에서 한 틱 어긋나면 "같은 틱에 같은 결정"이 깨진다. 정수는 그럴 일이 없다. 대신 1/60초가 16667µs로 반올림돼 주기가 20ppm 짧다(P4-077).
- **버킷은 NPC ID 번호의 나머지다.** 등록 순서로 돌려 배정하면(`BucketScheduler` 방식) "다음에 줄 버킷"을 저장해야 하고, 재시작 뒤 깨어나는 순서에 따라 달라질 수 있다. ID에서 계산하면 상태가 없다.
- **단계 문서의 "버킷 위상"은 시계 값 하나다.** 버킷이 ID에서 나오고 격자가 시계에서 나오므로 그 밖에 저장할 위상이 없다.
- **깨어날 때 단계(near/far)를 다시 재지 않는다.** 처음에는 재도록 생각했는데, 그러면 끊지 않은 실행(마지막 판정 칸의 단계를 들고 있음)과 복구한 실행(깨어나는 순간의 거리로 다시 잼)이 플레이어가 경계 근처에 있을 때 달라진다. 저장된 단계를 이어받고 다음 판정 칸이 고친다. 테스트에서 이 줄만 바꿔 보면 결정 기록 비교가 실패한다(아래).
- **인터럽트와 타이머를 한 구조로 합쳤다.** 즉시 인터럽트는 "지금 시각의 타이머"다. docs/13 §16.4의 "욕구 평가: 다음 범주 경계 시각을 인터럽트 큐에 예약"을 받으려면 시각이 있는 인터럽트가 필요했다. 달력 시간용 함수(`schedule_interrupt_world`)는 P4-2의 경계 시각이 달력 시간이라 넣었다.
- **인터럽트는 상한 안에서 센다.** 티켓 표는 "긴급 사건은 주기를 기다리지 않음"이고 docs/13 §16.4는 "다음 틱에 즉시(상한 안에서)"다. 상한 밖 자리를 주지 않았다(P4-071).
- **결정 함수는 클래스(`NpcDecider`)로 받는다.** Callable보다 인자 형이 드러나고 P4-4가 상속해 채우기 쉽다. 테스트가 기록용 결정 함수를 넣을 자리가 필요해서 `CompositionConfig.npc_decider`를 뒀다(`NpcService`에 단계를 꺼내는 함수가 없어서, 조립된 월드의 스케줄러에 닿는 길이 이것뿐이다).
  - **계약 변경 제안(하지 않음)**: `NpcService.get_stage(stage_id) -> NpcStage`가 있으면 `npc_decider` 필드와 `NpcDecider.on_attached` 없이 테스트·P4-8이 스케줄러에 닿는다. 다섯 줄짜리 추가지만 P4-1 소유 파일이라 손대지 않았다.
- **조립은 한 줄(`NpcScheduler.install`)이다.** 구성 요소 등록과 단계 추가를 묶어 조립 파일의 충돌 줄 수를 줄였다. 반환값(단계)은 P4-5a 실행기가 넘겨받는다.
- **소유 영역 밖 변경 하나**: 다른 티켓 테스트의 문서 비교 세 군데(`npc_state_test.gd`의 "5초 동안 문서가 같다" 비교, `npc_cell_persistence_test.gd`의 `_saved()`, main `b7922ba` 위로 옮긴 뒤 `npc_mind_test.gd`의 셀 왕복 비교). `npc_state_test.gd`의 구성 요소 목록 단언은 조정자가 "같은 조립의 NPC 목록 + COUNTER" 비교로 바꾼 것을 그대로 쓴다. 기본 조립의 NPC가 `schedule` 구성 요소를 갖게 되면서 "시간이 지나도 문서 전체가 같다"는 전제가 맞지 않게 됐다. 비교에서 그 슬롯만 뺐다(`last_simulated_world_time`을 빼던 것과 같은 방식). 일정의 저장·복구 동일성은 `npc_scheduler_test.gd`가 더 세게 본다.
- **테스트를 먼저 썼다.** 설정·구성 요소·결정 함수 자리와 API만 있는 빈 스케줄러로 12개가 전부 실패하는 것을 봤다(로드 오류가 아니라 `expected <["16 npc_000003 thirsty", ...]> but got <[]>` 같은 단언 실패. 셋은 단언 실패 뒤 빈 결과를 인덱싱하다 스크립트 오류로 끝났다). 구현 뒤 실패한 것은 테스트 쪽 잘못 둘이었다: 테스트용 조립 설정에 `validate()`를 불렀던 것(관심 반경·외형이 맞지 않는 설정이었다), 대본의 플레이어가 충분히 멀리 가지 않아 "메모리에서 내려간 NPC"를 거치지 않던 것(걸음 폭을 0.25m에서 0.35m로).
- **결정 기록 비교가 실제로 잡는지 확인했다.** 구현을 한 줄씩 망가뜨려 돌렸다: 저장하는 시계를 20ms 틀리게, 인터럽트를 저장하지 않게, 깨어날 때 단계를 다시 재게, 다음 결정 시각을 복구하지 않게. 넷 다 실패했다(시계는 끝 상태 비교에서, 나머지는 결정 기록의 첫 어긋난 줄에서).
- **재지 않은 것**: 결정 함수가 있는 상태의 비용, 50·100명. docs/15 §17.3 "확인하지 못한 것".
