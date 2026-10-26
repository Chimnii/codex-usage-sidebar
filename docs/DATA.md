# 데이터와 인증

수집기는 이 PC에서 실행합니다. 이 프로젝트가 운영하는 서버는 없습니다.

- GPT: 변경 없는 Codex CLI의 account/rateLimits/read를 호출합니다.
- Antigravity: 설치된 CLI의 /usage를 조회합니다. CLI가 없으면 미연결로 표시합니다.
- Claude: 새 설치에서 기본 활성화하며, 기존 Claude Code OAuth 토큰이 있을 때 Anthropic 사용량 엔드포인트를 조회합니다. 인증정보가 없거나 만료되면 미연결로 표시합니다. Setup의 `-DisableClaude` 옵션으로 끌 수 있습니다.

모델에게 프롬프트를 보내지 않습니다. UI와 캐시에는 정규화한 사용률·시간·상태만 전달하며,
토큰·원본 응답·CLI 오류 전문을 기록하지 않습니다. Claude 토큰을 갱신하거나 덮어쓰지 않습니다.
로그인 파일과 대화 내용은 프로젝트로 복제하지 않습니다.

Claude 직접 OAuth 조회는 공식 공개 API로 보장된 연결이 아닙니다.
[Anthropic 인증·자격증명 조건](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)이 적용되며,
이 연결을 활성화하는 것이 제3자 사용에 대한 별도 허가를 제공하지는 않습니다.

원본과 복사본은 사용자 데이터를 공유합니다. 대화 삭제·설정 변경도 공유되며,
파일 복원은 계정 데이터 복원이 아닙니다. [OpenAI 이용약관](https://openai.com/policies/terms-of-use/)은
오픈소스 라이선스와 별도로 적용됩니다. Layer의 MIT 라이선스가 앱 개조에 대한 허가를 제공하지는 않습니다.
