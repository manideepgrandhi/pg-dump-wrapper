#!/usr/bin/env bash
#
# pg_dump_wrapper.sh - opinionated, cron-friendly wrapper around PostgreSQL pg_dump
#
# Features: one or many databases per run (-d list or --all), long/short options,
# optional key=value config file (CLI overrides it), timestamped output names,
# logging to console + file, pre-checks (binaries, connectivity, disk space),
# dry-run, post-dump verification, sha256 checksum, safe per-database retention,
# removal of partial output on failure, and e-mail / webhook alerts.
#
# Exit codes (for multi-database runs: the highest code of any failed database):
#   0    success
#   1    usage / validation error
#   2    pre-check failure (missing binary, cannot connect, output dir problem)
#   3    pg_dump failed
#   4    post-dump verification or checksum failed
#   5    retention cleanup failed (the backup itself succeeded)
#   130  interrupted (INT/TERM)
#
# Passwords are NEVER accepted on the command line. Use ~/.pgpass, PGPASSFILE
# (or the pgpassfile= config key), the PGPASSWORD environment variable, or -W to prompt.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.0.0"

# ----------------------------------------------------------------------------
# Defaults (lowest precedence: defaults < config file < command line)
# ----------------------------------------------------------------------------
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_USER="${PGUSER:-${USER:-postgres}}"
DB_NAMES=()
ALL_DBS=0
EXCLUDE_DBS=()
MAINTENANCE_DB="postgres"
STOP_ON_ERROR=0
FORMAT="custom"
COMPRESS=""
JOBS=1
SCHEMA_ONLY=0
DATA_ONLY=0
NO_OWNER=0
NO_PRIVILEGES=0
CLEAN=0
IF_EXISTS=0
CREATE=0
INCLUDE_SCHEMAS=()
EXCLUDE_SCHEMAS=()
INCLUDE_TABLES=()
EXCLUDE_TABLES=()
EXCLUDE_TABLE_DATA=()
OUTPUT_DIR="."
FILE_NAME=""
LOG_FILE=""
RETENTION_DAYS=""
MIN_FREE_MB=1024
DRY_RUN=0
VERIFY=0
CHECKSUM=0
SKIP_PRECHECK=0
PROMPT_PASSWORD=0
VERBOSE=0
PG_BIN=""
PGPASSFILE_OPT=""
CONFIG_FILE=""
EXTRA_ARGS=()
# alerts
ALERT_EMAILS=()
ALERT_WEBHOOKS=()
ALERT_ON="failure"
ALERT_WEBHOOK_FORMAT="slack"
ALERT_FROM=""
ALERT_TEST=0
ALERT_LOG_LINES=20

# runtime state (parent)
DB_NAME=""
FILE_NAME_OVERRIDE=""
RUN_START=$SECONDS
RUN_START_TS=""
STAGE="init"
RESULT_DIR=""
CHILD_PID=""
RESULTS=()          # "db|rc|stage|size|duration|file"
MAIN_STARTED=0
# runtime state (per-database child)
OUTPUT_PATH=""
DUMP_STARTED=0
DUMP_DONE=0
PG_DUMP_PID=""
IS_CHILD=0
CHILD_RESULT_FILE=""
CHILD_START=0

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log() {
    local level="$1"; shift
    local line
    line="$(_ts) [$level]${DB_NAME:+ [$DB_NAME]} $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    fi
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }

die() {  # die <exit_code> <message...>
    local code="$1"; shift
    log_error "$@"
    exit "$code"
}

# ----------------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------------
usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - wrapper around pg_dump

Usage: $SCRIPT_NAME (-d DB[,DB...] | --all) [options] [-- extra pg_dump args]

Connection:
  -h, --host HOST              Server host or socket dir          (default: \$PGHOST or localhost)
  -p, --port PORT              Server port                        (default: \$PGPORT or 5432)
  -U, --user USER              Database user                      (default: \$PGUSER or \$USER)
  -W, --password               Prompt for password (interactive only; default never prompts)
      --pgpassfile FILE        Use this .pgpass file (sets PGPASSFILE)

Databases (each database gets its own dump file):
  -d, --dbname DB              Database(s) to dump; repeatable or comma-separated
      --all                    Dump every non-template database that allows connections
      --exclude-db PATTERN     With --all: skip databases matching shell glob    [repeatable]
      --maintenance-db DB      Database used to list databases for --all  (default: postgres)
      --stop-on-error          Stop at the first failed database (default: continue)

Output format:
  -F, --format FMT             plain|custom|directory|tar (p|c|d|t)  (default: custom)
  -Z, --compress LEVEL         0-9, or METHOD[:LEVEL] e.g. gzip:6, zstd:3, lz4 (PG16+ pg_dump)
  -j, --jobs N                 Parallel dump jobs (directory format only)

Scope (repeatable options may be given many times or comma-separated):
  -s, --schema-only            Dump only object definitions, no data
  -a, --data-only              Dump only data, no definitions
  -n, --schema PATTERN         Include only matching schema(s)            [repeatable]
  -N, --exclude-schema PATTERN Exclude matching schema(s)                 [repeatable]
  -t, --table PATTERN          Include only matching table(s)             [repeatable]
  -T, --exclude-table PATTERN  Exclude matching table(s)                  [repeatable]
      --exclude-table-data PATTERN  Keep table definition, skip its rows  [repeatable]
  -O, --no-owner               Do not output ownership (ALTER ... OWNER) commands
  -x, --no-privileges          Do not output GRANT/REVOKE commands
  -c, --clean                  Emit DROP before CREATE (plain format)
      --if-exists              Use DROP ... IF EXISTS (requires --clean)
  -C, --create                 Emit CREATE DATABASE + \\connect (plain format)

Files:
  -o, --output-dir DIR         Directory for backups                 (default: .)
  -f, --file NAME              Override generated file name (single database only)
  -l, --log-file FILE          Log file (default: OUTPUT_DIR/pg_dump_wrapper.log)
  -r, --retention-days N       After success, delete DB_YYYYmmdd_HHMMSS.* backups older than N days
      --min-free-mb N          Warn if free space in OUTPUT_DIR is below N MB (default: 1024)

