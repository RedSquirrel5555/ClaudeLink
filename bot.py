"""ClaudeLink — Telegram bridge for Claude Code with live streaming progress."""

import asyncio
import json
import logging
import os
import queue as stdlib_queue
import subprocess
import sys
import time
import threading
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
STATUS_THROTTLE = 3  # min seconds between Telegram status edits

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s", level=logging.INFO
)
log = logging.getLogger("claudelink")

# --- Tool descriptions ---

def _short(s: str, maxlen: int = 40) -> str:
    if len(s) <= maxlen:
        return s
    return "..." + s[-(maxlen - 3):]


def _describe_tool(name: str, inp: dict) -> str:
    """Turn a tool_use event into a friendly one-liner for the status message."""
    descs = {
        "Read":      lambda i: f"Reading {_short(i.get('file_path', '?'))}",
        "Glob":      lambda i: f"Searching for {i.get('pattern', 'files')}",
        "Grep":      lambda i: f"Searching code for \"{i.get('pattern', '...')}\"",
        "Bash":      lambda i: "Running command",
        "Write":     lambda i: f"Writing {_short(i.get('file_path', '?'))}",
        "Edit":      lambda i: f"Editing {_short(i.get('file_path', '?'))}",
        "WebSearch": lambda i: f"Searching web for \"{i.get('query', '...')}\"",
        "WebFetch":  lambda i: f"Fetching {_short(i.get('url', '?'), 60)}",
        "Task":      lambda i: "Running subtask",
    }
    fn = descs.get(name)
    return fn(inp) if fn else f"Using {name}"

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

# --- Streaming Claude Code invocation ---

def _read_stdout(proc, queue):
    """Read NDJSON lines from proc stdout into queue. Runs in a thread."""
    try:
        for raw_line in proc.stdout:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                queue.put(json.loads(line))
            except json.JSONDecodeError:
                log.warning("Non-JSON line: %s", line[:200])
    except Exception:
        log.exception("Error reading claude stdout")
    finally:
        queue.put(None)  # sentinel: stream ended


async def _edit_status(msg, tool_log: list[str]):
    """Edit the status message with the current tool log. Silently ignore errors."""
    text = "\n".join(tool_log) if tool_log else "Working..."
    if len(text) > MSG_LIMIT:
        text = text[-MSG_LIMIT:]
    try:
        await msg.edit_text(text)
    except Exception:
        log.debug("Failed to edit status message", exc_info=True)


async def stream_claude(prompt: str, status_msg) -> str:
    """Spawn claude with stream-json, update status_msg live, return final text."""
    global session_id

    cmd = [
        "claude", "-p", prompt,
        "--output-format", "stream-json",
        "--verbose",
        "--model", MODEL,
        "--allowedTools", "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task",
    ]
    if session_id:
        cmd += ["--resume", session_id]

    popen_kwargs = {}
    if sys.platform == "win32":
        popen_kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

    log.info("Spawning claude (session=%s)", session_id[:8] if session_id else "new")

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        cwd=WORKSPACE,
        **popen_kwargs,
    )

    q = stdlib_queue.Queue()
    reader = threading.Thread(target=_read_stdout, args=(proc, q), daemon=True)
    reader.start()

    tool_log = []
    last_edit = 0.0
    result_text = None
    pending_update = False
    loop = asyncio.get_running_loop()
    start = time.monotonic()

    while True:
        elapsed = time.monotonic() - start
        if elapsed > TIMEOUT:
            proc.kill()
            return f"Timed out after {TIMEOUT // 60}min. Try breaking it into smaller asks."

        # Non-blocking get from the queue (runs Queue.get in executor)
        try:
            event = await asyncio.wait_for(
                loop.run_in_executor(None, q.get, True, 1.0),
                timeout=2.0,
            )
        except (asyncio.TimeoutError, stdlib_queue.Empty):
            if pending_update and (time.monotonic() - last_edit) >= STATUS_THROTTLE:
                await _edit_status(status_msg, tool_log)
                last_edit = time.monotonic()
                pending_update = False
            continue

        if event is None:
            break

        # --- Result event ---
        if event.get("type") == "result":
            result_text = event.get("result", "")
            sid = event.get("session_id")
            if sid:
                session_id = sid
                save_session(session_id)
                log.info("Session: %s", session_id[:8])
            continue

        # --- Extract tool_use from assistant messages ---
        msg = event.get("message", event)
        content = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    desc = _describe_tool(block.get("name", "?"), block.get("input", {}))
                    tool_log.append(desc)
                    pending_update = True
                    log.info("Tool: %s", desc)

        # Save session_id from any event that carries it
        sid = event.get("session_id")
        if sid and isinstance(sid, str):
            session_id = sid
            save_session(session_id)

        # Throttled status edit
        if pending_update and (time.monotonic() - last_edit) >= STATUS_THROTTLE:
            await _edit_status(status_msg, tool_log)
            last_edit = time.monotonic()
            pending_update = False

    proc.wait(timeout=10)

    # Flush any remaining status update
    if pending_update:
        await _edit_status(status_msg, tool_log)

    stderr = proc.stderr.read().decode("utf-8", errors="replace").strip()

    log.info("claude exited %d, stderr=%d bytes, tools=%d",
             proc.returncode, len(stderr), len(tool_log))

    if proc.returncode != 0 and not result_text:
        log.error("claude error: %s", stderr)
        return f"Error (exit {proc.returncode}): {stderr}"

    if result_text is None:
        return stderr or "(no response)"

    return result_text

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

    status_msg = await update.message.reply_text("Working...")

    typing = True
    async def keep_typing():
        while typing:
            await update.message.chat.send_action("typing")
            await asyncio.sleep(4)
    typing_task = asyncio.create_task(keep_typing())

    try:
        response = await stream_claude(text, status_msg)
    except Exception as e:
        log.exception("Claude invocation failed")
        response = f"Error: {type(e).__name__}: check logs for details."
    finally:
        typing = False
        typing_task.cancel()

    msg_count += 1

    # Clean up status message
    try:
        await status_msg.delete()
    except Exception:
        pass

    # Send final response
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
