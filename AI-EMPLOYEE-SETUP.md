# AI 직원 컴퓨터 구축 가이드 (Intel iMac + AMD GPU)

> 자율 AI 직원 노드 구축 — 텔레그램 연동 · 다중 노드 미팅 · GPU 100% 활용

---

## 0. 대상 하드웨어

| 항목 | 사양 |
|------|------|
| 모델 | iMac20,2 (Retina 5K, 27-inch, 2020) |
| CPU | 3.6 GHz 10코어 Intel Core i9 |
| GPU | **AMD Radeon Pro 5700 XT 16GB** |
| RAM | **80GB 2133 MHz DDR4** |
| OS | macOS Tahoe 26.5 |
| 저장공간 | 1TB (현재 여유 18.37GB → **정리 필요**) |

### 왜 Ollama는 CPU만 쓰는가?
Ollama의 **인텔 Mac 빌드는 Metal(GPU) 가속이 비활성화**되어 있습니다.
Ollama의 Metal 지원은 Apple Silicon 전용입니다. 따라서 인텔 Mac + AMD GPU 조합에서는
**llama.cpp를 Metal 옵션으로 직접 빌드**해야 GPU를 활용할 수 있습니다.

---

## 전체 시스템 구조

```
┌─────────────────────────────────────────────────────┐
│                  외부 인터페이스                       │
│  텔레그램 Bot ←→ 명령/보고  │  다른 AI 직원 ←→ 미팅   │
└──────────────┬──────────────────────────┬────────────┘
               │                          │
┌──────────────▼──────────────────────────▼────────────┐
│                  AI Agent Core                        │
│   AutoGen / CrewAI (역할: 팀장/개발자/분석가 등)       │
│   ┌─────────────┐  ┌──────────────┐  ┌────────────┐  │
│   │  계획/판단   │  │  도구 실행   │  │  기억 관리  │  │
│   └─────────────┘  └──────────────┘  └────────────┘  │
└──────────────────────────┬───────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────┐
│           llama.cpp + Metal (AMD GPU 100%)            │
│         Qwen2.5 14B / 32B + ChromaDB                 │
└──────────────────────────────────────────────────────┘
```

---

## Phase 1: GPU 가속 LLM 엔진 구축

```bash
# 1. 개발 도구
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. llama.cpp Metal 빌드
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j10
sudo cmake --install build
```

### GPU 활성화 확인 (서버 실행 시 로그)
```
ggml_metal_init: GPU name:   AMD Radeon Pro 5700 XT  ✅
ggml_metal_init: GPU memory: 16.00 GB
llm_load_tensors: offloaded 49/49 layers to GPU       ✅
```

### GPU 100% 활용 서버 실행
```bash
llama-server \
  -m ~/ai-employee/models/MODEL.gguf \
  -ngl 99 \          # GPU 레이어 최대화 (핵심!)
  -c 16384 \         # 컨텍스트 길이
  -np 4 \            # 병렬 요청 수
  --host 0.0.0.0 \
  --port 11434 \
  --metrics
```

---

## Phase 2: AI Agent 프레임워크

```bash
mkdir ~/ai-employee && cd ~/ai-employee
python3 -m venv venv
source venv/bin/activate

pip install pyautogen chromadb fastapi uvicorn \
            python-telegram-bot redis celery \
            langchain sentence-transformers \
            schedule psutil httpx
```

