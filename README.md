# pg_dump_wrapper.sh

A Bash wrapper around PostgreSQL `pg_dump` that adds safe defaults, validation, logging,
pre-checks, verification, checksums, and retention, so one command (or one cron line)
produces a reliable, consistently named backup.

```
pg_dump_wrapper.sh -d DBNAME [options] [-- extra pg_dump args]
```

Settings are applied in this order (later ones win): **built-in defaults → `--config` file → command line**.

## Options

### Connection
| Option | pg_dump flag | Purpose |
|---|---|---|
| `-h, --host HOST` | `--host` | Server hostname or Unix socket directory. Default: `$PGHOST`, otherwise `localhost`. (`-h` means host here, just like in pg_dump. Use `--help` for help.) |
| `-p, --port PORT` | `--port` | Server port. Default: `$PGPORT`, otherwise `5432`. |
| `-U, --user USER` | `--username` | Role to connect as. Default: `$PGUSER`, otherwise `$USER`. |
| `-d, --dbname DB` | `--dbname` | **Required.** The database to back up. It's also used in the output file name. |
| `-W, --password` | `--password` | Forces a password prompt (interactive use only). Without it the wrapper passes `--no-password`, so cron jobs fail fast instead of hanging. |
| `--pgpassfile FILE` | env `PGPASSFILE` | Reads the password from this `.pgpass` file. |

**Passwords are never accepted on the command line**, because other users can see command arguments in `ps`. Use `~/.pgpass` (chmod 600), `--pgpassfile`, or the `PGPASSWORD` environment variable. The wrapper never prints or logs the password.

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
| `-f, --file NAME` | Overrides the generated name. Default: `DB_YYYYmmdd_HHMMSS.<ext>` (`.dump`, `.dir`, `.tar`, `.sql[.gz]`). An existing file is never overwritten. |
| `-l, --log-file FILE` | Log file. Every line is timestamped and also printed to the console (stderr). pg_dump's own messages are logged with the `[PG_DUMP]` tag. Default: `OUTPUT_DIR/pg_dump_wrapper.log`. |
| `-r, --retention-days N` | After a **successful** backup, deletes entries in OUTPUT_DIR older than N days, but **only** ones whose names match `DB_<8 digits>_<6 digits>.*`. Other files, other databases, and custom-named dumps are never touched. N must be ≥ 1. |
| `--min-free-mb N` | Warns when free space in OUTPUT_DIR is below N MB. Default: 1024. It also warns if the DB is larger than the free space. |

### Behaviour
| Option | Purpose |
|---|---|
| `--config FILE` | Loads `key=value` settings (see the sample below). The file is parsed, never `source`d or executed, and unknown keys are an error. |
| `--verify` | After the dump, runs `pg_restore --list` for custom/tar/directory dumps. For plain dumps it checks the file isn't empty and ends with pg_dump's "dump complete" footer. |
| `--checksum` | Writes `<dump>.sha256`. For directory format it covers every file in the directory. Check later with `cd OUTPUT_DIR && sha256sum -c <dump>.sha256`. |
| `--dry-run` | Validates everything and prints the exact `pg_dump` command (shell-quoted), then exits without connecting, writing, or deleting anything. |
| `--skip-precheck` | Skips the pg_isready, psql connectivity, version, and disk-space checks. |
| `--pg-bin DIR` | Uses `pg_dump`, `pg_restore`, `psql`, and `pg_isready` from DIR, e.g. `/usr/lib/postgresql/17/bin`. |
| `-v, --verbose` | Debug logging, and passes `--verbose` to pg_dump. |
| `--help`, `--version` | Shows help or the version. |
| `-- ARGS…` | Passes anything after `--` straight to pg_dump, e.g. `-- --lock-wait-timeout=30s --no-comments`. |

