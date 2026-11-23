# 개발용 NPC 10명 (2026-11-23)

사용자 지시: "npc 최소 10명까지 늘려줘".

더한 다섯(`resources/definitions/npcs/`, 명단 `rosters/dev_npc_roster.tres` 끝에 추가). 이름·성격·능력·외형은 조정자가 지어낸 임시 값이다(docs/15 P4-004).

| ID | 이름 | 나이대 | 업무 | 집(타일) | 일터(타일) | 잠드는 시각 |
|---|---|---|---|---|---|---|
| dev_npc_woojin | 정우진 | adult | guard | house_a (4,1) | warehouse (5,2) | 22.5 |
| dev_npc_sua | 배수아 | young_adult | farming | house_a (4,2) | shed (4,2) | 20.5 |
| dev_npc_youngho | 김영호 | middle_aged | cleaning | house_b (4,1) | clinic (1,1) | 23.5 |
| dev_npc_haeun | 이하은 | young_adult | research | house_b (1,2) | store (4,1) | 1.5 |
| dev_npc_bongsu | 최봉수 | elder | animal_care | house_c (2,1) | garage (3,3) | 21.25 |

지점(`resources/definitions/npc_spots/dev_test_map_spots.tres`): 침대 bed_house_a_3·a_4·b_3·b_4·c_2, 작업 work_<건물>_2 다섯. 지점 16 → 26. 맵 콘텐츠(건물·보관함)는 바꾸지 않았다.

잠드는 시각을 처음 값에서 둘 옮겼다: 최봉수 20.0은 첫날 물을 한 번만 마셔 수용 시험(하루 2번 이상)에 걸렸고, 이하은 0.0은 김영호 23.5보다 먼저 잠자리에 들어 "일찍 자는 사람이 먼저 눕는다" 시험에 걸렸다.

테스트: 5명을 셈하던 곳을 10명으로 바꿨다(phase4_acceptance, npc_behaviour_day, npc_cell_persistence, npc_executor, npc_sleep, npc_state). 25명 측정은 명단에 더하는 수를 25 - 명단 수로, npc_measure의 5명 측정은 10명으로 바꾸고 docs/13 §16.4의 5명 한도 0.3ms를 그대로 적용했다.

식량은 집마다 20단위 그대로. 사흘 실행에서 60단위 중 41단위를 먹었고 남은 양은 약 1.4일치다. 더 오래 버티게 할지는 사용자 결정이다.

## 식량 20 → 40 (2026-11-23)

물음 "식량도 늘려서 더 오래 버티게 할까요?"에 사용자 답 "네, 늘려줘". food 지점 셋의 `stock_units` 20 → 40. 40단위는 5개 묶음 8개로 보관함 `dev_cabinet`(8칸)을 꽉 채운다: 더 늘리려면 보관함을 바꾸거나 food 지점을 늘려야 한다. 사흘 실행: 120단위 넣음, 41단위 먹음, 79단위 남음(약 5.8일 더, 모두 약 8.8일치). 열흘 실행(ZSS_NPC_SOAK=1)은 돌리지 않았다.
