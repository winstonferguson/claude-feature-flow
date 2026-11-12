---
name: feature-flow
description: How this repo takes a feature from GitHub issue to merged PR — questions, a draft PR the maintainer tries, interaction tests, then ready. Use when starting a feature or any change with behaviour a user sees, slicing work, deciding what comes next, reporting on a slice, or preparing and reviewing a PR, even if the user only says "let's build X" or "what's next".
---

# Feature flow

Most of what's wrong with a feature shows the moment the maintainer uses it.
So the flow gets a working draft PR in front of them fast, and writes the
slow, brittle tests only once they have said the page is right.

**Issue → draft PR → `approve draft` → interaction tests → ready.**

Specs follow `spec-writing`, tests `testing`, pages the repo's UI conventions;
agents are in `.claude/agents/`. Hooks (`.claude/hooks/flow_gate.rb`) enforce
the safety checks in cloud sessions.

## 1. Issue

- The maintainer writes the GitHub issue in the spec format and starts the flow with `start feature #<issue>`. A name before the number is optional, typed any way; the hook makes it branch-safe. The issue is the spec; nothing goes in `docs/specs/`.
- The coordinator reads the issue and the code and asks at most three blocking questions, interaction first. It writes the answers into the issue with the GitHub `issue_write` tool.
- **`approve spec` only when the change adds a migration or changes an ADR.** Then the coordinator runs the architecture check against the ADRs in `docs/architecture/`, puts the proposed data shape in the issue, and waits. Hooks refuse writes to `db/migrate/` and `docs/architecture/` until the maintainer types it. Otherwise it goes straight to the draft.
- **Check the criteria against real data** before the draft (and before `approve spec` when it's needed): for each criterion, show what it gives on one or two real records (e.g. "the oldest project would show: 3 open comments, 1 overdue invoice").

## 2. Draft PR

- The builder builds in small slices. **Each slice includes its rule tests:** model and controller tests for what the issue says is saved, refused (with which message), allowed and kept after a reload. They are written from the issue's criteria before the code that passes them, and must fail first for the missing behaviour. No new browser tests yet.
- The reviewer checks each slice against the issue, for safety and scope, and against the repo's rules. On ready, commit and push. After the first slice, open a **draft PR**.
- When the feature works end to end, the coordinator runs the app and shows the maintainer each state of the page (idle, mid-action, empty, error), as screenshots or the running page.

## 3. Try and change

- The maintainer's feedback changes the issue first (the coordinator edits it), then the draft. Repeat until the maintainer types `approve draft`.

## 4. Interaction tests

- The builder writes browser tests for what the maintainer approved, such as dragging, previews, layout and focus, each proven by breaking what it guards. Fixes they find are made here, with the same slice review.

## 5. Ready

- A full-diff review, then mark the PR ready. Hooks refuse that until a ready `full diff` verdict covers the pushed commit. The description is written into the PR. Agents don't merge or approve.

## Roles

- One coordinator session runs the feature. The `builder` builds; the `reviewer` checks each slice (`Checked: slice`), the interaction tests (`Checked: interaction`) and the whole PR (`Checked: full diff`). Findings are passed on unchanged.
- "Fix first": rerun the builder with the reviewer's reply, stopping after two rounds. "Needs the maintainer": stop and ask.
- Builder prompts carry the issue text, the previous summary and the maintainer's notes, not the coordinator's reading of them.

## Scope

- At most 10 acceptance criteria per issue; the reviewer refuses more and asks the maintainer which part comes first. Each criterion is one behaviour.
- Out of scope is binding: reviewers flag anything in the diff that it names.
- **Size budget:** about 400 changed lines of app and test code (vendored files excluded), or 5 criteria. Going over doesn't block anything; it means stop and review. The coordinator either simplifies until the change fits, or splits the extra part into a new issue linked from this one, and tells the maintainer which it chose and why. The PR description says so.
- **New behaviour gets a new issue.** If feedback or a review adds behaviour the issue doesn't name, the coordinator recommends a new issue and estimates its size. Only fixes to an existing criterion stay in the PR.
- **Prep first.** Vendoring a library, moving code out of a spike and amending an ADR each go in their own small PR, merged before the feature.
- **Diagnostics go on their own branch** (`start fix`), never on the feature branch.
- **Agents may create issues** for split-off or follow-up work, labelled `ai-agent` and linked to the issue they came from. The maintainer triages them.

## Draft checklist

Before `approve draft`, the coordinator checks for:
- **existing data:** a migration or backfill for records already stored;
- **deletion:** attached files and dependent records go with the record;
- **concurrency:** every writer to a shared record takes the same lock in the same order, unless the issue accepts last save wins;
- **older tests the change contradicts;**
- **docs, ADRs and glossary entries** that will now say something false.

## PR and review

- **Description:** the issue's criteria, the decisions made, an "Also in this PR" list, what reviewers can ignore, declined review findings with reasons, blocks hit, known issues, and proposed skill changes. Known issues outside the feature go in `docs/backlog.md` with evidence.
- **Review findings:** fix real issues, one commit each; answer the rest on their threads with one line each. Don't rewrite history while a review is open.
- **Skill and rule changes** are proposed in the PR description, never made by agents.

## Fixes

`start fix <name>` or `start fix #<issue>`: a failing test that reproduces the bug, then the fix, then the PR.

## Messages to the maintainer

100 words at most: what's blocked or decided, then numbered questions, one line each, each with a recommendation. Summaries from agents stay under 200 words.
