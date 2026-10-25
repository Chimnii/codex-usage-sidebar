# 구조와 개발

| 모듈 | 책임 |
|---|---|
| patcher/ | ASAR/PE 구조 검사, Layer 연결, 파일 검증·복구 |
| collector/ | 공급자별 사용량 조회와 정규화한 JSON·캐시 |
| tweak/ | Layer 연결, 사용량 UI, 업데이트 메뉴 |
| scripts/ | 의존성, 설정, 복사본 관리, Store 업데이트, 배포 |

수집기는 UI에 의존하지 않습니다. 설치 시에만 확장 안으로 복사됩니다.
Layer 1.1.4와 ASAR 3.4.1은 package-lock.json으로 고정합니다.
scripts/patch-layer-runtime.cjs는 Layer의 설정 경로가 CODEX_HOME을 따르게 합니다.
기존 설정 호환을 위해 내부 확장 ID local.sidebar-usage-demo는 유지합니다.

Node 20 이상과 Windows PowerShell 5.1/7에서:

```powershell
npm ci --ignore-scripts
npm test
npm run test:windows
npm run release
```

브라우저 시험은 설치된 Microsoft Edge를 사용합니다. 자동 시험은 합성 앱·프로필만 사용합니다.
실제 Store 업데이트와 실제 앱 실행 검증은 계정이 있는 로컬 환경에서 별도로 수행합니다.
release는 허용 목록의 소스만 검사·패키징해 .local/releases/에 만듭니다.
앱 파일·개인 설정·로그·캐시·백업을 커밋하거나 프로젝트 폴더 전체를 배포하지 마세요.
