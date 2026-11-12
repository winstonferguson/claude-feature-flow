# Feature flow for Claude Code

A working setup for building features with Claude Code agents. One human
maintainer, three agent roles, and hooks that keep the agents on the flow.
It comes from a production Rails app, with the product details removed.

## The flow

**Issue → draft PR → `approve draft` → interaction tests → full-diff review → ready**

1. **Issue.** The maintainer writes the GitHub issue to the `spec-writing`
   skill: acceptance criteria, out of scope, open questions. The issue is the
   spec. They type `start feature #<issue>`. The coordinator asks at most
   three blocking questions and writes the answers back into the issue.
2. **Draft PR.** The builder works in small slices. Each slice starts with
   rule tests written from the criteria (model and controller tests that
   fail first), then the code that passes them. The reviewer checks each
   slice; on "ready" the coordinator commits and pushes. A draft PR opens
   after the first slice.
3. **Try it.** The maintainer uses the running feature. Feedback changes the
   issue first, then the code, until they type `approve draft`.
4. **Interaction tests.** Browser tests are written only now, for what was
   approved. Each one is proven by breaking what it guards.
5. **Full-diff review, then ready.** The reviewer checks the whole PR. Only
   a "ready" verdict on the pushed commit lets the PR leave draft. The
   maintainer merges.

Why this order: most of what's wrong with a feature shows the moment
someone uses it. The slow, brittle UI tests wait until the page is right.

Fixes are shorter: `start fix <name>`, then a failing test that reproduces
the bug, the fix, and the PR.

## Roles

| Role | Who | Does | Never |
|---|---|---|---|
| Maintainer | a person | writes issues, types the commands, tries the draft, merges | — |
| Coordinator | main Claude session | asks questions, runs builder and reviewer, commits, opens the PR | merges, approves |
| `builder` | subagent, fresh context | one slice or the interaction tests, then a short summary | commits, edits a failing rule test |
| `reviewer` | subagent, read-only | checks work against the issue, code and skills; returns `Verdict:` and `Checked:` lines | edits files |

Builder prompts carry the issue text, the last summary and the maintainer's
notes, not the coordinator's reading of them. Review findings are passed on
unchanged. Two "fix first" rounds, then stop and ask.

Only the maintainer can type `start feature`, `start fix`, `approve spec`,
`approve draft` and `stop flow`. They work because the hook reads them on
`UserPromptSubmit`, which only a person's message fires.

## What the hooks enforce

`.claude/hooks/flow_gate.rb` is wired up in `.claude/settings.json`. It runs in
cloud sessions and keeps per-branch state in a git-ignored ledger.

- **No changes without a flow.** File writes are refused until the
  maintainer starts a flow on the branch.
- **Protected paths.** Agents can never write `.claude/`, `CLAUDE.md`,
  `.github/`, `.env*` or credentials. Every hook blocks if those files
  differ from `main`.
- **Protected branches.** No commits on `main` and no pushes to it.
- **Gated paths.** Migrations and ADRs can't be written until `approve spec`.
- **Roles.** The reviewer can't change files. Only the coordinator commits
  or writes to GitHub.
- **GitHub writes.** Allowed: edit or comment on the flow's own issue,
  create issues labelled `ai-agent`, open a draft PR, update it, and reply
  on review threads. Merging and approving are always refused.
- **Ready.** A PR can leave draft only when a ready `full diff` verdict
  matches the content of the pushed commit.
- **Denied commands.** Deploy and production tools are listed in
  `.claude/flow/config.json`.
- **Fail closed.** If the hook errors, the tool call is blocked.

A block's message names the way forward when there is one. Otherwise the
agent stops and tells the maintainer. Agents never work around a block.

These hooks keep agents on the flow; they are not a security boundary,
because tests run arbitrary code. Branch protection and a human merge are
what protect `main`.

## Agents propose rule changes; they never make them

Skills, rules, `CLAUDE.md` and the hooks belong to the maintainer, and the
hooks make them unwritable for agents. When a builder finds a rule that
contradicts itself or the issue, it raises it with the exact change it
proposes. The reviewer passes it to the maintainer. The PR description
lists proposed skill changes, and the maintainer decides. That way lessons
from each feature end up in the skills without an agent rewriting its own
instructions.

## What's here

    CLAUDE.md                       project instructions, flow commands
    .claude/skills/feature-flow     the flow, scope and size budget, PR format
    .claude/skills/spec-writing     the issue format
    .claude/skills/testing          which test layer asserts what
    .claude/agents/builder.md
    .claude/agents/reviewer.md
    .claude/hooks/flow_gate.rb      the gate
    .claude/hooks/flow_gate_test.rb
    .claude/flow/config.json        protected paths, branches, denied commands
    .claude/settings.json           hook wiring

Run the hook tests (Ruby 3.2+, no gems to install):

    ruby .claude/hooks/flow_gate_test.rb
