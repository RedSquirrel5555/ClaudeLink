# ClaudeLink

A Telegram bot that bridges your messages to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI. Chat with Claude from your phone — with full access to your machine's tools and filesystem.

## How it works

1. You send a message in Telegram
2. The bot runs `claude -p "your message"` on your machine
3. Claude's response is sent back to you in Telegram
4. Sessions persist across messages via `--resume`, so Claude has full conversation context

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

## Security

- Only responds to the Telegram user ID in `OWNER_TELEGRAM_ID` — all other messages are silently ignored
- Your `.env` file contains secrets — never commit it

## License

MIT
