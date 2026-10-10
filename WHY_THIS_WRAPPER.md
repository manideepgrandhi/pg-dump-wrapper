# Why use pg_dump_wrapper.sh instead of plain pg_dump?

`pg_dump` is excellent at what it does: it takes a **consistent snapshot** of one
database while the database stays online, in a format that `psql` or `pg_restore` can
restore. But it is one building block. A *production* backup job needs more around it:
- predictable file names
- refusing to overwrite good backups
- checking the server before starting
- logs you can read the next morning
- removing half-written files
- proving the dump is readable
- pruning old copies
- handling many databases
- telling someone when it breaks

Usually that ends up as a home-grown shell script that's different on every server.
`pg_dump_wrapper.sh` (v2.0.0) is that script, written once, tested, and driven by options.

- Option reference: [README.md](README.md)
- Copy-paste recipes for every scenario: [EXAMPLES.md](EXAMPLES.md)

**Contents**
- [At a glance](#at-a-glance)
- [1. Safe, predictable output](#1-safe-predictable-output)
- [2. Fail early: validation and pre-checks](#2-fail-early-validation-and-pre-checks)
- [3. Credentials that work unattended](#3-credentials-that-work-unattended)
- [4. Observability: logs, summary, exit codes](#4-observability-logs-summary-exit-codes)
- [5. Trustworthy backups: verify, checksum, cleanup](#5-trustworthy-backups-verify-checksum-cleanup)
- [6. Retention without risk](#6-retention-without-risk)
- [7. Many databases in one run](#7-many-databases-in-one-run)
- [8. Alerts](#8-alerts)
- [9. Repeatable configuration and dry runs](#9-repeatable-configuration-and-dry-runs)
- [10. Before / after: a nightly all-database backup](#10-before--after-a-nightly-all-database-backup)
- [When plain pg_dump is enough, and limitations](#when-plain-pg_dump-is-enough-and-limitations)

---

## At a glance

| Capability | Plain `pg_dump` | `pg_dump_wrapper.sh` |
|---|---|---|
| Output file name | You choose it on every run | `DB_YYYYmmdd_HHMMSS.<ext>`, with the extension matched to the format and compression (`.dump`, `.dir`, `.tar`, `.sql`, `.sql.gz`, `.sql.zst`, `.sql.lz4`); `-f` to override |
| Existing file with the same name | **Silently overwritten** (plain/custom/tar); directory format errors if the folder exists | **Refused** (exit 1), so it never overwrites |
| File permissions | Follows your umask (typically `644`, world-readable) | `umask 077`: dumps, checksums and logs are owner-only (`600`/`700`) |
| Conflicting flags (`-s` + `-a`, `--if-exists` without `-c`, `-j` without directory format) | Rejected by pg_dump itself | Also rejected, **before connecting**, in one validation step, plus checks pg_dump can't do (`-f` with several DBs, `--retention-days 0`, bad compression spec, `-Z` with tar, invalid port, bad alert settings) |
| Server reachable? | You find out when the dump fails | `pg_isready` before anything starts |
| Auth / database exists / permission (CONNECT) | Error at dump time | `psql` login check per database, with a clear message |
| pg_dump older than the server | pg_dump refuses with "server version mismatch" | Detected up front, with a hint to use `--pg-bin DIR` to pick another client version |
| Disk space | Not checked | Free space logged; warns if below `--min-free-mb` or below the DB size |
| Password in unattended jobs | May prompt if a terminal is attached | Always `--no-password` (unless `-W`), never takes a password argument, rejects `password=` in config |
| Logging | Messages on stderr, no timestamps | Timestamped `[INFO]/[WARN]/[ERROR]/[PG_DUMP]` lines with `[db]` tags, to the console **and** a log file |
| Failure mid-dump | Leaves a partial/empty file or folder (e.g. a 0-byte `.dump`) | Partial output **removed** automatically |
| Ctrl-C / `kill` | pg_dump stops; partial output stays | pg_dump stopped, partial output removed, remaining DBs marked `SKIPPED`, alert sent, exit 130 |
| Verify the dump is readable | Manual (`pg_restore --list …`) | `--verify`: `pg_restore --list` for archives, footer check for `.sql` / `.sql.gz` |
| Checksums | Manual | `--checksum` writes `.sha256` (covering every file for directory format) |
| Retention | Manual `find … -delete` (easy to get dangerously wrong) | `-r N`: deletes only `DB_<date>_<time>.*` files, only that DB's, only after a successful dump, N ≥ 1 |
| Several databases | One pg_dump call per DB, scripted by you | `-d a,b -d c` or `--all` (+ `--exclude-db`), one file per DB, continues past failures (or `--stop-on-error`) |
| Run summary | – | Table of DB / status / failed stage / size / time / file |
| Exit codes | `0` OK / `1` anything wrong | `0` OK, `1` usage, `2` pre-check, `3` pg_dump, `4` verify/checksum, `5` retention, `130` interrupted |
| Alerts | – | E-mail (`mail`/`mailx`/`sendmail`) and webhooks (Slack-style or structured JSON), on failure or always, with the last 20 log lines |
| Config files | – (only `PG*` env vars / `.pgpass`) | `--config` key=value file that is parsed, never executed; CLI overrides it |
| Dry run | – | `--dry-run` prints the exact pg_dump command(s), shell-quoted |
| Multiple PostgreSQL versions | Call the right binary path yourself | `--pg-bin DIR` for pg_dump, pg_restore, psql and pg_isready |
| Every other pg_dump option | ✓ | ✓ Passed through unchanged after `--` |

---

## 1. Safe, predictable output

**Plain pg_dump:** you build the name yourself, and pg_dump silently replaces an existing
file with the same name (plain/custom/tar), so a fixed name or a copy-paste mistake overwrites the last good backup:
```bash
pg_dump -Fc -d salesdb -f /backups/salesdb.dump      # same name every night → previous backup is replaced
```

**Wrapper:**
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups
# → /backups/salesdb_20261010_013000.dump  (mode 600; refuses to run if that exact name already exists)
```
- The extension always matches what's inside (`-F p -Z zstd:9` → `.sql.zst`, `-F d` → `.dir`).
- The output directory is created if needed. Everything is written with `umask 077`, so dumps containing customer data aren't world-readable.
- `-f NAME` still lets you choose a fixed name (single database only), and it's also never overwritten.

## 2. Fail early: validation and pre-checks

pg_dump itself rejects some contradictory flags (for example `-j` without directory format,
or `-s` with `-a`). The wrapper repeats those checks and adds its own, **before** touching the
server, so a broken cron line fails in milliseconds with a precise message:
```
[ERROR] --jobs > 1 is only supported with --format directory (pg_dump limitation)
[ERROR] -f/--file can only be used with a single database
[ERROR] --retention-days must be >= 1 (refusing to delete everything)
```
Then, before dumping:

| Check | How | Failure → exit 2 with… |
|---|---|---|
| pg_dump installed | `command -v` (honours `--pg-bin`) | `pg_dump not found (install postgresql-client or use --pg-bin)` |
| Server up | `pg_isready -t 10` | `Server not accepting connections at host:port (pg_isready)` |
| Login, DB exists, CONNECT allowed | `psql -w -c 'SELECT …'` per database | `Cannot connect to database 'x' as 'y': FATAL: …` |
| Client ≥ server major version | compares `pg_dump --version` with `server_version_num` | `pg_dump major version 15 is older than server 17; use a newer pg_dump (--pg-bin)` |
| Disk space | `df` on the output dir vs `--min-free-mb` and the DB size | warning only |

The server version, database size and free space are logged, which helps capacity planning.

## 3. Credentials that work unattended

- The wrapper **never accepts a password as an argument**, because command lines are visible to every user through `ps`. A `password=` key in a config file is rejected.
- It passes `--no-password` to pg_dump and psql by default (pg_isready doesn't authenticate). A missing or wrong credential fails immediately with an auth error rather than waiting at a prompt. Use `-W` when you *want* an interactive prompt.
- Credentials come from the standard places: `~/.pgpass`, `--pgpassfile FILE` (sets `PGPASSFILE`), or `PGPASSWORD`. The wrapper never logs them.
- Webhook URLs, which contain secret tokens, are logged only as `https://host/...` and are handed to curl on stdin so they don't appear in `ps`.

## 4. Observability: logs, summary, exit codes

**Plain pg_dump:** silent on success, and an error message on stderr without timestamps. Under
cron that output goes to local mail or `/dev/null`.

**Wrapper:** every line goes to the console and to a log file
(`OUTPUT_DIR/pg_dump_wrapper.log` or `-l FILE`):
```
2026-10-10 01:30:00 [INFO] [salesdb] Connected: server_version_num=170011, database size=28 MB
2026-10-10 01:30:00 [INFO] [salesdb] Command: pg_dump --host=db01.example.com --port=5432 … --format=custom --file=/backups/salesdb_20261010_013000.dump --no-password
2026-10-10 01:30:01 [PG_DUMP] [salesdb] pg_dump: error: query failed: ERROR:  canceling statement due to statement timeout
2026-10-10 01:30:01 [ERROR] [salesdb] pg_dump failed with exit code 1
2026-10-10 01:30:01 [WARN] [salesdb] Removed partial output /backups/salesdb_20261010_013000.dump
```
Each run ends with a summary table:
```
DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
hrdb                     OK        -          4.0K     0m00s    /backups/hrdb_20261010_013000.dump
lockeddb                 FAIL(2)   precheck   -        0m00s    -
salesdb                  OK        -          4.5M     0m01s    /backups/salesdb_20261010_013001.dump
```
**Exit codes say *what* failed:** pg_dump returns `1` for everything. The wrapper returns
`1` usage, `2` pre-check, `3` pg_dump, `4` verify/checksum, `5` retention only (the backup itself is fine),
or `130` interrupted. A calling script, systemd (`SuccessExitStatus=5`) or a monitoring check can then react differently to each one.

## 5. Trustworthy backups: verify, checksum, cleanup

- **Partial output is removed.** When plain pg_dump fails part-way it can leave an empty or truncated file (we saw a 0-byte `.dump` after a lock timeout), which looks like a backup until you need it. The wrapper deletes the partial file or folder on failure, on Ctrl-C and on SIGTERM. It stops the running pg_dump first.
- **`--verify`** reads the archive back with `pg_restore --list` (custom/directory/tar) and logs the number of TOC entries. Plain `.sql`/`.sql.gz` dumps are checked for pg_dump's "dump complete" footer. A failed check gives exit 4.
- **`--checksum`** writes `<dump>.sha256`. For directory format it covers every file inside, so after copying offsite you can run `sha256sum -c` to detect corruption.

> Neither check replaces an occasional **test restore**. See [EXAMPLES.md §12.4](EXAMPLES.md#124-test-that-a-backup-actually-restores).

## 6. Retention without risk

A typical hand-written cleanup:
```bash
find /backups -mtime +14 -delete                      # also deletes logs, other DBs, hand-made dumps… and runs even if tonight's dump failed
```
**Wrapper:** `-r 14`
- Deletes only entries named `<thisdb>_YYYYmmdd_HHMMSS.*` (plus their `.sha256`) directly in the output directory. Custom-named dumps, other databases' files, logs and anything else are never touched.
- Runs **only after that database's new dump succeeded**, so a failing backup never erases the last good ones.
- Refuses `-r 0`. `--dry-run` prints the retention rule without deleting anything.

## 7. Many databases in one run

**Plain pg_dump:** one database per call. You need a loop, a query to list the databases,
error handling per iteration, and a way to report which ones failed.

**Wrapper:**
```bash
./pg_dump_wrapper.sh -d salesdb,hrdb -d inventory -o /backups        # explicit list
./pg_dump_wrapper.sh --all --exclude-db 'postgres,test_*' -o /backups   # everything connectable, minus globs
```
- `--all` reads `pg_database` and takes every database that allows connections and isn't a template. Use `--maintenance-db` if `postgres` isn't available.
- Each database runs in its own child process with its own pre-check, file, verify, checksum and retention. One failure doesn't affect the others' output.
- By default it continues after a failure. `--stop-on-error` stops and marks the rest `SKIPPED`.
- The overall exit code is the highest code among the failed databases, and the summary table shows exactly which one failed and at which stage.

## 8. Alerts

**Plain pg_dump:** nothing. You find out about a failed backup when you need to restore.

**Wrapper:** one combined alert per run, on failure (default) or always:
```bash
./pg_dump_wrapper.sh --all -o /backups \
    --alert-email dba@example.com,oncall@example.com --alert-from pg-backups@example.com \
    --alert-webhook https://hooks.slack.com/services/XXX/YYY/ZZZ
```
- **E-mail** goes through `mail`, `mailx` or `sendmail -t`. **Webhooks** go through curl with a timeout and retries. `--alert-webhook-format slack` sends a `{"text": …}` message that Slack/Teams/Google Chat-style incoming webhooks accept, and `json` sends a structured payload (status, exit code, failed stage, per-DB results, log tail) for your own tooling.
- On failure the alert contains the server, databases, exit code, which stage failed for which database, duration, output dir, the summary table and the **last 20 log lines**, so you can usually diagnose it from the alert alone.
- Validation errors alert too, so a broken config doesn't fail silently every night.
- `--alert-test` sends a test message to every target.
- A failing alert channel only logs a warning and **never changes the backup's exit code**.

## 9. Repeatable configuration and dry runs

- **Config files** (`--config FILE`): plain `key=value` with comments. The file is **parsed, never `source`d**, so a config file can't run commands. Unknown keys are errors, so typos don't get ignored. CLI options override config values, so one file can serve the nightly job and ad-hoc runs (`--config all.conf -d salesdb -F p -s`).
- **`--dry-run`** prints the exact, shell-quoted pg_dump command for each database and the retention rule, without dumping, deleting or alerting. Use it to review a change before it goes into cron.
- **`--pg-bin DIR`** picks a specific PostgreSQL client version for pg_dump, pg_restore, psql and pg_isready.
- **Nothing is hidden:** any pg_dump option the wrapper doesn't expose can be passed after `--` (`-- --lock-wait-timeout=60s --no-comments`), and the full command is logged.

---

## 10. Before / after: a nightly all-database backup

Goal: dump every database each night in directory format with 4 jobs, verify, checksum, keep 14 days,
and tell the team if anything fails.

### Before: plain pg_dump plus a hand-written script
```bash
#!/usr/bin/env bash
# nightly_backup.sh -- typical home-grown wrapper (simplified; still missing several things below)
set -u
umask 077
OUT=/backups/pg; LOG=$OUT/backup.log; TS=$(date +%Y%m%d_%H%M%S); FAILED=""
mkdir -p "$OUT"
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

pg_isready -h db01.example.com -q || { log "server down"; echo "server down" | mail -s "PG backup FAILED" dba@example.com; exit 1; }

for db in $(psql -h db01.example.com -U backup_user -w -At -d postgres \
            -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate"); do
  [[ $db == postgres || $db == test_* ]] && continue
  f="$OUT/${db}_${TS}.dir"
  log "dumping $db"
  if pg_dump -h db01.example.com -U backup_user -w -Fd -j 4 -d "$db" -f "$f" 2>>"$LOG" \
     && pg_restore --list "$f" >/dev/null 2>>"$LOG"; then
    (cd "$OUT" && find "$(basename "$f")" -type f -print0 | sort -z | xargs -0 sha256sum > "$f.sha256")
    find "$OUT" -maxdepth 1 -name "${db}_*" -mtime +14 -exec rm -rf {} +
  else
    rm -rf "$f"; FAILED="$FAILED $db"; log "FAILED: $db"
  fi
done

if [[ -n $FAILED ]]; then
  tail -n 20 "$LOG" | mail -s "PG backup FAILED:$FAILED" dba@example.com
  curl -s -X POST -H 'Content-Type: application/json' \
       -d "{\"text\": \"PG backup failed:$FAILED\"}" https://hooks.slack.com/services/XXX/YYY/ZZZ
  exit 1
fi
```
Even this version still has gaps. Every one of them is handled by the wrapper:
- pg_dump output isn't timestamped.
- Ctrl-C/SIGTERM leaves a partial folder.
- There's no auth or version pre-check per DB.
- Every failure is exit `1`.
- `${db}_*` would also match another database called `${db}_archive`.
- Database names with spaces break the `for` loop.
- The webhook URL is visible in `ps`.
- The Slack JSON isn't escaped.
- There's no summary table and no disk-space warning.
- A broken alert channel can't be told apart from a broken backup.

### After: one command (or one config file)
```bash
/opt/pg_dump_wrapper/pg_dump_wrapper.sh -h db01.example.com -U backup_user \
    --all --exclude-db 'postgres,test_*' -F d -j 4 -o /backups/pg \
    --verify --checksum -r 14 \
    --alert-email dba@example.com --alert-webhook https://hooks.slack.com/services/XXX/YYY/ZZZ
```
or, with the same settings in `/etc/pg_backup/all.conf`, a cron line of:
```cron
30 1 * * *  /opt/pg_dump_wrapper/pg_dump_wrapper.sh --config /etc/pg_backup/all.conf >/dev/null 2>&1
```
Check it once with `--dry-run` and `--alert-test`, then let it run.

---

## When plain pg_dump is enough, and limitations

**Plain pg_dump is the better choice when:**
- You're doing a **one-off manual dump**, e.g. `pg_dump -Fc mydb > mydb.dump` before trying something. The wrapper adds nothing important there.
- You're piping the dump straight into another command (`pg_dump … | psql -h other-host`) or over SSH. The wrapper always writes to a file.
- Another tool already orchestrates your backups (Kubernetes operators, managed-cloud snapshots, Ansible roles) and only needs the raw command.

**What the wrapper is *not*:**
- **Not point-in-time recovery.** Logical dumps restore to the moment the dump started. There's no WAL archiving, no PITR, no incremental or differential backups, and no block-level physical backups. For those, use **pgBackRest**, **Barman** or WAL-G (alongside or instead of logical dumps).
- **Not instant for very large databases.** pg_dump/pg_restore of multi-TB databases takes hours. Physical backup tools scale better there.
- **Not a full-cluster dump.** Roles, role memberships and tablespaces aren't in a per-database pg_dump. Add `pg_dumpall --globals-only` (see [EXAMPLES.md §9.5](EXAMPLES.md#95-roles-and-tablespaces)).

**Practical limitations:**
- Needs **Bash ≥ 4.4** (5.x recommended), plus `pg_dump`/`pg_restore`. `psql` and `pg_isready` are needed for the pre-checks and `--all`. Webhook alerts need `curl`.
- Databases are dumped **one after another**. `-j` parallelises tables *within* a database (directory format), not across databases.
- **E-mail alerts need a working MTA** behind `mail`/`sendmail` (postfix, exim, msmtp…). The wrapper only hands the message over. Webhooks are often the simpler choice.
- `-d` takes plain database names, not `postgresql://` connection URIs (the name becomes part of the file name).
- `--verify` checks that the archive is readable and complete. It doesn't restore the dump. Schedule a periodic test restore.
- Retention uses file modification times (`find -mtime`), so copying files with tools that reset mtimes affects what counts as "old".
- pg_dump options without a wrapper flag are passed through after `--` without being validated by the wrapper. pg_dump reports any mistakes (exit 3). Use `--dry-run` to review them.

---

See also: [README.md](README.md) (all options, exit codes, config keys) · [EXAMPLES.md](EXAMPLES.md) (91 recipes incl. cron/systemd and restores)
