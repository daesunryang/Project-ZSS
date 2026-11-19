# cloud-ready 작업 메모

## 2026-11-19

- 사용자: "이 작업들 나중에 클로드 클라우드로 옮겨서 코덱스랑 같이 작업 가능해?" → 가능하다고 답하고 준비할 것을 설명했더니 "준비 필요한 것 다 진행해".
- 정한 것(조정자):
  - Godot은 클라우드 환경의 설정 스크립트로 설치한다(공식 문서: 설정 스크립트는 root로 세션 전에 돌고 결과가 저장됨). 경로는 `tools/_godot_env.sh` 기본값 `/home/user/tools/godot/`. 공식 SHA512로 확인한다. 세션 안 재설치용으로 `tools/cloud/setup_godot.sh`.
  - Codex 키는 사용자가 환경 설정에 넣는다. 설정 스크립트는 비밀값을 못 읽으므로 로그인은 세션 안에서 `tools/cloud/setup_codex.sh`로 한다. 네트워크 비밀값 방식이 Codex CLI와 맞는지는 확인 못 함.
  - 저장소 `.claude/settings.json`에 SessionStart 훅은 넣지 않았다(설정 스크립트가 공식 권장 방식이고, 훅은 로컬 세션에도 영향을 줄 수 있음).
  - 메모리에만 있던 작업 노하우는 `AGENTS.md` §12로 옮겼다.
