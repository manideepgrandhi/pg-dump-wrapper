# pg_dump_wrapper.sh: usage examples (v2.0.0)

These are copy-paste recipes for every feature of `pg_dump_wrapper.sh`. Each example has
**when to use it**, **the command**, and **what you get**. Where it makes sense, there's also the matching **restore** command.
For the full option reference, see [README.md](README.md).

All hosts, users, e-mail addresses and webhook URLs below are placeholders
(`db01.example.com`, `backup_user`, `dba@example.com`, `hooks.slack.com/services/XXX`).
Replace them with your own values.

## Contents
1. [Before you start](#1-before-you-start)
2. [Passwords and authentication](#2-passwords-and-authentication)
3. [Connecting: host, port, socket, user](#3-connecting-host-port-socket-user)
4. [Output formats (with restore)](#4-output-formats-with-restore)
5. [Compression](#5-compression)
6. [Schema-only and data-only](#6-schema-only-and-data-only)
7. [Choosing schemas and tables](#7-choosing-schemas-and-tables)
8. [Ownership and privileges](#8-ownership-and-privileges)
9. [Migrating to another server (clean / if-exists / create)](#9-migrating-to-another-server-clean--if-exists--create)
10. [Output directory, file name, log file](#10-output-directory-file-name-log-file)
11. [Retention (auto-delete old backups)](#11-retention-auto-delete-old-backups)
12. [Verification and checksums](#12-verification-and-checksums)
13. [Dry run](#13-dry-run)
14. [Passing extra pg_dump options (`--`)](#14-passing-extra-pg_dump-options---)
15. [Config files](#15-config-files)
16. [Several PostgreSQL versions (`--pg-bin`)](#16-several-postgresql-versions---pg-bin)
17. [Multiple databases](#17-multiple-databases)
18. [Alerts: e-mail and webhooks](#18-alerts-e-mail-and-webhooks)
19. [Scheduling: cron and systemd](#19-scheduling-cron-and-systemd)
20. [Calling the wrapper from another script (exit codes)](#20-calling-the-wrapper-from-another-script-exit-codes)
21. [Common errors and what you'll see](#21-common-errors-and-what-youll-see)
22. [Restore recipes](#22-restore-recipes)

---

## 1. Before you start

### 1.1 Install the script
**When:** first-time setup on a backup host.
```bash
sudo install -d /opt/pg_dump_wrapper
sudo install -m 0755 pg_dump_wrapper.sh /opt/pg_dump_wrapper/
./pg_dump_wrapper.sh --version
./pg_dump_wrapper.sh --help
```
**Notes:** Needs Bash ≥ 4.4 and `pg_dump`/`pg_restore`. `psql` and `pg_isready` are needed for pre-checks and `--all`. Help is `--help`, not `-h`. As in pg_dump, `-h` means *host*.

### 1.2 A dedicated backup role (recommended)
**When:** you don't want backups to run as a superuser.
```sql
-- as a superuser, PostgreSQL 14+
CREATE ROLE backup_user LOGIN PASSWORD 'change-me' IN ROLE pg_read_all_data;
GRANT CONNECT ON DATABASE salesdb TO backup_user;   -- only needed if CONNECT was revoked from PUBLIC
```
**Notes:** `pg_read_all_data` can read every table but can't change anything.

---

## 2. Passwords and authentication
The wrapper **never** accepts a password as an argument. It always passes `--no-password` to pg_dump unless you ask for a prompt with `-W`, so unattended runs fail fast instead of hanging.

### 2.1 `~/.pgpass` (best for cron)
**When:** scheduled or unattended backups.
```bash
echo 'db01.example.com:5432:*:backup_user:change-me' >> ~/.pgpass
chmod 600 ~/.pgpass
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -o /backups
```
**Result:** `/backups/salesdb_YYYYmmdd_HHMMSS.dump`. The format is `host:port:database:user:password`, and `*` is a wildcard.

### 2.2 A separate pgpass file (`--pgpassfile`)
**When:** a service account or a shared backup host where each job has its own credentials file.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -o /backups --pgpassfile /etc/pg_backup/pgpass
```
**Notes:** Sets `PGPASSFILE` for pg_dump, psql and pg_isready. The file must be readable and should be `chmod 600`.

### 2.3 `PGPASSWORD` environment variable
**When:** quick one-offs, or a CI job where the secret comes from a vault or masked variable.
```bash
PGPASSWORD="$DB_PASSWORD" ./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -o /backups
```
**Notes:** Don't type the literal password into an interactive shell, because it ends up in history. Prefer `.pgpass`.

### 2.4 Interactive prompt (`-W`)
**When:** a manual run from a terminal with no stored credentials.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -o /backups -W
```
**Notes:** pg_dump asks for the password. The psql connectivity pre-check is skipped in this mode (pg_isready still runs). Don't use `-W` in cron.

---

## 3. Connecting: host, port, socket, user

### 3.1 Remote host, default port
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -o /backups
```

### 3.2 Non-default port
**When:** several clusters on one server, or PgBouncer/HAProxy in front.
```bash
./pg_dump_wrapper.sh -h db01.example.com -p 5433 -U backup_user -d salesdb -o /backups
```
**Notes:** Dump directly from PostgreSQL rather than through PgBouncer in transaction-pooling mode.

### 3.3 Local Unix socket (peer/trust auth, no password)
**When:** the backup runs on the DB server itself as the `postgres` OS user.
```bash
sudo -u postgres ./pg_dump_wrapper.sh -h /var/run/postgresql -U postgres -d salesdb -o /var/backups/pg
```
**Notes:** Pass the socket *directory* to `-h`.

### 3.4 Environment defaults (`PGHOST`, `PGPORT`, `PGUSER`)
**When:** you already export these in your profile.
```bash
export PGHOST=db01.example.com PGPORT=5432 PGUSER=backup_user
./pg_dump_wrapper.sh -d salesdb -o /backups
```

### 3.5 Long-option and `--opt=value` style
**When:** you want self-documenting scripts. Every option has a long form.
```bash
./pg_dump_wrapper.sh --host=db01.example.com --port=5432 --user=backup_user --dbname=salesdb --format=custom --output-dir=/backups
```

---

## 4. Output formats (with restore)

| Format | `-F` | Extension | Restore with | Parallel dump | Selective restore |
|---|---|---|---|---|---|
| plain | `p` | `.sql` (`.sql.gz`/`.zst`/`.lz4` if compressed) | `psql` | no | no |
| custom (default) | `c` | `.dump` | `pg_restore` | no | yes |
| directory | `d` | `.dir` (a folder) | `pg_restore` | **yes (`-j`)** | yes |
| tar | `t` | `.tar` | `pg_restore` | no | yes |

### 4.1 Custom format (default, recommended for most backups)
**When:** everyday backups. It's compressed, and you can restore single tables from it.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -o /backups
```
**Result:** `/backups/salesdb_20261010_013000.dump`
**Restore:**
```bash
createdb -h db02.example.com -U postgres salesdb_restored
pg_restore -h db02.example.com -U postgres -d salesdb_restored /backups/salesdb_20261010_013000.dump
```

### 4.2 Plain SQL
**When:** you want a human-readable script, or need to edit or grep it before applying.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F plain -o /backups
```
**Result:** `/backups/salesdb_20261010_013000.sql`
**Restore:**
```bash
psql -h db02.example.com -U postgres -d salesdb_restored -v ON_ERROR_STOP=1 -f /backups/salesdb_20261010_013000.sql
```

### 4.3 Plain SQL, gzip-compressed
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F p -Z 6 -o /backups
```
**Result:** `salesdb_….sql.gz`
**Restore:** `gunzip -c /backups/salesdb_….sql.gz | psql -h db02.example.com -U postgres -d salesdb_restored -v ON_ERROR_STOP=1`

### 4.4 Plain SQL, zstd or lz4 (pg_dump 16+)
**When:** zstd compresses better and faster than gzip. lz4 is the fastest but compresses the least.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F p -Z zstd:9 -o /backups
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F p -Z lz4 -o /backups
```
**Result:** `salesdb_….sql.zst` / `salesdb_….sql.lz4`
**Restore:** `zstd -dc file.sql.zst | psql -d target` / `lz4 -dc file.sql.lz4 | psql -d target` (needs the `zstd` / `lz4` command-line tools, e.g. `apt install zstd lz4`)
**Notes:** `--verify` can only check the footer of `.sql` and `.sql.gz` files. For zstd and lz4 it logs that the check was skipped.

### 4.5 Directory format with parallel jobs (large databases)
**When:** big databases where dump time matters. Each table is written by one of N workers.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F directory -j 8 -o /backups
```
**Result:** a folder `/backups/salesdb_20261010_013000.dir/` (`toc.dat` + one `NNNN.dat.gz` per table).
**Restore (parallel too):**
```bash
pg_restore -h db02.example.com -U postgres -d salesdb_restored -j 8 /backups/salesdb_20261010_013000.dir
```
**Notes:** `-j` > 1 is rejected for any other format. Each job uses one DB connection, so keep N ≤ the CPU count and below `max_connections`.

### 4.6 Tar format
**When:** you need a single standard archive file that tar tools can inspect.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F t -o /backups
```
**Result:** `salesdb_….tar` (uncompressed. `-Z` is rejected for tar.)
**Restore:** `pg_restore -h db02.example.com -U postgres -d salesdb_restored /backups/salesdb_….tar`

---

## 5. Compression

### 5.1 Compression levels
**When:** you're trading CPU for disk space. `0` = none, `1` = fastest, `9` = smallest.
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -Z 0
./pg_dump_wrapper.sh -d salesdb -o /backups -Z 1
./pg_dump_wrapper.sh -d salesdb -o /backups -Z 9
```

### 5.2 Choosing the method (pg_dump 16+)
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -F custom -Z zstd:5
./pg_dump_wrapper.sh -d salesdb -o /backups -F directory -j 4 -Z lz4
./pg_dump_wrapper.sh -d salesdb -o /backups -F custom -Z gzip:9
./pg_dump_wrapper.sh -d salesdb -o /backups -F custom -Z none
```
**Notes:** Accepted values are `0-9`, `gzip[:N]`, `zstd[:N]`, `lz4[:N]` and `none`. Older pg_dump versions (≤ 15) only accept the numeric form.

---

## 6. Schema-only and data-only

### 6.1 Schema-only (DDL)
**When:** keeping DDL in version control, building an empty copy for testing, or diffing schemas between environments.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F p -s -f salesdb_schema.sql -o /backups/schema
```
**Result:** `/backups/schema/salesdb_schema.sql` with tables, indexes, views, functions, and no rows.
**Apply:** `psql -d empty_db -v ON_ERROR_STOP=1 -f /backups/schema/salesdb_schema.sql`

### 6.2 Data-only
**When:** the schema already exists on the target and you only need the rows, e.g. to refresh a staging DB.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -a -o /backups
```
**Restore:** `pg_restore -d staging_db --data-only --disable-triggers /backups/salesdb_….dump` (`--disable-triggers` needs superuser and avoids foreign-key ordering problems).
**Notes:** `-s` and `-a` together are rejected, and so is `-a` with `-c`.

---

## 7. Choosing schemas and tables
`-n`, `-N`, `-t`, `-T` and `--exclude-table-data` can be **repeated** or given a **comma list**. Patterns use pg_dump wildcards (`*`, `?`). **Quote them** so your shell doesn't expand them.

### 7.1 Only some schemas
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -n sales -n hr
./pg_dump_wrapper.sh -d salesdb -o /backups -n sales,hr
```

### 7.2 All schemas except some
**When:** skipping scratch, staging or temporary schemas.
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -N audit -N 'tmp_*'
```

### 7.3 Only specific tables
**When:** a quick copy of a few tables before a risky change.
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups/adhoc -t sales.orders -t sales.customers
```
**Restore just one table from it:** `pg_restore -d salesdb_copy -n sales -t orders /backups/adhoc/salesdb_….dump`. The target database must already have the `sales` schema (`CREATE SCHEMA IF NOT EXISTS sales;`).

### 7.4 Tables by wildcard
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -t 'sales.cust*' -t 'public.report_202?'
```

### 7.5 Exclude whole tables
**When:** dropping obsolete or temporary tables from the backup completely (no structure, no data).
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -T public.tmp_import -T 'public.bak_*'
```

### 7.6 Keep the structure but skip the rows of huge tables
**When:** log, audit, event or session tables that are large and can be rebuilt. The restored DB still has the (empty) tables, so the application starts.
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups --exclude-table-data audit.event_log --exclude-table-data 'public.*_log'
```

### 7.7 Combining filters
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -n sales,hr -T sales.tmp_orders --exclude-table-data hr.login_history
```

---

## 8. Ownership and privileges

### 8.1 No owners (restore as whoever runs the restore)
**When:** the target server doesn't have the same roles, e.g. a developer laptop or a managed cloud DB.
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -O
```

### 8.2 No GRANT/REVOKE
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -x
```

### 8.3 Both (portable dump)
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -O -x
```
**Notes:** For custom/directory/tar dumps you can also decide this at restore time with `pg_restore --no-owner --no-privileges`.

---

## 9. Migrating to another server (clean / if-exists / create)
`-c`, `--if-exists` and `-C` change the SQL in **plain** dumps. For archive formats they're only restore hints, and the wrapper warns about that. Pass them to `pg_restore` instead.

### 9.1 Self-contained script that creates the database
**When:** moving a database to a new server in one step.
```bash
./pg_dump_wrapper.sh -h old-db.example.com -U backup_user -d salesdb -F p -C -O -x -f salesdb_migrate.sql -o /migrate
```
**Restore:** connect to *any* database (e.g. `postgres`). The script creates `salesdb` and connects to it:
```bash
psql -h new-db.example.com -U postgres -d postgres -v ON_ERROR_STOP=1 -f /migrate/salesdb_migrate.sql
```

### 9.2 Re-runnable script that replaces existing objects
**When:** refreshing an existing copy repeatedly. DROP … IF EXISTS runs before each CREATE.
```bash
./pg_dump_wrapper.sh -h old-db.example.com -U backup_user -d salesdb -F p -c --if-exists -O -f salesdb_refresh.sql -o /migrate
```
**Restore:** `psql -h new-db.example.com -U app_owner -d salesdb -v ON_ERROR_STOP=1 -f /migrate/salesdb_refresh.sql`

### 9.3 Drop and recreate the whole database
```bash
./pg_dump_wrapper.sh -h old-db.example.com -U backup_user -d salesdb -F p -c --if-exists -C -f salesdb_full.sql -o /migrate
```
**Restore:** `psql -h new-db.example.com -U postgres -d postgres -f /migrate/salesdb_full.sql`. This **drops the target's salesdb first**.

### 9.4 Same idea with a custom-format dump
```bash
./pg_dump_wrapper.sh -h old-db.example.com -U backup_user -d salesdb -F c -o /migrate
pg_restore -h new-db.example.com -U postgres -d postgres --create --clean --if-exists --no-owner /migrate/salesdb_….dump
```

### 9.5 Roles and tablespaces
pg_dump doesn't include roles or tablespaces. Copy them once with:
```bash
pg_dumpall -h old-db.example.com -U postgres --globals-only > globals.sql
psql -h new-db.example.com -U postgres -d postgres -f globals.sql
```

---

## 10. Output directory, file name, log file

### 10.1 Output directory (created if missing)
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups/postgres/salesdb
```
**Result:** `/backups/postgres/salesdb/salesdb_YYYYmmdd_HHMMSS.dump`. Without `-o` the current directory is used.

### 10.2 Custom file name (single database only)
**When:** a fixed, meaningful name, e.g. before a release.
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -f salesdb_before_release_42.dump
```
**Notes:** An existing file is **never overwritten** (exit 1). Custom names are **never deleted by retention**. `-f` only takes a bare file name and is rejected with several databases.

### 10.3 Separate log file
**When:** keeping all job logs in `/var/log`.
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -l /var/log/pg_backup/salesdb.log
```
**Notes:** The default is `OUTPUT_DIR/pg_dump_wrapper.log`. Every line is timestamped and tagged `[INFO]`, `[WARN]`, `[ERROR]` or `[PG_DUMP]` plus `[dbname]`, and is also printed to stderr.

### 10.4 Verbose (debug + pg_dump `--verbose`)
**When:** troubleshooting slow or failing dumps.
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -v
```

### 10.5 Low-disk warning threshold
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups --min-free-mb 20480
```
**Notes:** Logs a warning (it doesn't fail) if free space in `/backups` is below 20 GB, or below the DB size.

---

## 11. Retention (auto-delete old backups)

### 11.1 Keep 14 days
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -r 14
```
**What gets deleted:** only entries directly in `/backups` named `salesdb_YYYYmmdd_HHMMSS.*` (files, `.dir` folders and their `.sha256`) whose modification time is older than 14 days. This only happens **after the new backup succeeds**.
**What never gets deleted:** other databases' files, custom names (`-f`), the log file, anything else in the folder.

### 11.2 Retention for many databases at once
```bash
./pg_dump_wrapper.sh -d salesdb,hrdb,inventory -o /backups -r 7
```
**Notes:** Each database cleans up only its own files, and only if its own dump succeeded.

### 11.3 Preview what retention would do
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -r 14 --dry-run
find /backups -maxdepth 1 -name 'salesdb_[0-9]*_[0-9]*.*' -mtime +14
```

---

## 12. Verification and checksums

### 12.1 Verify after dumping
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups --verify
```
**What's checked:** custom/directory/tar dumps must be readable with `pg_restore --list`, and the TOC entry count is logged. Plain `.sql`/`.sql.gz` dumps must be non-empty and end with pg_dump's "dump complete" footer. A failed check gives exit code 4.

### 12.2 Write a SHA-256 checksum
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups --checksum
```
**Result:** `salesdb_….dump.sha256` next to the dump. For directory format it lists every file inside the `.dir` folder.

### 12.3 Validate a checksum later (e.g. after copying offsite)
```bash
cd /backups && sha256sum -c salesdb_20261010_013000.dump.sha256
cd /backups && sha256sum -c salesdb_20261010_013000.dir.sha256
```
**Expected output:** `salesdb_20261010_013000.dump: OK`. Run it from the directory that contains the dump, because the paths are relative.

### 12.4 Test that a backup actually restores
**When:** regularly, e.g. weekly. A backup you have never restored is only a hope.
```bash
createdb restore_test && pg_restore -d restore_test -j 4 /backups/salesdb_….dump && psql -d restore_test -c 'SELECT count(*) FROM sales.orders' && dropdb restore_test
```

---

## 13. Dry run

### 13.1 Preview the exact pg_dump command
**When:** checking a new command or config before it runs. It prints the exact pg_dump command(s) and touches nothing (no dump, no deletion, no alert). With `--all` it connects once to list the databases.
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F d -j 4 -N audit -r 7 --dry-run
```
**Output:**
```
2026-10-10 10:00:00 [INFO] DRY RUN - pg_dump would be executed as:
pg_dump --host=db01.example.com --port=5432 --username=backup_user --dbname=salesdb --format=directory --file=/backups/salesdb_20261010_100000.dir --no-password --jobs=4 --exclude-schema=audit
2026-10-10 10:00:00 [INFO] DRY RUN - would delete <db>_YYYYmmdd_HHMMSS.* in /backups older than 7 days
```

---

## 14. Passing extra pg_dump options (`--`)
Anything after `--` goes to pg_dump unchanged, for pg_dump options the wrapper doesn't have its own flag for.

### 14.1 Don't wait forever for table locks
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -- --lock-wait-timeout=60s
```

### 14.2 Several extra flags
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -- --no-comments --no-publications --no-subscriptions --no-security-labels
```

### 14.3 Exclude extensions, or dump large objects only when needed
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups -- --exclude-extension=postgis --no-blobs
```
**Notes:** `--exclude-extension` needs pg_dump 17+. The wrapper doesn't validate pass-through flags, so pg_dump reports any mistake (exit 3). Check them with `--dry-run` first.

---

## 15. Config files
`key=value` lines, `#` comments (also inline after a space), and optional quotes. The file is parsed, never executed. Unknown keys are an error. **Command-line options always win.** See `pg_dump_wrapper.conf.example` for every key.

### 15.1 Minimal config
```ini
# /etc/pg_backup/salesdb.conf
host=db01.example.com
user=backup_user
dbnames=salesdb
format=custom
output_dir=/backups/salesdb
retention_days=14
verify=yes
checksum=yes
alert_email=dba@example.com
```
```bash
./pg_dump_wrapper.sh --config /etc/pg_backup/salesdb.conf
```

### 15.2 Override one setting for a single run
```bash
./pg_dump_wrapper.sh --config /etc/pg_backup/salesdb.conf -F p -s -f salesdb_schema_today.sql
./pg_dump_wrapper.sh --config /etc/pg_backup/salesdb.conf -o /mnt/usb/backups --alert-on always
```
**Notes:** List options given on the CLI **replace** the config list. With `dbnames=salesdb`, passing `-d hrdb` dumps only `hrdb`. `-d` on the CLI also overrides `all=yes`, and `--all` overrides `dbnames=`.

### 15.3 Whole-server config with alerts
```ini
# /etc/pg_backup/all.conf   (chmod 600, it contains a webhook secret)
host=db01.example.com
user=backup_user
pgpassfile=/etc/pg_backup/pgpass
all=yes
exclude_db=postgres,test_*
format=directory
jobs=4
output_dir=/backups/pg
retention_days=14
verify=yes
checksum=yes
alert_on=failure
alert_email=dba@example.com,oncall@example.com
alert_from=pg-backups@example.com
alert_webhook=https://hooks.slack.com/services/XXX/YYY/ZZZ
alert_webhook_format=slack
```
```bash
./pg_dump_wrapper.sh --config /etc/pg_backup/all.conf
./pg_dump_wrapper.sh --config=/etc/pg_backup/all.conf --dry-run
```

---

## 16. Several PostgreSQL versions (`--pg-bin`)
pg_dump must be the **same or a newer major version** than the server. The wrapper checks this and fails with exit 2 if pg_dump is older. Debian and Ubuntu install each version under `/usr/lib/postgresql/<ver>/bin`.

### 16.1 Use a specific client version
```bash
./pg_dump_wrapper.sh --pg-bin /usr/lib/postgresql/17/bin -h db-new.example.com -U backup_user -d salesdb -o /backups
```

### 16.2 Different servers, different binaries
```bash
./pg_dump_wrapper.sh --pg-bin /usr/lib/postgresql/13/bin -h legacy-db.example.com -d erp -o /backups/legacy
./pg_dump_wrapper.sh --pg-bin /usr/lib/postgresql/17/bin -h db01.example.com -d salesdb -o /backups
```
**Notes:** A newer pg_dump can dump an older server, so a single v17 client usually covers all of them. `pg_restore`, `psql` and `pg_isready` are also taken from `--pg-bin`.

---

## 17. Multiple databases
Each database gets its own file with the usual name and is checked, verified, checksummed and retention-cleaned on its own. One summary table and one alert are produced per run. By default the wrapper **continues past failures**. The exit code is the highest code of any failed database.

### 17.1 A list with repeated `-d`
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -d hrdb -d inventory -o /backups
```

### 17.2 A comma list (mixable with repeats)
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb,hrdb -d inventory -o /backups
```
**Summary in the log:**
```
DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
salesdb                  OK        -          4.5M     0m01s    /backups/salesdb_20261010_013000.dump
hrdb                     OK        -          4.0K     0m00s    /backups/hrdb_20261010_013001.dump
inventory                OK        -          16K      0m00s    /backups/inventory_20261010_013001.dump
```

### 17.3 Every database on the server (`--all`)
```bash
./pg_dump_wrapper.sh -h db01.example.com -U backup_user --all -o /backups
```
**Notes:** Picks every database with `datallowconn` true that isn't a template, so `template0`, `template1` and databases with `ALLOW_CONNECTIONS false` are skipped. `postgres` is included unless you exclude it.

### 17.4 `--all` minus some (globs, repeatable or comma)
```bash
./pg_dump_wrapper.sh -U backup_user --all --exclude-db postgres --exclude-db 'test_*,tmp_*' -o /backups
```

### 17.5 List databases through a different maintenance DB
**When:** the `postgres` database was dropped, or your role can't connect to it.
```bash
./pg_dump_wrapper.sh -U backup_user --all --maintenance-db template1 -o /backups
```

### 17.6 Stop at the first failure
**When:** later databases depend on earlier ones, or you don't want partial runs.
```bash
./pg_dump_wrapper.sh -U backup_user -d salesdb,hrdb,inventory -o /backups --stop-on-error
```
**Result if hrdb fails:** `salesdb OK`, `hrdb FAIL(2) precheck`, `inventory SKIPPED`, exit 2.

### 17.7 Multi-database, parallel, verified, with retention
```bash
./pg_dump_wrapper.sh -U backup_user --all --exclude-db postgres -F d -j 4 --verify --checksum -r 14 -o /backups/pg
```
**Notes:** Databases are dumped **one after another**. `-j` parallelises the tables *within* each database.

---

## 18. Alerts: e-mail and webhooks
One combined alert per run. On **failure** (the default) it includes the server, databases, exit code, which stage failed and for which database, duration, output folder, log file, the per-database table, and the **last 20 log lines**. A failed alert never changes the backup's exit code. Dry runs never send alerts.

### 18.1 E-mail on failure
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups --alert-email dba@example.com
```
**Notes:** Uses `mail`, then `mailx`, then `sendmail -t`. You need a working MTA behind it (postfix, exim, msmtp…). If none is found, a warning is logged. Subject: `[pg_dump_wrapper] FAILED: salesdb on db01.example.com (exit 3)`.

### 18.2 Several recipients and a From address
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups --alert-email dba@example.com,oncall@example.com --alert-email manager@example.com --alert-from pg-backups@example.com
```

### 18.3 Slack (or Teams / Google Chat / Mattermost) incoming webhook
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups --alert-webhook https://hooks.slack.com/services/XXX/YYY/ZZZ
```
**Payload:** `{"text": "..."}`, with a bold headline (`*[pg_dump_wrapper] FAILED: salesdb on db01.example.com (exit 3)*`) and the report in a code block so the table stays aligned. Only `https://hooks.slack.com/...` appears in logs, and the URL is kept out of `ps`.

### 18.4 Structured JSON to your own endpoint (monitoring, ticketing)
```bash
./pg_dump_wrapper.sh -d salesdb,hrdb -o /backups --alert-webhook https://ops.example.com/hooks/pg-backup --alert-webhook-format json
```
**Payload:**
```json
{"status":"FAILED","exit_code":2,"failed_stage":"precheck (hrdb)","host":"backup01","server":"db01.example.com:5432",
 "user":"backup_user","started":"2026-10-10 01:30:00","duration_seconds":3,"output_dir":"/backups","log_file":"/backups/pg_dump_wrapper.log",
 "databases":[{"database":"salesdb","exit_code":"0","stage":"done","size":"4.5M","duration_seconds":"1","file":"/backups/salesdb_20261010_013000.dump"},
              {"database":"hrdb","exit_code":"2","stage":"precheck","size":"-","duration_seconds":"0","file":"-"}],
 "log_tail":"…last 20 log lines…","text":"…same report as the e-mail…"}
```

### 18.5 Alert on success too (`--alert-on always`)
**When:** you want a daily "backup OK" message, or a heartbeat for a dead-man's-switch monitor.
```bash
./pg_dump_wrapper.sh -d salesdb -o /backups --alert-on always --alert-webhook https://hooks.slack.com/services/XXX/YYY/ZZZ
```

### 18.6 E-mail and webhooks together, several of each
```bash
./pg_dump_wrapper.sh --all -o /backups --alert-email dba@example.com --alert-webhook https://hooks.slack.com/services/XXX/YYY/ZZZ --alert-webhook https://ops.example.com/hooks/pg-backup --alert-webhook-format json
```
**Notes:** `--alert-webhook-format` applies to every webhook in the run. To mix a Slack-format and a JSON-format webhook, run two config files or use `json` (it also contains a `text` field).

### 18.7 Test your alert setup
**When:** right after configuring a webhook or mail. It sends a `TEST` alert to every target and exits without dumping.
```bash
./pg_dump_wrapper.sh --alert-test --alert-email dba@example.com --alert-webhook https://hooks.slack.com/services/XXX/YYY/ZZZ
./pg_dump_wrapper.sh --config /etc/pg_backup/all.conf --alert-test
```

---

## 19. Scheduling: cron and systemd
Cron runs with a minimal environment. Use absolute paths, make sure the cron user has `~/.pgpass` (or use `--pgpassfile`), and rely on the wrapper's log file and alerts instead of cron mail.

### 19.1 Nightly full backup of one database
```cron
# m h dom mon dow  command
30 1 * * *  /opt/pg_dump_wrapper/pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F c -o /backups/salesdb -r 14 --verify --checksum --alert-email dba@example.com >/dev/null 2>&1
```

### 19.2 Hourly schema-only snapshot (track DDL changes)
```cron
5 * * * *   /opt/pg_dump_wrapper/pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F p -s -O -x -o /backups/schema -r 3 >/dev/null 2>&1
```

### 19.3 Weekly full parallel backup, kept 8 weeks
```cron
0 3 * * 0   /opt/pg_dump_wrapper/pg_dump_wrapper.sh -h db01.example.com -U backup_user -d salesdb -F d -j 8 -o /backups/weekly -r 56 --verify --checksum --alert-on always --alert-email dba@example.com >/dev/null 2>&1
```

### 19.4 All databases nightly, with alerts, from a config file
```cron
15 2 * * *  /opt/pg_dump_wrapper/pg_dump_wrapper.sh --config /etc/pg_backup/all.conf >/dev/null 2>&1
```
or entirely on one line:
```cron
15 2 * * *  /opt/pg_dump_wrapper/pg_dump_wrapper.sh -h db01.example.com -U backup_user --pgpassfile /etc/pg_backup/pgpass --all --exclude-db 'postgres,test_*' -F d -j 4 -o /backups/pg -r 14 --verify --checksum --alert-email dba@example.com --alert-webhook https://hooks.slack.com/services/XXX/YYY/ZZZ >/dev/null 2>&1
```

### 19.5 Prevent overlapping runs (`flock`)
**When:** a dump can sometimes take longer than the schedule interval.
```cron
30 1 * * *  flock -n /run/lock/pg_backup.lock /opt/pg_dump_wrapper/pg_dump_wrapper.sh --config /etc/pg_backup/all.conf >/dev/null 2>&1
```

### 19.6 systemd service + timer
`/etc/systemd/system/pg-backup.service`
```ini
[Unit]
Description=PostgreSQL backups (pg_dump_wrapper)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=postgres
ExecStart=/opt/pg_dump_wrapper/pg_dump_wrapper.sh --config /etc/pg_backup/all.conf
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
# exit 5 = only retention cleanup failed; don't mark the unit as failed for that
SuccessExitStatus=5
```
`/etc/systemd/system/pg-backup.timer`
```ini
[Unit]
Description=Nightly PostgreSQL backups

[Timer]
OnCalendar=*-*-* 01:30:00
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pg-backup.timer
systemctl list-timers pg-backup.timer
sudo systemctl start pg-backup.service      # run once now
journalctl -u pg-backup.service -n 50       # console output; the full log is in the log file
```
**Notes:** `Persistent=true` runs a missed backup after the machine boots.

---

## 20. Calling the wrapper from another script (exit codes)

| Code | Meaning | Typical action |
|---|---|---|
| 0 | all databases OK | – |
| 1 | usage / validation error (bad option, `-f` with many DBs, output exists) | fix the command or config |
| 2 | pre-check failed (pg_dump missing, server down, auth, DB missing, pg_dump too old) | check connectivity and credentials |
| 3 | pg_dump failed (partial output already removed) | read `[PG_DUMP]` lines in the log |
| 4 | verify or checksum failed | don't trust that dump, re-run it |
| 5 | retention cleanup failed (the backup itself is OK) | check permissions in the output dir |
| 130 | interrupted (Ctrl-C / SIGTERM) | re-run |

For multi-database runs: the highest code among the failed databases.

### 20.1 Branch on the result
```bash
#!/usr/bin/env bash
/opt/pg_dump_wrapper/pg_dump_wrapper.sh -d salesdb -o /backups --verify --checksum
rc=$?
case $rc in
  0)   echo "backup OK"; rsync -a /backups/ backup-store.example.com:/srv/pg/ ;;
  5)   echo "backup OK, but old files were not cleaned up" ;;
  2)   echo "cannot reach the database - not retrying" ; exit 2 ;;
  *)   echo "backup FAILED (rc=$rc), see /backups/pg_dump_wrapper.log" ; exit "$rc" ;;
esac
```

### 20.2 Retry a transient failure once
```bash
for attempt in 1 2; do
  /opt/pg_dump_wrapper/pg_dump_wrapper.sh -d salesdb -o /backups --verify && break
  rc=$?; [[ $rc -eq 1 ]] && break        # a usage error won't fix itself
  sleep 300
done
```

### 20.3 Find the newest backup file after a successful run
```bash
/opt/pg_dump_wrapper/pg_dump_wrapper.sh -d salesdb -o /backups && latest=$(ls -1td /backups/salesdb_[0-9]*_[0-9]*.dump | head -n1) && echo "latest: $latest"
```

---

## 21. Common errors and what you'll see

| Situation | Exit | What the log says |
|---|---|---|
| No `-d` and no `--all` | 1 | `Database name is required (-d/--dbname or --all). See --help.` |
| Typo in an option | 1 | `Unknown option: --frobnicate (see --help)` |
| `-j 4` with custom format | 1 | `--jobs > 1 is only supported with --format directory (pg_dump limitation)` |
| `-s` and `-a` together | 1 | `--schema-only and --data-only are mutually exclusive` |
| `--if-exists` without `-c` | 1 | `--if-exists requires --clean` |
| `-f` with several DBs | 1 | `-f/--file can only be used with a single database` |
| `-d` and `--all` together | 1 | `Use either -d/--dbname or --all, not both` |
| `-Z 99` | 1 | `Invalid --compress '99' (0-9 or gzip\|lz4\|zstd\|none[:level])` |
| `-r 0` | 1 | `--retention-days must be >= 1 (refusing to delete everything)` |
| File name already exists | 1 | `Output already exists, refusing to overwrite: /backups/x.dump` |
| `password=` in config | 1 | `Config …: 'password' is not supported; use ~/.pgpass or pgpassfile=` |
| Server down or wrong port | 2 | `Server not accepting connections at db01.example.com:5433 (pg_isready)` |
| Wrong password or no `.pgpass` entry | 2 | `Cannot connect to database 'salesdb' as 'backup_user': … password authentication failed` (or `fe_sendauth: no password supplied`) |
| Database doesn't exist | 2 | `Cannot connect to database 'saledb' …: FATAL: database "saledb" does not exist` |
| `REVOKE CONNECT` / no permission | 2 | `… permission denied for database "lockeddb" DETAIL: User does not have CONNECT privilege.` |
| pg_dump older than the server | 2 | `pg_dump major version 15 is older than server 17; use a newer pg_dump (--pg-bin)` |
| pg_dump not installed | 2 | `pg_dump not found (install postgresql-client or use --pg-bin)` |
| Lock timeout / permission denied on a table | 3 | `[PG_DUMP] pg_dump: error: query failed: …`, then `pg_dump failed with exit code 1` and `Removed partial output …` |
| Corrupt or truncated archive | 4 | `Verification failed: pg_restore --list error: …` |
| Ctrl-C / `kill` | 130 | `Interrupted by signal TERM`, then `Removed partial output …`, and the remaining DBs are `SKIPPED` |
| No mail program | 0/≠0 | `WARN Alert: no mail/mailx/sendmail found; cannot send e-mail …` (exit code unchanged) |
| Webhook down / 4xx / 5xx | 0/≠0 | `WARN Alert: webhook https://hooks.slack.com/... failed: curl: (22) …` (exit code unchanged) |

**Tip:** run the same command with `--dry-run` to check options, and with `-v` to see pg_dump's own progress lines.

---

## 22. Restore recipes
Make sure the restore user has enough rights, and use `pg_restore` 17+ for dumps made with pg_dump 17.

### 22.1 Full restore into a new database (custom / tar)
```bash
createdb -h db02.example.com -U postgres salesdb_restored
pg_restore -h db02.example.com -U postgres -d salesdb_restored --no-owner /backups/salesdb_20261010_013000.dump
```

### 22.2 Parallel restore (custom or directory)
```bash
pg_restore -h db02.example.com -U postgres -d salesdb_restored -j 8 /backups/salesdb_20261010_013000.dir
```

### 22.3 Replace an existing database in place
```bash
pg_restore -h db02.example.com -U postgres -d salesdb --clean --if-exists /backups/salesdb_20261010_013000.dump
```

### 22.4 Recreate the database from the dump (`--create`)
```bash
pg_restore -h db02.example.com -U postgres -d postgres --create /backups/salesdb_20261010_013000.dump
```

### 22.5 Restore one table (or one schema)
```bash
pg_restore -h db02.example.com -U postgres -d salesdb_restored -n sales -t orders /backups/salesdb_20261010_013000.dump
pg_restore -h db02.example.com -U postgres -d salesdb_restored -n hr /backups/salesdb_20261010_013000.dump
```
**Notes:** `-t` restores only the table (definition + data), not its schema. Into an empty database, create the schema first: `psql -d salesdb_restored -c 'CREATE SCHEMA IF NOT EXISTS sales'`. `-n hr` on its own restores the schema and everything in it.

### 22.6 Restore only schema or only data from a full dump
```bash
pg_restore -d salesdb_restored --schema-only /backups/salesdb_20261010_013000.dump
pg_restore -d salesdb_restored --data-only --disable-triggers /backups/salesdb_20261010_013000.dump
```

### 22.7 Look inside a dump / pick what to restore
```bash
pg_restore --list /backups/salesdb_20261010_013000.dump > toc.list
# edit toc.list: put ';' in front of lines you do NOT want
pg_restore -d salesdb_restored -L toc.list /backups/salesdb_20261010_013000.dump
```

### 22.8 Turn a custom/directory dump into SQL
```bash
pg_restore -f salesdb.sql /backups/salesdb_20261010_013000.dump
pg_restore -f - --schema-only /backups/salesdb_20261010_013000.dump | less
```

### 22.9 Plain SQL dumps (`.sql`, `.sql.gz`, `.sql.zst`)
```bash
psql -d salesdb_restored -v ON_ERROR_STOP=1 -f /backups/salesdb_20261010_013000.sql
gunzip -c /backups/salesdb_20261010_013000.sql.gz | psql -d salesdb_restored -v ON_ERROR_STOP=1
zstd -dc /backups/salesdb_20261010_013000.sql.zst | psql -d salesdb_restored -v ON_ERROR_STOP=1
```

### 22.10 Restore a whole `--all` run onto a new server
```bash
psql -h new-db.example.com -U postgres -d postgres -f globals.sql          # roles first (see 9.5)
for f in /backups/pg/*_20261010_*.dir; do
  pg_restore -h new-db.example.com -U postgres -d postgres --create -j 4 "$f"
done
```

### 22.11 Check the checksum before restoring
```bash
cd /backups && sha256sum -c salesdb_20261010_013000.dump.sha256 && pg_restore -d salesdb_restored salesdb_20261010_013000.dump
```
