# psql_wrapper.sh

One Bash wrapper around `psql` for the three jobs you usually script by hand:

| Command | What it does |
|---|---|
| `migrate` | Runs SQL files, or an ordered directory of migrations, in **one transaction** with `ON_ERROR_STOP`. Any error rolls everything back. Supports psql variables (`-v`), an optional tracking table (skips files already applied, records sha256, detects edited files), and a confirmation guard for production targets. |
| `query` | Runs a query and exports the result as CSV / TSV / JSON / NDJSON / text, to stdout or to a timestamped, optionally compressed file. **Read-only by default.** Built for cron reports. |
| `health` | Checks database and table sizes, connections, blocking locks, long-running queries, a bloat estimate, replication lag, cache hit ratio, vacuum/analyze status and XID wraparound. Thresholds set the exit code (OK / WARN / CRIT) and trigger alerts. Has a Nagios mode. |

```
psql_wrapper.sh migrate -d DB[,DB...] (-f FILE... | -D DIR) [options]
psql_wrapper.sh query   -d DB[,DB...] (-c SQL | -f FILE) [-F csv|tsv|json|ndjson|txt] [-o FILE | --output-dir DIR]
psql_wrapper.sh health  [-d DB[,DB...] | --all] [--warn CHECK=N] [--crit CHECK=N] [-F text|json] [--nagios]
```

Version 1.0.0. Needs Bash 4.4 or newer and `psql` (PostgreSQL 12+ client for `--csv`; `pg_blocking_pids` needs a 9.6+ server). Part of the [pg-dump-wrapper toolkit](README.md).

📘 **Copy-paste recipes for every scenario:** [EXAMPLES_psql.md](EXAMPLES_psql.md)
💡 **Why not just call psql?** [WHY_PSQL_WRAPPER.md](WHY_PSQL_WRAPPER.md)

Settings are applied in this order (later ones win): **built-in defaults → `--config` file → command line**. The command (`migrate`, `query`, `health`) must be the first argument.

## Common options

### Connection
| Option | Purpose |
|---|---|
| `-h, --host HOST` | Server host or Unix socket directory. Default: `$PGHOST`, otherwise `localhost`. |
| `-p, --port PORT` | Server port. Default: `$PGPORT`, otherwise `5432`. Config key `port=`. |
| `-U, --user USER` | Role to connect as. Default: `$PGUSER`, otherwise `$USER`. |
| `-W, --password` | Prompts **once** for the password and keeps it only in this process's environment (`PGPASSWORD`), never on a command line. |
| `--pgpassfile FILE` | Reads passwords from this `.pgpass` file (sets `PGPASSFILE`). |
| `--maintenance-db DB` | Database used for server-wide health checks and for listing databases with `--all`. Default: `postgres`. |

**Passwords are never accepted on the command line or in the config file.** Use `~/.pgpass` (chmod 600), `--pgpassfile`, or `PGPASSWORD`. Every psql call uses `--no-password`, so cron jobs fail fast instead of hanging at a prompt.

### Databases
| Option | Purpose |
|---|---|
| `-d, --dbname DB` | Target database(s). Repeat it or use a comma list. |
| `--all` | Every connectable, non-template database. `health` uses this by default when no `-d` is given. |
| `--exclude-db GLOB` | With `--all`, skips matching databases (`'test_*'`). Repeatable. |
| `--stop-on-error` | Stops at the first failed database. The default is to continue and report all of them. |

Each database runs in its own child process, so one failure never affects another database. The run exits with the **highest** exit code of any database, and the log ends with a summary table.

