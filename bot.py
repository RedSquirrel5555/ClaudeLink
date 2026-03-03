"""ClaudeLink — Telegram bridge calling the Anthropic API directly via OAuth, with tool use."""

import asyncio
import base64
import glob as globmod
import json
import logging
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import anthropic
import httpx
from dotenv import load_dotenv
from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters

load_dotenv()

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
OWNER_ID = int(os.environ["OWNER_TELEGRAM_ID"])
TIMEOUT = int(os.getenv("COMMAND_TIMEOUT", "600"))
MAX_HISTORY = int(os.getenv("MAX_HISTORY", "50"))
MAX_TOOL_TURNS = 25

_MODEL_MAP = {"opus": "claude-opus-4-6", "sonnet": "claude-sonnet-4-6",
              "haiku": "claude-haiku-4-5-20251001"}
_raw_model = os.getenv("CLAUDE_MODEL", "opus")
MODEL = _MODEL_MAP.get(_raw_model, _raw_model)

BOT_DIR = Path(__file__).parent
WORKSPACE = Path(os.getenv("WORKSPACE_DIR", ".")).resolve()
CREDENTIALS_FILE = Path(os.environ.get("USERPROFILE", os.environ.get("HOME", "."))) / ".claude" / ".credentials.json"
HISTORY_FILE = BOT_DIR / ".history.json"
DOWNLOADS_DIR = BOT_DIR / "downloads"
MSG_LIMIT = 4000
STATUS_THROTTLE = 3

TOKEN_URL = "https://api.anthropic.com/v1/oauth/token"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_SCOPES = "user:inference user:profile user:sessions:claude_code user:mcp_servers"
OAUTH_BETA = "oauth-2025-04-20"

VISION_MEDIA_TYPES = {
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
    ".gif": "image/gif", ".webp": "image/webp",
}
IMAGE_EXTENSIONS = set(VISION_MEDIA_TYPES) | {".bmp", ".tiff", ".svg"}

logging.basicConfig(format="%(asctime)s [%(levelname)s] %(message)s", level=logging.INFO)
log = logging.getLogger("claudelink")

# ── System prompt ──

def _build_system_prompt() -> str:
    parts = []
    for fname in ["CLAUDE.md", "SOUL.md", "IDENTITY.md", "USER.md"]:
        fpath = BOT_DIR / fname
        if fpath.exists():
            content = fpath.read_text(encoding="utf-8").strip()
            if content:
                parts.append(f"# {fname}\n\n{content}")
    return "\n\n---\n\n".join(parts) if parts else ""

SYSTEM_PROMPT = _build_system_prompt()

# ── Tool definitions ──

TOOLS = [
    {
        "name": "Bash",
        "description": "Execute a shell command and return stdout/stderr.",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "The shell command to execute"},
            },
            "required": ["command"],
        },
    },
    {
        "name": "Read",
        "description": "Read a file and return its contents with line numbers.",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Absolute path to the file"},
                "offset": {"type": "integer", "description": "Line to start from (1-based)"},
                "limit": {"type": "integer", "description": "Number of lines to read"},
            },
            "required": ["file_path"],
        },
    },
    {
        "name": "Write",
        "description": "Write content to a file, creating directories if needed.",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Absolute path to the file"},
                "content": {"type": "string", "description": "Content to write"},
            },
            "required": ["file_path", "content"],
        },
    },
    {
        "name": "Edit",
        "description": "Replace an exact string in a file. old_string must be unique in the file.",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Absolute path to the file"},
                "old_string": {"type": "string", "description": "Exact text to find"},
                "new_string": {"type": "string", "description": "Replacement text"},
            },
            "required": ["file_path", "old_string", "new_string"],
        },
    },
    {
        "name": "Glob",
        "description": "Find files matching a glob pattern. Returns file paths.",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Glob pattern (e.g. '**/*.py')"},
                "path": {"type": "string", "description": "Directory to search in (default: cwd)"},
            },
            "required": ["pattern"],
        },
    },
    {
        "name": "Grep",
        "description": "Search file contents for a regex pattern. Returns matching lines.",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Regex pattern to search for"},
                "path": {"type": "string", "description": "File or directory to search in (default: cwd)"},
                "glob": {"type": "string", "description": "File glob filter (e.g. '*.py')"},
            },
            "required": ["pattern"],
        },
    },
    {
        "name": "WebFetch",
        "description": "Fetch content from a URL and return it as text.",
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "The URL to fetch"},
            },
            "required": ["url"],
        },
    },
]

