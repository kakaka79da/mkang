# iMac 듀얼 부팅 가이드 — macOS + Ubuntu (AI 전용 GPU 가속)

## 개요

| | macOS | Ubuntu (Linux) |
|---|---|---|
| 용도 | 기존 작업 그대로 | AI 전용 (GPU 가속) |
| AI 속도 | CPU 10~15 t/s | **GPU 50~80 t/s** |
| 텔레그램 봇 | ✅ 작동 (launchd) | ✅ 작동 (systemd) |

- 두 OS는 동시에 켜지지 않고, 한 번에 하나씩 부팅됩니다.
- **양쪽 모두에 AI 시스템이 설치**되므로 어느 쪽으로 부팅해도 텔레그램 봇은 작동합니다.

### 🔄 텔레그램으로 OS 오가기 (`/switch`)

설치가 끝나면 컴퓨터 앞에 갈 필요 없이 **텔레그램에서 OS를 전환**할 수 있습니다:

```
macOS로 켜져 있을 때:  /switch yes  →  재부팅 → Ubuntu로 부팅 → Ubuntu 봇 응답
Ubuntu로 켜져 있을 때: /switch yes  →  재부팅 → macOS로 부팅 → macOS 봇 응답
```

"다음 1회만" 반대편으로 부팅하는 방식이라 기본 부팅 설정은 바뀌지 않으며,
재부팅 후 2~3분이면 반대편 OS의 봇이 자동 시작되어 응답합니다.

### iMac 연식 자동 대응

스크립트가 T2 보안칩 유무를 자동 감지해 알맞게 진행합니다:

| | iMac 2019 (T2 없음) | iMac 2020 (T2 있음) |
|---|---|---|
| Ubuntu ISO | 공식 일반판 | t2linux 패치판 (자동 다운로드) |
| 시동 보안 해제 | **불필요 — 건너뜀** | 복구 모드에서 필요 |
| WiFi 펌웨어 추출 | 불필요 | 자동 추출 |

## 준비물

- USB 메모리 16GB 이상 (내용 지워짐)
- USB **유선 키보드/마우스** 권장 (설치 중 블루투스 안 될 수 있음)
- 가능하면 **유선랜(이더넷) 연결** (설치 중 WiFi가 안 잡힐 경우 대비)
- 백업 (Time Machine 권장)

---

## 1단계 — macOS에서 준비 (자동)

```bash
cd ~/mkang && git pull origin claude/compassionate-sagan-2QGA4
bash ai-employee/dualboot_prepare.sh 250    # 숫자 = Linux용 GB
```

스크립트가 자동으로:
1. T2 칩/공간 확인
2. 알맞은 Ubuntu ISO 다운로드 (~6GB)
3. USB 부팅 디스크 제작 (USB 꽂고 디스크 번호 입력)
4. (T2일 때만) WiFi/블루투스 펌웨어 추출
5. 텔레그램 `/switch` 도구 설치 (macOS 쪽)
6. APFS 파티션 축소 → Linux용 빈 공간 확보

## 2단계 — 시동 보안 해제 (T2 맥만, 2019형은 건너뜀)

> 1단계에서 "T2 칩 없음"이 나왔다면 이 단계는 **건너뛰세요.**

1. 재시동 → 사과 로고 전까지 **⌘+R** 꾹 → 복구 모드 진입
2. 메뉴 막대 **유틸리티 > 시동 보안 유틸리티**
3. 관리자 암호 입력 후:
   - 보안 부팅: **보안 없음(No Security)**
   - 외부 부팅: **외부 미디어 부팅 허용**
4. 재시동

## 3단계 — Ubuntu 설치 (수동, 30분)

1. USB 꽂고 재시동 → 즉시 **Option(⌥)** 꾹 → 주황색 **EFI Boot** 선택
2. "Try or Install Ubuntu" → 설치 진행 ("서드파티 드라이버 설치" 체크 권장)
3. 설치 유형에서:
   - **"macOS와 함께 설치(Install alongside)"가 보이면 그걸 선택** (가장 쉬움)
   - 안 보이면 "기타(Something else)" → **빈 공간(free space)** 선택 → `+` 버튼 →
     ext4, 마운트 위치 `/` 로 생성 → 설치
   - ⚠️ **APFS(macOS) 파티션은 절대 건드리지 마세요**
4. 사용자 계정 만들고 설치 완료 → 재부팅 (USB 제거)

## 4단계 — Ubuntu에서 AI 시스템 설치 (자동)

Ubuntu 부팅 후 터미널(Ctrl+Alt+T):

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/kakaka79da/mkang ~/mkang
bash ~/mkang/ai-employee/linux_ai_setup.sh
```

자동으로: ROCm(GPU 드라이버) → GPU 종류 감지(5700 XT/Vega 48 모두 지원) →
llama.cpp GPU 빌드 → macOS 파티션에서 config.py/모델 복사(가능하면) →
부팅 자동 시작 등록 → `/switch` 도구 설치 → 즉시 가동.

> GPU 권한은 재부팅 후 적용되는 경우가 있습니다. 봇이 CPU 모드로 떴다면
> `sudo reboot` 한 번이면 GPU 모드로 올라옵니다.

## 5단계 — 기본 부팅 OS 정하기

`/switch`는 "다음 1회"만 바꾸므로, **평소에 어느 OS로 켜질지**는 따로 정합니다:

- 부팅 선택 화면(Option 부팅)에서 원하는 디스크에 커서 → **Control(⌃) 누른 채 클릭**
  → 화살표가 원형으로 바뀌며 기본 부팅으로 고정
- macOS에서는 시스템 설정 > 일반 > 시동 디스크에서도 변경 가능
- **추천**: 기본값 = Ubuntu (AI 24시간 GPU 가동), 맥 쓸 일 있을 때 `/switch yes`

---

## 문제 해결

| 증상 | 해결 |
|---|---|
| USB가 부팅 목록에 없음 | (T2만) 2단계 시동 보안 다시 확인 |
| 설치 화면에서 내장 SSD 안 보임 | T2 맥인데 일반 ISO를 쓴 경우 — 스크립트로 다시 |
| Ubuntu에서 WiFi 안 잡힘 | 유선랜 연결 후 `sudo apt install bcmwl-kernel-source` 또는 추가 드라이버 설정 |
| 블루투스 키보드 안 됨 | 설치 중에는 유선 사용 |
| GPU 인식 안 됨 (`rocminfo`) | `sudo reboot` 후 재시도 (render 그룹 권한 반영) |
| /switch 가 "도구 미설치" 응답 | 해당 OS에서 `bash ~/mkang/ai-employee/setup_os_switch.sh` 실행 |
| /switch 후 엉뚱한 OS로 부팅 | 드물게 펌웨어가 무시 — Option(⌥) 부팅으로 수동 선택 |
| 봇 상태 확인 (Ubuntu) | `systemctl status ai-employee` / `tail -f ~/mkang/ai-employee/logs/llm.log` |

## 운용 팁

- **Ubuntu로 켜두면**: GPU 가속 AI가 24시간 텔레그램 대기 (50~80 t/s)
- **macOS로 켜두면**: 기존 launchd 자동 시작으로 CPU 모드 AI 작동 (10~15 t/s)
- `/status` 로 지금 어느 OS인지 텔레그램에서 바로 확인 가능
- 모델/설정은 양쪽에 각각 존재하므로 한쪽을 수정해도 다른 쪽에 영향 없음
