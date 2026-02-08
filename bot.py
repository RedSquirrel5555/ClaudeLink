"""ClaudeLink — Telegram bridge for Claude Code."""

import asyncio
import json
import logging
import os
import subprocess
import sys
from pathlib import Path

from dotenv import load_dotenv
from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters

load_dotenv()

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
OWNER_ID = int(os.environ["OWNER_TELEGRAM_ID"])
MODEL = os.getenv("CLAUDE_MODEL", "opus")
WORKSPACE = os.getenv("WORKSPACE_DIR", ".")
TIMEOUT = int(os.getenv("COMMAND_TIMEOUT", "600"))

SESSION_FILE = Path(__file__).parent / ".session"
MSG_LIMIT = 4000

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s", level=logging.INFO
)
log = logging.getLogger("claudelink")

# --- Session ---

def load_session() -> str | None:
    if SESSION_FILE.exists():
        sid = SESSION_FILE.read_text().strip()
        if sid:
            return sid
    return None

def save_session(sid: str):
    SESSION_FILE.write_text(sid)

def clear_session():
    if SESSION_FILE.exists():
        SESSION_FILE.unlink()

session_id: str | None = load_session()
msg_count = 0

# --- Owner guard ---

def owner_only(func):
    async def wrapper(update: Update, context):
        if update.effective_user.id != OWNER_ID:
            return
        return await func(update, context)
    return wrapper

# --- Claude Code invocation ---

def _run_claude(prompt: str, sid: str | None) -> subprocess.CompletedProcess:
    """Run claude CLI synchronously (called from thread executor)."""
    cmd = [
        "claude", "-p", prompt,
        "--output-format", "json",
        "--model", MODEL,
        "--allowedTools", "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task",
    ]
    if sid:
        cmd += ["--resume", sid]

    kwargs = {}
    if sys.platform == "win32":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        cwd=WORKSPACE,
        timeout=TIMEOUT,
        **kwargs,
    )


async def ask_claude(prompt: str) -> str:
    global session_id

    log.info("Running: claude -p (session=%s)", session_id[:8] if session_id else "new")

    loop = asyncio.get_running_loop()
    try:
        result = await asyncio.wait_for(
            loop.run_in_executor(None, _run_claude, prompt, session_id),
            timeout=TIMEOUT + 10,
        )
    except asyncio.TimeoutError:
        raise

    raw = result.stdout.decode("utf-8", errors="replace").strip()
    err = result.stderr.decode("utf-8", errors="replace").strip()

    log.info("claude exited %d, stdout=%d bytes, stderr=%d bytes",
             result.returncode, len(raw), len(err))

    if result.returncode != 0:
        log.error("claude error: %s", err or raw)
        return f"Error (exit {result.returncode}): {err or raw}"

    try:
        data = json.loads(raw)
        if data.get("session_id"):
            session_id = data["session_id"]
            save_session(session_id)
            log.info("Session: %s", session_id[:8])
        return data.get("result", raw)
    except json.JSONDecodeError:
        return raw or "(no response)"

# --- Handlers ---

@owner_only
async def cmd_start(update: Update, context):
    await update.message.reply_text("ClaudeLink online. Send me anything.")

@owner_only
async def cmd_clear(update: Update, context):
    global session_id, msg_count
    clear_session()
    session_id = None
    msg_count = 0
    await update.message.reply_text("Session reset. Next message starts fresh.")

@owner_only
async def cmd_status(update: Update, context):
    sid = session_id[:8] + "..." if session_id else "none"
    await update.message.reply_text(
        f"Session: {sid}\nMessages: {msg_count}\nModel: {MODEL}"
    )

@owner_only
async def handle_message(update: Update, context):
    global msg_count
    text = update.message.text
    if not text:
        return

    log.info("Message from owner: %s", text[:80])

    # Keep "typing..." active while Claude works
    typing = True
    async def keep_typing():
        while typing:
            await update.message.chat.send_action("typing")
            await asyncio.sleep(4)
    typing_task = asyncio.create_task(keep_typing())

    try:
        response = await ask_claude(text)
    except asyncio.TimeoutError:
        response = f"Timed out after {TIMEOUT}s."
    except Exception as e:
        log.exception("Claude invocation failed")
        response = f"Error: {e}"
    finally:
        typing = False
        typing_task.cancel()

    msg_count += 1

    chunks = [response[i : i + MSG_LIMIT] for i in range(0, len(response), MSG_LIMIT)]
    for chunk in chunks:
        try:
            await update.message.reply_text(chunk, parse_mode="Markdown")
        except Exception:
            await update.message.reply_text(chunk)

# --- Main ---

def main():
    sid = session_id[:8] + "..." if session_id else "new"
    log.info("Starting ClaudeLink (session: %s)", sid)
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("clear", cmd_clear))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    app.run_polling(drop_pending_updates=True)

if __name__ == "__main__":
    main()
