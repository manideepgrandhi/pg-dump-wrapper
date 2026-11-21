#!/usr/bin/env bash
# shellcheck disable=SC2016  # bash -c '...' snippets get their values as $1, $2
#
# End-to-end tests for pg_dump_wrapper.sh against a throwaway PostgreSQL cluster.
#
# Linux tests use the real client tools. "Windows" tests simulate Git Bash on Linux:
#   - a fake `uname` reports MINGW64, so the wrapper takes its Windows code paths;
#   - a fake `cygpath` maps drive letters (C:\x, C:/x, c:x) to a fake drive root;
#   - fake psql.exe / pg_dump.exe / pg_restore.exe / pg_isready.exe run the real
#     tools, translate C:/... paths back, and turn every output line into CRLF,
#     exactly like the native Windows binaries do.
#
# Usage:
#   PDW_SERVER_BIN=/usr/lib/postgresql/16/bin tests/test_pg_dump_wrapper.sh
# Settings (environment):
#   PDW_SERVER_BIN   dir with initdb/pg_ctl       (default: dir of `initdb` in PATH)
#   PDW_CLIENT_BIN   dir with pg_dump/psql/...    (default: dir of `pg_dump` in PATH)
#   PDW_TEST_PORT    port for the test cluster    (default: 54329)
#   PDW_KEEP         1 = keep the temp dir for inspection
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${PDW_WRAPPER:-$HERE/../pg_dump_wrapper.sh}"
SERVER_BIN="${PDW_SERVER_BIN:-$(dirname "$(command -v initdb || echo /nonexistent/initdb)")}"
CLIENT_BIN="${PDW_CLIENT_BIN:-$(dirname "$(command -v pg_dump || echo /nonexistent/pg_dump)")}"
PORT="${PDW_TEST_PORT:-54329}"
PGUSER_T="postgres"
PASSWORD_T="pdw_test_pw"
TEST_DBS=(abc chatagent invent inventory)
ALL_DBS_SORTED="abc chatagent invent inventory postgres"
OLD_DAYS=30
RETENTION=7

