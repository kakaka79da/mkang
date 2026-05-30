"""다중 컴퓨터 AI 직원 네트워크 API 서버."""

import logging
import httpx
import uvicorn
from datetime import datetime
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from config import MACHINE_ID, NETWORK_PORT, PEER_NODES
from agent_core import ask_employee, team_meeting
from memory import memory

log = logging.getLogger(__name__)
app = FastAPI(title=f"AI Employee Network — {MACHINE_ID}")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── 스키마 ────────────────────────────────────────────────────────────────────

class MessagePayload(BaseModel):
    from_node: str
    message: str
    context: str = ""

class MeetingPayload(BaseModel):
    topic: str
    participants: list[str] = []   # IP 목록, 빈 경우 PEER_NODES 전체 사용
    max_round: int = 6

class TaskPayload(BaseModel):
    task: str
    assigned_to: str = "CEO"


# ── 엔드포인트 ────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"node": MACHINE_ID, "status": "ok", "time": datetime.now().isoformat()}


@app.post("/message")
async def receive_message(payload: MessagePayload):
    """다른 AI 직원 노드로부터 메시지 수신 및 응답."""
    log.info(f"[{payload.from_node}] → {payload.message[:80]}")

    reply = ask_employee(
        "CEO",
        f"[{payload.from_node} 에서 온 메시지]\n{payload.message}",
    )
    memory.remember(
        f"[네트워크] {payload.from_node}: {payload.message}\n답변: {reply}",
        metadata={"from": payload.from_node},
    )
    return {"from": MACHINE_ID, "reply": reply, "timestamp": datetime.now().isoformat()}


@app.post("/meeting/start")
async def start_network_meeting(payload: MeetingPayload):
    """이 노드가 호스트가 되어 피어 노드들과 미팅 진행."""
    nodes = payload.participants or PEER_NODES
    topic = payload.topic

    # 로컬 미팅 먼저 진행
    local_transcript = team_meeting(topic)
    local_summary = "\n".join(f"{role}: {say[:200]}" for role, say in local_transcript)

    # 피어 노드들에게 결과 공유 및 의견 수집
    peer_replies = []
    async with httpx.AsyncClient(timeout=60) as client:
        for ip in nodes:
            try:
                res = await client.post(
                    f"http://{ip}:{NETWORK_PORT}/message",
                    json={
                        "from_node": MACHINE_ID,
                        "message": f"[미팅 결과 공유] 주제: {topic}\n\n{local_summary}\n\n이에 대한 귀 노드의 의견은?",
                    },
                )
                peer_replies.append({"node": ip, "reply": res.json().get("reply", "")})
            except Exception as e:
                peer_replies.append({"node": ip, "error": str(e)})

    return {
        "host": MACHINE_ID,
        "topic": topic,
        "local_summary": local_summary,
        "peer_replies": peer_replies,
        "timestamp": datetime.now().isoformat(),
    }


@app.get("/peers/status")
async def check_peers():
    """모든 피어 노드 상태 확인."""
    results = []
    async with httpx.AsyncClient(timeout=10) as client:
        for ip in PEER_NODES:
            try:
                res = await client.get(f"http://{ip}:{NETWORK_PORT}/health")
                results.append({"node": ip, **res.json()})
            except Exception as e:
                results.append({"node": ip, "status": "offline", "error": str(e)})
    return {"peers": results}


@app.post("/task")
async def assign_task(payload: TaskPayload):
    """이 노드에 작업 할당."""
    key = payload.assigned_to.upper()
    if key not in {"CEO", "DEV", "ANALYST", "MARKETING"}:
        key = "CEO"
    plan = ask_employee(key, f"[작업 할당] {payload.task}\n실행 계획을 수립하세요.")
    memory.remember(f"[작업] {payload.task}\n[계획] {plan}", category="tasks")
    return {"node": MACHINE_ID, "task": payload.task, "plan": plan}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=NETWORK_PORT, log_level="info")
