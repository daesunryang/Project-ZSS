# F-31 발견과 대화 (브랜치 `f31-dialogue`)

기준 main `a1abdcc`. 계약은 docs/09 §17.16, 임시 가정과 측정은 docs/15 §27(F31-001~F31-024).

## 사용자 지시 원문 (2026-11-23)

> 그렇게 고치고 npc는 랜덤 집에서 혼자 버티고 살아남는 형태, 유저가 발견했을 때 포섭을 할 지 죽일지는 유저 선택, 역으로 성격이 포악하거나 대화에서 트러블이 생길 시 유저를 공격할 수 있음
> npc는 자유의지가 있으며 생존을 최우선 시 함
> 거처를 바꿔다닐 수도 있음

포섭한 NPC에 대한 답(같은 날): "포섭에서 같이 살고 플레이어가 동행요청하면 같이 돌아다니고". 이것은 F-32·F-20이고 이 티켓이 아니다.

조정자 지시(요약): 범위는 F-31만(포섭 수락, 플레이어 공격, 포섭된 생활은 F-32). 발견(위협과 같은 시야 규칙, 성격과 상태에 따른 반응, 무기·가해·NPC 살해 목격이 위협을 키움, 서버가 정하고 라벨로 보임), 대화 시작(상호작용 키, 거리·시야·생존·상태 검사, NPC가 거절할 수 있음, 자는 NPC를 깨우는 것은 결과가 따르는 선택), 대화(서버의 작은 상태 기계, 정해진 선택지, 실제 아이템 이동, 기억에서 나오는 소식, 간단한 거래, "같이 가자"는 요청과 고리만), 관계 변화(NPC별·플레이어별 저장, "대화가 틀어짐" 고리), 네트워크(의도만 보내고 서버가 검증, 대사는 말하는 사람에게만, 프로토콜 번호 올림), 클라이언트 화면(최소한), 저장(대화는 저장 안 함, 관계는 저장), 테스트·측정, 문서는 한국어. 게임 안에 LLM·외부 API 없음.

## 2026-11-25에 정한 것

사용자가 정한 것은 위 인용뿐이고, 아래는 전부 이 작업에서 임시로 정했다.

- **F-31 전체를 설정 하나로 켜고 끈다.** `CompositionConfig.npc_social`(기본 켜짐). null이면 F-30까지의 모습이다.
- **몸의 반응은 결정 계층이 한다.** 처음에는 사회 단계가 NPC를 직접 세우거나 돌리는 것을 생각했는데, 그러면 결정 계층이 계속 다른 행동을 골라 NPC를 움직인다. 그래서 하드 인터럽트 단계에 "좀비 다음에 플레이어"를 넣고, 사회 단계는 "무엇을 해야 하나"(`directive()`)만 답한다. 도망은 기존 `flee`를 그대로 쓰고(위협이 플레이어), 나머지는 새 행동 `meet` 하나의 방식 넷(`watch`·`approach`·`back_off`·`talk`)이다.
- **새 행동은 난수를 뽑지 않고 선택 대상이 아니다**(`draws_jitter = false`, `selectable = false`). F-29와 같은 이유: 행동 목록에 더해도 기존 NPC의 난수 순서가 바뀌지 않는다.
- **반응은 잠깐이다.** 처음 만든 판은 플레이어가 보이는 내내 NPC가 서서 지켜봤다. 플레이어 곁에 사는 NPC는 아무것도 못 하게 된다. "알아챈 뒤 8초"로 줄이고 그 뒤에는 생활로 돌아가게 했다(겁먹은 NPC만 보이는 동안 계속 도망친다).
- **공개 반응은 NPC마다 하나**다(가장 두려운 상대에 대한 것). 플레이어마다 다른 라벨을 보내면 "누구를 어떻게 생각하는지"가 다른 플레이어에게 샌다.
- **관계 점수는 기존 `relationships` 구성 요소에 둔다**(지시대로). 점수가 아닌 것(횟수·날짜·이유)만 새 구성 요소 `social`에 둔다. 보이기만 해서는 관계 기록을 만들지 않는다(낯선 사람의 신뢰는 성격에서 계산한다).
- **매번 보는 것으로 저장을 더럽히지 않는다.** "마지막으로 본 때"는 0.5초마다 바뀌므로 NPC 문서에 넣지 않았다(넣으면 NPC 문서를 계속 다시 만든다). 대신 단계의 월드 문서에 저장 시점의 값을 적는다.
- **누가 누구를 보는지를 저장하게 된 이유.** 처음에는 저장하지 않았더니 `phase4_acceptance_test`와 `npc_behaviour_day_test`의 "재시작한 서버는 계속 돈 서버와 같다"가 깨졌다: 재시작한 쪽만 플레이어를 "새로 알아채서" `meet`를 시작했다. 테스트에서 사회 계층을 끄는 대신 그 상태를 저장했다. 두 테스트는 사회 계층을 켠 채 통과한다.
- **대답은 계산, 문장은 데이터.** 어느 문장을 고를지는 NPC마다 세는 번호로 돌린다(난수 없음, 저장됨).
- **거절은 실패가 아니라 대답이다.** NPC가 말하기 싫어하는 것은 성공 결과(닫힌 화면 + 거절하는 말)로 돌려준다. 실패는 거리·죽음처럼 요청 자체를 볼 수 없었던 경우다.
- **화면 번호(`turn`)** 를 둬서 늦게 도착한 선택이 다른 화면의 선택지로 해석되지 않게 했다.
- **거래를 넣었다**(지시는 "간단하게 또는 자리만"). 1단위 대 1단위, NPC가 받아들일 조합만 보여 주는 식이라 화면이 따로 필요 없다. 기존 `exchange_items`가 전부 아니면 전무를 보장한다.
- **자는 NPC**: 대화를 여는 것만으로는 깨지 않게 `talker_of`(깨어서 말하는 상대)와 `partner_of`(자리를 차지한 상대)를 나눴다.
- **F-32가 이을 자리 둘**: `conversation_went_badly`와 `join_requested`(신호 + 저장되는 기록). NPC는 여기서 누구도 공격하지 않는다.
- **F-30의 "공격받으면 이사"(`NpcRelocation.note_attacked`)는 잇지 않았다.** 적대·반격과 같이 정해야 해서 F-32에 남겼다.
- **프로토콜 20 → 21.** NPC 공개 행에 반응 번호, 이벤트 `npc_reaction_changed`, 새 모듈 `NpcDialogueNet`. 세이브 스키마 번호는 그대로(구성 요소 하나와 단계 월드 문서 하나가 늘었다).
- **`RelationshipStore.peek_relationship`** 를 더했다(복사 없는 읽기). 기존 `relationship()`은 문서로 바꿨다 되읽는 복사라서 0.5초마다 NPC × 플레이어 수만큼 부르기에 무겁다.
- **ADR은 쓰지 않았다.** docs/00은 조정자가 병합 때 넣을지 정한다(내용: "NPC의 플레이어 반응은 결정 계층의 하드 인터럽트로 하고, 대화는 서버의 정해진 선택지 상태 기계다. 대화는 저장하지 않는다").
- **작업 나눔**: 서버 모델·데이터·단위 테스트·문서는 이 브랜치에서, 네트워크·클라이언트 화면·통합 테스트는 하위 에이전트가 따로 낸 worktree(`f31-net`)에서 하고 합쳤다.
- **소유 영역 밖 변경**: `decision/npc_utility_decider.gd`(플레이어 인터럽트), `behaviours/npc_behaviours.gd`·`npc_behaviour_state.gd`(행동 `meet`), `relationships/relationship_store.gd`(`peek_relationship`), `composition_config.gd`·`server_composition.gd`(조립), `build_info.gd`, NPC 복제 셋(`npc_net_protocol.gd`·`npc_net_module.gd`·`client_npc_state.gd`), 화면(`client_view.gd`·`client_view.tscn`·`client_input_actions.gd`·`client_presentation_settings.gd`·`npc_visuals.gd`), `tests/framework/npc_life_run.gd`(사회 계층을 끄는 스위치), `tests/test_tiers.cfg`·`tests/test_changes.cfg`. docs/09는 파일 끝(§17.16), docs/15는 파일 끝(§27).

