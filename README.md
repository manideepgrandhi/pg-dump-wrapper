# pg-dump-wrapper: a small PostgreSQL toolkit in Bash

Cron-friendly Bash wrappers around the PostgreSQL client tools. They add safe defaults, validation, logging, documented exit codes and e-mail/webhook alerts. All tools share the same conventions, so once you know one, you know them all.

## Tools

| Tool | Version | What it does | Docs |
|---|---|---|---|
| [`pg_dump_wrapper.sh`](pg_dump_wrapper.sh) | 2.0.0 | Backups with `pg_dump`: every format, one/many/all databases, verification, sha256 checksums, retention, alerts | [README](#pg_dump_wrappersh) (below) · [Examples](EXAMPLES.md) · [Why this wrapper](WHY_THIS_WRAPPER.md) · [Sample config](pg_dump_wrapper.conf.example) |
| [`psql_wrapper.sh`](psql_wrapper.sh) | 1.0.0 | One tool, three commands: `migrate` (transactional, tracked SQL migrations with a production guard), `query` (CSV/TSV/JSON/NDJSON exports and scheduled reports), `health` (sizes, connections, locks, long queries, bloat, replication, cache, vacuum, wraparound with WARN/CRIT thresholds) | [README](README_psql.md) · [Examples](EXAMPLES_psql.md) · [Why this wrapper](WHY_PSQL_WRAPPER.md) · [Sample config](psql_wrapper.conf.example) |

A matching `pg_restore` wrapper is planned and not in this repository yet. Until then, restore with the `pg_restore` / `psql` commands shown in [EXAMPLES.md](EXAMPLES.md).

## Shared conventions

- **Bash 4.4+**, plus the PostgreSQL client binaries (`--pg-bin DIR` to choose a version, e.g. `/usr/lib/postgresql/17/bin`).
- **Settings precedence:** built-in defaults → `--config FILE` (plain `key=value`, parsed, never executed, unknown keys rejected) → command line.
- **Connection:** `-h/--host`, `-p/--port` (default `$PGPORT`, otherwise 5432; config `port=`), `-U/--user`. **Passwords are never accepted on the command line or in config files.** Use `~/.pgpass`, `--pgpassfile`/`PGPASSFILE`, `PGPASSWORD`, or a `-W` prompt. Every call uses `--no-password`, so cron jobs fail fast instead of hanging.
- **Many databases:** `-d a,b,c` or `--all --exclude-db 'glob'`. Each database is isolated, the run ends with a summary table, and the exit code is the highest code of any database.
- **Dry run:** `--dry-run` prints exactly what would run and changes nothing.
- **Alerts:** `--alert-email`, `--alert-webhook` (Slack/Teams/Google Chat or structured JSON), `--alert-on`, `--alert-test`. Webhook tokens are never logged, and alerts never change the exit code.
- **Logging:** timestamped lines tagged with the database name, plus the client tool's own output.
- **Exit codes:** documented in each tool's README. `0` always means success.

---

# pg_dump_wrapper.sh

A Bash wrapper around PostgreSQL `pg_dump` that adds safe defaults, validation, logging,
pre-checks, verification, checksums, retention, multi-database runs, and e-mail/webhook
alerts, so one command (or one cron line) produces reliable, consistently named backups.

```
pg_dump_wrapper.sh (-d DB[,DB...] | --all) [options] [-- extra pg_dump args]
```

Version 2.0.0. Needs Bash 4.4 or newer.

📘 **For copy-paste recipes for every scenario (formats, filters, migration, multiple databases, alerts, cron/systemd, exit codes, errors, restores), see [EXAMPLES.md](EXAMPLES.md).**

💡 **Why use this instead of calling pg_dump directly?** See [WHY_THIS_WRAPPER.md](WHY_THIS_WRAPPER.md) for a feature comparison, a before/after example, and when plain pg_dump is enough.

Settings are applied in this order (later ones win): **built-in defaults → `--config` file → command line**.

## Options

### Connection
| Option | pg_dump flag | Purpose |
|---|---|---|
| `-h, --host HOST` | `--host` | Server hostname or Unix socket directory. Default: `$PGHOST`, otherwise `localhost`. (`-h` means host here, just like in pg_dump. Use `--help` for help.) |
| `-p, --port PORT` | `--port` | Server port. Default: `$PGPORT`, otherwise `5432`. |
| `-U, --user USER` | `--username` | Role to connect as. Default: `$PGUSER`, otherwise `$USER`. |
| `-W, --password` | `--password` | Forces a password prompt (interactive use only). Without it the wrapper passes `--no-password`, so cron jobs fail fast instead of hanging. |
| `--pgpassfile FILE` | env `PGPASSFILE` | Reads the password from this `.pgpass` file. |

**Passwords are never accepted on the command line**, because other users can see command arguments in `ps`. Use `~/.pgpass` (chmod 600), `--pgpassfile`, or the `PGPASSWORD` environment variable. The wrapper never prints or logs the password.

### Databases (one dump file per database)
| Option | Purpose |
|---|---|
| `-d, --dbname DB` | Database(s) to back up. Repeat it (`-d a -d b`) or use a comma list (`-d a,b`). The name is also used in each output file name. |
| `--all` | Backs up every database where `datallowconn` is true and `datistemplate` is false (read from `pg_database` with psql). `template0`/`template1` and databases with `ALLOW_CONNECTIONS false` are skipped. You can't combine it with `-d`. |
| `--exclude-db PAT` | With `--all`, skips databases matching a shell glob (`postgres`, `test_*`). Can be repeated or comma-separated. |
| `--maintenance-db DB` | Database that `--all` connects to in order to list databases. Default: `postgres`. |
| `--stop-on-error` | Stops at the first database that fails and marks the rest `SKIPPED`. By default the script **continues** with the remaining databases. |

Each database runs in its own child process, with its own pre-check, dump, verify, checksum, and retention. One database failing never removes another database's output. At the end the script logs a summary table like this:

```
DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
hrdb                     OK        -          4.0K     0m00s    /backups/hrdb_20261010_013000.dump
lockeddb                 FAIL(2)   precheck   -        0m00s    -
salesdb                  OK        -          4.5M     0m01s    /backups/salesdb_20261010_013001.dump
```
The overall exit code is 0 only if every database succeeded. Otherwise it's the **highest** exit code of any failed database. All databases share one log file, and each line is tagged `[dbname]`.

### Format and performance
| Option | pg_dump flag | Purpose |
|---|---|---|
| `-F, --format FMT` | `--format` | `plain` (`.sql` script for psql), `custom` (`.dump`, compressed, works with selective `pg_restore`), `directory` (`.dir`, one file per table, supports parallel dump and restore), `tar` (`.tar`). Default: `custom`. |
| `-Z, --compress L` | `--compress` | Compression: `0`-`9`, or `gzip:N` / `zstd:N` / `lz4` with pg_dump 16+. For plain format the file gets the matching extension (`.sql.gz`, `.sql.zst`, `.sql.lz4`). Not allowed for tar. |
| `-j, --jobs N` | `--jobs` | Dumps N tables in parallel. **Directory format only**: the wrapper rejects it for other formats. Each job opens its own DB connection. |

### Scope (what gets dumped)
| Option | pg_dump flag | Purpose |
|---|---|---|
| `-s, --schema-only` | `--schema-only` | DDL only (tables, indexes, functions…), no rows. |
| `-a, --data-only` | `--data-only` | Rows only, no DDL. Can't be combined with `-s` or `-c`. |
| `-n, --schema PAT` | `--schema` | Dumps only matching schemas. Can be repeated or comma-separated. Wildcards are allowed (`'sales*'`). |
| `-N, --exclude-schema PAT` | `--exclude-schema` | Skips matching schemas. Can be repeated. |
| `-t, --table PAT` | `--table` | Dumps only matching tables (`schema.table`). Can be repeated. |
| `-T, --exclude-table PAT` | `--exclude-table` | Skips matching tables completely (structure and data). Can be repeated. |
| `--exclude-table-data PAT` | `--exclude-table-data` | Keeps the table's structure but skips its rows. Useful for big log or audit tables. Can be repeated. |
| `-O, --no-owner` | `--no-owner` | Leaves out `ALTER … OWNER TO`, so restored objects belong to whoever runs the restore. |
| `-x, --no-privileges` | `--no-privileges` | Leaves out `GRANT`/`REVOKE`. |
| `-c, --clean` | `--clean` | Adds `DROP` statements before each `CREATE` (plain format. For archive formats, pass `-c` to `pg_restore` instead). |
| `--if-exists` | `--if-exists` | Uses `DROP … IF EXISTS`, so a clean restore doesn't error on missing objects. Requires `-c`. |
| `-C, --create` | `--create` | Adds `CREATE DATABASE` and `\connect` to the script (plain format). |

### Files, logging, retention
| Option | Purpose |
|---|---|
| `-o, --output-dir DIR` | Where backups go. Created if it doesn't exist. Default: `.` |
| `-f, --file NAME` | Overrides the generated name. **Only allowed with a single database.** Default: `DB_YYYYmmdd_HHMMSS.<ext>` (`.dump`, `.dir`, `.tar`, `.sql[.gz]`). An existing file is never overwritten. |
| `-l, --log-file FILE` | Log file. Every line is timestamped and also printed to the console (stderr). pg_dump's own messages are logged with the `[PG_DUMP]` tag. Default: `OUTPUT_DIR/pg_dump_wrapper.log`. |
| `-r, --retention-days N` | After a **successful** backup of a database, deletes that database's entries in OUTPUT_DIR older than N days, but **only** ones whose names match `DB_<8 digits>_<6 digits>.*`. Other files, other databases, and custom-named dumps are never touched. A failed database keeps all its old backups. N must be ≥ 1. |
| `--min-free-mb N` | Warns when free space in OUTPUT_DIR is below N MB. Default: 1024. It also warns if the DB is larger than the free space. |

### Alerts
| Option | Purpose |
|---|---|
| `--alert-email ADDR` | E-mails the run report to ADDR. Can be repeated or comma-separated. The script uses `mail`, then `mailx`, then `sendmail -t`. If none is installed it logs a clear warning and skips e-mail. |
| `--alert-webhook URL` | POSTs the report as JSON with `curl` (20 s timeout, 2 retries). Can be repeated. Only the scheme and host of the URL are logged, because webhook URLs contain secret tokens. The URL is passed to curl on stdin, so it doesn't show up in `ps`. |
| `--alert-webhook-format F` | `slack` (default): `{"text": "..."}`, which works with Slack, Mattermost, Rocket.Chat, Google Chat, and Teams incoming webhooks. `json`: a structured object with `status`, `exit_code`, `failed_stage`, `host`, `server`, `user`, `started`, `duration_seconds`, `output_dir`, `log_file`, `databases[]` (database, exit_code, stage, size, duration_seconds, file), `log_tail`, and `text`. |
| `--alert-on WHEN` | `failure` (default) sends an alert only when the run fails. `always` also sends one on success. |
| `--alert-from ADDR` | From address for e-mails (`mail -r` / `From:` header for sendmail). |
| `--alert-test` | Sends a test alert to all configured targets and exits. Useful after setting up a webhook. |

**One combined alert per run.** It includes the server host, port, and user, the database list, the exit code, the stage that failed (validate / precheck / dump / verify / checksum / retention / interrupted) and which database, start time, duration, output dir, log file, the per-database summary table, and, on failure, the **last 20 log lines**.

Alerts never change the backup's exit code: a failed e-mail or webhook only logs a `WARN`. Passwords never reach the alert (the wrapper never handles one), and anything that looks like `password=...` or `user:pass@` in the log tail is masked as a precaution. Validation errors (a bad option or config value) also trigger an alert, so a broken cron config doesn't fail silently. `--dry-run` never sends alerts.

### Behaviour
| Option | Purpose |
|---|---|
| `--config FILE` | Loads `key=value` settings (see the sample below). The file is parsed, never `source`d or executed, and unknown keys are an error. |
| `--verify` | After the dump, runs `pg_restore --list` for custom/tar/directory dumps. For plain dumps it checks the file isn't empty and ends with pg_dump's "dump complete" footer. |
| `--checksum` | Writes `<dump>.sha256`. For directory format it covers every file in the directory. Check later with `cd OUTPUT_DIR && sha256sum -c <dump>.sha256`. |
| `--dry-run` | Validates everything and prints the exact `pg_dump` command for each database (shell-quoted), then exits without dumping, deleting, or alerting. With `--all` it connects once to list the databases. |
| `--skip-precheck` | Skips the pg_isready, psql connectivity, version, and disk-space checks. |
| `--pg-bin DIR` | Uses `pg_dump`, `pg_restore`, `psql`, and `pg_isready` from DIR, e.g. `/usr/lib/postgresql/17/bin`. |
| `-v, --verbose` | Debug logging, and passes `--verbose` to pg_dump. |
| `--help`, `--version` | Shows help or the version. |
| `-- ARGS…` | Passes anything after `--` straight to pg_dump, e.g. `-- --lock-wait-timeout=30s --no-comments`. |

### What happens on every run
1. Arguments and config are validated (conflicting flags, `-j` only with directory format, `-f` only with one database, port, compression, alert settings, and so on).
2. Run-level pre-checks: pg_dump exists and its version is logged, `pg_isready` succeeds, and free disk space is checked. With `--all`, the database list is read here.
3. For each database (in a child process):
   - a `psql` login check, which also logs the server version and DB size and fails if pg_dump is older than the server
   - pg_dump runs with `--no-password` and its output streams into the log
   - optional verify, then checksum, then retention
4. If pg_dump fails, or the run is interrupted (Ctrl-C / SIGTERM), pg_dump is stopped and that database's **partial file or directory is removed**. On interrupt, the remaining databases are marked `SKIPPED`.
5. The summary table is logged, then one combined alert is sent (if configured).

Files are created with `umask 077` (owner-only permissions).

### Exit codes
| Code | Meaning |
|---|---|
| 0 | Success (every database) |
| 1 | Usage or validation error (bad or conflicting options, output already exists) |
| 2 | Pre-check failed (pg_dump missing, server down, auth or DB-not-found, version mismatch) |
| 3 | pg_dump failed (partial output removed) |
| 4 | Verification or checksum failed |
| 5 | Retention cleanup failed (the backup itself is fine) |
| 130 | Interrupted by a signal |

For multiple databases, the run exits with the highest code among the failed databases.

## Examples

Set up the password once (recommended):
```bash
echo 'localhost:5432:salesdb:backup_user:S3cret' >> ~/.pgpass && chmod 600 ~/.pgpass
```

**1. Full backup (custom format, verified, with checksum)**
```bash
./pg_dump_wrapper.sh -h localhost -U backup_user -d salesdb \
    -o /backups/salesdb -Z 6 --verify --checksum
# -> /backups/salesdb/salesdb_20261010_093000.dump (+ .sha256)
# restore: pg_restore -d salesdb_copy /backups/salesdb/salesdb_20261010_093000.dump
```

**2. Fast parallel backup of a large DB (directory format, 4 jobs)**
```bash
./pg_dump_wrapper.sh -d salesdb -U backup_user -F directory -j 4 -o /backups/salesdb --verify
# restore in parallel too: pg_restore -j 4 -d salesdb_copy /backups/salesdb/salesdb_..._.dir
```

**3. Schema-only script of selected schemas, portable to another server**
```bash
./pg_dump_wrapper.sh -d salesdb -U backup_user -F plain -s -n sales -n hr \
    -O -x -c --if-exists -f salesdb_schema.sql -o /tmp
# apply: psql -d target_db -f /tmp/salesdb_schema.sql
```

**4. Only specific tables**
```bash
./pg_dump_wrapper.sh -d salesdb -U backup_user -t sales.orders -t 'sales.cust*' -o /backups/adhoc
```

**5. Everything, but skip the rows of a huge log table and drop a scratch schema**
```bash
./pg_dump_wrapper.sh -d salesdb -U backup_user \
    --exclude-table-data audit.event_log -N scratch -T public.tmp_import -o /backups/salesdb
```

**6. Nightly cron job: every database, 14-day retention, alerts on failure**
```cron
# m h dom mon dow  command
30 1 * * * /opt/scripts/pg_dump_wrapper.sh --all --exclude-db 'postgres,test_*' -U backup_user -F d -j 4 -o /backups/pg -r 14 --verify --checksum --alert-email dba@example.com --alert-webhook https://hooks.slack.com/services/T000/B000/XXXX >/dev/null 2>&1
```
(The log is in `/backups/pg/pg_dump_wrapper.log`. The cron user needs a `~/.pgpass` entry, e.g. `*:5432:*:backup_user:secret`. For `--all`, use a role that can connect to every database and read all data: a superuser, or, on PG14+, a role with `pg_read_all_data` that has `CONNECT` on each database.)

**6b. Several named databases, stop at the first failure, report success too**
```bash
./pg_dump_wrapper.sh -d salesdb,hrdb -d inventory -U backup_user -o /backups/pg \
    --stop-on-error --alert-on always --alert-webhook "$SLACK_WEBHOOK_URL"
```

**6c. Structured JSON alerts to your own endpoint, and a test before relying on it**
```bash
./pg_dump_wrapper.sh --alert-test --alert-webhook https://ops.example.com/hooks/pg --alert-webhook-format json
./pg_dump_wrapper.sh --all -o /backups/pg --alert-webhook https://ops.example.com/hooks/pg --alert-webhook-format json
```

**7. Dry run: see the exact command without running it**
```bash
./pg_dump_wrapper.sh -d salesdb -F d -j 8 -N audit -r 7 --dry-run -- --lock-wait-timeout=30s
# pg_dump --host=localhost --port=5432 --username=... --dbname=salesdb --format=directory
#   --file=/backups/salesdb_20261010_093000.dir --no-password --jobs=8 --exclude-schema=audit --lock-wait-timeout=30s
```

**8. Config file plus a one-off override** (for a nightly job, `--config` + cron is usually all you need)
```bash
./pg_dump_wrapper.sh --config /etc/pg_backup/salesdb.conf                 # use the file as-is
./pg_dump_wrapper.sh --config /etc/pg_backup/salesdb.conf -F c -j 1 -s    # CLI wins: custom, schema-only
```

## Sample config file (`pg_dump_wrapper.conf.example`)
```ini
# pg_dump_wrapper.conf - key=value, '#' comments, quotes optional.
# Command-line options always override these values.
# List keys take comma-separated values.
# Passwords are NOT allowed here: use ~/.pgpass or pgpassfile=
# If you put webhook URLs here, chmod 600 this file (they contain secret tokens).

host=db01.internal
port=5432
user=backup_user
# pgpassfile=/etc/pg_backup/.pgpass

# --- which databases -------------------------------------------------------
# Either a list ...
dbnames=salesdb,hrdb
# ... or every connectable, non-template database:
# all=yes
# exclude_db=postgres,test_*        # globs, only used with all=yes
# maintenance_db=postgres           # where the database list is read from
stop_on_error=no                    # yes = stop at the first failed database

# --- format ------------------------------------------------------------------
format=directory          # plain | custom | directory | tar
jobs=4                    # >1 only valid for directory format
compress=6                # 0-9 or gzip:N / zstd:N / lz4 (pg_dump 16+)

# --- scope -------------------------------------------------------------------
# schemas=sales,hr
exclude_schemas=tmp
# tables=sales.orders
# exclude_tables=public.scratch_*
exclude_table_data=audit.event_log,public.*_log
no_owner=yes
no_privileges=no
# schema_only=no
# data_only=no
# clean=no
# if_exists=no
# create=no

# --- files -------------------------------------------------------------------
output_dir=/backups/postgres
# log_file=/var/log/pg_dump_wrapper.log
retention_days=14
min_free_mb=5120
verify=yes
checksum=yes
# verbose=no
# pg_bin=/usr/lib/postgresql/17/bin

# --- alerts ------------------------------------------------------------------
alert_on=failure                    # failure | always
alert_email=dba@example.com,oncall@example.com
# alert_from=pg-backups@example.com
# alert_webhook=https://hooks.slack.com/services/T000/B000/XXXXXXXX
alert_webhook_format=slack          # slack ({"text": ...}) | json (structured)
```
Boolean keys accept `yes/no`, `true/false`, `1/0`, and `on/off`. In list keys (`dbnames`, `exclude_db`, `schemas`, `exclude_schemas`, `tables`, `exclude_tables`, `exclude_table_data`, `alert_email`, `alert_webhook`), a CLI value **replaces** the config list instead of adding to it. Other alert keys: `alert_on`, `alert_webhook_format`, `alert_from`. Database keys: `all`, `exclude_db`, `maintenance_db`, `stop_on_error`. A `-d` on the command line overrides `all=yes` from the config, and `--all` overrides `dbnames=`.

## Notes and caveats
- Needs Bash ≥ 4.4 (5.x recommended), `pg_dump`, and `pg_restore`. `psql` and `pg_isready` are recommended for pre-checks, and `psql` is required for `--all`.
- `-d` must be a plain database name (not a `postgresql://` URI), because it's also used in the file name.
- Databases are dumped one after another, not in parallel. Use `-F d -j N` to parallelise inside each database.
- A superuser can connect even after `REVOKE CONNECT`. A non-superuser backup role will report such databases as `FAIL(2) precheck` under `--all`. Exclude them with `--exclude-db`.
- E-mail alerts need a working MTA behind `mail`/`sendmail` (postfix, exim, msmtp…). The wrapper only hands the message over. Webhook alerts need `curl`.
- Slack-format alerts wrap the report in a code block. Very long log lines are sent as-is, and Slack may truncate messages over about 40k characters.
- Your shell expands unquoted wildcards, so quote patterns: `-t 'sales.cust*'`.
- Retention uses file modification time (`find -mtime +N`) and only deletes entries matching the wrapper's own naming pattern.
- `--clean` and `--create` only change the SQL in **plain** dumps. For custom/dir/tar dumps, pass them to `pg_restore`.
- pg_dump takes a consistent snapshot but doesn't include roles or tablespaces. Use `pg_dumpall --globals-only` for those.
