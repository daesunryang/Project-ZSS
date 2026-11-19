# 18. 성능 측정 기록

같은 조건의 고정 시드 스트레스 벤치 결과를 실행 순서대로 덧붙인다. 서버 tick은 `중앙값 / p95 / 최댓값`(ms), 함수는 `중앙값/p95 ms 및 전체 tick 시간 점유율`, 클라이언트는 `평균 FPS / 1% low FPS`다. 1% low는 가장 느린 1% 프레임의 평균 프레임 시간을 FPS로 환산한다. headless 실행은 렌더 루프 수치가 있어도 GPU 측정으로 기록하지 않는다. 달성 서버 tick/s는 고정 delta를 기다리지 않고 같은 tick들을 연속 실행한 처리량이다.

| 날짜 | git commit | 머신/렌더러 | seed와 개수(P/Z/I) | 서버 tick ms (median/p95/max) | 상위 3 함수 | 클라이언트 FPS (avg/1% low) | 달성 서버 tick/s | 최종 digest |
|---|---|---|---|---|---|---|---:|---|
| 2026-11-19 | 84e271f | Windows; AMD Ryzen 7 3700X 8-Core Processor; headless; GPU not measured (headless) | seed 424242; P4/Z64/I256; 구조물 370/보관함 21 | 3.099 / 4.663 / 10.801 | zombie 2.456/3.530ms 77.2%; survival 0.268/0.428ms 8.9%; movement 0.103/0.161ms 3.4% | N/A (headless, GPU 미측정) | 303.9 | `578edfd59fb732a05d81c8d6998af4d4905dc4b952fdf16fe4af488c7d7a21b0` |
| 2026-11-19 | 84e271f | Windows; AMD Ryzen 7 3700X 8-Core Processor; Windows; NVIDIA GeForce RTX 2060 | seed 424242; P4/Z64/I256; 구조물 370/보관함 21 | 3.000 / 4.545 / 11.558 | zombie 2.392/3.514ms 77.4%; survival 0.265/0.411ms 8.8%; movement 0.101/0.156ms 3.4% | 164.93 / 75.40 | 309.2 | `578edfd59fb732a05d81c8d6998af4d4905dc4b952fdf16fe4af488c7d7a21b0` |
| 2026-11-19 | 84e271f | Windows; AMD Ryzen 7 3700X 8-Core Processor; Windows; NVIDIA GeForce RTX 2060 | seed 424242; P4/Z64/I256; 구조물 370/보관함 21 | 3.154 / 5.222 / 10.852 | zombie 2.495/3.973ms 77.5%; survival 0.272/0.442ms 8.8%; movement 0.105/0.180ms 3.4% | 164.85 / 68.56 | 292.0 | `578edfd59fb732a05d81c8d6998af4d4905dc4b952fdf16fe4af488c7d7a21b0` |
| 2026-11-19 | 8c1049c | Windows; AMD Ryzen 7 3700X 8-Core Processor; Windows; NVIDIA GeForce RTX 2060 | seed 424242; P4/Z64/I256; 구조물 370/보관함 21 | 2.983 / 4.711 / 12.139 | zombie 2.386/3.700ms 77.7%; survival 0.265/0.428ms 8.8%; movement 0.100/0.163ms 3.4% | 164.99 / 101.59 | 308.9 | `578edfd59fb732a05d81c8d6998af4d4905dc4b952fdf16fe4af488c7d7a21b0` |

## NPC 단계 측정 (P4-Z)

`tests/unit/npc_measure_test.gd`의 결과를 실행 순서대로 덧붙인다. 전용 서버와 같은 조립(개발 맵, 좀비 0, 플레이어 1), 달력 05:30~08:30을 60Hz 27000틱으로 잰 NPC 단계(스케줄러 + 결정 + 위협 센서 + 실행기 + 행동) 시간이다. "반복 최악"은 같은 실행을 세 번 돌려 틱마다 가장 작은 값을 남긴 것의 최악이다(25명만). 조건과 원인 분석은 docs/15 §17.10.

| 날짜 | git commit | 머신 | NPC 수 | NPC 단계 ms (median/p99/max) | 반복 최악 ms | 서버 틱 전체 ms (median/max) | NPC 문서 생성 ms | 비고 |
|---|---|---|---:|---|---:|---|---:|---|
| 2026-11-19 | 60e131b+P4-Z | Windows; AMD Ryzen 7 3700X; headless | 5 | 0.076 / 0.408 / 1.323 | - | 0.345 / 2.207 | 0.381 | 결정 1169, 검색 22 |
| 2026-11-19 | 60e131b+P4-Z | 같음 | 25 | 0.312 / 1.265 / 5.584 (3회: max 5.6·2.7·2.7) | 1.949 | 0.595 / 5.960 | 2.079 | 결정 6352, 검색 631, 경로 노드 약 0.1ms |
| 2026-11-19 | 60e131b+P4-Z | 같음 | 50 | 0.623 / 2.144 / 4.001 | - | 0.918 / 4.575 | 4.475 | 결정 12830, 검색 1420. 앞선 실행에서 29.9ms 1회(재현 안 됨) |
