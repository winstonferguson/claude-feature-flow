<!--
An example issue written to the spec-writing skill, for an invoicing app.
It is illustrative, not taken from a real project. hook-run.md shows the
gate's replies while this issue is built.
-->

# Overdue invoices

## Why
Account owners chase late payments by hand. This shows them which invoices
are overdue so they can follow up.

## Terms
- Overdue: unpaid, with a due date before today in the account's time zone.

## Acceptance criteria
1. Signed-in owner opens Invoices → each overdue invoice shows an "Overdue" badge; others don't.
2. Owner filters Invoices by "Overdue" with the page's existing status filter → only overdue invoices are listed.
3. Owner marks an overdue invoice paid → it loses the badge and leaves the "Overdue" filter.
4. Owner sets a due date on an invoice → the date is kept after a reload; a due date before the issue date is refused with "Due date can't be before the issue date".
5. Signed-in user opens another account's invoice → sees "Not found"; nothing about it is shown.

## Out of scope
- Reminder emails.
- Late fees.
- Changing the due date of a paid invoice.

## Constraints
- Reuse the status filter on Invoices (criterion 2).

## Open questions
- None.
