"""ChromaDB 기반 에이전트 장기 기억."""

import uuid
import chromadb
from datetime import datetime
from sentence_transformers import SentenceTransformer


class AgentMemory:
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._init()
        return cls._instance

    def _init(self):
        self.client = chromadb.PersistentClient(path="./memory_db")
        self.encoder = SentenceTransformer("all-MiniLM-L6-v2")
        self.conversations = self.client.get_or_create_collection("conversations")
        self.tasks = self.client.get_or_create_collection("tasks")
        self.decisions = self.client.get_or_create_collection("decisions")

    def remember(self, content: str, category: str = "conversations", metadata: dict = None):
        col = getattr(self, category, self.conversations)
        embedding = self.encoder.encode(content).tolist()
        col.add(
            documents=[content],
            embeddings=[embedding],
            metadatas=[{**(metadata or {}), "timestamp": datetime.now().isoformat()}],
            ids=[str(uuid.uuid4())],
        )

    def recall(self, query: str, category: str = "conversations", n: int = 5) -> list[str]:
        col = getattr(self, category, self.conversations)
        try:
            embedding = self.encoder.encode(query).tolist()
            result = col.query(query_embeddings=[embedding], n_results=n)
            return result["documents"][0]
        except Exception:
            return []

    def today_summary(self) -> list[str]:
        today = datetime.now().date().isoformat()
        result = self.conversations.get(where={"timestamp": {"$gte": today}})
        return result.get("documents", [])

    def save_decision(self, topic: str, decision: str, by: str):
        self.remember(
            f"[결정] 주제: {topic}\n결정: {decision}\n결정자: {by}",
            category="decisions",
            metadata={"topic": topic, "by": by},
        )


memory = AgentMemory()
