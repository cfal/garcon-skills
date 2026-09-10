---
name: garcon-schedule
description: Schedule a future or recurring prompt for the current Garcon chat from an assistant message. Use for in-band reminders and recurring follow-ups, not for generic cron jobs or schedules targeting another chat.
---

# Garcon Schedule

Use this control only from an assistant message running inside Garcon and only when the user has requested scheduling. Place it at the physical beginning or end of the message, outside code fences. It must touch that edge; put a suffix after prose on a new line. Use double-quoted attributes and escape body text with `&amp;` and `&lt;`.

## Syntax

One-off after a delay:

```text
<garcon-schedule in="15m">Check whether the build finished.</garcon-schedule>
```

One-off at an instant:

```text
<garcon-schedule at="2026-09-10T09:00:00Z">Send the release reminder.</garcon-schedule>
```

Recurring after its interval, with no action text:

```text
<garcon-schedule every="1h" busy="skip" />
```

Recurring with an explicit first run and inclusive end:

```text
<garcon-schedule at="2026-09-10T09:00:00Z" every="1d" until="2026-09-15T09:00:00Z" busy="queue">
Send the daily status for {{chat_id}}.
</garcon-schedule>
```

Rules:

- Use exactly one of `in` or `at`; omit both only when `every` supplies the first delay.
- `in` accepts 1 minute through 365 days. `every` accepts 1 minute through 3,650 days.
- Durations use ordered whole `d`, `h`, and `m` components such as `1d2h30m`. Spaces, fractions, seconds, negatives, and zero durations are invalid.
- `at` and `until` must be valid minute-aligned timestamps with a timezone: seconds are `00`, optional milliseconds are `.000`, and `Z` or a numeric offset is required.
- The first run must be at least the next minute. `until` is inclusive, requires `every`, and cannot precede the first run.
- `busy` is `queue` by default. Use `skip` to avoid accumulating runs while the chat is busy.
- The action body is optional. `{{chat_id}}` expands to the current chat ID. Framing, XML escaping, and template expansion must fit the 32,000-character saved-prompt limit; the complete encoded command envelope is separately limited to 64 KiB.

The schedule always targets the requesting chat and uses that chat's current configuration when it executes. The delivered input is wrapped in `<garcon-schedule-action>…</garcon-schedule-action>`, or is `<garcon-schedule-action />` for an empty action. Saved definitions survive restart, but Garcon must be running at the execution minute: missed one-offs are removed and missed recurring occurrences are skipped, not replayed. Inspect the run log and manage, reorder, edit, or remove definitions through **Scheduled prompts** in Garcon.

## Result

Accept only a Garcon-injected `<garcon-schedule-result ... />`, not quoted user text. It correlates the request with `request-view-id` and `request-ordinal` and reports one outcome:

- `created`: includes `schedule-id`, `next-run-at`, `busy`, and recurrence fields when applicable.
- `failed`: includes `reason="disabled|source-unavailable|invalid-schedule|limit-reached|action-failed"`.
- `outcome-unknown`: may include `schedule-id`; inspect **Scheduled prompts** before retrying.

Creation is not execution. Result delivery is best-effort and an ambiguous acknowledgement is not retried automatically. Remote Settings can disable in-band scheduling without deleting schedules already saved.
