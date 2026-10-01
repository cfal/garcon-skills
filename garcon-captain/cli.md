# Garcon CLI Reference

Use `"${GARCON_CLI[@]}"` below. Put connection options before the command when needed:

```bash
"${GARCON_CLI[@]}" --config-dir "$CONFIG_DIR" --runtime "$RUNTIME" --server "$SERVER" <command>
```

Omit optional connection flags that the user did not supply. `--config-dir` overrides `GARCON_CONFIG_DIR`, defaulting to `~/.garcon`. `--runtime` overrides `GARCON_RUNTIME`, defaulting to `auto`; explicit roles are `controller` and `executor`. Workspace selectors configure only the controller and are not CLI flags. `--server` asserts the selected runtime's URL; it does not redirect credentials.

Automatic discovery reads `<config-dir>/runtime.json` and `<config-dir>/executor/runtime.json`. When both exist, it selects the newer `startedAt` (controller on a tie) and warns on stderr. A failed selection never falls back to the other role. Garcon terminals and agent processes inherit their parent's config root and explicit role. Use the resolved role in follow-up commands, especially ticket retries; switching to the controller changes the caller's authority.

## Discover Selections

```bash
"${GARCON_CLI[@]}" list agents --json
"${GARCON_CLI[@]}" list preambles --json
"${GARCON_CLI[@]}" list providers --agent "$AGENT" --json
"${GARCON_CLI[@]}" list endpoints --agent "$AGENT" --provider "$PROVIDER" --json
"${GARCON_CLI[@]}" list models --agent "$AGENT" --provider "$PROVIDER" --json
"${GARCON_CLI[@]}" list permissions --agent "$AGENT" --json
"${GARCON_CLI[@]}" list reasoning-efforts --agent "$AGENT" --json
```

Resolve agent, provider, endpoint, then model. Provider names must be exact and unique; canonical IDs are safer. Preamble selections accept at most 100 unique UUIDs in order.

## Find Chats

```bash
"${GARCON_CLI[@]}" chats --filter 'project:/garcon tag:review is:!archived' --limit 50 --offset 0 --json
```

`chats` covers every registered chat, including chats whose project directory is unavailable. It sorts by effective activity descending with chat ID as the tie-breaker.

Filters:

- `title:`, `tag:`, `agent:`, `model:`, `project:`
- exact `id:` and direct-parent `parent:`
- `created-before:`, `created-after:`, `updated-before:`, `updated-after:`
- `status:active|unread`
- `is:pinned|normal|archived`, with `!` negation

Pipe-separated values are OR alternatives. Repeated `id:`, `parent:`, `title:`, and `tag:` groups are ANDed; `agent:`, `model:`, and `project:` values accumulate as alternatives. Bare terms match title, project path, first/last previews, and tags. Date-only values mean midnight UTC; datetimes require an RFC3339 timezone. `updated-*` means transcript/list activity, not metadata-edit time.

## Search And Read Transcripts

```bash
"${GARCON_CLI[@]}" transcript-search status --json
"${GARCON_CLI[@]}" transcript-search enable --json
"${GARCON_CLI[@]}" transcript-search rebuild --json
"${GARCON_CLI[@]}" transcript-search disable --json

"${GARCON_CLI[@]}" search '"version bump"' \
  --filter 'project:/garcon agent:codex' \
  --sort relevance --limit 20 --offset 0 --snippets 3 --json

"${GARCON_CLI[@]}" read "$CHAT_ID" "$ORDINAL" \
  -B 5 -A 5 --transcript-view-id "$VIEW_ID" --json
```

Search is lexical. Quoted phrases are adjacent within one indexed entry. Unquoted terms are ANDed at chat scope and may occur in different entries; terms of at least three code points use prefix matching. Sort is `relevance`, `activity`, or `created`. Page limits are 1–100, offsets 0–9,999, and snippets 1–3.

Metadata filtering happens before ranking. Do not split a filter selecting over 10,000 chats: narrow it. `page.total` is exact only when `index.resultsTruncated` is false. Follow `hasMore`/`nextOffset`, deduplicate IDs, and compare totals between pages; `created` is the least volatile long-enumeration order.

Coverage fields—pending, failed, unindexed, unsupported, truncation, and removed stale results—limit negative conclusions. Search snippets are bounded context. Plain search output emits a view-qualified `read` command. From JSON, map a hit to `read <chatId> <snippet.ordinal> --transcript-view-id <transcriptViewId>` and add context bounds. `read` defaults to the conversation spine; add repeatable or comma-separated categories when the anchor requires one: `tool-calls`, `tool-results`, `reasoning`, `permissions`, `diagnostics`, `handoffs`, or `tools`.

Use `export <chat-id> --format markdown|xml` for complete transcript retrieval. Use `handoff <chat-id> --context-window-size <tokens>` for a bounded summarization artifact. Both support `--output`; existing files require `--force`.

## Start And Resume Work

```bash
"${GARCON_CLI[@]}" start --cwd "$TARGET_DIR" \
  --agent "$AGENT" --provider "$PROVIDER" --endpoint "$ENDPOINT" \
  --model "$MODEL" --permissions "$PERMISSIONS" \
  --reasoning-effort "$EFFORT" --parent "$PARENT_CHAT_ID" \
  --tag delegated --title "$TITLE" --json - < "$PROMPT_FILE"

"${GARCON_CLI[@]}" start-async --cwd "$TARGET_DIR" \
  --agent "$AGENT" --model "$MODEL" --json - < "$PROMPT_FILE"
"${GARCON_CLI[@]}" resume "$CHAT_ID" --json - < "$PROMPT_FILE"
"${GARCON_CLI[@]}" resume-async "$CHAT_ID" --json - < "$PROMPT_FILE"
"${GARCON_CLI[@]}" resume-async "$CHAT_ID" --allow-steer --json - < "$PROMPT_FILE"
```

