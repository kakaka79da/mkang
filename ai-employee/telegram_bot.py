"""텔레그램 봇 — AI 직원 인터페이스."""

import asyncio
import logging
import psutil
from datetime import datetime
from telegram import Update
from telegram.ext import (
    Application, CommandHandler, MessageHandler,
    filters, ContextTypes,
)

import autogen
from config import TELEGRAM_TOKEN, AUTHORIZED_USERS, BOT_NAME, MACHINE_ID
from agent_core import ceo, dev, analyst, marketing, llm_config, make_user_proxy, run_meeting
from memory import memory

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)


def auth(func):
    """권한 없는 사용자 차단 데코레이터."""
    async def wrapper(*args, **kwargs):
        # 핸들러가 메서드면 args=(self, update, context), 함수면 args=(update, context)
        update = next(a for a in args if isinstance(a, Update))
        if update.effective_user.id not in AUTHORIZED_USERS:
            await update.message.reply_text("⛔ 접근 권한이 없습니다.")
            return
        return await func(*args, **kwargs)
    return wrapper


class TelegramAIBridge:
    def __init__(self):
        self.app = Application.builder().token(TELEGRAM_TOKEN).build()
        self._register_handlers()

    def _register_handlers(self):
        cmds = [
            ("start", self.cmd_start),
            ("help", self.cmd_help),
            ("meeting", self.cmd_meeting),
            ("task", self.cmd_task),
            ("ask", self.cmd_ask),
            ("status", self.cmd_status),
            ("memory", self.cmd_memory),
            ("today", self.cmd_today),
        ]
        for name, handler in cmds:
            self.app.add_handler(CommandHandler(name, handler))
        self.app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, self.handle_message))

    # ── 커맨드 핸들러 ────────────────────────────────────────────────────────

    @auth
    async def cmd_start(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        await update.message.reply_text(
            f"👋 안녕하세요! {BOT_NAME} 시스템 ({MACHINE_ID}) 가동 중입니다.\n\n"
            "/help — 전체 명령어 안내"
        )

    @auth
    async def cmd_help(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        await update.message.reply_text(
            "📋 *명령어 목록*\n\n"
            "/task [내용] — CEO에게 업무 지시\n"
            "/ask [직원] [질문] — 특정 직원에게 질문 (ceo/dev/analyst/marketing)\n"
            "/meeting [주제] — AI 팀 전체 미팅 시작\n"
            "/status — 시스템 상태\n"
            "/memory [검색어] — 과거 기억 검색\n"
            "/today — 오늘 업무 요약\n\n"
            "또는 그냥 메시지를 보내면 CEO AI가 답변합니다.",
            parse_mode="Markdown",
        )

    @auth
    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        msg = update.message.text
        await update.message.reply_text("🤔 CEO AI가 처리 중...")

        proxy = make_user_proxy("Boss")
        await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: proxy.initiate_chat(ceo.agent, message=msg, max_turns=2),
        )
        reply = proxy.last_message()["content"]
        memory.remember(f"Q: {msg}\nA: {reply}", metadata={"type": "telegram"})
        await update.message.reply_text(f"💼 CEO AI:\n{reply}")

    @auth
    async def cmd_task(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        task = " ".join(context.args)
        if not task:
            await update.message.reply_text("사용법: /task [업무 내용]")
            return
        await update.message.reply_text(f"📌 업무 접수: {task}\nCEO AI가 처리합니다...")

        proxy = make_user_proxy("Boss")
        await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: proxy.initiate_chat(
                ceo.agent,
                message=f"[업무 지시] {task}\n구체적인 실행 계획을 수립하세요.",
                max_turns=3,
            ),
        )
        reply = proxy.last_message()["content"]
        memory.remember(f"[업무] {task}\n[계획] {reply}", category="tasks",
                        metadata={"type": "task"})
        await update.message.reply_text(f"✅ CEO AI 계획:\n{reply}")

    @auth
    async def cmd_ask(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        if len(context.args) < 2:
            await update.message.reply_text("사용법: /ask [ceo|dev|analyst|marketing] [질문]")
            return
        target_key = context.args[0].lower()
        question = " ".join(context.args[1:])
        employee_map = {"ceo": ceo, "dev": dev, "analyst": analyst, "marketing": marketing}
        employee = employee_map.get(target_key)
        if not employee:
            await update.message.reply_text("직원: ceo, dev, analyst, marketing 중 선택하세요.")
            return

        await update.message.reply_text(f"🤔 {employee.role}에게 전달 중...")
        proxy = make_user_proxy("Boss")
        await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: proxy.initiate_chat(employee.agent, message=question, max_turns=2),
        )
        reply = proxy.last_message()["content"]
        await update.message.reply_text(f"💬 {employee.role}:\n{reply}")

    @auth
    async def cmd_meeting(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        topic = " ".join(context.args) if context.args else "이번 주 업무 계획 및 현안"
        await update.message.reply_text(f"📋 AI 팀 미팅 시작\n주제: {topic}\n\n(최대 2분 소요)")

        messages = await asyncio.get_event_loop().run_in_executor(
            None, lambda: run_meeting(topic)
        )

        lines = []
        for m in messages[-8:]:
            name = m.get("name", "?")
            content = m.get("content", "")[:300]
            lines.append(f"*{name}*: {content}")

        summary = "\n\n".join(lines)
        memory.remember(f"[미팅] {topic}\n{summary}", category="decisions",
                        metadata={"type": "meeting", "topic": topic})
        await update.message.reply_text(f"📊 미팅 결과:\n\n{summary}", parse_mode="Markdown")

    @auth
    async def cmd_status(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        ram = psutil.virtual_memory()
        cpu = psutil.cpu_percent(interval=1)
        disk = psutil.disk_usage("/")
        await update.message.reply_text(
            f"🖥️ *{MACHINE_ID} 상태*\n\n"
            f"CPU: {cpu:.1f}%\n"
            f"RAM: {ram.used/1024**3:.1f} / {ram.total/1024**3:.1f} GB "
            f"({ram.percent:.0f}%)\n"
            f"디스크: {disk.free/1024**3:.1f} GB 여유\n"
            f"GPU: AMD Radeon Pro 5700 XT 16GB\n"
            f"LLM: http://localhost:11434\n"
            f"시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
            parse_mode="Markdown",
        )

    @auth
    async def cmd_memory(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        query = " ".join(context.args)
        if not query:
            await update.message.reply_text("사용법: /memory [검색어]")
            return
        results = memory.recall(query, n=3)
        if not results:
            await update.message.reply_text("관련 기억을 찾지 못했습니다.")
            return
        text = "\n\n---\n\n".join(results[:3])
        await update.message.reply_text(f"🧠 관련 기억:\n\n{text}")

    @auth
    async def cmd_today(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        docs = memory.today_summary()
        if not docs:
            await update.message.reply_text("오늘 기록된 내용이 없습니다.")
            return
        summary = "\n\n".join(docs[-5:])
        await update.message.reply_text(f"📅 오늘 활동 요약:\n\n{summary}")

    def run(self):
        log.info(f"텔레그램 봇 시작 ({MACHINE_ID})")
        self.app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    TelegramAIBridge().run()
