# config.py — 이 파일을 복사해서 config.py 로 저장 후 값을 채우세요
# cp config.example.py config.py

# ─── 텔레그램 ──────────────────────────────────────────────────────────────
TELEGRAM_TOKEN = "YOUR_BOT_TOKEN"       # @BotFather 에서 발급
AUTHORIZED_USERS = [123456789]          # @userinfobot 에서 확인한 본인 숫자 ID
BOT_NAME = "AI 직원"

# ─── LLM 서버 ──────────────────────────────────────────────────────────────
LLM_HOST = "0.0.0.0"
LLM_PORT_MAIN = 11434       # 상시 가동
LLM_PORT_HQ = 11435         # 고품질 모델 (필요시만)
LLM_CONTEXT = 8192
LLM_PARALLEL = 1

# 모델 파일 경로 (setup.sh 실행 시 자동 설정됨)
# 디스크 여유분에 따라 자동 선택:
#   ≥20GB: gpt-oss-20b-Q5_K_M.gguf   (~13.7GB)
#   ≥14GB: Qwen_Qwen3-14B-Q4_K_M.gguf (~8.4GB)
#   <14GB:  Qwen_Qwen3-8B-Q4_K_M.gguf  (~5GB)
MODEL_MAIN = "~/mkang/ai-employee/models/Qwen_Qwen3-8B-Q4_K_M.gguf"
MODEL_HQ   = "~/mkang/ai-employee/models/Qwen_Qwen3-14B-Q4_K_M.gguf"

# ─── 에이전트 네트워크 ──────────────────────────────────────────────────────
MACHINE_ID   = "iMac-Node-1"            # 이 컴퓨터의 고유 이름
NETWORK_PORT = 8000                     # 다중 노드 API 포트
# 같은 회사의 다른 AI 직원 노드 IP 목록 (추가 컴퓨터 연결 시)
PEER_NODES: list[str] = [
    # "192.168.1.101",
    # "192.168.1.102",
]

# ─── AI 직원 정의 ───────────────────────────────────────────────────────────
EMPLOYEES = {
    "CEO": {
        "name": "CEO_AI",
        "role": "최고경영자",
        "prompt": (
            "당신은 회사의 최고경영자입니다. "
            "전략적 방향을 제시하고, 팀을 이끌며, 중요한 의사결정을 내립니다. "
            "큰 그림을 보고, 장기적 관점에서 판단합니다."
        ),
    },
    "DEV": {
        "name": "Dev_AI",
        "role": "시니어 개발자",
        "prompt": (
            "당신은 시니어 풀스택 개발자입니다. "
            "코드를 작성하고, 기술 문제를 해결하며, 아키텍처를 설계합니다. "
            "실용적이고 효율적인 솔루션을 제시합니다."
        ),
    },
    "ANALYST": {
        "name": "Analyst_AI",
        "role": "데이터 분석가",
        "prompt": (
            "당신은 데이터 분석가입니다. "
            "숫자와 데이터로 인사이트를 도출하고, 의사결정을 지원합니다. "
            "항상 근거를 바탕으로 이야기합니다."
        ),
    },
    "MARKETING": {
        "name": "Marketing_AI",
        "role": "마케팅 전문가",
        "prompt": (
            "당신은 마케팅 전문가입니다. "
            "시장 트렌드를 분석하고, 마케팅 전략을 수립합니다. "
            "고객 관점에서 생각합니다."
        ),
    },
}
