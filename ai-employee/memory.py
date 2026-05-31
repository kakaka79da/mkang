"""ChromaDB 기반 에이전트 장기 기억."""

import uuid
import chromadb
from datetime import datetime


class AgentMemory:
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._init()
        return cls._instance

    def _init(self):
        self.client = chromadb.PersistentClient(path="./memory_db")
        # sentence-transformers 없이 ChromaDB 기본 ONNX 임베딩 사용
        self.conversations = self.client.get_or_create_collection("conversations")
        self.tasks = self.client.get_or_create_collection("tasks")
        self.decisions = self.client.get_or_create_collection("decisions")

    def remember(self, content: str, category: str = "conversations", metadata: dict = None):
        col = getattr(self, category, self.conversations)
        col.add(
            documents=[content],
            metadatas=[{**(metadata or {}), "timestamp": datetime.now().isoformat()}],
            ids=[str(uuid.uuid4())],
        )

    def recall(self, query: str, category: str = "conversations", n: int = 5) -> list[str]:
        col = getattr(self, category, self.conversations)
        try:
            result = col.query(query_texts=[query], n_results=n)
            return result["documents"][0]
        except Exception:
            return []

    def today_summary(self) -> list[str]:
        today = datetime.now().date().isoformat()
        try:
            result = self.conversations.get(where={"timestamp": {"$gte": today}})
            return result.get("documents", [])
        except Exception:
            return []

    def save_decision(self, topic: str, decision: str, by: str):
        self.remember(
            f"[결정] 주제: {topic}\n결정: {decision}\n결정자: {by}",
            category="decisions",
            metadata={"topic": topic, "by": by},
        )


memory = AgentMemory()
