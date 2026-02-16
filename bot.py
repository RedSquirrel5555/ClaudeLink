"""ClaudeLink — Telegram bridge for Claude Code with live streaming progress."""

import asyncio
import json
import logging
import os
import queue as stdlib_queue
import shutil
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
DOWNLOADS_DIR = Path(__file__).parent / "downloads"
MSG_LIMIT = 4000
STATUS_THROTTLE = 3  # min seconds between Telegram status edits
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tiff", ".svg"}

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

# --- Telegram file downloads ---

async def _download_telegram_file(file_obj, original_name: str | None = None) -> Path:
    """Download a Telegram file to DOWNLOADS_DIR and return the local path."""
    tg_file = await file_obj.get_file()
    ext = Path(tg_file.file_path).suffix if tg_file.file_path else ""

    if original_name:
        # Documents: preserve original name, prefix with timestamp to avoid collisions
        safe_name = f"{int(time.time())}_{original_name}"
    else:
        # Photos: use unique ID + extension
        safe_name = f"{file_obj.file_unique_id}{ext or '.jpg'}"

    dest = DOWNLOADS_DIR / safe_name
    await tg_file.download_to_drive(dest)
    log.info("Downloaded %s (%d bytes)", dest.name, dest.stat().st_size)
    return dest

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
        while True:
            raw_line = proc.stdout.readline()
            if not raw_line:
                break  # EOF
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


async def stream_claude(prompt: str, status_msg) -> tuple[str, list[str]]:
    """Spawn claude with stream-json, update status_msg live, return (text, written_files)."""
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

    # Strip CLAUDECODE env var to avoid "nested session" detection
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}

    log.info("Spawning claude (session=%s)", session_id[:8] if session_id else "new")

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        cwd=WORKSPACE,
        env=env,
        **popen_kwargs,
    )

    q = stdlib_queue.Queue()
    reader = threading.Thread(target=_read_stdout, args=(proc, q), daemon=True)
    reader.start()

    tool_log = []
    written_files = []
    last_edit = 0.0
    result_text = None
    pending_update = False
    loop = asyncio.get_running_loop()
    start = time.monotonic()

    while True:
        elapsed = time.monotonic() - start
        if elapsed > TIMEOUT:
            proc.kill()
            return f"Timed out after {TIMEOUT // 60}min. Try breaking it into smaller asks.", written_files

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
                    tool_name = block.get("name", "?")
                    tool_input = block.get("input", {})
                    desc = _describe_tool(tool_name, tool_input)
                    tool_log.append(desc)
                    pending_update = True
                    log.info("Tool: %s", desc)
                    if tool_name == "Write" and tool_input.get("file_path"):
                        written_files.append(tool_input["file_path"])

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
        return f"Error (exit {proc.returncode}): {stderr}", written_files

    if result_text is None:
        return (stderr or "(no response)"), written_files

    return result_text, written_files

# --- Outbound file sending ---

async def _send_written_files(chat, written_files: list[str]):
    """Send files that Claude wrote back to Telegram."""
    seen = set()
    workspace = Path(WORKSPACE).resolve()
    for raw_path in written_files:
        p = Path(raw_path)
        if not p.is_absolute():
            p = workspace / p
        p = p.resolve()
        if str(p) in seen:
            continue
        seen.add(str(p))

        if not p.exists():
            log.warning("Written file not found: %s", p)
            continue
        size = p.stat().st_size
        if size == 0:
            log.info("Skipping empty file: %s", p.name)
            continue

        try:
            if p.suffix.lower() in IMAGE_EXTENSIONS:
                if size > 10 * 1024 * 1024:
                    await chat.send_message(f"Image too large for Telegram (>10MB): {p.name}")
                    continue
                await chat.send_photo(photo=open(p, "rb"), caption=p.name)
            else:
                if size > 50 * 1024 * 1024:
                    await chat.send_message(f"File too large for Telegram (>50MB): {p.name}")
                    continue
                await chat.send_document(document=open(p, "rb"), filename=p.name)
            log.info("Sent file to Telegram: %s (%d bytes)", p.name, size)
        except Exception:
            log.exception("Failed to send file: %s", p.name)

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
    # Clean up downloaded files
    if DOWNLOADS_DIR.exists():
        shutil.rmtree(DOWNLOADS_DIR)
        DOWNLOADS_DIR.mkdir(exist_ok=True)
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
    msg = update.message
    text = msg.text or msg.caption or ""
    file_paths = []

    # Download photos
    if msg.photo:
        photo = msg.photo[-1]  # largest size
        path = await _download_telegram_file(photo)
        file_paths.append(str(path))

    # Download documents
    if msg.document:
        path = await _download_telegram_file(msg.document, msg.document.file_name)
        file_paths.append(str(path))

    # Build prompt
    if file_paths:
        file_refs = "\n".join(f"- {p}" for p in file_paths)
        default_text = "Please examine the file(s) above and describe what you see."
        user_text = text or default_text
        prompt = (
            f"I'm sending you file(s). Use the Read tool to read each one:\n"
            f"{file_refs}\n\n{user_text}"
        )
    else:
        prompt = text

    if not prompt:
        return

    log.info("Message from owner: %s", prompt[:80])

    status_msg = await msg.reply_text("Working...")

    typing = True
    async def keep_typing():
        while typing:
            await msg.chat.send_action("typing")
            await asyncio.sleep(4)
    typing_task = asyncio.create_task(keep_typing())

    written_files = []
    try:
        response, written_files = await stream_claude(prompt, status_msg)
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
            await msg.reply_text(chunk, parse_mode="Markdown")
        except Exception:
            await msg.reply_text(chunk)

    # Send any files Claude wrote
    if written_files:
        await _send_written_files(msg.chat, written_files)

# --- Main ---

def main():
    DOWNLOADS_DIR.mkdir(exist_ok=True)
    sid = session_id[:8] + "..." if session_id else "new"
    log.info("Starting ClaudeLink (session: %s)", sid)
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("clear", cmd_clear))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(MessageHandler(
        (filters.TEXT | filters.PHOTO | filters.Document.ALL) & ~filters.COMMAND,
        handle_message,
    ))
    app.run_polling(drop_pending_updates=True)

if __name__ == "__main__":
    main()
