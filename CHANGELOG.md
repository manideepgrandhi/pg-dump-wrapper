# Changelog

## pg_dump_wrapper.sh

### 2.0.1 (2026-11-21)

Windows (Git Bash / MSYS2 / Cygwin) support. Behaviour on Linux is unchanged.

**Fixed**
- `--all` on Windows: `psql.exe` ends lines with CRLF, so every database name carried a hidden
  carriage return (`abc\r`). All but the last database failed the pre-check with
  `database "abc" does not exist`, and the names overwrote each other on screen. The CR is now
  stripped from all captured tool output: the database list, the server version and size check,
  the `pg_dump --version` check, `pg_restore --list` verification, `pg_dump` log lines, `df` and `hostname`.
- Database size check no longer fails on Windows (the size number ended with a CR).

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
