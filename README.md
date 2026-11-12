# Feature flow for Claude Code

Left alone, coding agents write PRs too big to review. With this flow, PRs
went from 1,000+ lines to a few hundred, and I ship more.

**What it is:** a `.claude/` setup you copy into a Rails app. A person
writes a GitHub issue and types a few commands. A coordinator session, a
`builder` agent and a read-only `reviewer` agent take it to a draft PR in
small, reviewed slices. A Ruby hook refuses anything off the flow, from
editing before a flow starts to merging. It comes from a production Rails
app, with the product details removed.

**Try it:**

- **Read a run (2 minutes):** [an example issue](examples/issue.md), then
  [the hook's real replies while it is built](examples/hook-run.md).
- **Run the hook yourself** (Ruby 3.2+ and git, no gems to install). Clone this repo,
  then from its root:

  ```bash
  ruby examples/hook_run.rb
  ```

  ```bash
  ruby .claude/hooks/flow_gate_test.rb
  ```

- **Use it in your app:** [seven steps](#use-it-in-your-rails-app).

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

## Limits

Short reports keep the maintainer's reading small. Code, inline code and
file paths don't count towards word limits.

| What | Limit |
|---|---|
| Blocking questions before the draft | 3, interaction first |
| Acceptance criteria per issue | At most 10: the reviewer refuses an 11th and asks the maintainer which part comes first. More than 5 is over the size budget (next row): simplify the issue, or split off a part that can ship alone as its own issue |
| Size budget per PR | About 400 changed lines of app and test code, or 5 acceptance criteria (row above), whichever comes first |
| Builder's report | 150 words, at most five "Done" bullets |
| Reviewer's report | 200 words, at most five findings, a three-line reply to the builder |
| Other agent summaries | 200 words |
| A message to the maintainer | 100 words: what's blocked or decided, then numbered one-line questions, each with a recommendation |
| "Fix first" rounds | 2, then stop and ask |

Going over the size budget blocks nothing. The coordinator simplifies until
the change fits, or splits the extra part into a new issue, and tells the
maintainer which it chose.

## When the maintainer is called in

Otherwise agents state their recommendation and carry on. They stop and ask
the maintainer when:

- the issue conflicts with an ADR, or there's a real design choice;
- a block names no way forward, including a failed hook or protected files
  that differ from `main`;
- the reviewer returns `needs the maintainer`: more than 10 criteria, an
  interaction that doesn't say what the user sees during it, a block the
  builder worked around, or a decision or gap the issue doesn't settle;
- two "fix first" rounds haven't reached "ready";
- a review finding offers a choice, such as whether a constraint becomes a
  criterion or is cut;
- a builder proposes a change to a skill or rule.

The maintainer also acts at fixed points: `start feature` or `start fix`,
`approve spec` when a migration or ADR changes, trying the draft and typing
`approve draft`, triaging `ai-agent` issues, and merging. If
`SLACK_WEBHOOK_URL` is set, the Stop hook posts to Slack whenever Claude is
waiting for a reply.

## What the hooks enforce

`.claude/hooks/flow_gate.rb` is wired up in `.claude/settings.json`. It runs in
cloud sessions (Claude Code on the web) and keeps per-branch state in a
git-ignored ledger.

Locally it does nothing. The hook exits at once unless `CLAUDE_CODE_REMOTE`
is `true`, which Claude Code sets only in cloud sessions, and the
protected-files check in `settings.json` is skipped too. So a local session
gets no status line, keeps no ledger, refuses nothing, and treats the typed
commands as ordinary text. `CLAUDE.md`, the skills and the agents still
guide Claude, and the `bin/rails db:*` commands that wipe data still ask
first.

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

## Use it in your Rails app

1. Copy `.claude/` and `CLAUDE.md` into your app's root, and add this
   repo's `.gitignore` line. With this repo cloned next to your app, from
   your app's root:

   ```bash
   cp -R ../claude-feature-flow/.claude ../claude-feature-flow/CLAUDE.md .
   ```

   ```bash
   cat ../claude-feature-flow/.gitignore >> .gitignore
   ```

   If your app already has a `CLAUDE.md` or `.claude/settings.json`, merge
   them by hand instead of overwriting.
2. Edit `.claude/flow/config.json`: your protected branches, the paths
   agents never write, your deploy commands, and the paths that wait for
   `approve spec`.
3. Fit the skills to your app. The `testing` skill names test helpers
   (`sign_in_as`, `assert_notice`) and CSS frameworks (daisyUI, Tailwind);
   swap in yours. Add standing instructions under "Maintainer's notes" in
   `CLAUDE.md`.
4. Run `ruby .claude/hooks/flow_gate_test.rb`.
5. Commit and push to `main`. While `.claude/`, `.github/` or `CLAUDE.md`
   differ from `origin/main`, the hooks block every prompt and every file,
   shell, agent and GitHub tool call, so the setup has to be on `main`
   before a session starts.
6. On GitHub, protect `main` (require a pull request and a review), and
   create an `ai-agent` label.
7. Write an issue to the `spec-writing` skill
   ([example](examples/issue.md)), open a cloud session on the repo, and
   type `start feature #<issue>`.

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
    examples/issue.md               an example issue
    examples/hook-run.md            the gate's real replies while it is built
    examples/hook_run.rb            the script that produces hook-run.md
    LICENSE                         MIT

Run the hook tests (Ruby 3.2+, no gems to install):

    ruby .claude/hooks/flow_gate_test.rb
