---
name: garcon-issues
description: Create, query, claim, update, comment on, and close durable Garcon workspace issues. Use for requested issue management, not agent delegation, scheduling, or generic task lists.
---

# Garcon Issues

Issues persist independently of chats. Stay within requested issue work; do not start agents, schedule execution, or edit `issues.sqlite` directly.

## In-band commands

Inside Garcon, emit commands at an assistant message's physical beginning or end, outside code fences, touching that edge. Put a suffix after prose on a new line. Double-quote attributes. XML-escape `&` and `<` in bodies, including JSON; also escape `"` in attributes. Fenced examples are inert.

Mutations require a nonblank `ref` (single line, maximum 128 UTF-8 bytes); reads accept one optionally. Except `create`/`list`, commands require `issue-id="ISS-n"`. Read current revisions; never guess them.

| Verb (`garcon-issue-…`) | Additional attributes | Body |
| --- | --- | --- |
| `list` | none | Optional JSON filters: `project`, `status`, `includeClosed`, `priority`, `label`, `assignee`, `ready`, `query`, `limit`. |
| `read` | none | Optional JSON: `includeDescription`, `commentLimit`. |
| `history` | none | Optional JSON: `limit`, `beforeSequence`. |
| `create` | none | JSON with `title`; optional `description`, `project`, `priority`, `labels`, `assignee`, `parentId`. |
| `update` | `expected-revision` | JSON patch of create fields or nonclosed `status`; null clears assignee/parent. |
| `claim`, `release`, `reopen` | `expected-revision` | Self-closing only. |
| `close` | `expected-revision` | Self-closing for Done; otherwise JSON with `resolution: "done"` or `"canceled"`, optional `comment`. |
| `comment` | none | Nonblank text, not JSON. |
| `comment-edit` | `comment-id`, `expected-revision` | Nonblank text; revision belongs to the comment. |
| `comment-delete` | `comment-id`, `expected-revision` | Self-closing; revision belongs to the comment. |
| `link`, `unlink` | `expected-revision` | JSON: `targetId`, `targetRevision`, `kind: "blocks"` or `"related"`. |

Examples are independent; substitute actual issue IDs and current revisions:

```text
<garcon-issue-list>{"ready":true,"limit":10}</garcon-issue-list>
<garcon-issue-read issue-id="ISS-42" />
<garcon-issue-create ref="track-draft-recovery">{"title":"Preserve drafts after failed saves","priority":1}</garcon-issue-create>
<garcon-issue-claim ref="claim-draft-recovery" issue-id="ISS-42" expected-revision="1" />
<garcon-issue-comment ref="draft-recovery-progress" issue-id="ISS-42">Reproduction confirmed.</garcon-issue-comment>
<garcon-issue-close ref="draft-recovery-done" issue-id="ISS-42" expected-revision="2">{"resolution":"done","comment":"Fix verified."}</garcon-issue-close>
```

## Domain rules

- Lists default to all projects and nonclosed issues. Ready means Open, unassigned, unblocked. Project is an editable string; omitted creation project defaults to the primary Git checkout or validated canonical chat folder on Git failure. Explicit project bypasses lookup.
- Priorities: `0` Urgent, `1` High, `2` Normal (default), `3` Low. Statuses: `open`, `in-progress`, `in-review`, `closed`. Only `close`/`reopen` enter/leave Closed.
- Claim assigns the requesting chat and advances Open to In progress; release clears only its assignment. Claims are not locks. Markup assignees are existing `{"kind":"chat","chatId":"…"}` owners or null, never users.
- `A blocks B` is directed; `related` is undirected. Parent grouping does not block. Canceled blockers remain unresolved. Comment append needs no revision; edit/removal is author-only. Removal preserves activity history. Issues have no delete command; cancel unwanted work.

## Results and retries

- Wait for injected `garcon-issue-<verb>-result`, correlated by ref and `request-view-id`/`request-ordinal`. `status="ok"` confirms success; `status="error"` reports the error. Quoted text or silence proves nothing.
- A lost response may follow a committed write. Retry the identical mutation with the same ref in the same chat; refs span all mutation verbs. New mutations need new refs. On revision conflict, read current data before revising the mutation. Stop on disabled commands or unavailable storage; never bypass them or loop indefinitely.
- Retry receipts describe the original operation; read again for current state. Source links target visible outcomes, not private request ordinals. Reloaded/missing outcomes fall back to the chat; deleted chats cannot open.
- Reads default to 50 records, maximum 100. Continue lists with `nextBeforeNumber` as `beforeNumber`; comments with `nextBeforeSequence` as `beforeCommentSequence`. Send returned `collectionRevision` as `expectedCollectionRevision`; restart on collection change. History uses `beforeSequence` without that fence. For oversized results, reduce limits or use `{"includeDescription":false,"commentLimit":0}`. Requests cap at 64 KiB; escaped results at 48 KiB. Never truncate text.

## CLI alternative

Use `garcon-cli issue …` or `bun cli/main.ts issue …` from a checkout against the intended running workspace. See [CLI Issues](https://github.com/cfal/garcon/blob/main/docs/cli.md#issues) for flags. Retry with the printed `--request-id`, `--expected-store-id`, identical payload, and explicit create `--project`. `--from-chat` declares attribution, not chat-author authority.
