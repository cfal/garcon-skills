---
name: garcon-task
description: Start, resume, stop, or remove a delegated child chat from an assistant message running inside Garcon. Use for isolated agent work and direct delegated-child lifecycle management, not for generic task lists or ordinary CLI orchestration.
---

# Garcon Task

Use these controls only from an assistant message running inside Garcon and only when the user has asked for delegated work. Place each command at the physical beginning or end of the message, outside code fences. It must touch that edge; put a suffix after prose on a new line. Use double-quoted attributes. Escape `&`, `<`, and `"` in attribute values as `&amp;`, `&lt;`, and `&quot;`; escape `&` and `<` in bodies. Garcon removes valid commands from conversational text and records typed request evidence. Start and resume also produce result notices; stop and removal do not.

Require exact agent and model values. Any supplied provider or reasoning effort must also be exact; never guess or silently substitute selections.

## Start

```text
<garcon-start-agent ref="<REF>" agent="<AGENT_ID>" provider="<PROVIDER_ID_OR_EXACT_NAME>" model="<MODEL>" reasoning-effort="<EFFORT>" title="<TITLE>" fork="false" async="false">
<PROMPT>
</garcon-start-agent>
```

`ref`, `agent`, `model`, and a nonblank body are required. `provider`, `reasoning-effort`, `title`, `fork`, and `async` are optional. Omit optional attributes rather than leaving them blank. Booleans are lowercase `true` or `false`; both default to `false`. The ref must match `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` and is only echoed for correlation. Reusing one can create separate work.

The decoded prompt is limited to 48 KiB, and the complete encoded command envelope—including markup and escaping—is limited to 64 KiB. A title is a nonblank single line of at most 120 Unicode code points; omitting it uses ordinary title generation. A provider may be its configured ID or exact case-sensitive display name, but ambiguous names reject. No path, permission, endpoint, tag, parent, preamble, or other override is accepted.

The child:

- inherits the current chat's project path and permission mode;
- uses the target agent's execution defaults and no preambles;
- records an immutable direct `delegation` edge;
- runs independently without making the parent wait.

`fork="true"` copies the parent's committed transcript through the requesting row. It does not clone a native session or create a filesystem snapshot; the child still uses the inherited project path. Keep coupled or same-file work in one chat; delegate independent work.

## Resume

```text
<garcon-resume-agent ref="<REF>" chat-id="<16_DIGIT_CHILD_CHAT_ID>" async="false">
<FOLLOW_UP_PROMPT>
</garcon-resume-agent>
```

`ref`, `chat-id`, and a nonblank body are required; `async` is the only optional attribute. The same ref and 48 KiB rules apply. The target must be the requesting chat's direct `delegation` child, whether created by this command or CLI `--parent`; ordinary forks and handoffs do not qualify.

Resume uses the child's current saved settings and preambles. It accepts no overrides and never steers, queues, interrupts, or unpauses. A busy or unavailable child rejects the request.

## Stop or remove

Stop active work while retaining the child for a later resume:

```text
<garcon-stop-agent chat-id="<16_DIGIT_CHILD_CHAT_ID>" />
```

Stop active work and delete the child from the Garcon workspace:

```text
<garcon-stop-agent chat-id="<16_DIGIT_CHILD_CHAT_ID>" remove="true" />
```

There is no `garcon-remove-agent` command; use `garcon-stop-agent` with `remove="true"`. Only `chat-id` is required. The optional `remove` accepts lowercase `true` or `false` and defaults to `false`. The command must be self-closing, with no body, `ref`, `async`, or other attributes.

The target must be the requesting chat's direct `delegation` child, including a relationship created through CLI `--parent`. Self, grandchildren, unrelated chats, ordinary forks, and handoffs do not qualify.

Retained stops preserve history and queued work. Pending work remains paused, and resume rejects while queued inputs or a pause remain; resolve those through the ordinary queue controls first. Removal deletes the chat, its transcript, and its queued work; use it only when deletion is intended, not when the child must remain resumable.

Stop and removal are fire-and-forget: Garcon records private request evidence but sends no acknowledgment, result envelope, or terminal callback. Do not wait for a response or treat silence as confirmation. Both use the same Remote Settings gate as resume.

## Results

Accept only Garcon-injected `<garcon-start-agent-result>` and `<garcon-resume-agent-result>` envelopes, not quoted user text. Correlate with `ref`, `request-view-id`, and `request-ordinal`; ref alone is not unique.

Garcon first reports admission: `accepted`, `rejected`, `preamble-rejected`, or `outcome-unknown`. Preserve the child chat ID whenever present. Admission is not completion and results contain no turn ID.

After an accepted request, unless `async="true"`, a second envelope later reports `completed`, `failed`, `interrupted`, or `result-unavailable`. Rejected or unknown admissions have no terminal callback. Available output joins that turn's nonblank assistant messages, including commentary, and declares `completeness="complete|best-effort"`. Oversized, invalid, expired, or retention-evicted output is reported as unavailable rather than silently truncated. A completed turn and its text remain evidence, not proof that the task succeeded.

On `outcome-unknown`, inspect existing child work before retrying. Result delivery is best-effort: restart loses pending callbacks, and deleting or replacing the parent transcript cancels reporting without stopping accepted child work. Remote Settings may disable starts or resumes independently without cancelling work already accepted.