Alerts:
      --alert-email ADDR       Mail the run report to ADDR (mail/mailx/sendmail) [repeatable]
      --alert-webhook URL      POST the run report as JSON via curl            [repeatable]
      --alert-webhook-format F slack ({"text": ...}; Slack/Teams/Google Chat) | json (structured)
                               (default: slack)
      --alert-on WHEN          failure | always                        (default: failure)
      --alert-from ADDR        From address for e-mail alerts (sendmail / mailx -r)
      --alert-test             Send a test alert to the configured targets and exit

Behaviour:
      --config FILE            Load key=value settings (CLI arguments override them)
      --verify                 Verify dump afterwards (pg_restore --list / plain-file footer)
      --checksum               Write a .sha256 file next to the dump
      --dry-run                Print the pg_dump command(s) and exit without dumping
      --skip-precheck          Skip connectivity and disk-space checks
      --pg-bin DIR             Directory containing pg_dump/pg_restore/psql/pg_isready
  -v, --verbose                Debug logging + pass --verbose to pg_dump
      --help                   Show this help
      --version                Show wrapper version
  --                           Everything after -- is passed to pg_dump verbatim

Exit codes: 0 ok, 1 usage, 2 pre-check, 3 pg_dump, 4 verify/checksum, 5 retention, 130 interrupted
(multi-database runs exit with the highest code of any failed database)
USAGE
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# Append comma-separated values to the array named by $1
add_list() {
    local -n _arr="$1"
    local _item
    local -a _parts
    IFS=',' read -r -a _parts <<<"$2"
    for _item in "${_parts[@]}"; do
        _item="${_item#"${_item%%[![:space:]]*}"}"   # ltrim
        _item="${_item%"${_item##*[![:space:]]}"}"   # rtrim
        [[ -n "$_item" ]] && _arr+=("$_item")
    done
    return 0
}

is_true() {
    case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac
}

bin() {  # resolve a postgres binary, honouring --pg-bin
    if [[ -n "$PG_BIN" ]]; then printf '%s/%s' "${PG_BIN%/}" "$1"; else printf '%s' "$1"; fi
}

need_arg() {  # need_arg <option> <remaining-arg-count>
    [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"
}

# Webhook URLs usually embed a secret token: only ever log scheme://host/...
redact_url() {
    local u="$1"
    if [[ "$u" =~ ^([a-zA-Z]+://[^/]+) ]]; then printf '%s/...' "${BASH_REMATCH[1]}"; else printf '<webhook>'; fi
}

# Escape a string for use inside a JSON string literal
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # drop any other control characters
    s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
    printf '%s' "$s"
}

fmt_duration() {
    local s="$1"
    printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
}

# ----------------------------------------------------------------------------
# Config file: plain key=value, '#' comments, optional quotes. Never sourced/executed.
# List keys accept comma-separated values.
# ----------------------------------------------------------------------------
load_config() {
    local file="$1" line key val lineno=0
    [[ -r "$file" ]] || die 1 "Config file not readable: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            die 1 "Config $file:$lineno: invalid line (expected key=value)"
        fi
        key="${BASH_REMATCH[1],,}"
        val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"([^\"]*)\" || "$val" =~ ^\'([^\']*)\' ]]; then
            val="${BASH_REMATCH[1]}"                       # quoted: take literally
        else
            [[ "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && val="${BASH_REMATCH[1]}"  # strip inline " # comment"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        case "$key" in
            host)               DB_HOST="$val" ;;
            port)               DB_PORT="$val" ;;
            user|username)      DB_USER="$val" ;;
            dbname|database|dbnames|databases) DB_NAMES=(); add_list DB_NAMES "$val" ;;
            all|all_databases)  is_true "$val" && ALL_DBS=1 || ALL_DBS=0 ;;
            exclude_db|exclude_dbs) EXCLUDE_DBS=(); add_list EXCLUDE_DBS "$val" ;;
            maintenance_db)     MAINTENANCE_DB="$val" ;;
            stop_on_error)      is_true "$val" && STOP_ON_ERROR=1 || STOP_ON_ERROR=0 ;;
            format)             FORMAT="$val" ;;
            compress)           COMPRESS="$val" ;;
            jobs)               JOBS="$val" ;;
            schema_only)        is_true "$val" && SCHEMA_ONLY=1 || SCHEMA_ONLY=0 ;;
            data_only)          is_true "$val" && DATA_ONLY=1 || DATA_ONLY=0 ;;
            no_owner)           is_true "$val" && NO_OWNER=1 || NO_OWNER=0 ;;
            no_privileges)      is_true "$val" && NO_PRIVILEGES=1 || NO_PRIVILEGES=0 ;;
            clean)              is_true "$val" && CLEAN=1 || CLEAN=0 ;;
            if_exists)          is_true "$val" && IF_EXISTS=1 || IF_EXISTS=0 ;;
            create)             is_true "$val" && CREATE=1 || CREATE=0 ;;
            schemas|schema)     INCLUDE_SCHEMAS=(); add_list INCLUDE_SCHEMAS "$val" ;;
            exclude_schemas|exclude_schema) EXCLUDE_SCHEMAS=(); add_list EXCLUDE_SCHEMAS "$val" ;;
            tables|table)       INCLUDE_TABLES=(); add_list INCLUDE_TABLES "$val" ;;
            exclude_tables|exclude_table) EXCLUDE_TABLES=(); add_list EXCLUDE_TABLES "$val" ;;
            exclude_table_data) EXCLUDE_TABLE_DATA=(); add_list EXCLUDE_TABLE_DATA "$val" ;;
            output_dir)         OUTPUT_DIR="$val" ;;
            file|file_name)     FILE_NAME="$val" ;;
            log_file)           LOG_FILE="$val" ;;
            retention_days)     RETENTION_DAYS="$val" ;;
            min_free_mb)        MIN_FREE_MB="$val" ;;
            verify)             is_true "$val" && VERIFY=1 || VERIFY=0 ;;
            checksum)           is_true "$val" && CHECKSUM=1 || CHECKSUM=0 ;;
            verbose)            is_true "$val" && VERBOSE=1 || VERBOSE=0 ;;
            pg_bin)             PG_BIN="$val" ;;
            pgpassfile)         PGPASSFILE_OPT="$val" ;;
            alert_email|alert_emails) ALERT_EMAILS=(); add_list ALERT_EMAILS "$val" ;;
            alert_webhook|alert_webhooks) ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$val" ;;
            alert_webhook_format) ALERT_WEBHOOK_FORMAT="$val" ;;
            alert_on)           ALERT_ON="$val" ;;
            alert_from)         ALERT_FROM="$val" ;;
            password)           die 1 "Config $file:$lineno: 'password' is not supported; use ~/.pgpass or pgpassfile=" ;;
            *)                  die 1 "Config $file:$lineno: unknown key '$key'" ;;
        esac
    done <"$file"
}

