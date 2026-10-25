# 설치와 설정

1. Windows x64에서 Store 원본 앱을 열고 로그인합니다.
2. 프로젝트를 계속 사용할 고정 폴더에 둡니다. 앱을 완전히 닫고 Setup.cmd를 실행합니다.
3. 시작 메뉴의 **Codex Usage Sidebar**로 실행하고 작업표시줄에 고정합니다.

처음에는 인터넷 연결이 필요합니다. Node 24.14.0은 해시를 확인해 .local/tools에 설치하며,
라이브러리는 잠금 파일에 맞춰 설치합니다. 시스템 Node나 PATH를 변경하지 않습니다.
원본과 복사본을 동시에 사용하지 마세요. 두 앱은 같은 로그인·대화·설정을 사용합니다.

| 파일 | 역할 |
|---|---|
| Setup.cmd | 최초 설치, 설정 반영, 새 확장 버전 적용, 바로가기 생성 |
| Launch.cmd | 복사본 검사·준비 후 실행. 평소에는 시작 메뉴 바로가기 사용 |
| Update.cmd | Store 원본 업데이트 확인 → 필요 시 업데이트 → 복사본 재패치·실행 |
| Restore.cmd | 직전 복사본 복원. 대화·설정 데이터는 되돌리지 않음 |
| Uninstall.cmd | 복사본과 그 바로가기 제거. 원본·계정·대화·프로젝트 소스 보존 |

## 선택 연결

Antigravity CLI(agy)가 기본 위치에 설치되어 있으면 연결합니다. 없어도 설치가 됩니다.
Claude는 새 설치에서 연결하지 않습니다. 아래 명령은 앱을 종료한 뒤 프로젝트 폴더의 PowerShell에서 실행합니다.

```powershell
# Antigravity 끄기 / 다른 경로 지정
.\scripts\Setup.ps1 -DisableAntigravity
.\scripts\Setup.ps1 -AntigravityPath 'C:\Tools\agy\agy.exe'

# 실험적 Claude 연결 켜기 / 끄기
.\scripts\Setup.ps1 -EnableClaude
.\scripts\Setup.ps1 -DisableClaude
```

Claude는 기존 Claude Code 로그인 파일을 읽습니다. [인증 설명](DATA.md)을 먼저 확인하세요.
기존 설치 갱신 시에는 기존 연결 설정을 보존합니다.
고급 경로는 생성된 .local/settings.json에서 지정할 수 있습니다. 이 파일을 공유하지 마세요.

## 업데이트·복구

- Store 조회는 6시간 간격이며 도움말 메뉴로 즉시 확인할 수 있습니다. 실패하면 1시간 뒤 재시도합니다.
- 앱 하단 업데이트 버튼은 정상 종료를 기다립니다. 작업을 마치고 앱을 완전히 종료하세요.
- Restore.cmd로 복원한 버전은 다음 Setup.cmd 또는 Update.cmd 실행까지 유지합니다.
- 새 프로젝트 소스는 같은 폴더에 갱신하고 Setup.cmd를 실행합니다. 프로젝트 자체의 자동 다운로드는 없습니다.
- 문제가 생기면 복사본을 닫고 Store 원본으로 돌아갈 수 있습니다. .local/copy/last-*-error.json을 확인하세요.
- Store CLI가 없으면 Microsoft Store를 갱신합니다. 원본을 직접 업데이트한 뒤 Setup.cmd를 실행해도 됩니다.
- 프로젝트를 옮기면 기존 바로가기를 쓰지 말고 새 위치에서 Setup.cmd로 다시 준비하세요.
