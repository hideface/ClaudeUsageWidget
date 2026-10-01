# Claude Usage Bar (macOS) — Claude Code 작업 안내

Claude Code 구독 플랜 사용량(5시간 / 주간 / 모델별 주간 한도, 추가 크레딧, 오늘 토큰)과 Codex(앱·CLI·VS Code 확장이 같은 로그를 씀) 한도를 메뉴바에 보여 주는 macOS 앱.
사용자 가이드는 `docs/GUIDE.md`, 사용자에게 설명할 때는 그 문서의 표현을 따른다.

## 명령

```bash
scripts/build-app.sh --run      # release 빌드 → ~/Applications/ClaudeUsageBar.app 설치 후 실행(기존 인스턴스 종료)
swift test                      # 단위 테스트 (UsageCore)
swift build && .build/debug/ClaudeUsageBar --snapshot <폴더>   # 실제 데이터로 패널·메뉴바·설정 PNG(state.json 복사본 사용, API 호출 안 함)
.build/debug/ClaudeUsageBar --test-refresh                      # 자동 갱신과 같은 조건으로 CLI 실행 점검(약 500토큰)
open ~/Applications/ClaudeUsageBar.app --args --simulate-expired-token   # 실제 앱에서 토큰 만료를 한 번 흉내 내 자동 갱신 흐름 전체 점검(설정에서 자동 갱신이 켜져 있어야 CLI 실행)
```

- 요구: macOS 14+, Swift 6 툴체인(Xcode 16+ 또는 Command Line Tools 16+). `swift --version`으로 확인하고 없으면 `xcode-select --install` 안내
- 번들을 저장소 안(`build/` 등)에 만들지 않는다. 저장소가 iCloud 동기화 폴더(Documents 등)에 있으면 확장 속성 때문에 `codesign`이 거부된다. 그래서 `~/Applications`에 만든다(`APP_DIR`로 변경 가능)
- 화면 캡처 권한이 없어도 UI는 `--snapshot`으로 확인할 수 있다. 사용자에게 스크린샷을 요구하기 전에 먼저 이걸 쓴다

## 구조

- `Sources/UsageCore/` — UI 없는 로직, 전부 단위 테스트 대상
  - `Credentials.swift` 키체인 `Claude Code-credentials`를 `/usr/bin/security`로 읽기(팝업 없음). `CLAUDE_CONFIG_DIR/.credentials.json`이 있으면 우선. `AuthHints`로 API 키 사용자 구분(`~/.claude.json`의 `primaryApiKey`, `~/.codex/auth.json`의 `auth_mode`), 값은 읽지 않음
  - `UsageAPIClient.swift` / `UsageResponse.swift` `GET https://api.anthropic.com/api/oauth/usage`(비공식). 모든 필드 옵셔널로 관대하게 디코딩
  - `FetchPolicy.swift` 주기(최소 120초), 429 백오프 5→10→20→30분, 수동 갱신도 2분에 한 번(API 호출 규칙), 재시작 후 유지
  - `DesktopHistory.swift` Claude 데스크톱 앱 기록 `~/Library/Application Support/Claude/plan-usage-history.json`(version 2만)
  - `DisplayResolver.swift` API 값(신선하면) → 데스크톱 기록(토큰 만료 시) → 오래된 API 값(회색) 순으로 표시 결정. 지난 리셋은 0%(`percentInferred`)·주간은 7일씩 넘겨 다음 리셋 계산, 5시간 리셋은 데스크톱 기록으로 추정(`resetEstimated`, 실측 오차 +7분)
  - `SessionLogScanner.swift` `~/.claude/projects/**/*.jsonl` 오늘 토큰 증분 집계, `message.id|requestId` 중복 제거
  - `CodexUsage.swift` `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`(또는 `CODEX_HOME`)에서 `token_count` 이벤트의 `rate_limits`를 한도(`limit_id`)별로 마지막 값만 읽음. 세션 로그가 수 GB라 최근 30일 폴더·8일 안에 수정된 파일의 끝부분만 읽고, 수정 시각이 같으면 다시 읽지 않는다. 꼬리에 없는 한도는 오늘 로그 전체 스캔(`CodexTokenScanner.limits`)과 `state.json`에 저장한 값으로 보완(`CodexSnapshot.merged`). 기본 한도 `codex`는 8일이 지나도 남기고(리셋 지났으면 0%), 모델별 추가 한도만 8일 뒤 숨김
  - `AlertEngine.swift` 경고/위험/100%/속도 예측/크레딧 알림 규칙(Codex 한도에도 같은 규칙, 제목에 "Codex"). 주기 구분은 리셋 시각 기준이되 5분 안의 흔들림은 같은 주기(Codex resets_at이 ±1초씩 흔들림)
  - `CodexTokens.swift` 오늘 Codex 토큰: 세션별 `total_token_usage` 누적치(오늘 마지막 − 0시 이전 마지막). 첫 스캔은 오늘 수정된 파일 전체(수백 MB 가능), 이후 증분
  - `UsageEngine.swift` 위를 묶는 actor. `tick(claude:codex:)`로 서비스별 켜기/끄기(Claude를 끄면 키체인·API 접근 안 함)