### Behaviour, logging and alerts
| Option | Purpose |
|---|---|
| `-v, --set NAME=VALUE` | psql variable, usable in your SQL as `:NAME`, `:'NAME'` (literal) or `:"NAME"` (identifier). Repeatable. **Note:** in this tool `-v` means variable, as in psql. Verbose logging is `--verbose`. |
| `--config FILE` | `key=value` settings (see [psql_wrapper.conf.example](psql_wrapper.conf.example)). Parsed, never `source`d. Unknown keys are an error. |
| `-l, --log-file FILE` | Also appends every log line to FILE. Logs always go to **stderr**, so stdout stays clean for query output and reports. |
| `--dry-run` | Shows what would run (migration files and checksums, the generated driver script, the exact query, the health thresholds). Connects to nothing and changes nothing. |
| `--pg-bin DIR` | Uses `psql` from DIR, e.g. `/usr/lib/postgresql/17/bin`. |
| `--alert-email ADDR` | Mails the report via `mail`, `mailx` or `sendmail -t`. Repeatable. |
| `--alert-webhook URL` | POSTs the report with curl (20 s timeout, 2 retries). The URL goes to curl on stdin (not visible in `ps`), and only `scheme://host/...` is logged. |
| `--alert-webhook-format F` | `slack` (default, `{"text": ...}`, also works for Teams, Google Chat and Mattermost) or `json` (`tool`, `command`, `status`, `exit_code`, `failed_stage`, `health`, `host`, `server`, `user`, `started`, `duration_seconds`, `databases`, `text`). |
| `--alert-on WHEN` | `failure` (default: any non-zero exit, **including health WARN/CRIT**), `crit` (failures and CRIT, not WARN), `always`. |
| `--alert-from ADDR` | From address for e-mail. |
| `--alert-test` | Sends a test alert and exits: `psql_wrapper.sh --alert-test --alert-webhook URL`. |

On failure the alert includes the last 20 log lines (from `-l FILE`). Anything that looks like `password=...` or `user:pass@` is masked. Alerts never change the exit code.

### Production guard
| Option | Purpose |
|---|---|
| `--production GLOB` | Database names that count as production (`'*_prod'`, `salesdb`). Repeatable. Config: `production_dbs=`. |
| `--production-host GLOB` | Hosts that count as production. Every database on them is guarded. Config: `production_hosts=`. |
| `-y, --yes` | Confirms writes to every production target (for automation). |
| `--confirm DB` | Confirms only the named database(s). Safer than `--yes` in cron, because a typo in `-d` is refused instead of confirmed. |

The guard applies to `migrate` and to `query --read-write`. With neither flag, an interactive terminal is asked to **type the database name**. Without a terminal the run is refused with exit code 5 and nothing is changed. `--yes` and `--confirm` are deliberately **not** accepted in the config file.

## `migrate`

| Option | Purpose |
|---|---|
| `-f, --file FILE` | SQL file to run. Repeatable. Files run in the order given. |
| `-D, --dir DIR` | Runs every `*.sql` in DIR in **version order** (`sort -V`: `001_`, `002_`, `010_`, `V2__`, `V10__`). `-f` files run first. |
| `--transaction MODE` | `all` (default): one transaction for every file, and any error rolls back **everything**. `per-file`: each file in its own transaction; stops at the first failure and keeps earlier files. `none`: autocommit, for statements that cannot run in a transaction (`CREATE INDEX CONCURRENTLY`, `VACUUM`). |
| `--track` | Records each applied file in a tracking table and skips it on later runs. |
| `--track-table NAME` | Tracking table, `[schema.]table` (default `public.schema_migrations`; the schema must exist). Implies `--track`. |
| `--allow-changed` | When an applied file has been edited, skip it with a warning instead of failing with exit 4. |
| `--status` | With `--track`, prints `applied` / `pending` / `CHANGED` for every file and exits (4 if anything changed). Read-only. |

