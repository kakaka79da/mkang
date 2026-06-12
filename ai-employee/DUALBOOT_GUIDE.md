# iMac 듀얼 부팅 가이드 — macOS + Ubuntu (AI 전용 GPU 가속)

## 개요

| | macOS | Ubuntu (Linux) |
|---|---|---|
| 용도 | 기존 작업 그대로 | AI 전용 (GPU 가속) |
| AI 속도 | CPU 10~15 t/s | **GPU 50~80 t/s** |
| 텔레그램 봇 | ✅ 작동 (launchd) | ✅ 작동 (systemd) |

- 두 OS는 **동시에 켜지지 않고**, 전원 켤 때 **Option(⌥) 키를 꾹 눌러** 선택합니다.
- **양쪽 모두에 AI 시스템이 설치**되므로 어느 쪽으로 부팅해도 텔레그램 봇은 작동합니다.
- 평소엔 **Ubuntu를 기본 부팅**으로 두고(AI 24시간 가동, 5배 빠름), 맥 작업이 필요할 때만 재부팅해서 macOS를 선택하는 운용을 추천합니다.

> ⚠️ iMac 2020은 **Apple T2 보안칩**이 있어 일반 Ubuntu로는 내장 SSD를 인식하지 못합니다.
> 반드시 아래 스크립트가 받아주는 **t2linux 패치판 Ubuntu**를 사용하세요.

## 준비물

- USB 메모리 16GB 이상 (내용 지워짐)
- USB **유선 키보드/마우스** 권장 (설치 중 블루투스 안 될 수 있음)
- 백업 (Time Machine 권장)

---

## 1단계 — macOS에서 준비 (자동)

```bash
cd ~/mkang && git pull origin claude/compassionate-sagan-2QGA4
bash ai-employee/dualboot_prepare.sh 250    # 숫자 = Linux용 GB
```

스크립트가 자동으로:
1. T2 칩/공간 확인
2. t2linux Ubuntu ISO 다운로드 (~6GB)
3. USB 부팅 디스크 제작 (USB 꽂고 디스크 번호 입력)
4. WiFi/블루투스 펌웨어 추출 (질문 나오면 그냥 엔터 = EFI에 저장)
5. APFS 파티션 250GB 축소 → Linux용 빈 공간 확보

## 2단계 — 시동 보안 해제 (수동, T2 필수)

1. 재시동 → 사과 로고 전까지 **⌘+R** 꾹 → 복구 모드 진입
2. 메뉴 막대 **유틸리티 > 시동 보안 유틸리티**
3. 관리자 암호 입력 후:
   - 보안 부팅: **보안 없음(No Security)**
   - 외부 부팅: **외부 미디어 부팅 허용**
4. 재시동

## 3단계 — Ubuntu 설치 (수동, 30분)

1. USB 꽂고 재시동 → 즉시 **Option(⌥)** 꾹 → 주황색 **EFI Boot** 선택
2. "Try or Install Ubuntu" → 설치 진행
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

자동으로: ROCm(GPU 드라이버) → llama.cpp GPU 빌드 → AI 시스템 설치 →
macOS 파티션에서 config.py/모델 복사(가능하면) → systemd 부팅 자동 시작 등록 → 즉시 가동.

> GPU 권한은 재부팅 후 적용되는 경우가 있습니다. 봇이 CPU 모드로 떴다면
> `sudo reboot` 한 번이면 GPU 모드로 올라옵니다.

## 5단계 — 기본 부팅 OS 설정

- 부팅 시 **Option(⌥)** 으로 매번 선택하거나,
- 부팅 선택 화면에서 원하는 디스크에 커서를 두고 **Control(⌃)을 누른 채 클릭**
  → 화살표가 원형으로 바뀌며 **기본 부팅 디스크로 고정**됩니다.
- macOS에서는 시스템 설정 > 일반 > 시동 디스크에서도 변경 가능.

---

## 문제 해결

| 증상 | 해결 |
|---|---|
| USB가 부팅 목록에 없음 | 2단계 시동 보안(외부 부팅 허용) 다시 확인 |
| 설치 화면에서 내장 SSD 안 보임 | t2linux ISO 가 맞는지 확인 (일반 Ubuntu는 불가) |
| Ubuntu에서 WiFi 안 잡힘 | 1단계 펌웨어 추출을 했는지 확인. 임시로 유선랜/USB 테더링 |
| 블루투스 키보드 안 됨 | 설치 중에는 유선 사용, 설치 후엔 펌웨어로 해결됨 |
| GPU 인식 안 됨 (`rocminfo`) | `sudo reboot` 후 재시도 (render 그룹 권한 반영) |
| 봇 상태 확인 | `systemctl status ai-employee` / `tail -f ~/mkang/ai-employee/logs/llm.log` |
| macOS로 돌아가기 | 재시동 → Option(⌥) → Macintosh HD |

## 운용 팁

- **Ubuntu로 켜두면**: GPU 가속 AI가 24시간 텔레그램 대기 (50~80 t/s)
- **macOS로 켜두면**: 기존 launchd 자동 시작으로 CPU 모드 AI 작동 (10~15 t/s)
- 모델/설정은 양쪽에 각각 존재하므로 한쪽을 수정해도 다른 쪽에 영향 없음
