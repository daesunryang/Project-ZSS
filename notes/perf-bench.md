# PERF-BENCH 작업 기록

## 2026-11-19

사용자 지시(원문):

> [4 성능 검사] 적이 제일 많은 장면을 시드 고정으로 재현하는 측정용 판을 만들고, 함수마다 프레임 시간을 재서 병목을 찾아 줘. 고친 뒤엔 바꾸기 전과 결과가 같은지 비교하는 회귀 테스트를 돌리고, FPS 평균과 1% 저점을 같은 조건에서 재서 날짜와 함께 기록에 남겨.

이번 작업에서 정한 사항:

- 기본 측정 조건은 seed `424242`, 고정 delta `1/60초`, 총 600 tick, 플레이어 봇 4명, 월드 아이템 256개, 현재 설정의 좀비 상한 전부다. 현재 `data/tuning/zombie_settings.tres`의 상한은 64마리다. 모든 수치는 인자로 바꿀 수 있다.
- 전용 서버와 같은 `ServerComposition`을 쓰고 테스트 맵의 구조물·보관함을 모두 시드한다. 봇은 `house_a` 안에서 이동 의도를 계속 보내며, 좀비의 75%는 먼 벽 뒤에서 추격을 시작해 경로 계획을 만들고 나머지는 근거리 추격 부하를 만든다. `house_a` 문 하나는 열어 경로가 실제로 완성될 수 있게 한다.
- 함수별 core 측정은 이동, 월드 시계, 등록 순서의 모든 `ServerSystem.step`, 네트워크 모듈 flush와 플레이어 위치 row 생성, 주기적 저장 문서 요청을 벤치에서 감싼다. 게임 코드에는 측정용 타이밍 훅을 넣지 않았다. 소켓 전송과 GPU 비용은 별도 live 서버·클라이언트 실행에서만 포함된다.
- 최종 digest는 플레이어 위치·각도·체력·소지 수량, 좀비 위치·각도·상태·체력·대상, 월드 아이템 위치·수량, 보관함 상태·내용, 구조물 상태·문·체력·진행도를 정렬해 만든다. 부동소수 위치와 각도 등은 `0.001` 단위로 반올림하고 SHA-256을 쓴다. 시간 측정값과 일시적 네트워크 큐는 digest에서 제외한다.
- 평균 FPS는 측정 프레임 수/측정 실제 시간이다. 1% low는 가장 느린 1% 프레임(최소 1프레임)의 평균 프레임 시간을 구한 뒤 `1000 / 평균 ms`로 환산한다. headless에서는 CPU 렌더 루프가 돌아도 GPU FPS는 미측정으로 기록한다.
- `--compare <base-ref>`는 임시 detached worktree에 현재 벤치 스크립트만 복사하여 기준 코드와 현재 코드를 같은 인자로 실행한다. digest 일치 여부와 tick median/p95/max 차이를 출력하고 임시 worktree를 제거하며 git history는 바꾸지 않는다.
- 첫 기본 측정에서 `zombie`가 tick 시간의 70.18%로 가장 컸다. 결과 규칙과 경로 예산을 그대로 두고, 좀비마다 반복하던 `NavigationService` 조회를 tick당 한 번으로 줄이며 같은 셀의 좀비가 내는 저장 dirty 신호를 tick당 한 번으로 합치기로 했다. dirty revision의 정확한 증가 횟수는 저장 결과가 아니며, 저장 전 한 번 이상 바뀌었다는 사실만 캐시 무효화에 쓰인다.
- 첫 측정의 `world_cells` 비용에는 벤치가 갱신 주기를 0으로 바꾼 인위적 매-tick 갱신이 들어 있었다. 전용 서버와 같은 설정을 비교하기 위해 이 재정의를 제거하고 출하 기본값 0.25초를 유지한다. 최초 배치 뒤 한 번의 명시적 `refresh()`만 한다.
- line-blocking 질의는 `ServerSystem.blocks_lines()`로 제공자를 등록할 때 한 번 분류해, 시야·경로의 hot path가 무관한 시스템의 기본 no-op을 매번 호출하지 않는다. 현재 제공자는 `NavigationService` 하나다. 이 서비스는 등록 때 찾은 `BuildingService`를 재사용하며, 한 zombie step 동안 건축 step이 끼어들지 않으므로 blocking edge 개수도 계획 round당 한 번만 읽는다.
- 2026-11-19 샌드박스에서 `tools/perf_bench.sh --compare 84e271f --no-client --no-log`를 실행했으나, 현재 트리 측정 뒤 `Project-ZSS/.git/worktrees/base` 생성이 권한 거부되어 기준 worktree 실행은 못 했다. 공용 git 디렉터리가 작업 트리 쓰기 범위 밖인 환경 제약이며 코디네이터가 밖에서 재실행해야 한다.
- 첫 기록 행은 기본 조건에서 server tick 3.099/4.663/10.801ms(median/p95/max), 연속 처리량 303.9 tick/s, digest `578edfd59fb732a05d81c8d6998af4d4905dc4b952fdf16fe4af488c7d7a21b0`였다. headless 클라이언트는 10.008초 동안 1448프레임, loop 평균 144.68 FPS와 1% low 63.29 FPS였지만 GPU는 측정하지 못했다. 상위 함수는 zombie 77.2%, survival 8.9%, movement 3.4%였다.
- Windows 실창 Vulkan Forward+ 10초 측정을 같은 기본 조건으로 추가했다. NVIDIA GeForce RTX 2060에서 1649프레임, 평균 164.85 FPS, 1% low 68.56 FPS였고 core server tick은 3.154/5.222/10.852ms, 연속 처리량은 292.0 tick/s였다. 상위 함수는 zombie 77.5%, survival 8.8%, movement 3.4%였으며 digest는 앞선 실행과 같았다.
- 변경 전 기준 커밋과의 공식 timing diff와 digest 비교는 위 worktree 권한 문제 때문에 완료로 간주하지 않는다. 다만 변경 전 수동 측정과 변경 후 core 실행의 digest는 모두 `578edfd59fb732a05d81c8d6998af4d4905dc4b952fdf16fe4af488c7d7a21b0`였고, 짧은 동일 seed 2회/다른 seed 1회 단위 테스트도 통과했다.