- `Sources/ClaudeUsageBar/` — AppKit 상태 항목(하나, 서비스별 조각을 텍스트 첨부 이미지로 이어 붙임) + SwiftUI 패널(서비스별 섹션, 기본/작게)·설정, 알림, 스냅샷 모드
- 큰 파일 읽기는 조각마다 `autoreleasepool`로 비운다(안 그러면 첫 스캔 때 메모리가 파일 크기만큼 오른다)
- `Tests/UsageCoreTests/Fixtures/` — API 응답·데스크톱 기록·세션 로그 샘플

## 지켜야 할 원칙

- **토큰은 읽기만 한다.** 앱이 refresh token으로 갱신하거나 키체인에 다시 쓰지 않는다(Claude Code 로그인이 풀릴 수 있음). 만료되면 CLI가 스스로 갱신하게 한다: 사용자가 터미널에서 `claude`를 실행하거나, 설정의 "CLI 토큰 자동 갱신"(기본 꺼짐)을 켜면 앱이 `CLIRefresher.swift`로 CLI를 짧게 실행(Haiku·짧은 시스템 프롬프트·도구/MCP 끔·세션 저장 안 함, 약 500토큰, 일시적 실패는 2분부터 두 배씩 최대 30분·CLI 없음은 30분 간격). `claude auth status`로는 갱신되지 않는다(확인함)
- 토큰 값을 출력·로그·커밋에 남기지 않는다. 디버깅할 때도 `security ... -w` 결과를 그대로 출력하지 말고 구조만 확인한다(`Redact.secrets` 참고)
- 사용량 API는 2분보다 자주 호출하지 않는다(429 유발)
- 색은 그래프(도넛)에만 쓴다: 5시간 코랄 `#D85A30`, 주간 보라 `#7F77DD`, 모델별 청록 `#1D9E75`, Codex 전체 파랑 `#378ADD`, 70%+ 주황, 90%+ 빨강, 최신 아님 회색

## 문제 진단 순서

1. `~/Library/Application Support/ClaudeUsageBar/app.log` (최근 200줄, 토큰 마스킹됨). `[token] auto refresh`, `[desktop] 새 기록`(데스크톱 앱이 기록을 남긴 시각) 줄 참고
2. `state.json`의 `status`, `policy.nextAPI`(429 대기 중인지), `lastAPI.fetchedAt`
3. 키체인 토큰 만료 여부(값은 출력하지 말 것):
   `security find-generic-password -s "Claude Code-credentials" -w | python3 -c 'import json,sys,time;o=json.load(sys.stdin)["claudeAiOauth"];print("%.0f min left"%((o["expiresAt"]/1000-time.time())/60))'`
4. API 응답 형식이 바뀌어 패널에 "조회 실패(응답 형식 변경)"가 뜨면 `UsageResponse.swift`와 픽스처를 새 형식에 맞춘다
