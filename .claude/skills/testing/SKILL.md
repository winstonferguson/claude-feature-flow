---
name: testing
description: Which test layer asserts what in this repo — model, service, job, mailer, lib, controller, helper, presenter, partial (view) and system tests — how to turn a spec's acceptance criteria into failing tests, how much to test, how to build test data, when to stub, and how to select elements. Use whenever you write, review, fix or move a test in test/, add assertions to an existing one, write tests from a spec before implementing, or decide where coverage for a change belongs, even if the user doesn't mention testing practice. Also use it when a test breaks after a restyle, or when someone asks whether a check belongs in a controller, view or system test.
---

# Testing

Each layer answers one question, and no logic is asserted in two layers. A
test should fail for one reason, so its name says what broke. Mixing layers
makes tests longer, harder to read and noisier when something unrelated
changes, which makes them less effective.

The logic is asserted in the layer that owns it. A caller's test runs the real
callee and checks only the caller's own outcome: the response, the redirect,
that a record now exists, that a job was enqueued (`assert_enqueued_with`). It
never re-asserts the callee's detailed results, and it never mocks the callee
just to prove it was called: that is stubbing an internal collaborator (see
"Stubbing").

## Layers

| Layer | Question it answers | Lives in |
|---|---|---|
| Model | Does the domain rule hold: validations, scopes, state changes, domain methods? | `test/models/` |
| Database constraint | Does the database refuse what validations would, even past Rails? | `test/models/database_constraints_test.rb` |
| Service | Given this input, is the result right? | `test/services/` |
| Job | Does the job run, skip, retry and report as it should? | `test/jobs/` |
| Mailer | Does the mail go to the right person, with the right subject and link? | `test/mailers/` |
| Lib and tasks | Given this input, is the output right? | `test/lib/` |
| Controller | Does this request give the right response and page content? | `test/controllers/` |
| Partial | Does this shared partial produce the design system's markup? | `test/views/` |
| Helper | Does this display decision return the right value? | `test/helpers/` |
| Presenter | Does this plain-Ruby view model return the right items and states? | `test/presenters/` |
| System | Does it work in a browser: JavaScript, layout, focus? | `test/system/` |

- **Model tests: domain behaviour.** These cover validations, normalisations, scopes, callbacks and domain methods (`archive!`, `change_password`), against the real database. Don't test Rails itself: that an association or enum is declared isn't behaviour. Test what it makes true.
- **Database constraint tests: what the schema enforces.** They write past validations (`update_columns`, `insert_all`), as bulk writes do, and assert the database raises. A migration that adds a check, foreign key or `NOT NULL` adds a test there.
- **Service tests: input to result.** Call the public entry point (`.call`, the result object) with real input, and assert the result and the records it wrote. Never test private methods: if one needs its own test, it's a separate object.
- **Job tests: the job's own contract.** That covers status transitions, skipping work already done, discarding a missing record, and reporting errors through `Rails.error`. What the job's services compute is asserted in their own tests. Enqueuing is asserted where it happens, with `assert_enqueued_with` in the caller's test. `perform_enqueued_jobs` with a block runs the jobs queued inside the block, including those queued by other jobs, but not jobs already queued when it starts. Without a block it runs only the jobs queued at the call: a job they queue needs a second call.
- **Mailer tests: the envelope and what the reader acts on.** That means subject, recipients and the link or token's shape. How the mail looks is checked in its preview (`test/mailers/previews/`), not asserted.
- **Lib and task tests: input to output.** Stub only the boundary (network, shell, filesystem outside the repo).
- **Controller tests: the request and its response.** They check status, redirect, flash, that the expected records changed (not their computed details, which belong to the model or service), and what the page says and offers:
  - text
  - links (`href`)
  - form fields (name, value, `required`)
  - accessible names (`aria-label`, `aria-current`)
  - the `data-*` hooks a Stimulus controller relies on

  Select by element, attribute, id or text, and scope with landmarks (`main`, `header`, `nav`, `section`). **Never select by a styling class**, daisyUI or Tailwind (`.btn-square`, `.badge-success`, `.max-w-3xl`): restyling must not fail a controller test.

  Pass attribute values to `assert_select` as substitutions, never inline: `assert_select "form[action=?][data-turbo-confirm=?]", path, "Discard this draft?"`. A `?` inside an inline quoted value is read as a placeholder and swapped for the next argument, so the selector silently asks for something else.

  Controller tests also own access:
  - **Ownership:** every action that loads a user's record by id has a test that another user's record is not found, so one user can never read or change another's data.
  - **Authentication:** each controller has one signed-out test (redirected to sign in), unless it allows unauthenticated access.