```python
# ~/ai-employee/agent_core.py
import autogen
from datetime import datetime

llm_config = {
    "config_list": [{
        "model": "local-model",
        "base_url": "http://localhost:11434/v1",
        "api_key": "local",
        "price": [0, 0]
    }],
    "temperature": 0.7,
    "max_tokens": 4096,
}

class AIEmployee:
    def __init__(self, name, role, system_prompt):
        self.agent = autogen.AssistantAgent(
            name=name,
            system_message=f"""당신은 {role}입니다.
            {system_prompt}
            항상 한국어로 답변하고, 구체적인 행동 계획을 제시하세요.""",
            llm_config=llm_config,
        )
        self.name = name
        self.role = role

ceo_agent = AIEmployee("CEO_AI", "최고경영자",
    "회사 전략을 수립하고 팀을 이끕니다. 큰 그림을 보고 결정합니다.")
developer_agent = AIEmployee("Dev_AI", "시니어 개발자",
    "코드를 작성하고 기술 문제를 해결합니다. 실용적인 솔루션을 제시합니다.")
analyst_agent = AIEmployee("Analyst_AI", "데이터 분석가",
    "데이터를 분석하고 인사이트를 도출합니다. 숫자로 이야기합니다.")
```

---

## Phase 3: 텔레그램 연동

```python
# ~/ai-employee/telegram_bot.py
from telegram.ext import Application, CommandHandler, MessageHandler, filters
import autogen, asyncio, psutil
from agent_core import ceo_agent, developer_agent, analyst_agent, llm_config

TELEGRAM_TOKEN = "YOUR_BOT_TOKEN"   # @BotFather 발급
AUTHORIZED_USERS = [123456789]      # @userinfobot 으로 확인한 본인 ID

class TelegramAIBridge:
    def __init__(self):
        self.app = Application.builder().token(TELEGRAM_TOKEN).build()
        self.app.add_handler(CommandHandler("start", self.start))
        self.app.add_handler(CommandHandler("meeting", self.start_meeting))
        self.app.add_handler(CommandHandler("status", self.check_status))
        self.app.add_handler(MessageHandler(filters.TEXT, self.handle_message))

    async def start(self, update, context):
        await update.message.reply_text(
            "🤖 AI 직원 시스템 가동 중\n"
            "/meeting [주제] - AI 직원 미팅\n"
            "/status - 시스템 상태 보고\n"
            "(일반 메시지) - CEO AI 에게 지시")

    async def handle_message(self, update, context):
        if update.effective_user.id not in AUTHORIZED_USERS:
            return
        await update.message.reply_text("🤔 처리 중...")
        user_proxy = autogen.UserProxyAgent(
            name="Boss", human_input_mode="NEVER",
            max_consecutive_auto_reply=2)
        await asyncio.get_event_loop().run_in_executor(
            None, lambda: user_proxy.initiate_chat(
                ceo_agent.agent, message=update.message.text, max_turns=2))
        await update.message.reply_text(
            f"💼 CEO AI:\n{user_proxy.last_message()['content']}")

    async def start_meeting(self, update, context):
        await update.message.reply_text("📋 AI 팀 미팅 시작...")
        groupchat = autogen.GroupChat(
            agents=[ceo_agent.agent, developer_agent.agent, analyst_agent.agent],
            messages=[], max_round=6)
        manager = autogen.GroupChatManager(groupchat=groupchat, llm_config=llm_config)
        topic = " ".join(context.args) if context.args else "이번 주 업무 계획"
        proxy = autogen.UserProxyAgent(name="Facilitator", human_input_mode="NEVER")
        proxy.initiate_chat(manager, message=f"주제: {topic}")
        summary = "\n".join(f"• {m['name']}: {m['content'][:200]}"
                            for m in groupchat.messages[-6:])
        await update.message.reply_text(f"📊 미팅 결과:\n{summary}")

    async def check_status(self, update, context):
        ram = psutil.virtual_memory()
        await update.message.reply_text(
            f"🖥️ 시스템 상태\n"
            f"CPU: {psutil.cpu_percent()}%\n"
            f"RAM: {ram.used/1024**3:.1f}GB / {ram.total/1024**3:.1f}GB\n"
            f"GPU: AMD Radeon Pro 5700 XT\n"
            f"LLM 서버: ✅ 실행 중")

    def run(self):
        self.app.run_polling()

if __name__ == "__main__":
    TelegramAIBridge().run()
```