### What happens on every run
1. Arguments and config are validated (conflicting flags, `-j` only with directory format, port, compression, and so on).
2. Pre-checks: pg_dump exists and its version is logged, `pg_isready` succeeds, a `psql` login works, and the server version and DB size are logged. The run fails if pg_dump is older than the server. Free disk space is checked.
3. pg_dump runs with `--no-password` and its output streams into the log.
4. If pg_dump fails, or the run is interrupted (Ctrl-C / SIGTERM), pg_dump is stopped and the **partial file or directory is removed**.
5. Optional verify, then checksum, then retention.

Files are created with `umask 077` (owner-only permissions).

### Exit codes
| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Usage or validation error (bad or conflicting options, output already exists) |
| 2 | Pre-check failed (pg_dump missing, server down, auth or DB-not-found, version mismatch) |
| 3 | pg_dump failed (partial output removed) |
| 4 | Verification or checksum failed |
| 5 | Retention cleanup failed (the backup itself is fine) |
| 130 | Interrupted by a signal |

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

**6. Nightly cron job with 14-day retention**
```cron
# m h dom mon dow  command
30 1 * * * /opt/scripts/pg_dump_wrapper.sh -d salesdb -U backup_user -F d -j 4 -o /backups/salesdb -r 14 --verify --checksum >/dev/null 2>&1 || echo "salesdb backup failed rc=$?" | mail -s "PG backup FAILED" dba@example.com
```
(The log is in `/backups/salesdb/pg_dump_wrapper.log`. cron needs `~/.pgpass` for the cron user.)

**7. Dry run: see the exact command without running it**
```bash
./pg_dump_wrapper.sh -d salesdb -F d -j 8 -N audit -r 7 --dry-run -- --lock-wait-timeout=30s
# pg_dump --host=localhost --port=5432 --username=... --dbname=salesdb --format=directory
#   --file=/backups/salesdb_20261010_093000.dir --no-password --jobs=8 --exclude-schema=audit --lock-wait-timeout=30s
```

**8. Config file plus a one-off override**
```bash
./pg_dump_wrapper.sh --config /etc/pg_backup/salesdb.conf                 # use the file as-is
./pg_dump_wrapper.sh --config /etc/pg_backup/salesdb.conf -F c -j 1 -s    # CLI wins: custom, schema-only
```

## Sample config file (`pg_dump_wrapper.conf.example`)
```ini
# key=value, '#' comments (also inline after a space), quotes optional.
# List keys take comma-separated values. CLI options override these values.
host=db01.internal
port=5432
user=backup_user
dbname=salesdb
# pgpassfile=/etc/pg_backup/.pgpass      # 'password=' is deliberately rejected

format=directory          # plain | custom | directory | tar
jobs=4                    # >1 only valid for directory format
compress=6

# schemas=sales,hr
exclude_schemas=tmp
# tables=sales.orders
# exclude_tables=public.scratch_*
exclude_table_data=audit.event_log,public.*_log

no_owner=yes
no_privileges=no
# schema_only / data_only / clean / if_exists / create = yes|no

output_dir=/backups/postgres/salesdb
# log_file=/var/log/pg_dump_wrapper.log
retention_days=14
min_free_mb=5120
verify=yes
checksum=yes
# verbose=no
# pg_bin=/usr/lib/postgresql/17/bin
```
Boolean keys accept `yes/no`, `true/false`, `1/0`, and `on/off`. In list keys (`schemas`, `exclude_schemas`, `tables`, `exclude_tables`, `exclude_table_data`), a CLI value **replaces** the config list instead of adding to it.

## Notes and caveats
- Needs Bash ≥ 4.4 (5.x recommended), `pg_dump`, and `pg_restore`. `psql` and `pg_isready` are optional but recommended for pre-checks.
- `-d` must be a plain database name (not a `postgresql://` URI), because it's also used in the file name.
- Your shell expands unquoted wildcards, so quote patterns: `-t 'sales.cust*'`.
- Retention uses file modification time (`find -mtime +N`) and only deletes entries matching the wrapper's own naming pattern.
- `--clean` and `--create` only change the SQL in **plain** dumps. For custom/dir/tar dumps, pass them to `pg_restore`.
- pg_dump takes a consistent snapshot but doesn't include roles or tablespaces. Use `pg_dumpall --globals-only` for those.
