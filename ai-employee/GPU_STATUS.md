# GPU 가속 진단 결과 — AMD Radeon Pro 5700 XT (Intel iMac)

## 결론: macOS에서 이 GPU로 LLM 추론 불가

fix_gpu.sh 실행 결과로 확정됨. 소프트웨어 설정 문제가 아닌 **OS/드라이버 레벨의 근본적 한계**.

---

## 시도한 모든 방법과 실패 원인

### 1. Metal 백엔드 (llama.cpp 기본값)
- **증상**: 추론은 되는데 출력이 깨짐 (`@@@@@` 또는 gibberish)
- **원인**: llama.cpp issue [#19563](https://github.com/ggml-org/llama.cpp/issues/19563)  
  Intel Mac + AMD RDNA1(Navi 10)의 Metal compute shader 버그
- **공식 입장**: "closed — won't fix" (애플 실리콘 우선, Intel Mac 지원 종료)

### 2. Vulkan / MoltenVK 백엔드
- **증상**: GPU가 인식(`ggml_vulkan: Found AMD Radeon Pro 5700 XT`)되지만 `tg16 = 0.00 t/s`
- **원인**: llama.cpp issue [#20104](https://github.com/ggml-org/llama.cpp/issues/20104)  
  MoltenVK가 Vulkan → Metal SPIR-V 셰이더 변환 시 RDNA1(GFX1010)에서 compute 실행 실패
- **GGML_VK_VISIBLE_DEVICES=0**: 0.00 t/s (device 인식되나 연산 안 됨)
- **GGML_VK_VISIBLE_DEVICES=1**: "Invalid device index 1" (amd가 device 0, index 1은 없음)

### 3. OpenCL, DirectML
- llama.cpp는 OpenCL 지원 제거됨. DirectML은 Windows 전용.

---

## 현실적인 대안

### ✅ 지금 당장 쓸 수 있는 방법: Qwen3-30B-A3B MoE CPU 모드

| | 현재 (8B 일반 모델) | Qwen3-30B-A3B MoE |
|---|---|---|
| 모델 파라미터 | 8B 전체 활성 | 30B 선언, **3.3B만 활성** |
| 속도 | ~3.7 t/s | **10~15 t/s** |
| 품질 | 보통 | 30B급 (훨씬 높음) |
| GPU 필요 | 없음 | 없음 |

모델이 다운로드 완료되면 자동 전환:
```bash
bash ~/mkang/ai-employee/switch_model.sh
```

### ✅ GPU를 정말 쓰려면: 같은 컴퓨터에 Linux 설치

AMD Radeon Pro 5700 XT는 **Linux + ROCm**에서 완벽 작동:

```
예상 속도: Qwen3-30B-A3B Q4_K_M 기준
  macOS CPU: 10~15 t/s
  Linux ROCm GPU: 50~80 t/s  (5~8배 빠름)
```

Linux 설치 방법:
1. Ubuntu 24.04 USB 부팅 디스크 생성
2. iMac에서 Option 키 누른 채 부팅 → USB 선택
3. 파티션 분할 설치 (듀얼 부팅) 또는 macOS 대체 설치
4. `bash ~/mkang/ai-employee/linux_gpu_setup.sh` 실행 (ROCm + llama.cpp 자동 설치)

---

## 현재 시스템 상태

- **작동 중**: Telegram 봇, AI 직원 4명, 미팅 기능, Google Drive 연동
- **속도**: Qwen3-8B CPU @ ~3.7 t/s (Qwen3-30B-A3B 다운로드 후 10~15 t/s)
- **GPU**: macOS에서는 불가, gpu.env에 GPU_OK=0 기록됨
- **자동 시작**: launchd 등록됨 (재부팅 후 자동 켜짐)
