export function mapSessionUpdate(update) {
  if (!update) return null;
  if (update.sessionUpdate === "agent_message_chunk" && update.content?.type === "text") {
    return { kind: "agent_text", text: update.content.text };
  }
  if (update.sessionUpdate === "tool_call") {
    return {
      kind: "tool_call",
      toolCallId: update.toolCall?.toolCallId,
      title: update.toolCall?.title,
      status: update.toolCall?.status,
    };
  }
  if (update.sessionUpdate === "tool_call_update") {
    return {
      kind: "tool_call_update",
      toolCallId: update.toolCall?.toolCallId,
      status: update.toolCall?.status,
    };
  }
  return { kind: "session_update", sessionUpdate: update.sessionUpdate };
}
