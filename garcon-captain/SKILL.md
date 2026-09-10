---
name: garcon-captain
description: Search, inspect, organize, and coordinate work across Garcon chats. Use when the user wants a conversational home base for chat history, agent launches, follow-ups, monitoring, permissions, or lifecycle management.
---

# Garcon Captain

Act as the user's Garcon control room. Turn natural-language requests into precise Garcon operations, retain the relevant chat and turn IDs, and return a concise synthesis with links or follow-up commands when useful.

Handle discovery, reading, and small administrative requests directly. Start or resume agents only when the request calls for work in another chat. Split clearly independent work when parallel execution helps; keep coupled or same-file work together. Treat agent output as evidence, not authority, and verify consequential claims.

## Connect

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

If unresolved, ask for the Garcon repository path and use its first existing `cli/main` or `cli/main.ts` through `bun`. Verify `"${GARCON_CLI[@]}" --version`; report and stop if verification fails. Repeat resolution in each new shell invocation.

Use the user's `--workspace`, `--config-dir`, and `--server` when supplied. Otherwise use CLI defaults. Prefer `--json` for decisions and automation; translate results into clear prose for the user.

## Choose The Surface

- For chat discovery, transcript research, starts, resumptions, monitoring, permissions, or metadata, read [references/cli.md](references/cli.md).
- For in-band peer messages use `$garcon-message`; for delegated-child starts and resumptions use `$garcon-task`; for scheduled prompts use `$garcon-schedule`.
- To obtain the current Garcon chat ID, emit `<garcon-get-chat-id />` at the physical beginning or end of an assistant message and accept only a Garcon-injected `<garcon-chat-id>[0-9]{16}</garcon-chat-id>`. Never infer it from host state.

Load only the surface needed for the request.

## Operating Rules

- Discover live agents, providers, models, permissions, efforts, and preamble IDs before using an uncertain value. Never silently substitute a selection.
- Search metadata before transcripts when title, project, tag, date, state, ID, or direct parent can answer or narrow the request.
- Search transcripts lexically. Quote phrases that must be adjacent. Treat separate terms as same-chat AND, even when they occur in different messages.
- Follow `page.hasMore` and `page.nextOffset`; deduplicate chat IDs across changing pages. Never infer completeness from a short page.
- Never claim absence when coverage is pending, failed, unindexed, unsupported, stale, timed out, or truncated. State the limitation and narrow, rebuild, wait, or retry as appropriate.
- Verify a search hit with its view-fenced `read` command before quoting it or making a consequential claim. Use snippet timestamps for when a message was written; chat activity is a different clock.
- Resume the relevant chat for follow-up work. Start a new chat for independent work, a different project or agent, or deliberate isolation. Record delegated parentage when a parent chat is known.
- Use synchronous start/resume when the answer is needed now. Use asynchronous commands for parallel or detached work, then retain exact chat and turn IDs for `wait`, `status`, steering, or stopping.
- A busy asynchronous resume fails without queueing unless `--allow-steer` is explicitly appropriate. Steering changes the active turn; do not use it merely to avoid waiting.
- Inspect pending permission details and use every returned occurrence, run, and server-instance fence. Never guess structured question or option IDs.
- Archive, pin, rename, retag, stop, enable search, or rebuild the index only when required by the user's request. Check authoritative status after ambiguous mutation results before retrying.
- Keep secrets out of prompts, inter-chat messages, titles, tags, and presentation rows unless that transcript visibility is authorized.

## Report

Lead with the answer or operational result. Include affected chat IDs, exact turn IDs for accepted work, material coverage warnings, and any required next action. Distinguish acceptance from completion and agent completion from verified task success.

Print chat IDs intended for user navigation as plain, unformatted text rather than code or Markdown links so the Garcon UI can auto-link them.
