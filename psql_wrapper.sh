#!/usr/bin/env bash
#
# psql_wrapper.sh - all-in-one psql toolkit (companion to pg_dump_wrapper.sh)
#
# Commands:
#   migrate  Run SQL files or an ordered directory of migrations in ONE transaction with
#            ON_ERROR_STOP (any error rolls everything back), psql variables (-v),
#            optional tracking table (skip applied files, record sha256, detect edited
#            files), confirmation guard for production targets, --status, --dry-run.
#   query    Run a query and export CSV / TSV / JSON / NDJSON / text to stdout or to a
#            timestamped, optionally compressed file (atomic write). Read-only by default.
#   health   Database/table sizes, connections, blocking locks, long-running queries,
#            bloat estimate, replication lag, cache hit ratio, vacuum/analyze and
#            wraparound status, with WARN/CRIT thresholds -> exit codes and alerts.
#
# Exit codes (multi-database runs: the highest code of any database):
#   0    success / health OK
#   1    usage / validation error
#   2    pre-check failure (psql missing, cannot connect, standby, missing files)
#   3    SQL failed (migration rolled back, query error)
#   4    migration checksum drift (an already-applied file was modified)
#   5    refused by the production safety guard
#   6    output error (cannot write the export file)
#   10   health WARN        11  health CRIT
#        (with --nagios: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN)
#   130  interrupted (INT/TERM)
#
# Passwords are NEVER accepted on the command line. Use ~/.pgpass, PGPASSFILE
# (or the pgpassfile= config key), the PGPASSWORD environment variable, or -W.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
readonly US=$'\x1f'   # field separator for psql output
readonly TAB=$'\t'

# ----------------------------------------------------------------------------
# Defaults (lowest precedence: defaults < config file < command line)
# ----------------------------------------------------------------------------
COMMAND=""
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_USER="${PGUSER:-${USER:-postgres}}"
DB_NAMES=()
ALL_DBS=0
EXCLUDE_DBS=()
MAINTENANCE_DB="postgres"
STOP_ON_ERROR=0
VARS=()
LOG_FILE=""
DRY_RUN=0
PROMPT_PASSWORD=0
VERBOSE=0
PG_BIN=""
PGPASSFILE_OPT=""
CONFIG_FILE=""
ASSUME_YES=0
CONFIRM_DBS=()
PRODUCTION_DBS=()
PRODUCTION_HOSTS=()
# migrate
SQL_FILES=()
SQL_DIR=""
TXN_MODE="all"
TRACK=0
TRACK_TABLE="public.schema_migrations"
ALLOW_CHANGED=0
STATUS_ONLY=0
# query
QUERY_SQL=""
FORMAT=""
HEADER=1
DELIMITER=""
OUTPUT_FILE=""
OUTPUT_DIR=""
OUTPUT_NAME="query"
COMPRESS="none"
FORCE=0
RETENTION_DAYS=""
READ_WRITE=0
TIMEOUT=0
# health
CHECKS_ALL=(connections long_running blocking replication db_size cache_hit bloat vacuum wraparound)
CHECKS=()
NAGIOS=0
TOP_N=5
MIN_ROWS=1000
declare -A WARN=([connections]=80 [long_running]=300 [blocking]=30 [replication]=60 [db_size]=0
                 [cache_hit]=95 [bloat]=20 [vacuum]=7 [wraparound]=1000000000)
declare -A CRIT=([connections]=95 [long_running]=900 [blocking]=120 [replication]=300 [db_size]=0
                 [cache_hit]=90 [bloat]=50 [vacuum]=30 [wraparound]=1500000000)
# alerts
ALERT_EMAILS=()
ALERT_WEBHOOKS=()
ALERT_ON="failure"
ALERT_WEBHOOK_FORMAT="slack"
ALERT_FROM=""
ALERT_TEST=0
ALERT_LOG_LINES=20

# runtime state
DB_NAME=""
RUN_START=$SECONDS
RUN_START_TS=""
STAGE="init"
RESULT_DIR=""
CHILD_PID=""
RESULTS=()        # "db|rc|stage|detail"
MAIN_STARTED=0
INTERACTIVE=0
IS_CHILD=0
CHILD_RESULT_FILE=""
CHILD_DETAIL=""
WORK_PID=""
CURRENT_DB=""; CURRENT_RES=""
FILE_PATHS=(); FILE_KEYS=(); FILE_SUMS=()
TRK_SCHEMA=""; TRK_TABLE=""
HEALTH_STATUS="OK"
HEALTH_TEXT=""

# ----------------------------------------------------------------------------
# Logging (always stderr, so stdout stays clean for query output / reports)
# ----------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() {
    local level="$1"; shift
    local line
    line="$(_ts) [$level]${DB_NAME:+ [$DB_NAME]} $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local code="$1"; shift; log_error "$@"; exit "$code"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - all-in-one psql wrapper

Usage: $SCRIPT_NAME migrate -d DB[,DB...] (-f FILE... | -D DIR) [options]
       $SCRIPT_NAME query   -d DB[,DB...] (-c SQL | -f FILE) [-F csv|tsv|json|ndjson|txt] [-o FILE | --output-dir DIR]
       $SCRIPT_NAME health  [-d DB[,DB...] | --all] [--warn CHECK=N] [--crit CHECK=N] [-F text|json] [--nagios]