# ----------------------------------------------------------------------------
# Argument parsing. Supports "-x val", "--opt val" and "--opt=val".
# ----------------------------------------------------------------------------
parse_args() {
    # Pass 1: find --config so its values can be overridden by the CLI.
    local i
    for ((i = 1; i <= $#; i++)); do
        case "${!i}" in
            --) break ;;
            --config=*) CONFIG_FILE="${!i#*=}" ;;
            --config) local j=$((i + 1)); [[ $j -le $# ]] || die 1 "Option --config requires a value"; CONFIG_FILE="${!j}" ;;
        esac
    done
    [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"

    # Lists given on the CLI replace (not extend) lists from the config file.
    local cli_n=0 cli_N=0 cli_t=0 cli_T=0 cli_D=0 cli_d=0 cli_X=0 cli_ae=0 cli_aw=0 cli_all=0

    # Pass 2: real parsing.
    while [[ $# -gt 0 ]]; do
        local opt="$1" val=""
        # split --opt=value
        if [[ "$opt" == --*=* ]]; then
            val="${opt#*=}"; opt="${opt%%=*}"
            set -- "$opt" "$val" "${@:2}"
        fi
        case "$opt" in
            -h|--host)          need_arg "$opt" $#; DB_HOST="$2"; shift 2 ;;
            -p|--port)          need_arg "$opt" $#; DB_PORT="$2"; shift 2 ;;
            -U|--user|--username) need_arg "$opt" $#; DB_USER="$2"; shift 2 ;;
            -d|--dbname)        need_arg "$opt" $#; ((cli_d++)) || DB_NAMES=(); add_list DB_NAMES "$2"; shift 2 ;;
            --all)              ALL_DBS=1; cli_all=1; shift ;;
            --exclude-db)       need_arg "$opt" $#; ((cli_X++)) || EXCLUDE_DBS=(); add_list EXCLUDE_DBS "$2"; shift 2 ;;
            --maintenance-db)   need_arg "$opt" $#; MAINTENANCE_DB="$2"; shift 2 ;;
            --stop-on-error)    STOP_ON_ERROR=1; shift ;;
            -W|--password)      PROMPT_PASSWORD=1; shift ;;
            --pgpassfile)       need_arg "$opt" $#; PGPASSFILE_OPT="$2"; shift 2 ;;
            -F|--format)        need_arg "$opt" $#; FORMAT="$2"; shift 2 ;;
            -Z|--compress)      need_arg "$opt" $#; COMPRESS="$2"; shift 2 ;;
            -j|--jobs)          need_arg "$opt" $#; JOBS="$2"; shift 2 ;;
            -s|--schema-only)   SCHEMA_ONLY=1; shift ;;
            -a|--data-only)     DATA_ONLY=1; shift ;;
            -n|--schema)        need_arg "$opt" $#; ((cli_n++)) || INCLUDE_SCHEMAS=(); add_list INCLUDE_SCHEMAS "$2"; shift 2 ;;
            -N|--exclude-schema) need_arg "$opt" $#; ((cli_N++)) || EXCLUDE_SCHEMAS=(); add_list EXCLUDE_SCHEMAS "$2"; shift 2 ;;
            -t|--table)         need_arg "$opt" $#; ((cli_t++)) || INCLUDE_TABLES=(); add_list INCLUDE_TABLES "$2"; shift 2 ;;
            -T|--exclude-table) need_arg "$opt" $#; ((cli_T++)) || EXCLUDE_TABLES=(); add_list EXCLUDE_TABLES "$2"; shift 2 ;;
            --exclude-table-data) need_arg "$opt" $#; ((cli_D++)) || EXCLUDE_TABLE_DATA=(); add_list EXCLUDE_TABLE_DATA "$2"; shift 2 ;;
            -O|--no-owner)      NO_OWNER=1; shift ;;
            -x|--no-privileges) NO_PRIVILEGES=1; shift ;;
            -c|--clean)         CLEAN=1; shift ;;
            --if-exists)        IF_EXISTS=1; shift ;;
            -C|--create)        CREATE=1; shift ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            -f|--file)          need_arg "$opt" $#; FILE_NAME="$2"; shift 2 ;;
            -l|--log-file)      need_arg "$opt" $#; LOG_FILE="$2"; shift 2 ;;
            -r|--retention-days) need_arg "$opt" $#; RETENTION_DAYS="$2"; shift 2 ;;
            --min-free-mb)      need_arg "$opt" $#; MIN_FREE_MB="$2"; shift 2 ;;
            --alert-email)      need_arg "$opt" $#; ((cli_ae++)) || ALERT_EMAILS=(); add_list ALERT_EMAILS "$2"; shift 2 ;;
            --alert-webhook)    need_arg "$opt" $#; ((cli_aw++)) || ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$2"; shift 2 ;;
            --alert-webhook-format) need_arg "$opt" $#; ALERT_WEBHOOK_FORMAT="$2"; shift 2 ;;
            --alert-on)         need_arg "$opt" $#; ALERT_ON="$2"; shift 2 ;;
            --alert-from)       need_arg "$opt" $#; ALERT_FROM="$2"; shift 2 ;;
            --alert-test)       ALERT_TEST=1; shift ;;
            --config)           shift 2 ;;   # already handled in pass 1
            --verify)           VERIFY=1; shift ;;
            --checksum)         CHECKSUM=1; shift ;;
            --dry-run)          DRY_RUN=1; shift ;;
            --skip-precheck)    SKIP_PRECHECK=1; shift ;;
            --pg-bin)           need_arg "$opt" $#; PG_BIN="$2"; shift 2 ;;
            -v|--verbose)       VERBOSE=1; shift ;;
            --help|-\?)         usage; exit 0 ;;
            --version)          echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            --)                 shift; EXTRA_ARGS=("$@"); break ;;
            -*)                 die 1 "Unknown option: $opt (see --help)" ;;
            *)                  die 1 "Unexpected argument: $opt (pg_dump extras go after --)" ;;
        esac
    done
    # -d on the CLI overrides all=yes from the config, and --all overrides dbnames=.
    if (( cli_d && !cli_all )); then ALL_DBS=0; fi
    if (( cli_all && !cli_d )); then DB_NAMES=(); fi
    return 0
}

# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------
validate_alerts() {
    case "${ALERT_ON,,}" in failure|always) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be 'failure' or 'always'" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be 'slack' or 'json'" ;; esac
    local a
    for a in "${ALERT_EMAILS[@]}"; do
        [[ "$a" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $a"
    done
    for a in "${ALERT_WEBHOOKS[@]}"; do
        [[ "$a" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$a")"
    done
    if (( ${#ALERT_WEBHOOKS[@]} )) && ! command -v curl >/dev/null 2>&1; then
        log_warn "--alert-webhook given but curl is not installed; webhook alerts will be skipped"
    fi
    if (( ${#ALERT_EMAILS[@]} )) && ! command -v mail >/dev/null 2>&1 && ! command -v mailx >/dev/null 2>&1 \
        && ! command -v sendmail >/dev/null 2>&1 && [[ ! -x /usr/sbin/sendmail ]]; then
        log_warn "--alert-email given but none of mail/mailx/sendmail is installed; e-mail alerts will be skipped"
    fi
    return 0
}

validate() {
    if (( ALL_DBS )); then
        (( ${#DB_NAMES[@]} )) && die 1 "Use either -d/--dbname or --all, not both"
    else
        (( ${#DB_NAMES[@]} )) || die 1 "Database name is required (-d/--dbname or --all). See --help."
        (( ${#EXCLUDE_DBS[@]} )) && log_warn "--exclude-db only applies with --all; ignoring"
    fi
    local d
    for d in "${DB_NAMES[@]}"; do
        [[ "$d" != */* ]] || die 1 "Database name must not contain '/': $d"
    done
    if [[ -n "$FILE_NAME" ]] && { (( ALL_DBS )) || (( ${#DB_NAMES[@]} > 1 )); }; then
        die 1 "-f/--file can only be used with a single database"
    fi

    if [[ ! "$DB_PORT" =~ ^[0-9]+$ ]] || (( DB_PORT < 1 || DB_PORT > 65535 )); then
        die 1 "Invalid port: $DB_PORT"
    fi

    case "${FORMAT,,}" in
        p|plain) FORMAT=plain ;;
        c|custom) FORMAT=custom ;;
        d|directory) FORMAT=directory ;;
        t|tar) FORMAT=tar ;;
        *) die 1 "Invalid format '$FORMAT' (plain|custom|directory|tar)" ;;
    esac

    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die 1 "--jobs must be a positive integer (got '$JOBS')"
    if (( JOBS > 1 )) && [[ "$FORMAT" != directory ]]; then
        die 1 "--jobs > 1 is only supported with --format directory (pg_dump limitation)"
    fi

    if [[ -n "$COMPRESS" ]]; then
        [[ "$COMPRESS" =~ ^([0-9]|gzip|lz4|zstd|none)(:[0-9]+)?$ ]] \
            || die 1 "Invalid --compress '$COMPRESS' (0-9 or gzip|lz4|zstd|none[:level])"
        [[ "$FORMAT" == tar && "$COMPRESS" != 0 && "$COMPRESS" != none* ]] \
            && die 1 "tar format does not support compression"
    fi

    (( SCHEMA_ONLY && DATA_ONLY )) && die 1 "--schema-only and --data-only are mutually exclusive"
    (( DATA_ONLY && CLEAN )) && die 1 "--clean cannot be used with --data-only"
    (( IF_EXISTS && !CLEAN )) && die 1 "--if-exists requires --clean"
    (( SCHEMA_ONLY )) && (( ${#EXCLUDE_TABLE_DATA[@]} )) && log_warn "--exclude-table-data has no effect with --schema-only"
    if [[ "$FORMAT" != plain ]] && (( CLEAN || CREATE )); then
        log_warn "--clean/--create are stored in archive formats only as restore hints; pass them to pg_restore instead"
    fi

    [[ -z "$RETENTION_DAYS" || "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die 1 "--retention-days must be a non-negative integer"
    [[ -n "$RETENTION_DAYS" ]] && (( RETENTION_DAYS < 1 )) && die 1 "--retention-days must be >= 1 (refusing to delete everything)"
    [[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || die 1 "--min-free-mb must be an integer"

    [[ -z "$FILE_NAME" || "$FILE_NAME" != */* ]] || die 1 "--file must be a bare file name; use --output-dir for the directory"

    if [[ -n "$PGPASSFILE_OPT" ]]; then
        [[ -r "$PGPASSFILE_OPT" ]] || die 1 "pgpassfile not readable: $PGPASSFILE_OPT"
        export PGPASSFILE="$PGPASSFILE_OPT"
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Database list (--all)
# ----------------------------------------------------------------------------
resolve_databases() {
    (( ALL_DBS )) || return 0
    command -v "$(bin psql)" >/dev/null 2>&1 || die 2 "--all requires psql to list databases"
    local out db pat skip
    if ! out="$("$(bin psql)" -X -w -At -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$MAINTENANCE_DB" \
            -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname" 2>&1)"; then
        die 2 "Cannot list databases via '$MAINTENANCE_DB': ${out//$'\n'/ }"
    fi
    DB_NAMES=()
    while IFS= read -r db; do
        [[ -n "$db" ]] || continue
        skip=0
        for pat in "${EXCLUDE_DBS[@]}"; do
            # shellcheck disable=SC2053  # intentional glob match
            if [[ "$db" == $pat ]]; then skip=1; break; fi
        done
        if (( skip )); then log_info "Excluding database '$db' (--exclude-db)"; continue; fi
        if [[ "$db" == */* ]]; then log_warn "Skipping database with '/' in its name: $db"; continue; fi
        DB_NAMES+=("$db")
    done <<<"$out"
    (( ${#DB_NAMES[@]} )) || die 1 "--all matched no databases (after --exclude-db)"
    log_info "Databases selected by --all: ${DB_NAMES[*]}"
}

# ----------------------------------------------------------------------------
# Output naming
# ----------------------------------------------------------------------------
extension_for_format() {
    case "$FORMAT" in
        custom)    echo "dump" ;;
        tar)       echo "tar" ;;
        directory) echo "dir" ;;
        plain)
            case "$COMPRESS" in
                ""|0|0:*|none|none:*) echo "sql" ;;
                lz4*)  echo "sql.lz4" ;;
                zstd*) echo "sql.zst" ;;
                *)     echo "sql.gz" ;;
            esac ;;
    esac
}

prepare_output_dir() {
    if [[ "$DRY_RUN" -eq 0 ]]; then
        mkdir -p "$OUTPUT_DIR" || die 2 "Cannot create output dir: $OUTPUT_DIR"
        [[ -w "$OUTPUT_DIR" ]] || die 2 "Output dir not writable: $OUTPUT_DIR"
    fi
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" 2>/dev/null && pwd || printf '%s' "$OUTPUT_DIR")"
    [[ -n "$LOG_FILE" ]] || LOG_FILE="$OUTPUT_DIR/pg_dump_wrapper.log"
    return 0
}

prepare_output_path() {  # uses DB_NAME, FILE_NAME_OVERRIDE
    if [[ -n "$FILE_NAME_OVERRIDE" ]]; then
        FILE_NAME="$FILE_NAME_OVERRIDE"
    else
        FILE_NAME="${DB_NAME}_$(date '+%Y%m%d_%H%M%S').$(extension_for_format)"
    fi
    OUTPUT_PATH="$OUTPUT_DIR/$FILE_NAME"
    if [[ "$DRY_RUN" -eq 0 && -e "$OUTPUT_PATH" ]]; then
        die 1 "Output already exists, refusing to overwrite: $OUTPUT_PATH"
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Build pg_dump command (as an array -> no word-splitting/quoting bugs)
# ----------------------------------------------------------------------------
build_command() {
    local x
    CMD=("$(bin pg_dump)"
         --host="$DB_HOST" --port="$DB_PORT" --username="$DB_USER" --dbname="$DB_NAME"
         --format="$FORMAT" --file="$OUTPUT_PATH")
    if (( PROMPT_PASSWORD )); then CMD+=(--password); else CMD+=(--no-password); fi
    [[ -n "$COMPRESS" ]] && CMD+=(--compress="$COMPRESS")
    (( JOBS > 1 )) && CMD+=(--jobs="$JOBS")
    (( SCHEMA_ONLY )) && CMD+=(--schema-only)
    (( DATA_ONLY )) && CMD+=(--data-only)
    for x in "${INCLUDE_SCHEMAS[@]}";    do CMD+=(--schema="$x"); done
    for x in "${EXCLUDE_SCHEMAS[@]}";    do CMD+=(--exclude-schema="$x"); done
    for x in "${INCLUDE_TABLES[@]}";     do CMD+=(--table="$x"); done
    for x in "${EXCLUDE_TABLES[@]}";     do CMD+=(--exclude-table="$x"); done
    for x in "${EXCLUDE_TABLE_DATA[@]}"; do CMD+=(--exclude-table-data="$x"); done
    (( NO_OWNER )) && CMD+=(--no-owner)
    (( NO_PRIVILEGES )) && CMD+=(--no-privileges)
    (( CLEAN )) && CMD+=(--clean)
    (( IF_EXISTS )) && CMD+=(--if-exists)
    (( CREATE )) && CMD+=(--create)
    (( VERBOSE )) && CMD+=(--verbose)
    (( ${#EXTRA_ARGS[@]} )) && CMD+=("${EXTRA_ARGS[@]}")
    return 0
}

print_command() {
    local out="" a
    for a in "${CMD[@]}"; do out+="$(printf '%q' "$a") "; done
    printf '%s\n' "${out% }"
}

# ----------------------------------------------------------------------------
# Pre-checks
# ----------------------------------------------------------------------------
global_prechecks() {   # once per run
    local pgd; pgd="$(bin pg_dump)"
    command -v "$pgd" >/dev/null 2>&1 || die 2 "pg_dump not found (install postgresql-client or use --pg-bin)"
    log_info "Using $("$pgd" --version) ($(command -v "$pgd"))"

    (( SKIP_PRECHECK )) && { log_warn "Skipping connectivity and disk-space checks"; return 0; }

    if command -v "$(bin pg_isready)" >/dev/null 2>&1; then
        "$(bin pg_isready)" -q -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -t 10 \
            || die 2 "Server not accepting connections at $DB_HOST:$DB_PORT (pg_isready)"
        log_debug "pg_isready OK"
    fi

    local free_kb free_mb
    free_kb="$(df -Pk "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
    if [[ "$free_kb" =~ ^[0-9]+$ ]]; then
        free_mb=$(( free_kb / 1024 ))
        log_info "Free space in $OUTPUT_DIR: ${free_mb} MB"
        (( free_mb < MIN_FREE_MB )) && log_warn "Free space ${free_mb} MB is below --min-free-mb ${MIN_FREE_MB} MB"
    fi
    return 0
}

db_prechecks() {       # once per database (runs in the per-db child)
    (( SKIP_PRECHECK )) && return 0
    command -v "$(bin psql)" >/dev/null 2>&1 || return 0
    (( PROMPT_PASSWORD )) && return 0
    local out server_ver db_size_bytes client_major server_major free_kb
    if ! out="$("$(bin psql)" -X -w -At -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -c "SELECT current_setting('server_version_num') || '|' || pg_database_size(current_database())" 2>&1)"; then
        die 2 "Cannot connect to database '$DB_NAME' as '$DB_USER': ${out//$'\n'/ }"
    fi
    server_ver="${out%%|*}"; db_size_bytes="${out##*|}"
    log_info "Connected: server_version_num=$server_ver, database size=$(( db_size_bytes / 1024 / 1024 )) MB"
    client_major="$("$(bin pg_dump)" --version | grep -oE '[0-9]+' | head -n1)"
    server_major=$(( server_ver / 10000 ))
    if (( client_major < server_major )); then
        die 2 "pg_dump major version $client_major is older than server $server_major; use a newer pg_dump (--pg-bin)"
    fi
    free_kb="$(df -Pk "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( db_size_bytes / 1024 > free_kb )); then
        log_warn "Database size exceeds free space; an uncompressed dump may not fit"
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Dump / verify / checksum / retention (per database)
# ----------------------------------------------------------------------------
run_dump() {
    log_info "Starting dump ($FORMAT) -> $OUTPUT_PATH"
    log_info "Command: $(print_command)"
    local start=$SECONDS rc
    DUMP_STARTED=1
    # Run pg_dump in the background and wait for it, so TERM traps fire
    # immediately (and can stop pg_dump) instead of after pg_dump finishes.
    local logfd reader_pid
    exec {logfd}> >(while IFS= read -r l; do _log PG_DUMP "$l"; done)
    reader_pid=$!
    "${CMD[@]}" >&"$logfd" 2>&1 &
    PG_DUMP_PID=$!
    rc=0
    wait "$PG_DUMP_PID" || rc=$?
    PG_DUMP_PID=""
    exec {logfd}>&-                         # close pipe so the log reader finishes
    wait "$reader_pid" 2>/dev/null || true  # ensure pg_dump messages are logged before ours
    if (( rc != 0 )); then
        die 3 "pg_dump failed with exit code $rc"
    fi
    DUMP_DONE=1
    local size; size="$(du -sh "$OUTPUT_PATH" | cut -f1)"
    log_info "Dump finished in $(( SECONDS - start ))s, size $size"
}

verify_dump() {
    log_info "Verifying dump..."
    if [[ "$FORMAT" == plain ]]; then
        [[ -s "$OUTPUT_PATH" ]] || die 4 "Verification failed: dump file is empty"
        local tailtxt
        case "$OUTPUT_PATH" in
            *.sql)    tailtxt="$(tail -n 5 "$OUTPUT_PATH")" ;;
            *.sql.gz) tailtxt="$(gzip -dc "$OUTPUT_PATH" | tail -n 5)" ;;
            *)        log_warn "Footer check skipped for $(basename "$OUTPUT_PATH")"; return 0 ;;
        esac
        grep -q "PostgreSQL database dump complete" <<<"$tailtxt" \
            || die 4 "Verification failed: 'dump complete' footer not found"
        log_info "Verification OK (plain dump footer present)"
    else
        local list n
        list="$("$(bin pg_restore)" --list "$OUTPUT_PATH" 2>&1)" \
            || die 4 "Verification failed: pg_restore --list error: ${list//$'\n'/ }"
        n="$(grep -cvE '^\s*(;|$)' <<<"$list" || true)"
        log_info "Verification OK (pg_restore --list: $n TOC entries)"
    fi
}

write_checksum() {
    local sumfile="$OUTPUT_PATH.sha256"
    (
        cd "$OUTPUT_DIR"
        if [[ -d "$FILE_NAME" ]]; then
            find "$FILE_NAME" -type f -print0 | sort -z | xargs -0 sha256sum
        else
            sha256sum "$FILE_NAME"
        fi
    ) >"$sumfile" || die 4 "Checksum generation failed"
    log_info "Checksum written: $sumfile"
}

apply_retention() {
    [[ -n "$RETENTION_DAYS" ]] || return 0
    # Escape glob metacharacters in the db name so -name matches it literally.
    local db_glob="${DB_NAME//[\[\]\*\?\\]/\\&}"
    local pattern="${db_glob}_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].*"
    local victims=() p
    while IFS= read -r -d '' p; do
        [[ "$p" == "$OUTPUT_PATH" || "$p" == "$OUTPUT_PATH.sha256" ]] && continue
        victims+=("$p")
    done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -name "$pattern" -mtime +"$RETENTION_DAYS" -print0)
    if (( ${#victims[@]} == 0 )); then
        log_info "Retention: nothing older than $RETENTION_DAYS day(s) to delete"
        return 0
    fi
    local failed=0
    for p in "${victims[@]}"; do
        if rm -rf -- "$p"; then log_info "Retention: deleted $p"; else log_warn "Retention: failed to delete $p"; failed=1; fi
    done
    (( failed )) && die 5 "Retention cleanup failed for some files"
    return 0
}

# ----------------------------------------------------------------------------
# Per-database child process. Runs in a subshell so a failure (die/exit) only
# ends this database; its EXIT trap cleans partial output and reports a result.
# ----------------------------------------------------------------------------
# shellcheck disable=SC2317  # invoked indirectly via trap
child_on_exit() {
    local rc=$?
    if (( rc != 0 && DUMP_STARTED && !DUMP_DONE )) && [[ -n "$OUTPUT_PATH" && -e "$OUTPUT_PATH" ]]; then
        rm -rf -- "$OUTPUT_PATH" "$OUTPUT_PATH.sha256" 2>/dev/null || true
        _log WARN "Removed partial output $OUTPUT_PATH"
    fi
    local size="-" file="-"
    if (( DUMP_DONE )) && [[ -e "$OUTPUT_PATH" ]]; then
        size="$(du -sh "$OUTPUT_PATH" 2>/dev/null | cut -f1)"; file="$OUTPUT_PATH"
    fi
    if (( rc == 0 )); then _log INFO "Backup completed successfully: $OUTPUT_PATH"; fi
    printf '%s|%s|%s|%s|%s|%s\n' "$DB_NAME" "$rc" "$STAGE" "${size:--}" "$(( SECONDS - CHILD_START ))" "$file" \
        >"$CHILD_RESULT_FILE" 2>/dev/null || true
}

# shellcheck disable=SC2317  # invoked indirectly via trap
child_on_signal() {
    _log ERROR "Interrupted by signal $1"
    if [[ -n "$PG_DUMP_PID" ]] && kill -0 "$PG_DUMP_PID" 2>/dev/null; then
        kill -TERM "$PG_DUMP_PID" 2>/dev/null || true
        wait "$PG_DUMP_PID" 2>/dev/null || true
    fi
    exit 130
}

dump_one_db() {   # dump_one_db <dbname> <result-file>   (called inside a subshell)
    IS_CHILD=1
    DB_NAME="$1"
    CHILD_RESULT_FILE="$2"
    CHILD_START=$SECONDS
    OUTPUT_PATH=""; DUMP_STARTED=0; DUMP_DONE=0; PG_DUMP_PID=""
    trap child_on_exit EXIT
    trap 'child_on_signal TERM' TERM
    trap 'child_on_signal INT' INT
    STAGE="precheck"; prepare_output_path
    build_command
    db_prechecks
    STAGE="dump";      run_dump
    STAGE="verify";    (( VERIFY )) && verify_dump
    STAGE="checksum";  (( CHECKSUM )) && write_checksum
    STAGE="retention"; apply_retention
    STAGE="done"
    exit 0
}

# ----------------------------------------------------------------------------
# Summary and alerts
# ----------------------------------------------------------------------------
summary_lines() {
    local r db rc stage size dur file status
    printf '%-24s %-9s %-10s %-8s %-8s %s\n' "DATABASE" "STATUS" "STAGE" "SIZE" "TIME" "FILE"
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r db rc stage size dur file <<<"$r"
        if [[ "$rc" == skipped ]]; then status="SKIPPED"; stage="-"; dur="-"
        elif (( rc == 0 )); then status="OK"; stage="-"; dur="$(fmt_duration "$dur")"
        else status="FAIL($rc)"; dur="$(fmt_duration "$dur")"; fi
        printf '%-24s %-9s %-10s %-8s %-8s %s\n' "$db" "$status" "$stage" "$size" "$dur" "$file"
    done
}

# shellcheck disable=SC2317  # called from the EXIT trap
log_summary() {
    (( ${#RESULTS[@]} )) || return 0
    local line
    log_info "Summary:"
    while IFS= read -r line; do _log INFO "  $line"; done < <(summary_lines)
}

# Mask anything that looks like a password in text we send out.
redact_text() {
    sed -E 's/(password[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1*****/Ig; s#(://[^:/@[:space:]]+:)[^@/[:space:]]+@#\1*****@#g'
}

build_alert_body() {   # build_alert_body <rc> <status-word>
    local rc="$1" status="$2" dbs
    if (( ${#DB_NAMES[@]} )); then dbs="${DB_NAMES[*]}"; elif (( ALL_DBS )); then dbs="(all)"; else dbs="-"; fi
    {
        printf 'pg_dump_wrapper %s on %s\n\n' "$status" "$(hostname 2>/dev/null || echo unknown)"
        printf 'Server     : %s:%s (user %s)\n' "$DB_HOST" "$DB_PORT" "$DB_USER"
        printf 'Databases  : %s\n' "$dbs"
        printf 'Exit code  : %s\n' "$rc"
        (( rc != 0 )) && printf 'Failed at  : %s\n' "$STAGE"
        printf 'Started    : %s\n' "$RUN_START_TS"
        printf 'Duration   : %s\n' "$(fmt_duration $(( SECONDS - RUN_START )))"
        printf 'Output dir : %s\n' "$OUTPUT_DIR"
        printf 'Log file   : %s\n' "$LOG_FILE"
        if (( ${#RESULTS[@]} )); then printf '\n'; summary_lines; fi
        if (( rc != 0 )) && [[ -r "$LOG_FILE" ]]; then
            printf '\nLast %s log lines:\n' "$ALERT_LOG_LINES"
            tail -n "$ALERT_LOG_LINES" "$LOG_FILE"
        fi
    } | redact_text
}

build_alert_json() {   # build_alert_json <rc> <status-word> <text-body>
    local rc="$1" status="$2" body="$3" r db drc stage size dur file first=1 dbjson=""
    if [[ "$ALERT_WEBHOOK_FORMAT" == slack ]]; then
        # First line as the headline, the rest in a code block so the table stays aligned.
        local head="${body%%$'\n'*}" rest="${body#*$'\n'}"
        printf '{"text": "%s"}' "$(json_escape "*${head}*"$'\n''```'"${rest}"'```')"
        return 0
    fi
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r db drc stage size dur file <<<"$r"
        (( first )) || dbjson+=","
        first=0
        dbjson+="$(printf '{"database":"%s","exit_code":"%s","stage":"%s","size":"%s","duration_seconds":"%s","file":"%s"}' \
            "$(json_escape "$db")" "$(json_escape "$drc")" "$(json_escape "$stage")" "$(json_escape "$size")" \
            "$(json_escape "$dur")" "$(json_escape "$file")")"
    done
    local tailtxt=""
    if (( rc != 0 )) && [[ -r "$LOG_FILE" ]]; then tailtxt="$(tail -n "$ALERT_LOG_LINES" "$LOG_FILE" | redact_text)"; fi
    printf '{"status":"%s","exit_code":%d,"failed_stage":"%s","host":"%s","server":"%s:%s","user":"%s","started":"%s","duration_seconds":%d,"output_dir":"%s","log_file":"%s","databases":[%s],"log_tail":"%s","text":"%s"}' \
        "$(json_escape "$status")" "$rc" "$( (( rc != 0 )) && json_escape "$STAGE")" \
        "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" "$(json_escape "$DB_HOST")" "$DB_PORT" \
        "$(json_escape "$DB_USER")" "$(json_escape "$RUN_START_TS")" $(( SECONDS - RUN_START )) \
        "$(json_escape "$OUTPUT_DIR")" "$(json_escape "$LOG_FILE")" "$dbjson" "$(json_escape "$tailtxt")" \
        "$(json_escape "$body")"
}

send_email_alert() {   # send_email_alert <subject> <body>
    local subject="$1" body="$2" mailer="" to
    local -a tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout 60)
    if command -v mail >/dev/null 2>&1; then mailer="mail"
    elif command -v mailx >/dev/null 2>&1; then mailer="mailx"
    elif command -v sendmail >/dev/null 2>&1; then mailer="sendmail"
    elif [[ -x /usr/sbin/sendmail ]]; then mailer=/usr/sbin/sendmail
    else
        log_warn "Alert: no mail/mailx/sendmail found; cannot send e-mail to ${ALERT_EMAILS[*]}"
        return 1
    fi
    if [[ "$mailer" == mail || "$mailer" == mailx ]]; then
        local -a from=()
        [[ -n "$ALERT_FROM" ]] && from=(-r "$ALERT_FROM")
        printf '%s\n' "$body" | "${tmo[@]}" "$mailer" "${from[@]}" -s "$subject" -- "${ALERT_EMAILS[@]}"
    else
        to="$(IFS=,; printf '%s' "${ALERT_EMAILS[*]}")"
        {
            [[ -n "$ALERT_FROM" ]] && printf 'From: %s\n' "$ALERT_FROM"
            printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' "$to" "$subject" "$body"
        } | "${tmo[@]}" "$mailer" -t -oi
    fi
}

send_webhook_alert() {   # send_webhook_alert <url> <json>
    local url="$1" json="$2" out
    command -v curl >/dev/null 2>&1 || { log_warn "Alert: curl not installed; webhook skipped"; return 1; }
    # URL is passed via a curl config on stdin so it never appears in `ps` output.
    out="$(printf 'url = "%s"\n' "${url//\"/\\\"}" | curl -sS --fail --max-time 20 --retry 2 \
            -H 'Content-Type: application/json' --data-binary "$json" -o /dev/null -w '%{http_code}' -K - 2>&1)" \
        || { log_warn "Alert: webhook $(redact_url "$url") failed: ${out%%$'\n'*}"; return 1; }
    log_info "Alert: webhook $(redact_url "$url") -> HTTP $out"
}

send_alerts() {   # send_alerts <rc> [test]  -- never fails, never changes the exit code
    local rc="$1" mode="${2:-}"
    (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || return 0
    if [[ "$mode" != test && "$ALERT_ON" == failure ]] && (( rc == 0 )); then return 0; fi
    local status subject body json url dbs
    if [[ "$mode" == test ]]; then status="TEST"
    elif (( rc == 0 )); then status="SUCCESS"
    else status="FAILED"; fi
    if (( ${#DB_NAMES[@]} )); then dbs="${DB_NAMES[*]}"; else dbs="(all)"; fi
    (( ${#dbs} > 60 )) && dbs="${dbs:0:57}..."
    subject="[pg_dump_wrapper] $status: $dbs on $DB_HOST (exit $rc)"
    body="$(build_alert_body "$rc" "$status")"
    if (( ${#ALERT_EMAILS[@]} )); then
        if send_email_alert "$subject" "$body"; then
            log_info "Alert: e-mail sent to ${ALERT_EMAILS[*]}"
        else
            log_warn "Alert: e-mail to ${ALERT_EMAILS[*]} failed"
        fi
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
# shellcheck disable=SC2317  # invoked indirectly via trap
on_exit() {
    local rc=$?
    (( IS_CHILD )) && return 0
    trap - EXIT INT TERM
    set +e
    (( MAIN_STARTED )) || exit "$rc"
    log_summary
    if (( rc == 0 )); then
        _log INFO "Run finished OK in $(fmt_duration $(( SECONDS - RUN_START )))"
    else
        _log ERROR "Run finished with exit code $rc (stage: $STAGE)"
    fi
    send_alerts "$rc" || true
    [[ -n "$RESULT_DIR" ]] && rm -rf -- "$RESULT_DIR"
    exit "$rc"
}

# shellcheck disable=SC2317  # invoked indirectly via trap
on_signal() {
    _log ERROR "Interrupted by signal $1"
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
        collect_result "$CURRENT_DB" "$CURRENT_RES" 130
        local k
        for (( k = CURRENT_IDX + 1; k < ${#DB_NAMES[@]}; k++ )); do RESULTS+=("${DB_NAMES[$k]}|skipped|-|-|0|-"); done
    fi
    STAGE="interrupted"
    exit 130
}

collect_result() {   # collect_result <db> <result-file> <rc>
    local db="$1" res="$2" rc="$3" line
    if [[ -s "$res" ]]; then
        line="$(<"$res")"
    else
        line="$db|$rc|unknown|-|0|-"
    fi
    RESULTS+=("$line")
}

# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    trap on_exit EXIT
    RUN_START_TS="$(_ts)"
    STAGE="validate"
    validate_alerts
    if (( ALERT_TEST )); then
        prepare_output_dir
        log_info "Sending test alert..."
        send_alerts 0 test
        exit 0
    fi
    # From here on, failures (including validation errors) trigger alerts.
    (( DRY_RUN )) || MAIN_STARTED=1
    validate
    FILE_NAME_OVERRIDE="$FILE_NAME"

    if (( DRY_RUN )); then
        prepare_output_dir
        resolve_databases
        log_info "DRY RUN - pg_dump would be executed as:"
        local db
        for db in "${DB_NAMES[@]}"; do
            DB_NAME="$db"; prepare_output_path; build_command; print_command
        done
        DB_NAME=""
        [[ -n "$RETENTION_DAYS" ]] && log_info "DRY RUN - would delete <db>_YYYYmmdd_HHMMSS.* in $OUTPUT_DIR older than $RETENTION_DAYS days"
        (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) && log_info "DRY RUN - alerts (on $ALERT_ON) -> ${#ALERT_EMAILS[@]} e-mail, ${#ALERT_WEBHOOKS[@]} webhook target(s)"
        exit 0
    fi

    prepare_output_dir
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM

    log_info "===== $SCRIPT_NAME v$SCRIPT_VERSION: host=$DB_HOST port=$DB_PORT user=$DB_USER ====="
    STAGE="precheck"
    global_prechecks
    resolve_databases
    log_info "Databases to dump (${#DB_NAMES[@]}): ${DB_NAMES[*]}"

    RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_dump_wrapper.XXXXXX")"
    local i db rc worst=0 first_fail_stage=""
    CURRENT_DB=""; CURRENT_RES=""; CURRENT_IDX=0
    for i in "${!DB_NAMES[@]}"; do
        db="${DB_NAMES[$i]}"
        if [[ -n "$first_fail_stage" ]] && (( STOP_ON_ERROR )); then
            RESULTS+=("$db|skipped|-|-|0|-")
            continue
        fi
        STAGE="dump"
        CURRENT_DB="$db"; CURRENT_RES="$RESULT_DIR/$i.res"; CURRENT_IDX=$i
        ( dump_one_db "$db" "$CURRENT_RES" ) &
        CHILD_PID=$!
        rc=0
        wait "$CHILD_PID" || rc=$?
        CHILD_PID=""
        collect_result "$db" "$CURRENT_RES" "$rc"
        if (( rc != 0 )); then
            (( rc > worst )) && worst=$rc
            [[ -n "$first_fail_stage" ]] || first_fail_stage="$(cut -d'|' -f3 <<<"${RESULTS[-1]}") ($db)"
            (( STOP_ON_ERROR )) && log_error "Stopping after failure of '$db' (--stop-on-error)"
        fi
    done
    CURRENT_DB=""
    if (( worst != 0 )); then
        STAGE="$first_fail_stage"
        exit "$worst"
    fi
    STAGE="done"
    exit 0
}

main "$@"
