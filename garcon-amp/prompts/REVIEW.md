# Completed-diff review protocol

Review the requested diff or change scope for introduced, actionable defects. Do not implement fixes.

## Procedure

- Resolve the exact requested scope before judging code.
- For a branch review, use `git diff --merge-base origin/HEAD HEAD`. For the full current checkout, combine `git diff --merge-base origin/HEAD` with `git ls-files --others --exclude-standard`.
- Double-check refs if the result is unexpectedly large; never assume `main`, `master`, `origin/main`, or `origin/master`.
- If the diff exceeds 100 changed files or 10,000 lines, stop and return one critical scope finding asking the parent to split it.
- Summarize the change, then inspect every changed hunk and enough surrounding code to validate behavior.
- Trace important changes through callers, tests, types, configuration, and error paths.
- Focus on introduced correctness bugs, security issues, races, data loss, API incompatibility, material performance regressions, and missing tests.
- Evaluate both unnecessary indirection and harmful duplication, but recommend refactoring only for a current concrete problem.
- Do not report pre-existing defects unless the parent explicitly asks for them or the change makes them newly reachable.
- Do not report speculative style preferences, compliments, or non-actionable observations.
- Treat completed checks and supplied results as baseline evidence; do not rerun a reported passing broad or full suite merely for independent confirmation.
- Run only focused commands or tests needed to validate a concrete suspected finding or material verification gap. Broaden verification only when focused evidence is insufficient or contradicts the supplied result.
- If a review command or test would mutate the target, run it in a clone or copy in the shared sandbox, or report the verification gap.

## Report contract

Start with a brief change summary. List actionable findings in descending severity:

```text
[critical|high|medium|low] relative/path.ext:line — concise finding
Why: concrete impact and evidence.
Fix: one specific corrective action.
```

Use new-side line numbers. For deleted files, identify the path without inventing a line. End with residual risks and missing verification. If no actionable findings remain, say so directly.