Connection (all commands):
  -h, --host HOST          Server host or socket dir      (default: \$PGHOST or localhost)
  -p, --port PORT          Server port                    (default: \$PGPORT or 5432)
  -U, --user USER          Database user                  (default: \$PGUSER or \$USER)
  -W, --password           Prompt once for the password (kept in this process's env only)
      --pgpassfile FILE    Use this .pgpass file (sets PGPASSFILE)
      --maintenance-db DB  Database for server-wide queries and --all  (default: postgres)

Databases:
  -d, --dbname DB          Target database(s); repeatable or comma-separated
      --all                Every connectable, non-template database
      --exclude-db PATTERN With --all: skip databases matching shell glob [repeatable]
      --stop-on-error      Stop at the first failed database (default: continue)

Common:
  -v, --set NAME=VALUE     psql variable, usable as :NAME / :'NAME' / :"NAME" [repeatable]
      --config FILE        Load key=value settings (CLI arguments override them)
  -l, --log-file FILE      Also append log lines to FILE (default: console/stderr only)
      --dry-run            Show what would run; connect to nothing, change nothing
      --pg-bin DIR         Directory containing psql
      --verbose            Debug logging
      --help, --version

Production guard (migrate, and query --read-write):
      --production GLOB    Database names treated as production [repeatable]
      --production-host GLOB  Hosts treated as production (every database on them) [repeatable]
  -y, --yes                Confirm writes to production targets (automation)
      --confirm DB         Confirm only these databases [repeatable]
                           Otherwise an interactive terminal must type the database name.

migrate:
  -f, --file FILE          SQL file to run, in the given order [repeatable]
  -D, --dir DIR            Run every *.sql in DIR in version order (001_, 002_, 010_ ...)
      --transaction MODE   all (default: one transaction for everything) | per-file | none
      --track              Record applied files in a tracking table and skip them next time
      --track-table NAME   Tracking table (default: public.schema_migrations)
      --allow-changed      With --track: skip (warn) instead of failing when an applied file changed
      --status             With --track: show applied / pending / changed files and exit

query:
  -c, --command SQL        Query text (one statement)
  -f, --file FILE          Read the query from FILE
  -F, --format FMT         csv (default) | tsv | json (array) | ndjson | txt (aligned table)
      --no-header          Omit the header row (csv/tsv/txt)
      --delimiter C        Field separator for csv (one character)
  -o, --output FILE        Write to FILE ('-' = stdout, the default)
      --output-dir DIR     Write NAME_DB_YYYYmmdd_HHMMSS.EXT into DIR (one file per database)
      --name NAME          File name prefix for --output-dir (default: query)
  -Z, --compress METHOD    none | gzip | zstd   (file output only)
      --force              Overwrite an existing -o FILE
  -r, --retention-days N   With --output-dir: delete NAME_* reports older than N days
      --read-write         Allow writes (default: default_transaction_read_only=on)
      --timeout SEC        statement_timeout for the query (default: 0 = none)

health:
      --checks LIST        Comma list (default: all): ${CHECKS_ALL[*]}
      --warn CHECK=N       Override a WARN threshold [repeatable]
      --crit CHECK=N       Override a CRIT threshold [repeatable]
                           connections %used (80/95), long_running s (300/900), blocking s waited (30/120),
                           replication s lag (60/300), db_size MB (0=off), cache_hit % below (95/90),
                           bloat % dead tuples (20/50), vacuum days (7/30), wraparound xid age (1e9/1.5e9)
      --min-rows N         Ignore tables smaller than N rows for bloat/vacuum (default: 1000)
      --top N              Largest tables listed by db_size (default: 5)
  -F, --format FMT         text (default) | json
      --nagios             One-line output and Nagios exit codes (0/1/2/3)

Alerts:
      --alert-email ADDR   Mail the report (mail/mailx/sendmail) [repeatable]
      --alert-webhook URL  POST the report as JSON via curl [repeatable]
      --alert-webhook-format F  slack | json (default: slack)
      --alert-on WHEN      failure (default; includes health WARN/CRIT) | crit | always
      --alert-from ADDR    From address for e-mail alerts
      --alert-test         Send a test alert and exit

Exit codes: 0 ok, 1 usage, 2 pre-check, 3 SQL failed, 4 checksum drift, 5 guard, 6 output,
10 health WARN, 11 health CRIT, 130 interrupted
USAGE
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
add_list() {
    local -n _arr="$1"
    local _item
    local -a _parts
    IFS=',' read -r -a _parts <<<"$2"
    for _item in "${_parts[@]}"; do
        _item="${_item#"${_item%%[![:space:]]*}"}"
        _item="${_item%"${_item##*[![:space:]]}"}"
        [[ -n "$_item" ]] && _arr+=("$_item")
    done
    return 0
}
is_true() { case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac; }
bin() { if [[ -n "$PG_BIN" ]]; then printf '%s/%s' "${PG_BIN%/}" "$1"; else printf '%s' "$1"; fi; }
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }
in_list() { local v="$1" x; shift; for x in "$@"; do [[ "$x" == "$v" ]] && return 0; done; return 1; }
redact_url() {
    if [[ "$1" =~ ^([a-zA-Z]+://[^/]+) ]]; then printf '%s/...' "${BASH_REMATCH[1]}"; else printf '<webhook>'; fi
}
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
    printf '%s' "$s"
}
fmt_duration() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

set_threshold() {   # set_threshold WARN|CRIT CHECK=N
    local -n _t="$1"
    [[ "$2" =~ ^([a-z_]+)=([0-9]+(\.[0-9]+)?)$ ]] || die 1 "Threshold must look like CHECK=NUMBER (got '$2')"
    in_list "${BASH_REMATCH[1]}" "${CHECKS_ALL[@]}" || die 1 "Unknown check '${BASH_REMATCH[1]}' (${CHECKS_ALL[*]})"
    _t[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
}

psql_args() {   # common psql arguments, incl. user variables
    PSQL=("$(bin psql)" -X -w -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -v ON_ERROR_STOP=1
          -v trk_schema="$TRK_SCHEMA" -v trk_table="$TRK_TABLE" -v trk_full="$TRK_SCHEMA.$TRK_TABLE")
    local v
    for v in "${VARS[@]}"; do PSQL+=(-v "$v"); done
}
psql_q() {      # psql_q <db> <sql> [extra args]: -At output, SQL via stdin so :vars work
    local db="$1" sql="$2"; shift 2
    local -a PSQL; psql_args
    printf '%s\n' "$sql" | "${PSQL[@]}" -q -At -F "$US" -d "$db" "$@" -f - 2>&1
}

# ----------------------------------------------------------------------------
# Config file: key=value, '#' comments. Never sourced/executed.
# ----------------------------------------------------------------------------
load_config() {
    local file="$1" line key val lineno=0
    [[ -r "$file" ]] || die 1 "Config file not readable: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] \
            || die 1 "Config $file:$lineno: invalid line (expected key=value)"
        key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"([^\"]*)\" || "$val" =~ ^\'([^\']*)\' ]]; then val="${BASH_REMATCH[1]}"
        else
            [[ "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && val="${BASH_REMATCH[1]}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        case "$key" in
            host) DB_HOST="$val" ;;  port) DB_PORT="$val" ;;  user|username) DB_USER="$val" ;;
            pgpassfile) PGPASSFILE_OPT="$val" ;;  maintenance_db) MAINTENANCE_DB="$val" ;;
            dbname|database|dbnames|databases) DB_NAMES=(); add_list DB_NAMES "$val" ;;
            all|all_databases) is_true "$val" && ALL_DBS=1 || ALL_DBS=0 ;;
            exclude_db|exclude_dbs) EXCLUDE_DBS=(); add_list EXCLUDE_DBS "$val" ;;
            stop_on_error) is_true "$val" && STOP_ON_ERROR=1 || STOP_ON_ERROR=0 ;;
            set|vars|variables) VARS=(); add_list VARS "$val" ;;
            log_file) LOG_FILE="$val" ;;  pg_bin) PG_BIN="$val" ;;
            verbose) is_true "$val" && VERBOSE=1 || VERBOSE=0 ;;
            production|production_dbs) PRODUCTION_DBS=(); add_list PRODUCTION_DBS "$val" ;;
            production_host|production_hosts) PRODUCTION_HOSTS=(); add_list PRODUCTION_HOSTS "$val" ;;
            yes|assume_yes|confirm) die 1 "Config $file:$lineno: '$key' is not allowed in a config file; pass --yes/--confirm on the command line" ;;
            dir|migrations_dir) SQL_DIR="$val" ;;
            transaction) TXN_MODE="$val" ;;
            track) is_true "$val" && TRACK=1 || TRACK=0 ;;
            track_table) TRACK_TABLE="$val" ;;
            allow_changed) is_true "$val" && ALLOW_CHANGED=1 || ALLOW_CHANGED=0 ;;
            format) FORMAT="$val" ;;
            header) is_true "$val" && HEADER=1 || HEADER=0 ;;
            delimiter) DELIMITER="$val" ;;
            output) OUTPUT_FILE="$val" ;;  output_dir) OUTPUT_DIR="$val" ;;  name) OUTPUT_NAME="$val" ;;
            compress) COMPRESS="$val" ;;  retention_days) RETENTION_DAYS="$val" ;;
            read_write) is_true "$val" && READ_WRITE=1 || READ_WRITE=0 ;;
            timeout) TIMEOUT="$val" ;;
            checks) CHECKS=(); add_list CHECKS "$val" ;;
            warn_*) set_threshold WARN "${key#warn_}=$val" ;;
            crit_*) set_threshold CRIT "${key#crit_}=$val" ;;
            min_rows) MIN_ROWS="$val" ;;  top) TOP_N="$val" ;;
            nagios) is_true "$val" && NAGIOS=1 || NAGIOS=0 ;;
            alert_email|alert_emails) ALERT_EMAILS=(); add_list ALERT_EMAILS "$val" ;;
            alert_webhook|alert_webhooks) ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$val" ;;
            alert_webhook_format) ALERT_WEBHOOK_FORMAT="$val" ;;
            alert_on) ALERT_ON="$val" ;;  alert_from) ALERT_FROM="$val" ;;
            password) die 1 "Config $file:$lineno: 'password' is not supported; use ~/.pgpass or pgpassfile=" ;;
            *) die 1 "Config $file:$lineno: unknown key '$key'" ;;
        esac
    done <"$file"
}

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------
parse_args() {
    case "${1:-}" in
        migrate|query|health) COMMAND="$1"; shift ;;
        --help|-\?|help|"") usage; exit 0 ;;
        --version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
        --alert-test) COMMAND="alert-test" ;;
        *) die 1 "First argument must be a command: migrate | query | health (see --help)" ;;
    esac
    local i
    for ((i = 1; i <= $#; i++)); do
        case "${!i}" in
            --config=*) CONFIG_FILE="${!i#*=}" ;;
            --config) local j=$((i + 1)); [[ $j -le $# ]] || die 1 "Option --config requires a value"; CONFIG_FILE="${!j}" ;;
        esac
    done
    [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"
    local cli_d=0 cli_all=0 cli_X=0 cli_v=0 cli_f=0 cli_ae=0 cli_aw=0 cli_c=0 cli_P=0 cli_H=0 cli_k=0
    while [[ $# -gt 0 ]]; do
        local opt="$1"
        if [[ "$opt" == --*=* ]]; then set -- "${opt%%=*}" "${opt#*=}" "${@:2}"; opt="$1"; fi
        case "$opt" in
            -h|--host) need_arg "$opt" $#; DB_HOST="$2"; shift 2 ;;
            -p|--port) need_arg "$opt" $#; DB_PORT="$2"; shift 2 ;;
            -U|--user|--username) need_arg "$opt" $#; DB_USER="$2"; shift 2 ;;
            -W|--password) PROMPT_PASSWORD=1; shift ;;
            --pgpassfile) need_arg "$opt" $#; PGPASSFILE_OPT="$2"; shift 2 ;;
            --maintenance-db) need_arg "$opt" $#; MAINTENANCE_DB="$2"; shift 2 ;;
            -d|--dbname) need_arg "$opt" $#; ((cli_d++)) || DB_NAMES=(); add_list DB_NAMES "$2"; shift 2 ;;
            --all) ALL_DBS=1; cli_all=1; shift ;;
            --exclude-db) need_arg "$opt" $#; ((cli_X++)) || EXCLUDE_DBS=(); add_list EXCLUDE_DBS "$2"; shift 2 ;;
            --stop-on-error) STOP_ON_ERROR=1; shift ;;
            -v|--set|--variable) need_arg "$opt" $#; ((cli_v++)) || VARS=(); VARS+=("$2"); shift 2 ;;
            --config) shift 2 ;;
            -l|--log-file) need_arg "$opt" $#; LOG_FILE="$2"; shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            --pg-bin) need_arg "$opt" $#; PG_BIN="$2"; shift 2 ;;
            --verbose) VERBOSE=1; shift ;;
            --production) need_arg "$opt" $#; ((cli_P++)) || PRODUCTION_DBS=(); add_list PRODUCTION_DBS "$2"; shift 2 ;;
            --production-host) need_arg "$opt" $#; ((cli_H++)) || PRODUCTION_HOSTS=(); add_list PRODUCTION_HOSTS "$2"; shift 2 ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            --confirm) need_arg "$opt" $#; ((cli_c++)) || CONFIRM_DBS=(); add_list CONFIRM_DBS "$2"; shift 2 ;;
            -f|--file) need_arg "$opt" $#; ((cli_f++)) || SQL_FILES=(); SQL_FILES+=("$2"); shift 2 ;;
            -D|--dir) need_arg "$opt" $#; SQL_DIR="$2"; shift 2 ;;
            --transaction) need_arg "$opt" $#; TXN_MODE="$2"; shift 2 ;;
            --track) TRACK=1; shift ;;
            --track-table) need_arg "$opt" $#; TRACK_TABLE="$2"; TRACK=1; shift 2 ;;
            --allow-changed) ALLOW_CHANGED=1; shift ;;
            --status) STATUS_ONLY=1; shift ;;
            -c|--command) need_arg "$opt" $#; QUERY_SQL="$2"; shift 2 ;;
            -F|--format) need_arg "$opt" $#; FORMAT="$2"; shift 2 ;;
            --no-header) HEADER=0; shift ;;
            --header) HEADER=1; shift ;;
            --delimiter) need_arg "$opt" $#; DELIMITER="$2"; shift 2 ;;
            -o|--output) need_arg "$opt" $#; OUTPUT_FILE="$2"; shift 2 ;;
            --output-dir) need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --name) need_arg "$opt" $#; OUTPUT_NAME="$2"; shift 2 ;;
            -Z|--compress) need_arg "$opt" $#; COMPRESS="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -r|--retention-days) need_arg "$opt" $#; RETENTION_DAYS="$2"; shift 2 ;;
            --read-write) READ_WRITE=1; shift ;;
            --timeout) need_arg "$opt" $#; TIMEOUT="$2"; shift 2 ;;
            --checks) need_arg "$opt" $#; ((cli_k++)) || CHECKS=(); add_list CHECKS "$2"; shift 2 ;;
            --warn) need_arg "$opt" $#; set_threshold WARN "$2"; shift 2 ;;
            --crit) need_arg "$opt" $#; set_threshold CRIT "$2"; shift 2 ;;
            --min-rows) need_arg "$opt" $#; MIN_ROWS="$2"; shift 2 ;;
            --top) need_arg "$opt" $#; TOP_N="$2"; shift 2 ;;
            --nagios) NAGIOS=1; shift ;;
            --alert-email) need_arg "$opt" $#; ((cli_ae++)) || ALERT_EMAILS=(); add_list ALERT_EMAILS "$2"; shift 2 ;;
            --alert-webhook) need_arg "$opt" $#; ((cli_aw++)) || ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$2"; shift 2 ;;
            --alert-webhook-format) need_arg "$opt" $#; ALERT_WEBHOOK_FORMAT="$2"; shift 2 ;;
            --alert-on) need_arg "$opt" $#; ALERT_ON="$2"; shift 2 ;;
            --alert-from) need_arg "$opt" $#; ALERT_FROM="$2"; shift 2 ;;
            --alert-test) ALERT_TEST=1; shift ;;
            --help|-\?) usage; exit 0 ;;
            --version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            -*) die 1 "Unknown option: $opt (see --help)" ;;
            *) die 1 "Unexpected argument: $opt" ;;
        esac
    done
    if (( cli_d && !cli_all )); then ALL_DBS=0; fi
    if (( cli_all && !cli_d )); then DB_NAMES=(); fi
    return 0
}

# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------
validate_alerts() {
    case "${ALERT_ON,,}" in failure|crit|always) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be failure, crit or always" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be slack or json" ;; esac
    local a
    for a in "${ALERT_EMAILS[@]}"; do
        [[ "$a" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $a"
    done
    for a in "${ALERT_WEBHOOKS[@]}"; do [[ "$a" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$a")"; done
    return 0
}

validate() {
    [[ "$DB_PORT" =~ ^[0-9]+$ ]] && (( DB_PORT >= 1 && DB_PORT <= 65535 )) || die 1 "Invalid port: $DB_PORT"
    (( ALL_DBS && ${#DB_NAMES[@]} )) && die 1 "Use either -d/--dbname or --all, not both"
    local d v
    for d in "${DB_NAMES[@]}"; do [[ "$d" != *=* ]] || die 1 "Database name must not contain '=': $d"; done
    for v in "${VARS[@]}"; do [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die 1 "-v must look like NAME=VALUE (got '$v')"; done
    if [[ -n "$PGPASSFILE_OPT" ]]; then
        [[ -r "$PGPASSFILE_OPT" ]] || die 1 "pgpassfile not readable: $PGPASSFILE_OPT"
        export PGPASSFILE="$PGPASSFILE_OPT"
    fi
    [[ -t 0 && -r /dev/tty ]] && INTERACTIVE=1
    case "$COMMAND" in
        migrate)
            (( ${#DB_NAMES[@]} || ALL_DBS )) || die 1 "migrate needs -d DB (or --all)"
            (( ${#SQL_FILES[@]} )) || [[ -n "$SQL_DIR" ]] || die 1 "migrate needs -f FILE and/or -D DIR"
            case "$TXN_MODE" in all|per-file|none) ;; *) die 1 "--transaction must be all, per-file or none" ;; esac
            [[ "$TRACK_TABLE" =~ ^([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)$ ]] || [[ "$TRACK_TABLE" =~ ^()([a-z_][a-z0-9_]*)$ ]] \
                || die 1 "--track-table must be [schema.]table in lower case letters, digits and _"
            TRK_SCHEMA="${BASH_REMATCH[1]:-public}"; TRK_TABLE="${BASH_REMATCH[2]}"
            (( STATUS_ONLY && !TRACK )) && die 1 "--status needs --track"
            collect_files ;;
        query)
            (( ${#DB_NAMES[@]} || ALL_DBS )) || die 1 "query needs -d DB (or --all)"
            if [[ -n "$QUERY_SQL" && ${#SQL_FILES[@]} -gt 0 ]]; then die 1 "Use either -c SQL or -f FILE"; fi
            if (( ${#SQL_FILES[@]} > 1 )); then die 1 "query takes a single -f FILE"; fi
            if (( ${#SQL_FILES[@]} )); then
                [[ -r "${SQL_FILES[0]}" ]] || die 2 "Query file not readable: ${SQL_FILES[0]}"
                QUERY_SQL="$(<"${SQL_FILES[0]}")"
            fi
            [[ -n "${QUERY_SQL//[[:space:]]/}" ]] || die 1 "query needs -c SQL or -f FILE"
            FORMAT="${FORMAT:-csv}"
            case "$FORMAT" in csv|tsv|json|ndjson|txt) ;; *) die 1 "query --format must be csv, tsv, json, ndjson or txt" ;; esac
            [[ -z "$DELIMITER" || ${#DELIMITER} -eq 1 ]] || die 1 "--delimiter must be a single character"
            [[ -z "$DELIMITER" || "$FORMAT" == csv ]] || die 1 "--delimiter only applies to csv"
            case "$COMPRESS" in none|gzip|zstd) ;; *) die 1 "--compress must be none, gzip or zstd" ;; esac
            [[ -n "$OUTPUT_FILE" && -n "$OUTPUT_DIR" ]] && die 1 "Use either -o FILE or --output-dir DIR"
            if (( ALL_DBS || ${#DB_NAMES[@]} > 1 )) && [[ -z "$OUTPUT_DIR" ]]; then die 1 "Several databases need --output-dir (one file per database)"; fi
            if [[ "$COMPRESS" != none ]] && [[ -z "$OUTPUT_DIR" && ( -z "$OUTPUT_FILE" || "$OUTPUT_FILE" == - ) ]]; then die 1 "--compress needs file output (-o FILE or --output-dir)"; fi
            [[ "$COMPRESS" == none ]] || command -v "$COMPRESS" >/dev/null 2>&1 || die 2 "$COMPRESS is not installed"
            [[ "$OUTPUT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--name may only contain letters, digits, . _ -"
            [[ -z "$RETENTION_DAYS" || ( "$RETENTION_DAYS" =~ ^[0-9]+$ && "$RETENTION_DAYS" -ge 1 ) ]] || die 1 "--retention-days must be >= 1"
            [[ -z "$RETENTION_DAYS" || -n "$OUTPUT_DIR" ]] || die 1 "--retention-days needs --output-dir"
            [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die 1 "--timeout must be whole seconds" ;;
        health)
            FORMAT="${FORMAT:-text}"
            case "$FORMAT" in text|json) ;; *) die 1 "health --format must be text or json" ;; esac
            (( ${#CHECKS[@]} )) || CHECKS=("${CHECKS_ALL[@]}")
            local c; for c in "${CHECKS[@]}"; do in_list "$c" "${CHECKS_ALL[@]}" || die 1 "Unknown check '$c' (${CHECKS_ALL[*]})"; done
            [[ "$MIN_ROWS" =~ ^[0-9]+$ && "$TOP_N" =~ ^[0-9]+$ ]] || die 1 "--min-rows/--top must be integers"
            (( ${#DB_NAMES[@]} )) || ALL_DBS=1 ;;
    esac
    return 0
}

collect_files() {   # FILE_PATHS / FILE_KEYS / FILE_SUMS in run order
    local f list=()
    for f in "${SQL_FILES[@]}"; do [[ -f "$f" && -r "$f" ]] || die 2 "SQL file not readable: $f"; list+=("$f"); done
    if [[ -n "$SQL_DIR" ]]; then
        [[ -d "$SQL_DIR" ]] || die 2 "Migration directory not found: $SQL_DIR"
        while IFS= read -r -d '' f; do list+=("$f"); done < <(find "$SQL_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.sql' -print0 | LC_ALL=C sort -zV)
    fi
    (( ${#list[@]} )) || die 2 "No .sql files found"
    local abs key
    for f in "${list[@]}"; do
        abs="$(cd "$(dirname -- "$f")" && pwd)/$(basename -- "$f")"
        [[ "$abs" != *$'\n'* ]] || die 1 "File names with newlines are not supported"
        key="$(basename -- "$f")"
        in_list "$key" "${FILE_KEYS[@]}" && die 1 "Duplicate migration file name: $key"
        if [[ "$TXN_MODE" != none ]] && grep -qiE '^[[:space:]]*(BEGIN|COMMIT|ROLLBACK|END|START[[:space:]]+TRANSACTION)[[:space:]]*;' "$abs"; then
            die 1 "$key contains its own BEGIN/COMMIT/ROLLBACK; remove it or use --transaction none"
        fi
        grep -qE '^[[:space:]]*\\(c|connect)([[:space:]]|$)' "$abs" && die 1 "$key uses \\connect, which is not allowed in migrations"
        FILE_PATHS+=("$abs"); FILE_KEYS+=("$key"); FILE_SUMS+=("$(sha256sum "$abs" | cut -d' ' -f1)")
    done
    return 0
}

resolve_databases() {
    (( ALL_DBS )) || return 0
    local out db pat skip
    out="$(psql_q "$MAINTENANCE_DB" "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname;")" \
        || die 2 "Cannot list databases via '$MAINTENANCE_DB': ${out//$'\n'/ }"
    DB_NAMES=()
    while IFS= read -r db; do
        [[ -n "$db" ]] || continue
        skip=0
        for pat in "${EXCLUDE_DBS[@]}"; do
            # shellcheck disable=SC2053
            if [[ "$db" == $pat ]]; then skip=1; break; fi
        done
        (( skip )) && continue
        DB_NAMES+=("$db")
    done <<<"$out"
    (( ${#DB_NAMES[@]} )) || die 1 "--all matched no databases"
    log_info "Databases selected by --all: ${DB_NAMES[*]}"
}

# ----------------------------------------------------------------------------
# Production guard
# ----------------------------------------------------------------------------
is_production() {
    local db="$1" p
    # shellcheck disable=SC2053
    for p in "${PRODUCTION_DBS[@]}"; do [[ "$db" == $p ]] && return 0; done
    # shellcheck disable=SC2053
    for p in "${PRODUCTION_HOSTS[@]}"; do [[ "$DB_HOST" == $p ]] && return 0; done
    return 1
}

production_guard() {   # production_guard <db> <what>
    local db="$1" what="$2" ans
    is_production "$db" || return 0
    if (( ASSUME_YES )); then log_warn "Production target '$db': $what confirmed by --yes"; return 0; fi
    if (( ${#CONFIRM_DBS[@]} )); then
        in_list "$db" "${CONFIRM_DBS[@]}" && { log_warn "Production target '$db': $what confirmed by --confirm"; return 0; }
        die 5 "Refusing: production database '$db' is not in --confirm (${CONFIRM_DBS[*]})"
    fi
    if (( INTERACTIVE )); then
        printf '\n*** PRODUCTION database "%s" on %s:%s ***\n%s\nType the database name to continue: ' "$db" "$DB_HOST" "$DB_PORT" "$what" >/dev/tty
        read -r ans </dev/tty || ans=""
        [[ "$ans" == "$db" ]] || die 5 "Not confirmed (typed '$ans'); nothing was changed"
        log_warn "Production target '$db': confirmed interactively"
        return 0
    fi
    die 5 "Refusing to $what on production database '$db' without confirmation. Re-run with --confirm $db or --yes."
}

# ----------------------------------------------------------------------------
# Streaming a psql run into the log (background + wait so signals are handled)
# ----------------------------------------------------------------------------
run_logged() {   # run_logged <tag> <cmd...>  ; returns the command's exit code
    local tag="$1" logfd reader_pid rc=0; shift
    exec {logfd}> >(while IFS= read -r l; do _log "$tag" "$l"; done)
    reader_pid=$!
    "$@" >&"$logfd" 2>&1 &
    WORK_PID=$!
    wait "$WORK_PID" || rc=$?
    WORK_PID=""
    exec {logfd}>&-
    wait "$reader_pid" 2>/dev/null || true
    return "$rc"
}

# ----------------------------------------------------------------------------
# migrate
# ----------------------------------------------------------------------------
psql_quote_path() { local q="${1//\\/\\\\}"; q="${q//\'/\'\'}"; printf "'%s'" "$q"; }

write_driver() {   # write_driver <indexes...>  (prints the driver script to stdout)
    local i
    local track_ddl='CREATE TABLE IF NOT EXISTS :"trk_schema".:"trk_table" (filename text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now(), applied_by text NOT NULL DEFAULT current_user);'
    {
        printf '\\set ON_ERROR_STOP on\n\\set ON_ERROR_ROLLBACK off\n'
        if [[ "$TXN_MODE" == all ]]; then
            printf 'BEGIN;\n'
            (( TRACK )) && printf '%s\nLOCK TABLE :"trk_schema".:"trk_table" IN SHARE ROW EXCLUSIVE MODE;\n' "$track_ddl"
        elif (( TRACK )); then
            printf '%s\n' "$track_ddl"
        fi
        for i in "$@"; do
            [[ "$TXN_MODE" == per-file ]] && printf 'BEGIN;\n'
            printf '\\echo >>> applying %s\n' "${FILE_KEYS[$i]}"
            printf '\\i %s\n' "$(psql_quote_path "${FILE_PATHS[$i]}")"
            (( TRACK )) && printf 'INSERT INTO :"trk_schema".:"trk_table" (filename, checksum) VALUES (:'"'"'mf_%d'"'"', :'"'"'mc_%d'"'"');\n' "$i" "$i"
            [[ "$TXN_MODE" == per-file ]] && printf 'COMMIT;\n'
        done
        [[ "$TXN_MODE" == all ]] && printf 'COMMIT;\n'
        printf '\\echo >>> all files applied\n'
    }
}

migrate_one_db() {
    local db="$1" out i state applied_sum
    local -A applied=()
    local pending=() drift=0
    STAGE="precheck"
    out="$(psql_q "$db" "SELECT pg_is_in_recovery();")" || die 2 "Cannot connect to '$db': ${out//$'\n'/ }"
    [[ "$out" == f ]] || die 2 "'$db' is a read-only standby"
    if (( TRACK )); then
        out="$(psql_q "$db" "SELECT to_regclass(:'trk_full') IS NOT NULL;")" || die 2 "Cannot read tracking table: ${out//$'\n'/ }"
        if [[ "$out" == t ]]; then
            out="$(psql_q "$db" 'SELECT filename, checksum FROM :"trk_schema".:"trk_table";')" || die 2 "Cannot read tracking table: ${out//$'\n'/ }"
            local f s
            while IFS="$US" read -r f s; do [[ -n "$f" ]] && applied["$f"]="$s"; done <<<"$out"
        fi
    fi
    (( STATUS_ONLY )) && printf '%-10s %-40s %s\n' "STATE" "FILE" "SHA256"
    for i in "${!FILE_PATHS[@]}"; do
        applied_sum="${applied[${FILE_KEYS[$i]}]:-}"
        if [[ -z "$applied_sum" ]]; then state="pending"; pending+=("$i")
        elif [[ "$applied_sum" == "${FILE_SUMS[$i]}" ]]; then state="applied"
        else
            state="CHANGED"; drift=1
            log_warn "${FILE_KEYS[$i]} was applied with sha256 ${applied_sum:0:12}... but the file now has ${FILE_SUMS[$i]:0:12}..."
        fi
        (( STATUS_ONLY )) && printf '%-10s %-40s %s\n' "$state" "${FILE_KEYS[$i]}" "${FILE_SUMS[$i]:0:12}"
    done
    CHILD_DETAIL="${#pending[@]} pending of ${#FILE_PATHS[@]}"
    if (( STATUS_ONLY )); then
        (( drift )) && { STAGE="checksum"; die 4 "Applied migration file(s) changed since they were applied"; }
        exit 0
    fi
    if (( drift && !ALLOW_CHANGED )); then
        STAGE="checksum"; die 4 "Applied migration file(s) changed; restore the original or pass --allow-changed to skip them"
    fi
    if (( ${#pending[@]} == 0 )); then log_info "Nothing to apply (${#FILE_PATHS[@]} file(s) already applied)"; CHILD_DETAIL="up to date"; exit 0; fi
    STAGE="guard"
    production_guard "$db" "run ${#pending[@]} migration file(s)"
    STAGE="migrate"
    local driver="$RESULT_DIR/driver.$BASHPID.sql"
    write_driver "${pending[@]}" >"$driver"
    local -a PSQL; psql_args
    for i in "${pending[@]}"; do PSQL+=(-v "mf_$i=${FILE_KEYS[$i]}" -v "mc_$i=${FILE_SUMS[$i]}"); done
    log_info "Applying ${#pending[@]} file(s) (transaction: $TXN_MODE$( (( TRACK )) && printf ', tracked in %s.%s' "$TRK_SCHEMA" "$TRK_TABLE")): $(for i in "${pending[@]}"; do printf '%s ' "${FILE_KEYS[$i]}"; done)"
    local rc=0
    run_logged PSQL "${PSQL[@]}" -q -d "$db" -f "$driver" || rc=$?
    rm -f -- "$driver"
    if (( rc != 0 )); then
        case "$TXN_MODE" in
            all) die 3 "Migration failed (psql exit $rc): the whole transaction was ROLLED BACK, '$db' is unchanged" ;;
            per-file) die 3 "Migration failed (psql exit $rc): the failing file was rolled back; files before it stay applied" ;;
            none) die 3 "Migration failed (psql exit $rc): statements before the error were NOT rolled back (--transaction none)" ;;
        esac
    fi
    CHILD_DETAIL="applied ${#pending[@]} file(s)"
    log_info "Migration OK: applied ${#pending[@]} file(s)"
}

migrate_dry_run() {
    local i
    log_info "DRY RUN - migrate on: ${DB_NAMES[*]:-(all databases)} (transaction: $TXN_MODE)"
    for i in "${!FILE_PATHS[@]}"; do log_info "  file ${FILE_KEYS[$i]}  sha256 ${FILE_SUMS[$i]:0:12}  ${FILE_PATHS[$i]}"; done
    (( TRACK )) && log_info "  tracking: $TRK_SCHEMA.$TRK_TABLE (already-applied files are skipped at run time; see --status)"
    local d; for d in "${DB_NAMES[@]}"; do is_production "$d" && log_info "  guard: '$d' is production -> needs --yes, --confirm $d or an interactive confirmation"; done
    log_info "  driver script:"
    write_driver "${!FILE_PATHS[@]}"
}

# ----------------------------------------------------------------------------
# query
# ----------------------------------------------------------------------------
query_sql_for_format() {
    local body="$QUERY_SQL"
    body="${body%"${body##*[![:space:];]}"}"   # strip trailing ; and whitespace
    case "$FORMAT" in
        json)   printf 'SELECT coalesce(json_agg(q), %s) FROM (\n%s\n) q;\n' "'[]'::json" "$body" ;;
        ndjson) printf 'SELECT row_to_json(q) FROM (\n%s\n) q;\n' "$body" ;;
        *)      printf '%s;\n' "$body" ;;
    esac
}

query_dest() {   # prints destination path or '-'
    local db="$1" ext="$FORMAT"
    [[ "$COMPRESS" == gzip ]] && ext+=".gz"
    [[ "$COMPRESS" == zstd ]] && ext+=".zst"
    if [[ -n "$OUTPUT_DIR" ]]; then printf '%s/%s_%s_%s.%s' "${OUTPUT_DIR%/}" "$OUTPUT_NAME" "$db" "$(date '+%Y%m%d_%H%M%S')" "$ext"
    else printf '%s' "${OUTPUT_FILE:--}"; fi
}

query_one_db() {
    local db="$1" out dest tmp errf sql
    local -a fmt=() comp=(cat)
    STAGE="precheck"
    out="$(psql_q "$db" "SELECT 1;")" || die 2 "Cannot connect to '$db': ${out//$'\n'/ }"
    if (( READ_WRITE )); then STAGE="guard"; production_guard "$db" "run a read-write query"; fi
    case "$FORMAT" in
        csv) fmt=(--csv); [[ -n "$DELIMITER" ]] && fmt+=(-P "csv_fieldsep=$DELIMITER") ;;
        tsv) fmt=(--csv -P "csv_fieldsep=$TAB") ;;
        json|ndjson) fmt=(-A -t) ;;
        txt) fmt=(-P footer=off) ;;
    esac
    [[ "$FORMAT" == csv || "$FORMAT" == tsv || "$FORMAT" == txt ]] && (( !HEADER )) && fmt+=(-t)
    [[ "$COMPRESS" == gzip ]] && comp=(gzip -c)
    [[ "$COMPRESS" == zstd ]] && comp=(zstd -q -c)
    sql="$(query_sql_for_format)"
    local opts="${PGOPTIONS:-}"
    (( READ_WRITE )) || opts+=" -c default_transaction_read_only=on"
    (( TIMEOUT > 0 )) && opts+=" -c statement_timeout=${TIMEOUT}s"
    local -a PSQL; psql_args
    dest="$(query_dest "$db")"
    errf="$RESULT_DIR/err.$BASHPID"
    STAGE="query"
    if [[ "$dest" == - ]]; then
        printf '%s' "$sql" | PGOPTIONS="$opts" "${PSQL[@]}" -q -d "$db" "${fmt[@]}" -f - 2>"$errf" \
            || die 3 "Query failed on '$db': $(tr '\n' ' ' <"$errf")"
        CHILD_DETAIL="stdout"
        return 0
    fi
    if [[ -e "$dest" && "$FORCE" -eq 0 ]]; then STAGE="output"; die 6 "Output exists, refusing to overwrite (use --force): $dest"; fi
    mkdir -p -- "$(dirname -- "$dest")" 2>/dev/null || { STAGE="output"; die 6 "Cannot create output directory for $dest"; }
    [[ -w "$(dirname -- "$dest")" ]] || { STAGE="output"; die 6 "Output directory not writable: $(dirname -- "$dest")"; }
    tmp="$dest.part.$BASHPID"
    local -a st
    set +e
    printf '%s' "$sql" | PGOPTIONS="$opts" "${PSQL[@]}" -q -d "$db" "${fmt[@]}" -f - 2>"$errf" | "${comp[@]}" >"$tmp"
    st=("${PIPESTATUS[@]}")
    set -e
    if (( st[1] != 0 )) && [[ -s "$errf" ]]; then rm -f -- "$tmp"; die 3 "Query failed on '$db': $(tr '\n' ' ' <"$errf")"; fi
    if (( st[1] != 0 || st[2] != 0 )) || ! mv -f -- "$tmp" "$dest"; then rm -f -- "$tmp" 2>/dev/null; STAGE="output"; die 6 "Cannot write $dest"; fi
    local info
    info="$(du -h "$dest" | cut -f1)"
    [[ "$COMPRESS" == none ]] && info+=", $(wc -l <"$dest" | tr -d ' ') line(s)"
    log_info "Wrote $dest ($info)"
    CHILD_DETAIL="$dest"
    apply_retention
}

apply_retention() {
    [[ -n "$RETENTION_DAYS" && -n "$OUTPUT_DIR" ]] || return 0
    local p n=0
    while IFS= read -r -d '' p; do
        rm -f -- "$p" && { log_info "Retention: deleted $p"; n=$((n + 1)); }
    done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type f -name "${OUTPUT_NAME}_*_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].*" -mtime +"$RETENTION_DAYS" -print0)
    (( n )) || log_info "Retention: nothing older than $RETENTION_DAYS day(s)"
    return 0
}

# ----------------------------------------------------------------------------
# health
# ----------------------------------------------------------------------------
health_sql() {   # health_sql server|db  -> SQL printing check|status|value|detail rows
    local scope="$1" c
    for c in "${CHECKS[@]}"; do
        case "$scope:$c" in
        server:connections) cat <<'SQL'
WITH a AS (SELECT coalesce(state, 'unknown') st FROM pg_stat_activity WHERE backend_type = 'client backend'),
     s AS (SELECT count(*) used, (SELECT string_agg(st || '=' || n, ', ' ORDER BY n DESC) FROM (SELECT st, count(*) n FROM a GROUP BY st) x) states FROM a),
     m AS (SELECT current_setting('max_connections')::numeric mx)
SELECT 'connections', CASE WHEN 100.0*used/mx >= :w_connections THEN (CASE WHEN 100.0*used/mx >= :c_connections THEN 'CRIT' ELSE 'WARN' END) ELSE 'OK' END,
       used || '/' || mx || ' (' || round(100.0*used/mx, 1) || '%)', coalesce(states, '-') FROM s, m;
SQL
        ;;
        server:long_running) cat <<'SQL'
WITH q AS (SELECT pid, datname, state, extract(epoch FROM now() - CASE WHEN state = 'active' THEN query_start ELSE xact_start END)::int secs,
                  left(regexp_replace(query, '\s+', ' ', 'g'), 80) qry
           FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'
             AND state IN ('active', 'idle in transaction', 'idle in transaction (aborted)')
             AND CASE WHEN state = 'active' THEN query_start ELSE xact_start END IS NOT NULL)
SELECT 'long_running', CASE WHEN max(secs) >= :c_long_running THEN 'CRIT' WHEN max(secs) >= :w_long_running THEN 'WARN' ELSE 'OK' END,
       coalesce(max(secs), 0) || 's max', count(*) FILTER (WHERE secs >= :w_long_running) || ' over ' || :w_long_running || 's'
       || coalesce('; longest: pid ' || (array_agg(pid ORDER BY secs DESC))[1] || ' db ' || (array_agg(datname ORDER BY secs DESC))[1]
       || ' ' || (array_agg(state ORDER BY secs DESC))[1] || ': ' || (array_agg(qry ORDER BY secs DESC))[1], '') FROM q;
SQL
        ;;
        server:blocking) cat <<'SQL'
WITH b AS (SELECT pid, datname, pg_blocking_pids(pid) blockers, extract(epoch FROM now() - query_start)::int secs
           FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0)
SELECT 'blocking', CASE WHEN max(secs) >= :c_blocking THEN 'CRIT' WHEN max(secs) >= :w_blocking THEN 'WARN' ELSE 'OK' END,
       count(*) || ' blocked, ' || coalesce(max(secs), 0) || 's max wait',
       coalesce(string_agg('pid ' || pid || ' (' || datname || ') waits ' || secs || 's on ' || array_to_string(blockers, ','), '; '), 'no blocked sessions') FROM b;
SQL
        ;;
        server:replication) cat <<'SQL'
SELECT 'replication', CASE WHEN lag IS NULL THEN 'OK' WHEN lag >= :c_replication THEN 'CRIT' WHEN lag >= :w_replication THEN 'WARN' ELSE 'OK' END,
       coalesce(round(lag)::text || 's', 'n/a'), detail
FROM (SELECT CASE WHEN pg_is_in_recovery() THEN extract(epoch FROM now() - pg_last_xact_replay_timestamp())
                  ELSE (SELECT max(extract(epoch FROM replay_lag)) FROM pg_stat_replication) END AS lag,
             CASE WHEN pg_is_in_recovery() THEN 'standby: time since last replayed transaction'
                  ELSE (SELECT coalesce(count(*) || ' replica(s): ' || string_agg(coalesce(application_name, '?') || ' ' || state || ' '
                        || coalesce(pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), '?') || ' behind', ', '), 'primary, no replicas')
                        FROM pg_stat_replication) END AS detail) r;
SQL
        ;;
        db:db_size) cat <<'SQL'
SELECT 'db_size', CASE WHEN :c_db_size > 0 AND s >= :c_db_size * 1048576 THEN 'CRIT' WHEN :w_db_size > 0 AND s >= :w_db_size * 1048576 THEN 'WARN' ELSE 'OK' END,
       pg_size_pretty(s), 'largest: ' || coalesce((SELECT string_agg(n || ' ' || pg_size_pretty(sz), ', ' ORDER BY sz DESC) FROM (
           SELECT c.oid::regclass::text n, pg_total_relation_size(c.oid) sz FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
           WHERE c.relkind IN ('r', 'p', 'm') AND ns.nspname NOT IN ('pg_catalog', 'information_schema') AND ns.nspname !~ '^pg_'
           ORDER BY sz DESC LIMIT :top_n) t), '-')
FROM (SELECT pg_database_size(current_database()) s) x;
SQL
        ;;
        db:cache_hit) cat <<'SQL'
SELECT 'cache_hit', CASE WHEN blks_hit + blks_read < 1000 OR ratio IS NULL THEN 'OK' WHEN ratio < :c_cache_hit THEN 'CRIT' WHEN ratio < :w_cache_hit THEN 'WARN' ELSE 'OK' END,
       coalesce(ratio::text || '%', 'n/a'), blks_hit || ' hits / ' || blks_read || ' reads' || CASE WHEN blks_hit + blks_read < 1000 THEN ' (too little traffic to judge)' ELSE '' END
FROM (SELECT blks_hit, blks_read, round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) ratio FROM pg_stat_database WHERE datname = current_database()) s;
SQL
        ;;
        db:bloat) cat <<'SQL'
WITH t AS (SELECT relid::regclass::text n, n_dead_tup dead, round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) pct
           FROM pg_stat_user_tables WHERE n_live_tup + n_dead_tup >= :min_rows)
SELECT 'bloat', CASE WHEN max(pct) >= :c_bloat THEN 'CRIT' WHEN max(pct) >= :w_bloat THEN 'WARN' ELSE 'OK' END,
       coalesce(max(pct), 0) || '% dead (max)',
       coalesce((SELECT string_agg(n || ' ' || pct || '% (' || dead || ' dead rows)', ', ' ORDER BY pct DESC)
                 FROM (SELECT * FROM t WHERE pct >= :w_bloat ORDER BY pct DESC LIMIT 5) x), 'no table over ' || :w_bloat || '% dead rows') FROM t;
SQL
        ;;
        db:vacuum) cat <<'SQL'
WITH t AS (SELECT relid::regclass::text n, n_dead_tup dead, n_mod_since_analyze mods,
                  coalesce(extract(epoch FROM now() - greatest(last_vacuum, last_autovacuum)) / 86400, :w_vacuum) vd,
                  coalesce(extract(epoch FROM now() - greatest(last_analyze, last_autoanalyze)) / 86400, :w_vacuum) ad
           FROM pg_stat_user_tables),
     s AS (SELECT * FROM t WHERE (dead >= :min_rows AND vd >= :w_vacuum) OR (mods >= :min_rows AND ad >= :w_vacuum))
SELECT 'vacuum', CASE WHEN count(*) FILTER (WHERE vd >= :c_vacuum OR ad >= :c_vacuum) > 0 THEN 'CRIT' WHEN count(*) > 0 THEN 'WARN' ELSE 'OK' END,
       count(*) || ' table(s) need vacuum/analyze',
       coalesce(string_agg(n || ' (' || dead || ' dead, ' || mods || ' changed since analyze)', ', '), 'all tables recently vacuumed/analyzed') FROM s;
SQL
        ;;
        db:wraparound) cat <<'SQL'
SELECT 'wraparound', CASE WHEN a >= :c_wraparound THEN 'CRIT' WHEN a >= :w_wraparound THEN 'WARN' ELSE 'OK' END,
       a || ' xids', round(100.0 * a / 2147483647, 1) || '% of the wraparound limit' FROM (SELECT age(datfrozenxid) a FROM pg_database WHERE datname = current_database()) x;
SQL
        ;;
        esac
    done
}

health_one() {   # health_one <db|(server)> : writes rows to CHILD_RESULT_FILE.rows
    local target="$1" db scope sql out c
    local -a thr=()
    if [[ "$target" == "(server)" ]]; then db="$MAINTENANCE_DB"; scope=server; else db="$target"; scope=db; fi
    STAGE="health"
    sql="$(health_sql "$scope")"
    [[ -n "$sql" ]] || exit 0
    for c in "${CHECKS_ALL[@]}"; do thr+=(-v "w_$c=${WARN[$c]}" -v "c_$c=${CRIT[$c]}"); done
    thr+=(-v "min_rows=$MIN_ROWS" -v "top_n=$TOP_N")
    if ! out="$(PGOPTIONS="${PGOPTIONS:-} -c default_transaction_read_only=on -c statement_timeout=30s" psql_q "$db" "$sql" "${thr[@]}")"; then
        printf '%s%s%s%s%s%s%s\n' "$target" "$US" "connect" "$US" "CRIT" "$US" "error$US${out//$'\n'/ }" >"$CHILD_RESULT_FILE.rows"
        exit 0
    fi
    while IFS= read -r c; do [[ -n "$c" ]] && printf '%s%s%s\n' "$target" "$US" "$c"; done <<<"$out" >"$CHILD_RESULT_FILE.rows"
    exit 0
}

health_report() {   # merge rows, print report, set HEALTH_STATUS
    local f db chk st val det warn=0 crit=0 rows=() r first=1
    for f in "$RESULT_DIR"/*.res.rows; do [[ -f "$f" ]] && while IFS= read -r r; do rows+=("$r"); done <"$f"; done
    for r in "${rows[@]}"; do
        IFS="$US" read -r db chk st val det <<<"$r"
        [[ "$st" == WARN ]] && warn=$((warn + 1))
        [[ "$st" == CRIT ]] && crit=$((crit + 1))
    done
    if (( crit )); then HEALTH_STATUS=CRIT; elif (( warn )); then HEALTH_STATUS=WARN; else HEALTH_STATUS=OK; fi
    if (( NAGIOS )); then
        local word=OK msg=""
        [[ "$HEALTH_STATUS" == WARN ]] && word=WARNING
        [[ "$HEALTH_STATUS" == CRIT ]] && word=CRITICAL
        for r in "${rows[@]}"; do IFS="$US" read -r db chk st val det <<<"$r"; [[ "$st" != OK ]] && msg+="$db/$chk=$val ($st); "; done
        printf 'PSQL_HEALTH %s - %d crit, %d warn, %d checks%s\n' "$word" "$crit" "$warn" "${#rows[@]}" "${msg:+: ${msg%; }}"
    elif [[ "$FORMAT" == json ]]; then
        printf '{"status":"%s","host":"%s","port":%d,"checked_at":"%s","checks":[' "$HEALTH_STATUS" "$(json_escape "$DB_HOST")" "$DB_PORT" "$(_ts)"
        for r in "${rows[@]}"; do
            IFS="$US" read -r db chk st val det <<<"$r"
            (( first )) || printf ','; first=0
            printf '{"database":"%s","check":"%s","status":"%s","value":"%s","detail":"%s"}' \
                "$(json_escape "$db")" "$chk" "$st" "$(json_escape "$val")" "$(json_escape "$det")"
        done
        printf ']}\n'
    else
        printf '%-16s %-13s %-6s %-32s %s\n' "DATABASE" "CHECK" "STATUS" "VALUE" "DETAIL"
        for r in "${rows[@]}"; do
            IFS="$US" read -r db chk st val det <<<"$r"
            printf '%-16s %-13s %-6s %-32s %s\n' "$db" "$chk" "$st" "$val" "$det"
        done
        printf 'Overall: %s (%d crit, %d warn)\n' "$HEALTH_STATUS" "$crit" "$warn"
    fi
    HEALTH_TEXT="$(for r in "${rows[@]}"; do IFS="$US" read -r db chk st val det <<<"$r"; [[ "$st" != OK ]] && printf '%s %s %s %s %s\n' "$db" "$chk" "$st" "$val" "$det"; done; true)"
}

# ----------------------------------------------------------------------------
# Per-database child process
# ----------------------------------------------------------------------------
# shellcheck disable=SC2317
child_on_exit() {
    local rc=$?
    printf '%s|%s|%s|%s\n' "$CURRENT_DB" "$rc" "$STAGE" "${CHILD_DETAIL//|//}" >"$CHILD_RESULT_FILE" 2>/dev/null || true
}
# shellcheck disable=SC2317
child_on_signal() {
    _log ERROR "Interrupted by signal $1"
    if [[ -n "$WORK_PID" ]]; then
        # SIGINT makes psql send a cancel request, so the server stops the running
        # statement (and rolls back) right away instead of finishing it.
        kill -INT "$WORK_PID" 2>/dev/null || true
        local n=0
        while kill -0 "$WORK_PID" 2>/dev/null && (( n < 50 )); do sleep 0.1; n=$((n + 1)); done
        if kill -0 "$WORK_PID" 2>/dev/null; then
            if command -v pkill >/dev/null 2>&1; then pkill -TERM -P "$BASHPID" 2>/dev/null || true; else kill -TERM "$WORK_PID" 2>/dev/null || true; fi
        fi
        wait "$WORK_PID" 2>/dev/null || true
    fi
    exit 130
}
child_main() {   # child_main <db> <result-file>
    IS_CHILD=1; CURRENT_DB="$1"; CHILD_RESULT_FILE="$2"; DB_NAME="$1"; CHILD_DETAIL=""
    trap child_on_exit EXIT
    trap 'child_on_signal TERM' TERM
    trap 'child_on_signal INT' INT
    case "$COMMAND" in
        migrate) migrate_one_db "$1" ;;
        query)   query_one_db "$1" ;;
        health)  health_one "$1" ;;
    esac
    STAGE="done"
    exit 0
}

# ----------------------------------------------------------------------------
# Summary and alerts
# ----------------------------------------------------------------------------
summary_lines() {
    local r db rc stage det status
    printf '%-24s %-9s %-10s %s\n' "DATABASE" "STATUS" "STAGE" "DETAIL"
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r db rc stage det <<<"$r"
        if [[ "$rc" == skipped ]]; then status=SKIPPED; stage="-"; elif (( rc == 0 )); then status=OK; stage="-"; else status="FAIL($rc)"; fi
        printf '%-24s %-9s %-10s %s\n' "$db" "$status" "$stage" "${det:--}"
    done
}
redact_text() { sed -E 's/(password[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1*****/Ig; s#(://[^:/@[:space:]]+:)[^@/[:space:]]+@#\1*****@#g'; }

build_alert_body() {
    local rc="$1" status="$2"
    {
        printf 'psql_wrapper %s %s on %s\n\n' "$COMMAND" "$status" "$(hostname 2>/dev/null || echo unknown)"
        printf 'Server     : %s:%s (user %s)\n' "$DB_HOST" "$DB_PORT" "$DB_USER"
        printf 'Databases  : %s\n' "${DB_NAMES[*]:--}"
        printf 'Exit code  : %s\n' "$rc"
        (( rc != 0 )) && printf 'Failed at  : %s\n' "$STAGE"
        printf 'Started    : %s\nDuration   : %s\n' "$RUN_START_TS" "$(fmt_duration $(( SECONDS - RUN_START )))"
        [[ "$COMMAND" == health ]] && printf 'Health     : %s\n%s\n' "$HEALTH_STATUS" "${HEALTH_TEXT:-}"
        if (( ${#RESULTS[@]} )) && [[ "$COMMAND" != health ]]; then printf '\n'; summary_lines; fi
        if (( rc != 0 )) && [[ -n "$LOG_FILE" && -r "$LOG_FILE" ]]; then printf '\nLast %s log lines:\n' "$ALERT_LOG_LINES"; tail -n "$ALERT_LOG_LINES" "$LOG_FILE"; fi
    } | redact_text
}

build_alert_json() {
    local rc="$1" status="$2" body="$3"
    if [[ "$ALERT_WEBHOOK_FORMAT" == slack ]]; then
        local head="${body%%$'\n'*}" rest="${body#*$'\n'}"
        printf '{"text": "%s"}' "$(json_escape "*${head}*"$'\n''```'"${rest}"'```')"
        return 0
    fi
    printf '{"tool":"psql_wrapper","command":"%s","status":"%s","exit_code":%d,"failed_stage":"%s","health":"%s","host":"%s","server":"%s:%s","user":"%s","started":"%s","duration_seconds":%d,"databases":"%s","text":"%s"}' \
        "$COMMAND" "$status" "$rc" "$( (( rc != 0 )) && json_escape "$STAGE")" "${HEALTH_STATUS:-}" \
        "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" "$(json_escape "$DB_HOST")" "$DB_PORT" "$(json_escape "$DB_USER")" \
        "$(json_escape "$RUN_START_TS")" $(( SECONDS - RUN_START )) "$(json_escape "${DB_NAMES[*]:-}")" "$(json_escape "$body")"
}

send_email_alert() {
    local subject="$1" body="$2" mailer="" to
    local -a tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout 60)
    if command -v mail >/dev/null 2>&1; then mailer="mail"
    elif command -v mailx >/dev/null 2>&1; then mailer="mailx"
    elif command -v sendmail >/dev/null 2>&1; then mailer="sendmail"
    elif [[ -x /usr/sbin/sendmail ]]; then mailer=/usr/sbin/sendmail
    else log_warn "Alert: no mail/mailx/sendmail found"; return 1; fi
    if [[ "$mailer" == mail || "$mailer" == mailx ]]; then
        local -a from=(); [[ -n "$ALERT_FROM" ]] && from=(-r "$ALERT_FROM")
        printf '%s\n' "$body" | "${tmo[@]}" "$mailer" "${from[@]}" -s "$subject" -- "${ALERT_EMAILS[@]}"
    else
        to="$(IFS=,; printf '%s' "${ALERT_EMAILS[*]}")"
        { [[ -n "$ALERT_FROM" ]] && printf 'From: %s\n' "$ALERT_FROM"
          printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' "$to" "$subject" "$body"; } | "${tmo[@]}" "$mailer" -t -oi
    fi
}

send_webhook_alert() {
    local url="$1" json="$2" out
    command -v curl >/dev/null 2>&1 || { log_warn "Alert: curl not installed; webhook skipped"; return 1; }
    out="$(printf 'url = "%s"\n' "${url//\"/\\\"}" | curl -sS --fail --max-time 20 --retry 2 \
            -H 'Content-Type: application/json' --data-binary "$json" -o /dev/null -w '%{http_code}' -K - 2>&1)" \
        || { log_warn "Alert: webhook $(redact_url "$url") failed: ${out%%$'\n'*}"; return 1; }
    log_info "Alert: webhook $(redact_url "$url") -> HTTP $out"
}

send_alerts() {   # never fails, never changes the exit code
    local rc="$1" mode="${2:-}" status subject body json url
    (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || return 0
    if [[ "$mode" != test ]]; then
        case "$ALERT_ON" in
            failure) (( rc == 0 )) && return 0 ;;
            crit)    (( rc == 0 || rc == 10 )) && return 0 ;;
        esac
    fi
    if [[ "$mode" == test ]]; then status=TEST; elif (( rc == 0 )); then status=SUCCESS
    elif (( rc == 10 )); then status=WARNING; elif (( rc == 11 )); then status=CRITICAL; else status=FAILED; fi
    subject="[psql_wrapper] $COMMAND $status: ${DB_NAMES[*]:-server} on $DB_HOST (exit $rc)"
    (( ${#subject} > 120 )) && subject="${subject:0:117}..."
    body="$(build_alert_body "$rc" "$status")"
    if (( ${#ALERT_EMAILS[@]} )); then
        if send_email_alert "$subject" "$body"; then log_info "Alert: e-mail sent to ${ALERT_EMAILS[*]}"; else log_warn "Alert: e-mail failed"; fi
    fi
    if (( ${#ALERT_WEBHOOKS[@]} )); then
        json="$(build_alert_json "$rc" "$status" "$subject"$'\n\n'"$body")"
        for url in "${ALERT_WEBHOOKS[@]}"; do send_webhook_alert "$url" "$json" || true; done
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Parent exit / signal handling
# ----------------------------------------------------------------------------
# shellcheck disable=SC2317
on_exit() {
    local rc=$?
    (( IS_CHILD )) && return 0
    trap - EXIT INT TERM
    set +e
    (( MAIN_STARTED )) || exit "$rc"
    DB_NAME=""
    if (( ${#RESULTS[@]} )) && [[ "$COMMAND" != health ]]; then
        local line; log_info "Summary:"; while IFS= read -r line; do _log INFO "  $line"; done < <(summary_lines)
    fi
    if (( rc == 0 )); then _log INFO "Run finished OK in $(fmt_duration $(( SECONDS - RUN_START )))"
    else _log ERROR "Run finished with exit code $rc (stage: $STAGE)"; fi
    send_alerts "$rc" || true
    [[ -n "$RESULT_DIR" ]] && rm -rf -- "$RESULT_DIR"
    if (( NAGIOS )) && [[ "$COMMAND" == health ]]; then
        case "$rc" in 0) exit 0 ;; 10) exit 1 ;; 11) exit 2 ;; *) exit 3 ;; esac
    fi
    exit "$rc"
}
# shellcheck disable=SC2317
on_signal() {
    _log ERROR "Interrupted by signal $1"
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true; wait "$CHILD_PID" 2>/dev/null || true
    fi
    STAGE="interrupted"
    exit 130
}

# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    trap on_exit EXIT
    RUN_START_TS="$(_ts)"
    STAGE="validate"
    validate_alerts
    if (( ALERT_TEST )) || [[ "$COMMAND" == alert-test ]]; then
        COMMAND="${COMMAND/alert-test/test}"; log_info "Sending test alert..."; send_alerts 0 test; exit 0
    fi
    (( DRY_RUN )) || MAIN_STARTED=1
    command -v "$(bin psql)" >/dev/null 2>&1 || die 2 "psql not found (install postgresql-client or use --pg-bin)"
    validate
    if (( PROMPT_PASSWORD && !DRY_RUN )); then
        [[ -r /dev/tty ]] || die 1 "-W needs an interactive terminal; use ~/.pgpass or PGPASSFILE"
        read -rsp "Password for $DB_USER@$DB_HOST:$DB_PORT: " PGPASSWORD </dev/tty; printf '\n' >&2; export PGPASSWORD
    fi
    if (( DRY_RUN )); then
        case "$COMMAND" in
            migrate) migrate_dry_run ;;
            query)   log_info "DRY RUN - query on ${DB_NAMES[*]:-(all)} -> $(query_dest "${DB_NAMES[0]:-DB}") (format $FORMAT, $( (( READ_WRITE )) && echo read-write || echo read-only))"; query_sql_for_format ;;
            health)  log_info "DRY RUN - health checks: ${CHECKS[*]}"; local c; for c in "${CHECKS[@]}"; do log_info "  $c warn=${WARN[$c]} crit=${CRIT[$c]}"; done ;;
        esac
        exit 0
    fi
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    log_debug "$SCRIPT_NAME v$SCRIPT_VERSION $COMMAND host=$DB_HOST port=$DB_PORT user=$DB_USER"
    STAGE="precheck"
    resolve_databases
    RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/psql_wrapper.XXXXXX")"
    local targets=("${DB_NAMES[@]}") i db rc worst=0 first_fail=""
    [[ "$COMMAND" == health ]] && targets=("(server)" "${DB_NAMES[@]}")
    for i in "${!targets[@]}"; do
        db="${targets[$i]}"
        if [[ -n "$first_fail" ]] && (( STOP_ON_ERROR )); then RESULTS+=("$db|skipped|-|-"); continue; fi
        CURRENT_DB="$db"; CURRENT_RES="$RESULT_DIR/$(printf '%04d' "$i").res"
        ( child_main "$db" "$CURRENT_RES" ) &
        CHILD_PID=$!
        rc=0; wait "$CHILD_PID" || rc=$?
        CHILD_PID=""
        if [[ -s "$CURRENT_RES" ]]; then RESULTS+=("$(<"$CURRENT_RES")"); else RESULTS+=("$db|$rc|unknown|-"); fi
        if (( rc != 0 )); then
            (( rc > worst )) && worst=$rc
            [[ -n "$first_fail" ]] || first_fail="$(cut -d'|' -f3 <<<"${RESULTS[-1]}") ($db)"
        fi
    done
    if [[ "$COMMAND" == health ]]; then
        health_report
        if (( worst == 0 )); then
            case "$HEALTH_STATUS" in WARN) STAGE="health"; exit 10 ;; CRIT) STAGE="health"; exit 11 ;; esac
        fi
    fi
    if (( worst != 0 )); then STAGE="$first_fail"; exit "$worst"; fi
    STAGE="done"
    exit 0
}

main "$@"
