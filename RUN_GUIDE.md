# Manual Run Guide

This project is a local Claude Code + Codex usage dashboard. It scans Claude and Codex JSONL transcripts, stores usage data in SQLite, and serves a browser dashboard.

## Requirements

- Python 3.8 or newer
- Claude Code transcript files under `~/.claude/projects/`
- Codex transcript files under `~/.codex/sessions/`
- Internet access in the browser for Chart.js from the CDN

No `pip install`, virtual environment, or build step is required. The app uses only Python standard-library modules.

## Project Files

- `cli.py` - command-line entry point
- `scanner.py` - scans Claude and Codex JSONL transcripts into SQLite
- `dashboard.py` - local HTTP dashboard server with provider/model filters
- `tests/` - unittest test suite
- `~/.claude/usage.db` - generated SQLite database

## From A Fresh Clone

```bash
git clone https://github.com/phuryn/claude-usage
cd claude-usage
```

On Linux or macOS, use `python3` in the commands below. On Windows, use `python` if `python3` is not available.

## Verify Python

```bash
python3 --version
```

Expected: Python 3.8+.

## Run Tests

```bash
python3 -m unittest discover -s tests
```

Expected result:

```text
OK
```

## Scan Usage Logs

```bash
python3 cli.py scan
```

What this does:

- Reads Claude transcript files from `~/.claude/projects/`
- Also checks the Xcode Claude integration transcript directory on macOS
- Reads Codex transcript files from `~/.codex/sessions/`
- Creates or updates `~/.claude/usage.db`
- Skips unchanged files on later runs

Scan custom transcript directories:

```bash
python3 cli.py scan --projects-dir /path/to/claude/transcripts
python3 cli.py scan --codex-sessions-dir /path/to/codex/sessions
python3 cli.py scan --projects-dir /path/to/claude/transcripts --codex-sessions-dir /path/to/codex/sessions
```

## View Terminal Reports

Today's usage by provider/model:

```bash
python3 cli.py today
```

Last 7 days:

```bash
python3 cli.py week
```

All-time stats:

```bash
python3 cli.py stats
```

If these commands say the database is missing, run:

```bash
python3 cli.py scan
```

## Run The Dashboard

Default host and port:

```bash
python3 cli.py dashboard
```

Then open:

```text
http://localhost:8080
```

Custom host and port:

```bash
python3 cli.py dashboard --host 127.0.0.1 --port 8090
```

Then open:

```text
http://127.0.0.1:8091
```

You can also use environment variables:

```bash
HOST=0.0.0.0 PORT=9000 python3 cli.py dashboard
```

Stop the dashboard with `Ctrl+C` in the terminal where it is running.

## Current Verified Local Run

On this machine, the project was verified with:

```bash
python3 -m unittest discover -s tests
python3 cli.py scan
python3 cli.py today
python3 cli.py week
python3 cli.py stats
python3 cli.py dashboard --host 127.0.0.1 --port 8090
```

The dashboard responded successfully at:

```text
http://127.0.0.1:8091/
http://127.0.0.1:8091/api/data
```

The dashboard includes provider and model filters, so Claude and Codex usage can be viewed together or separately.

The generated local database is:

```text
~/.claude/usage.db
```

## Troubleshooting

If port `8080` is already in use, run with another port:

```bash
python3 cli.py dashboard --port 8090
```

If the dashboard has no data, scan first:

```bash
python3 cli.py scan
```

If the browser charts do not load, check that the browser can reach the Chart.js CDN used by `dashboard.py`.

If you want to rebuild the usage database from scratch, stop the dashboard and remove the generated DB:

```bash
rm ~/.claude/usage.db
python3 cli.py scan
```
