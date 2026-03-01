/**
 * bridge.mjs — Node.js bridge between ClaudeLink (Python) and the Claude Agent SDK.
 *
 * Reads prompt from stdin, streams SDK messages as NDJSON to stdout.
 * Env vars:
 *   BRIDGE_SESSION_ID  — session UUID to resume (optional)
 *   BRIDGE_MODEL       — model short name or full ID (optional)
 */

import { query } from "@anthropic-ai/claude-agent-sdk";

// Read entire prompt from stdin
const chunks = [];
process.stdin.setEncoding("utf-8");
for await (const chunk of process.stdin) {
  chunks.push(chunk);
}
const prompt = chunks.join("").trim();

if (!prompt) {
  process.stderr.write("bridge: no prompt on stdin\n");
  process.exit(1);
}

// Strip nested-session detection so the SDK can spawn its own CLI process
delete process.env.CLAUDECODE;

const sessionId = process.env.BRIDGE_SESSION_ID || undefined;
const model = process.env.BRIDGE_MODEL || undefined;

try {
  const q = query({
    prompt,
    options: {
      ...(sessionId && { resume: sessionId }),
      ...(model && { model }),
      includePartialMessages: true,
      allowedTools: [
        "Bash", "Read", "Write", "Edit", "Glob", "Grep",
        "WebFetch", "WebSearch", "Task",
      ],
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      settingSources: ["user", "project"],
      stderr: (data) => process.stderr.write(data),
    },
  });

  for await (const message of q) {
    process.stdout.write(JSON.stringify(message) + "\n");
  }
} catch (err) {
  const detail = err.stack || err.message || String(err);
  process.stderr.write(`bridge error: ${detail}\n`);
  // Emit error as a result event so the Python caller can parse it uniformly
  process.stdout.write(
    JSON.stringify({
      type: "result",
      subtype: "error_during_execution",
      result: String(err.message || err),
      is_error: true,
    }) + "\n"
  );
  process.exit(1);
}