# ── Tool execution ──

def _short(s: str, n: int = 40) -> str:
    return s if len(s) <= n else "..." + s[-(n - 3):]

def _describe_tool(name: str, inp: dict) -> str:
    descs = {
        "Read":      lambda i: f"Reading {_short(i.get('file_path', '?'))}",
        "Glob":      lambda i: f"Searching for {i.get('pattern', 'files')}",
        "Grep":      lambda i: f"Searching code for \"{i.get('pattern', '...')}\"",
        "Bash":      lambda i: "Running command",
        "Write":     lambda i: f"Writing {_short(i.get('file_path', '?'))}",
        "Edit":      lambda i: f"Editing {_short(i.get('file_path', '?'))}",
        "WebFetch":  lambda i: f"Fetching {_short(i.get('url', '?'), 60)}",
    }
    fn = descs.get(name)
    return fn(inp) if fn else f"Using {name}"


async def _tool_bash(inp: dict) -> str:
    cmd = inp["command"]
    try:
        result = await asyncio.to_thread(
            subprocess.run,
            ["bash", "-c", cmd],
            capture_output=True, text=True, timeout=120,
            cwd=str(WORKSPACE), stdin=subprocess.DEVNULL,
        )
        out = result.stdout
        if result.stderr:
            out += ("\n" if out else "") + result.stderr
        if result.returncode != 0:
            out += f"\n(exit code {result.returncode})"
        return (out[:50000] if out else "(no output)").strip()
    except subprocess.TimeoutExpired:
        return "Command timed out after 120s"
    except Exception as e:
        return f"Error: {e}"


def _tool_read(inp: dict) -> str:
    p = Path(inp["file_path"])
    if not p.exists():
        return f"File not found: {p}"
    try:
        lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception as e:
        return f"Error reading file: {e}"
    offset = max(inp.get("offset", 1), 1) - 1  # convert 1-based to 0-based
    limit = inp.get("limit", len(lines))
    selected = lines[offset:offset + limit]
    numbered = [f"{i + offset + 1:>6}\t{line}" for i, line in enumerate(selected)]
    text = "\n".join(numbered)
    if len(text) > 100000:
        text = text[:100000] + "\n...(truncated)"
    return text or "(empty file)"


def _tool_write(inp: dict) -> str:
    p = Path(inp["file_path"])
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(inp["content"], encoding="utf-8")
        return f"Wrote {len(inp['content'])} bytes to {p}"
    except Exception as e:
        return f"Error writing file: {e}"


def _tool_edit(inp: dict) -> str:
    p = Path(inp["file_path"])
    if not p.exists():
        return f"File not found: {p}"
    try:
        text = p.read_text(encoding="utf-8")
    except Exception as e:
        return f"Error reading file: {e}"
    old = inp["old_string"]
    count = text.count(old)
    if count == 0:
        return "old_string not found in file"
    if count > 1:
        return f"old_string found {count} times — must be unique. Add more context."
    text = text.replace(old, inp["new_string"], 1)
    p.write_text(text, encoding="utf-8")
    return f"Edited {p}"


def _tool_glob(inp: dict) -> str:
    pattern = inp["pattern"]
    base = inp.get("path", str(WORKSPACE))
    try:
        matches = sorted(globmod.glob(os.path.join(base, pattern), recursive=True))
        if not matches:
            return "No files matched"
        result = "\n".join(matches[:200])
        if len(matches) > 200:
            result += f"\n...({len(matches)} total)"
        return result
    except Exception as e:
        return f"Error: {e}"


def _tool_grep(inp: dict) -> str:
    pattern = inp["pattern"]
    base = Path(inp.get("path", str(WORKSPACE)))
    file_glob = inp.get("glob", "**/*")
    try:
        regex = re.compile(pattern)
    except re.error as e:
        return f"Invalid regex: {e}"
    results = []
    try:
        files = [base] if base.is_file() else sorted(base.glob(file_glob))
        for f in files:
            if not f.is_file() or f.stat().st_size > 1_000_000:
                continue
            try:
                text = f.read_text(encoding="utf-8", errors="replace")
                for i, line in enumerate(text.splitlines(), 1):
                    if regex.search(line):
                        results.append(f"{f}:{i}:{line}")
                        if len(results) >= 200:
                            break
            except (PermissionError, OSError):
                continue
            if len(results) >= 200:
                break
    except Exception as e:
        return f"Error: {e}"
    return "\n".join(results) if results else "No matches found"