[[ -x "$SERVER_BIN/initdb" ]] || { echo "initdb not found; set PDW_SERVER_BIN" >&2; exit 2; }
[[ -x "$CLIENT_BIN/pg_dump" ]] || { echo "pg_dump not found; set PDW_CLIENT_BIN" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pdw-test.XXXXXX")"
PGDATA_T="$T/pgdata"
cleanup() {
    "$SERVER_BIN/pg_ctl" -D "$PGDATA_T" -m fast -w stop >/dev/null 2>&1 || true
    if [[ "${PDW_KEEP:-0}" == 1 ]]; then echo "kept $T"; else rm -rf -- "$T"; fi
}
trap cleanup EXIT
cd "$T" || exit 2   # relative paths (e.g. a Windows path an old version does not understand) land in the temp dir

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /' | tail -n 25; return 0; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d" "$OUT"; fi; }
section() { printf '\n== %s\n' "$1"; }

OUT=""; RC=0
run() {   # run [ENV=..] -- wrapper args ; output in $OUT, exit code in $RC
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    OUT="$(env "${envs[@]}" bash "$WRAPPER" "$@" 2>&1)"; RC=$?
}
has()  { grep -qF -- "$1" <<<"$OUT"; }
hasnt() { ! grep -qF -- "$1" <<<"$OUT"; }
count_files() { find "$1" -maxdepth 1 -name "$2" | wc -l; }

# ----------------------------------------------------------------------------
section "Start PostgreSQL ($("$SERVER_BIN/postgres" --version)) on port $PORT"
printf '%s\n' "$PASSWORD_T" >"$T/pw"
"$SERVER_BIN/initdb" -D "$PGDATA_T" -U "$PGUSER_T" --auth=scram-sha-256 --pwfile="$T/pw" >"$T/initdb.log" 2>&1 \
    || { cat "$T/initdb.log"; exit 2; }
"$SERVER_BIN/pg_ctl" -D "$PGDATA_T" -l "$T/server.log" -w \
    -o "-p $PORT -k $T -c listen_addresses=127.0.0.1" start >/dev/null || { cat "$T/server.log"; exit 2; }
PGPASS_FILE="$T/pgpass"
printf '127.0.0.1:%s:*:%s:%s\n' "$PORT" "$PGUSER_T" "$PASSWORD_T" >"$PGPASS_FILE"; chmod 600 "$PGPASS_FILE"
export PGPASSFILE="$PGPASS_FILE"
for db in "${TEST_DBS[@]}"; do
    "$CLIENT_BIN/psql" -X -q -h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" -d postgres -c "CREATE DATABASE $db" >/dev/null
    "$CLIENT_BIN/psql" -X -q -h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" -d "$db" \
        -c "CREATE TABLE t_$db(id int primary key, v text); INSERT INTO t_$db SELECT g, md5(g::text) FROM generate_series(1,1000) g" >/dev/null
done
# abc gets a second schema: sales.orders (largest) and sales."MixedCase" (smallest)
"$CLIENT_BIN/psql" -X -q -h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" -d abc -c "
    CREATE SCHEMA sales;
    CREATE TABLE sales.orders(id int primary key, note text);
    INSERT INTO sales.orders SELECT g, repeat(md5(g::text), 4) FROM generate_series(1,5000) g;
    CREATE TABLE sales.\"MixedCase\"(id int);
    INSERT INTO sales.\"MixedCase\" VALUES (1),(2),(3);
    ANALYZE;" >/dev/null
# inventory also has sales.orders; invent has a table whose name is not file-system safe
"$CLIENT_BIN/psql" -X -q -h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" -d inventory -c "
    CREATE SCHEMA sales; CREATE TABLE sales.orders(id int); INSERT INTO sales.orders SELECT generate_series(1,10); ANALYZE;" >/dev/null
"$CLIENT_BIN/psql" -X -q -h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" -d invent -c "
    CREATE SCHEMA \"odd sch\"; CREATE TABLE \"odd sch\".\"we|ird:na*me\"(id int); INSERT INTO \"odd sch\".\"we|ird:na*me\" VALUES (1);" >/dev/null
unset PGPASSFILE
COMMON=(-h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" --pgpassfile "$PGPASS_FILE" --min-free-mb 1)

# ----------------------------------------------------------------------------
section "Linux: real client tools"
L="$T/linux"; mkdir -p "$L"

run -- "${COMMON[@]}" --all -o "$L/all"
check "--all exits 0" test "$RC" -eq 0
check "--all lists 5 databases" has "Databases to dump (5): $ALL_DBS_SORTED"
check "--all wrote 5 dumps" test "$(count_files "$L/all" '*.dump')" -eq 5
check "free space is reported" has "Free space in $L/all:"

run -- "${COMMON[@]}" --all --exclude-db 'inv*' -o "$L/excl"
check "--exclude-db 'inv*' leaves 3 databases" has "Databases to dump (3): abc chatagent postgres"

run -- "${COMMON[@]}" -d abc,chatagent --verify --checksum -o "$L/vc"
check "custom + verify + checksum exits 0" test "$RC" -eq 0
check "verify reports TOC entries" has "Verification OK (pg_restore --list:"
check "checksums validate with sha256sum -c" bash -c "cd '$L/vc' && for f in *.sha256; do sha256sum -c --quiet \"\$f\" || exit 1; done"

run -- "${COMMON[@]}" -d abc -F plain -Z 6 --verify -o "$L/plain"
check "plain gzip verify footer" has "Verification OK (plain dump footer present)"

run -- "${COMMON[@]}" -d inventory -F directory -j 2 --verify --checksum -o "$L/dir"
check "directory -j 2 + checksum exits 0" test "$RC" -eq 0
check "directory checksum validates" bash -c "cd '$L/dir' && sha256sum -c --quiet inventory_*.dir.sha256"

run -- "${COMMON[@]}" -d invent -F tar --verify -o "$L/tar"
check "tar format verify" has "Verification OK (pg_restore --list:"

run -- "${COMMON[@]}" -d abc -f my_abc.dump -o "$L/file"
check "--file single database" test -s "$L/file/my_abc.dump"

SP="$T/Program Files/PostgreSQL 17/bin"; mkdir -p "$SP"
for x in psql pg_dump pg_restore pg_isready; do ln -s "$CLIENT_BIN/$x" "$SP/$x"; done
run -- "${COMMON[@]}" -d abc --pg-bin "$SP" -o "$L/with space/out dir" --log-file "$L/with space/run log.txt" --checksum
check "spaces in --pg-bin, -o and --log-file" test "$RC" -eq 0
check "log file with spaces written" test -s "$L/with space/run log.txt"

mkdir -p "$L/ret"
for f in abc_20200101_000000.dump abc_20200101_000000.dump.sha256 chatagent_20200101_000000.dump abcd_20200101_000000.dump; do
    : >"$L/ret/$f"; touch -d "$OLD_DAYS days ago" "$L/ret/$f"
done
run -- "${COMMON[@]}" -d abc -r "$RETENTION" -o "$L/ret"
check "retention deletes old abc_* files" test ! -e "$L/ret/abc_20200101_000000.dump" -a ! -e "$L/ret/abc_20200101_000000.dump.sha256"
check "retention keeps other databases' files" test -e "$L/ret/chatagent_20200101_000000.dump" -a -e "$L/ret/abcd_20200101_000000.dump"
check "retention keeps the new dump" test "$(count_files "$L/ret" 'abc_*.dump')" -eq 1

run -- "${COMMON[@]}" -d abc,nosuchdb,chatagent -o "$L/fail"
check "missing database -> exit 2" test "$RC" -eq 2
check "other databases still dumped" test "$(count_files "$L/fail" '*.dump')" -eq 2

run -- "${COMMON[@]}" --all --dry-run -o "$L/dry"
check "dry-run prints commands, writes nothing" bash -c "[[ ! -e '$L/dry' ]] && grep -q -- '--file=$L/dry/postgres_' <<<\"\$1\"" _ "$OUT"

printf 'host=127.0.0.1\r\nport=%s\r\nuser=%s\r\nall=yes\r\noutput_dir=%s\r\npgpassfile=%s\r\nmin_free_mb=1\r\n' \
    "$PORT" "$PGUSER_T" "$L/conf" "$PGPASS_FILE" >"$L/crlf.conf"
run -- --config "$L/crlf.conf"
check "CRLF config file works" test "$RC" -eq 0 -a "$(count_files "$L/conf" '*.dump')" -eq 5

run -- "${COMMON[@]}" -d abc -o "$L/lowfree" --min-free-mb 999999999
check "low free space warning" has "is below --min-free-mb"

# sha256sum missing -> shasum fallback
NOSHA="$T/nosha"; mkdir -p "$NOSHA"
for x in /usr/bin/* /bin/*; do b="${x##*/}"; [[ "$b" == sha256sum || -e "$NOSHA/$b" ]] || ln -s "$x" "$NOSHA/$b"; done
if [[ -e "$NOSHA/shasum" ]]; then
    run PATH="$NOSHA" -- "${COMMON[@]}" -d abc --checksum --pg-bin "$CLIENT_BIN" -o "$L/shasum"
    check "checksum via shasum when sha256sum is missing" bash -c "cd '$L/shasum' && sha256sum -c --quiet abc_*.sha256"
fi

# Ctrl+C / TERM during pg_dump: exit 130 and remove partial output
SLOW="$T/slowbin"; mkdir -p "$SLOW"
for x in psql pg_restore pg_isready; do ln -s "$CLIENT_BIN/$x" "$SLOW/$x"; done
cat >"$SLOW/pg_dump" <<SLOWEOF
#!/usr/bin/env bash
[[ "\${1:-}" == --version ]] && exec "$CLIENT_BIN/pg_dump" --version
for a; do [[ "\$a" == --file=* ]] && printf 'partial' >"\${a#--file=}"; done
sleep 30
SLOWEOF
chmod +x "$SLOW/pg_dump"
mkdir -p "$L/int"
bash "$WRAPPER" "${COMMON[@]}" -d abc,chatagent --pg-bin "$SLOW" -o "$L/int" >"$T/int.out" 2>&1 &
wpid=$!
for _ in $(seq 1 100); do compgen -G "$L/int/abc_*.dump" >/dev/null && break; sleep 0.1; done
kill -TERM "$wpid"; wait "$wpid"; RC=$?; OUT="$(cat "$T/int.out")"
check "TERM during dump -> exit 130" test "$RC" -eq 130
check "partial dump removed" test "$(count_files "$L/int" '*.dump')" -eq 0
check "remaining database marked SKIPPED" has "SKIPPED"
pkill -f "$SLOW/pg_dump" 2>/dev/null || true

# ----------------------------------------------------------------------------
section "Windows (Git Bash) simulation: CRLF tools, drive-letter paths"
W="$T/win"; DRIVES="$W/drives"; FAKE="$W/fakebin"; NOCYG="$W/nocygpath"
WINBIN_WIN='C:\Program Files\PostgreSQL\18\bin'
WINBIN="$DRIVES/c/Program Files/PostgreSQL/18/bin"
mkdir -p "$FAKE" "$NOCYG" "$WINBIN" "$DRIVES/c/Users/me/pg pass" "$DRIVES/c/conf"
REAL_UNAME="$(command -v uname)"
cat >"$FAKE/uname" <<UEOF
#!/usr/bin/env bash
[[ "\${1:-}" == -s ]] && { echo MINGW64_NT-10.0-19045; exit 0; }
exec "$REAL_UNAME" "\$@"
UEOF
cp "$FAKE/uname" "$NOCYG/uname"
cat >"$FAKE/cygpath" <<CEOF
#!/usr/bin/env bash
# fake cygpath: drive letters live under $DRIVES/<letter>
mode="\$1"; p="\$2"
case "\$mode" in
  -u) p="\${p//\\\\//}"
      if [[ "\$p" =~ ^([A-Za-z]):/?(.*)\$ ]]; then p="$DRIVES/\${BASH_REMATCH[1],,}/\${BASH_REMATCH[2]}"; fi
      printf '%s\r\n' "\$p" ;;
  -m) if [[ "\$p" == "$DRIVES/"?/* ]]; then r="\${p#"$DRIVES/"}"; p="\${r:0:1}"; p="\${p^^}:/\${r:2}"; fi
      printf '%s\r\n' "\$p" ;;
  *) echo "fake cygpath: unsupported \$mode" >&2; exit 1 ;;
esac
CEOF
for x in "$FAKE/uname" "$FAKE/cygpath" "$NOCYG/uname"; do chmod +x "$x"; done
for x in psql pg_dump pg_restore pg_isready; do
    cat >"$WINBIN/$x.exe" <<TEOF
#!/usr/bin/env bash
# fake native Windows $x: C:/... paths in, CRLF out
args=()
for a; do
    if [[ "\$a" =~ ^(--file=)?([A-Za-z]):/(.*)\$ ]]; then a="\${BASH_REMATCH[1]}$DRIVES/\${BASH_REMATCH[2],,}/\${BASH_REMATCH[3]}"; fi
    args+=("\$a")
done
printf '%s|PGPASSFILE=%s\n' "\$*" "\${PGPASSFILE:-}" >>"$W/calls.log"
if [[ "\${PGPASSFILE:-}" =~ ^([A-Za-z]):/(.*)\$ ]]; then export PGPASSFILE="$DRIVES/\${BASH_REMATCH[1],,}/\${BASH_REMATCH[2]}"; fi
"$CLIENT_BIN/$x" "\${args[@]}" 2> >(sed 's/\$/\r/' >&2) | sed 's/\$/\r/'
exit "\${PIPESTATUS[0]}"
TEOF
    chmod +x "$WINBIN/$x.exe"
done
cp "$PGPASS_FILE" "$DRIVES/c/Users/me/pg pass/pgpass.conf"
WCOMMON=(-h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" --min-free-mb 1
         --pgpassfile 'C:\Users\me\pg pass\pgpass.conf' --pg-bin "$WINBIN_WIN")
WENV=("PATH=$FAKE:$PATH")

PGPASSFILE="$PGPASS_FILE" bash -c "'$WINBIN/psql.exe' -X -At -h 127.0.0.1 -p $PORT -U $PGUSER_T -d postgres -c 'select 1' | od -c" >"$T/od.txt"
OUT="$(cat "$T/od.txt")"
check "fake psql.exe really prints CRLF" has '1  \r  \n'

# Reproduce the reported bug with the previous release (v2.0.0) when available.
if git -C "$HERE/.." cat-file -e "v2.0.0:pg_dump_wrapper.sh" 2>/dev/null || git -C "$HERE/.." cat-file -e "main:pg_dump_wrapper.sh" 2>/dev/null; then
    ref=main; git -C "$HERE/.." cat-file -e "v2.0.0:pg_dump_wrapper.sh" 2>/dev/null && ref=v2.0.0
    git -C "$HERE/.." show "$ref:pg_dump_wrapper.sh" >"$W/old_wrapper.sh"
    if grep -q 'SCRIPT_VERSION="2.0.0"' "$W/old_wrapper.sh"; then
        OLDBIN="$W/oldbin"; mkdir -p "$OLDBIN"
        for x in psql pg_dump pg_restore pg_isready; do ln -s "$WINBIN/$x.exe" "$OLDBIN/$x"; done
        OUT="$(env "${WENV[@]}" bash "$W/old_wrapper.sh" -h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" --min-free-mb 1 \
              --pgpassfile "$PGPASS_FILE" --pg-bin "$OLDBIN" --all -o "$W/old" 2>&1)"; RC=$?
        check "v2.0.0 reproduces the bug (CR in database names)" bash -c '[[ $1 -ne 0 ]] && grep -q "does not exist" <<<"$2"' _ "$RC" "$OUT"
    fi
fi

: >"$W/calls.log"
run "${WENV[@]}" -- "${WCOMMON[@]}" --all -o 'c:\backups'
check "Windows --all -o 'c:\\backups' exits 0" test "$RC" -eq 0
check "Windows --all selects 5 clean names" has "Databases selected by --all: $ALL_DBS_SORTED"
check "Windows --all dumps 5 databases" test "$(count_files "$DRIVES/c/backups" '*.dump')" -eq 5
for db in $ALL_DBS_SORTED; do
    check "Windows summary: $db OK" bash -c 'grep -qE "\[INFO\]   $1 +OK " <<<"$2"' _ "$db" "$OUT"
done
check "no CR in Windows log file" bash -c "! grep -q \$'\\r' '$DRIVES/c/backups/pg_dump_wrapper.log'"
check "Windows prechecks report database size" has "Connected: server_version_num="
check "pg_dump.exe gets --file=C:/backups/..." grep -q -- '--file=C:/backups/abc_' "$W/calls.log"
check "PGPASSFILE handed over as C:/Users/me/pg pass/pgpass.conf" grep -q 'PGPASSFILE=C:/Users/me/pg pass/pgpass.conf' "$W/calls.log"

mkdir -p "$DRIVES/c/backups2" "$DRIVES/c/logs"
for f in abc_20200101_000000.dump abc_20200101_000000.dump.sha256; do : >"$DRIVES/c/backups2/$f"; touch -d "$OLD_DAYS days ago" "$DRIVES/c/backups2/$f"; done
run "${WENV[@]}" -- "${WCOMMON[@]}" -d abc,chatagent -o 'C:/backups2' --log-file 'C:\logs\pdw run.log' \
    --verify --checksum -r "$RETENTION"
check "Windows C:/ output + verify + checksum + retention exits 0" test "$RC" -eq 0
check "Windows verify parsed CRLF pg_restore output" has "Verification OK (pg_restore --list:"
check "Windows log file at C:\\logs\\pdw run.log" test -s "$DRIVES/c/logs/pdw run.log"
check "Windows checksums validate" bash -c "cd '$DRIVES/c/backups2' && for f in *_2[1-9]*.sha256 *_20[3-9]*.sha256; do [[ -e \$f ]] || continue; sha256sum -c --quiet \"\$f\" || exit 1; done; ls *.sha256 | grep -qv 20200101"
check "Windows retention removed old abc backup" test ! -e "$DRIVES/c/backups2/abc_20200101_000000.dump"

run "${WENV[@]}" -- "${WCOMMON[@]}" -d inventory -F directory -j 2 --checksum -o 'C:\backups3'
check "Windows directory format -j 2 + checksum" bash -c "[[ $RC -eq 0 ]] && cd '$DRIVES/c/backups3' && sha256sum -c --quiet inventory_*.dir.sha256"

run "${WENV[@]}" -- "${WCOMMON[@]}" -d abc -F plain --verify -o 'C:\backups4'
check "Windows plain format verify" has "Verification OK (plain dump footer present)"

run "${WENV[@]}" -- "${WCOMMON[@]}" -d abc -o 'c:backups5'
check "unquoted c:\\backups (arrives as c:backups) warns" has "bash drops backslashes"
check "unquoted c:\\backups still dumps to C:/backups5" test "$(count_files "$DRIVES/c/backups5" '*.dump')" -eq 1

printf 'host=127.0.0.1\r\nport=%s\r\nuser=%s\r\ndbnames=abc,invent\r\noutput_dir=C:\\backups6\r\npgpassfile=C:\\Users\\me\\pg pass\\pgpass.conf\r\npg_bin=%s\r\nmin_free_mb=1\r\n' \
    "$PORT" "$PGUSER_T" "$WINBIN_WIN" >"$DRIVES/c/conf/pdw.conf"
run "${WENV[@]}" -- --config 'C:\conf\pdw.conf'
check "Windows paths inside a CRLF config file" test "$RC" -eq 0 -a "$(count_files "$DRIVES/c/backups6" '*.dump')" -eq 2

run "${WENV[@]}" -- "${WCOMMON[@]}" -d abc -f 'sub\x.dump' -o 'C:\backups7'
check "Windows --file with a backslash is rejected" test "$RC" -eq 1

run "PATH=$NOCYG:$PATH" -- -h 127.0.0.1 -p "$PORT" -d abc -o 'c:\backups' --pg-bin "$CLIENT_BIN" --dry-run -v
check "no cygpath: c:\\backups -> /c/backups" has "output_dir=/c/backups"
check "no cygpath: pg_dump gets --file=C:/backups/..." has "--file=C:/backups/abc_"

run "PATH=$NOCYG:$PATH" -- -h 127.0.0.1 -p "$PORT" -d abc -o '/c/backups' --pg-bin "$CLIENT_BIN" --dry-run
check "no cygpath: /c/backups -> --file=C:/backups/..." has "--file=C:/backups/abc_"

# ----------------------------------------------------------------------------
section "Table-size report (--table-sizes / table-sizes=)"
S="$T/sizes"; mkdir -p "$S"
line_no() { grep -nF -- "$1" <<<"$OUT" | head -n1 | cut -d: -f1; }

run -- "${COMMON[@]}" -d abc -o "$S/default"
check "default lists every table of abc (3 <= default)" has "Largest tables: all 3"
check "rows sorted by size: sales.orders before public.t_abc" bash -c '[[ -n $1 && -n $2 && $1 -lt $2 ]]' _ "$(line_no "  sales.orders ")" "$(line_no "  public.t_abc ")"
check "estimated rows shown (5000)" bash -c 'grep -qE "sales\.orders +[0-9.]+ [kMG]?B +5000$" <<<"$1"' _ "$OUT"
check "system schemas excluded" hasnt "pg_catalog."
check "report is in the log file too" grep -q "Largest tables: all 3" "$S/default/pg_dump_wrapper.log"

run -- "${COMMON[@]}" -d abc --table-sizes 2 -o "$S/two"
check "--table-sizes 2 -> top 2 of 3" has "Largest tables: top 2 of 3"
check "--table-sizes 2 hides the smallest" hasnt 'sales.MixedCase'

run -- "${COMMON[@]}" -d abc --table-sizes 0 -o "$S/off"
check "--table-sizes 0 turns it off" hasnt "Largest tables"

run -- "${COMMON[@]}" -d abc --table-sizes ALL -o "$S/all"
check "--table-sizes all" has "Largest tables: all 3"

run -- "${COMMON[@]}" -d abc --table-sizes lots -o "$S/bad"
check "invalid --table-sizes -> exit 1" bash -c '[[ $1 -eq 1 ]] && grep -q "must be a number" <<<"$2"' _ "$RC" "$OUT"

printf 'host=127.0.0.1\nport=%s\nuser=%s\ndbnames=abc\npgpassfile=%s\nmin_free_mb=1\ntable-sizes=1\n' \
    "$PORT" "$PGUSER_T" "$PGPASS_FILE" >"$S/sizes.conf"
run -- --config "$S/sizes.conf" -o "$S/conf"
check "config key table-sizes=1 -> top 1 of 3" has "Largest tables: top 1 of 3"
run -- --config "$S/sizes.conf" --table-sizes 0 -o "$S/conf0"
check "CLI --table-sizes overrides the config" hasnt "Largest tables"

run -- "${COMMON[@]}" -d abc -t public.t_abc -o "$S/t"
check "-t public.t_abc lists only that table" bash -c 'grep -q "Largest tables matching -t public.t_abc: all 1" <<<"$1" && ! grep -q "  sales.orders " <<<"$1"' _ "$OUT"

run -- "${COMMON[@]}" -d abc -o "$S/extra" -- -t 'sales.*'
check "-t 'sales.*' after -- lists the 2 sales tables" has "Largest tables matching -t sales.*: all 2"

run -- "${COMMON[@]}" -d abc -t 'sales."MixedCase"' -o "$S/quoted"
check "quoted -t pattern keeps case" bash -c 'grep -q "all 1" <<<"$1" && grep -q "  sales.MixedCase " <<<"$1"' _ "$OUT"

run -- "${COMMON[@]}" -d abc -t 'nosuch*' -o "$S/none"
check "-t matching nothing -> 'no tables matching' (dump still runs)" has "Table sizes: no tables matching -t nosuch*"

run -- "${COMMON[@]}" -d abc --dry-run -o "$S/dry"
check "dry-run shows the report" has "Largest tables: all 3"

run -- "${COMMON[@]}" -d abc --skip-precheck -o "$S/skip"
check "--skip-precheck -> report skipped with a warning" has "Table sizes skipped (--skip-precheck)"

run -- -h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" -d abc --dry-run --pgpassfile "$T/pw" -o "$S/dryfail"
check "dry-run without a working login -> warning, exit 0" bash -c '[[ $1 -eq 0 ]] && grep -q "Table sizes unavailable" <<<"$2"' _ "$RC" "$OUT"

run "${WENV[@]}" -- "${WCOMMON[@]}" -d abc -o 'C:\sizes'
check "Windows CRLF tools: report has clean rows" bash -c 'grep -qE "sales\.orders +[0-9.]+ [kMG]?B +5000$" <<<"$1"' _ "$OUT"
check "Windows CRLF tools: no CR in the log" bash -c "! grep -q \$'\\r' '$DRIVES/c/sizes/pg_dump_wrapper.log'"

# ----------------------------------------------------------------------------
section "One file per table (--per-table)"
Q="$T/pertable"; mkdir -p "$Q"

run -- "${COMMON[@]}" -d abc --per-table -o "$Q/none"
check "--per-table without -t/-n -> exit 1" bash -c '[[ $1 -eq 1 ]] && grep -q "needs tables" <<<"$2"' _ "$RC" "$OUT"
run -- "${COMMON[@]}" -d abc --per-table -t sales.orders -f x.dump -o "$Q/f"
check "--per-table with -f -> exit 1" test "$RC" -eq 1
run -- "${COMMON[@]}" -d abc --per-table -n sales -o "$Q/extra" -- -t public.t_abc
check "--per-table with -t after -- -> exit 1" test "$RC" -eq 1
run -- "${COMMON[@]}" -d abc --per-table -t sales.orders --per-table-file-pattern '{db}_{schema}_{table}.dump' -o "$Q/p1"
check "file pattern without {date} -> exit 1" bash -c '[[ $1 -eq 1 ]] && grep -q "must contain {date}" <<<"$2"' _ "$RC" "$OUT"
run -- "${COMMON[@]}" -d abc --per-table -t sales.orders --per-table-file-pattern '{db}_{schema}_{table}_{date}_{host}' -o "$Q/p2"
check "file pattern with unknown token -> exit 1" bash -c '[[ $1 -eq 1 ]] && grep -q "unknown token" <<<"$2"' _ "$RC" "$OUT"

run -- "${COMMON[@]}" -d abc --per-table -t sales.orders,public.t_abc --verify --checksum -o "$Q/two"
check "-t sales.orders,public.t_abc -> exit 0" test "$RC" -eq 0
check "one file per table" bash -c '[[ $(ls "$1"/abc_sales_orders_*.dump | wc -l) -eq 1 && $(ls "$1"/abc_public_t_abc_*.dump | wc -l) -eq 1 ]]' _ "$Q/two"
check "per-file checksums validate" bash -c "cd '$Q/two' && for f in *.sha256; do sha256sum -c --quiet \"\$f\" || exit 1; done && [[ \$(ls *.sha256 | wc -l) -eq 2 ]]"
check "per-file verify ran twice" bash -c '[[ $(grep -c "Verification OK" <<<"$1") -eq 2 ]]' _ "$OUT"
check "summary has one row per table" bash -c 'grep -q "DATABASE:TABLE" <<<"$1" && grep -qE "abc:sales\.orders +OK" <<<"$1" && grep -qE "abc:public\.t_abc +OK" <<<"$1"' _ "$OUT"
check "each file holds only its table" bash -c 'l="$("$1"/pg_restore --list "$2"/abc_sales_orders_*.dump)"; grep -q "TABLE DATA sales orders" <<<"$l" && ! grep -q "t_abc" <<<"$l"' _ "$CLIENT_BIN" "$Q/two"
check "table sizes listed once for the selected tables" bash -c '[[ $(grep -c "Largest selected tables: all 2" <<<"$1") -eq 1 ]]' _ "$OUT"

run -- "${COMMON[@]}" -d abc --per-table -n sales -o "$Q/schema"
check "-n sales -> every table in the schema (2)" bash -c '[[ $1 -eq 0 ]] && [[ $(ls "$2"/*.dump | wc -l) -eq 2 ]] && ls "$2"/abc_sales_MixedCase_*.dump >/dev/null' _ "$RC" "$Q/schema"

run -- "${COMMON[@]}" -d invent --per-table -n 'odd sch' -o "$Q/odd"
check "unsafe names sanitised: invent_odd_sch_we_ird_na_me_<date>.dump" bash -c '[[ $1 -eq 0 ]] && ls "$2"/invent_odd_sch_we_ird_na_me_*.dump >/dev/null' _ "$RC" "$Q/odd"

run -- "${COMMON[@]}" -d abc,chatagent,inventory --per-table -t sales.orders -o "$Q/multi"
check "multi-db: exit 2 because chatagent has no sales.orders" test "$RC" -eq 2
check "multi-db: clear message for the missing table" has "No table matches -t sales.orders in database 'chatagent'"
check "multi-db: FAIL row for chatagent, OK rows for abc and inventory" bash -c 'grep -qE "chatagent:-t sales\.orders +FAIL\(2\) +precheck" <<<"$1" && grep -qE "abc:sales\.orders +OK" <<<"$1" && grep -qE "inventory:sales\.orders +OK" <<<"$1"' _ "$OUT"
check "multi-db: 2 files written" test "$(count_files "$Q/multi" '*.dump')" -eq 2

run -- "${COMMON[@]}" -d chatagent,abc --per-table -t sales.orders --stop-on-error -o "$Q/stop"
check "--stop-on-error: later database SKIPPED" bash -c '[[ $1 -eq 2 ]] && grep -qE "INFO\]   abc +SKIPPED" <<<"$2"' _ "$RC" "$OUT"

run -- "${COMMON[@]}" -d abc --per-table -t sales.orders,nosuch.table,public.t_abc -o "$Q/partial"
check "one missing table does not stop the others" bash -c '[[ $1 -eq 2 ]] && [[ $(ls "$2"/*.dump | wc -l) -eq 2 ]] && grep -q "abc:-t nosuch.table" <<<"$3"' _ "$RC" "$Q/partial" "$OUT"

printf 'host=127.0.0.1\nport=%s\nuser=%s\ndbnames=abc\npgpassfile=%s\nmin_free_mb=1\nper-table=yes\ntables=sales.orders\nformat=plain\nper-table-file-pattern={schema}.{table}-{db}-{date}\n' \
    "$PORT" "$PGUSER_T" "$PGPASS_FILE" >"$Q/pt.conf"
run -- --config "$Q/pt.conf" -o "$Q/conf" --verify
check "config per-table-file-pattern (no {ext} -> .sql appended)" bash -c '[[ $1 -eq 0 ]] && ls "$2"/sales.orders-abc-2*.sql >/dev/null' _ "$RC" "$Q/conf"

mkdir -p "$Q/ret"
for f in abc_sales_orders_20200101_000000.dump abc_sales_orders_20200101_000000.dump.sha256 \
         abc_sales_orders_extra_20200101_000000.dump abc_20200101_000000.dump abc_public_t_abc_20200101_000000.dump; do
    : >"$Q/ret/$f"; touch -d "$OLD_DAYS days ago" "$Q/ret/$f"
done
run -- "${COMMON[@]}" -d abc --per-table -t sales.orders -r "$RETENTION" -o "$Q/ret"
check "retention deletes this table's old files" test ! -e "$Q/ret/abc_sales_orders_20200101_000000.dump" -a ! -e "$Q/ret/abc_sales_orders_20200101_000000.dump.sha256"
check "retention keeps other tables' and whole-db files" test -e "$Q/ret/abc_sales_orders_extra_20200101_000000.dump" -a -e "$Q/ret/abc_20200101_000000.dump" -a -e "$Q/ret/abc_public_t_abc_20200101_000000.dump"

run -- "${COMMON[@]}" -d abc --per-table -t 'sales.*' -F directory -j 2 --dry-run -o "$Q/dry"
check "dry-run: one command per table, exact quoted --table" bash -c '[[ ! -e $2 ]] && grep -qF -- "--table=\\\"sales\\\".\\\"orders\\\"" <<<"$1" && [[ $(grep -c -- "--file=" <<<"$1") -eq 2 ]]' _ "$OUT" "$Q/dry"

run -- "${COMMON[@]}" -d abc --per-table -t sales.orders -F directory -j 2 --checksum -o "$Q/dir"
check "directory format per table" bash -c '[[ $1 -eq 0 ]] && cd "$2" && sha256sum -c --quiet abc_sales_orders_*.dir.sha256' _ "$RC" "$Q/dir"

run "${WENV[@]}" -- "${WCOMMON[@]}" -d abc,inventory --per-table -t sales.orders --verify --checksum -o 'C:\pertable'
check "Windows CRLF tools: per-table for 2 databases" bash -c '[[ $1 -eq 0 ]] && [[ $(ls "$2"/*_sales_orders_*.dump | wc -l) -eq 2 ]]' _ "$RC" "$DRIVES/c/pertable"
check "Windows: no CR in table names / log" bash -c "! grep -q \$'\\r' '$DRIVES/c/pertable/pg_dump_wrapper.log'"

# ----------------------------------------------------------------------------
section "-W: one prompt from the terminal (driven through a pty with script(1))"
P="$T/prompt"; mkdir -p "$P"
NOPASS=(-h 127.0.0.1 -p "$PORT" -U "$PGUSER_T" --min-free-mb 1)
RUNTTY_ENV=()
runtty() {   # runtty <typed-password> wrapper-args... ; pty transcript in $OUT
    local typed="$1"; shift
    local cmd; cmd="$(printf '%q ' env PGPASSFILE="$T/no-such-pgpass" PGPASSWORD= "${RUNTTY_ENV[@]}" bash "$WRAPPER" "$@")"
    OUT="$( { sleep 1; printf '%s\n' "$typed"; } | script -qefc "$cmd" /dev/null 2>&1)"; RC=$?
}
prompts() { grep -o "Password for user" <<<"$OUT" | wc -l; }

runtty "$PASSWORD_T" "${NOPASS[@]}" -W -d abc -o "$P/one"
check "-W -d abc exits 0" test "$RC" -eq 0
check "-W -d abc wrote the dump" test "$(count_files "$P/one" 'abc_*.dump')" -eq 1
check "-W runs the connection pre-check" has "Connected: server_version_num="

runtty "$PASSWORD_T" "${NOPASS[@]}" -W --all -o "$P/all" --verify --checksum
check "-W --all exits 0" test "$RC" -eq 0
check "-W --all dumps 5 databases" test "$(count_files "$P/all" '*.dump')" -eq 5
check "-W --all prompts exactly once" test "$(prompts)" -eq 1
check "password not echoed on the terminal or in output" hasnt "$PASSWORD_T"

runtty "$PASSWORD_T" "${NOPASS[@]}" -W -d abc,chatagent,invent -o "$P/multi"
check "-W with 3 databases prompts exactly once" test "$(prompts)" -eq 1 -a "$(count_files "$P/multi" '*.dump')" -eq 3
check "pg_dump gets --no-password, not --password" bash -c 'grep -q -- "--no-password" <<<"$1" && ! grep -q -- " --password" <<<"$1"' _ "$OUT"

check "password not in any log file" bash -c "! grep -rqF -- '$PASSWORD_T' '$P'/*/pg_dump_wrapper.log"

runtty "wrong_$PASSWORD_T" "${NOPASS[@]}" -W -d abc -o "$P/wrong"
check "wrong password -> exit 2" test "$RC" -eq 2
check "wrong password -> authentication error shown" has "password authentication failed"
check "wrong password -> no dump left" test "$(count_files "$P/wrong" '*.dump')" -eq 0

runtty "wrong_$PASSWORD_T" "${NOPASS[@]}" -W --all -o "$P/wrongall"
check "wrong password with --all -> exit 2, clean message" bash -c '[[ $1 -eq 2 ]] && grep -q "Cannot list databases" <<<"$2"' _ "$RC" "$OUT"

runtty "" "${NOPASS[@]}" -W -d abc -o "$P/empty"
check "empty password -> exit 1 with message" bash -c '[[ $1 -eq 1 ]] && grep -q "No password entered" <<<"$2"' _ "$RC" "$OUT"

OUT="$(PGPASSFILE="$T/no-such-pgpass" setsid bash "$WRAPPER" "${NOPASS[@]}" -W -d abc -o "$P/notty" </dev/null 2>&1)"; RC=$?
check "no terminal -> exit 1" test "$RC" -eq 1
check "no terminal -> points to pgpass" has "-W needs a terminal"

runtty "$PASSWORD_T" "${NOPASS[@]}" -W -d abc -o "$P/dry" --dry-run --table-sizes 0
check "-W dry-run for -d (no table sizes) does not prompt" test "$(prompts)" -eq 0
runtty "$PASSWORD_T" "${NOPASS[@]}" -W -d abc -o "$P/drysizes" --dry-run
check "-W dry-run with table sizes prompts once and shows them" bash -c '[[ $(grep -c "Password for user" <<<"$1") -eq 1 ]] && grep -q "Largest tables: all 3" <<<"$1"' _ "$OUT"
runtty "$PASSWORD_T" "${NOPASS[@]}" -W --all -o "$P/dryall" --dry-run
check "-W dry-run --all prompts once and lists 5" bash -c '[[ $1 -eq 0 ]] && [[ $(grep -c -- "--file=" <<<"$2") -eq 5 ]]' _ "$RC" "$OUT"

RUNTTY_ENV=("${WENV[@]}")
runtty "$PASSWORD_T" "${NOPASS[@]}" --pg-bin "$WINBIN_WIN" -W --all -o 'C:\wprompt'
RUNTTY_ENV=()
check "-W --all with simulated Windows tools" test "$RC" -eq 0 -a "$(count_files "$DRIVES/c/wprompt" '*.dump')" -eq 5

# ----------------------------------------------------------------------------
section "Static checks"
if command -v shellcheck >/dev/null 2>&1; then
    OUT="$(shellcheck -e SC2329 "$WRAPPER" 2>&1)"; check "shellcheck clean" test -z "$OUT"
fi
OUT="$(bash "$WRAPPER" --version)"; check "--version" has "2.2.0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
