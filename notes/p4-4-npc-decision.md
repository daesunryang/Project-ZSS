# P4-4 NPC 행동 선택 작업 기록

브랜치 `p4-4-npc-decision`, 기준 main `281d1aa`(P4-1·P4-2·P4-3·P4-6·P4-7 병합 뒤). 계약은 docs/09 §17.6, 임시 가정은 docs/15 §17.6(P4-151~P4-171).

## 2026-11-19

사용자 지시(docs/13 §16에 옮겨져 있는 원문): "지금부터 쭉 작업을 진행하고 마지막에 수치랑 규칙 조정을 하자", "에이전트들 활용많이해서 빠르게 해". 그래서 아래 수치·규칙은 전부 임시 기본값이고, 사용자가 정한 것은 아직 없다.

조정자 지시(원문 일부):

> P4-4 per docs/13 §16.1: hard interrupts + normalized Utility + bounded state machine. Candidate action definitions as Resources (preconditions, base priority, need/personality/environment term weights); each term clamped to [0,1] and a documented sum formula; tie-break: score → fixed priority → action id; any jitter only from the NPC RNG; anti-oscillation (hysteresis bonus for the current action + minimum duration); no-action fallback (Idle wander); states Idle/Evaluate/Plan/Navigate/Perform/Interrupt/Recover with allowed transitions; failure reason codes and Recover cooldown; first hard interrupt "flee from a visible zombie" (line of sight via the same blocking hook as zombie sight); a decision-record ring buffer (top candidates with per-term scores, chosen action, failure reason) for the debug overlay (P4-8) and tests.

이번 작업에서 정한 것:

