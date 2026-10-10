#!/usr/bin/env bash
#
# pg_dump_wrapper.sh - opinionated, cron-friendly wrapper around PostgreSQL pg_dump
#
# Features: long/short options, optional key=value config file (CLI overrides it),
# timestamped output names, logging to console + file, pre-checks (binaries,
# connectivity, disk space), dry-run, post-dump verification, sha256 checksum,
# safe retention cleanup, and removal of partial output on failure.
#
# Exit codes:
#   0  success
#   1  usage / validation error
#   2  pre-check failure (missing binary, cannot connect, output dir problem)
#   3  pg_dump failed
#   4  post-dump verification or checksum failed
#   5  retention cleanup failed (the backup itself succeeded)
#
# Passwords are NEVER accepted on the command line. Use ~/.pgpass, PGPASSFILE
# (or the pgpassfile= config key), the PGPASSWORD environment variable, or -W to prompt.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

# ----------------------------------------------------------------------------
# Defaults (lowest precedence: defaults < config file < command line)
# ----------------------------------------------------------------------------
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_USER="${PGUSER:-${USER:-postgres}}"
DB_NAME=""
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

# runtime state
OUTPUT_PATH=""
DUMP_STARTED=0
DUMP_DONE=0
TMP_FILES=()
PG_DUMP_PID=""

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log() {
    local level="$1"; shift
    local line
    line="$(_ts) [$level] $*"
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

Usage: $SCRIPT_NAME -d DBNAME [options] [-- extra pg_dump args]

Connection:
  -h, --host HOST              Server host or socket dir          (default: \$PGHOST or localhost)
  -p, --port PORT              Server port                        (default: \$PGPORT or 5432)
  -U, --user USER              Database user                      (default: \$PGUSER or \$USER)
  -d, --dbname DBNAME          Database to dump                   (REQUIRED)
  -W, --password               Prompt for password (interactive only; default never prompts)
      --pgpassfile FILE        Use this .pgpass file (sets PGPASSFILE)

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
  -f, --file NAME              Override generated file name (default: DB_YYYYmmdd_HHMMSS.EXT)
  -l, --log-file FILE          Log file (default: OUTPUT_DIR/pg_dump_wrapper.log)
  -r, --retention-days N       After success, delete DB_*-pattern backups older than N days
      --min-free-mb N          Warn if free space in OUTPUT_DIR is below N MB (default: 1024)

Behaviour:
      --config FILE            Load key=value settings (CLI arguments override them)
      --verify                 Verify dump afterwards (pg_restore --list / plain-file footer)
      --checksum               Write a .sha256 file next to the dump
      --dry-run                Print the pg_dump command and exit without dumping
      --skip-precheck          Skip connectivity and disk-space checks
      --pg-bin DIR             Directory containing pg_dump/pg_restore/psql/pg_isready
  -v, --verbose                Debug logging + pass --verbose to pg_dump
      --help                   Show this help
      --version                Show wrapper version
  --                           Everything after -- is passed to pg_dump verbatim

Exit codes: 0 ok, 1 usage, 2 pre-check, 3 pg_dump, 4 verify/checksum, 5 retention
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
            dbname|database)    DB_NAME="$val" ;;
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
    local cli_n=0 cli_N=0 cli_t=0 cli_T=0 cli_D=0

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
            -d|--dbname)        need_arg "$opt" $#; DB_NAME="$2"; shift 2 ;;
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
}

# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------
validate() {
    [[ -n "$DB_NAME" ]] || die 1 "Database name is required (-d/--dbname). See --help."
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
    [[ "$DB_NAME" != */* ]] || die 1 "Database name must not contain '/'"

    if [[ -n "$PGPASSFILE_OPT" ]]; then
        [[ -r "$PGPASSFILE_OPT" ]] || die 1 "pgpassfile not readable: $PGPASSFILE_OPT"
        export PGPASSFILE="$PGPASSFILE_OPT"
    fi
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

prepare_output() {
    if [[ "$DRY_RUN" -eq 0 ]]; then
        mkdir -p "$OUTPUT_DIR" || die 2 "Cannot create output dir: $OUTPUT_DIR"
        [[ -w "$OUTPUT_DIR" ]] || die 2 "Output dir not writable: $OUTPUT_DIR"
    fi
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" 2>/dev/null && pwd || printf '%s' "$OUTPUT_DIR")"
    [[ -n "$LOG_FILE" ]] || LOG_FILE="$OUTPUT_DIR/pg_dump_wrapper.log"
    if [[ -z "$FILE_NAME" ]]; then
        FILE_NAME="${DB_NAME}_$(date '+%Y%m%d_%H%M%S').$(extension_for_format)"
    fi
    OUTPUT_PATH="$OUTPUT_DIR/$FILE_NAME"
    if [[ "$DRY_RUN" -eq 0 && -e "$OUTPUT_PATH" ]]; then
        die 1 "Output already exists, refusing to overwrite: $OUTPUT_PATH"
    fi
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
prechecks() {
    local pgd; pgd="$(bin pg_dump)"
    command -v "$pgd" >/dev/null 2>&1 || die 2 "pg_dump not found (install postgresql-client or use --pg-bin)"
    log_info "Using $("$pgd" --version) ($(command -v "$pgd"))"

    (( SKIP_PRECHECK )) && { log_warn "Skipping connectivity and disk-space checks"; return 0; }

    if command -v "$(bin pg_isready)" >/dev/null 2>&1; then
        "$(bin pg_isready)" -q -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t 10 \
            || die 2 "Server not accepting connections at $DB_HOST:$DB_PORT (pg_isready)"
        log_debug "pg_isready OK"
    fi

    local db_size_bytes="" server_ver=""
    if command -v "$(bin psql)" >/dev/null 2>&1 && (( !PROMPT_PASSWORD )); then
        local out
        if ! out="$("$(bin psql)" -X -w -At -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
                -c "SELECT current_setting('server_version_num') || '|' || pg_database_size(current_database())" 2>&1)"; then
            die 2 "Cannot connect to database '$DB_NAME' as '$DB_USER': ${out//$'\n'/ }"
        fi
        server_ver="${out%%|*}"; db_size_bytes="${out##*|}"
        log_info "Connected: server_version_num=$server_ver, database size=$(( db_size_bytes / 1024 / 1024 )) MB"
        local client_major server_major
        client_major="$("$pgd" --version | grep -oE '[0-9]+' | head -n1)"
        server_major=$(( server_ver / 10000 ))
        if (( client_major < server_major )); then
            die 2 "pg_dump major version $client_major is older than server $server_major; use a newer pg_dump (--pg-bin)"
        fi
    fi

    local free_kb free_mb
    free_kb="$(df -Pk "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
    if [[ "$free_kb" =~ ^[0-9]+$ ]]; then
        free_mb=$(( free_kb / 1024 ))
        log_info "Free space in $OUTPUT_DIR: ${free_mb} MB"
        (( free_mb < MIN_FREE_MB )) && log_warn "Free space ${free_mb} MB is below --min-free-mb ${MIN_FREE_MB} MB"
        if [[ -n "$db_size_bytes" ]] && (( db_size_bytes / 1024 > free_kb )); then
            log_warn "Database size exceeds free space; an uncompressed dump may not fit"
        fi
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Dump / verify / checksum / retention
# ----------------------------------------------------------------------------
run_dump() {
    log_info "Starting dump of '$DB_NAME' ($FORMAT) -> $OUTPUT_PATH"
    log_info "Command: $(print_command)"
    local start=$SECONDS rc
    DUMP_STARTED=1
    # Run pg_dump in the background and wait for it, so INT/TERM traps fire
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
    log_info "Checksum written: $sumfile (verify: cd '$OUTPUT_DIR' && sha256sum -c '$(basename "$sumfile")')"
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
    (( failed )) && return 5
    return 0
}

# ----------------------------------------------------------------------------
# Cleanup trap: remove partial output if the dump did not complete
# ----------------------------------------------------------------------------
# shellcheck disable=SC2317  # invoked indirectly via trap
on_exit() {
    local rc=$?
    if (( rc != 0 && DUMP_STARTED && !DUMP_DONE )) && [[ -n "$OUTPUT_PATH" && -e "$OUTPUT_PATH" ]]; then
        rm -rf -- "$OUTPUT_PATH" "$OUTPUT_PATH.sha256" 2>/dev/null || true
        _log WARN "Removed partial output $OUTPUT_PATH"
    fi
    local t; for t in "${TMP_FILES[@]}"; do rm -f -- "$t"; done
    if (( rc == 0 )); then
        [[ "$DRY_RUN" -eq 1 ]] || _log INFO "Backup completed successfully: $OUTPUT_PATH"
    else
        _log ERROR "Exiting with code $rc"
    fi
}
# shellcheck disable=SC2317  # invoked indirectly via trap
on_signal() {
    _log ERROR "Interrupted by signal $1"
    if [[ -n "$PG_DUMP_PID" ]] && kill -0 "$PG_DUMP_PID" 2>/dev/null; then
        kill -TERM "$PG_DUMP_PID" 2>/dev/null || true
        wait "$PG_DUMP_PID" 2>/dev/null || true
    fi
    exit 130
}

# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate
    prepare_output
    build_command

    if (( DRY_RUN )); then
        log_info "DRY RUN - pg_dump would be executed as:"
        print_command
        [[ -n "$RETENTION_DAYS" ]] && log_info "DRY RUN - would delete ${DB_NAME}_YYYYmmdd_HHMMSS.* in $OUTPUT_DIR older than $RETENTION_DAYS days"
        exit 0
    fi

    trap on_exit EXIT
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM

    log_info "===== $SCRIPT_NAME v$SCRIPT_VERSION: db=$DB_NAME host=$DB_HOST port=$DB_PORT user=$DB_USER ====="
    prechecks
    run_dump
    (( VERIFY )) && verify_dump
    (( CHECKSUM )) && write_checksum
    local rrc=0
    apply_retention || rrc=$?
    (( rrc )) && exit "$rrc"
    exit 0
}

main "$@"
