# psql_wrapper.sh: usage examples (v1.0.0)

Copy-paste recipes for [psql_wrapper.sh](README_psql.md). Outputs shown here come from real test runs against PostgreSQL 17. Timestamps, sizes and pids will differ on your system.

## Contents
1. [Setup and authentication](#1-setup-and-authentication)
2. [Connecting: host, port, socket](#2-connecting-host-port-socket)
3. [Migrations](#3-migrations)
4. [Query exports](#4-query-exports)
5. [Scheduled reports (cron)](#5-scheduled-reports-cron)
6. [Health checks](#6-health-checks)
7. [Monitoring integration (cron, Nagios, JSON)](#7-monitoring-integration)
8. [Alerts](#8-alerts)
9. [Config files](#9-config-files)
10. [Exit codes in scripts](#10-exit-codes-in-scripts)
11. [Common errors](#11-common-errors)

---

## 1. Setup and authentication

```bash
install -m 755 psql_wrapper.sh /usr/local/bin/psql_wrapper.sh
echo 'db01.internal:5432:*:app_admin:S3cret' >> ~/.pgpass && chmod 600 ~/.pgpass
```
Other options: `--pgpassfile /etc/pg_tools/.pgpass`, `PGPASSWORD=... psql_wrapper.sh ...` (environment, not argv), or `-W` to be prompted once. Passwords are never accepted as arguments or config values:
```
$ psql_wrapper.sh query --config bad.conf -d app -c 'select 1'
[ERROR] Config bad.conf:1: 'password' is not supported; use ~/.pgpass or pgpassfile=     (exit 1)
```

A role for health checks that can see every session but change nothing:
```sql
CREATE ROLE monitor LOGIN PASSWORD '...' IN ROLE pg_monitor;
```

## 2. Connecting: host, port, socket

```bash
psql_wrapper.sh health -h db01.internal -p 6432 -U monitor -d salesdb   # remote host, custom port
PGPORT=5433 psql_wrapper.sh health -d salesdb                            # port from the environment
psql_wrapper.sh health -h /var/run/postgresql -d salesdb                 # local Unix socket (peer auth)
psql_wrapper.sh query --host=db01 --port=5432 --dbname=salesdb -c 'select now()'   # --opt=value style
```

## 3. Migrations

Example directory (`-D` runs `*.sql` in version order, so `010_` comes after `002_`):
```
migrations/
  001_init.sql      CREATE TABLE customers (id serial PRIMARY KEY, name text NOT NULL, region text);
  002_seed.sql      INSERT INTO customers (name, region) VALUES ('Asha', :'region'), ('Ravi', :'region'), ('Mei', 'APAC');
  010_orders.sql    CREATE TABLE orders (...); INSERT INTO orders ...;
```

### 3.1 Apply all pending migrations, tracked, with a psql variable
```
$ psql_wrapper.sh migrate -d appdb -D migrations --track -v region=EMEA
[INFO] [appdb] Applying 3 file(s) (transaction: all, tracked in public.schema_migrations): 001_init.sql 002_seed.sql 010_orders.sql
[PSQL] [appdb] >>> applying 001_init.sql
[PSQL] [appdb] >>> applying 002_seed.sql
[PSQL] [appdb] >>> applying 010_orders.sql
[PSQL] [appdb] >>> all files applied
[INFO] [appdb] Migration OK: applied 3 file(s)
```
Running it again is a no-op: `Nothing to apply (3 file(s) already applied)`, exit 0.

### 3.2 A failing migration rolls back everything
`002_broken.sql` inserts a good row and then references a column that doesn't exist:
```
$ psql_wrapper.sh migrate -d appdb -D migrations_bad --track
[PSQL] [appdb] >>> applying 001_init.sql
[PSQL] [appdb] >>> applying 002_broken.sql
[PSQL] [appdb] psql:/srv/migrations_bad/002_broken.sql:2: ERROR:  column "no_such_column" of relation "customers" does not exist
[ERROR] [appdb] Migration failed (psql exit 3): the whole transaction was ROLLED BACK, 'appdb' is unchanged
$ echo $?
3
```
Afterwards the database has **no** tables: `001_init.sql` and the good row were rolled back too, and nothing was recorded in the tracking table.

### 3.3 Status: applied, pending, changed
```
$ psql_wrapper.sh migrate -d appdb -D migrations --track --status
STATE      FILE                                     SHA256
applied    001_init.sql                             d7b30f687730
CHANGED    002_seed.sql                             6a8fda87ad17
applied    010_orders.sql                           fb4d7a0a814f
[WARN] [appdb] 002_seed.sql was applied with sha256 47124a59f236... but the file now has 6a8fda87ad17...
```
Exit code 4. A normal run stops with exit 4 too. Restore the original file and add a new migration instead, or pass `--allow-changed` to skip edited files with a warning.

### 3.4 Specific files, in your order
```bash
psql_wrapper.sh migrate -d appdb -f hotfix/drop_temp_index.sql -f hotfix/backfill.sql
```

### 3.5 Transaction modes
```bash
# default: one transaction for everything
psql_wrapper.sh migrate -d appdb -D migrations --track

# each file commits on its own; stops at the first failure, earlier files stay applied (and tracked)
psql_wrapper.sh migrate -d appdb -D migrations --track --transaction per-file

# autocommit, for statements that can't run inside a transaction
psql_wrapper.sh migrate -d appdb -f concurrently/001_idx.sql --transaction none
#   001_idx.sql:  CREATE INDEX CONCURRENTLY orders_customer_idx ON orders (customer_id);
```
Files that contain their own `BEGIN`/`COMMIT` are rejected unless you use `--transaction none`:
```
[ERROR] txn.sql contains its own BEGIN/COMMIT/ROLLBACK; remove it or use --transaction none     (exit 1)
```

### 3.6 A custom tracking table
```bash
psql -d appdb -c 'CREATE SCHEMA IF NOT EXISTS ops'
psql_wrapper.sh migrate -d appdb -D migrations --track-table ops.migrations
```

### 3.7 Production guard
```
$ psql_wrapper.sh migrate -d salesdb -D migrations --production 'salesdb,*_prod'
[ERROR] [salesdb] Refusing to run 3 migration file(s) on production database 'salesdb' without confirmation. Re-run with --confirm salesdb or --yes.
$ echo $?
5
```
From a terminal you are asked instead:
```
*** PRODUCTION database "salesdb" on db01.internal:5432 ***
run 3 migration file(s)
Type the database name to continue: salesdb
[WARN] [salesdb] Production target 'salesdb': confirmed interactively
```
In CI/cron, confirm the exact database: `--confirm salesdb`. A typo in `-d` is then refused rather than confirmed. `--yes` confirms everything. Whole servers can be marked with `--production-host 'db*.prod.example.com'`.

### 3.8 Several databases (e.g. one schema per tenant DB)
```bash
psql_wrapper.sh migrate -d tenant_a,tenant_b,tenant_c -D migrations --track
psql_wrapper.sh migrate --all --exclude-db 'postgres,template*' -D migrations --track --stop-on-error
```
```
[INFO] Summary:
[INFO]   DATABASE                 STATUS    STAGE      DETAIL
[INFO]   tenant_a                 OK        -          up to date
[INFO]   tenant_b                 OK        -          applied 2 file(s)
[INFO]   tenant_c                 FAIL(2)   precheck   -
```

### 3.9 Dry run: see the generated driver script
```
$ psql_wrapper.sh migrate -d appdb -f mig/010_orders.sql -f mig/001_init.sql --track --dry-run
[INFO] DRY RUN - migrate on: appdb (transaction: all)
[INFO]   file 010_orders.sql  sha256 fb4d7a0a814f  /srv/mig/010_orders.sql
[INFO]   file 001_init.sql  sha256 d7b30f687730  /srv/mig/001_init.sql
[INFO]   driver script:
\set ON_ERROR_STOP on
\set ON_ERROR_ROLLBACK off
BEGIN;
CREATE TABLE IF NOT EXISTS :"trk_schema".:"trk_table" (filename text PRIMARY KEY, ...);
LOCK TABLE :"trk_schema".:"trk_table" IN SHARE ROW EXCLUSIVE MODE;
\echo >>> applying 010_orders.sql
\i '/srv/mig/010_orders.sql'
INSERT INTO :"trk_schema".:"trk_table" (filename, checksum) VALUES (:'mf_0', :'mc_0');
...
COMMIT;
```

## 4. Query exports

```
$ psql_wrapper.sh query -d appdb -c "select id, name, region from customers order by id"
id,name,region
1,Asha,EMEA
2,Ravi,EMEA
3,Mei,APAC
```

| Want | Command |
|---|---|
| CSV with `;`, no header, a variable | `query -d appdb -c "select id, name from customers where region = :'r'" -v r=EMEA --no-header --delimiter ';'` → `1;Asha` |
| TSV | `query -d appdb -f q.sql -F tsv` |
| JSON array | `query -d appdb -c "select id, name from customers" -F json` → `[{"id":1,"name":"Asha"}, ...]` (`[]` when no rows) |
| NDJSON (one object per line, for `jq`, log shippers) | `query -d appdb -c "select * from orders" -F ndjson` |
| Aligned table for a terminal or e-mail | `query -d appdb -c "select name, region from customers" -F txt` |
| To a file | `query -d appdb -f q.sql -o /tmp/out.csv` (refuses to overwrite; add `--force`) |
| zstd file | `query -d appdb -f q.sql -o /tmp/out.csv.zst -Z zstd` |
| Query from a file with variables | `query -d appdb -f reports/by_region.sql -v r=APAC` |
| With a time limit | `query -d appdb -f heavy.sql --timeout 300` → exit 3 `canceling statement due to statement timeout` |

### 4.1 Read-only by default
```
$ psql_wrapper.sh query -d appdb -c "insert into customers(name) values ('x')"
[ERROR] [appdb] Query failed on 'appdb': psql:<stdin>:1: ERROR:  cannot execute INSERT in a read-only transaction     (exit 3)

$ psql_wrapper.sh query -d appdb -c "insert into customers(name) values ('x') returning id" --read-write
id
4
```
`--read-write` against a `--production` database needs `--confirm`/`--yes` like a migration.

### 4.2 One timestamped file per database
```
$ psql_wrapper.sh query -d appdb,reportdb -c "select count(*) as n from customers" --output-dir rep --name daily -Z gzip
[INFO] [appdb] Wrote rep/daily_appdb_20261010_121324.csv.gz (4.0K)
[INFO] [reportdb] Wrote rep/daily_reportdb_20261010_121324.csv.gz (4.0K)
```

## 5. Scheduled reports (cron)

```cron
# m h dom mon dow  command
# 06:00 daily: sales CSV, gzip, keep 30 days, alert on failure
0 6 * * * /usr/local/bin/psql_wrapper.sh query -h db01 -U report -d salesdb -f /opt/reports/daily_sales.sql --output-dir /srv/reports --name daily_sales -Z gzip -r 30 --timeout 600 -l /var/log/psql_wrapper.log --alert-email dba@example.com >/dev/null 2>&1

# Monday 07:00: JSON for the dashboard importer
0 7 * * 1 /usr/local/bin/psql_wrapper.sh query --config /etc/pg_tools/report.conf -f /opt/reports/weekly.sql -F json -o /srv/dashboard/weekly.json --force >/dev/null 2>&1
```
`/opt/reports/daily_sales.sql`:
```sql
SELECT o.id, c.name, c.region, o.amount
FROM orders o JOIN customers c ON c.id = o.customer_id
WHERE o.created_at >= current_date - 1 AND o.created_at < current_date
ORDER BY o.id
```
Retention only deletes `daily_sales_*_YYYYmmdd_HHMMSS.*` files older than 30 days in `/srv/reports`. Other files are never touched. A failed query leaves no partial file (output is written to `*.part.<pid>` and renamed at the end).

## 6. Health checks

```
$ psql_wrapper.sh health -d appdb,healthdb
DATABASE         CHECK         STATUS VALUE                            DETAIL
(server)         connections   OK     1/100 (1.0%)                     active=1
(server)         long_running  OK     0s max                           0 over 300s
(server)         blocking      OK     0 blocked, 0s max wait           no blocked sessions
(server)         replication   OK     n/a                              primary, no replicas
appdb            db_size       OK     7846 kB                          largest: schema_migrations 32 kB, customers 32 kB, orders 24 kB
appdb            cache_hit     OK     99.97%                           13714 hits / 4 reads
appdb            bloat         OK     0% dead (max)                    no table over 20% dead rows
appdb            vacuum        OK     0 table(s) need vacuum/analyze   all tables recently vacuumed/analyzed
appdb            wraparound    OK     664 xids                         0.0% of the wraparound limit
healthdb         db_size       OK     10 MB                            largest: bloaty 2792 kB, locked_t 8192 bytes
healthdb         cache_hit     OK     100.00%                          37114 hits / 0 reads
healthdb         bloat         CRIT   70.0% dead (max)                 bloaty 70.0% (14000 dead rows)
healthdb         vacuum        WARN   1 table(s) need vacuum/analyze   bloaty (14000 dead, 34000 changed since analyze)
healthdb         wraparound    OK     664 xids                         0.0% of the wraparound limit
Overall: CRIT (1 crit, 1 warn)
$ echo $?
11
```
Without `-d`, `health` checks the server plus every connectable database (`--exclude-db 'template*'` to skip some).

### 6.1 Only some checks, custom thresholds
```bash
psql_wrapper.sh health -d appdb --checks long_running,blocking --warn long_running=60 --crit long_running=300 --warn blocking=10 --crit blocking=60
psql_wrapper.sh health -d appdb --checks db_size --warn db_size=50000 --crit db_size=80000    # MB
psql_wrapper.sh health -d appdb --checks cache_hit --warn cache_hit=99 --crit cache_hit=95     # alert when BELOW
psql_wrapper.sh health -d appdb --checks bloat,vacuum --min-rows 10000 --warn bloat=30 --warn vacuum=3
```

### 6.2 Catching a blocking lock and a long query
Session 1 holds a lock: `BEGIN; LOCK TABLE locked_t IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(40);`. Session 2 runs `SELECT * FROM locked_t` and waits. Session 3 runs `SELECT pg_sleep(40)`.
```
$ psql_wrapper.sh health -d healthdb --checks long_running,blocking --warn long_running=2 --crit long_running=30 --warn blocking=2 --crit blocking=30
DATABASE         CHECK         STATUS VALUE                            DETAIL
(server)         long_running  WARN   4s max                           3 over 2s; longest: pid 106637 db healthdb active: SELECT pg_sleep(40)
(server)         blocking      WARN   1 blocked, 3s max wait           pid 106642 (healthdb) waits 3s on 106638
Overall: WARN (0 crit, 2 warn)          # exit 10
```
A few seconds later, with `--crit ...=5`, both checks are `CRIT` (exit 11). The detail tells you which pid to look at (`pg_cancel_backend(106638)` / `pg_terminate_backend(106638)` if you decide to). The wrapper never kills sessions itself.

### 6.3 JSON report
```bash
psql_wrapper.sh health -d appdb -F json | jq '.checks[] | select(.status != "OK")'
```
```json
{"status":"CRIT","host":"/var/run/postgresql","port":5432,"checked_at":"2026-10-10 12:14:12","checks":[
 {"database":"(server)","check":"long_running","status":"CRIT","value":"7s max","detail":"3 over 2s; longest: pid 106637 ..."}, ...]}
```

## 7. Monitoring integration

```cron
# every 5 minutes: alert Slack on CRIT only, keep a log
*/5 * * * * /usr/local/bin/psql_wrapper.sh health --config /etc/pg_tools/health.conf --alert-on crit --alert-webhook https://hooks.slack.com/services/T000/B000/XXXX -l /var/log/psql_health.log >/dev/null 2>&1
```

Nagios / Icinga `check_command`:
```
$ psql_wrapper.sh health -d appdb --nagios
PSQL_HEALTH OK - 0 crit, 0 warn, 9 checks                                        # exit 0
PSQL_HEALTH CRITICAL - 1 crit, 0 warn, 2 checks: (server)/long_running=7s max (CRIT)   # exit 2
```

Use it as a deployment gate:
```bash
psql_wrapper.sh health -d salesdb --checks blocking,long_running,replication --nagios || { echo "DB not healthy, aborting deploy"; exit 1; }
psql_wrapper.sh migrate -d salesdb -D migrations --track --production salesdb --confirm salesdb
```

## 8. Alerts

```bash
# test the webhook first
psql_wrapper.sh --alert-test --alert-webhook "$SLACK_WEBHOOK_URL"

# failed migration -> e-mail + structured JSON to your own endpoint
psql_wrapper.sh migrate -d appdb -D migrations --track -l /var/log/psql_wrapper.log \
    --alert-email dba@example.com --alert-webhook https://ops.example.com/hooks/pg --alert-webhook-format json
```
The JSON body for that failure (abridged):
```json
{"tool":"psql_wrapper","command":"migrate","status":"FAILED","exit_code":3,"failed_stage":"migrate (appdb)",
 "host":"db01","server":"db01:5432","user":"app_admin","duration_seconds":0,"databases":"appdb",
 "text":"[psql_wrapper] migrate FAILED: appdb on db01 (exit 3)\n...\nLast 20 log lines:\n... ERROR:  relation \"customers\" already exists\n..."}
```
E-mail subject: `[psql_wrapper] health CRITICAL: salesdb on db01 (exit 11)`.

`--alert-on failure` (default) alerts on errors and on health WARN/CRIT. `crit` skips WARN. `always` also reports success, which is handy as a "the report ran" heartbeat.

## 9. Config files

Start from [psql_wrapper.conf.example](psql_wrapper.conf.example). One file per job works well:
```ini
# /etc/pg_tools/health.conf
host=db01.internal
user=monitor
all=yes
exclude_db=template*,postgres
warn_long_running=120
crit_long_running=600
warn_blocking=15
alert_webhook=https://hooks.slack.com/services/T000/B000/XXXX
```
```bash
chmod 600 /etc/pg_tools/health.conf     # it contains a webhook token
psql_wrapper.sh health --config /etc/pg_tools/health.conf
psql_wrapper.sh health --config /etc/pg_tools/health.conf -d salesdb --checks bloat    # CLI overrides
```

## 10. Exit codes in scripts

```bash
psql_wrapper.sh health -d salesdb >/tmp/health.txt
case $? in
  0)  echo "healthy" ;;
  10) echo "warning";  mail -s "DB warning" dba@example.com </tmp/health.txt ;;
  11) echo "critical"; page_oncall </tmp/health.txt ;;
  *)  echo "check itself failed (usage/connection)" ;;
esac

psql_wrapper.sh migrate -d appdb -D migrations --track
case $? in
  0) ;; 3) echo "migration failed and was rolled back" ;; 4) echo "someone edited an applied migration" ;;
  5) echo "production target not confirmed" ;; *) echo "error" ;;
esac
```

## 11. Common errors

| Message | Cause / fix |
|---|---|
| `fe_sendauth: no password supplied` (exit 2) | No `.pgpass` entry for this host/port/db/user. Add one, or use `--pgpassfile` / `PGPASSWORD`. Locally, try the socket: `-h /var/run/postgresql`. |
| `First argument must be a command: migrate \| query \| health` | Put the command first: `psql_wrapper.sh health -d db`. |
| `-v must look like NAME=VALUE` | `-v` is a psql variable here. For verbose logging use `--verbose`. |
| `... contains its own BEGIN/COMMIT/ROLLBACK` | Remove transaction control from the file, or run it with `--transaction none`. |
| `ERROR: CREATE INDEX CONCURRENTLY cannot run inside a transaction block` (exit 3, rolled back) | Move it into its own file and run that with `--transaction none`. |
| `Applied migration file(s) changed` (exit 4) | Someone edited an applied file. Revert it and write a new migration, or use `--allow-changed` once you've reviewed it. |
| `Refusing to run ... on production database` (exit 5) | Add `--confirm DB` (or `--yes`), or run it from a terminal and type the name. |
| `Several databases need --output-dir` | Multi-database queries write one file per database. |
| `Output exists, refusing to overwrite` (exit 6) | Use `--output-dir` (timestamped names) or `--force`. |
| `cannot execute INSERT in a read-only transaction` (exit 3) | Queries are read-only by default. Add `--read-write` if you really mean it. |
| `connect CRIT ... database "x" does not exist` | Health shows unreachable databases as CRIT rows instead of silently skipping them. |
