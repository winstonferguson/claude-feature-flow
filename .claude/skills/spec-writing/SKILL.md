---
name: spec-writing
description: How to write a feature spec, which is the feature's GitHub issue — at most three blocking questions, acceptance criteria, out of scope and open questions, answers written back into the issue. Use whenever the user starts a new feature, asks to spec, scope or plan a change, says "/spec", or asks for new behaviour that has no spec yet, even if they don't say "spec". Not for bug fixes, refactors or restyles.
---

# Feature specs

A spec fixes what a change should do. It is the feature's GitHub issue, and
the contract for the rest of the build: rule tests are written from it (the
`testing` skill's "Tests from a spec"), and reviewers check the diff against
it. It changes as the maintainer tries the draft PR (the `feature-flow`
skill). A spec says what and why, never how.

## When a change needs one

A change gets a spec when it adds behaviour a user sees, changes who can do
something, changes the shape of stored data, or has questions worth settling
before coding. The spec covers what the stored data must allow; the
architecture check against the ADRs in `docs/architecture/` decides its shape
before the draft.

It doesn't for:
- **bug fixes**: two or three criteria in the request and a failing test that reproduces the bug are enough;
- **refactors** with no change in behaviour;
- **copy and styling** changes.

If it's unclear, ask the user rather than writing one by default.

## Questions first

Work read-only. Read the issue and the codebase so the questions are informed
(similar features, existing rules, how refusals look elsewhere), but don't
propose an implementation.

- **At most three blocking questions**, interaction first: what the user sees while they act, not only after saving. Anything else is decided by trying the draft.
- **Ask what users need before what it costs.**
- **Ask about behaviour, not structure:** who can do it, what they see, what happens when it fails, and the edges: empty, duplicate, too large, expired, another user's record.
- **Offer a recommended answer** where the codebase suggests one ("Other uploads show the limit in the error. Same here?"), so the user can just say yes.
- **Ask about order** where a step can fail: a check that might reject the work belongs before the work it would waste.
- **Ask what's out of scope.** Name the things a reasonable person might assume are included and ask whether they are.
- **No implementation talk:** no models, columns, classes, callbacks or gems. If the user raises one, it goes under "Constraints" only if it's a real constraint ("must reuse the existing upload flow"); otherwise it's the builder's to decide.

After a split or any change of scope, ask again: removing or adding a piece
creates new edges.

## The issue

One issue, one PR. **At most 10 acceptance criteria**: an 11th, or groups
that could ship on their own, means split the issue; ask the user which part
comes first. Past about 5 criteria, review the spec: simplify it, or split
off a part that can ship alone as its own issue. Agents may create that
issue, labelled `ai-agent` and linked to this one, for the maintainer to
triage. There is no word limit; mockups and open questions are free.

The maintainer writes the issue from this template. The coordinator writes
answers and changes back into it with the GitHub `issue_write` tool:

```markdown
# <Feature name>

## Why
One or two sentences: who this is for and what it lets them do.

## Terms
- <Term the criteria use>: <what it means, in one line>

## Acceptance criteria
1. <Who> <does what> → <what they observe>

## Out of scope
- <What this change does not do>

## Constraints
- <Only real ones: must reuse X, must not change Y. Each names the criterion it protects; cut one that names none. Each one copied from an ADR or issue is checked against the code today; drop it only if the current code or another criterion already enforces what it protects, or it no longer applies. Don't copy an ADR's structure (tables, slots, versions) into a spec: the build decides shape from the criteria>

## Open questions
- <Anything the user hasn't decided>
```

Why stays at one or two sentences. Anything else that seems to belong there
is either a term or a criterion.

Terms is optional: one line for each word the criteria depend on that a
reader couldn't define the same way unaided. Definitions only. Anything
someone can observe is a criterion, not a term.

### Acceptance criteria

Each criterion becomes one test, named after it, so each must be testable from
outside the code:

- **Observable:** a response, a page, a record created or not, an email, a job, or a result a service or job produces when there’s no request. If no test could check it from outside the code, it’s either an implementation detail or too vague.
- **One behaviour each.** "Uploads and shows a preview" is two criteria.
- **One rule, one criterion.** A behaviour is not a case. When several criteria apply the same rule to different inputs ("an invoice due last week is overdue", "an invoice due yesterday is overdue", "an invoice due today is not overdue"), define the rule's terms once in "Terms" and write one criterion that states it. The cases go in the test plan, not the spec. Before posting, read the criteria together and merge any that differ only in their example.
- **Concrete:** "after 7 days", not "after a while"; the message the user sees, not "an error".
- **Refusals included:** signed out, another user's record, invalid input. Specs that only describe the happy path produce code that only handles the happy path. If records have no owner yet, say who can see them instead of leaving it out.
- **Refusals say where the user goes:** "is sent to the current step", not "is not reachable".
- **New controls reuse the page's patterns.** A criterion that adds a control to a page (sort, filter, select, toggle) names the existing pattern on that page that provides it, or says why none fits.
- **Screens the user has to understand** (several decisions on one form, a review step, progress) **need an approved mockup in the spec.** Criteria say what each control does; the mockup says what the user understands.
- **Every block has a way out.** If a state refuses something (a pending draft blocks uploads), name how the user leaves that state, or someone gets stuck.
- **Checked against each other and existing rules.** Two choices that can conflict need a criterion for which wins. A new state meets old rules: does a duplicate check count a failed upload? Can a discarded name be reused?
- **No implementation words:** no class names, columns, callbacks or gems.

For example:
- Too vague: "Uploads should be validated."
- Implementation: "Add a size validation to `Attachment`."
- Good: "Signed-in user uploads a file over the size limit → sees an error that names the limit; no attachment is created."

### Out of scope

This list is what stops the build growing. Reviewers flag anything in the diff
that it names. A short spec with a good out-of-scope list beats a long one
without.

## Done

- **The blocking questions are answered** and the answers are in the issue. Then the draft starts.
- **With a migration or ADR change, done is `approve spec`:** the proposed data shape is in the issue and the maintainer has typed it.
- **A review finding that offers a choice goes to the user.** If a review says a constraint or criterion must "become a criterion, or be cut", ask which, with a recommendation (usually cut). Don't pick.

## During and after the build

- **The issue changes first.** The maintainer's feedback on the draft, or a criterion the build shows is wrong, goes into the issue before the code or a rule test changes.
- **Copy the acceptance criteria into the PR description.**
- **Code and tests never cite the issue.** No issue or criterion number: a comment states the rule itself and a test is named after the behaviour. Move any out-of-scope item that is a real follow-up into `docs/backlog.md`.
