# 05. NPC AI 시스템 명세 (1차 구현 기준)

## 1. 목표와 비목표

### 목표
- NPC가 플레이어에게 직접 지시받지 않아도 생존, 업무, 휴식, 사회 행동을 수행한다.
- 성격/욕구/감정/기억/관계/목표가 행동 선택에 영향을 준다.
- NPC-NPC 및 플레이어-NPC 관계를 같은 기본 모델로 표현한다.
- AI는 규칙 기반이며 테스트/재현/튜닝 가능해야 한다.
- 멀리 있는 NPC는 요약 시뮬레이션으로 계속 존재감을 유지한다.

### 비목표
- 외부 LLM 또는 클라우드 AI 호출.
- 모든 NPC의 모든 행동을 매 프레임 시뮬레이션.
- 무한한 자연어 대화 생성. 대화는 우선 선택지/태그 기반 상호작용으로 구현.
- 성격 하나로 범죄나 폭력을 자동 결정하는 단순 모델.

## 2. NPC 계층 데이터

1. **정체성:** 고유 ID, 이름, 외형 프리셋, 나이대, 출신/배경.
2. **능력:** 전투, 의료, 농업, 요리, 건축, 정비, 제작, 사교 등.
3. **성격:** 비교적 안정적인 특성 벡터.
4. **욕구:** 시간에 따라 변화하는 생존/사회 욕구.
5. **감정:** 사건과 욕구에 반응하는 단기 상태.
6. **기억:** 사건을 경험한 기록 및 중요도/감정적 해석.
7. **관계:** 대상별 방향성 평가.
8. **목표:** 장기/중기/단기 목표.
9. **업무:** 쉘터 역할, 작업 예약, 작업 숙련.
10. **건강:** 부상, 감염, 질병, 피로.
11. **지식:** 알려진 장소, 루머, 레시피, 위험 정보.

## 3. 성격 모델

초기 성격 특성(0~1 정규화 권장):
- `extraversion`: 사교/집단 활동 선호.
- `agreeableness`: 협력/배려 경향.
- `conscientiousness`: 책임감/업무 지속성.
- `openness`: 새로운 경험/탐험 선호.
- `neuroticism`: 스트레스 반응 민감도.
- `impulsivity`: 숙고 전 행동 가능성.
- `self_interest`: 자기 이익 우선 경향.
- `courage`: 위험 상황에서 버티는 경향.
- `jealousy_proneness`: 관계 경쟁 민감도.
- `animal_affinity`: 동물 친화.
- `risk_tolerance`: 위험 감수 경향.

성격은 행동을 강제하지 않는다. 각 행동의 점수/성공 확률/감정 반응에 영향을 주는 가중치다. `neuroticism` 등 특성은 현실의 정신질환 진단을 의미하지 않는다.

## 4. 욕구 모델

초기 욕구 목록:
- 생리: hunger, thirst, sleep, warmth, hygiene, medical_need.
- 안전: personal_safety, shelter_safety, weapon_need.
- 사회: companionship, belonging, intimacy, family_contact.
- 자율/성취: autonomy, competence, purpose, recreation.

각 욕구는 정규화된 강도와 임계 구간을 가진다. 욕구 변화율은 활동, 환경, 특성, 건강 상태에 따라 다르다.

## 5. 감정 모델

초기 감정 축:
- happiness/joy, sadness, anger, fear, disgust, surprise.
- loneliness, shame, guilt, jealousy, hope, grief, frustration.

감정은 단기 변화 값이며 기억과 동일시하지 않는다. 한 감정이 행동을 자동 결정하지 않도록 한다. 복수 감정이 동시에 존재할 수 있다.

## 6. 기억 모델

각 기억에는 다음을 저장한다.
- memory_id, event_id, event_type.
- participants 및 관계 역할(actor/target/witness/helper).
- 장소/시간.
- 관찰 신뢰도(직접 경험/목격/전언).
- 중요도, 감정 강도, 반복 여부.
- 기억 강도/감쇠 정책.
- NPC가 해당 사건을 어떻게 해석했는지(예: 도움, 배신, 모욕).

