# 19. 그림 루프

## 1. 무엇인가

그림(모델, 텍스처, UI 그림, 아이콘 등)을 만들거나 고칠 때 쓰는 반복 절차입니다.

- 회차마다 결과를 **스냅샷**(PNG)으로 남깁니다.
- 잡티·끊긴 선처럼 **셀 수 있는 것**은 스크립트가 잽니다.
- **"AI 티"** 와 **"우리 그림체와 어울리는지"** 는 그 그림을 처음 보는 **검토자 둘**이 기준표와 기준 그림만 보고 채점하고, 둘의 점수를 평균 냅니다.
- **회차 상한**이 있고, 점수가 더 안 오르면 **멈추고 사용자에게 보여 줍니다.**

이 루프는 그림을 승인하지 않습니다. 수치와 점수는 회차끼리 견주려는 숫자이고, 그림을 받아들일지는 사용자가 직접 보고 정합니다.

에이전트가 따르는 절차는 `.claude/skills/art-loop/SKILL.md`, 정해진 것의 기록은 `notes/art-loop.md` 입니다.

## 2. 사용자가 채워야 하는 것 (지금 비어 있음)

| 무엇 | 어디 | 비어 있으면 |
|---|---|---|
| 기준 그림 — "이것이 우리 그림체다"라고 고른 그림 | `art/loop/reference/` 에 png/jpg/webp 파일 | 검토자 채점을 시작할 수 없음 |
| 우리 그림체의 특징 | `art/loop/rubric.md` 의 첫 번째 `[빈칸 — 사용자 작성]` | 위와 같음 |
| 점수 5·3·1의 본보기 | `art/loop/rubric.md` 의 두 번째 `[빈칸 — 사용자 작성]` | 위와 같음 |

빈칸을 채울 때는 `[빈칸 — 사용자 작성]` 표시를 지우고 그 자리에 내용을 적습니다. 표시가 하나라도 남아 있거나 기준 그림이 한 장도 없으면 도구가 `NOT READY FOR REVIEWERS` 로 멈춥니다. 이때도 스냅샷과 스크립트 수치는 1회차까지 남길 수 있습니다.

고쳐도 되는 것(초기값이며 사용자가 정한 값이 아님):

- `art/loop/rubric.md` 의 "AI 티" 보는 곳과 점수 기준 — 일반적인 내용만 적어 둔 초안입니다.
- `art/loop/settings.json` 의 회차 상한, 멈춤 기준, 측정 문턱값.

## 3. 작업 시작과 한 회차

```bash
export GODOT="<Godot 4.7.2 실행 파일>"
tools/art_loop.sh start <작업이름> "<사용자가 말한 목표 그대로>"
```

한 회차는 다음 순서입니다.

1. 그림을 만들거나 고칩니다(`.claude/skills/codex-art-handoff/SKILL.md` 대로 Codex 에 넘기고, 돌아온 결과를 직접 확인).
2. 스냅샷을 찍습니다. 게임 안 모습은 `tools/capture_view.gd` 로 게임 창을 찍습니다. 매 회차 같은 이름·크기·구도여야 수치를 견줄 수 있습니다.
3. `tools/art_loop.sh round <작업이름> <png>...` — 회차 폴더를 만들고 스냅샷을 복사하고 수치를 잽니다.
4. `tools/art_loop.sh pack <작업이름>` — 검토자가 볼 수 있는 것만 프로젝트 밖 임시 폴더에 모으고, 검토자에게 줄 글을 출력합니다.
5. 새 검토자 둘을 띄워 그 글만 줍니다. 답을 `rNN/reviews/reviewer_1.json`, `reviewer_2.json` 으로 저장합니다.
6. `tools/art_loop.sh record <작업이름>` — 평균을 내고, 이어 갈지 멈출지 알려 줍니다.

멈추면 `tools/art_loop.sh report <작업이름>` 으로 점수표·수치 추이·가장 점수 높은 회차의 스냅샷을 뽑아 사용자에게 보여 주고 묻습니다.

수치만 재려면: `tools/art_loop.sh metrics <그림>...` (JSON 출력).

### 검토자가 보는 것

검토자는 매 회차 새로 띄운 하위 에이전트입니다. 받는 것은 셋뿐입니다.

- `rubric.md` (기준표)
- `reference/` 의 그림 파일 (README 는 주지 않음)
- 이번 회차 스냅샷 — 이름을 `snapshot_01.png` 처럼 바꿔서 작업 이름과 회차를 알 수 없게 함

지난 회차, 지난 점수, 스크립트 수치, 만든 쪽의 설명은 주지 않습니다. 검토자에게 주는 글의 틀은 `art/loop/reviewer_prompt.md` 이고, 답은 이 모양으로 고정입니다.

```json
{"scores":{"ai_look":{"score":4,"reason":"한 줄"},"style_fit":{"score":3,"reason":"한 줄"}}}
```

점수는 1~5 정수, 두 항목 모두 높을수록 좋습니다(`ai_look` 5 = AI 티가 전혀 안 남). 모양이 틀린 답은 `record` 가 받지 않습니다.

회차 점수 = 항목마다 두 검토자의 평균, `overall` = 두 항목 평균의 평균.

## 4. 멈추는 기준

`art/loop/settings.json` 의 `loop`, `regression` 에 있습니다.