Omit flags without selected values. `start`/`resume` wait for the accepted turn; asynchronous forms return after acceptance. New chats always get the `cli` tag. `--parent` creates immutable delegation lineage. Use `--no-preamble` for none or repeat `--preamble <uuid>` for an exact ordered selection; omit both for server defaults. Existing chats retain their project and saved settings unless an explicitly supported resume override is requested.

Synchronous `start --json` and `resume --json` emit one versioned document only after settlement, combining acceptance metadata with `turnReceipt`. Failed, interrupted, and output-unavailable receipts are still emitted before the matching nonzero exit. Use the asynchronous forms followed by `wait --json` when automation needs the chat and turn IDs immediately.

`--parent` records lineage only; it does not copy transcript content, inherit settings, or make either chat wait. Synchronous `resume` supports explicit agent, routing, model, permission, effort, title, and tag overrides. `resume-async` always uses the chat's saved execution settings.

Start and resume messages support `--message-title`, `--message-style info|notice|error|custom`, custom `--color <light[,dark]>`, and `--collapsible`. This presentation is visible in Garcon but excluded from the prompt sent to the agent.

Put substantial prompts in a private temporary file and pass `-` through stdin. State the task, exact working directory, constraints, expected output, and validation. Point to readable files instead of copying them.

## Fork Chats

```bash
"${GARCON_CLI[@]}" fork "$SOURCE_CHAT_ID" --json
"${GARCON_CLI[@]}" fork "$SOURCE_CHAT_ID" --json - < "$PROMPT_FILE"
"${GARCON_CLI[@]}" fork-async "$SOURCE_CHAT_ID" --json - < "$PROMPT_FILE"
```

`fork` creates a whole-chat fork at the source's current transcript watermark. Bare `fork` returns after creation. Prompted `fork` atomically creates the fork and waits for its first turn; `fork-async` returns the accepted fork and turn IDs immediately. Every form supports JSON, and prompted synchronous JSON includes `turnReceipt`.

Forks require a settled native fork by default. Use `--allow-handoff-fork` only when a frozen provider-neutral transcript in a new native session is an acceptable fallback. Prompted forks have correlated retry protection. Bare forks do not; after an ambiguous failure, inspect the reported target chat ID before retrying.

## Monitor And Control

```bash
"${GARCON_CLI[@]}" status "$CHAT_ID" --messages 20 --json
"${GARCON_CLI[@]}" wait "$CHAT_ID" --turn "$TURN_ID" --json
"${GARCON_CLI[@]}" stop "$CHAT_ID" --json
```

`status` is a one-shot observation and includes processing, controls, queue state, transcript, and pending permissions. `wait` binds completion to the exact accepted turn. Available `wait --json` output contains the integration-selected final assistant response, including all of that response's text parts but not earlier commentary. An explicitly empty final succeeds without text; a successful turn with no identifiable final reports `no-final-response`. Failed and interrupted turns do not return partial commentary as the answer.

Turn receipts are process-local and may expire after restart or retention eviction even though the transcript remains durable. Terminal interruption only detaches the CLI; it does not stop Garcon work. Stopping a chat with queued messages pauses its queue; resume the queue in Garcon before sending a new direct turn.

For a Boolean permission request, copy every fence from `status`:

```bash
"${GARCON_CLI[@]}" permission-decision "$CHAT_ID" "$OCCURRENCE_ID" allow \
  --run "$RUN_ID" --server-instance "$SERVER_INSTANCE_ID" --json
```

Use `deny` to reject. For structured questions, copy exact question and option IDs:

```bash
"${GARCON_CLI[@]}" permission-answer "$CHAT_ID" "$OCCURRENCE_ID" \
  --answers '[{"questionId":"question-id","selectedOptionIds":["option-id"]}]' \
  --run "$RUN_ID" --server-instance "$SERVER_INSTANCE_ID" --json
```

Answer every pending question exactly once. Do not answer a newer occurrence with stale fences.

Exit codes are `0` for success, `1` when an accepted turn fails, `2` for an invalid request or selection, `3` for an operational, busy, or unavailable result, `4` for a stopped turn or deleted chat, and `130` for terminal interruption.

## Organize And Annotate

```bash
"${GARCON_CLI[@]}" archive "$CHAT_ID" --json
"${GARCON_CLI[@]}" unarchive "$CHAT_ID" --json
"${GARCON_CLI[@]}" pin "$CHAT_ID" --json
"${GARCON_CLI[@]}" unpin "$CHAT_ID" --json
"${GARCON_CLI[@]}" rename "$CHAT_ID" "$TITLE" --json
"${GARCON_CLI[@]}" set-tags "$CHAT_ID" --tag review --tag complete --json
"${GARCON_CLI[@]}" set-tags "$CHAT_ID" --clear --json
"${GARCON_CLI[@]}" add-row "$CHAT_ID" --type notice --title "$TITLE" --markdown --json "$CONTENT"
"${GARCON_CLI[@]}" lookup-native-session "$NATIVE_SESSION_ID" --agent "$AGENT"
```

Archive/pin commands set desired state and are safe to repeat. `set-tags` replaces the entire normalized tag set, including `cli`; it does not append. `add-row` creates presentation-only history: it is not sent to the agent or transcript search. Its JSON result includes the durable ordinal, transcript view, presentation, timestamp, and whether the row was appended or replayed as a duplicate.
