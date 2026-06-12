# 구글 드라이브 연동 설정 (1회만 하면 됨)

AI 직원이 미팅록·보고서를 드라이브에 저장하고, 드라이브 문서를 읽고 요약할 수 있게 합니다.

## 1단계: Google Cloud 프로젝트 만들기 (5분)

1. https://console.cloud.google.com 접속 → 구글 계정 로그인
2. 상단 프로젝트 선택 → **새 프로젝트** → 이름 `ai-employee` → 만들기
3. 왼쪽 메뉴 **API 및 서비스 → 라이브러리**
4. `Google Drive API` 검색 → **사용 설정** 클릭

## 2단계: OAuth 동의 화면 (3분)

1. **API 및 서비스 → OAuth 동의 화면**
2. User Type: **외부** 선택 → 만들기
3. 앱 이름 `AI Employee`, 사용자 지원 이메일 = 본인 이메일 → 저장 후 계속
4. 범위(Scopes)는 건너뛰고 계속
5. **테스트 사용자**에 본인 Gmail 주소 추가 ← 중요!
6. 저장

## 3단계: OAuth 클라이언트 ID 발급 (2분)

1. **API 및 서비스 → 사용자 인증 정보**
2. **+ 사용자 인증 정보 만들기 → OAuth 클라이언트 ID**
3. 애플리케이션 유형: **데스크톱 앱** → 만들기
4. **JSON 다운로드** 클릭
5. 다운로드한 파일을 `credentials.json` 으로 이름 변경 후 이동:

```bash
mv ~/Downloads/client_secret_*.json ~/mkang/ai-employee/credentials.json
```

## 4단계: 최초 인증 (1분)

아이맥 터미널에서:

```bash
cd ~/mkang/ai-employee
source venv/bin/activate
pip install google-api-python-client google-auth-httplib2 google-auth-oauthlib
python gdrive.py
```

- 브라우저가 자동으로 열림 → 구글 로그인 → "확인되지 않은 앱" 경고가 나오면
  **고급 → AI Employee(안전하지 않음)으로 이동** 클릭 → 허용
- 터미널에 `✅ 인증 성공!` 이 보이면 끝
- `token.json` 이 생성되며, 이후에는 자동 갱신됩니다

## 5단계: 시스템 재시작

```bash
bash ~/mkang/ai-employee/stop.sh
bash ~/mkang/ai-employee/start.sh
```

## 사용법 (텔레그램에서)

| 명령 | 동작 |
|------|------|
| `/drive` | 드라이브 최근 파일 목록 |
| `/drive 기획서` | 이름에 '기획서'가 들어간 파일 검색 |
| `/read 사업계획.docx` | 파일 읽고 분석가 AI가 요약 |
| `/report 6월 매출 분석` | AI가 보고서 작성 → 드라이브 자동 저장 |
| `/meeting 신제품 전략` | 팀 미팅 → 미팅록 드라이브 자동 저장 |
| `/chat dev analyst 주제` | AI 둘이서 토론 |

미팅록과 보고서는 드라이브의 **AI-Employee** 폴더에 자동 저장됩니다.

## 보안 주의

- `credentials.json` 과 `token.json` 은 **절대 깃에 커밋하지 마세요** (.gitignore 처리됨)
- 이 파일이 있으면 누구나 내 드라이브에 접근 가능합니다
