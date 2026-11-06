#!/bin/bash
# shellcheck disable=SC2015  # "[ test ] && ok || bad" is the intended reporting idiom here
# Tests for the job "Database PSQL - Dictionary Restore Dump": the dump URL comes from build-spec.json
# (jq, whitespace stripped, refused before any AWS call unless s3://<bucket>/<key>.tar), the in-boundary bucket is read
# with the instance role while any other bucket takes the legacy curated_datasets_s3_role path, and the dump is checked
# (non-empty, extracts, toc.dat) before the secret fetch, the connection test or pg_restore.
# The job shell step is extracted from config.xml and run against a fake `aws` (S3 = a directory tree), fake `psql` and
# `pg_restore` on PATH, and a fake Bash_Functions workspace (assume_role, reset_role, fetch_secret, extract_field).
# tar and jq are the real ones. No real AWS, database or Jenkins is touched. Only placeholder data.
#
# usage: bash jenkins-docker/tests/dictionary-restore.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
JOB_REL="jenkins-docker/jobs/Database PSQL - Dictionary Restore Dump/config.xml"
JOB_XML="$HERE/../jobs/Database PSQL - Dictionary Restore Dump/config.xml"

T="$(mktemp -d "${TMPDIR:-/tmp}/dictionary-restore-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
check() { # check <description> <command...>
    local d="$1"
    shift
    if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

# ---------------------------------------------------------------- fakes
BIN="$T/bin"
mkdir -p "$BIN"

cat > "$BIN/aws" << 'FAKE_AWS'
#!/bin/bash
# fake aws: bucket/key lives at $FAKE_S3/<bucket>/<key>; every call is logged to the shared call log.
echo "aws $*" >> "$CALLS"
if [ "$1/$2" = "s3/cp" ]; then
    src="$FAKE_S3/${3#s3://}"
    [ -f "$src" ] || { echo "fake aws: missing source $3" >&2; exit 1; }
    cp "$src" "$4"
else
    echo "fake aws: unsupported: $*" >&2
    exit 2
fi
FAKE_AWS

cat > "$BIN/psql" << 'FAKE_PSQL'
#!/bin/bash
echo "psql $*" >> "$CALLS"
FAKE_PSQL

cat > "$BIN/pg_restore" << 'FAKE_PG_RESTORE'
#!/bin/bash
if [ "$1" = "--list" ]; then
    # offline TOC read: logged separately (it touches no database). One TABLE DATA line per <id>.dat* file,
    # plus $FAKE_TOC_EXTRA (an id with no file); $FAKE_TOC_FAIL makes it fail like a corrupt toc.dat.
    echo "pg_restore $*" >> "$CALLS.list"
    [ -z "${FAKE_TOC_FAIL:-}" ] || { echo "pg_restore: error: corrupt toc" >&2; exit 1; }
    echo ";"
    echo "; Archive created at 2026-11-05"
    for f in "$2"/*.dat*; do
        [ -e "$f" ] || continue
        id="$(basename "$f")"; id="${id%%.*}"
        echo "${id}; 1259 16400 TABLE DATA dict t${id} owner"
    done
    [ -z "${FAKE_TOC_EXTRA:-}" ] || echo "${FAKE_TOC_EXTRA}; 1259 16401 TABLE DATA dict t${FAKE_TOC_EXTRA} owner"
    echo "4100; 2606 16500 CONSTRAINT dict t3001 pk owner"
    exit 0
fi
echo "pg_restore $*" >> "$CALLS"
# what pg_restore would see in the directory
echo "pg_restore sees: $(find "${@: -1}" -type f | sed 's|.*/||' | sort | tr '\n' ' ')" >> "$CALLS"
FAKE_PG_RESTORE
chmod +x "$BIN/aws" "$BIN/psql" "$BIN/pg_restore"

export FAKE_S3="$T/s3"
export CALLS="$T/calls.log"
export PATH="$BIN:$PATH"

# fake Bash_Functions workspace
export JENKINS_HOME="$T/jh"
mkdir -p "$JENKINS_HOME/workspace/Bash_Functions"
cat > "$JENKINS_HOME/workspace/Bash_Functions/functions.sh" << 'FAKE_FUNCS'
assume_role() { echo "assume_role${*:+ $*}" >> "$CALLS"; }
reset_role() { echo "reset_role" >> "$CALLS"; }
fetch_secret() { echo "fetch_secret $*" >> "$CALLS"; echo '{"username":"fakeuser","password":"fakepass"}'; }
extract_field() { case "$2" in username) echo fakeuser ;; password) echo fakepass ;; esac; }
FAKE_FUNCS

