"""구글 드라이브 연동 — AI 직원의 파일 저장소.

사전 준비 (GOOGLE_DRIVE_SETUP.md 참고):
  1. Google Cloud Console 에서 OAuth 클라이언트(데스크톱 앱) 생성
  2. credentials.json 을 이 폴더에 저장
  3. 최초 1회 `python gdrive.py` 실행 → 브라우저에서 구글 로그인
     → token.json 자동 생성, 이후 자동 갱신
"""

import io
import os

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaIoBaseUpload

DIR = os.path.dirname(os.path.abspath(__file__))
CREDENTIALS_FILE = os.path.join(DIR, "credentials.json")
TOKEN_FILE = os.path.join(DIR, "token.json")

SCOPES = ["https://www.googleapis.com/auth/drive"]

# AI 직원이 사용하는 드라이브 폴더 이름
WORK_FOLDER = "AI-Employee"

# 구글 문서류는 export, 일반 파일은 download 로 읽는다
_EXPORT_AS_TEXT = {
    "application/vnd.google-apps.document": "text/plain",
    "application/vnd.google-apps.spreadsheet": "text/csv",
    "application/vnd.google-apps.presentation": "text/plain",
}
_TEXT_MIMES = ("text/", "application/json", "application/xml")


class DriveClient:
    """지연 초기화 싱글턴 — 토큰 없으면 첫 호출 때 브라우저 인증."""

    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._service = None
            cls._instance._folder_id = None
        return cls._instance

    # ── 인증 ────────────────────────────────────────────────────────────────

    def _auth(self):
        creds = None
        if os.path.exists(TOKEN_FILE):
            creds = Credentials.from_authorized_user_file(TOKEN_FILE, SCOPES)
        if not creds or not creds.valid:
            if creds and creds.expired and creds.refresh_token:
                creds.refresh(Request())
            else:
                if not os.path.exists(CREDENTIALS_FILE):
                    raise FileNotFoundError(
                        "credentials.json 이 없습니다. "
                        "GOOGLE_DRIVE_SETUP.md 의 안내대로 발급 후 ai-employee/ 에 두세요."
                    )
                flow = InstalledAppFlow.from_client_secrets_file(CREDENTIALS_FILE, SCOPES)
                creds = flow.run_local_server(port=0)
            with open(TOKEN_FILE, "w") as f:
                f.write(creds.to_json())
        return creds

    @property
    def service(self):
        if self._service is None:
            self._service = build("drive", "v3", credentials=self._auth())
        return self._service

    def is_configured(self) -> bool:
        """인증 파일이 준비됐는지 (네트워크 호출 없이) 확인."""
        return os.path.exists(TOKEN_FILE) or os.path.exists(CREDENTIALS_FILE)

    # ── 폴더 ────────────────────────────────────────────────────────────────

    def work_folder_id(self) -> str:
        """AI-Employee 작업 폴더 ID (없으면 생성)."""
        if self._folder_id:
            return self._folder_id
        res = self.service.files().list(
            q=f"name='{WORK_FOLDER}' and mimeType='application/vnd.google-apps.folder' "
              f"and trashed=false",
            fields="files(id)",
        ).execute()
        files = res.get("files", [])
        if files:
            self._folder_id = files[0]["id"]
        else:
            meta = {"name": WORK_FOLDER, "mimeType": "application/vnd.google-apps.folder"}
            self._folder_id = self.service.files().create(
                body=meta, fields="id").execute()["id"]
        return self._folder_id

    # ── 목록 / 검색 ─────────────────────────────────────────────────────────

    def list_files(self, query: str = "", n: int = 15) -> list[dict]:
        """드라이브 파일 목록. query 가 있으면 이름으로 검색."""
        q = "trashed=false"
        if query:
            safe = query.replace("'", "\\'")
            q += f" and name contains '{safe}'"
        res = self.service.files().list(
            q=q,
            pageSize=n,
            orderBy="modifiedTime desc",
            fields="files(id, name, mimeType, modifiedTime, size)",
        ).execute()
        return res.get("files", [])

    # ── 읽기 ────────────────────────────────────────────────────────────────

    def read_file(self, name_or_id: str, max_chars: int = 8000) -> str:
        """파일 내용을 텍스트로 읽는다. 이름으로 찾으면 가장 최근 수정본 사용."""
        meta = self._resolve(name_or_id)
        if meta is None:
            return f"(파일을 찾지 못했습니다: {name_or_id})"

        fid, mime, fname = meta["id"], meta.get("mimeType", ""), meta["name"]

        if mime in _EXPORT_AS_TEXT:
            request = self.service.files().export_media(
                fileId=fid, mimeType=_EXPORT_AS_TEXT[mime])
        elif mime.startswith(_TEXT_MIMES):
            request = self.service.files().get_media(fileId=fid)
        else:
            return f"(텍스트로 읽을 수 없는 형식입니다: {fname} — {mime})"

        buf = io.BytesIO()
        downloader = MediaIoBaseDownload(buf, request)
        done = False
        while not done:
            _, done = downloader.next_chunk()
        text = buf.getvalue().decode("utf-8", errors="replace")
        if len(text) > max_chars:
            text = text[:max_chars] + f"\n\n…(총 {len(text)}자 중 앞 {max_chars}자만 표시)"
        return text

    def _resolve(self, name_or_id: str) -> dict | None:
        # 드라이브 파일 ID 형식이면 직접 조회
        if len(name_or_id) > 20 and " " not in name_or_id:
            try:
                return self.service.files().get(
                    fileId=name_or_id, fields="id, name, mimeType").execute()
            except Exception:
                pass
        files = self.list_files(query=name_or_id, n=1)
        return files[0] if files else None

    # ── 쓰기 ────────────────────────────────────────────────────────────────

    def upload_text(self, name: str, content: str) -> str:
        """텍스트를 AI-Employee 폴더에 파일로 저장. 웹 링크 반환."""
        media = MediaIoBaseUpload(
            io.BytesIO(content.encode("utf-8")), mimetype="text/plain")
        meta = {"name": name, "parents": [self.work_folder_id()]}
        f = self.service.files().create(
            body=meta, media_body=media, fields="id, webViewLink").execute()
        return f.get("webViewLink", f"https://drive.google.com/file/d/{f['id']}")

    def upload_file(self, local_path: str, name: str | None = None) -> str:
        """로컬 파일을 AI-Employee 폴더에 업로드. 웹 링크 반환."""
        from googleapiclient.http import MediaFileUpload
        name = name or os.path.basename(local_path)
        meta = {"name": name, "parents": [self.work_folder_id()]}
        media = MediaFileUpload(local_path, resumable=True)
        f = self.service.files().create(
            body=meta, media_body=media, fields="id, webViewLink").execute()
        return f.get("webViewLink", f"https://drive.google.com/file/d/{f['id']}")


drive = DriveClient()


if __name__ == "__main__":
    # 최초 인증 테스트: python gdrive.py
    print("구글 드라이브 인증 시작 (브라우저가 열립니다)...")
    files = drive.list_files(n=5)
    print(f"✅ 인증 성공! 최근 파일 {len(files)}개:")
    for f in files:
        print(f"  - {f['name']}")
    print(f"✅ 작업 폴더 준비: {WORK_FOLDER} (id={drive.work_folder_id()})")