- **실행기가 없으면 아무것도 정하지 않는다.** P4-5a가 병렬로 진행 중이라 기본 조립에는 실행기가 없다. 그 상태에서 행동을 고르면 "먹는 중"이라고 보이면서 서 있거나, 모든 행동이 매번 실패해 Recover를 도는 두 가지 모양뿐이다. 둘 다 거짓 상태라 결정 자체를 하지 않게 했다. 덕분에 다른 티켓 테스트의 "시간이 지나도 문서가 같다" 비교를 건드리지 않아도 됐다. P4-5a가 `set_executor` 한 줄을 더하면 그때부터 결정한다(그 병합 때는 그 비교들이 `decision` 슬롯을 빼야 할 수 있다).
- **실패 보고의 사유는 `action_failed_<code>`다(지시의 `action_failed:<code>`와 다르다).** 스케줄러의 인터럽트 사유는 snake_case ID만 받는다(`NpcScheduleComponent.is_valid_reason`). 사유 이름에 코드를 넣으면 실패 코드가 `schedule` 구성 요소와 함께 저장돼, 실행기가 보고한 직후 서버가 꺼져도 사라지지 않는다. 도착 보고 `action_arrived`도 더했다: 걷는 중(`walk`)과 수행 중(`eat`)을 라벨로 나누려면 결정 상태가 도착을 알아야 한다.
- **실행기 계약은 함수 셋(`begin`·`is_running`·`cancel`)이다.** `begin`은 `Error`가 아니라 실패 사유 코드 문자열을 돌려준다(`""` = 받음): 사유 코드가 문자열이라 `Error`로는 "왜"를 못 적는다. `is_running`은 복구 뒤 실행기가 그 행동을 잃었는지 알아보는 데 쓴다(`executor_lost`).
- **욕구 경계 인터럽트는 `need_boundary` 하나다(지시의 `need_<kind>`와 다르다).** `NpcNeeds`가 세 욕구 중 가장 이른 경계 시각 하나만 돌려준다. 욕구별로 나누려면 P4-2에 조회를 더해야 한다(제안만, 하지 않음).
- **위협 센서 단계(`threat_sensor`)를 더했다(계획의 파일 목록에 없던 것).** 결정은 주기(2초/10초)에만 오므로, 결정 함수 안에서만 좀비를 보면 원거리 NPC는 최대 10초 늦게 알아챈다. "긴급 사건은 주기를 기다리지 않음"(P4-3)을 쓰려면 누군가 결정 사이에 봐야 한다. 센서는 0.5초마다 살피고 인터럽트만 요청한다. 상태가 없다(칸은 스케줄러의 저장된 시계에서 계산).
- **도주는 점수를 매기지 않는다.** 하드 인터럽트는 Utility 밖이다(docs/05 §9.1). 도주 행동은 `selectable = false`라 후보 목록에 없고, 기록에는 `hard_interrupt`로 남는다. 도주 행동이 방금 실패해 쿨다운 중이면 평소 선택으로 넘어간다(매 0.5초 실패를 반복하지 않게).
- **합산식에서 뺀 것**: `goal_alignment`(목표 모델 없음), 비용 항 셋(거리·자원·위험은 실행기와 지점 데이터가 있어야 계산된다). 자리만 있고 값이 0인 항은 지시대로 관계·기억 둘이다. 나누어 정규화하지 않고 "항 값과 가중치를 [0,1]로 자른 합"으로 범위를 고정했다: 행동마다 자기 가중치 합으로 나누면 가중치가 행동 안에서만 뜻을 갖게 돼 행동끼리 비교가 틀어진다.
- **평가당 난수 개수를 일정하게 했다.** 처음에는 선행조건을 통과한 후보에만 흔들림을 뽑게 썼는데, 그러면 후보 수가 한 번 달라진 실행은 그 뒤 RNG가 영영 어긋난다. 카탈로그의 행동마다 하나씩 뽑는다.
- **Evaluate·Plan·Interrupt는 결정 한 번 안에서 지나가는 상태다.** 결정은 시간이 걸리지 않으므로 저장되는 상태는 Idle·Navigate·Perform·Recover 넷이다. 지나간 상태는 기록의 `path`에 남고, 전이 표는 일곱 상태 전부에 대해 검사한다.
- **시각은 전부 스케줄러의 정수 시계다.** 최소 지속·쿨다운·Recover를 float로 세면 저장 왕복에서 경계 틱이 갈린다(P4-3과 같은 이유).
- **결정 기록은 저장하지 않는다.** 디버그 자료이고, 저장하면 NPC 문서가 몇 배로 커진다. 순번(`decision_count`)만 저장한다.
- **저장의 float 반올림이 실제로 결정을 갈랐다.** 저장 → 복구 테스트의 첫 판이 실패했다: 욕구가 문턱(40)에 닿는 시각이 틱과 정확히 겹친 결정에서, 복구한 실행만 경계 인터럽트를 한 번 더 받았다(끊지 않은 실행은 문턱을 넘은 것으로, 복구한 실행은 아직 안 넘은 것으로 본 것이다. 값을 직접 찍어 보지는 않았고, 저장이 float를 14자리로 반올림한다는 것과 증상에서 추정했다). 그 한 번이 결정 순번을 밀어 뒤가 전부 달라졌다. 고친 것: 경계 타이머를 경계 +1ms에 두고, 지금 막 지나는 경계(0.00001 달력 초 이내)는 예약하지 않고, 문턱·시간대 판정에 작은 여유를 뒀다. 근본 해결은 저장을 전체 정밀도로 쓰는 것인데 `SaveService`는 내 수정 범위 밖이다(계약 변경 제안).
- **소유 영역 밖 변경**: `server_composition.gd`(결정 함수 만들기·`install`, `NpcNetModule`에 `NpcDecisionComponent.label_of` 전달: 조정자가 "한 줄이면 해도 된다"고 한 것), `composition_config.gd`(`npc_decision`·`npc_actions` 필드, 기본값 로딩, 검증), `tests/test_tiers.cfg`·`tests/test_changes.cfg`(한 줄씩). `scripts/domain/npc/`의 다른 티켓 파일과 다른 티켓의 테스트는 고치지 않았다.
- **테스트를 먼저 썼다.** 클래스·API와 빈 `decide`(첫 줄에서 반환)·빈 센서로 19개 중 14개가 단언에서 실패하는 것을 봤다(`one decision in the next tick: expected <1> but got <0>` 등. 순수 함수·데이터·구성 요소 저장 테스트 다섯은 그때 이미 통과했다: 그 부분은 테스트와 함께 구현이 있었다). 구현을 켠 뒤 실패한 셋 중 둘은 테스트 쪽 잘못이었고(일하기의 최소 지속 20초를 잊은 것, 타이머가 "그 시각의 틱"에 온다는 것), 하나가 위의 float 문제였다.
- **테스트가 실제로 잡는지 확인했다.** 구현을 한 줄씩 망가뜨려 돌렸다: 쿨다운을 저장하지 않게(저장 → 복구 테스트가 결정 65번에서 실패), 시작 시각을 복구하지 않게(결정 67번에서 실패), 시야가 벽을 무시하게(도주 테스트 실패), 최소 지속을 무시하게(최소 지속 테스트 실패). 유지 보너스는 테스트 안에서 보너스 0과 대조한다.
- **재지 않은 것·못 본 것**: docs/15 §17.6 "확인하지 못한 것".
- **작업 중 사고**: 임시 폴더(세션 scratchpad)를 병렬 에이전트(P4-5a)와 같이 쓰고 있었고, 둘 다 `doc09.md`·`doc15.md`라는 이름으로 문서 조각을 썼다. 내가 그쪽의 `doc15.md`를 한 번 덮어썼고(그쪽이 곧 다시 썼다) 내 `doc09.md`는 그쪽 내용으로 바뀌었다. 내 문서는 다른 폴더에 다시 써서 넣었다. P4-5a 브랜치의 docs/15에 P4-4 절(§17.6)이 섞여 들어가지 않았는지 병합 때 확인이 필요하다.
