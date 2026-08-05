## What changed

<!-- One line. -->

## Linked issue

<!-- Nib is issue-first: link the issue this implements. If there isn't one, please open one before
     going further — see CONTRIBUTING.md. -->

Closes #

## Checklist

- [ ] `make check` is green (boundaries, format, lint, tests, size gate)
- [ ] No new dependency
- [ ] No `Timer` — FSEvents, a vnode source or an `NSWorkspace` notification instead
- [ ] No `import AppKit` or `SwiftUI` outside `NibUI`
- [ ] Tests added or updated, and they fail without the change
- [ ] Nothing added to `applicationDidFinishLaunching`

## Footprint

<!-- Fill this in if the change could plausibly move any of them. `make size`, `make measure`,
     `make memory`. Delete the row if it is genuinely unaffected. -->

| | Before | After |
|---|---|---|
| Bundle size | | |
| Cold launch | | |
| Idle footprint | | |

## Explain in one paragraph what this does and why

<!-- This box is the actual review control, not a formality. If the paragraph is hard to write, the
     change is not ready. Describe the behaviour, not the diff. -->
