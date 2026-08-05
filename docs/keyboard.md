# Keyboard

Every shortcut is a menu item. That is a rule, not a coincidence: a shortcut that exists only as a
local key handler is undiscoverable, does not appear in Help search, and cannot be re-bound in
System Settings. If you add one and it is not in `App/MainMenu.swift`, it is a bug.

## Sending

| | |
|---|---|
| `⌘↩` | Send |
| `⌘.` | Cancel |
| `⌘L` | Focus the URL field |

## Requests and collections

| | |
|---|---|
| `⌘T` | New tab |
| `⌘N` | New request |
| `⇧⌘N` | New folder |
| `⌘S` | Save the request |
| `⌘O` | Open a collection folder |
| `⌘K` | Go to request — fuzzy switcher over everything in the collection |
| `⌘E` | Environments |
| `⇧⌘I` | Import from Postman |
| `⌥⇧⌘W` | Close the collection |

## Tabs

| | |
|---|---|
| `⌘1`…`⌘5` | Select a tab by position |
| `⇧⌘[` / `⇧⌘]` | Previous / next tab, wrapping |
| `⌘W` | Close the tab — closes the window on the last one |
| `⇧⌘W` | Close the window |

## Interchange

| | |
|---|---|
| `⇧⌘C` | Copy as cURL |
| `⌥⇧⌘C` | Copy as cURL, with credentials redacted |
| `⌥⌘V` | Paste a cURL command as a request |

`⌥⌘V` is enabled only when the clipboard actually holds something that looks like a cURL command,
so it is never offered when it could only produce an error.

## Response

| | |
|---|---|
| `⌘F` | Find in the response body |
| `⌘G` / `⇧⌘G` | Next / previous match (macOS find bar) |

## View

| | |
|---|---|
| `⌃⌘S` | Toggle the sidebar |
| `⌃⌘F` | Full screen |

## Two conventions worth knowing

**Menu key equivalents win over the view hierarchy.** AppKit matches them before the event reaches
a view, so a `.keyboardShortcut` in SwiftUI that duplicates a menu item is dead code that drifts out
of step with `validateMenuItem`. The Send button deliberately has no shortcut of its own.

**Disabled items are still listed.** The whole map is laid out up front so it stays coherent, rather
than each feature grabbing whichever key happens to be free. `⌘,` is reserved for Settings and does
nothing yet.
