# Fixture corpus

Built BEFORE the importers, and development is driven off it.

- `postman/` — 30+ real collections scraped from public GitHub repos. Every polymorphic spot
  in the v2.1 schema (`url`, `header`, `description`, `script.exec`, `host`, `path`) is a
  place a naive `Codable` conformance throws on a real file. Roughly 70% of importer bugs
  live here, so the corpus is the defence.
- `curl/` — verbatim strings from Chrome devtools, Firefox devtools, and Windows
  `cmd` "Copy as cURL". These three are the acceptance test for the shell tokenizer.
- `expected/` — expected `ImportResult` snapshots.