async def _tool_webfetch(inp: dict) -> str:
    try:
        async with httpx.AsyncClient(follow_redirects=True) as http:
            resp = await http.get(inp["url"], timeout=15)
            text = resp.text
            if len(text) > 50000:
                text = text[:50000] + "\n...(truncated)"
            return text
    except Exception as e:
        return f"Error fetching URL: {e}"


async def _execute_tool(name: str, inp: dict) -> str:
    dispatch = {
        "Bash": _tool_bash, "Read": _tool_read, "Write": _tool_write,
        "Edit": _tool_edit, "Glob": _tool_glob, "Grep": _tool_grep,
        "WebFetch": _tool_webfetch,
    }
    fn = dispatch.get(name)
    if not fn:
        return f"Unknown tool: {name}"
    try:
        if asyncio.iscoroutinefunction(fn):
            return await fn(inp)
        return fn(inp)
    except Exception as e:
        return f"Tool error: {type(e).__name__}: {e}"

# ── OAuth token management ──

def _load_credentials() -> dict:
    data = json.loads(CREDENTIALS_FILE.read_text(encoding="utf-8"))
    return data.get("claudeAiOauth", {})

def _save_credentials(creds: dict):
    data = {}
    if CREDENTIALS_FILE.exists():
        data = json.loads(CREDENTIALS_FILE.read_text(encoding="utf-8"))
    data["claudeAiOauth"] = creds
    CREDENTIALS_FILE.write_text(json.dumps(data), encoding="utf-8")

async def _get_access_token() -> str:
    creds = _load_credentials()
    expires_at = creds.get("expiresAt", 0)
    if time.time() * 1000 > expires_at - 300_000:
        log.info("Refreshing OAuth token...")
        async with httpx.AsyncClient() as http:
            resp = await http.post(TOKEN_URL, json={
                "grant_type": "refresh_token",
                "refresh_token": creds["refreshToken"],
                "client_id": CLIENT_ID,
                "scope": OAUTH_SCOPES,
            }, headers={"Content-Type": "application/json"}, timeout=15)
            resp.raise_for_status()
            new = resp.json()
        creds["accessToken"] = new["access_token"]
        creds["refreshToken"] = new.get("refresh_token", creds["refreshToken"])
        creds["expiresAt"] = int(time.time() * 1000) + new.get("expires_in", 3600) * 1000
        _save_credentials(creds)
        log.info("OAuth token refreshed")
    return creds["accessToken"]

def _make_client(access_token: str) -> anthropic.AsyncAnthropic:
    return anthropic.AsyncAnthropic(
        api_key=None,
        default_headers={
            "Authorization": f"Bearer {access_token}",
            "anthropic-beta": OAUTH_BETA,
        },
    )

# ── Conversation history ──

def _load_history() -> list[dict]:
    if HISTORY_FILE.exists():
        try:
            data = json.loads(HISTORY_FILE.read_text(encoding="utf-8"))
            if isinstance(data, list):
                return data
        except (json.JSONDecodeError, OSError):
            pass
    return []

def _save_history(history: list[dict]):
    MAX_SAVE = 2000
    cleaned = []
    for msg in history:
        content = msg.get("content")
        if isinstance(content, list):
            cblocks = []
            for block in content:
                if isinstance(block, dict):
                    if block.get("type") == "image":
                        cblocks.append({"type": "text", "text": "[image]"})
                    elif block.get("type") == "tool_result":
                        c = block.get("content", "")
                        if isinstance(c, str) and len(c) > MAX_SAVE:
                            c = c[:MAX_SAVE] + "...(truncated)"
                        cblocks.append({**block, "content": c})
                    else:
                        cblocks.append(block)
                else:
                    cblocks.append(block)
            cleaned.append({"role": msg["role"], "content": cblocks})
        elif isinstance(content, str) and len(content) > MAX_SAVE:
            cleaned.append({"role": msg["role"], "content": content[:MAX_SAVE] + "...(truncated)"})
        else:
            cleaned.append(msg)
    HISTORY_FILE.write_text(json.dumps(cleaned, ensure_ascii=False), encoding="utf-8")

