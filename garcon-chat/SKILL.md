---
name: garcon-chat
description: Communicate with Garcon agents by chat ID.
---

# Garcon Chat

Send one message between two existing Garcon chats and return as soon as Garcon accepts it.
Do not wait for the target agent to finish; replies arrive as separate messages through this same skill.

## Collect Inputs

Require:

- Caller agent chat ID: the chat ID of the agent sending the message.
- Target agent chat ID: the chat ID of the agent receiving the message.
- Message: the content to deliver.

Ask for any missing chat ID before sending. Treat `--workspace` as a named Garcon data workspace, not a filesystem path. Omit it when the workspace is unset or `default`.

Verify the CLI path before the first send:

```bash
bun /garcon/cli/main --version
```

If this fails, stop and inform the user. Never assume an installed `garcon-cli` executable.

## Format The Message

Prefix every outbound message exactly as follows:

```text
[garcon-chat: <CALLING_CHAT_ID> to <TARGET_CHAT_ID>] <message>
```

Put multiline or substantial messages in a uniquely named temporary Markdown file.

## Send Asynchronously

Always pass `--allow-steer`. It starts a new turn when the target is idle and steers the active turn when the target is busy; it never queues the message.

```bash
bun /garcon/cli/main \
  --workspace "$WORKSPACE" \
  send-async "$TARGET_CHAT_ID" \
  --allow-steer \
  - < "$MESSAGE_FILE"
```

Omit the `--workspace` pair for the default workspace. Pass `--config-dir` or `--server` only when the user explicitly supplies the corresponding Garcon connection setting. Do not use `--resume`; this workflow sends to an existing chat and must return immediately.

Expect successful output in this form:

```text
chat id: <TARGET_CHAT_ID>
delivery: new-turn|steer
turn id: <TURN_ID>
```

Verify that the returned chat ID matches the target. R`new-turn` means the target was idle; `steer` means the message entered its active turn.

If delivery fails because paused or queued work prevents both routes, report the failure instead of changing the target's execution state. After an ambiguous transport failure, inspect the target before retrying so the message is not submitted twice:

```bash
bun /garcon/cli/main --workspace "$WORKSPACE" status "$TARGET_CHAT_ID" --messages 10 --json
```

Again omit `--workspace` for the default workspace.