중요한 사망/배신/생명 구조 기억은 장기간 유지한다. 사소한 대화/일상 행동은 시간이 지나면 영향이 약해진다. 기억을 삭제하더라도 사건 기록은 서버의 사건 원장에 남을 수 있다.

## 7. 관계 모델

관계는 방향성이 있다. A가 B를 신뢰하는 값과 B가 A를 신뢰하는 값은 독립적이다.

초기 축(0~1):
- trust, liking, respect, fear, resentment, attraction, jealousy, dependence.
- `relationship_status`: stranger/acquaintance/friend/close_friend/romantic_partner/fiance/spouse/ex_partner/hostile 등.

상태 라벨은 점수만으로 자동 확정하지 않는다. 상호 동의, 사건, 약속, 기존 관계, 서버 규칙을 검증한다.

## 8. 목표와 행동 계획

- 장기 목표: 가족 찾기, 안전한 쉘터 만들기, 치료 연구, 농장 운영 등.
- 중기 목표: 특정 재료 확보, 기술 훈련, 특정 NPC와 관계 개선.
- 단기 목표: 식사, 수면, 경비 교대, 작업 완료, 대화.
- 목표는 우선순위/긴급도/실현 가능성/위험도를 가진다.
- 환경 변화나 목표 실패 시 목표를 중단/재평가할 수 있다.

## 9. 행동 선택 알고리즘

추천: **하드 우선순위 규칙 + 점수 기반 Utility 선택 + 제한된 상태 머신** 혼합.

### 9.1 하드 인터럽트

즉시 평가해야 하는 상황:
- 즉각적인 생명 위협.
- 심각한 출혈/의식 저하.
- 화재/붕괴/익사 등 긴급 위험.
- 감염 의심/격리 지시 등 서버 정책상 긴급 상태.

### 9.2 후보 행동

예: flee, fight, rescue, heal_self, seek_food, drink, sleep, work, repair, guard, socialize, comfort, flirt, investigate, hide_item, flee_shelter, care_for_animal.

각 후보는 선행조건과 점수를 갖는다.

`score = base_priority + need_urgency + personality_bias + relationship_context + memory_context + goal_alignment + environment_fit - risk_cost - travel_cost - resource_cost`

각 항은 설정 가능한 가중치이며 초기 수치는 테스트 후 조정한다. 이 수식은 설명 모델이며 구현 시 각 항의 범위와 정규화를 고정해야 한다.

### 9.3 행동 실행

- 선택된 행동은 목표 위치/대상/자원/선행조건을 검증한다.
- 이동은 별도 Navigation/Movement 서비스가 담당한다.
- 행동 중 조건이 바뀌면 중단/재평가한다.
- 행동 실패 원인을 기록한다(경로 없음, 자원 없음, 목표 사라짐, 위험 증가 등).

## 10. 행동 상태 머신

기본 상태: Idle, Evaluate, Plan, Navigate, Perform, Interrupt, Recover.

- Idle: 일정 주기 또는 이벤트에 의해 평가 시작.
- Evaluate: 욕구/위협/목표 후보 점수 계산.
- Plan: 행동 단계와 자원 예약.
- Navigate: 목적지 이동.
- Perform: 작업/대화/전투/휴식 수행.
- Interrupt: 긴급 이벤트 또는 선행 조건 실패 대응.
- Recover: 실패 후 짧은 쿨다운/대체 행동.

## 11. 시간/성능 단계

초기 튜닝 후보(프로파일링 후 조정):
- 플레이어 근거리: 욕구 갱신 1초 간격, 행동 재평가 1~3초 간격.
- 중거리: 5~15초 간격의 요약 갱신.
- 원거리: 월드 시간 경과를 이용한 배치/요약 시뮬레이션.

경로 계산은 모든 NPC가 동시에 재요청하지 않도록 분산 스케줄링한다. 전투/긴급 상황은 주기 제한을 우회할 수 있다.

## 12. 업무와 자율성

업무 역할: guard, farming, cooking, medical, construction, maintenance, cleaning, gathering, hunting, research, animal_care.

