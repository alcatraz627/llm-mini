#!/usr/bin/env node
/**
 * llm-mini-mcp-server.js — MCP server exposing the llm-mini callable.
 *
 * Registered in .mcp.json as a stdio server. Provides tools: "ask", "list_templates".
 * Delegates all logic to llm-mini-core.sh — this server is a thin MCP wrapper.
 *
 * Usage (in .mcp.json):
 *   "llm-mini": { "type": "stdio", "command": "node",
 *                  "args": ["~/.claude/scripts/llm-mini-mcp-server.js"] }
 */

const { execFileSync } = require("child_process");
const os = require("os");
const path = require("path");

const LLM_MINI_CORE = path.join(os.homedir(), ".claude/scripts/llm-mini-core.sh");

function callMini(prompt, template, backend, maxTokens) {
  const args = [LLM_MINI_CORE];

  if (backend === "local") args.push("--local");
  else if (backend === "cloud") args.push("--quality");

  if (maxTokens) args.push("--max-tokens", String(maxTokens));
  if (template) args.push("--template", template);

  args.push(prompt);

  try {
    const result = execFileSync("bash", args, {
      timeout: 15000,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return result.trim();
  } catch (e) {
    return `Error: ${e.message}`;
  }
}

function listTemplates() {
  try {
    const result = execFileSync("bash", [LLM_MINI_CORE, "--list"], {
      timeout: 5000,
      encoding: "utf8",
    });
    return result.trim();
  } catch {
    return "Error listing templates";
  }
}

function sendResponse(id, result) {
  const response = { jsonrpc: "2.0", id, result };
  const json = JSON.stringify(response);
  process.stdout.write(
    `Content-Length: ${Buffer.byteLength(json)}\r\n\r\n${json}`
  );
}

function sendError(id, code, message) {
  const response = { jsonrpc: "2.0", id, error: { code, message } };
  const json = JSON.stringify(response);
  process.stdout.write(
    `Content-Length: ${Buffer.byteLength(json)}\r\n\r\n${json}`
  );
}

function handleRequest(msg) {
  const { id, method, params } = msg;

  switch (method) {
    case "initialize":
      sendResponse(id, {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "llm-mini", version: "2.0.0" },
      });
      break;

    case "notifications/initialized":
      break;

    case "tools/list":
      sendResponse(id, {
        tools: [
          {
            name: "ask",
            description:
              "Fast mini-model query (<1s). Uses local Ollama by default, falls back to cloud Haiku. Use for: session titles, doc lookups, command composition, short summaries. NOT for complex reasoning.",
            inputSchema: {
              type: "object",
              properties: {
                prompt: {
                  type: "string",
                  description: "The question or input text",
                },
                template: {
                  type: "string",
                  description:
                    "Optional template: session-title, doc-lookup, cmd-compose, summarize",
                  enum: [
                    "session-title",
                    "doc-lookup",
                    "cmd-compose",
                    "summarize",
                  ],
                },
                backend: {
                  type: "string",
                  description:
                    "Backend: auto (default), local (Ollama), cloud (Haiku)",
                  enum: ["auto", "local", "cloud"],
                  default: "auto",
                },
                max_tokens: {
                  type: "number",
                  description: "Max output tokens (default: 200)",
                  default: 200,
                },
              },
              required: ["prompt"],
            },
          },
          {
            name: "list_templates",
            description:
              "List available prompt templates for the mini-model",
            inputSchema: { type: "object", properties: {} },
          },
        ],
      });
      break;

    case "tools/call": {
      const toolName = params?.name;
      const toolArgs = params?.arguments || {};

      if (toolName === "ask") {
        const text = callMini(
          toolArgs.prompt || "",
          toolArgs.template,
          toolArgs.backend || "auto",
          toolArgs.max_tokens
        );
        sendResponse(id, { content: [{ type: "text", text }] });
      } else if (toolName === "list_templates") {
        sendResponse(id, {
          content: [{ type: "text", text: listTemplates() }],
        });
      } else {
        sendError(id, -32601, `Unknown tool: ${toolName}`);
      }
      break;
    }

    default:
      if (id !== undefined) {
        sendError(id, -32601, `Method not found: ${method}`);
      }
  }
}

// MCP stdio transport
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) break;
    const header = buffer.slice(0, headerEnd);
    const match = header.match(/Content-Length:\s*(\d+)/i);
    if (!match) {
      buffer = buffer.slice(headerEnd + 4);
      continue;
    }
    const contentLength = parseInt(match[1], 10);
    const bodyStart = headerEnd + 4;
    if (buffer.length < bodyStart + contentLength) break;
    const body = buffer.slice(bodyStart, bodyStart + contentLength);
    buffer = buffer.slice(bodyStart + contentLength);
    try {
      handleRequest(JSON.parse(body));
    } catch {
      // skip malformed
    }
  }
});
process.stdin.on("end", () => process.exit(0));