conversation_history: list[dict] = _load_history()
msg_count = 0

# ── Telegram file helpers ──

async def _download_telegram_file(file_obj, original_name: str | None = None) -> Path:
    tg_file = await file_obj.get_file()
    ext = Path(tg_file.file_path).suffix if tg_file.file_path else ""
    if original_name:
        safe_name = f"{int(time.time())}_{original_name}"
    else:
        safe_name = f"{file_obj.file_unique_id}{ext or '.jpg'}"
    dest = DOWNLOADS_DIR / safe_name
    await tg_file.download_to_drive(dest)
    log.info("Downloaded %s (%d bytes)", dest.name, dest.stat().st_size)
    return dest

def _file_to_content_blocks(path: Path) -> list[dict]:
    ext = path.suffix.lower()
    media_type = VISION_MEDIA_TYPES.get(ext)
    if media_type:
        data = base64.standard_b64encode(path.read_bytes()).decode("ascii")
        return [{"type": "image", "source": {
            "type": "base64", "media_type": media_type, "data": data,
        }}]
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
        return [{"type": "text", "text": f"[File: {path.name}]\n{text}"}]
    except Exception:
        return []

# ── Owner guard ──

def owner_only(func):
    async def wrapper(update: Update, context):
        if update.effective_user.id != OWNER_ID:
            return
        return await func(update, context)
    return wrapper

# ── Status editing ──

async def _edit_status(msg, text: str):
    if len(text) > MSG_LIMIT:
        text = text[-MSG_LIMIT:]
    try:
        await msg.edit_text(text)
    except Exception:
        pass

# ── Streaming Claude API with agentic tool loop ──

async def stream_claude(content_blocks: list, status_msg) -> tuple[str, list[str]]:
    """Call Claude API with streaming and tool use. Returns (response_text, written_files)."""
    global conversation_history

    conversation_history.append({"role": "user", "content": content_blocks})

    max_msgs = MAX_HISTORY * 2
    if len(conversation_history) > max_msgs:
        conversation_history = conversation_history[-max_msgs:]

    written_files = []
    tool_log = []
    response_text = ""

    for turn in range(MAX_TOOL_TURNS):
        access_token = await _get_access_token()
        client = _make_client(access_token)

        log.info("API call (turn %d, history=%d msgs)", turn + 1, len(conversation_history))

        response_text = ""
        last_edit = 0.0

        try:
            async with client.messages.stream(
                model=MODEL,
                max_tokens=16384,
                system=SYSTEM_PROMPT,
                messages=conversation_history,
                tools=TOOLS,
            ) as stream:
                async for event in stream:
                    # Stream text preview to status
                    if event.type == "content_block_delta" and hasattr(event.delta, "text"):
                        response_text += event.delta.text
                        now = time.monotonic()
                        if now - last_edit >= STATUS_THROTTLE:
                            preview = response_text[-300:] if len(response_text) > 300 else response_text
                            status = ("\n".join(tool_log) + "\n\n" + preview).strip() if tool_log else preview
                            await _edit_status(status_msg, status)
                            last_edit = now

                final_msg = await stream.get_final_message()

        except anthropic.AuthenticationError:
            log.warning("Auth error, forcing token refresh...")
            creds = _load_credentials()
            creds["expiresAt"] = 0
            _save_credentials(creds)
            _pop_failed_user_msg()
            return "Auth expired — please try again.", written_files
        except anthropic.APIError as e:
            log.error("API error: %s", e)
            _pop_failed_user_msg()
            return f"API Error: {e}", written_files
        except Exception as e:
            log.exception("API call failed")
            _pop_failed_user_msg()
            return f"Error: {type(e).__name__}: {e}", written_files

        # Serialize assistant message for history
        assistant_content = []
        for block in final_msg.content:
            if block.type == "text":
                assistant_content.append({"type": "text", "text": block.text})
            elif block.type == "tool_use":
                assistant_content.append({
                    "type": "tool_use", "id": block.id,
                    "name": block.name, "input": block.input,
                })
        conversation_history.append({"role": "assistant", "content": assistant_content})

        # If no tool use, we're done
        if final_msg.stop_reason != "tool_use":
            _save_history(conversation_history)
            log.info("Response: %d chars, %d tool turns", len(response_text), turn + 1)
            return response_text, written_files

        # Execute tools
        tool_results = []
        for block in final_msg.content:
            if block.type != "tool_use":
                continue
            desc = _describe_tool(block.name, block.input)
            tool_log.append(desc)
            log.info("Tool: %s", desc)
            await _edit_status(status_msg, "\n".join(tool_log))

            result = await _execute_tool(block.name, block.input)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": block.id,
                "content": result,
            })
            if block.name == "Write" and block.input.get("file_path"):
                written_files.append(block.input["file_path"])

        conversation_history.append({"role": "user", "content": tool_results})

    _save_history(conversation_history)
    return response_text or "(max tool turns reached)", written_files