| 기준 | 설정 | 초기값 | 뜻 |
|---|---|---|---|
| 회차 상한 | `loop.max_rounds` | 5 | 채점까지 끝난 회차가 이 수에 닿으면 멈춤 |
| 점수가 안 오름 | `loop.min_improvement`, `loop.patience_rounds` | 0.25, 2 | `overall` 이 마지막으로 뚜렷이 오른 점수보다 0.25 이상 오르지 못한 회차가 2번 이어지면 멈춤 |
| 수치가 나빠짐 | `regression.<수치>.abs`, `.rel` | 잡티 2개/10%, 끊긴 선 1개/10%, 번짐 4px/10% | 바로 앞 회차보다 `abs` 와 `rel`(앞 회차 값의 비율) 둘 다를 넘게 늘면 채점 없이 멈춤 |

- 스냅샷의 이름이나 크기가 앞 회차와 다르면 수치를 견주지 않고 그 사실만 알립니다.
- 멈춘 뒤에는 사용자가 더 돌리라고 해야만 다음 회차가 열립니다. 그 말은 `--user-said-continue="..."` 로 넘기며 `job.json` 에 남습니다.
- 채점 안 된 회차가 있으면 다음 회차를 열 수 없습니다.
- 도구가 내는 상태는 `continue`, `score_pending`, `stopped_show_user` 셋뿐입니다. "승인"은 없습니다.

## 5. 스크립트가 재는 것

`tools/art_metrics_lib.gd` 가 계산하고, 문턱값은 `settings.json` 의 `metrics` 에 있습니다. 색 값은 0~255, 길이는 픽셀입니다.

| 수치 | 무엇을 세나 | 설정 (초기값) |
|---|---|---|
| `specks` 잡티 | 서로 비슷한 색으로 이어진 픽셀 무리(`join_tolerance` 24 이내) 가운데, 크기가 `max_px`(6) 이하이고, 둘레와의 색 차이가 `min_contrast`(48) 이상이며, 그 둘레가 고른 면(`ring_max_spread` 16 이하)인 것. 투명한 곳 위의 불투명한 점도 셉니다. | `metrics.specks` |
| `line_breaks` 끊긴 선 | 어두운 픽셀(밝기 `dark_max_luma` 80 이하, 알파 `min_alpha` 128 이상)을 가늘게 깎아(`thinning_passes` 3) 선의 끝점을 찾고, 서로 마주 보는(`min_alignment` 0.5) 두 끝점 사이가 1~`gap_max_px`(6) 픽셀 비어 있으면 한 군데로 셉니다. 길이 `min_stroke_px`(6) 미만의 짧은 자국과 넓은 어두운 면은 선으로 보지 않습니다. | `metrics.line_breaks` |
| `halo_px` 가장자리 번짐 | 반투명 픽셀(알파가 `transparent_max_alpha` 8 초과, `opaque_min_alpha` 247 미만) 가운데, `radius_px`(2) 안에 불투명 픽셀이 있는데도 그 어느 것과도 색이 `min_color_diff`(48) 이상 다른 것. 배경을 따낸 뒤 남은 흰 테·검은 테가 여기 잡힙니다. | `metrics.halo` |
| `colors_exact`, `colors_quantized` 색 수 | 보이는 픽셀의 서로 다른 색 수. 뒤의 것은 채널마다 `quantize_bits`(4) 비트로 줄여 센 값. 많고 적음의 좋고 나쁨은 정해져 있지 않아 **참고용**이며 멈춤 기준에 쓰지 않습니다. | `metrics.colors` |

알아 둘 한계:

- 잡티와 끊긴 선은 면이 고르고 선이 또렷한 그림(UI, 아이콘, 선화, 단색 면)에서 뜻이 분명합니다. 3D 렌더 화면에서는 값 자체보다 회차 사이의 변화를 봅니다.
- 가장자리 번짐은 투명 배경이 있는 그림에서만 나옵니다. 불투명한 화면 캡처에서는 0입니다. 알파가 0 아니면 255뿐인 그림의 흰 테는 테두리 선과 구분할 수 없어 세지 않습니다.
- 스크립트 수치가 깨끗하다는 것은 "셀 수 있는 흠이 적다"는 뜻일 뿐입니다.

검증: `tests/unit/art_metrics_test.gd` 가 `Image` 로 직접 그린 그림(잡티 3개, 끊긴 선 2군데, 번짐 10픽셀 등 답을 아는 그림)으로 수를 확인하고, `tests/unit/art_loop_test.gd` 가 평균·멈춤 기준을 확인합니다.

## 6. 파일

```
art/loop/
  .gdignore              Godot 이 이 폴더를 게임 자원으로 들여오지 않게 함
  settings.json          회차 상한, 멈춤 기준, 측정 문턱값
  rubric.md              기준표 (빈칸 2곳은 사용자 작성)
  reviewer_prompt.md     검토자에게 주는 글의 틀
  reference/             기준 그림 자리 (사용자가 넣음) + README
  runs/<작업>/
    job.json             목표(사용자 말 그대로), 멈춘 뒤 이어 가라고 한 사용자 말
    scores.json          회차별 수치·점수·판단
    rNN/
      snapshots/         그 회차의 스냅샷 원본
      metrics.json       스냅샷별 수치와 그때 쓴 문턱값
      reviews/           reviewer_1.json, reviewer_2.json (검토자 답 그대로)
tools/
  art_loop.sh            start / round / pack / record / report / metrics
  art_loop.gd            위 명령의 본체 (Godot headless)
  art_loop_lib.gd        평균, 수치 비교, 멈춤 판단
  art_metrics.gd         수치만 재는 명령
  art_metrics_lib.gd     잡티·끊긴 선·번짐·색 수 계산
```

`art/loop/runs/dryrun-placeholder/` 는 도구를 시험하려고 임시 그림(게임 창 캡처) 한 장으로 돌려 본 기록입니다. 채점은 하지 않았습니다.
