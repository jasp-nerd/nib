## What and why

<!--
One paragraph, in your own words: what this changes and why it needs to change.

This is the most important box on the form. If the paragraph is hard to write, the change is
not ready — that is the signal, not an inconvenience. Do not paste a diff summary here.
-->

## Checklist

- [ ] `make check` is green (boundaries + format + tests)
- [ ] I can explain every line of this diff
- [ ] No new dependency (or: there is an agreed issue, linked below)
- [ ] No new polling timer
- [ ] Added or updated a test for the behaviour this changes
- [ ] No new TCC permission

## Footprint

<!-- Required for anything touching the app target, a Package.swift, or project.yml. -->

|            | before | after |
|------------|--------|-------|
| Bundle     |        |       |
| Launch     |        |       |
| Idle RSS   |        |       |

RAM stays under 60 MB and the bundle under 5 MB. Always. No feature is worth going over —
if this change needs more, that is a conversation in an issue, not a line in a PR.

## Visual change

<!-- If this changes the UI: a side-by-side before/after screenshot or a short recording.
     A recording beats a paragraph. -->

## Related issue

Closes #