How a run works:
1. Files are collected and checked before connecting: they must be readable, names must be unique, files must not contain their own `BEGIN`/`COMMIT`/`ROLLBACK` (unless `--transaction none`), and `\connect` is rejected.
2. The tool connects, refuses read-only standbys, and reads the tracking table (if any). Applied files with the same sha256 are skipped. An edited file stops the run with **exit 4**.
3. The production guard runs.
4. A small driver script is generated: `\set ON_ERROR_STOP on`, `BEGIN`, create the tracking table if missing, `LOCK` it (so two concurrent runs can't apply the same file), then `\i file` followed by an `INSERT` into the tracking table for each file, then `COMMIT`. File names and checksums are passed as psql variables, never pasted into SQL.
5. psql's output streams into the log with a `[PSQL]` tag (`>>> applying 002_seed.sql`, errors with file and line).

Tracking table:
```sql
CREATE TABLE public.schema_migrations (
    filename   text PRIMARY KEY,          -- file name without directory
    checksum   text NOT NULL,             -- sha256 of the file
    applied_at timestamptz NOT NULL DEFAULT now(),
    applied_by text NOT NULL DEFAULT current_user);
```

On SIGINT/SIGTERM the tool asks psql to **cancel the running statement** on the server (not just kill the client), so the transaction rolls back immediately. Exit code 130.

## `query`

| Option | Purpose |
|---|---|
| `-c, --command SQL` / `-f, --file FILE` | The query: one statement. psql variables (`-v`) work inside it. |
| `-F, --format FMT` | `csv` (default; psql `--csv`, RFC 4180 quoting), `tsv` (the same with a tab separator), `json` (one array: `[{"col": value, ...}]`, `[]` when empty), `ndjson` (one JSON object per line), `txt` (aligned psql table, no row-count footer). |
| `--no-header` | Omits the header row (csv/tsv/txt). |
| `--delimiter C` | Field separator for csv, e.g. `';'` for European spreadsheets. |
| `-o, --output FILE` | Writes to FILE. `-` or no option means stdout. An existing file is never overwritten without `--force`. |
| `--output-dir DIR` + `--name NAME` | Writes `DIR/NAME_<db>_YYYYmmdd_HHMMSS.<ext>`, one file per database. Required when you query several databases. |
| `-Z, --compress M` | `gzip` (`.gz`) or `zstd` (`.zst`) for file output. |
| `-r, --retention-days N` | With `--output-dir`, deletes this report's older files (`NAME_*_YYYYmmdd_HHMMSS.*`, by mtime) after a successful run. Other files are never touched. |
| `--read-write` | Allows INSERT/UPDATE/DDL. By default the session runs with `default_transaction_read_only=on`, so a report query can't change data by accident. Read-write queries go through the production guard. |
| `--timeout SEC` | `statement_timeout` for the query. |

File output is written to `<file>.part.<pid>` and renamed only when psql and the compressor both succeed, so a failed query never leaves a half-written report. JSON formats wrap your query as `SELECT json_agg(q) FROM (<your query>) q`, so the query must be a single SELECT (a trailing `;` is fine).

## `health`

| Option | Purpose |
|---|---|
| `--checks LIST` | Which checks to run (default: all). |
| `--warn CHECK=N`, `--crit CHECK=N` | Override thresholds. Repeatable. Config keys: `warn_<check>=`, `crit_<check>=`. |
| `--min-rows N` | Tables with fewer rows are ignored by `bloat` and `vacuum` (default 1000). |
| `--top N` | How many of the largest tables `db_size` lists (default 5). |
| `-F, --format` | `text` (table, default) or `json` (`{"status", "host", "port", "checked_at", "checks": [{database, check, status, value, detail}]}`). |
| `--nagios` | One line (`PSQL_HEALTH WARNING - 0 crit, 2 warn, ...`) and Nagios/Icinga exit codes. |

| Check | Scope | Measures | WARN / CRIT default |
|---|---|---|---|
| `connections` | server | client connections as % of `max_connections`, broken down by state | 80 / 95 % |
| `long_running` | server | longest active query, or open transaction for `idle in transaction`; shows pid, db and query | 300 / 900 s |
| `blocking` | server | sessions waiting on another session's lock (`pg_blocking_pids`); shows who blocks whom and for how long | 30 / 120 s waited |
| `replication` | server | primary: max `replay_lag` of replicas and bytes behind. Standby: time since the last replayed transaction | 60 / 300 s |
| `db_size` | per DB | database size, plus the N largest tables (incl. indexes and TOAST) | off (0) / off, in MB |
| `cache_hit` | per DB | `blks_hit / (blks_hit + blks_read)`; ignored below 1000 block reads | below 95 / below 90 % |
| `bloat` | per DB | **estimate** from dead tuples: `n_dead_tup / (n_live_tup + n_dead_tup)` per table | 20 / 50 % |
| `vacuum` | per DB | tables with ≥ min-rows dead tuples (or changed rows) whose last (auto)vacuum/analyze is older than N days (never counts as WARN) | 7 / 30 days |
| `wraparound` | per DB | `age(datfrozenxid)` | 1e9 / 1.5e9 xids |

Health sessions are read-only (`default_transaction_read_only=on`) with a 30 s statement timeout. A database you can't connect to shows up as a `connect CRIT` row, so monitoring never mistakes "unreachable" for "healthy". For exact bloat numbers use the `pgstattuple` extension. The dead-tuple estimate is cheap and needs no extension.

## Exit codes

| Code | Meaning | `--nagios` |
|---|---|---|
| 0 | Success / health OK | 0 OK |
| 1 | Usage or validation error | 3 UNKNOWN |
| 2 | Pre-check failed (psql missing, cannot connect, standby, file or directory missing) | 3 |
| 3 | SQL failed: migration rolled back (see `--transaction`), or the query failed | 3 |
| 4 | Migration checksum drift (an applied file was edited) | 3 |
| 5 | Refused by the production guard | 3 |
| 6 | Output error (directory not writable, file exists, compressor failed) | 3 |
| 10 | Health WARN | 1 WARNING |
| 11 | Health CRIT | 2 CRITICAL |
| 130 | Interrupted (SIGINT/SIGTERM) | 3 |

## Quick examples

```bash
# Apply pending migrations, tracked, one transaction, variables for the SQL
./psql_wrapper.sh migrate -d salesdb -D ./migrations --track -v app_schema=sales

# What would run / what is applied?
./psql_wrapper.sh migrate -d salesdb -D ./migrations --track --status

# Production: must be confirmed explicitly
./psql_wrapper.sh migrate -d salesdb -D ./migrations --track --production salesdb --confirm salesdb

# Nightly CSV report, gzip, 30-day retention
./psql_wrapper.sh query -d salesdb -f reports/daily_sales.sql --output-dir /srv/reports --name daily_sales -Z gzip -r 30

# JSON for an API / script
./psql_wrapper.sh query -d salesdb -c "select id, name from customers where region = :'r'" -v r=EMEA -F json

# Health of every database, alert Slack on WARN/CRIT
./psql_wrapper.sh health --all --exclude-db 'template*' --alert-webhook "$SLACK_WEBHOOK_URL"
```

More in [EXAMPLES_psql.md](EXAMPLES_psql.md).

## Notes and caveats
- `-v` is a psql **variable** in this tool (`-v name=value`), unlike the other wrappers in the toolkit, where it means verbose. Use `--verbose` here.
- `--transaction all` can't contain statements that refuse to run in a transaction block (`CREATE INDEX CONCURRENTLY`, `VACUUM`, `CREATE DATABASE`). Put those in their own file and run it with `--transaction none`.
- The tracking key is the **file name**, not the path, so moving the migrations directory doesn't re-apply anything. Renaming a file does.
- `health` needs `pg_monitor` (or superuser) to see other users' queries in `pg_stat_activity`. Without it, `long_running` and `blocking` only see your own sessions.
- Quote globs so your shell doesn't expand them: `--production '*_prod'`.
