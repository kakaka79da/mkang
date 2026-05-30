"""AI 직원 에이전트 정의 및 공통 LLM 설정."""

import autogen
from datetime import datetime
from config import EMPLOYEES, LLM_PORT_MAIN, LLM_HOST

LLM_BASE_URL = f"http://localhost:{LLM_PORT_MAIN}/v1"

llm_config = {
    "config_list": [{
        "model": "local-model",
        "base_url": LLM_BASE_URL,
        "api_key": "local",
        "price": [0, 0],
    }],
    "temperature": 0.7,
    "max_tokens": 4096,
    "timeout": 300,
}

# 고품질 설정 — Qwen3 32B 사용 시
llm_config_hq = {**llm_config, "config_list": [{
    **llm_config["config_list"][0],
    "base_url": f"http://localhost:11435/v1",
}]}


class AIEmployee:
    def __init__(self, key: str):
        cfg = EMPLOYEES[key]
        self.name = cfg["name"]
        self.role = cfg["role"]
        self.agent = autogen.AssistantAgent(
            name=self.name,
            system_message=(
                # /no_think: Qwen3 의 thinking 모드를 끈다. 켜져 있으면 추론 과정에
                # 토큰을 다 써버려 실제 답변(content)이 비는 문제가 있다.
                f"/no_think\n"
                f"당신은 {cfg['role']}입니다.\n"
                f"{cfg['prompt']}\n\n"
                f"항상 한국어로 답변하고, 결론과 다음 행동 계획을 명확히 제시하세요.\n"
                f"현재 일시: {datetime.now().strftime('%Y-%m-%d %H:%M')}"
            ),
            llm_config=llm_config,
        )


def make_user_proxy(name: str = "Boss") -> autogen.UserProxyAgent:
    return autogen.UserProxyAgent(
        name=name,
        human_input_mode="NEVER",
        max_consecutive_auto_reply=3,
        code_execution_config=False,
    )


def run_meeting(topic: str, max_round: int = 8) -> list[dict]:
    """AI 직원 전체 팀 미팅 실행 후 메시지 목록 반환."""
    employees = [AIEmployee(k) for k in EMPLOYEES]
    agents = [e.agent for e in employees]

    groupchat = autogen.GroupChat(
        agents=agents,
        messages=[],
        max_round=max_round,
        speaker_selection_method="round_robin",
    )
    manager = autogen.GroupChatManager(groupchat=groupchat, llm_config=llm_config)
    proxy = make_user_proxy("Facilitator")
    proxy.initiate_chat(manager, message=f"[미팅 주제] {topic}\n각자 역할에 맞는 의견을 제시해주세요.")
    return groupchat.messages


# 싱글턴 직원 인스턴스 (telegram_bot 등에서 import)
ceo = AIEmployee("CEO")
dev = AIEmployee("DEV")
analyst = AIEmployee("ANALYST")
marketing = AIEmployee("MARKETING")