LEGACY_BUCKET=example-legacy-bucket
INB_BUCKET=bdc-etl-data-d0d6191
INB_URL="s3://$INB_BUCKET/data/dictionary/db-dumps/dictionary_db_11-05-26T14.tar"
LEGACY_URL="s3://$LEGACY_BUCKET/general/hpds/javabin/dictionary_db_10-01-26T09.tar"
ROLE="arn:aws:iam::000000000000:role/fake-curated"
EXPECTED_RESTORE="pg_restore --host=db.example.invalid --port=5432 --username=fakeuser --dbname=picsure --format=d --jobs=10 --clean --verbose --no-owner --no-privileges --no-tablespaces --no-comments --no-publications --no-subscriptions --no-security-labels --no-table-access-method --schema=dict dump_files/"

python3 -I "$HERE/extract-shell.py" "$JOB_XML" > "$T/job.sh" || { echo "cannot extract the job shell"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$JOB_XML" --groovy --index 0 > "$T/job.groovy" || { echo "cannot extract the groovy step"; exit 1; }

# ---------------------------------------------------------------- fixtures
# make_dump <bucket> <key> [valid|notoc|garbage|empty] : put a dump tar into the fake S3.
make_dump() {
    local f="$FAKE_S3/$1/$2" kind="${3:-valid}" d="$T/mk"
    mkdir -p "$(dirname "$f")"
    rm -rf "$d"
    mkdir -p "$d/dictionary_db.sql"
    case "$kind" in
        valid)
            printf 'TOC' > "$d/dictionary_db.sql/toc.dat"
            printf 'D1' > "$d/dictionary_db.sql/3001.dat.gz"
            printf 'D2' > "$d/dictionary_db.sql/3002.dat.gz"
            tar -C "$d" -cf "$f" dictionary_db.sql
            ;;
        notoc)
            printf 'D1' > "$d/dictionary_db.sql/3001.dat.gz"
            tar -C "$d" -cf "$f" dictionary_db.sql
            ;;
        garbage) head -c 4000 /dev/zero | tr '\0' 'x' > "$f" ;;
        empty) : > "$f" ;;
    esac
}

# run_job <build-spec.json contents|-NONE-> : fresh workspace holding build-spec.json; exit code in $rc,
# stdout/stderr in $T/out and $T/err, calls in $CALLS.
run_job() {
    rm -rf "$T/ws"
    mkdir -p "$T/ws"
    : > "$CALLS"
    : > "$CALLS.list"
    if [ "$1" != "-NONE-" ]; then printf '%s\n' "$1" > "$T/ws/build-spec.json"; fi
    (
        cd "$T/ws" || exit 99
        curated_datasets_s3_role="${CURATED_ROLE-$ROLE}" database_psql_root_user_secret_name=fake-secret \
            database_psql_host_address=db.example.invalid \
            bash "$T/job.sh" > "$T/out" 2> "$T/err" < /dev/null
    )
    rc=$?
}

spec() { jq -n --arg u "$1" '{source_dictionary_db_s3_url: $u, other: "x"}'; }
called() { grep -q "$1" "$CALLS"; }
count() { grep -c "$1" "$CALLS" || true; }
line_of() { grep -n "$1" "$CALLS" | head -1 | cut -d: -f1; }
no_aws_call() { ! called '^aws '; }
no_db_calls() { ! called '^fetch_secret' && ! called '^psql' && ! called '^pg_restore'; }

