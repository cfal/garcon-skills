---
name: garcon-agent
description: Direct an agent through an already-running Garcon server. Use for advice, reviews, implementation, testing, or follow-ups that should resume an existing Garcon chat.
---

# Garcon Agent

## Workflow

Resolve the CLI in this order: `garcon-cli` on `PATH`, `$HOME/garcon`, then `/garcon`.

```bash
GARCON_CLI=()
if garcon_cli_path=$(command -v garcon-cli 2>/dev/null); then
  GARCON_CLI=("$garcon_cli_path")
else
  for garcon_root in "$HOME/garcon" /garcon; do
    for garcon_entry in "$garcon_root/cli/main" "$garcon_root/cli/main.ts"; do
      if [[ -f "$garcon_entry" ]]; then
        GARCON_CLI=(bun "$garcon_entry")
        break 2
      fi
    done
  done
fi
```

If the array remains empty, stop and ask the user for the Garcon repository path, then use its first existing `cli/main` or `cli/main.ts` through `bun`. Otherwise verify with `"${GARCON_CLI[@]}" --version`; stop and tell the user if verification fails. Use the resolved array in each shell invocation below, repeating the block in later shell invocations when needed.

User inputs:

- `TARGET_DIR` is the absolute directory where the agent must work.
- `AGENT` is the agent. One of `pi`, `claude`, `codex`, or `opencode`.
- `MODEL` is the model.
- `PROVIDER` (optional) is the provider, only necessary for some providers or when not using defaults.
- `WORKSPACE` (optional) is the named Garcon workspace, not a filesystem path. Omit if the user did not provide.

For every new chat, pass `--cwd "$TARGET_DIR"` **and** put this instruction in the prompt:

```text
Perform all work in exactly: <absolute TARGET_DIR>
Do not switch to, edit, or run git commands in a parent checkout, the root repository, or a sibling worktree. Keep your work inside this directory.
If `pwd` returns this directory by default, do not add unnecessary `cd` commands.

*DO NOT start any agents or delegate the work, do the work yourself*
```

## Discover Exact Selections

Use the user's inputs to query before starting a new chat.
Omit `--workspace` if `WORKSPACE` is unset or set to `default`.
The output can be long, so use `grep -i` to filter on values provided by the user.

```bash
"${GARCON_CLI[@]}" --workspace "$WORKSPACE" list providers --agent "$AGENT" --json
"${GARCON_CLI[@]}" --workspace "$WORKSPACE" list endpoints --agent "$AGENT" --provider "$PROVIDER" --json
"${GARCON_CLI[@]}" --workspace "$WORKSPACE" list models --agent "$AGENT" --provider "$PROVIDER" --json
"${GARCON_CLI[@]}" --workspace "$WORKSPACE" list permissions --agent "$AGENT" --json
"${GARCON_CLI[@]}" --workspace "$WORKSPACE" list reasoning-efforts --agent "$AGENT" --json
```

Discover in dependency order: agent, provider, endpoint when applicable, then model. A provider is optional when the model is unambiguous; omit its filter in that case.

Validate user-supplied IDs against these live results. Resolve shorthand such as `opus` only when it has one unambiguous match.
Never silently substitute another agent, provider, model, or lower effort; ask when the requested choice is absent or ambiguous.

## Choose Permissions And Metadata

- Honor the user-selected permission mode. If not provided, select a suitable permission:
  - For implementation, fixes, or any other mutating task, use `--permissions bypassPermissions` automatically when supported. This skill grants permission to select it without asking again. If unsupported, use `manualBypass` when available; otherwise ask for direction. Never use `plan` for mutating work.
  - Never select `plan` mode without explicit direction from the user for any work.
- Treat review plus changes as mutating work.
- Pass the exact requested `--reasoning-effort` after validating it through discovery. Omit it when the user did not request an effort.
- Add each user-requested extra tag with a separate `--tag`. If the user has not specified a tag, include one of the following iff it is relevant: plan, review, implement
- Pass `--title` only when the user explicitly provides a title. Do not invent one.

## Prepare The Prompt

Put substantial prompts in a uniquely named temporary Markdown file and pass `-` through stdin. Include:

- The task and expected output.
- The exact `TARGET_DIR` confinement instruction above.
- Relevant branch, commit range, files, design docs, decisions, and constraints.
- Whether changes are required or prohibited.
- For delegated work, instructions to implement fully, validate, and report changed files and tests.

Point at files the consultant can read directly; do not copy repository contents into the prompt.

## Start Chat

Use only flags with actual values:

```bash
"${GARCON_CLI[@]}" \
  --workspace "$WORKSPACE" \
  --cwd "$TARGET_DIR" \
  --agent "$AGENT" \
  --provider "$PROVIDER" \
  --model "$MODEL" \
  --permissions "$PERMISSIONS" \
  --reasoning-effort "$EFFORT" \
  - < "$PROMPT_FILE"
```

Omit `--provider`, `--reasoning-effort`, and other optional flags when not selected. Append repeatable `--tag` flags and `--title` only when requested. Add `--endpoint` only when discovery shows it is needed.

Common request mapping:

- “Get Pi `alibaba-token-plan/qwen-3.8-max-preview` to implement…” means discover and validate agent `pi`, provider `alibaba-token-plan`, and that model; use the exact worktree, `bypassPermissions`, and no title or extra tags unless requested.
- “Get Claude opus at max effort to review…, add the review tag” means discover the unique Claude agent and opus model, validate `max`, use `plan`, add `--tag review`, and omit `--title`.
- For multiple consultants, create one chat per agent and keep each chat ID paired with its selection.

Do not impose an artificial timeout. Keep the CLI attached while the agent works or waits for Garcon interaction.

## Resume Chat

Resume follow-up work on the same topic and agent instead of starting over:

```bash
"${GARCON_CLI[@]}" \
  --workspace "$WORKSPACE" \
  --resume "$CHAT_ID" \
  - < "$FOLLOW_UP_PROMPT_FILE"
```

Use the chat ID recorded from the earlier turn; ask when it is unavailable. Never resume one agent's chat as another agent. Do not pass `--cwd` on resume because the chat retains it, but restate its exact recorded `TARGET_DIR` confinement in the follow-up prompt. Add title, tags, effort, permissions, model, provider, or endpoint only when explicitly requested or required for the new turn. A follow-up that changes from review to fixes must override permissions to a discovered write-capable mode.

## Return The Result

Expect stdout to print:

```text
chat id: <chat-id>
<agent response>
```

Record the chat ID immediately and return it with the agent and model. `SIGINT` detaches the CLI but does not stop the Garcon turn; use Garcon controls to stop work. After an accepted chat ID, inspect that chat before retrying a transport failure so the same task is not submitted twice.
