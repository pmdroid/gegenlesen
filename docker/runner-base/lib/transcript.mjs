function contentText(block) {
  if (!block) return "";
  if (typeof block === "string") return block;
  if (typeof block.text === "string") return block.text;
  if (block.type === "text" && typeof block.content === "string") return block.content;
  if (block.content) return contentText(block.content);
  return "";
}

function extractText(update) {
  const direct = contentText(update.content);
  if (direct) return direct;
  if (typeof update.text === "string") return update.text;
  if (Array.isArray(update.content)) {
    return update.content.map(contentText).filter(Boolean).join("");
  }
  return "";
}

function extractTool(update) {
  const nested = update.toolCall && typeof update.toolCall === "object" ? update.toolCall : null;
  const toolCallId = nested?.toolCallId ?? nested?.id ?? update.toolCallId ?? update.id;
  const title = nested?.title ?? nested?.kind ?? update.title ?? update.kind ?? update.toolName;
  const status = nested?.status ?? update.status;
  return { toolCallId, title, status };
}

export function mapSessionUpdate(update) {
  if (!update) return null;
  const kind = update.sessionUpdate;
  if (kind === "agent_message_chunk" || kind === "agent_message" || kind === "agent_thought_chunk" || kind === "agent_thought") {
    const text = extractText(update);
    if (text) return { kind: "agent_text", text };
  }
  if (kind === "tool_call" || kind === "tool_call_update") {
    const tool = extractTool(update);
    return {
      kind,
      toolCallId: tool.toolCallId,
      title: tool.title,
      status: tool.status,
    };
  }
  return { kind: "session_update", sessionUpdate: kind };
}

export function liveTranscriptLine(mapped) {
  if (!mapped) return null;
  if (mapped.kind === "agent_text" && mapped.text) {
    return { type: "text", part: { type: "text", text: mapped.text } };
  }
  if (mapped.kind === "tool_call" || mapped.kind === "tool_call_update") {
    return {
      type: "tool",
      part: {
        type: "tool",
        tool: mapped.title || "tool",
        state: {
          status: mapped.status,
          title: mapped.title,
          toolCallId: mapped.toolCallId,
        },
      },
    };
  }
  return null;
}
