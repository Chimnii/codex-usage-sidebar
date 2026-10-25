# 구조와 개발

| 모듈 | 책임 |
|---|---|
| patcher/ | ASAR/PE 구조 검사, Layer 연결, 파일 검증·복구 |
| collector/ | 공급자별 사용량 조회와 정규화한 JSON·캐시 |
| tweak/ | Layer 연결, 사용량 UI, 업데이트 메뉴 |
| scripts/ | 의존성, 설정, 복사본 관리, Store 업데이트, 배포 |

수집기는 UI에 의존하지 않습니다. 설치 시에만 확장 안으로 복사됩니다.
Layer 1.1.4와 ASAR 3.4.1은 package-lock.json으로 고정합니다.
scripts/patch-layer-runtime.cjs는 Layer의 설정 경로가 CODEX_HOME을 따르게 하고,
사용하지 않는 MCP 자동 동기화를 차단해 원본 사용자 설정을 보존합니다.
기존 설정 호환을 위해 내부 확장 ID local.sidebar-usage-demo는 유지합니다.

관리 복사본은 `active` 한 벌만 유지합니다. `staging`에서 새 버전을 완성하고 교체 중에만 `retired`에 기존 실행본을 둡니다.
교체 기록으로 중단을 복구하며, 완료 후 이전 버전과 임시 파일을 정리합니다. Restore.cmd는 Store 원본에서 재생성합니다.
일반 리소스는 robocopy와 목록·크기로 확인하고, 패치할 두 파일은 원본에서 직접 생성해 staging으로 이동합니다.
관리 복사본 패치는 구조·원본 변경·최종 파일을 검사하며 범용 파일 교체 도구의 추가 백업·반복 해시는 사용하지 않습니다.
수집기는 `active/app/resources/codex.exe`를 재사용합니다. 기존 설정은 별도 CLI 경로도 계속 읽을 수 있습니다.

Node 20 이상과 Windows PowerShell 5.1/7에서:

```powershell
npm ci --ignore-scripts
npm test
npm run test:windows
npm run release
```

브라우저 시험은 설치된 Microsoft Edge를 사용합니다. 자동 시험은 합성 앱·프로필만 사용합니다.
실제 Store 업데이트와 실제 앱 실행 검증은 계정이 있는 로컬 환경에서 별도로 수행합니다.
[호환성 기록](COMPATIBILITY.md)은 구조 검증과 실제 앱 사용 검증을 구분합니다.
release는 허용 목록의 소스만 검사·패키징해 .local/releases/에 만듭니다.
앱 파일·개인 설정·로그·캐시·백업을 커밋하거나 프로젝트 폴더 전체를 배포하지 마세요.