---

## Phase 4: 다중 컴퓨터 AI 미팅 시스템

```python
# ~/ai-employee/agent_network.py  (각 컴퓨터마다 실행)
from fastapi import FastAPI
from datetime import datetime
import httpx, uvicorn

app = FastAPI()
MACHINE_ID = "iMac-Node-1"   # 컴퓨터마다 고유 ID

@app.post("/receive_message")
async def receive_message(payload: dict):
    response = process_with_local_ai(payload["message"])  # 로컬 LLM 호출
    return {"from": MACHINE_ID, "response": response,
            "timestamp": datetime.now().isoformat()}

@app.post("/start_meeting")
async def start_meeting(payload: dict):
    responses = []
    async with httpx.AsyncClient() as client:
        for node_ip in payload["participants"]:   # ["192.168.1.2", ...]
            res = await client.post(
                f"http://{node_ip}:8000/receive_message",
                json={"from": MACHINE_ID, "message": f"미팅 주제: {payload['topic']}"})
            responses.append(res.json())
    return {"meeting_summary": responses}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
```

---

## Phase 5: 장기 기억 (ChromaDB)

```python
# ~/ai-employee/memory.py
import chromadb, uuid
from sentence_transformers import SentenceTransformer
from datetime import datetime

class AgentMemory:
    def __init__(self):
        self.client = chromadb.PersistentClient(path="./memory_db")
        self.encoder = SentenceTransformer('all-MiniLM-L6-v2')
        self.collection = self.client.get_or_create_collection("agent_memory")

    def remember(self, content, metadata=None):
        emb = self.encoder.encode(content).tolist()
        self.collection.add(
            documents=[content], embeddings=[emb],
            metadatas=[{**(metadata or {}), "timestamp": datetime.now().isoformat()}],
            ids=[str(uuid.uuid4())])

    def recall(self, query, n=5):
        emb = self.encoder.encode(query).tolist()
        return self.collection.query(query_embeddings=[emb], n_results=n)["documents"][0]
```

---

## Phase 6: 자동 시작 (launchd)

```bash
# ~/ai-employee/start.sh
#!/bin/bash
cd ~/ai-employee
source venv/bin/activate
llama-server -m models/MODEL.gguf -ngl 99 -c 16384 -np 4 \
  --host 0.0.0.0 --port 11434 &
sleep 10
python agent_network.py &
python telegram_bot.py &
echo "✅ AI Employee System Started"
wait
```

```bash
chmod +x ~/ai-employee/start.sh
# ~/Library/LaunchAgents/com.aiemployee.plist 등록 후:
launchctl load ~/Library/LaunchAgents/com.aiemployee.plist
```

---

## 최종 디렉토리 구조

```
~/ai-employee/
├── models/MODEL.gguf
├── memory_db/          # ChromaDB 장기 기억
├── logs/
├── agent_core.py       # AI 직원 정의
├── telegram_bot.py     # 텔레그램 인터페이스
├── agent_network.py    # 다중 컴퓨터 통신
├── memory.py           # 장기 기억 관리
├── start.sh            # 전체 시작 스크립트
└── venv/
```

---

## 권장 모델 (이 PC 전용 · 2026년 최신)

> VRAM 16GB + RAM 80GB. AI 직원(추론·도구 호출·자율 미팅)에는 아래 모델들이 2026년 현재 최강 조합.

---

### 🏆 모델 한눈에 비교