업무 지시는 다음을 가진다.
- 우선순위.
- 작업 구역/대상.
- 작업 시간대/교대.
- 필요한 능력/도구.
- 거부/중단 사유.

NPC는 부상, 피로, 공포, 관계, 개인 목표에 따라 업무를 지연/거부/중단할 수 있다. 단, 서버 소유자가 설정한 정책/명령 강제 수준에 따라 결과가 달라질 수 있도록 구조화한다.

## 13. 사회 행동

사회 행동은 관계/감정/기억에 이벤트를 생성한다. 예: greet, small_talk, discuss_memory, ask_help, offer_gift, comfort, argue, apologize, flirt, invite_date, propose, confess, threaten, trade, spread_rumor.

실행 가능 여부는 대상과의 관계, 대상의 현재 상태, 사생활/목격자, 장소, 시간, 문화/성격 태그에 영향을 받는다.

## 14. 비밀 행동과 정보 공개

- 모든 플레이어가 모든 NPC의 비밀 정보를 자동으로 알지 않는다.
- NPC의 계획/관계/사건 정보는 `knowledge`와 `witness` 관계를 통해 개별 보유한다.
- 플레이어에게는 목격, 조사, 대화, 소문을 통해서만 공개한다.
- 서버는 실제 사실(ground truth)과 각 NPC가 믿는 사실(belief/knowledge)을 구분한다.

## 15. 범죄 판단 원칙

범죄는 `동기 + 능력 + 기회 + 기대 이득 + 인지된 위험 + 억제 요인`을 평가한다. 특정 감정/성격 하나만으로 살인 등 중대한 행동을 자동 발생시키지 않는다.

중대 행동은 별도의 임계값, 단계적 갈등, 선택 가능한 대안, 사건 이력을 확인한다. NPC의 우울/불안 등의 심리 고통을 폭력성의 직접 원인으로 취급하지 않는다.

## 16. 결정론과 멀티플레이

- AI 의사결정과 결과는 서버에서 실행한다.
- 각 NPC는 저장 가능한 RNG seed/sequence를 가진다.
- 중요한 결정은 결과 이벤트를 기록해 서버 재시작 후 중복 실행되지 않게 한다.
- 클라이언트는 결과/애니메이션/대사 표현을 받는다.
- 원거리 시뮬레이션과 근거리 시뮬레이션은 동일한 핵심 규칙을 공유해야 한다.

## 17. 디버깅 도구 요구사항

개발자 UI에서 다음을 볼 수 있어야 한다.
- NPC 현재 상태/목표/행동.
- 상위 행동 후보와 점수.
- 욕구/감정/관계 수치.
- 마지막 기억/사건.
- 행동 취소 및 실패 원인.
- 현재 경로와 목적지.
- NPC 시뮬레이션 LOD 단계.
- 고정 seed 재생/리플레이 식별자.

## 18. 1차 AI 수용 기준

- 5명의 NPC가 음식/물/수면/업무를 스스로 수행한다.
- 위험을 감지하면 업무를 중단하고 적절히 도주/방어한다.
- NPC 간 대화/도움이 관계와 기억에 반영된다.
- 같은 사건을 경험한 NPC들이 서로 다른 성격/관계에 따라 다르게 반응한다.
- NPC A→B와 B→A 관계가 독립적으로 저장된다.
- 플레이어가 구역을 떠나거나 서버를 재시작해도 주요 기억/관계가 유지된다.
- AI 선택은 고정 seed 테스트에서 재현 가능하다.
- AI가 실패/정체 상태에 빠졌을 때 원인을 디버그 로그로 확인할 수 있다.

## 19. 2차 심화 설계 범위

정밀한 점수 공식, 감정 갱신식, 기억 감쇠, 관계 발전 임계치, 질투/외도/살인 의사결정, 루머 확산, 장기 목표 계획, 인구 규모 최적화는 `docs/16_npc_ai_deep_dive_backlog.md`에서 별도 심화한다. 현재 문서의 임시 파라미터를 확정값으로 취급하지 않는다.