## 기존 테스트를 고친 곳

- **프로토콜 번호 20 → 21**: `character_net`, `consume_net`, `container_net`, `ground_transfer_net`, `inventory_net`, `npc_debug_net`, `npc_net`, `posture_net`, `rest_net`, `structure_net`, `trade_net`, `treat_other_net`.
- **NPC 공개 행 모양**(값 8 → 9개, 열쇠 `reaction`): `npc_net_state_test`, `npc_health_net_test`, `phase4_acceptance_test`. 키 목록 수: `trade_presentation_test`(32 → 34).
- **행동 목록**: `npc_decision_test`("배포된 행동은 열한 개" → 열두 개, `meet` 포함).
- **사회 계층을 끈 파일**(다른 것을 보는 테스트이고, 플레이어는 셀을 깨워 두려고 NPC 곁에 서 있을 뿐이다. 켜 두면 NPC가 플레이어를 보고 서거나 다가와서 그 테스트가 재는 걸음·결정 수가 달라진다): `npc_scheduler_test`, `npc_executor_test`, `npc_behaviour_test`, `npc_decision_test`, `npc_state_test`, `npc_cell_persistence_test`, `npc_scavenge_test`(`NpcLifeRun.with_social`). 단언은 고치지 않았다.
- 그 밖의 NPC 테스트(F-25 체력, F-28 집, F-30 이사, 하루 실행, P4-Z 수용, 측정)는 사회 계층을 켠 채 그대로 통과한다.

## 측정

docs/15 §27.1 표가 기준이다.

## 확인하지 못한 것

docs/15 §27.2. 요약: 실제 게임 창에서 본 적 없음(자동 검사 통과는 재미·그림·문장 승인이 아니다), 벽 너머 시야, 플레이어 곁에서 여러 날 사는 NPC, 실제 프로세스 둘 이상.

## 사용자가 정할 것

1. NPC가 얼마나 쉽게 마음을 여는지(F31-002·F31-009): 반응 수치와 관계 변화량 전체.
2. 선택지 목록(F31-006): 지금 인사·누구인지·건네기·소식·바꾸기·같이 가자·위협·자리 뜨기(+ 깨우기).
3. 키(F31-017): 말 걸기 Enter, 끝내기 Esc, 선택 숫자 1~9.
4. 문장(F31-016): `lines_ko.tres`의 문장과 말투.
5. 반응이 하던 일을 끊는 정도(F31-004·F31-005): 지금 알아챈 뒤 8초.
6. 건넬 수 있는 물건(F31-010)과 거래 방식(F31-011).
7. 화면(F31-019): 이름표 꼬리표와 글자 패널은 자리 표시다.

## 다음 작업 제안

- F-32: `conversation_went_badly`·`join_requested`와 기록을 읽어 적대·포섭을 정한다. `NpcRelocation.note_attacked`를 `NpcSocial.npc_harmed_by_player`에 잇는다. 포섭된 NPC는 `relocate` 후보에서 뺀다(F30-001).
- 두려움·원한이 시간이 지나며 풀리는 규칙(지금은 저절로 변하지 않는다).
- 먼 NPC의 요약 시뮬레이션(F31-023).
