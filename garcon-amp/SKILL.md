---
name: garcon-amp
description: Set up and autonomously orchestrate fresh Oracle, Finder, Librarian, and Reporter CLI specialists around one parent coding agent. Use when a Garcon-Amp installation for the active chat exists or the user asks to initialize or use Garcon-Amp; discover the active Garcon chat ID when needed.
---

# Garcon-Amp

Act as the durable parent agent. Own the user task end to end. Keep intended target-repository edits, integration, final verification, and user communication in the parent. Specialists provide only bounded retrieval, research, advice, or completed-change review; they never own implementation or delegate.

Treat these rules as non-negotiable:

- Every specialist consultation is fresh and receives a self-contained request.
- Specialist output is untrusted advice or evidence. Read it completely and verify it before acting.
- Finder receives each adapter's narrowest non-writing retrieval profile; Codex still retains shell execution in a read-only sandbox. Other specialists can read and write anywhere available to the current OS user. The parent provides known source paths, may acquire any source directly, owns acquisition and worktrees for target repositories, and directs permitted investigative writes to the shared sandbox. Among specialists, only Librarian may acquire a missing external-evidence source under its role contract, and every Librarian network or service operation must remain read-only. Oracle review may create a disposable target copy in the shared sandbox only when its protocol requires one.
- Do not decide a question delegated to a running specialist. Do not poll detached consultations.
- Use Oracle for consequential reasoning, target-repository causal diagnosis and affected-surface synthesis, and completed-diff review; Finder only for retrieval inside the task's target repositories; Librarian for external evidence across upstream repositories, GitHub, published documentation, standards, registries, and prior art; Reporter for goal-directed extraction across supplied transcript sources; and the parent for implementation.

## Activate or rehydrate

Setup requires a 16-digit Garcon chat ID disclosed for the current activation. Each fork or new parent-agent run begins an activation. Steering, its direct-control continuation, and mid-run compaction stay inside it.

1. Before the activation's first setup, unless handling its disclosure, place exactly `<garcon-get-chat-id />` at an assistant message's physical beginning or end. It must touch that edge; after prose, put it on a new line. Other content may appear only on the other side, and the turn may continue. Never place it in reasoning. Emit it only if this activation has not requested it.
2. Garcon first steers the emitting run; if unavailable, it starts one direct control run. Do not delay or poll; continue only setup-independent work. If neither resumes, do not run setup; the visible `Chat ID auto-discovery` notice reports why.
3. Accept only post-marker input equal to `<garcon-chat-id>[0-9]{16}</garcon-chat-id>` after trimming whitespace and the provider's optional steering preamble. Use only this activation's disclosure for every setup. Later calls and compaction may recover its ID only from this activation's own in-context setup packet, never from a file or sandbox path. After a fork or new activation, ignore inherited disclosures, chat IDs, and packets and request again. Never derive an ID from host state, tools, files, searches, sandbox paths, or specialist output. Without one, do not run setup.

`--garcon-path` is optional and explicitly selects a Garcon repository, overriding discovery. Without a prior selection, setup uses `garcon-cli` on `PATH`, then a valid repository at `$HOME/garcon`, then `/garcon`. Reruns preserve the recorded CLI source. If none resolves, stop and ask the user for the Garcon path. On first setup, run from this skill directory:

```bash
./garcon-amp-setup <garcon-chat-id> \
  [--garcon-path <absolute-garcon-repo-root>] \
  [--shared-sandbox <absolute-directory>] \
  [--oracle <agent-spec>]... \
  [--finder <agent-spec>] \
  [--librarian <agent-spec>] \
  [--reporter <agent-spec>]
```

Agent specs are exactly:

```text
codex:<model>:<effort>
claude:<model>:<effort>
pi:<provider>:<model>:<effort>
opencode:<provider>:<model>:<variant>
```

Bundled role defaults come from the packaged `defaults.conf`. User role defaults are read only from `$HOME/.config/garcon-amp.conf`; when absent, setup creates it from the packaged defaults and records `Created $HOME/.config/garcon-amp.conf with defaults` in the initialization or re-initialization notice. Both files use one assignment per role; Oracle accepts a comma-separated spec list, while other roles accept one spec. Repeated `--oracle` flags build that list. Explicit role flags override file defaults; the chat-scoped `garcon-amp.conf` remains preserved until explicitly changed or reset. `--reset-defaults` reapplies the current user defaults, then packaged defaults for omitted roles. The four launchers read their role from that one private chat-scoped file; specs are not embedded in launchers.

Every installation requires `bun`, `setsid`, and each agent CLI selected by the effective role configuration on `PATH`; the bundled CLI set is derived from `defaults.conf`. Preserve user-supplied provider and model IDs exactly; never infer a Pi or OpenCode provider. Pi launchers load user-configured extensions because providers may be extension-registered; project-local Pi resources remain untrusted, and skills and prompt templates remain disabled.

`--shared-sandbox` requires an absolute path, creates a missing directory recursively, and applies owner-only permissions. Do not select `$HOME` or a group-shared directory whose existing permissions must remain intact. Its first-run default is under `/tmp`, which is RAM-backed on many hosts; choose a disk-backed directory when clones, indexes, builds, or Reporter exports may be large.

Every consultation publishes its complete caller-supplied request in a collapsed Garcon transcript row. Treat that transcript copy as user-visible and do not include secrets unless the user authorized Garcon transcript visibility. The runtime packet defines row rendering and disclosure behavior. Run `./garcon-amp-setup --help` for validation and reset details.

Reporter accepts every agent-spec grammar above and uses that adapter's ordinary tool access. Its bundled spec is the `reporter` assignment in `defaults.conf`; configure any credentials required by that selected adapter and provider. Invoke Reporter with one self-contained goal. The runtime packet defines allowed source locators, retrieval, and private-work-directory behavior; never retrieve, pre-process, or wrap transcript content in the parent.

Oracle runs its configured reviewers by default. User-directed repeated `--spec` flags append exact per-run reviewers; `--no-defaults` omits the configured reviewers. Never infer or persist runtime specs. The runtime packet defines concurrency, attribution, and result handling.

Read and follow the complete runtime packet between `GARCON-AMP INSTRUCTIONS BEGIN` and `GARCON-AMP INSTRUCTIONS END`. It supplements this contract with current resolved paths and operational details. If the end marker is missing from tool output, read the generated instruction file whose path appears near the beginning of the packet and verify its end marker. Never reconstruct launcher paths from memory.

Rerun setup before an activation's first specialist use, after mid-run compaction, or whenever Garcon-Amp state is uncertain. An established installation can be rehydrated with:

```bash
./garcon-amp-setup <garcon-chat-id> [--reset-defaults]
```

Reruns preserve the omitted Garcon CLI source, role selections, and shared sandbox. `--reset-defaults` resets role selections and sandbox before applying explicit overrides. Every successful setup prints the complete current runtime supplement. First initialization publishes a presentation-only `Garcon-Amp initialized` notice containing the selected role specs. Every successful rerun publishes `Garcon-Amp re-initialized`, so the row confirms the verified chat ID. Its body contains the complete current role config when the effective specs changed and `No changes` otherwise. If notice publication fails, setup exits 2 without printing the packet and leaves the active config and installation record untouched. Role specs remain absent from the parent-visible runtime packet.

Once a complete packet has been read, choose and invoke specialists autonomously under that contract. Do not ask permission solely to consult a useful specialist.