- **Partial tests: a shared partial's markup.** This is the one place classes are asserted, because a partial's job is producing the design system's markup. Every `app/views/shared/` partial has a test in `test/views/shared_partials_test.rb` (`ActionView::TestCase`), including that a missing required local raises. A partial rendered only by another (`shared/menu_list` inside `shared/menu`) is covered by that partial's test.
- **Helper and presenter tests: display decisions.** Helpers cover fallbacks and lookups such as `page_heading`, `page_width_class` and `upload_status_class`; presenters cover navigation items and their active and disabled states. Assert the returned value, not rendered HTML.
- **System tests: what only a browser shows.** That means JavaScript behaviour, layout and geometry, and focus. Find by role, label or text, and use a class only where the markup offers no other hook (daisyUI's `.tab-content`).
- **No page-level view tests.** A page's content is covered by its controller test, its behaviour by system tests, and its parts by partial tests. Rendering whole templates in `test/views/` would repeat the controller test at the markup level.

## Tests from a spec

A feature's spec is its GitHub issue (the `feature-flow` skill). Its tests
come in two passes:

1. **Rule tests, inside each draft slice, before the slice's code.** Model and controller tests for what the issue says is saved, refused (with which message), allowed and kept after a reload, written from the issue's criteria, not the code. Each goes in the test file of the model or controller it exercises, never one file per issue. Run them and confirm each fails for the right reason: missing route or behaviour, not a syntax, fixture or setup error. A rule that already holds gets a passing guard, proved by breaking what it guards (see "Proving a test").
2. **Browser tests only after `approve draft`,** for what the maintainer approved: JavaScript behaviour, previews, layout and focus. Each is proved by breaking what it guards. Before then, touch `test/system/` only to fix a test the change broke.
3. **Never edit a rule test to make it pass.** If one looks wrong, say which criterion and why; the issue decides, not the code. A rule test changes only when the issue's rule changes.
4. **Lower-layer tests come with the code**, in the layer where the logic lands (a calculation gets a service test). They don't repeat what the rule tests already check.

## How much to test

One test per behaviour. Cover what the spec or the change names, plus the real
edges: nil or blank input, boundary values, a permission refused. Don't add
cases nobody named, and don't write several tests that differ only in their
input when one shows the rule. Name tests by what breaks: "rejects an expired
invite", not "invite test 4".

## Test data

- **Fixtures for the shared world** (`test/fixtures/*.yml`, loaded with `fixtures :all`): the users and records most tests start from. Add a fixture when several tests need the same state, not for one test.
- **`create!` in the test for the record the test is about**, so the reader sees what matters without opening a YAML file.
- **Real files for parsing** (`test/fixtures/files/`): code that reads uploaded files is tested on real files, the smallest one that shows the case.
- **Time with `travel_to`.** Anything that depends on time (expiry, "recent", scheduled work) freezes or moves the clock. Never rely on the real clock: the test will fail at midnight, month-end or in another time zone.
- **No hard-coded ids or keys** that a fresh database could also give a record: take them from the record the test made or a fixture.
- **Changes, not totals.** Assert with `assert_difference` and `assert_no_difference`, not absolute counts, so adding a fixture doesn't break unrelated tests. The same goes for pages: assert that the expected rows are listed and the excluded ones aren't, not how many rows a list of every fixture has. Counting is fine where the test made the records or owns the record they belong to.

## Stubbing

Use the real code wherever it can run in a test. Stub (Mocha) only:
- **at a boundary the test can't or mustn't reach**: HTTP, external services, the shell, Open3;
- **to force a failure path** that real input can't produce, such as a collaborator raising so error reporting can be checked;
- **with `expects(...).never`** to prove something isn't called (the service isn't reached after a refused upload);
- **to prove a guarantee a test can't reproduce**, such as a row lock that only matters when two transactions race (`expects(:lock!).once`). Say why in a comment.

Never stub the object under test, and don't stub an internal collaborator to shape normal input or to prove it was called: build the input with a fixture or a fixture file, and assert the caller's own outcome. A stub that stands in for real behaviour keeps passing after that behaviour breaks.

## Shared setup

Setup used across files lives in one helper, never copied into each file's `setup`:
- `sign_in_as(user)` in `test/test_helpers/session_test_helper.rb` for controller tests, and in `ApplicationSystemTestCase` for system tests (through the form).
- `assert_notice(text)` checks a flash message by its `[role=alert]`.

`sign_in_test` signs in by hand, because signing in is what it tests.

## Running tests

- While working, run the one test: `bin/rails test test/models/invite_test.rb:42`.
- Then the file, then the whole suite with `bin/rails test` before handing the change back.
- System tests run separately with `bin/rails test:system`; run them when the change touches views, JavaScript or a system test.
- A system test that fails and then passes with no change is flaky: record it in `docs/backlog.md` with the date and what you saw (the failing step, the error, what made it pass). Don't retry, skip or quarantine it.

## Proving a test

A test written before the code is proved by its first run failing for the right reason (see "Tests from a spec").

To prove a test written after a fix catches the bug, undo the fix by editing the file, run the test and see it fail, then restore the file and run the test again to confirm it passes. Don't use `git stash` or other git writes for this.

A rule test that passes before any code is written hasn’t been proved yet. Leave it, and once the implementation is in, prove it like a test written after a fix: break the behaviour it guards, see it fail, then restore.
