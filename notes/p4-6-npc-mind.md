# P4-6 NPC 감정·기억·관계 작업 기록

브랜치 `p4-6-npc-mind`, 기준 `fff46b4`(P4-1 병합 뒤). 계약은 docs/09 §17.4, 임시 가정은 docs/15 §17.4(P4-091~P4-111).

## 2026-11-19

사용자 지시(원문):

> "지금부터 쭉 작업을 진행하고 마지막에 수치랑 규칙 조정을 하자"

> "필요한 작업있으면 codex 사용량을 좀 더 늘려서 활용해"

이번 작업에서 정한 것:

- **행동은 넣지 않았다.** P4-5b가 아직 없어서 `apply_emotion`, `record_memory`, `put_relationship` API와 셀 저장 왕복만 구현했다. 배고픔 해소·도주가 이 API를 호출하는 연결은 P4-5b 몫이다.
- **감정은 공통 반감기의 지연 계산이다.** 13축을 0~1로 두고, 저장 시각과 저장값에서 조회 시점 값을 계산한다. 적용 때만 13축을 한 번 materialize하므로 틱 비용은 0이다. 공통 6시간은 임시 값(P4-092)이다.
- **기억은 별도 런타임 모델과 구성 요소로 나눴다.** `NpcMemory`가 필드를 검증·직렬화하고 `NpcMemoryStore`가 ID, 같은 사건 통합, 64개 상한, 중요도 축출, 장기 보호를 맡는다.
- **사건 원장은 만들지 않았다.** 빈 사건 ID를 기록할 때 P4-1부터 저장되는 월드 `EntityIdGenerator`에서 `event_<번호>`만 발급한다. 기억 ID도 같은 발급기의 `memory_<번호>`라 셀 해제·재시작 뒤 재사용되지 않는다.
- **같은 사건은 사실이 같을 때만 합친다.** event_type·장소·달력 시각이 다르면 충돌로 거부한다. 같으면 참여자·해석을 합치고 반복 횟수와 더 강한 값들을 남긴다(P4-100).
- **새 기억도 축출 비교에 넣었다.** 상한에서 새 기억이 기존 최저보다 약하면 기존 것을 밀어내지 않고 새 기억이 남지 않는다. 장기 보호는 축출만 막고 감쇠는 계속된다(P4-098·099).
- **관계는 source NPC 소유의 방향성 구성 요소다.** target은 NPC/player ID, 여덟 축은 임시로 0~1, status는 입력을 그대로 저장할 뿐 점수로 바꾸지 않는다(P4-105~108).
- **P4-1 계약 파일은 고치지 않았다.** 세 구성 요소는 `ServerComposition` 등록 줄만 사용하고, 변경마다 `mark_npc_dirty`를 부른다.
- **테스트를 먼저 썼다.** 구현 전 `NpcMindSettings`, `NpcEmotions`, `NpcMemoryStore`, `RelationshipState`, `RelationshipStore`를 찾을 수 없어 두 테스트 파일이 로드 실패하는 것을 확인했다. 구현 뒤 새 테스트 7개는 모두 통과했다.
- **샌드박스에서 못 한 검사**: Godot이 `user://logs`, `user://test_saves`, Windows 인증서 저장소에 접근하지 못했다. 메모리 셀 저장 왕복은 통과했고 실제 파일 저장·전체 `tools/check.sh`는 조정자가 밖에서 다시 돌린다.
- **P4-1 테스트의 고정 목록 한 곳은 범위 밖이라 남겼다.** `npc_state_test.gd::test_components_are_created_saved_and_restored_with_their_npc`는 component ID가 `t41_counter` 하나라고 비교해, 새 기본 세 구성 요소가 붙은 뒤 `emotions`, `memories`, `relationships`, `t41_counter`가 되어 실패한다. P4-1 계약은 뒤 티켓의 등록을 허용하므로 조정자가 병합 때 기대 목록만 갱신해야 한다(같은 파일의 나머지 9개 검사는 통과).
