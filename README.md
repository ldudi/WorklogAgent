# WorklogAgent

Turn your recent screen history into a searchable local worklog. WorklogAgent reads JustNow evidence, asks a local Ollama model to reconstruct activities, stores validated records in SQLite, and generates daily, weekly, and monthly Markdown reports.

The project includes a macOS menu-bar app, a command-line tool, and a reusable Swift library. It is an early-stage project: activity labels and durations are estimates from sampled screen evidence and can be corrected. It does not measure keyboard activity or prove time worked.

## Features

- Local model inference with loopback-only Ollama connections; no cloud inference or telemetry in WorklogAgent.
- A single activity timeline across multiple displays, with checkpoints, cached replay, and overlap protection.
- Daily, weekly, and monthly reports with category, project, intent, focus, and context-switch estimates.
- Indexed search, explicit project aliases, audited corrections, and optional legacy Markdown import.
- Menu-bar controls for summarization, pause/resume, model selection, reports, and output settings.

## Requirements

- macOS 14 or later, with Xcode or a Swift toolchain supporting Swift 5.10 or later. SQLite is provided by the macOS SDK; no Homebrew SQLite installation is required.
- [JustNow](https://github.com/yjsoon/justnow), installed separately and recording screen history with Screen Recording permission. WorklogAgent expects `frames.sqlite` and `text_cache.sqlite` in its data directory and does not capture screens itself.
- [Ollama](https://ollama.com), running locally, with a downloaded model. The default is [`gemma4:e4b`](https://ollama.com/library/gemma4:e4b). Memory requirements depend on the model; vision requires a model with image support.

JustNow and Ollama are separate projects with their own licenses and requirements. WorklogAgent relies on JustNow's internal database schema, so compatibility can change between JustNow versions. Linux is not a supported end-to-end platform for this macOS integration.

## Quick start

Install and start JustNow and Ollama first. Allow JustNow to record some history, then download the default model:

```bash
ollama pull gemma4:e4b
```

If the Ollama desktop app is not running, start its server with `ollama serve` in another terminal.

```bash
git clone https://github.com/ldudi/WorklogAgent.git
cd WorklogAgent
swift build
swift run WorklogAgent doctor
swift run WorklogAgent summarize
swift run WorklogAgent report today
```

`doctor` checks the evidence databases, local model, and output/storage configuration. The first summary covers the latest configured lookback (90 minutes by default); subsequent automatic processing starts from the stored checkpoint.

### Menu-bar app

```bash
bash scripts/build-macos-app.sh
open dist/Worklog.app
```

The script builds a release app and signs it ad hoc. It does not produce a notarized distribution. Close an older running copy before launching a rebuilt app. The menu-bar app provides its own scheduler; use either it or the CLI daemon for routine automatic processing.

### CLI background installation

```bash
bash scripts/install-daemon.sh
# Optional: WORKLOG_INTERVAL=60 WORKLOG_MODEL=gemma4:e4b bash scripts/install-daemon.sh
bash scripts/uninstall-daemon.sh
```

The installer builds the CLI, copies it into your Application Support folder, and registers a per-user LaunchAgent. Logs are written to `~/Library/Logs/WorklogAgent.log` and `WorklogAgent.error.log`. Uninstall removes the LaunchAgent and stops it; it preserves your binary, database, reports, and logs.

## Commands

```bash
swift test
swift run WorklogAgent doctor
swift run WorklogAgent inspect --minutes 30
swift run WorklogAgent summarize
swift run WorklogAgent report today
swift run WorklogAgent report week
swift run WorklogAgent report month
swift run WorklogAgent stats week
swift run WorklogAgent search "Ollama" --from 2026-09-01 --to 2026-10-01
swift run WorklogAgent search --project WorklogAgent --category coding --intent BUILD
swift run WorklogAgent search --entity Swift --fact outcome
swift run WorklogAgent projects
swift run WorklogAgent daemon --interval 90
```

`daily` is an alias for regenerating today's report. `models` lists installed local models. The default model remains `gemma4:e4b`; up to six representative screenshots are recognized independently before activity reconstruction. Cleaned OCR is secondary evidence, sampled across displays. All model-independent tests use temporary stores and network stubs; no running Ollama is required.

Default paths:

- Database: `~/Library/Application Support/WorklogAgent/worklog.sqlite`
- Project configuration: `~/Library/Application Support/WorklogAgent/projects.json`
- Markdown projections: `~/Documents/Worklogs`
- External read-only evidence: `~/Library/Application Support/JustNow`

Use `--database`, `--output`, `--justnow`, `--model`, `--projects-config`, and `--focus-minutes` to override these. `--ollama` accepts loopback endpoints only. `--no-images` disables vision. `--no-daily-summary` disables the automatic daily projection. Output folder bookmarks still work in the menu-bar app.

## Canonical processing versus inspection

`Summarize Now` and `summarize` process the SQLite checkpoint through now minus the grace period. Initial processing covers the latest 90 minutes; it does **not** claim to have captured the whole day. Catch-up splits at the configured interval and local midnight. Empty periods advance the checkpoint without inventing tracked activity. Stored explicit ranges are skipped during subsequent catch-up.

```bash
# Read-only evidence inspection (no model)
swift run WorklogAgent inspect --minutes 90

# Model inspection, never changes canonical records/checkpoint/Markdown
swift run WorklogAgent summarize --minutes 90
swift run WorklogAgent summarize --from 2026-01-15T09:00:00Z --to 2026-01-15T10:00:00Z --inspect-only

# Canonical explicit interval. Different overlapping ranges are rejected.
swift run WorklogAgent summarize --from 2026-01-15T09:00:00Z --to 2026-01-15T10:00:00Z

# Exact replay returns saved records and regenerates the report without model calls.
# Deliberate reprocessing replaces unconfirmed records atomically, never duplicates time.
swift run WorklogAgent summarize --from 2026-01-15T09:00:00Z --to 2026-01-15T10:00:00Z --reprocess
```

Reprocessing an interval with user corrections is refused so those corrections cannot be erased by changed model segmentation. Model/transport outages do not advance the checkpoint. Malformed activity JSON gets one repair attempt, then an unclear fallback with evidence references. Vision decoding failures retain the available OCR path. Model output is constrained by JSON Schema and separately validated in Swift.

Dates are local calendar dates or ISO 8601 timestamps with explicit timezone. Ranges are half-open `[from,to)`; date-only `--to 2026-10-01` excludes October 1. Weeks start Monday. Reports use the full calendar period, so current periods are incomplete. Search supports date/project/category/intent/entity/fact filters and literal FTS5 terms, with `--limit` (default 100, maximum 10,000). Basic SQL totals can span years; reports load at most a calendar month of facts.

## Projects and corrections

Create `projects.json` using this format; replace the example with your own explicit projects:

```json
{
  "projects": [
    {
      "name": "MyProduct",
      "aliases": ["MyProductApp", "my-product"],
      "repository": "/absolute/path/to/my-product"
    }
  ]
}
```

Project configurations are persisted in owned storage and reused when no configuration file is present. `projects` lists both stored and currently configured projects. Only a unique configured name/alias match in cited evidence assigns a project. Low-confidence or ambiguous matches stay unassigned. The model's invented project names are ignored. Repository paths are configuration metadata; **Git collection is not implemented yet**. Nothing scans the filesystem.

```bash
swift run WorklogAgent search "animation"
# Copy the full activity ID from search:
swift run WorklogAgent correct <activity-id> --title "Swift animation tutorial" --category technical_learning --intent LEARN
swift run WorklogAgent report today --date 2026-09-28
```

Corrections are separately audited and mark the canonical activity `USER_CONFIRMED`; replay preserves them. API corrections can also set/clear a configured project. No training or automatic semantic matching is performed.

## Safe legacy migration

Existing Markdown is not imported automatically and is never treated as raw evidence. The first SQLite projection of a legacy daily file copies it to `legacy-backups/<day>-<UUID>.md` before replacing it. You can run all checks with a separate `--database` and `--output` directory to leave current files untouched.

```bash
swift run WorklogAgent import-markdown ~/Documents/Worklogs --database /tmp/legacy-review.sqlite
# To import into the canonical store, omit --database.
```

The importer accepts `### Activity` interval entries, skips old clarification/noise responses and already generated projections, and imports only uncovered portions of overlapping intervals. Legacy records have source `legacyMarkdown`, confidence 0.35, unknown classification, and **no screenshot evidence**. Re-import is idempotent. Overlap trimming establishes unique coverage, not precise historical activity attribution. Prefer reprocessing retained JustNow evidence in a fresh store when classification matters.

The old `state.json` processing timestamp is deliberately not migrated: earlier versions advanced it for overlapping lookbacks. Only its daily scheduler marker is still used. SQLite versions are transactional; upgrades back up the owned database using SQLite's backup API, preserve records, and refuse future versions. Never run an older app concurrently with the new version against the same report folder: the older binary still appends prose. Existing `dist/Worklog.app` is not automatically replaced by `swift build`.

## Statistics and reports

SQLite calculates clipped time totals by category, intent, and project. Swift calculates focus and switching from primary records. Both monitors contribute evidence to **one** primary timeline; background context never adds time. Creation means `BUILD + FIX`. Planning, research and learning remain separate; consumption means `CONSUME`. No productivity score or moral judgment is generated.

A focus block is adjacent primary activity with the same project (or unassigned title), category and intent, for at least 25 minutes (`--focus-minutes` configurable). Context switches compare coherent blocks of at least two minutes with at most a five-minute intervening gap. Screenshots and window changes themselves are never switch counters. These are estimates, not foreground-input telemetry. Sparse evidence becomes unclear; tracked coverage is not proof of continuous attention, work or presence.

Daily, weekly, and monthly Markdown query original facts, never earlier reports. Weekly/monthly comparisons calculate numeric differences in Swift. These initial reports are deterministic; LLM improvement interpretation, goal alignment, recurring-problem linking, query planning/`ask`, and yearly trend packages are deferred.

## Privacy and retention

Structured records, classifications, entities, facts and corrections are retained indefinitely. Up to 24 redacted OCR excerpts (maximum 900 characters each) and six bounded vision descriptions are stored per processing window. Screenshot paths and JustNow frame/span IDs are references; **no screenshots are copied**. References expire under JustNow's own retention, so future reprocessing may lose access to original pixels. Vision descriptions are `INFERRED`; copied OCR is `OBSERVED`. Facts inferred from either retain their evidence IDs, confidence, activity and project associations.

Text secret redaction runs before prompts and again at persistence. This is defense in depth: unrelated private text can still be captured, and redaction does not remove secrets from screenshot pixels sent to the local model. Configure JustNow exclusions or use `--no-images` for sensitive screens. The owned SQLite file and upgrade backups are mode 0600. No raw OCR dumps are archived. `--diagnostics <directory>` explicitly enables bounded, redacted failed model response files locally; leave it unset for normal use.

## Architecture, schema and limitations

See [architecture](docs/ACTIVITY_ARCHITECTURE.md) for the data flow, schema, migrations, and roadmap. Build a distributable app with `bash scripts/build-macos-app.sh`; launch it yourself after closing the previous version. `scripts/install-daemon.sh` remains available for the CLI daemon.

JustNow's `frame_spans` and `frame_text` schema is an internal, read-only integration, not a public API. Future JustNow schema changes can require reader updates. Run `doctor` after updating JustNow or Ollama.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| JustNow data or a database is missing | Start JustNow, enable recording, and allow it to capture history. Use `--justnow` if its data directory differs from the default. Both expected databases must exist. |
| Ollama is unreachable or the model is missing | Start the local Ollama server, run `ollama list`, and pull the selected model. Use `swift run WorklogAgent models` to list installed models. |
| Vision is unavailable | Select an image-capable model or run the CLI with `--no-images`. |
| Report output is not writable | Choose a writable output folder in Settings or pass `--output` to the CLI. |
| An interval overlaps existing history | Use inspection mode, replay the exact interval, or deliberately reprocess that exact unconfirmed interval. User-corrected intervals cannot be reprocessed. |
| A summary looks inaccurate | Inspect the supporting evidence, correct individual records, and review the privacy and inference limitations above. |

## Development and contributions

```bash
swift test
swift build -c release --product WorklogAgent
swift build -c release --product WorklogMenuBar
```

Tests use temporary stores and stubbed network responses; they do not require a running Ollama server or personal JustNow history. Source is organized into `WorklogCore` (storage, evidence readers, inference, and reports), `WorklogAgent` (CLI), and `WorklogMenuBar` (SwiftUI app).

Issues and pull requests are welcome. Describe the problem, keep changes focused, and include relevant validation. Use synthetic evidence in tests and issue reports. Never attach personal screen recordings, worklogs, databases, or unreviewed diagnostic output.

Generated builds, local Xcode state, private verification files, local databases, and environment files are excluded by `.gitignore`. Keep personal project configuration and report output outside the repository. Secret redaction cannot guarantee that captured text or pixels are safe to share.

## License

[MIT](LICENSE), copyright 2026 Labhesh Dudi. This license covers WorklogAgent; separately installed applications and model weights retain their own licenses.
