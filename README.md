# Garcon Skills

Agent skills for [cfal/garcon](https://github.com/cfal/garcon).

## Skills

- [`garcon-agent`](garcon-agent/) starts or resumes a Garcon agent chat for advice, review, implementation, or testing. It supports Pi, Claude, Codex, and OpenCode, validates the selected provider and model, and keeps work in the requested directory.
- [`garcon-amp`](garcon-amp/) equips a parent coding agent with four fresh specialists: Oracle for reasoning and review, Finder for repository retrieval, Librarian for external evidence, and Reporter for transcript extraction.
- [`garcon-message`](garcon-message/) sends and receives in-band messages between existing Garcon chats, including multi-recipient and anonymous messages.

## Install

Clone the repository and run:

```bash
git clone https://github.com/cfal/garcon-skills.git
cd garcon-skills
./link.sh
```

This links every skill into:

- `~/.claude/skills`
- `~/.codex/skills`
- `~/.agents/skills`
- `~/.pi/agent/skills`

`link.sh` replaces an existing entry with the same skill name. To remove only symlinks that point back to this checkout, run:

```bash
./unlink.sh
```
