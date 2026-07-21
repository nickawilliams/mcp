# Memory instructions — canonical client block

The graphiti MCP server (`graphiti.mcp.nickawilliams.com`) is long-term memory,
but connected ≠ used: MCP tools are inert unless standing instructions tell the
model to call them. This file is the **source of truth** for the instruction
block that makes clients use memory proactively. It is the interim (v1)
mitigation for ROADMAP entries **C1/C5**; a v2 MCP gateway would deliver the
same directive server-side.

Standing instructions are *guidance*, not a guarantee — models weight them
well but not perfectly. The block below is worded for reliable following
(concrete triggers, concrete tool names), not wishful "always."

## Division of labor (decided 2026-07-21)

**Layered.** graphiti is the **system of record** for durable memory —
cross-client, episodic, relational. Claude Code's built-in file memory is a
**hot cache**: only the tiny always-relevant layer (identity, active projects,
standing feedback), free to read because it rides in context. Duplicating a
hot-core fact into both is allowed and expected — the file is a cache, not a
second authority. Other clients have no file layer and use graphiti alone.

## The canonical block

Paste verbatim. Do not fork the text per client; per-client additions go
*after* the block (see placement guide).

```markdown
## Long-term memory (graphiti MCP)

The `graphiti` MCP server is persistent cross-session memory. Use it
proactively — don't wait for "remember this" or "recall X".

**Recall** — before answering, call `search_memory_facts` (relationships,
"what do I/we…") or `search_nodes` (entities) when the task plausibly has
history: it names a person, project, tool, or preference; builds on a past
decision; or continues ongoing work. Skip recall for self-contained tasks
(general knowledge, one-off code, math) — each search costs latency and an
embedding call.

**Persist** — when a durable fact emerges mid-conversation, call `add_memory`
with a short descriptive name and a 1–3 sentence episode stating who/what/when.
Durable: decisions and their rationale, preferences, people and relationships,
project state and milestones, stable facts. Not durable: transient task state,
scratch details, secrets/credentials, anything stale within a week. When new
information supersedes a stored fact, persist the update as a new episode —
the graph tracks validity over time.

**Namespace** — memory is grouped by `group_id`. Omit it so the server's
configured default applies; never pass an explicit `group_id` unless the
operator asks.
```

## Placement guide

| Client | Where the block goes |
| --- | --- |
| Claude Code | `~/.claude/CLAUDE.md` (global), + tweak below |
| Codex CLI | `~/.codex/AGENTS.md` (global; or per-repo `AGENTS.md`) |
| Cursor | Settings → Rules → User Rules (global, plain text) |
| Claude Desktop | Settings → Profile → custom instructions |

ChatGPT and claude.ai-web are out of scope: OAuth-only connectors, not wired
up (ROADMAP C4).

### Per-client tweak — Claude Code only

Claude Code also has built-in file memory (`MEMORY.md`, always in context).
Append this paragraph after the block there:

```markdown
Claude Code layering: built-in file memory is the hot cache (identity, active
projects, standing feedback — what every session needs in context); graphiti
is the system of record. Answer from in-context file memory first — it's free;
search graphiti when the answer isn't there or involves history/relationships.
Persist durable facts to graphiti; additionally mirror a fact into file memory
only if every future session needs it without a lookup.
```

## Maintenance

- Edit the block **here first**, then re-paste into each client surface listed
  above. Bounded fan-out (≤4 surfaces), stable text, so churn is low.
- If a personal/work `group_id` split lands (ROADMAP C2), the block already
  copes: clients inherit whatever default their endpoint/token pins, and the
  "never pass an explicit `group_id`" rule keeps sessions inside their lane.
