# ClaudeLink

A Telegram bot that bridges your messages to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI. Chat with Claude from your phone — with full access to your machine's tools and filesystem.

## How it works

1. You send a message in Telegram
2. The bot sends a "Working..." status message and spawns `claude -p` with streaming output
3. As Claude uses tools (reading files, running commands, searching the web), the status message updates in real-time so you can see what's happening
4. When Claude finishes, the status message is removed and the final response is sent
5. Sessions persist across messages via `--resume`, so Claude has full conversation context

### Live streaming progress

While Claude works, you'll see a live status message that updates as tools are used:

```
Reading src/auth.ts
Searching code for "validateToken"
Running command
Editing src/auth.ts
```

Status updates are throttled to respect Telegram's rate limits (max 1 edit per 3 seconds).

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Python 3.10+
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Your Telegram user ID (from [@userinfobot](https://t.me/userinfobot))

## Setup

1. Clone the repo:
   ```bash
   git clone https://github.com/RedSquirrel5555/ClaudeLink.git
   cd ClaudeLink
   ```

2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

3. Create a `.env` file (see `.env.example`):
   ```
   TELEGRAM_BOT_TOKEN=your-bot-token
   OWNER_TELEGRAM_ID=your-telegram-user-id
   CLAUDE_MODEL=opus
   WORKSPACE_DIR=.
   COMMAND_TIMEOUT=600
   ```

4. Run the bot:
   ```bash
   python bot.py
   ```

### Running with pm2 (recommended)

```bash
pm2 start ecosystem.config.js
pm2 save
```

## Telegram commands

| Command   | Description                          |
|-----------|--------------------------------------|
| `/start`  | Confirm the bot is online            |
| `/clear`  | Reset the session (new conversation) |
| `/status` | Show session ID, message count, model|

## Personality (optional)

ClaudeLink looks for a `CLAUDE.md` file in the workspace directory. Claude Code reads this automatically and uses it as a system prompt. You can also add personality files referenced from `CLAUDE.md`:

- `SOUL.md` — personality and style
- `IDENTITY.md` — name and identity
- `USER.md` — context about you

These are optional. Without them, Claude responds with its default personality.

## Architecture

```
Telegram  ←→  bot.py  ←→  claude CLI (subprocess)
                │
                ├── Popen with --output-format stream-json --verbose
                ├── NDJSON lines read in background thread
                ├── tool_use events → live status message edits
                └── result event → final response sent to chat
```

Key implementation details:
- Uses `subprocess.Popen` (not `subprocess.run`) for streaming output
- Stdout is read line-by-line in a daemon thread, parsed as NDJSON
- An `asyncio.Queue` bridges the reader thread to the async event loop
- `CREATE_NO_WINDOW` flag on Windows prevents console popups
- `stdin=DEVNULL` prevents the subprocess from hanging on input

## Security

- Only responds to the Telegram user ID in `OWNER_TELEGRAM_ID` — all other messages are silently ignored
- Your `.env` file contains secrets — never commit it

## License

MIT
