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

from config import TELEGRAM_TOKEN, AUTHORIZED_USERS, BOT_NAME, MACHINE_ID, EMPLOYEES
from agent_core import ask_employee, team_meeting, duo_chat
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


def _drive():
    """구글 드라이브 클라이언트 (미설정 시 None)."""
    try:
        from gdrive import drive
        if drive.is_configured():
            return drive
    except Exception as e:
        log.warning(f"gdrive 사용 불가: {e}")
    return None


async def _send_long(update: Update, text: str, **kwargs):
    """텔레그램 4096자 제한 대비 분할 전송."""
    for i in range(0, len(text), 3500):
        await update.message.reply_text(text[i:i + 3500], **kwargs)


class TelegramAIBridge:
    def __init__(self):
        self.app = Application.builder().token(TELEGRAM_TOKEN).build()
        self._register_handlers()

    def _register_handlers(self):
        cmds = [
            ("start", self.cmd_start),
            ("help", self.cmd_help),
            ("meeting", self.cmd_meeting),
            ("chat", self.cmd_chat),
            ("task", self.cmd_task),
            ("ask", self.cmd_ask),
            ("status", self.cmd_status),
            ("memory", self.cmd_memory),
            ("today", self.cmd_today),
            ("drive", self.cmd_drive),
            ("read", self.cmd_read),
            ("report", self.cmd_report),
        ]
        for name, handler in cmds:
            self.app.add_handler(CommandHandler(name, handler))
        self.app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, self.handle_message))

    # ── 기본 커맨드 ──────────────────────────────────────────────────────────

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
            "*AI 직원*\n"
            "/task [내용] — CEO에게 업무 지시\n"
            "/ask [직원] [질문] — 특정 직원에게 질문 (ceo/dev/analyst/marketing)\n"
            "/meeting [주제] — AI 팀 전체 미팅\n"
            "/chat [직원1] [직원2] [주제] — AI 둘이서 토론\n\n"
            "*구글 드라이브*\n"
            "/drive — 최근 파일 목록\n"
            "/drive [검색어] — 파일 검색\n"
            "/read [파일명] — 파일 읽고 AI가 요약\n"
            "/report [주제] — 보고서 작성 후 드라이브 저장\n\n"
            "*시스템*\n"
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

        reply = await asyncio.get_event_loop().run_in_executor(
            None, lambda: ask_employee("CEO", msg)
        )
        memory.remember(f"Q: {msg}\nA: {reply}", metadata={"type": "telegram"})
        await _send_long(update, f"💼 CEO AI:\n{reply}")

    @auth
    async def cmd_task(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        task = " ".join(context.args)
        if not task:
            await update.message.reply_text("사용법: /task [업무 내용]")
            return
        await update.message.reply_text(f"📌 업무 접수: {task}\nCEO AI가 처리합니다...")

        reply = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: ask_employee(
                "CEO",
                f"[업무 지시] {task}\n구체적인 실행 계획을 단계별로 수립하세요.",
            ),
        )
        memory.remember(f"[업무] {task}\n[계획] {reply}", category="tasks",
                        metadata={"type": "task"})
        await _send_long(update, f"✅ CEO AI 계획:\n{reply}")

    @auth
    async def cmd_ask(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        if len(context.args) < 2:
            await update.message.reply_text("사용법: /ask [ceo|dev|analyst|marketing] [질문]")
            return
        target_key = context.args[0].upper()
        question = " ".join(context.args[1:])
        if target_key not in EMPLOYEES:
            await update.message.reply_text("직원: ceo, dev, analyst, marketing 중 선택하세요.")
            return

        role = EMPLOYEES[target_key]["role"]
        await update.message.reply_text(f"🤔 {role}에게 전달 중...")
        reply = await asyncio.get_event_loop().run_in_executor(
            None, lambda: ask_employee(target_key, question)
        )
        await _send_long(update, f"💬 {role}:\n{reply}")

    # ── AI 끼리 대화 ─────────────────────────────────────────────────────────

    @auth
    async def cmd_meeting(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        topic = " ".join(context.args) if context.args else "이번 주 업무 계획 및 현안"
        await update.message.reply_text(
            f"📋 AI 팀 미팅 시작\n주제: {topic}\n\n(직원 수만큼 발언, 1~2분 소요)"
        )

        transcript = await asyncio.get_event_loop().run_in_executor(
            None, lambda: team_meeting(topic)
        )

        summary = "\n\n".join(f"🗣 *{role}*\n{say}" for role, say in transcript)
        memory.remember(f"[미팅] {topic}\n{summary}", category="decisions",
                        metadata={"type": "meeting", "topic": topic})
        await _send_long(update, f"📊 *미팅 결과* — {topic}\n\n{summary}",
                         parse_mode="Markdown")

        # 미팅록을 구글 드라이브에 자동 저장
        d = _drive()
        if d:
            try:
                plain = "\n\n".join(f"[{role}]\n{say}" for role, say in transcript)
                fname = f"미팅록_{datetime.now().strftime('%Y%m%d_%H%M')}_{topic[:20]}.txt"
                link = await asyncio.get_event_loop().run_in_executor(
                    None, lambda: d.upload_text(fname, f"주제: {topic}\n\n{plain}")
                )
                await update.message.reply_text(f"📁 드라이브 저장 완료:\n{link}")
            except Exception as e:
                log.warning(f"드라이브 저장 실패: {e}")

    @auth
    async def cmd_chat(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        if len(context.args) < 3:
            await update.message.reply_text(
                "사용법: /chat [직원1] [직원2] [주제]\n"
                "예: /chat dev analyst 신규 서비스 기술 스택"
            )
            return
        key_a, key_b = context.args[0].upper(), context.args[1].upper()
        topic = " ".join(context.args[2:])
        if key_a not in EMPLOYEES or key_b not in EMPLOYEES:
            await update.message.reply_text("직원: ceo, dev, analyst, marketing 중 선택하세요.")
            return

        role_a, role_b = EMPLOYEES[key_a]["role"], EMPLOYEES[key_b]["role"]
        await update.message.reply_text(
            f"💬 {role_a} ↔ {role_b} 대화 시작\n주제: {topic}\n\n(각 3번씩 발언, 1~2분 소요)"
        )

        transcript = await asyncio.get_event_loop().run_in_executor(
            None, lambda: duo_chat(key_a, key_b, topic)
        )
        body = "\n\n".join(f"🗣 *{role}*\n{say}" for role, say in transcript)
        memory.remember(f"[1:1대화] {topic}\n" +
                        "\n".join(f"{r}: {s[:150]}" for r, s in transcript),
                        category="decisions", metadata={"type": "duo_chat"})
        await _send_long(update, f"💬 *대화 결과* — {topic}\n\n{body}",
                         parse_mode="Markdown")

    # ── 구글 드라이브 ────────────────────────────────────────────────────────

    @auth
    async def cmd_drive(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        d = _drive()
        if not d:
            await update.message.reply_text(
                "❌ 구글 드라이브 미설정.\nGOOGLE_DRIVE_SETUP.md 참고 후 "
                "`python gdrive.py` 로 인증하세요."
            )
            return
        query = " ".join(context.args)
        await update.message.reply_text("📁 드라이브 조회 중...")
        try:
            files = await asyncio.get_event_loop().run_in_executor(
                None, lambda: d.list_files(query=query, n=10)
            )
        except Exception as e:
            await update.message.reply_text(f"❌ 드라이브 오류: {e}")
            return
        if not files:
            await update.message.reply_text("파일이 없습니다.")
            return
        lines = []
        for f in files:
            mtime = f.get("modifiedTime", "")[:10]
            lines.append(f"• {f['name']}  ({mtime})")
        title = f"🔍 '{query}' 검색 결과" if query else "📁 최근 파일"
        await _send_long(update, f"{title}:\n\n" + "\n".join(lines))

    @auth
    async def cmd_read(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        d = _drive()
        if not d:
            await update.message.reply_text("❌ 구글 드라이브 미설정.")
            return
        name = " ".join(context.args)
        if not name:
            await update.message.reply_text("사용법: /read [파일명]")
            return
        await update.message.reply_text(f"📖 '{name}' 읽는 중...")
        try:
            content = await asyncio.get_event_loop().run_in_executor(
                None, lambda: d.read_file(name)
            )
        except Exception as e:
            await update.message.reply_text(f"❌ 읽기 실패: {e}")
            return
        if content.startswith("("):
            await update.message.reply_text(content)
            return

        await update.message.reply_text("🤔 분석가 AI가 요약 중...")
        summary = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: ask_employee(
                "ANALYST",
                f"다음 문서를 핵심만 간결하게 요약하고 시사점을 정리하세요.\n\n{content}",
            ),
        )
        memory.remember(f"[문서요약] {name}\n{summary}", metadata={"type": "drive_read"})
        await _send_long(update, f"📄 *{name}* 요약:\n\n{summary}")

    @auth
    async def cmd_report(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        d = _drive()
        topic = " ".join(context.args)
        if not topic:
            await update.message.reply_text("사용법: /report [보고서 주제]")
            return
        await update.message.reply_text(f"📝 보고서 작성 중: {topic}\n(2~3분 소요)")

        report = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: ask_employee(
                "ANALYST",
                f"[보고서 작성] 주제: {topic}\n"
                f"제목, 개요, 본문(3~5개 섹션), 결론 및 제언 구조의 보고서를 작성하세요.",
                max_tokens=2048,
            ),
        )
        memory.remember(f"[보고서] {topic}\n{report[:500]}", category="tasks",
                        metadata={"type": "report"})
        await _send_long(update, f"📑 보고서 — {topic}:\n\n{report}")

        if d:
            try:
                fname = f"보고서_{datetime.now().strftime('%Y%m%d_%H%M')}_{topic[:20]}.txt"
                link = await asyncio.get_event_loop().run_in_executor(
                    None, lambda: d.upload_text(fname, f"주제: {topic}\n\n{report}")
                )
                await update.message.reply_text(f"📁 드라이브 저장 완료:\n{link}")
            except Exception as e:
                await update.message.reply_text(f"⚠️ 드라이브 저장 실패: {e}")
        else:
            await update.message.reply_text("(드라이브 미설정 — 텔레그램에만 전송)")

    # ── 시스템 ──────────────────────────────────────────────────────────────

    @auth
    async def cmd_status(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        ram = psutil.virtual_memory()
        cpu = psutil.cpu_percent(interval=1)
        disk = psutil.disk_usage("/")
        drive_state = "✅ 연동됨" if _drive() else "❌ 미설정"
        await update.message.reply_text(
            f"🖥️ *{MACHINE_ID} 상태*\n\n"
            f"CPU: {cpu:.1f}%\n"
            f"RAM: {ram.used/1024**3:.1f} / {ram.total/1024**3:.1f} GB "
            f"({ram.percent:.0f}%)\n"
            f"디스크: {disk.free/1024**3:.1f} GB 여유\n"
            f"GPU: AMD Radeon Pro 5700 XT 16GB\n"
            f"드라이브: {drive_state}\n"
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
        await _send_long(update, f"🧠 관련 기억:\n\n{text}")

    @auth
    async def cmd_today(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        docs = memory.today_summary()
        if not docs:
            await update.message.reply_text("오늘 기록된 내용이 없습니다.")
            return
        summary = "\n\n".join(docs[-5:])
        await _send_long(update, f"📅 오늘 활동 요약:\n\n{summary}")

    def run(self):
        log.info(f"텔레그램 봇 시작 ({MACHINE_ID})")
        self.app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    TelegramAIBridge().run()
