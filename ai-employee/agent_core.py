"""AI 직원 에이전트 정의 및 공통 LLM 설정."""

import autogen
from datetime import datetime
from openai import OpenAI
from config import EMPLOYEES, LLM_PORT_MAIN, LLM_HOST

LLM_BASE_URL = f"http://localhost:{LLM_PORT_MAIN}/v1"

# 로컬 llama.cpp(OpenAI 호환) 직접 호출용 클라이언트.
# ag2 의 initiate_chat 은 1턴 질의에도 빈 2차 호출을 일으켜 느린 CPU에서
# 응답이 멈추거나 2배 느려진다. 단순 질의/지시/미팅은 이 클라이언트로 직접 호출한다.
_client = OpenAI(base_url=LLM_BASE_URL, api_key="local", timeout=600)


def chat(system_prompt: str, user_message: str, max_tokens: int = 1024) -> str:
    """단일 직원에게 직접 질의하고 답변 텍스트를 반환한다."""
    resp = _client.chat.completions.create(
        model="local",
        messages=[
            {"role": "system", "content": "/no_think\n" + system_prompt},
            {"role": "user", "content": user_message},
        ],
        max_tokens=max_tokens,
        temperature=0.7,
    )
    return (resp.choices[0].message.content or "").strip()


def ask_employee(key: str, user_message: str, max_tokens: int = 1024) -> str:
    """역할(key: CEO/DEV/ANALYST/MARKETING)에 맞는 직원에게 직접 질의."""
    cfg = EMPLOYEES[key]
    system = (
        f"당신은 {cfg['role']}입니다.\n{cfg['prompt']}\n\n"
        f"항상 한국어로 답변하고, 결론과 다음 행동 계획을 명확히 제시하세요."
    )
    return chat(system, user_message, max_tokens)


def team_meeting(topic: str) -> list[tuple[str, str]]:
    """AI 직원들이 순서대로 발언하는 미팅. (역할명, 발언) 목록 반환.

    각 직원은 앞선 동료들의 발언을 보고 자기 관점에서 의견을 더한다.
    ag2 GroupChat 대신 직접 호출로 구현해 CPU에서 안정적으로 동작한다.
    """
    transcript: list[tuple[str, str]] = []
    for key in EMPLOYEES:
        cfg = EMPLOYEES[key]
        prior = "\n\n".join(f"[{r}] {t}" for r, t in transcript) or "(아직 발언 없음)"
        system = (
            f"당신은 {cfg['role']}입니다.\n{cfg['prompt']}\n\n"
            f"회사 미팅 중입니다. 한국어로 3~5문장으로 당신 역할 관점의 의견을 말하세요."
        )
        user = (
            f"[미팅 주제] {topic}\n\n"
            f"[지금까지 동료들의 발언]\n{prior}\n\n"
            f"이제 {cfg['role']}로서 의견을 제시하세요."
        )
        say = chat(system, user, max_tokens=512)
        transcript.append((cfg["role"], say))
    return transcript


def duo_chat(key_a: str, key_b: str, topic: str, rounds: int = 3) -> list[tuple[str, str]]:
    """두 AI 직원이 주제를 놓고 번갈아 대화. (역할명, 발언) 목록 반환.

    예: duo_chat("DEV", "ANALYST", "신규 서비스 기술 스택") → 개발자와
    분석가가 rounds 번씩 주고받으며 토론한다.
    """
    cfg_a, cfg_b = EMPLOYEES[key_a], EMPLOYEES[key_b]
    transcript: list[tuple[str, str]] = []

    for i in range(rounds * 2):
        speaker = cfg_a if i % 2 == 0 else cfg_b
        listener = cfg_b if i % 2 == 0 else cfg_a
        prior = "\n\n".join(f"[{r}] {t}" for r, t in transcript) or "(첫 발언입니다)"
        last_round = i >= rounds * 2 - 2
        system = (
            f"당신은 {speaker['role']}입니다.\n{speaker['prompt']}\n\n"
            f"{listener['role']}와 1:1 대화 중입니다. "
            f"한국어로 2~4문장, 상대 발언에 직접 반응하며 대화를 이어가세요."
            + ("\n마지막 발언이니 합의점이나 결론을 정리하세요." if last_round else "")
        )
        user = (
            f"[대화 주제] {topic}\n\n"
            f"[지금까지의 대화]\n{prior}\n\n"
            f"이제 {speaker['role']}로서 발언하세요."
        )
        say = chat(system, user, max_tokens=400)
        transcript.append((speaker["role"], say))
    return transcript


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