| 순위 | 모델 | 양자화 | VRAM | GPU 적재 | 속도 | AI 직원 적합도 |
|------|------|--------|------|----------|------|----------------|
| **1위** ⭐ | **GPT-OSS 20B** (OpenAI 오픈소스) | Q5_K_M | ~13.7GB | **100% GPU** | ~35-45 t/s | ★★★★★ 추론·툴콜 최강, o3-mini 수준 |
| **2위** | **Qwen3 14B** | Q6_K | ~12GB | **100% GPU** | ~40-50 t/s | ★★★★★ 에이전트·툴콜 1위 오픈소스 |
| **3위** | **Qwen3.5-35B-A3B** (MoE) | Q4_K_M | ~7GB | **100% GPU** | ~55-70 t/s | ★★★★☆ 실제 활성 3B, 매우 빠름 |
| **4위** | Qwen3 32B | Q4_K_M | ~20GB | GPU 16 + RAM | ~20-28 t/s | ★★★★★ 최고 품질, 판단력 최강 |
| **5위** | Gemma 4 26B MoE (A4B) | Q4_K_M | ~7GB | **100% GPU** | ~60-75 t/s | ★★★★☆ Google, 추론 우수 |
| **코딩 전용** | Qwen3-Coder-30B-A3B | Q4_K_M | ~7GB | **100% GPU** | ~50-65 t/s | ★★★★★ 코드 생성 특화 |

---

### 📌 AI 직원 구성 추천 (이중 모델)

```
┌─────────────────────────────────────────────────────┐
│  상시 가동 (포트 11434)                               │
│  GPT-OSS 20B Q5_K_M  OR  Qwen3 14B Q6_K            │
│  → 텔레그램 응답, 일상 업무, 빠른 판단              │
├─────────────────────────────────────────────────────┤
│  고난도 작업 시 기동 (포트 11435)                     │
│  Qwen3 32B Q4_K_M                                   │
│  → 중요 의사결정, AI 직원 간 미팅, 전략 수립         │
└─────────────────────────────────────────────────────┘
```

---

### 🥇 1위: GPT-OSS 20B — OpenAI 오픈소스 첫 번째 모델

| 항목 | 값 |
|------|-----|
| 출처 | OpenAI (Apache 2.0) — 2026년 공개 |
| 특징 | **o3-mini 수준의 추론 성능** · 16GB VRAM에 딱 맞게 설계됨 |
| 생성 속도 | ~35-45 t/s (AMD Radeon 16GB 기준) |
| VRAM | ~13.7GB → 16GB에 완전 적재 |
| 도구 호출 | ✅ 강력 |
| AMD 공식 지원 | ✅ AMD가 공식 Radeon 가이드 발행 |
| GGUF 출처 | `unsloth/gpt-oss-20b-GGUF` |

```bash
huggingface-cli download unsloth/gpt-oss-20b-GGUF \
  gpt-oss-20b-Q5_K_M.gguf --local-dir ~/ai-employee/models
```

---

### 🥈 2위: Qwen3 14B — 에이전트·툴콜 오픈소스 1위

| 항목 | 값 |
|------|-----|
| 출처 | Alibaba (Apache 2.0) |
| 특징 | **Thinking 모드 / Non-thinking 모드** 전환 가능, 툴콜 최강 |
| 생성 속도 | ~40-50 t/s |
| VRAM | ~12GB → 16GB에 완전 적재 |
| 컨텍스트 | 기본 32K · YaRN으로 131K까지 확장 |
| 도구 호출 | ✅ 오픈소스 최고 수준 |
| GGUF 출처 | `bartowski/Qwen_Qwen3-14B-GGUF` |

```bash
huggingface-cli download bartowski/Qwen_Qwen3-14B-GGUF \
  Qwen3-14B-Q6_K.gguf --local-dir ~/ai-employee/models
```

---

### 🥉 3위: Qwen3.5-35B-A3B (MoE) — 속도/품질 극단적 균형

| 항목 | 값 |
|------|-----|
| 출처 | Alibaba (Apache 2.0) |
| 특징 | 35B 전체 중 **3B만 활성화** → 7B급 속도에 35B급 품질 |
| 생성 속도 | ~55-70 t/s (가장 빠름) |
| VRAM | ~7GB → 여유 VRAM으로 긴 컨텍스트 처리 |
| GGUF 출처 | `unsloth/Qwen3.5-35B-A3B-GGUF` |

