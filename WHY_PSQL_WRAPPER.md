# Why use psql_wrapper.sh instead of plain psql?

`psql` can do everything this wrapper does. The wrapper doesn't add new database features. What it adds are the **safe defaults, checks and plumbing** that you would otherwise rewrite (and sometimes get wrong) in every migration script, cron report and monitoring check. This page compares the two honestly, including when plain psql is the better choice. Back to the [toolkit index](README.md) · [README_psql.md](README_psql.md) · [EXAMPLES_psql.md](EXAMPLES_psql.md).

## Side by side

| Concern | Plain `psql` | `psql_wrapper.sh` |
|---|---|---|
| **Stop on the first error** | Off by default: `psql -f file.sql` keeps going after an error and exits 0. You must remember `-v ON_ERROR_STOP=1`. | Always on. |
| **All-or-nothing migrations** | `-1/--single-transaction` per invocation. Running several files atomically needs a hand-written wrapper script with `\i`. | `migrate -D dir` runs every file in **one** transaction by default. `per-file` and `none` modes are there when you need them. |
| **File order** | Shell glob order (`10_` before `2_`). | Version sort (`2_` before `10_`). `-f` keeps your order. |
| **Already-applied migrations** | Not tracked. | `--track`: tracking table with filename, sha256, who and when. Applied files are skipped. Concurrent runs are serialised with a table lock. |
| **Edited migrations** | Silently ignored, or re-run by hand. | Detected by checksum. Exit 4 unless `--allow-changed`. `--status` shows applied / pending / CHANGED. |
| **Files with their own BEGIN/COMMIT, or `\connect`** | Break your single transaction without warning. | Rejected before connecting, with a clear message. |
| **Production safety** | Nothing stops `psql -h prod -f drop_stuff.sql`. | `--production` / `--production-host` globs. Writes need a typed confirmation, `--confirm DB` or `--yes`. `--yes` is refused in config files. |
| **Report queries changing data** | Possible. | `query` runs with `default_transaction_read_only=on` unless you pass `--read-write` (which is then production-guarded). |
| **CSV / JSON export** | `--csv` (PG12+), `-t` for no header, `-P csv_fieldsep`. JSON means writing `json_agg` wrappers by hand. | `-F csv\|tsv\|json\|ndjson\|txt`, `--no-header`, `--delimiter`. JSON returns `[]` for no rows. |
| **Report files** | `> file` overwrites, leaves partial files on error, no naming scheme. | Timestamped `NAME_db_YYYYmmdd_HHMMSS.ext`, atomic `.part` → rename, never overwrites without `--force`, gzip/zstd, retention that only touches its own files. |
| **Health monitoring** | You write and maintain the `pg_stat_activity`, `pg_blocking_pids`, `pg_stat_replication`, `pg_stat_user_tables` and `age(datfrozenxid)` queries yourself. | 9 built-in checks with WARN/CRIT thresholds, text/JSON/Nagios output, and exit codes 0/10/11 (or 0/1/2/3). |
| **Unreachable database in a check** | The script errors, or the check silently passes. | Reported as a `connect CRIT` row. |
| **Many databases** | A shell loop with your own error handling. | `-d a,b,c` or `--all --exclude-db`, isolated per database, a summary table, worst exit code wins. |
| **Ctrl-C / SIGTERM mid-migration** | Killing psql leaves the server-side statement running until it notices. | Sends psql a cancel request first, so the server stops at once and rolls back. Exit 130. |
| **Exit codes** | 0 / 1 / 2 / 3, with different meanings per situation. | Documented: 1 usage, 2 pre-check, 3 SQL, 4 drift, 5 guard, 6 output, 10 WARN, 11 CRIT, 130 interrupted. |
| **Alerts** | None. | E-mail and Slack/Teams/JSON webhooks on failure / CRIT / always. Webhook tokens are never logged. |
| **Passwords** | `PGPASSWORD=... psql` in scripts, sometimes a password in a connection URI on the command line. | Never on the command line or in config. `.pgpass`, `PGPASSFILE`, environment, or a one-time `-W` prompt. Always `--no-password`, so cron never hangs. |
| **Logging** | Whatever you redirect. | Timestamped, tagged `[db]` / `[PSQL]` lines on stderr (stdout stays clean for data), plus an optional log file. |

## Before and after

### 1. Running migrations

**Before:**
```bash
for f in migrations/*.sql; do          # 10_ sorts before 2_
  psql -h db01 -d salesdb -f "$f"      # no ON_ERROR_STOP: errors are ignored, exit code 0
done                                   # no transaction: half-applied on failure
                                       # no record of what ran; re-running re-applies everything
```
**After:**
```bash
psql_wrapper.sh migrate -h db01 -d salesdb -D migrations --track --production salesdb --confirm salesdb
```
Result: one transaction, stop at the first error, a full rollback on failure (exit 3), applied files skipped next time, edited files caught (exit 4), and a confirmation required for production.

### 2. A nightly CSV report

**Before:**
```bash
PGPASSWORD=S3cret psql -h db01 -U report -d salesdb --csv -f daily.sql > /srv/reports/daily.csv
# the password is visible in the crontab; yesterday's report gets overwritten;
# a failed query leaves an empty or partial file; nobody is told it failed
```
**After:**
```bash
psql_wrapper.sh query -h db01 -U report -d salesdb -f daily.sql --output-dir /srv/reports --name daily \
    -Z gzip -r 30 --alert-email dba@example.com          # password from ~/.pgpass
```

### 3. "Is anything blocked?"

**Before:**
```bash
psql -d salesdb -Atc "select count(*) from pg_stat_activity where cardinality(pg_blocking_pids(pid)) > 0"
# then: hand-written thresholds, Nagios exit codes, Slack curl, and the same again for long queries, replication, bloat ...
```
**After:**
```bash
psql_wrapper.sh health -d salesdb --checks blocking,long_running --warn blocking=10 --crit blocking=60 --nagios
# PSQL_HEALTH WARNING - 0 crit, 1 warn, 2 checks: (server)/blocking=1 blocked, 12s max wait (WARN)
```

## When plain psql is enough

Use plain `psql` when:
- **You're exploring interactively.** `psql` with tab completion, `\d`, `\x` and `\timing` is the better tool, and the wrapper isn't trying to replace it.
- **It's a one-off ad-hoc statement** on a dev database, and nobody depends on its result or exit code.
- **You already have a migration framework** (Flyway, Liquibase, Sqitch, Alembic, Rails/Django migrations). Keep it. The wrapper's `migrate` is meant for teams that run plain `.sql` files and want the same safety without a JVM/Python dependency. Its tracking table is not compatible with those tools.
- **You need advanced `psql` features** like `\gexec`, `\crosstabview`, `\copy ... FROM` imports or custom `\pset` formats. Run those with psql directly, or put them inside a migration file (the wrapper runs files through psql, so meta-commands still work there).
- **You already have real monitoring** (Prometheus `postgres_exporter`, pganalyze, Datadog, pgwatch). They give you history and graphs. `health` is a point-in-time check for cron/Nagios/deploy gates, or for servers that have no monitoring yet.
- **You need exact bloat figures.** `health` estimates bloat from dead tuples. For exact numbers use `pgstattuple` or a full bloat query.