def _pop_failed_user_msg():
    global conversation_history
    if conversation_history and conversation_history[-1].get("role") == "user":
        conversation_history.pop()

# ── Outbound file sending ──

async def _send_written_files(chat, written_files: list[str]):
    seen = set()
    for raw_path in written_files:
        p = Path(raw_path).resolve()
        if str(p) in seen or not p.exists():
            continue
        seen.add(str(p))
        size = p.stat().st_size
        if size == 0:
            continue
        try:
            if p.suffix.lower() in IMAGE_EXTENSIONS and size <= 10 * 1024 * 1024:
                await chat.send_photo(photo=open(p, "rb"), caption=p.name)
            elif size <= 50 * 1024 * 1024:
                await chat.send_document(document=open(p, "rb"), filename=p.name)
            log.info("Sent file: %s (%d bytes)", p.name, size)
        except Exception:
            log.exception("Failed to send file: %s", p.name)

# ── Handlers ──

@owner_only
async def cmd_start(update: Update, context):
    await update.message.reply_text("ClaudeLink online. Send me anything.")

@owner_only
async def cmd_clear(update: Update, context):
    global conversation_history, msg_count
    conversation_history = []
    msg_count = 0
    for f in [HISTORY_FILE, BOT_DIR / ".session"]:
        if f.exists():
            f.unlink()
    if DOWNLOADS_DIR.exists():
        shutil.rmtree(DOWNLOADS_DIR)
        DOWNLOADS_DIR.mkdir(exist_ok=True)
    await update.message.reply_text("Session reset. Next message starts fresh.")

@owner_only
async def cmd_status(update: Update, context):
    await update.message.reply_text(
        f"Messages: {msg_count}\nHistory: {len(conversation_history)} entries\nModel: {MODEL}"
    )

@owner_only
async def handle_message(update: Update, context):
    global msg_count
    msg = update.message
    text = msg.text or msg.caption or ""
    content_blocks = []

    if msg.photo:
        photo = msg.photo[-1]
        path = await _download_telegram_file(photo)
        content_blocks.extend(_file_to_content_blocks(path))

    if msg.document:
        path = await _download_telegram_file(msg.document, msg.document.file_name)
        content_blocks.extend(_file_to_content_blocks(path))

    if text:
        content_blocks.append({"type": "text", "text": text})
    elif content_blocks:
        content_blocks.append({"type": "text", "text": "Describe what you see."})

    if not content_blocks:
        return

    log.info("Message from owner: %s", text[:80] if text else "[file]")

    status_msg = await msg.reply_text("Working...")

    typing = True
    async def keep_typing():
        while typing:
            await msg.chat.send_action("typing")
            await asyncio.sleep(4)
    typing_task = asyncio.create_task(keep_typing())

    written_files = []
    try:
        response, written_files = await stream_claude(content_blocks, status_msg)
    except Exception as e:
        log.exception("Claude invocation failed")
        response = f"Error: {type(e).__name__}: check logs."
    finally:
        typing = False
        typing_task.cancel()

    msg_count += 1

    try:
        await status_msg.delete()
    except Exception:
        pass

    chunks = [response[i : i + MSG_LIMIT] for i in range(0, len(response), MSG_LIMIT)]
    for chunk in chunks:
        try:
            await msg.reply_text(chunk, parse_mode="Markdown")
        except Exception:
            await msg.reply_text(chunk)

    if written_files:
        await _send_written_files(msg.chat, written_files)

# ── Main ──

def main():
    DOWNLOADS_DIR.mkdir(exist_ok=True)
    log.info("Starting ClaudeLink (model=%s, history=%d msgs)", MODEL, len(conversation_history))
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
