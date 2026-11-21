# Changelog

## pg_dump_wrapper.sh

### 2.2.0 (2026-11-21)

**Added**
- `--per-table` (config `per_table=yes`): one pg_dump and one file per table, picked with `-t schema.table`
  (repeatable/comma list, wildcards) and/or `-n SCHEMA` (every table in it). It's an error without `-t`/`-n`,
  with `-f`, or with `-t`/`-n` after `--`.
- `--per-table-file-pattern` / `per_table_file_pattern=`: tokens `{db}` `{schema}` `{table}` `{date}` (required)
  and `{ext}` (appended if missing). Default `{db}_{schema}_{table}_{date}.{ext}`. Names are made safe for
  Linux and Windows file systems.
- `--verify`, `--checksum` and retention work per file. Retention only removes older files of the same table.
- The summary has one `db:schema.table` row per table. A table or schema missing in a database is a
  `FAIL(2) precheck` row with a clear message. The other tables still run (unless `--stop-on-error`), and the
  exit code is the worst of all rows.
- Works with several databases (`-d a,b` / `--all`). The table-size report is shown once per database for the
  selected tables.
- `--dry-run` lists one exact `--table="schema"."table"` command per table.

**Changed**
- Summary column widens for long `db:schema.table` labels.

### 2.1.0 (2026-11-21)

**Added**
- Table-size report before each database's dump: `schema.table`, total size including indexes and TOAST,
  and estimated rows (`reltuples`; `-` if never analyzed), largest first. It goes to the screen and the log,
  and is also shown in `--dry-run`.
- `--table-sizes N|all` and config key `table_sizes=` (also `table-sizes=`). Default 10; `0` = off; `all` = every table.
- With `-t`/`--table` (wrapper option or after `--`), only the matching tables are listed (`*`/`?` wildcards,
  quoted names, `schema.table`).
- System schemas (`pg_*`, `information_schema`) are excluded. CRLF output from Windows `psql.exe` is handled.
- The report never fails a run: with `--skip-precheck`, no `psql`, or a failing query it logs a warning instead.
- Config keys may now be written with `-` or `_` (`table-sizes` = `table_sizes`).
- With `-W`, `--dry-run` asks for the password when it needs to connect (for `--all` or the table-size report).

### 2.0.1 (2026-11-21)

Windows (Git Bash / MSYS2 / Cygwin) support. Behaviour on Linux is unchanged.

**Fixed**
- `--all` on Windows: `psql.exe` ends lines with CRLF, so every database name carried a hidden
  carriage return (`abc\r`). All but the last database failed the pre-check with
  `database "abc" does not exist`, and the names overwrote each other on screen. The CR is now
  stripped from all captured tool output: the database list, the server version and size check,
  the `pg_dump --version` check, `pg_restore --list` verification, `pg_dump` log lines, `df` and `hostname`.
- Database size check no longer fails on Windows (the size number ended with a CR).
- `-W` did not prompt: with `--all` the database listing failed with `fe_sendauth: no password supplied`,
  pre-checks were skipped, `pg_dump.exe` can't prompt in Git Bash/mintty, and a multi-database run would
  have asked once per database. The wrapper now asks **once** at the start (hidden typing, from the terminal),
  keeps the password in memory for that run only (`PGPASSWORD` for the wrapper and its child tools, unset on exit),
  runs the pre-checks again, and always passes `--no-password` to the tools. With no terminal (cron/Task Scheduler)
  it stops with exit code 1 and points to `~/.pgpass` / `--pgpassfile`; an empty answer is also exit code 1.
  The password is never written to logs, the printed command, the summary or alerts.

**Added**
- Windows paths for `-o/--output-dir`, `-l/--log-file`, `--pg-bin`, `--pgpassfile`, `--config` and the matching
  config keys: `C:\backups`, `C:/backups` and `/c/backups` all work, including paths with spaces.
  Unquoted `c:\backups` (which bash turns into `c:backups`) is accepted with a warning that explains quoting.
- Native Windows tools get `C:/...` paths for `--file`, `pg_restore --list` and `PGPASSFILE`.
- `pg_dump.exe` and friends are found in `--pg-bin` without the `.exe` suffix.
- `--checksum` falls back to `shasum -a 256` when `sha256sum` is not installed.
- `--file` names containing `\` are rejected on Windows (same rule as `/`).
- Free-space check reads the column before `Capacity`, so a filesystem name with spaces
  (`C:/Program Files/Git`) no longer hides the value. A failing `df` no longer stops the run.
- `tests/test_pg_dump_wrapper.sh`: end-to-end tests on a throwaway cluster, including a Windows
  simulation (CRLF tools, fake `cygpath`/`uname`, drive-letter paths).

### 2.0.0
- Multi-database runs (`-d a,b,c`, `--all`, `--exclude-db`), summary table, e-mail and webhook alerts.
