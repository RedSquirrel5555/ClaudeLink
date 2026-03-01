# ClaudeLink

A Telegram bot that bridges your messages to Claude — with full tool access to your machine's filesystem and shell. Chat with Claude from your phone.

## How it works

1. You send a message in Telegram
2. The bot calls the Anthropic API directly using your Claude subscription's OAuth token
3. Claude can use tools (Read, Write, Edit, Bash, Glob, Grep, WebFetch) — executed locally by the bot
4. As Claude works, the status message updates in real-time showing tool activity and a response preview
5. When Claude finishes, the final response is sent and any written files are shared back
6. Conversation history persists across messages

### Live streaming progress

While Claude works, you'll see a live status message showing tools being used and a preview of the response:

```
Reading src/auth.ts
Searching code for "validateToken"
Running command
Editing src/auth.ts
```

### File and image sharing

**Telegram → Claude:** Send a photo or document in the chat. Images are sent to the API as vision content. Other files are read and included as text.

**Claude → Telegram:** When Claude writes files using the Write tool, they're automatically sent back to you. Images are sent as photos; everything else as documents.

## Prerequisites

- Python 3.10+
- A Claude subscription (Pro/Max) with Claude Code authenticated (`claude login`)
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
| `/clear`  | Reset conversation and history       |
| `/status` | Show message count, history size, model |

## Tools

Claude has access to these tools, executed locally by the bot:

| Tool       | Description                              |
|------------|------------------------------------------|
| `Bash`     | Run shell commands (via Git Bash on Windows) |
| `Read`     | Read files with line numbers             |
| `Write`    | Create or overwrite files                |
| `Edit`     | Find-and-replace in files                |
| `Glob`     | Find files by glob pattern               |
| `Grep`     | Search file contents with regex          |
| `WebFetch` | Fetch content from URLs                  |

The agentic loop supports up to 25 tool turns per message.

## Personality (optional)

The bot builds a system prompt from personality files in the project directory:

- `CLAUDE.md` — base instructions
- `SOUL.md` — personality and style
- `IDENTITY.md` — name and identity
- `USER.md` — context about you

These are optional. Without them, Claude responds with its default personality.

## Architecture

```
Telegram  ←→  bot.py  ←→  Anthropic API (direct HTTP)
                │
                ├── OAuth bearer auth from Claude subscription
                ├── Auto token refresh via stored credentials
                ├── Streaming responses with live preview
                ├── Agentic tool loop (up to 25 turns)
                ├── Tools executed locally in Python
                └── Written files sent back to Telegram
```

Key implementation details:
- Calls the Anthropic Messages API directly — no Claude Code CLI or subprocess
- Authenticates via OAuth token from `~/.claude/.credentials.json` with `anthropic-beta: oauth-2025-04-20`
- Streaming via the `anthropic` Python SDK for real-time response preview
- Tool results are fed back to the API for multi-turn agentic workflows
- Conversation history (including tool use) persisted to `.history.json`
- Large tool results truncated when saving to keep history manageable

## Security

- Only responds to the Telegram user ID in `OWNER_TELEGRAM_ID` — all other messages are silently ignored
- Your `.env` file contains secrets — never commit it
- Tools run with full filesystem/shell access — this is a personal bot, not a multi-user service

## License

MIT
