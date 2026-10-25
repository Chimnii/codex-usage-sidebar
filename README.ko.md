# Codex Usage Sidebar

[English](README.md) · **한국어**

Codex Windows 앱 사이드바에 GPT, Antigravity Gemini·Argon, Claude 사용량을 상시 노출시켜주는 비공식 로컬 확장입니다.

- 게이지·사용률·초기화 시간 표시, 약 1분 간격 갱신
- 원본 앱을 보존하고 기존 로그인·대화를 사용하는 별도 복사본
- 작업표시줄 바로가기, Store 업데이트 확인 및 복사본 재패치
- Antigravity·Claude는 선택 사항이며 GPT만으로 사용 가능

사용하지 않도록 끈 서비스는 숨깁니다. 패널에 마우스를 올리거나 키보드로 포커스를 이동하면 새로고침 버튼이 나타나며, 이 버튼을 눌러 사용량을 갱신합니다. 표시 순서·언어·갱신 주기는 [설정 파일](docs/OPTIONS.md)에서 변경할 수 있습니다.

## 동작 방식

`app.asar`에 [ChatGPT Layer](https://github.com/LightHaru/chatgpt-layer)를 주입하고 EXE의 ASAR 무결성 해시를 갱신합니다.
Store 경로의 쓰기 제한을 피해 별도 복사본을 패치하며, 원본 프로필을 공유합니다.

## 시작

Windows x64에서 Microsoft Store 원본 앱을 설치하고 한 번 로그인합니다.
소스를 원하는 고정 폴더에 내려받은 뒤 앱을 완전히 종료하고 **Setup.cmd**를 실행하세요.
프로젝트 전용 Node와 고정 버전 라이브러리를 준비하며 관리자 권한은 필요하지 않습니다.
앱 복사본 한 벌만 유지합니다(검증한 앱 버전 기준 약 2.4GiB). 업데이트 중 임시 파일은 완료 후 정리하며 직전 버전은 보관하지 않습니다. **Restore.cmd**는 설치된 원본에서 다시 생성합니다.

설치 후 시작 메뉴의 **ChatGPT with usage**를 실행하세요. 바로가기를 우클릭해 **작업표시줄에 고정**을 한 번 선택하면 됩니다. Setup은 이미 고정된 항목을 갱신하며, 새 고정 항목을 자동으로 추가하지는 않습니다.
업데이트는 앱의 **도움말 → 업데이트 확인** 또는 하단 업데이트 버튼으로 확인·진행합니다.

[설정·복구 가이드](docs/SETUP.md) · [표시 옵션](docs/OPTIONS.md) · [호환성](docs/COMPATIBILITY.md)

**Doctor.cmd**로 앱을 변경하지 않고 상태를 진단할 수 있습니다. [구조·개발](docs/DEVELOPMENT.md).

앱 바이너리와 계정 정보는 배포하지 않습니다. 복사본은 원본과 사용자 데이터를 공유합니다.
OpenAI 공식 제품이나 승인된 플러그인이 아니며, 앱 수정에는 서비스 이용 조건이 별도로 적용됩니다.
Claude 직접 OAuth 조회는 새 설치에서 기본 비활성화된 실험적 연결입니다.

MIT · [외부 라이브러리 고지](THIRD_PARTY_NOTICES.md) · [인증·데이터 취급](docs/DATA.md)