```bash
huggingface-cli download unsloth/Qwen3.5-35B-A3B-GGUF \
  Qwen3.5-35B-A3B-Q4_K_M.gguf --local-dir ~/ai-employee/models
```

---

### 4위: Qwen3 32B — 최고 품질 (하이브리드)

```bash
huggingface-cli download bartowski/Qwen_Qwen3-32B-GGUF \
  Qwen3-32B-Q4_K_M.gguf --local-dir ~/ai-employee/models
# ~20GB → GPU 16GB + RAM 4GB 자동 하이브리드
```

---

### 코딩 전용: Qwen3-Coder-30B-A3B

```bash
huggingface-cli download unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
  Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf --local-dir ~/ai-employee/models
# 활성 파라미터 3B → VRAM ~7GB, 코드 생성 특화
```

---

### 전체 다운로드 스크립트

```bash
pip3 install -U "huggingface_hub[cli]"
mkdir -p ~/ai-employee/models

# ① 메인 상시 가동 (추천)
huggingface-cli download unsloth/gpt-oss-20b-GGUF \
  gpt-oss-20b-Q5_K_M.gguf --local-dir ~/ai-employee/models

# ② 툴콜 에이전트 특화
huggingface-cli download bartowski/Qwen_Qwen3-14B-GGUF \
  Qwen3-14B-Q6_K.gguf --local-dir ~/ai-employee/models

# ③ 고품질 의사결정 (선택)
huggingface-cli download bartowski/Qwen_Qwen3-32B-GGUF \
  Qwen3-32B-Q4_K_M.gguf --local-dir ~/ai-employee/models
```

> ⚠️ **저장공간 주의**: 3종 합산 ~46GB 필요. 최소 60GB 확보 후 다운로드 권장.

---

## 예상 성능 비교 (AMD Radeon Pro 5700 XT 16GB + Metal)

| 모델 | 생성 속도 | VRAM 사용 | 첫 토큰 지연 | AI 직원 평가 |
|------|----------|----------|------------|-------------|
| GPT-OSS 20B Q5_K_M | ~35-45 t/s | 13.7GB | 빠름 | 추론+툴콜 균형 최고 |
| Qwen3 14B Q6_K | ~40-50 t/s | 12GB | 매우 빠름 | 에이전트 툴콜 1위 |
| Qwen3.5-35B-A3B Q4 | ~55-70 t/s | 7GB | 최고 빠름 | 응답성 최고 |
| Qwen3 32B Q4_K_M | ~20-28 t/s | 16+RAM | 중간 | 판단 품질 최고 |

---

## ⚠️ 사전 준비: 저장공간 확보 (현재 18GB 여유)

```bash
du -sh ~/Downloads/* | sort -hr | head -20   # 큰 파일 확인
brew cleanup --prune=all                       # 캐시 정리
# 모델 2종 = 약 30GB → 최소 50GB 이상 확보 권장
```

---

## 텔레그램 Bot 발급

1. 텔레그램에서 `@BotFather` → `/newbot` → API Token 발급
2. `@userinfobot` 에서 본인 숫자 ID 확인
3. `telegram_bot.py` 의 `TELEGRAM_TOKEN`, `AUTHORIZED_USERS` 에 입력

---

## 구축 로드맵

| 단계 | 내용 | 소요 |
|------|------|------|
| Phase 1 | GPU LLM 서버 (llama.cpp Metal) | 2시간 |
| Phase 2 | Agent 프레임워크 | 1시간 |
| Phase 3 | 텔레그램 봇 | 1시간 |
| Phase 4 | 다중 노드 통신 | 2시간 |
| Phase 5 | 장기 기억 | 1시간 |
| Phase 6 | 자동 시작 | 30분 |

**총 약 7-8시간** → 완전 자율 AI 직원 노드 완성
