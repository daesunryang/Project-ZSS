# 20. 클라우드 세션에서 작업하기 (2026-11-19)

Claude Code 클라우드 세션(claude.ai/code)에서 이 저장소를 이어서 작업하기 위한 준비와 규칙이다. 작업 규칙 자체는 `AGENTS.md` 하나다(클라우드 세션도 저장소의 `CLAUDE.md` → `@AGENTS.md`와 `.claude/skills/`를 읽는다).

근거: Claude Code 공식 문서 `cloud-environments`, `claude-code-on-the-web`, `settings`, `memory`, `skills` (code.claude.com/docs/en/). 아래에서 "확인 못 함"이라고 쓴 것은 실제 클라우드 세션에서 아직 돌려 보지 않은 것이다.

## 1. 한 번만 할 준비 (사용자가 claude.ai/code 환경 설정에서)

### 1.1 설정 스크립트에 Godot 설치

환경 설정의 "설정 스크립트(setup script)"에 아래를 넣는다. 설정 스크립트는 세션이 시작되기 전에 root로 한 번 돌고, 약 5분 안에 끝나면 그 결과가 저장돼 다음 세션에서 다시 쓰인다(약 7일 또는 스크립트가 바뀔 때까지). 실패하면 세션이 시작되지 않으므로 마지막에 확인만 한다.

```bash
set -e
V=4.7.2-stable
D=/home/user/tools/godot
B=$D/Godot_v${V}_linux.x86_64
if [ ! -x "$B" ]; then
  mkdir -p "$D"
  curl -fsSL --retry 3 -o /tmp/godot.zip "https://github.com/godotengine/godot/releases/download/${V}/Godot_v${V}_linux.x86_64.zip"
  echo "9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65  /tmp/godot.zip" | sha512sum -c -
  unzip -q -o /tmp/godot.zip -d "$D" && chmod +x "$B" && rm -f /tmp/godot.zip
  chown -R user "$D" 2>/dev/null || true
fi
"$B" --headless --version
npm install -g @openai/codex >/dev/null 2>&1 || true
```

- 경로는 `tools/_godot_env.sh`의 기본값과 같다. 그래서 클라우드에서는 `GODOT` 없이 `bash tools/check.sh`가 돈다.
- 받는 곳(github.com 릴리스)은 기본 네트워크 허용 목록에 있다. 체크섬은 Godot 공식 `SHA512-SUMS.txt`의 값이다.
- 같은 일을 하는 저장소 안의 스크립트가 `tools/cloud/setup_godot.sh`다(세션 안에서 다시 깔 때).
- 마지막 줄은 Codex CLI 설치다. 실패해도 세션은 시작된다.

### 1.2 Codex를 쓰려면 (키는 사용자만 다룬다)

설정 스크립트는 환경 변수와 비밀값보다 먼저 돌아서 키를 읽지 못한다. 로그인은 세션 안에서 한다.

1. 환경 설정의 "허용 도메인"에 `api.openai.com`을 더한다(기본 목록에 없다).
2. 키를 넣는 방법은 둘이다.
   - **환경 변수** `OPENAI_API_KEY`: 세션 안에서 `bash tools/cloud/setup_codex.sh`가 이 값을 화면에 내지 않고 `codex login --with-api-key`로 넘겨 로그인한다. 단, 그 환경을 쓰는 사람은 누구나 이 값을 볼 수 있다.
   - **네트워크 비밀값**(키가 VM 안으로 들어오지 않고, 지정한 호스트로 가는 요청에 프록시가 붙여 줌): 더 안전하지만 Codex CLI가 로컬 로그인 없이 이 방식으로 동작하는지는 **확인 못 함**.
3. 조정자는 키를 대화에 쓰거나 저장소에 넣지 않는다.

## 2. 클라우드에서 되는 것과 안 되는 것

| 일 | 클라우드 | 메모 |
|---|---|---|
| 코드·문서 작업, 티켓 나누기, 검토 | 됨 | 규칙은 `AGENTS.md` |
| `tools/check.sh`, `tools/run_tests.sh`, `tools/test_changed.sh` | 될 것(확인 못 함) | 화면 없이 도는 검사다. 명령 시간 제한(기본 2분, 최대 10분)이 있으니 전체 검사는 백그라운드로 |
| 성능 측정판 서버 쪽(`tools/perf_bench.sh --no-client`) | 될 것(확인 못 함) | 4 vCPU라 수치는 이 PC와 다르다. `docs/18`에 기계 이름과 함께 따로 적는다 |
| 강제 종료·복구 점검(`tools/crash_recovery_check.sh`) | 될 것(확인 못 함) | 리눅스에서는 `kill -9`를 쓴다 |
| 그림 루프의 측정·기록(`tools/art_loop.sh`) | 될 것 | 검토자 채점(하위 에이전트 둘)도 됨 |
| 실제 창 캡처(`tools/capture_view.gd`), 클라이언트 FPS·1% 저점 | **안 됨** | 화면·GPU가 없다. Windows PC에서 한다 |
| Codex에 넘기기 | 1.2를 마친 뒤 | 넘기는 방법은 `.claude/skills/codex-art-handoff/`와 같다 |

## 3. 클라우드로 가져가지 않는 것

자동 메모리, 사용자 전역 설정·스킬(`~/.claude`), 로컬 MCP 서버(Godot MCP 등), 이 PC의 공유 노트 폴더(Codex 지시서), 커밋하지 않은 파일, 이 PC의 `user://` 테스트 저장은 클라우드 세션에 없다. 그래서 작업에 필요한 내용은 저장소에 둔다.

- 규칙과 작업 방식: `AGENTS.md`
- 진행 현황과 다음 작업: `docs/13` §14~§16
- 결정 대기 목록(마지막 수치·규칙 조정): `docs/17`
- 임시 가정과 확인 못 한 것: `docs/15`
- 성능 기록: `docs/18`, 그림 루프: `docs/19`
- 작업별 결정 메모: `notes/`
- Codex 지시서: 클라우드에서는 `/tmp`나 작업 폴더 밖 임시 경로에 쓴다(저장소에 커밋하지 않는다)

## 4. 현재 상태 (2026-11-19)

- Phase 1~3 완료, 성능 기반(PERF-1~3), 실제 창 HUD 수정, 측정판, 그림 루프 틀, 규칙 파일 정리까지 main에 있다.
- 다음 작업 후보: 실제 창에서 찾은 건축 미리보기 조준 문제와 왼쪽 HUD 폭(이 PC에서), `docs/17`로 수치·규칙 조정(사용자와), Phase 4(NPC, 계획은 `docs/13` §16).
- 그림 루프는 사용자가 기준 그림과 기준표 빈칸을 채워야 채점이 된다(`docs/19`).
- 클라우드 세션은 이 PC 세션에 메시지를 보내지 못한다. 결과는 클라우드 세션 화면과 GitHub 브랜치로 확인한다. 두 곳에서 동시에 main을 고치지 않도록, 클라우드 작업은 브랜치로 하고 병합 전에 원격과 맞춘다.