# ================================================================ in-boundary URL
rm -rf "$FAKE_S3"
make_dump "$INB_BUCKET" data/dictionary/db-dumps/dictionary_db_11-05-26T14.tar valid
run_job "$(spec "$INB_URL")"
[ "$rc" = 0 ] && ok "in-boundary: exits 0" || { bad "in-boundary: exits 0 (rc=$rc)"; cat "$T/err"; }
check "in-boundary: no assume_role with the curated role (nor before the download)" test "$(grep -c "assume_role $ROLE" "$CALLS")" = 0
check "in-boundary: no reset_role" test "$(count '^reset_role')" = 0
check "in-boundary: the only assume_role is the bare one for the secret, after the download" bash -c "
    [ \"\$(grep -c '^assume_role' '$CALLS')\" = 1 ] && grep -qx 'assume_role' '$CALLS' &&
    [ \$(grep -n '^aws ' '$CALLS' | head -1 | cut -d: -f1) -lt \$(grep -n '^assume_role' '$CALLS' | head -1 | cut -d: -f1) ]"
check "in-boundary: exactly one aws call, s3 cp from the URL" test "$(grep -c '^aws ' "$CALLS")" = 1 -a "$(grep -c "^aws s3 cp $INB_URL dictionary_db.tar\$" "$CALLS")" = 1
check "in-boundary: pg_restore called with the unchanged flags on dump_files/" grep -qxF "$EXPECTED_RESTORE" "$CALLS"
check "in-boundary: pg_restore sees the flattened files (toc.dat and the data files)" grep -qx 'pg_restore sees: 3001.dat.gz 3002.dat.gz toc.dat ' "$CALLS"
check "in-boundary: psql connection test ran against picsure" grep -q '^psql --host=db.example.invalid --port=5432 --username=fakeuser --dbname=picsure -c \\q$' "$CALLS"
check "in-boundary: fetch_secret before psql before pg_restore" test "$(line_of '^fetch_secret')" -lt "$(line_of '^psql')" -a "$(line_of '^psql')" -lt "$(line_of '^pg_restore ')"
check "in-boundary: log names the source and the instance role" grep -q "in-boundary bucket, $INB_URL (identity: Jenkins instance role" "$T/out"
check "in-boundary: no secret in the output" bash -c "! grep -q fakepass '$T/out' '$T/err'"
check "in-boundary: the dump TOC was read offline (pg_restore --list dump_files/)" grep -qx 'pg_restore --list dump_files/' "$CALLS.list"

# in-boundary download failure: no role, no database
rm -rf "$FAKE_S3"
run_job "$(spec "$INB_URL")"
[ "$rc" != 0 ] && ok "in-boundary, missing object: fails" || bad "in-boundary, missing object: fails"
check "in-boundary, missing object: no assume_role or reset_role at all" bash -c "! grep -qE '^(assume_role|reset_role)' '$CALLS'"
check "in-boundary, missing object: no fetch_secret, psql or pg_restore" no_db_calls

# bucket names that only look like the in-boundary bucket take the legacy path
for spoof in "$INB_BUCKET.evil" "${INB_BUCKET}x"; do
    rm -rf "$FAKE_S3"
    make_dump "$spoof" k/dictionary_db.tar valid
    run_job "$(spec "s3://$spoof/k/dictionary_db.tar")"
    [ "$rc" = 0 ] && ok "lookalike bucket $spoof: exits 0" || bad "lookalike bucket $spoof: exits 0 (rc=$rc)"
    check "lookalike bucket $spoof: legacy identity (assume curated role, then reset_role)" bash -c "
        [ \"\$(sed -n 1p '$CALLS')\" = 'assume_role $ROLE' ] && [ \"\$(sed -n 3p '$CALLS')\" = 'reset_role' ]"
done

# ================================================================ legacy URL
rm -rf "$FAKE_S3"
make_dump "$LEGACY_BUCKET" general/hpds/javabin/dictionary_db_10-01-26T09.tar valid
run_job "$(spec "$LEGACY_URL")"
[ "$rc" = 0 ] && ok "legacy: exits 0" || { bad "legacy: exits 0 (rc=$rc)"; cat "$T/err"; }
check "legacy: assume_role with the curated role comes first" test "$(sed -n 1p "$CALLS")" = "assume_role $ROLE"
check "legacy: aws s3 cp from the URL after assume_role" test "$(sed -n 2p "$CALLS")" = "aws s3 cp $LEGACY_URL dictionary_db.tar"
check "legacy: reset_role right after the download" test "$(sed -n 3p "$CALLS")" = "reset_role"
check "legacy: then the bare assume_role, fetch_secret, psql, pg_restore" bash -c "
    [ \"\$(sed -n 4p '$CALLS')\" = 'assume_role' ] && [ \"\$(sed -n 5p '$CALLS')\" = 'fetch_secret fake-secret' ] &&
    sed -n 6p '$CALLS' | grep -q '^psql ' && sed -n 7p '$CALLS' | grep -q '^pg_restore '"
check "legacy: pg_restore called with the unchanged flags on dump_files/" grep -qxF "$EXPECTED_RESTORE" "$CALLS"
check "legacy: log names the legacy source and curated_datasets_s3_role" grep -q "legacy location, $LEGACY_URL (identity: curated_datasets_s3_role)" "$T/out"

CURATED_ROLE="" run_job "$(spec "$LEGACY_URL")"
[ "$rc" = 0 ] && ok "legacy, role not set: exits 0" || { bad "legacy, role not set: exits 0 (rc=$rc)"; cat "$T/err"; }
check "legacy, role not set: no curated assume_role and no reset_role" bash -c "! grep -q 'assume_role arn' '$CALLS' && ! grep -q '^reset_role' '$CALLS'"

# legacy download failure: role is reset, build fails, database untouched
rm -rf "$FAKE_S3"
run_job "$(spec "$LEGACY_URL")"
[ "$rc" != 0 ] && ok "legacy, missing object: fails" || bad "legacy, missing object: fails"
check "legacy, missing object: reset_role still runs, after the aws call" test "$(line_of '^aws ')" -lt "$(line_of '^reset_role')"
check "legacy, missing object: no fetch_secret, psql or pg_restore" no_db_calls

# ================================================================ whitespace in the JSON value
rm -rf "$FAKE_S3"
make_dump "$INB_BUCKET" data/dictionary/db-dumps/dictionary_db_11-05-26T14.tar valid
run_job "{\"source_dictionary_db_s3_url\": \"  \\t $INB_URL \\n \"}"
[ "$rc" = 0 ] && ok "whitespace around the URL: works" || { bad "whitespace around the URL: works (rc=$rc)"; cat "$T/err"; }
check "whitespace around the URL: s3 cp gets the clean URL" grep -qx "aws s3 cp $INB_URL dictionary_db.tar" "$CALLS"
rm -rf "$FAKE_S3"
make_dump "$LEGACY_BUCKET" general/hpds/javabin/dictionary_db_10-01-26T09.tar valid
run_job "{\"source_dictionary_db_s3_url\": \" $LEGACY_URL\\n\"}"
[ "$rc" = 0 ] && ok "whitespace around a legacy URL: works" || { bad "whitespace around a legacy URL: works (rc=$rc)"; cat "$T/err"; }

# ================================================================ bad build-spec: refused, no aws call
refused() { # refused <description> <build-spec contents|-NONE->
    run_job "$2"
    [ "$rc" = 1 ] && ok "$1: exit 1" || bad "$1: exit 1 (rc=$rc)"
    check "$1: REFUSED message" grep -q '^REFUSED: ' "$T/err"
    check "$1: no aws call, no database call, no assume_role" test ! -s "$CALLS"
}
refused "missing field" '{"other": "x"}'
refused "empty field" '{"source_dictionary_db_s3_url": ""}'
refused "whitespace-only field" '{"source_dictionary_db_s3_url": "  \t "}'
refused "null field" '{"source_dictionary_db_s3_url": null}'
refused "non-string field" '{"source_dictionary_db_s3_url": 42}'
refused "no build-spec.json" -NONE-
refused "build-spec.json is not JSON" 'not json {'
refused "non-s3 URL (https)" "$(spec "https://$LEGACY_BUCKET/x/dictionary_db.tar")"
refused "non-s3 URL (bare path)" "$(spec "$LEGACY_BUCKET/x/dictionary_db.tar")"
refused "s3 URL without a key" "$(spec "s3://$LEGACY_BUCKET")"
refused "s3 URL with an empty key" "$(spec "s3://$LEGACY_BUCKET/")"
refused "s3 URL without a bucket" "$(spec "s3:///x/dictionary_db.tar")"
refused "URL with inner whitespace" "$(spec "s3://$LEGACY_BUCKET/x/dictionary db.tar")"
refused "key not ending in .tar (legacy)" "$(spec "s3://$LEGACY_BUCKET/x/dictionary_db.tar.gz")"
refused "key not ending in .tar (in-boundary)" "$(spec "s3://$INB_BUCKET/data/dictionary/db-dumps/")"
refused "key is a prefix, not a tar" "$(spec "s3://$INB_BUCKET/data/dictionary/db-dumps/dictionary_db_11-05-26T14")"
check "REFUSED message names the field" grep -q 'source_dictionary_db_s3_url' "$T/err"

# ================================================================ bad dump: checked before the database is touched
bad_dump() { # bad_dump <description> <kind> <message regexp>
    local bucket key url
    for which in in-boundary legacy; do
        rm -rf "$FAKE_S3"
        if [ "$which" = in-boundary ]; then bucket=$INB_BUCKET; key=data/dictionary/db-dumps/d.tar; else bucket=$LEGACY_BUCKET; key=general/d.tar; fi
        url="s3://$bucket/$key"
        make_dump "$bucket" "$key" "$2"
        run_job "$(spec "$url")"
        [ "$rc" != 0 ] && ok "$1 ($which): exits non-zero" || bad "$1 ($which): exits non-zero"
        check "$1 ($which): clear message" grep -q "$3" "$T/err"
        check "$1 ($which): no fetch_secret, psql or pg_restore" no_db_calls
        check "$1 ($which): the download did happen (so the check is the gate)" called '^aws s3 cp '
    done
}
bad_dump "empty download" empty "empty"
bad_dump "tar that will not extract" garbage "could not be extracted"
bad_dump "tar without toc.dat" notoc "no toc.dat"
check "bad dump (legacy): reset_role ran before the check failed" bash -c "grep -q '^reset_role' '$CALLS'"

# TOC checks (pg_restore --list): unreadable TOC, or a TABLE DATA entry without its data file
for which in in-boundary legacy; do
    if [ "$which" = in-boundary ]; then bucket=$INB_BUCKET; key=data/dictionary/db-dumps/d.tar; else bucket=$LEGACY_BUCKET; key=general/d.tar; fi
    rm -rf "$FAKE_S3"
    make_dump "$bucket" "$key" valid
    export FAKE_TOC_FAIL=1
    run_job "$(spec "s3://$bucket/$key")"
    unset FAKE_TOC_FAIL
    [ "$rc" != 0 ] && ok "unreadable TOC ($which): fails" || bad "unreadable TOC ($which): fails"
    check "unreadable TOC ($which): clear message" grep -q 'cannot read the dump table of contents' "$T/err"
    check "unreadable TOC ($which): no fetch_secret, psql or pg_restore" no_db_calls
    export FAKE_TOC_EXTRA=3999
    run_job "$(spec "s3://$bucket/$key")"
    unset FAKE_TOC_EXTRA
    [ "$rc" != 0 ] && ok "TOC lists a missing data file ($which): fails" || bad "TOC lists a missing data file ($which): fails"
    check "TOC lists a missing data file ($which): names it" grep -q 'missing data file 3999.dat' "$T/err"
    check "TOC lists a missing data file ($which): no fetch_secret, psql or pg_restore" no_db_calls
done

# a stale dump_files/ from an earlier build in the same workspace must not satisfy the toc.dat check
rm -rf "$FAKE_S3"
make_dump "$INB_BUCKET" data/dictionary/db-dumps/d.tar notoc
rm -rf "$T/ws"
mkdir -p "$T/ws/dump_files"
touch "$T/ws/dump_files/toc.dat"
: > "$CALLS"
: > "$CALLS.list"
spec "s3://$INB_BUCKET/data/dictionary/db-dumps/d.tar" > "$T/ws/build-spec.json"
if (cd "$T/ws" && database_psql_root_user_secret_name=s database_psql_host_address=h bash "$T/job.sh" > "$T/out" 2> "$T/err" < /dev/null); then
    bad "stale toc.dat from an earlier build does not pass the check"
else
    ok "stale toc.dat from an earlier build does not pass the check"
fi
check "stale toc.dat: no database call" no_db_calls
check "stale toc.dat: fails on the toc.dat check (the old dump_files/ was cleared), not on mkdir" bash -c "grep -q 'no toc.dat' '$T/err' && ! grep -q 'File exists' '$T/err'"

# ================================================================ static checks
extract_restore_flags() { awk '/^pg_restore \\$/,/"dump_files\/"$/' "$1"; }
# The job was renamed after main: find main's path of this file through git's rename detection when main has no such path.
MAIN_REL="$JOB_REL"
if ! git -C "$HERE" cat-file -e "main:$JOB_REL" 2> /dev/null; then
    renamed_from=$(git -C "$HERE" diff -M --name-status main -- :/jenkins-docker/jobs 2> /dev/null | awk -F'\t' -v new="$JOB_REL" '$1 ~ /^R/ && $3 == new {print $2}')
    [ -z "$renamed_from" ] || MAIN_REL="$renamed_from"
fi
if git -C "$HERE" show "main:$MAIN_REL" > "$T/main.xml" 2> /dev/null && python3 -I "$HERE/extract-shell.py" "$T/main.xml" > "$T/main.sh" 2> /dev/null; then
    extract_restore_flags "$T/main.sh" > "$T/flags.main"
    extract_restore_flags "$T/job.sh" > "$T/flags.job"
    check "pg_restore flag list is not empty" test -s "$T/flags.main" -a "$(wc -l < "$T/flags.main" | tr -d ' ')" -ge 18
    check "pg_restore flag list is unchanged from main" cmp "$T/flags.main" "$T/flags.job"
    check "secret fetch lines are unchanged from main" bash -c "diff <(grep -E 'fetch_secret|extract_field' '$T/main.sh') <(grep -E 'fetch_secret|extract_field' '$T/job.sh')"
else
    echo "skip - main:$MAIN_REL not readable here (no git history), flag comparison skipped"
fi
check "Groovy Bash_Functions step is the first builder" python3 -I - "$JOB_XML" << 'PY'
import sys, xml.etree.ElementTree as E
b = E.parse(sys.argv[1]).getroot().find("builders")
kids = [c.tag for c in b]
assert kids == ["hudson.plugins.groovy.SystemGroovy", "hudson.tasks.Shell"], kids
PY
check "Groovy step builds the Bash_Functions job" grep -q 'getItemByFullName("Bash_Functions").scheduleBuild2' "$T/job.groovy"
check "job never mentions the real legacy bucket" test "$(grep -c 'avillach-73-bdcatalyst-etl' "$JOB_XML")" = 0
check "in-boundary bucket is one constant near the top of the shell" test "$(grep -c 'bdc-etl-data-d0d6191' "$T/job.sh")" = 1 -a "$(grep -n 'INBOUNDARY_DUMP_BUCKET=' "$T/job.sh" | head -1 | cut -d: -f1)" -le 6
check "XML is well formed" python3 -I -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$JOB_XML"
check "description: source, in-boundary URL, instance role, legacy rollback, IAM grant and the follow-up job" bash -c "
    d=\$(python3 -I -c 'import sys, xml.etree.ElementTree as E; print(E.parse(sys.argv[1]).getroot().findtext(\"description\"))' '$JOB_XML')
    for s in source_dictionary_db_s3_url 's3://bdc-etl-data-d0d6191/data/dictionary/db-dumps/dictionary_db_<ts>.tar' 'PIC-SURE Dictionary ETL Pipeline/dict-ingest' 'instance role' curated_datasets_s3_role rollback 's3:GetObject' 's3:ListBucket' 'bucket policy' 'PIC-SURE Dictionary Weights Build and Run'; do
        printf '%s' \"\$d\" | grep -qiF -- \"\$s\" || { echo \"description lacks: \$s\"; exit 1; }
    done"

if command -v shellcheck > /dev/null 2>&1; then
    check "shellcheck: job shell step is clean" shellcheck -s bash "$T/job.sh"
else
    echo "skip - shellcheck not installed"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
