#!/bin/bash
# shellcheck disable=SC2015  # "[ test ] && ok || bad" is the intended reporting idiom here
# Tests for the standalone staging job HPDS Data - Stage to Stack Bucket (HPDS_VARIANT both|auth|open, source URL and deploy key
# derived from build-spec.json) and for the staged check in Check For Updates (fails fast unless the data is staged).
# The job shell steps are extracted from the config.xml files and run against a fake `aws` (S3 = a directory tree)
# and a fake `docker` on PATH, in a throwaway git repo standing in for the release-control checkout.
# No real AWS, docker or Jenkins is touched. Only placeholder data.
#
# usage: bash jenkins-docker/tests/import-hpds.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
JOBS="$HERE/../jobs"
IMPORT_XML="$JOBS/HPDS Data - Stage to Stack Bucket/config.xml"
CFU_XML="$JOBS/Check For Updates/config.xml"

T="$(mktemp -d "${TMPDIR:-/tmp}/import-hpds-test.XXXXXX")"
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
# fake aws: bucket/key lives at $FAKE_S3/<bucket>/<key>; every call is logged.
# Streams: `s3 cp <s3 URL> -` writes the object to stdout, `s3 cp - <s3 URL>` stores stdin.
# $FAKE_AWS_IDENTITY_LOG gets one line per call with the identity it ran as. Like the real CLI, an explicit --profile wins over
# AWS_* keys in the environment while AWS_PROFILE does not: --profile hpds-source (with an AWS_CONFIG_FILE that holds role_arn and
# credential_source) is the source role, no --profile and no AWS_PROFILE/AWS_CONFIG_FILE is the instance role, anything else a leak.
# The --profile pair is dropped from the call log so the expected call lists stay identity-free.
profile=""
args=()
while [ $# -gt 0 ]; do
    if [ "$1" = --profile ] && [ $# -ge 2 ]; then profile="$2"; shift 2; continue; fi
    args+=("$1"); shift
done
set -- ${args[@]+"${args[@]}"}
echo "aws $*" >> "$FAKE_AWS_LOG"
if [ "$profile" = hpds-source ]; then
    if [ -f "${AWS_CONFIG_FILE:-}" ] && grep -q '^role_arn = ' "$AWS_CONFIG_FILE" && grep -q '^credential_source = Ec2InstanceMetadata$' "$AWS_CONFIG_FILE"; then
        echo "ident=source cfgpath=$AWS_CONFIG_FILE cfg=ok mode=$(ls -ld "$AWS_CONFIG_FILE" | cut -c1-10) role=$(sed -n 's/^role_arn = //p' "$AWS_CONFIG_FILE") session=$(sed -n 's/^role_session_name = //p' "$AWS_CONFIG_FILE") duration=$(sed -n 's/^duration_seconds = //p' "$AWS_CONFIG_FILE") aws $*" >> "$FAKE_AWS_IDENTITY_LOG"
    else
        echo "ident=source cfg=bad aws $*" >> "$FAKE_AWS_IDENTITY_LOG"
        echo "The config profile (hpds-source) could not be found" >&2
        exit 255
    fi
elif [ -n "${profile}${AWS_PROFILE:-}${AWS_CONFIG_FILE:-}" ]; then
    echo "ident=leak profile=${profile:-${AWS_PROFILE:-none}} cfg=${AWS_CONFIG_FILE:-none} aws $*" >> "$FAKE_AWS_IDENTITY_LOG"
else
    echo "ident=instance aws $*" >> "$FAKE_AWS_IDENTITY_LOG"
fi
bucket="" key="" prefix="" expected=""
pos=()
while [ $# -gt 0 ]; do
    case "$1" in
        --bucket) bucket="$2"; shift 2 ;;
        --key) key="$2"; shift 2 ;;
        --prefix) prefix="$2"; shift 2 ;;
        --expected-size) expected="$2"; shift 2 ;;
        --sse | --query | --output | --role-arn | --role-session-name | --duration-seconds | --region | --profile) shift 2 ;;
        --*) shift ;;
        *) pos+=("$1"); shift ;;
    esac
done
# a CLI that reads stdin (FAKE_AWS_EAT_STDIN=1) would swallow the rest of a while-read loop's input; a `-` source reads its pipe
[ -z "${FAKE_AWS_EAT_STDIN:-}" ] || [ "${pos[2]:-}" = "-" ] || cat > /dev/null
loc() { case "$1" in s3://*) echo "$FAKE_S3/${1#s3://}" ;; *) echo "$1" ;; esac; }
case "${pos[0]}/${pos[1]}" in
    s3/cp)
        from="${pos[2]}"
        to="${pos[3]}"
        src="$(loc "$from")"
        dst="$(loc "$to")"
        if [ "$from" != "-" ]; then
            [ -f "$src" ] || { echo "fake aws: missing source $from" >&2; exit 1; }
        fi
        if [ -n "${FAKE_FAIL_COPY:-}" ] && [[ "$to" == *"$FAKE_FAIL_COPY"* ]]; then
            echo "fake aws: injected copy failure for $to" >&2
            exit 1
        fi
        # a read that dies half way through the object: a few bytes, then a failure
        if [ -n "${FAKE_FAIL_READ:-}" ] && [ "$to" = "-" ] && [[ "$from" == *"$FAKE_FAIL_READ"* ]]; then
            head -c 3 "$src"
            echo "fake aws: injected read failure for $from" >&2
            exit 1
        fi
        if [ -n "${FAKE_NOOP_COPY:-}" ] && [[ "$to" == *"$FAKE_NOOP_COPY"* ]]; then
            [ "$from" != "-" ] || cat > /dev/null
            exit 0
        fi
        if [ "$to" = "-" ]; then cat "$src"; exit 0; fi
        if [ "$from" = "-" ]; then
            src="$(mktemp "${FAKE_AWS_LOG}.stream.XXXXXX")"
            cat > "$src"
            # FAKE_CONC_LOG: one line when a stream write starts and one when it ends (how many run at the same time)
            [ -z "${FAKE_CONC_LOG:-}" ] || echo start >> "$FAKE_CONC_LOG"
            # FAKE_SLOW_COPY: writes whose destination matches take FAKE_SLOW_SECS (default 0.3) s; FAKE_JITTER: every write takes a random 0 to 0.29 s.
            # Both make copies end in another order than they started in.
            if [ -n "${FAKE_SLOW_COPY:-}" ] && [[ "$to" == *"$FAKE_SLOW_COPY"* ]]; then sleep "${FAKE_SLOW_SECS:-0.3}"; fi
            [ -z "${FAKE_JITTER:-}" ] || sleep "0.$((RANDOM % 3))$((RANDOM % 10))"
            echo "stream to=$to bytes=$(wc -c < "$src" | tr -d ' ') expected=${expected:-none}" >> "$FAKE_AWS_IDENTITY_LOG"
        fi
        mkdir -p "$(dirname "$dst")"
        if [ -n "${FAKE_CORRUPT_COPY:-}" ] && [[ "$to" == *"$FAKE_CORRUPT_COPY"* ]]; then
            head -c 3 "$src" > "$dst"
        else
            cp "$src" "$dst"
        fi
        [ "$from" != "-" ] || rm -f "$src"
        [ -z "${FAKE_CONC_LOG:-}" ] || [ "$from" != "-" ] || echo end >> "$FAKE_CONC_LOG"
        ;;
    s3api/head-object)
        f="$FAKE_S3/$bucket/$key"
        [ -f "$f" ] || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254; }
        printf '{"ContentLength": %s, "ETag": "\\"fake\\""}\n' "$(wc -c < "$f" | tr -d ' ')"
        ;;
    s3api/list-objects-v2)
        [ -z "${FAKE_LIST_DENIED:-}" ] || { echo "An error occurred (AccessDenied) when calling the ListObjectsV2 operation" >&2; exit 255; }
        (cd "$FAKE_S3/$bucket" 2> /dev/null && find . -type f | sed 's|^\./||' | sort) | while IFS= read -r k; do
            case "$k" in "$prefix"*) printf '%s\n' "$k" ;; esac
        done | jq -R -s -c 'split("\n") | map(select(length > 0)) | if length == 0 then empty else {Contents: map({Key: .})} end'
        ;;
    sts/get-caller-identity)
        if [ -n "${FAKE_FAIL_SOURCE_IDENTITY:-}" ] && [ "$profile" = hpds-source ]; then
            echo "An error occurred (AccessDenied) when calling the AssumeRole operation: not authorized" >&2
            exit 255
        fi
        echo "arn:aws:sts::515157839325:assumed-role/curated-datasets-s3-role/session"
        ;;
    sts/assume-role)
        # the legacy path (Bash_Functions assume_role) only
        echo "AKIAFAKE FAKESECRET FAKETOKEN"
        ;;
    *)
        echo "fake aws: unsupported: ${pos[*]}" >&2
        exit 2
        ;;
esac
FAKE_AWS

cat > "$BIN/docker" << 'FAKE_DOCKER'
#!/bin/bash
echo "docker $*" >> "$FAKE_DOCKER_LOG"
case "$1" in
    load) cat > /dev/null; echo "Loaded image: fake-hpds-etl:1" ;;
    run) : ;;
esac
FAKE_DOCKER
# fake env: the job must never pass an AWS_ variable (a secret or the profile) through env, whose arguments are visible in ps
cat > "$BIN/env" << 'FAKE_ENV'
#!/bin/bash
for a in "$@"; do
    case "$a" in AWS_*) echo "env $*" >> "$FAKE_ENV_LOG"; echo "fake env: refusing $a" >&2; exit 99 ;; esac
done
exec /usr/bin/env "$@"
FAKE_ENV
chmod +x "$BIN/aws" "$BIN/docker" "$BIN/env"

export FAKE_S3="$T/s3"
export FAKE_AWS_LOG="$T/aws.log"
export FAKE_AWS_IDENTITY_LOG="$T/aws.identity.log"
export FAKE_ENV_LOG="$T/env.calls"
export FAKE_DOCKER_LOG="$T/docker.log"
export PATH="$BIN:$PATH"

SRC_BUCKET=bdc-etl-data-d0d6191
CURATED_ROLE=arn:aws:iam::515157839325:role/curated-datasets-s3-role
DATASET_ID=2026-11-04T0930Z
DATASET_URL="s3://$SRC_BUCKET/data/hpds/pheno/datasets/$DATASET_ID/"
DATASET_DIR="$FAKE_S3/$SRC_BUCKET/data/hpds/pheno/datasets/$DATASET_ID"
STACK=stack-bucket

sha() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
sha256_text() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }

# ---------------------------------------------------------------- extracted scripts
# description_of CONFIG_XML: the text of the <description> element only (XML parsed, never the whole file), white space collapsed
# so that a sentence wrapped over two lines is still one sentence
description_of() {
    python3 -I -c 'import sys, xml.etree.ElementTree as E; sys.stdout.write(" ".join((E.parse(sys.argv[1]).getroot().findtext("description") or "").split()))' "$1"
}
description_of "$IMPORT_XML" > "$T/import.desc" || { echo "cannot read the stage job description"; exit 1; }
description_of "$CFU_XML" > "$T/cfu.desc" || { echo "cannot read the Check For Updates description"; exit 1; }
[ -s "$T/import.desc" ] && [ -s "$T/cfu.desc" ] || { echo "empty job description"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$IMPORT_XML" > "$T/import.sh" || { echo "cannot extract import shell"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$CFU_XML" > "$T/cfu.sh" || { echo "cannot extract check-for-updates shell"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$CFU_XML" --groovy --index 0 > "$T/cfu.groovy.first" || { echo "cannot extract first groovy"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$CFU_XML" --groovy --index 1 > "$T/cfu.groovy" || { echo "cannot extract last groovy"; exit 1; }

# ---------------------------------------------------------------- fixtures
# make_dataset [same_sha] [open_meta] : dataset prefix with auth + open variants. same_sha -> open columnMeta sha == full sha.
# open_meta (any value) -> the open variant ships its own, different metadata.json (open/metadata.json).
make_dataset() {
    local d="$DATASET_DIR" same="${1:-}" open_meta="${2:-}" open_sha
    rm -rf "$d"
    mkdir -p "$d/static" "$d/open"
    printf 'AOS-DATA' > "$d/allObservationsStore.javabin"
    printf 'FULL-COLUMNMETA' > "$d/columnMeta.javabin"
    printf 'a,b\n' > "$d/columnMeta.csv"
    printf 'KEY0123' > "$d/encryption_key"
    printf '{"m":1}' > "$d/static/metadata.json"
    printf '{"m":2}' > "$d/open/metadata.json"
    printf '\\phs000000\\x\n' > "$d/static/conceptsToRemove.txt"
    printf 'OPEN-COLUMNMETA' > "$d/open/columnMeta.javabin"
    open_sha="$(sha "$d/open/columnMeta.javabin")"
    [ -z "$same" ] || open_sha="$(sha "$d/columnMeta.javabin")"
    entry() { # src dest [nosha]
        local s="$d/$1" shaj
        if [ "${3:-}" = nosha ]; then shaj=null; else shaj="\"$(sha "$s")\""; fi
        printf '{"src":"%s","dest":"%s","bytes":%s,"sha256":%s,"etag":"\\"etag-%s\\""}' "$1" "$2" "$(wc -c < "$s" | tr -d ' ')" "$shaj" "$2"
    }
    {
        printf '{"schema":"bdc-hpds-pheno-release/1","dataset_id":"%s","url":"%s",' "$DATASET_ID" "$DATASET_URL"
        printf '"removal":{"concepts_in_list":1,"full_columnmeta_sha256":"%s","open_columnmeta_sha256":"%s",' "$(sha "$d/columnMeta.javabin")" "$open_sha"
        printf '"full_columnmeta_content_sha256":"%s","open_columnmeta_content_sha256":"%s"},' "$(sha256_text FULL-CONTENT)" "$(sha256_text OPEN-CONTENT)"
        printf '"variants":{"auth":['
        entry allObservationsStore.javabin allObservationsStore.javabin nosha; printf ','
        entry columnMeta.javabin columnMeta.javabin; printf ','
        entry encryption_key encryption_key; printf ','
        entry static/metadata.json metadata.json
        printf '],"open":['
        entry allObservationsStore.javabin allObservationsStore.javabin nosha; printf ','
        entry open/columnMeta.javabin columnMeta.javabin; printf ','
        entry encryption_key encryption_key; printf ','
        if [ -n "$open_meta" ]; then entry open/metadata.json metadata.json; else entry static/metadata.json metadata.json; fi; printf ','
        entry static/conceptsToRemove.txt conceptsToRemove.txt
        printf ']}}\n'
    } > "$d/manifest.json"
    jq -e . "$d/manifest.json" > /dev/null || { echo "fixture manifest.json is not valid JSON"; exit 1; }
}

reset_world() {
    rm -rf "$FAKE_S3" "$FAKE_AWS_LOG" "$FAKE_AWS_LOG".* "$FAKE_AWS_IDENTITY_LOG" "$FAKE_ENV_LOG" "$FAKE_DOCKER_LOG" "$T/ws" "$T/jh" "$T/tmp"
    mkdir -p "$FAKE_S3" "$T/ws" "$T/tmp"
    : > "$FAKE_AWS_LOG"
    : > "$FAKE_AWS_IDENTITY_LOG"
    : > "$FAKE_DOCKER_LOG"
    unset ALLOW_OPEN_STIGVARS_NOT_REMOVED AWS_PROFILE AWS_CONFIG_FILE FAKE_FAIL_COPY FAKE_FAIL_READ FAKE_FAIL_SOURCE_IDENTITY FAKE_NOOP_COPY FAKE_CORRUPT_COPY FAKE_LIST_DENIED FAKE_AWS_EAT_STDIN FAKE_SLOW_COPY FAKE_SLOW_SECS FAKE_JITTER FAKE_CONC_LOG COPY_PARALLEL WS_SEED DEPLOY_TO_STAGING_STACK curated_datasets_s3_role IMPORT_BASH_OPTS
    # The Jenkins instance role: what every call that is not a source read must run as.
    export AWS_ACCESS_KEY_ID=AKIAINSTANCE AWS_SECRET_ACCESS_KEY=INSTANCESECRET AWS_SESSION_TOKEN=INSTANCETOKEN
}

# cfu_repo <auth url> <open url> : git repo (stands in for the release-control checkout) whose last commit adds
# build-spec.json; sets REPO, C1 (that commit), and STAGE (where C1's data lives in the fake stack bucket).
# Dates are fixed so the same fixture always gets the same commit hash.
cfu_repo() {
    REPO="$T/release-control"
    rm -rf "$REPO"
    mkdir -p "$REPO"
    (
        cd "$REPO" || exit 1
        export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
        git init -q .
        git config user.email t@example.invalid
        git config user.name test
        git config commit.gpgsign false
        echo readme > README.md
        git add README.md && git commit -q -m readme
        cat > build-spec.json << SPEC
{
  "source_dataset_s3_url": "$1",
  "source_destigmatized_dataset_s3_url": "$2",
  "source_genomic_dataset_s3_url": "s3://example-bucket/genomic/"
}
SPEC
        git add build-spec.json && git commit -q -m spec
    )
    C1="$(git -C "$REPO" rev-parse HEAD)"
    STAGE="$FAKE_S3/$STACK/data/$C1"
}

IMPORT_SCRIPT="$T/import.sh"

# run_import_in_repo <variant> : run the Import shell step in a copy of $REPO; exit code in $rc, stderr in $T/err
run_import_in_repo() {
    rm -rf "$T/ws"
    cp -R "$REPO" "$T/ws"
    [ -z "${WS_SEED:-}" ] || printf 'target_stack=stale\n' > "$T/ws/$WS_SEED"
    (
        cd "$T/ws" || exit 99
        HPDS_VARIANT="$1" stack_s3_bucket="$STACK" WORKSPACE="$T/ws" JENKINS_HOME="$T/jh" \
            TMPDIR="$T/tmp" JOB_NAME="${TEST_JOB_NAME:-HPDS Data - Stage to Stack Bucket}" BUILD_NUMBER="${TEST_BUILD_NUMBER:-42}" \
            bash ${IMPORT_BASH_OPTS:+"$IMPORT_BASH_OPTS"} "$IMPORT_SCRIPT" > "$T/out" 2> "$T/err" < /dev/null
    )
    rc=$?
}

# run_import <variant> <auth url> [open url, default: the auth url] : new fixture repo, then run_import_in_repo
run_import() {
    cfu_repo "$2" "${3:-$2}"
    run_import_in_repo "$1"
}

staged() { [ -e "$STAGE/$1" ]; }
stage_files() { (cd "$STAGE/$1" 2> /dev/null && find . -type f | sed 's|^\./||' | sort | tr '\n' ' '); }
AUTH_DIR=javabins_rekeyed
OPEN_DIR=destigmatized_javabins_rekeyed

# ================================================================ Import: dataset prefix, auth
reset_world
make_dataset
run_import auth "$DATASET_URL"
[ "$rc" = 0 ] && ok "auth staging exits 0" || { bad "auth staging exits 0 (rc=$rc)"; cat "$T/err"; }
[ "$(stage_files javabins_rekeyed)" = "allObservationsStore.javabin columnMeta.javabin encryption_key manifest.tsv metadata.json " ] \
    && ok "auth layout: exactly the auth files + manifest.tsv under javabins_rekeyed/" || bad "auth layout: $(stage_files javabins_rekeyed)"
check "auth columnMeta.javabin is the FULL index" grep -qx 'FULL-COLUMNMETA' "$STAGE/javabins_rekeyed/columnMeta.javabin"
check "fence_mapping.json is the static metadata.json" cmp "$STAGE/fence_mapping.json" "$DATASET_DIR/static/metadata.json"
M="$STAGE/javabins_rekeyed/manifest.tsv"
check "manifest.tsv magic line" test "$(sed -n 1p "$M")" = "# bdc-hpds-deploy/1"
check "manifest.tsv variant line" test "$(sed -n 2p "$M")" = "# variant=auth"
check "manifest.tsv dataset_id line" test "$(sed -n 3p "$M")" = "# dataset_id=$DATASET_ID"
check "manifest.tsv source line" test "$(sed -n 4p "$M")" = "# source=$DATASET_URL"
check "manifest.tsv manifest_sha256 line" test "$(sed -n 5p "$M")" = "# manifest_sha256=$(sha "$DATASET_DIR/manifest.json")"
check "manifest.tsv column header" test "$(sed -n 6p "$M")" = "$(printf 'dest\tbytes\tsha256\tetag\tsrc')"
check "manifest.tsv big file row has '-' sha256" grep -qx "$(printf 'allObservationsStore.javabin\t8\t-\t"etag-allObservationsStore.javabin"\tallObservationsStore.javabin')" "$M"
check "manifest.tsv metadata row maps static/ src" grep -qx "$(printf 'metadata.json\t7\t%s\t"etag-metadata.json"\tstatic/metadata.json' "$(sha "$DATASET_DIR/static/metadata.json")")" "$M"
check "manifest.tsv has 6 header lines + 4 rows" test "$(wc -l < "$M" | tr -d ' ')" = 10
last_cp="$(grep 'aws s3 cp' "$FAKE_AWS_LOG" | tail -1)"
check "manifest.tsv is the last object written" bash -c "echo '$last_cp' | grep -q 'javabins_rekeyed/manifest.tsv'"
check "copies into the stack bucket exist" test "$(grep -cE 'aws s3 cp [^ ]+ s3://' "$FAKE_AWS_LOG")" -ge 5
check "every copy into the stack bucket uses --sse AES256" test "$(grep -E 'aws s3 cp [^ ]+ s3://' "$FAKE_AWS_LOG" | grep -vc -- '--sse AES256')" = 0
check "per-file path never calls docker" test ! -s "$FAKE_DOCKER_LOG"
check "per-file path checks that the source role can be assumed once (sts get-caller-identity), and calls no sts assume-role" test "$(grep -c 'sts get-caller-identity' "$FAKE_AWS_LOG")" = 1 -a "$(grep -c 'sts assume-role' "$FAKE_AWS_LOG")" = 0

# ================================================================ Import: dataset prefix, open
reset_world
make_dataset
run_import open "$DATASET_URL"
[ "$rc" = 0 ] && ok "open staging exits 0" || { bad "open staging exits 0 (rc=$rc)"; cat "$T/err"; }
[ "$(stage_files destigmatized_javabins_rekeyed)" = "allObservationsStore.javabin columnMeta.javabin conceptsToRemove.txt encryption_key manifest.tsv metadata.json " ] \
    && ok "open layout: files + conceptsToRemove.txt + manifest.tsv under destigmatized_javabins_rekeyed/" || bad "open layout: $(stage_files destigmatized_javabins_rekeyed)"
check "open columnMeta.javabin is the OPEN index" grep -qx 'OPEN-COLUMNMETA' "$STAGE/destigmatized_javabins_rekeyed/columnMeta.javabin"
OM="$STAGE/destigmatized_javabins_rekeyed/manifest.tsv"
check "open manifest.tsv variant line" test "$(sed -n 2p "$OM")" = "# variant=open"
check "open manifest.tsv columnMeta row has src open/columnMeta.javabin" grep -q "columnMeta.javabin.*open/columnMeta.javabin\$" "$OM"
check "open staging leaves the auth prefix alone" test ! -e "$STAGE/javabins_rekeyed"
check "open staging writes no fence_mapping.json" test ! -e "$STAGE/fence_mapping.json"
check "open staging makes no copy to fence_mapping.json" test "$(grep -c 'fence_mapping.json' "$FAKE_AWS_LOG")" = 0

# the open variant ships a different metadata.json: with equal keys, auth then open leaves the auth fence mapping alone
reset_world
make_dataset "" differs
run_import both "$DATASET_URL"
[ "$rc" = 0 ] && ok "both with a different open metadata.json: exits 0" || { bad "both, open metadata differs (rc=$rc)"; cat "$T/err"; }
check "both, equal keys: the open prefix holds the open metadata.json" grep -qx '{"m":2}' "$STAGE/destigmatized_javabins_rekeyed/metadata.json"
check "both, equal keys: the auth prefix holds the auth metadata.json" grep -qx '{"m":1}' "$STAGE/javabins_rekeyed/metadata.json"
check "both, equal keys: fence_mapping.json is the auth content" grep -qx '{"m":1}' "$STAGE/fence_mapping.json"
check "both, equal keys: fence_mapping.json is written exactly once (by auth)" test "$(grep -c 's3://.*/fence_mapping.json' "$FAKE_AWS_LOG" | tr -d ' ')" = 1
run_import_in_repo both
check "both again: fence_mapping.json is still the auth content" grep -qx '{"m":1}' "$STAGE/fence_mapping.json"

# ================================================================ Import: both | auth | open
reset_world
make_dataset
run_import both "$DATASET_URL"
[ "$rc" = 0 ] && ok "both: exits 0" || { bad "both (rc=$rc)"; cat "$T/err"; }
[ "$(stage_files $AUTH_DIR)" = "allObservationsStore.javabin columnMeta.javabin encryption_key manifest.tsv metadata.json " ] \
    && ok "both: auth layout" || bad "both auth layout: $(stage_files $AUTH_DIR)"
[ "$(stage_files $OPEN_DIR)" = "allObservationsStore.javabin columnMeta.javabin conceptsToRemove.txt encryption_key manifest.tsv metadata.json " ] \
    && ok "both: open layout" || bad "both open layout: $(stage_files $OPEN_DIR)"
check "both: auth columnMeta is the FULL index, open columnMeta the OPEN index" bash -c "grep -qx FULL-COLUMNMETA '$STAGE/$AUTH_DIR/columnMeta.javabin' && grep -qx OPEN-COLUMNMETA '$STAGE/$OPEN_DIR/columnMeta.javabin'"
check "both: auth is staged before open (auth manifest.tsv write precedes the first open copy)" bash -c "
    a=\$(grep -n '/data/$C1/$AUTH_DIR/manifest.tsv' '$FAKE_AWS_LOG' | head -1 | cut -d: -f1)
    o=\$(grep -n '/data/$C1/$OPEN_DIR/' '$FAKE_AWS_LOG' | head -1 | cut -d: -f1)
    [ -n \"\$a\" ] && [ -n \"\$o\" ] && [ \"\$a\" -lt \"\$o\" ]"
check "both: summary line for auth" grep -qx "auth: staged (deploy key $C1)" "$T/out"
check "both: summary line for open" grep -qx "open: staged (deploy key $C1)" "$T/out"
check "both: the Next line is the last line" test "$(tail -1 "$T/out")" = "Next: run Check For Updates (or wait for the scheduled run) to deploy."
check "both: per-file path never calls docker" test ! -s "$FAKE_DOCKER_LOG"
check "both: the source role is checked once per staged variant (sts get-caller-identity), no sts assume-role" test "$(grep -c 'sts get-caller-identity' "$FAKE_AWS_LOG")" = 2 -a "$(grep -c 'sts assume-role' "$FAKE_AWS_LOG")" = 0

# source URL and deploy key come from build-spec.json: the copies read the URL of the spec, write under the blame commit
check "both: copies read from the build-spec dataset prefix" grep -q "aws s3 cp ${DATASET_URL}manifest.json " "$FAKE_AWS_LOG"
check "both: copies write under data/<blame commit>/" grep -q "s3://$STACK/data/$C1/$AUTH_DIR/columnMeta.javabin" "$FAKE_AWS_LOG"
check "both: the deploy key is the build-spec commit" test "$C1" = "$(git -C "$REPO" log -1 --format=%H -- build-spec.json)"

run_import_in_repo both
[ "$rc" = 0 ] && ok "both again: exits 0" || bad "both again (rc=$rc)"
check "both again: both variants report 'already staged, skipping'" test "$(grep -c 'already staged, skipping' "$T/out")" = 2
check "both again: summary says already staged for both" bash -c "grep -qx 'auth: already staged (deploy key $C1)' '$T/out' && grep -qx 'open: already staged (deploy key $C1)' '$T/out'"

reset_world
make_dataset
run_import auth "$DATASET_URL"
[ "$rc" = 0 ] && ok "auth only: exits 0" || bad "auth only (rc=$rc)"
check "auth only: open is not staged" test ! -e "$STAGE/$OPEN_DIR"
check "auth only: no summary line for open" test "$(grep -c '^open:' "$T/out")" = 0

reset_world
make_dataset
run_import open "$DATASET_URL"
[ "$rc" = 0 ] && ok "open only: exits 0" || bad "open only (rc=$rc)"
check "open only: auth is not staged" test ! -e "$STAGE/$AUTH_DIR"
check "open only: open is staged" test -f "$STAGE/$OPEN_DIR/manifest.tsv"

# mixed: auth already staged, open is not
reset_world
make_dataset
run_import auth "$DATASET_URL"
: > "$FAKE_AWS_LOG"
run_import_in_repo both
[ "$rc" = 0 ] && ok "both with auth already staged: exits 0" || bad "both, auth staged (rc=$rc)"
check "mixed: auth is skipped" grep -q '^auth: already staged, skipping' "$T/out"
check "mixed: open is staged" grep -qx "open: staged (deploy key $C1)" "$T/out"
check "mixed: nothing is copied into the staged auth prefix" test "$(grep -c "/data/$C1/$AUTH_DIR/" "$FAKE_AWS_LOG")" = 0

# mixed: open already staged, auth is not
reset_world
make_dataset
run_import open "$DATASET_URL"
: > "$FAKE_AWS_LOG"
run_import_in_repo both
check "mixed: open skipped, auth staged" bash -c "grep -q '^open: already staged, skipping' '$T/out' && grep -qx 'auth: staged (deploy key $C1)' '$T/out'"
check "mixed: nothing is copied into the staged open prefix" test "$(grep -c "/data/$C1/$OPEN_DIR/" "$FAKE_AWS_LOG")" = 0

# with both, a failed auth stops before open
reset_world
make_dataset
export FAKE_FAIL_COPY=encryption_key
run_import both "$DATASET_URL"
unset FAKE_FAIL_COPY
[ "$rc" != 0 ] && ok "both: failing auth ends the build non-zero" || bad "both, auth fails (rc=$rc)"
check "both: failing auth stops before open starts" test "$(grep -c "/data/$C1/$OPEN_DIR/" "$FAKE_AWS_LOG")" = 0
check "both: failing auth prints no Next line" test "$(grep -c '^Next:' "$T/out")" = 0
check "both: failing auth leaves no manifest.tsv" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv"

# a refusal in open comes after auth was staged: auth stays staged, build fails
reset_world
make_dataset same
run_import both "$DATASET_URL"
[ "$rc" != 0 ] && grep -q REFUSED "$T/err" && ok "both: open refusal ends the build non-zero" || bad "both, open refused (rc=$rc)"
check "both: auth was staged before the open refusal" test -f "$STAGE/$AUTH_DIR/manifest.tsv"
check "both: open refusal stages nothing for open" test ! -e "$STAGE/$OPEN_DIR"
check "both: open refusal prints no Next line" test "$(grep -c '^Next:' "$T/out")" = 0

# inputs derived from the release-control checkout
reset_world
make_dataset
cfu_repo "$DATASET_URL" "$DATASET_URL"
rm -rf "$T/ws"; mkdir -p "$T/ws"
(cd "$T/ws" && HPDS_VARIANT=auth stack_s3_bucket="$STACK" bash "$T/import.sh" > "$T/out" 2> "$T/err" < /dev/null)
rc=$?
[ "$rc" != 0 ] && grep -q 'build-spec.json not found' "$T/err" && ok "no build-spec.json in the workspace is refused" || bad "no build-spec (rc=$rc)"
check "no build-spec.json: no aws call" test ! -s "$FAKE_AWS_LOG"
cfu_repo "$DATASET_URL" "s3://$SRC_BUCKET/data/hpds/pheno/datasets/2026-11-05T0000Z/"
run_import_in_repo both
[ "$rc" != 0 ] && grep -q 'must be identical' "$T/err" && ok "stage job: differing dataset-prefix URLs are refused" || bad "stage job URL mismatch (rc=$rc)"
check "stage job: URL mismatch stages nothing and calls no aws" test ! -s "$FAKE_AWS_LOG"

# ================================================================ Import: refusals
reset_world
make_dataset same
run_import open "$DATASET_URL"
[ "$rc" != 0 ] && grep -q 'REFUSED' "$T/err" && ok "open refuses when full and open columnMeta shas are equal" || bad "open sha-equal refusal (rc=$rc)"
check "sha-equal refusal staged nothing" test ! -e "$STAGE/destigmatized_javabins_rekeyed"
run_import auth "$DATASET_URL"
[ "$rc" = 0 ] && ok "auth is unaffected by equal shas" || bad "auth with equal shas (rc=$rc)"

# content shas: the stored files differ (RemoveConceptFromMetadata always re-gzips) but the gunzipped content is the same
reset_world
make_dataset
jq '.removal.open_columnmeta_content_sha256 = .removal.full_columnmeta_content_sha256' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import open "$DATASET_URL"
[ "$rc" != 0 ] && grep -q 'REFUSED' "$T/err" && ok "open refuses when the gunzipped content shas are equal" || bad "open content-sha-equal refusal (rc=$rc)"
check "content-sha-equal refusal staged nothing" test ! -e "$STAGE/destigmatized_javabins_rekeyed"
run_import auth "$DATASET_URL"
[ "$rc" = 0 ] && ok "auth is unaffected by equal content shas" || bad "auth with equal content shas (rc=$rc)"

reset_world
make_dataset
jq 'del(.removal.full_columnmeta_content_sha256, .removal.open_columnmeta_content_sha256)' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import open "$DATASET_URL"
[ "$rc" = 0 ] && ok "open without content shas in the manifest still stages (stored-file shas are checked)" || bad "open without content shas (rc=$rc)"

reset_world
make_dataset
jq 'del(.removal.full_columnmeta_content_sha256)' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import open "$DATASET_URL"
[ "$rc" = 0 ] && ok "open with only one content sha present stages" || bad "open with one content sha (rc=$rc)"

# an already staged variant is skipped, never overwritten (per-file: manifest.tsv, legacy: the tar)
reset_world
make_dataset
cfu_repo "$DATASET_URL" "$DATASET_URL"
mkdir -p "$STAGE/javabins_rekeyed"
printf 'old\n' > "$STAGE/javabins_rekeyed/manifest.tsv"
printf 'old-fence' > "$STAGE/fence_mapping.json"
run_import_in_repo auth
[ "$rc" = 0 ] && grep -q 'already staged, skipping' "$T/out" && ok "auth with an existing manifest.tsv is skipped (exit 0)" || bad "existing manifest.tsv skip (rc=$rc)"
check "skipped stage prefix is untouched" test "$(stage_files javabins_rekeyed)" = "manifest.tsv " -a "$(cat "$STAGE/javabins_rekeyed/manifest.tsv")" = old
check "skip happens before any copy" test "$(grep -c 'aws s3 cp' "$FAKE_AWS_LOG")" = 0
check "skip prints the summary line with the deploy key" grep -qx "auth: already staged (deploy key $C1)" "$T/out"
check "skip still ends with the Next line" grep -qx 'Next: run Check For Updates (or wait for the scheduled run) to deploy.' "$T/out"

reset_world
make_dataset
cfu_repo "$DATASET_URL" "$DATASET_URL"
mkdir -p "$STAGE"
printf 'old-tar' > "$STAGE/javabins_rekeyed.tar"
printf 'old-fence' > "$STAGE/fence_mapping.json"
run_import_in_repo auth
[ "$rc" = 0 ] && grep -q 'already staged, skipping' "$T/out" && ok "auth with an existing legacy tar is skipped" || bad "existing tar skip (rc=$rc)"
check "legacy tar skip leaves the tar and the fence mapping alone and stages nothing else" test "$(find "$STAGE" -type f | wc -l | tr -d ' ')" = 2 -a "$(cat "$STAGE/javabins_rekeyed.tar")" = old-tar -a "$(cat "$STAGE/fence_mapping.json")" = old-fence
check "legacy tar skip makes no copy" test "$(grep -c 'aws s3 cp' "$FAKE_AWS_LOG")" = 0

reset_world
make_dataset
cfu_repo "$DATASET_URL" "$DATASET_URL"
mkdir -p "$STAGE/javabins_rekeyed"
printf 'partial\n' > "$STAGE/javabins_rekeyed/columnMeta.javabin"
run_import_in_repo auth
[ "$rc" = 0 ] && staged javabins_rekeyed/manifest.tsv && ok "a partial stage (no manifest.tsv) is not 'staged': the variant is staged now" || bad "partial stage restage (rc=$rc)"

# ---- an already staged auth variant without fence_mapping.json: restored from the staged metadata.json (per-file) or refused (tar)
reset_world
make_dataset
run_import auth "$DATASET_URL"
rm -f "${STAGE:?}/fence_mapping.json"
: > "$FAKE_AWS_LOG"
run_import_in_repo auth
[ "$rc" = 0 ] && ok "repair: auth already staged per-file without fence_mapping.json exits 0" || { bad "repair (rc=$rc)"; cat "$T/err"; }
check "repair: prints that fence_mapping.json was restored from the staged metadata.json" grep -qx 'fence_mapping.json restored from the staged metadata.json' "$T/out"
check "repair: fence_mapping.json is the staged metadata.json" cmp "$STAGE/fence_mapping.json" "$STAGE/javabins_rekeyed/metadata.json"
check "repair: the copy is server-side from the staged metadata.json, with --sse AES256" grep -qx "aws s3 cp s3://$STACK/data/$C1/javabins_rekeyed/metadata.json s3://$STACK/data/$C1/fence_mapping.json --sse AES256 --only-show-errors" "$FAKE_AWS_LOG"
check "repair: that is the only copy (nothing re-staged, source bucket untouched)" test "$(grep -c 'aws s3 cp' "$FAKE_AWS_LOG")" = 1
check "repair: no docker, no role" bash -c "test ! -s '$FAKE_DOCKER_LOG' && test \$(grep -c assume-role '$FAKE_AWS_LOG') = 0"
check "repair: the staged auth prefix is untouched" test "$(stage_files javabins_rekeyed)" = "allObservationsStore.javabin columnMeta.javabin encryption_key manifest.tsv metadata.json "
check "repair: existence is verified after the copy (a fence_mapping.json probe follows the copy)" bash -c "
    c=\$(grep -n 'aws s3 cp' '$FAKE_AWS_LOG' | cut -d: -f1)
    [ \$(tail -n +\$((c + 1)) '$FAKE_AWS_LOG' | grep -c 'data/$C1/fence_mapping.json') -ge 1 ]"
printf 'edited' > "$STAGE/fence_mapping.json"
: > "$FAKE_AWS_LOG"
run_import_in_repo auth
[ "$rc" = 0 ] && ok "no repair: auth staged with fence_mapping.json exits 0" || bad "no repair (rc=$rc)"
check "no repair: an existing fence_mapping.json is left alone" test "$(cat "$STAGE/fence_mapping.json")" = edited
check "no repair: no restore message and no copy" bash -c "! grep -q 'restored' '$T/out' && test \$(grep -c 'aws s3 cp' '$FAKE_AWS_LOG') = 0"

# HPDS_VARIANT=open does not look at the fence mapping (flag off)
reset_world
make_dataset
run_import both "$DATASET_URL"
rm -f "${STAGE:?}/fence_mapping.json"
: > "$FAKE_AWS_LOG"
run_import_in_repo open
[ "$rc" = 0 ] && ok "HPDS_VARIANT=open with a missing fence_mapping.json exits 0 (flag off)" || bad "open, fence missing (rc=$rc)"
check "HPDS_VARIANT=open: no restore, no probe of fence_mapping.json" bash -c "test ! -e '$STAGE/fence_mapping.json' && test \$(grep -c 'fence_mapping.json' '$FAKE_AWS_LOG') = 0"

# the restore copy fails, or does not leave the object behind
reset_world
make_dataset
run_import auth "$DATASET_URL"
rm -f "${STAGE:?}/fence_mapping.json"
export FAKE_FAIL_COPY=fence_mapping.json
run_import_in_repo auth
unset FAKE_FAIL_COPY
[ "$rc" != 0 ] && grep -q "cannot restore data/$C1/fence_mapping.json" "$T/err" && ok "repair: a failing copy fails the build" || bad "repair, copy fails (rc=$rc)"
check "repair: a failing copy prints no restored message and leaves no file" bash -c "! grep -q restored '$T/out' && test ! -e '$STAGE/fence_mapping.json'"
export FAKE_NOOP_COPY=fence_mapping.json
run_import_in_repo auth
unset FAKE_NOOP_COPY
[ "$rc" != 0 ] && grep -q 'is still missing after the restore' "$T/err" && ok "repair: a copy that leaves no object is detected" || bad "repair, copy without object (rc=$rc)"
check "repair: no restored message when the object is not there" test "$(grep -c restored "$T/out")" = 0
rm -f "${STAGE:?}/javabins_rekeyed/metadata.json"
run_import_in_repo auth
[ "$rc" != 0 ] && grep -q 'cannot restore' "$T/err" && ok "repair: a staged prefix without metadata.json cannot be repaired (refused)" || bad "repair, metadata.json gone (rc=$rc)"

# auth staged as a legacy tar without fence_mapping.json: refused, nothing else happens (also not for open)
reset_world
make_dataset
cfu_repo "$DATASET_URL" "$DATASET_URL"
mkdir -p "$STAGE"
printf 'old-tar' > "$STAGE/javabins_rekeyed.tar"
run_import_in_repo both
[ "$rc" != 0 ] && grep -q "staged as a legacy tar and data/$C1/fence_mapping.json is missing; it cannot be restored in place: restage under a new deploy key" "$T/err" && ok "repair: auth staged as a tar without fence_mapping.json is refused with the restage hint" || { bad "tar without fence (rc=$rc)"; cat "$T/err"; }
check "tar without fence: nothing is copied, open is not staged, no fence_mapping.json appears" bash -c "test \$(grep -c 'aws s3 cp' '$FAKE_AWS_LOG') = 0 && test ! -e '$STAGE/fence_mapping.json' && test ! -e '$STAGE/$OPEN_DIR'"
run_import_in_repo open
[ "$rc" = 0 ] && ok "HPDS_VARIANT=open next to an auth tar without fence_mapping.json is not affected (flag off)" || bad "open next to a tar (rc=$rc)"

reset_world
make_dataset
run_import neither "$DATASET_URL"
[ "$rc" != 0 ] && grep -q "unknown HPDS_VARIANT" "$T/err" && ok "unknown HPDS_VARIANT is refused" || bad "unknown variant refusal (rc=$rc)"
check "unknown variant makes no aws call" test ! -s "$FAKE_AWS_LOG"
run_import "" "$DATASET_URL"
[ "$rc" != 0 ] && ok "empty HPDS_VARIANT is refused" || bad "empty variant refusal"

reset_world
make_dataset
rm "$DATASET_DIR/manifest.json"
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && ok "prefix without manifest.json is refused" || bad "no manifest.json refusal"
check "no manifest.json: nothing staged" test ! -e "$STAGE/javabins_rekeyed"

reset_world
make_dataset
jq 'del(.variants.open)' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import open "$DATASET_URL"
[ "$rc" != 0 ] && ok "variant missing from the manifest is refused" || bad "missing variant refusal"

reset_world
make_dataset
jq '.variants.auth[1].dest = "../evil"' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && ok "path traversal in dest is refused" || bad "path traversal refusal"
check "traversal refusal staged nothing" test ! -e "$STAGE/javabins_rekeyed"

reset_world
make_dataset
jq '.schema = "other/9"' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && ok "unknown manifest schema is refused" || bad "schema refusal"

reset_world
make_dataset
jq '.variants.open[1].src = "columnMeta.javabin"' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import open "$DATASET_URL"
[ "$rc" != 0 ] && ok "open entry pointing at the full columnMeta.javabin is refused" || bad "open full-columnMeta refusal"

# ================================================================ Import: retry and byte checks
reset_world
make_dataset
export FAKE_FAIL_COPY=encryption_key
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && ok "partial stage: failing copy fails the job" || bad "partial stage rc"
check "partial stage: no manifest.tsv" test ! -e "$STAGE/javabins_rekeyed/manifest.tsv"
check "partial stage: earlier files are there" test -f "$STAGE/javabins_rekeyed/allObservationsStore.javabin"
unset FAKE_FAIL_COPY
run_import auth "$DATASET_URL"
[ "$rc" = 0 ] && ok "retry over a partial stage succeeds" || { bad "retry over partial stage (rc=$rc)"; cat "$T/err"; }
[ "$(stage_files javabins_rekeyed)" = "allObservationsStore.javabin columnMeta.javabin encryption_key manifest.tsv metadata.json " ] \
    && ok "retry completes the layout" || bad "retry layout: $(stage_files javabins_rekeyed)"
copies_before_third="$(grep -c 'aws s3 cp' "$FAKE_AWS_LOG")"
run_import auth "$DATASET_URL"
[ "$rc" = 0 ] && grep -q 'already staged, skipping' "$T/out" && ok "after the retry the prefix is immutable (third run skips it)" || bad "third run skip (rc=$rc)"
check "third run copied nothing" test "$(grep -c 'aws s3 cp' "$FAKE_AWS_LOG")" = "$copies_before_third"

# a CLI that reads stdin must not shorten the stage
for v in auth open; do
    reset_world
    make_dataset
    export FAKE_AWS_EAT_STDIN=1
    run_import "$v" "$DATASET_URL"
    [ "$rc" = 0 ] && ok "$v: aws that consumes stdin does not end the loop (rc 0)" || { bad "$v: stdin-eating aws (rc=$rc)"; cat "$T/err"; }
    sd="$([ "$v" = auth ] && echo javabins_rekeyed || echo destigmatized_javabins_rekeyed)"
    rows="$(tail -n +7 "$STAGE/$sd/manifest.tsv" 2> /dev/null | wc -l | tr -d ' ')"
    want="$(jq ".variants.$v | length" "$DATASET_DIR/manifest.json")"
    [ "$rows" = "$want" ] && ok "$v: manifest.tsv lists all $want entries" || bad "$v: manifest.tsv rows $rows, want $want"
    unset FAKE_AWS_EAT_STDIN
done

# guard: if the loop were cut short anyway, manifest.tsv must not be uploaded. Simulated by removing the </dev/null redirects.
reset_world
make_dataset
sed 's|< /dev/null||g' "$T/import.sh" > "$T/import-noredirect.sh"
check "guard test: redirects were really removed" test "$(grep -c '< /dev/null' "$T/import-noredirect.sh")" = 0
export FAKE_AWS_EAT_STDIN=1 COPY_PARALLEL=1
IMPORT_SCRIPT="$T/import-noredirect.sh"
run_import auth "$DATASET_URL"
IMPORT_SCRIPT="$T/import.sh"
unset FAKE_AWS_EAT_STDIN COPY_PARALLEL
[ "$rc" != 0 ] && grep -q 'data rows' "$T/err" && ok "short manifest.tsv is refused before upload" || bad "short manifest.tsv guard (rc=$rc)"
check "short manifest.tsv was not uploaded" test ! -e "$STAGE/javabins_rekeyed/manifest.tsv"

reset_world
make_dataset
export FAKE_CORRUPT_COPY=columnMeta.javabin
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && grep -q 'manifest says' "$T/err" && ok "byte-count mismatch after copy fails the job" || bad "byte mismatch (rc=$rc)"
check "byte mismatch: no manifest.tsv" test ! -e "$STAGE/javabins_rekeyed/manifest.tsv"
unset FAKE_CORRUPT_COPY

# ================================================================ Import: dataset prefix, source read through the source role profile
# The source bucket is in another account: its objects are read as curated-datasets-s3-role through an AWS CLI profile (hpds-source,
# in a private temporary config file, the CLI assumes the role itself) and streamed into the stack bucket, which is written as the
# instance role. The fake aws logs the identity of every call in $FAKE_AWS_IDENTITY_LOG: AWS_PROFILE=hpds-source with a config file
# holding role_arn and credential_source is "source", no AWS_PROFILE and no AWS_CONFIG_FILE is "instance", anything else is a leak.
SRC_ID="ident=source"
INST_ID="ident=instance"
idlog() { grep -E "$1" "$FAKE_AWS_IDENTITY_LOG"; }
# count_with / count_without <pattern> <identity>: lines of the identity log matching the pattern that do / do not start with the identity
count_with() { idlog "$1" | grep -c "^$2 " || true; }
count_without() { idlog "$1" | grep -vc "^$2 " || true; }
SRC_READ=' aws s3 cp s3://'
DEST_WRITE=' aws s3 cp (-|dataset_work/manifest.tsv) s3://'
SECRET_WORDS='INSTANCESECRET|INSTANCETOKEN'
# every "stream" line of the identity log: the bytes received equal --expected-size, and --expected-size is there
streams_consistent() {
    awk '/^stream / {
        n++
        if ($4 !~ /^expected=[0-9]+$/) bad++
        else { split($3, a, "="); split($4, b, "="); if (a[2] != b[2]) bad++ }
    } END { exit (n == 0 || bad > 0) }' "$FAKE_AWS_IDENTITY_LOG"
}
tmp_is_empty() { [ -z "$(ls -A "$T/tmp")" ]; }

reset_world
make_dataset
run_import both "$DATASET_URL"
[ "$rc" = 0 ] && ok "source role: both variants stage (rc 0)" || { bad "source role, both (rc=$rc)"; cat "$T/err"; }
n_src_reads="$(idlog "$SRC_READ" | wc -l | tr -d ' ')"
check "source role: the source reads exist (2 manifest.json + 10 files)" test "$n_src_reads" = 12
check "source role: every read of the source bucket ran as the source profile" test "$(count_with "$SRC_READ" "$SRC_ID")" = "$n_src_reads"
check "source role: no source read ran as the instance role" test "$(count_without "$SRC_READ" "$SRC_ID")" = 0
check "source role: the source profile was used for source reads and the access check only (12 reads + 2 checks)" test "$(grep -c "^$SRC_ID " "$FAKE_AWS_IDENTITY_LOG")" = 14
check "source role: the access check is sts get-caller-identity as the source profile, once per variant, and it is the first source call" bash -c "test \$(grep -c '^$SRC_ID .* aws sts get-caller-identity' '$FAKE_AWS_IDENTITY_LOG') = 2 && grep '^$SRC_ID ' '$FAKE_AWS_IDENTITY_LOG' | head -1 | grep -q ' aws sts get-caller-identity'"
check "source role: every write to the stack bucket ran as the instance role" test "$(count_with "$DEST_WRITE" "$INST_ID")" = 12 -a "$(count_without "$DEST_WRITE" "$INST_ID")" = 0
check "source role: every stack bucket list and head ran as the instance role" test "$(idlog ' aws s3api ' | wc -l | tr -d ' ')" -gt 12 -a "$(count_without ' aws s3api ' "$INST_ID")" = 0
check "source role: no call leaked AWS_PROFILE or AWS_CONFIG_FILE into a command that is not a source read (no 'leak' identity)" test "$(grep -c '^ident=leak' "$FAKE_AWS_IDENTITY_LOG")" = 0
check "source role: no stream was written anywhere but the stack bucket" test "$(idlog ' aws s3 cp - ' | grep -vc " aws s3 cp - s3://$STACK/data/$C1/")" = 0
check "source role: the profile file was seen by the CLI with role_arn + credential_source, mode 600, the curated-datasets role, 3600 s and a session named after job and build" test "$(idlog "^$SRC_ID " | grep -vcF "cfg=ok mode=-rw------- role=$CURATED_ROLE session=HPDS-Data---Stage-to-Stack-Bucket-42 duration=3600 ")" = 0
check "source role: the session name is a valid role session name" bash -c "grep -o 'session=[^ ]*' '$FAKE_AWS_IDENTITY_LOG' | sort -u | cut -d = -f 2 | grep -qE '^[A-Za-z0-9+=,.@_-]{2,64}\$'"
check "source role: no role is assumed by the job itself (no sts assume-role call)" test "$(grep -c 'sts assume-role' "$FAKE_AWS_LOG")" = 0
check "source role: the temporary profile file is gone after a successful run" tmp_is_empty
check "source role: the temporary profile file was made under TMPDIR" bash -c "grep -q '^ident=source cfgpath=' '$FAKE_AWS_IDENTITY_LOG' && ! grep '^ident=source cfgpath=' '$FAKE_AWS_IDENTITY_LOG' | grep -v -q '^ident=source cfgpath=$T/tmp/'"

# bytes: every staged file is the source file, the stream got the manifest bytes as --expected-size
bytes_ok=true
for v in auth open; do
    sd="$([ "$v" = auth ] && echo $AUTH_DIR || echo $OPEN_DIR)"
    while IFS=$'\t' read -r s d b; do
        cmp -s "$DATASET_DIR/$s" "$STAGE/$sd/$d" || { bytes_ok=false; echo "content differs: $v $d" >&2; }
        grep -qxF "stream to=s3://$STACK/data/$C1/$sd/$d bytes=$b expected=$b" "$FAKE_AWS_IDENTITY_LOG" || { bytes_ok=false; echo "no stream of $b bytes to $v $d" >&2; }
        grep -qE "^${d}"$'\t'"${b}"$'\t' "$STAGE/$sd/manifest.tsv" || { bytes_ok=false; echo "manifest.tsv row: $v $d" >&2; }
    done < <(jq -r --arg v "$v" '.variants[$v][] | [.src, .dest, (.bytes | tostring)] | @tsv' "$DATASET_DIR/manifest.json")
done
check "source role: every staged file of both variants is byte-identical to its source, was streamed with --expected-size = manifest bytes, and has its manifest.tsv row" $bytes_ok
check "source role: fence_mapping.json was streamed (a second read of the auth metadata.json) with the metadata.json bytes as --expected-size" grep -qxF "stream to=s3://$STACK/data/$C1/fence_mapping.json bytes=7 expected=7" "$FAKE_AWS_IDENTITY_LOG"
check "source role: every stream got exactly --expected-size bytes and none lacks it" streams_consistent
check "source role: the byte check (head-object on the destination) still runs for every file and for fence_mapping.json" test "$(grep -c 's3api head-object' "$FAKE_AWS_LOG")" = 10
check "source role: manifest.tsv is still the last object written" bash -c "grep -E 'aws s3 cp (-|dataset_work/manifest.tsv) s3://' '$FAKE_AWS_LOG' | tail -1 | grep -q '/$OPEN_DIR/manifest.tsv'"
check "source role: no secret in stdout or stderr" test "$(cat "$T/out" "$T/err" | grep -cE "$SECRET_WORDS")" = 0

# no credential and no profile name ever travels through env (its arguments are visible in ps)
check "source role: the job never calls env with an AWS_ argument (static)" test "$(grep -cE '(^|[^A-Za-z_])env +([^ ]+ +)*AWS_' "$T/import.sh")" = 0
check "source role: a fake env on PATH was never given an AWS_ argument" test ! -e "$FAKE_ENV_LOG"
check "source role: nothing exports credentials or the profile (no export / declare -x of AWS_ variables)" test "$(grep -cE 'export +AWS_|declare -x +AWS_' "$T/import.sh")" = 0
check "source role: AWS_CONFIG_FILE is a prefix assignment of the one aws --profile hpds-source command in src_aws, nowhere else" bash -c "test \$(grep -cE 'AWS_CONFIG_FILE' '$T/import.sh') = 1 && grep -qF 'AWS_CONFIG_FILE=\"\${src_cfg}\" aws --profile hpds-source \"\$@\"' '$T/import.sh'"
check "source role: the job never sets AWS_PROFILE (the CLI would let AWS_* keys in the environment win over it)" test "$(grep -c 'AWS_PROFILE' "$T/import.sh")" = 0
check "source role: the job holds no credential variables (no AccessKeyId, SecretAccessKey or SessionToken in the shell step)" test "$(grep -cE 'AccessKeyId|SecretAccessKey|SessionToken' "$T/import.sh")" = 0
check "source role: the dataset path does not source Bash_Functions" test "$(grep -c 'sourcing' "$T/out")" = 0 -a ! -d "$T/jh"

# a long job name gives a 64-character session name that keeps the build number
reset_world
make_dataset
cfu_repo "$DATASET_URL" "$DATASET_URL"
TEST_JOB_NAME="$(printf 'J%.0s' $(seq 1 90))" TEST_BUILD_NUMBER=7 run_import_in_repo auth
check "source role: a 90-character job name still gives a valid 64-character session name ending with the build number" bash -c "n=\$(grep -o 'session=[^ ]*' '$FAKE_AWS_IDENTITY_LOG' | head -1 | cut -d = -f 2); [ \${#n} -eq 64 ] && [ \"\${n: -2}\" = -7 ] && printf '%s' \"\$n\" | grep -qE '^[A-Za-z0-9+=,.@_-]{2,64}\$'"

# with tracing on, nothing secret is printed and the identities stay apart
reset_world
make_dataset
export IMPORT_BASH_OPTS=-x
run_import auth "$DATASET_URL"
unset IMPORT_BASH_OPTS
[ "$rc" = 0 ] && ok "source role: bash -x run stages (rc 0)" || { bad "source role bash -x (rc=$rc)"; tail -5 "$T/err"; }
check "source role: bash -x really traced (the trace is in stderr)" test "$(grep -c '^+' "$T/err")" -gt 20
check "source role: bash -x output holds no secret" test "$(cat "$T/out" "$T/err" | grep -cE "$SECRET_WORDS")" = 0
check "source role: bash -x run keeps the identities apart" test "$(count_without "$SRC_READ" "$SRC_ID")" = 0 -a "$(count_without "$DEST_WRITE" "$INST_ID")" = 0 -a "$(grep -c '^ident=leak' "$FAKE_AWS_IDENTITY_LOG")" = 0

# the role is fixed: a global curated_datasets_s3_role (on the deploy Jenkins it can name another account's role) is ignored
reset_world
make_dataset
export curated_datasets_s3_role=arn:aws:iam::736265540791:role/curated-datasets-s3-role
run_import auth "$DATASET_URL"
unset curated_datasets_s3_role
[ "$rc" = 0 ] && ok "source role: a curated_datasets_s3_role in the environment does not break the run (rc 0)" || bad "role in env (rc=$rc)"
check "source role: every source call still uses the 515157839325 role, never the environment's" test "$(idlog "^$SRC_ID " | grep -cF "role=$CURATED_ROLE ")" = 7 -a "$(grep -c '736265540791' "$FAKE_AWS_IDENTITY_LOG")" = 0

# the source role cannot be assumed: refused with the role (no secrets) before anything is written
reset_world
make_dataset
export FAKE_FAIL_SOURCE_IDENTITY=1
run_import both "$DATASET_URL"
unset FAKE_FAIL_SOURCE_IDENTITY
[ "$rc" != 0 ] && ok "a source role that cannot be assumed ends the build non-zero" || bad "source identity failure rc"
check "source role refusal: REFUSED names the role and the source" grep -q "REFUSED: cannot assume $CURATED_ROLE to read $DATASET_URL" "$T/err"
check "source role refusal: nothing was written (no copy, no manifest.tsv, nothing in the stack bucket)" bash -c "test \$(grep -c 'aws s3 cp' '$FAKE_AWS_LOG') = 0 && test -z \"\$(find '$FAKE_S3/$STACK' -type f 2> /dev/null)\""
check "source role refusal: no source read was attempted, no head-object either" test "$(grep -cE 'aws s3 cp|head-object' "$FAKE_AWS_LOG")" = 0
check "source role refusal: the access check ran once, then the build stopped (auth failed, open not started)" test "$(grep -c 'sts get-caller-identity' "$FAKE_AWS_LOG")" = 1 -a "$(grep -c 'open: staging' "$T/out")" = 0
check "source role refusal: the temporary profile file is gone" tmp_is_empty
check "source role refusal: no secret in stdout or stderr" test "$(cat "$T/out" "$T/err" | grep -cE "$SECRET_WORDS")" = 0

# a source read that dies in the middle of the stream: the destination side of the pipe still ends cleanly, the build must fail anyway
reset_world
make_dataset
export FAKE_FAIL_READ=columnMeta.javabin COPY_PARALLEL=1
run_import both "$DATASET_URL"
unset FAKE_FAIL_READ COPY_PARALLEL
[ "$rc" != 0 ] && ok "a source read failing mid-stream ends the build non-zero" || bad "mid-stream read failure rc"
check "mid-stream read failure: the copy is reported as failed (pipefail, not only the later byte check)" grep -q "REFUSED: copy of s3://$SRC_BUCKET/data/hpds/pheno/datasets/$DATASET_ID/columnMeta.javabin to s3://$STACK/data/$C1/$AUTH_DIR/columnMeta.javabin failed" "$T/err"
check "mid-stream read failure: no manifest.tsv, and later files are not copied" bash -c "test ! -e '$STAGE/$AUTH_DIR/manifest.tsv' && test ! -e '$STAGE/$AUTH_DIR/encryption_key' && test ! -e '$STAGE/fence_mapping.json'"
check "mid-stream read failure: open is not started" test ! -e "$STAGE/$OPEN_DIR"
check "mid-stream read failure: the source error text is shown" grep -q 'injected read failure' "$T/err"
check "mid-stream read failure: the temporary profile file is gone" tmp_is_empty

# the fence_mapping.json read fails
reset_world
make_dataset
export FAKE_FAIL_READ=static/metadata.json
run_import auth "$DATASET_URL"
unset FAKE_FAIL_READ
[ "$rc" != 0 ] && ok "a failing read of metadata.json (also the fence mapping source) fails the build" || bad "metadata.json read failure rc"
check "metadata.json read failure: no manifest.tsv" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv"

# a destination write that fails
reset_world
make_dataset
export FAKE_FAIL_COPY=columnMeta.javabin
run_import both "$DATASET_URL"
unset FAKE_FAIL_COPY
[ "$rc" != 0 ] && ok "a destination write failing ends the build non-zero" || bad "destination write failure rc"
check "destination write failure: reported as a failed copy" grep -q "REFUSED: copy of .*columnMeta.javabin to s3://$STACK/data/$C1/$AUTH_DIR/columnMeta.javabin failed" "$T/err"
check "destination write failure: no manifest.tsv, open not started" bash -c "test ! -e '$STAGE/$AUTH_DIR/manifest.tsv' && test ! -e '$STAGE/$OPEN_DIR'"
check "destination write failure: the temporary profile file is gone" tmp_is_empty
reset_world
make_dataset
export FAKE_FAIL_COPY=fence_mapping.json
run_import auth "$DATASET_URL"
unset FAKE_FAIL_COPY
[ "$rc" != 0 ] && ok "a failing write of fence_mapping.json ends the build non-zero" || bad "fence write failure rc"
check "fence write failure: no manifest.tsv" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv"

# a source that is not readable (the object is missing): refused, nothing past it
reset_world
make_dataset
rm "$DATASET_DIR/encryption_key"
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && ok "a source file that cannot be read fails the build" || bad "missing source file rc"
check "missing source file: no manifest.tsv" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv"

# the fence mapping repair is stack-bucket only and runs as the instance role, also after the source role was used in the same build
reset_world
make_dataset
run_import auth "$DATASET_URL"
rm -f "${STAGE:?}/fence_mapping.json"
: > "$FAKE_AWS_IDENTITY_LOG"
: > "$FAKE_AWS_LOG"
run_import_in_repo auth
[ "$rc" = 0 ] && ok "repair: still works (rc 0)" || { bad "repair (rc=$rc)"; cat "$T/err"; }
check "repair: fence_mapping.json is restored" cmp "$STAGE/fence_mapping.json" "$STAGE/$AUTH_DIR/metadata.json"
check "repair: every call ran as the instance role, no profile, no role assumed" test "$(count_without ' aws ' "$INST_ID")" = 0 -a "$(grep -c 'assume-role\|get-caller-identity' "$FAKE_AWS_LOG")" = 0
check "repair: no temporary profile file was made" tmp_is_empty
reset_world
make_dataset
run_import auth "$DATASET_URL"
rm -f "${STAGE:?}/fence_mapping.json"
: > "$FAKE_AWS_IDENTITY_LOG"
: > "$FAKE_AWS_LOG"
export DEPLOY_TO_STAGING_STACK=true
run_import_in_repo open
unset DEPLOY_TO_STAGING_STACK
[ "$rc" = 0 ] && ok "repair after the open variant was staged in the same build (source profile used earlier in the build): rc 0" || { bad "repair after source reads (rc=$rc)"; cat "$T/err"; }
check "repair after source reads: the open variant was read as the source role" test "$(count_with "$SRC_READ" "$SRC_ID")" -gt 0
check "repair after source reads: the repair copy ran as the instance role, with no profile" bash -c "grep -F ' aws s3 cp s3://$STACK/data/$C1/$AUTH_DIR/metadata.json s3://$STACK/data/$C1/fence_mapping.json ' '$FAKE_AWS_IDENTITY_LOG' | grep -q '^$INST_ID '"
check "repair after source reads: nothing but source reads and the access check ran as the source role, nothing leaked" test "$(grep -c "^$SRC_ID " "$FAKE_AWS_IDENTITY_LOG")" = "$(($(idlog "$SRC_READ" | grep -c "^$SRC_ID ") + 1))" -a "$(grep -c '^ident=leak' "$FAKE_AWS_IDENTITY_LOG")" = 0

# ================================================================ Import: legacy .tar path
make_legacy() {
    reset_world
    local w="$T/legacy-src"
    rm -rf "$w"
    mkdir -p "$w" "$T/jh/workspace/Bash_Functions"
    printf 'AOS' > "$w/allObservationsStore.javabin"
    printf 'CM' > "$w/columnMeta.javabin"
    printf 'KEY' > "$w/encryption_key"
    printf '{"m":1}' > "$w/metadata.json"
    printf 'concept\n' > "$w/conceptsToRemove.txt"
    mkdir -p "$FAKE_S3/legacy-src/pheno"
    (cd "$w" && tar -cf "$FAKE_S3/legacy-src/pheno/final.tar" ./*.javabin encryption_key metadata.json conceptsToRemove.txt)
    mkdir -p "$FAKE_S3/$STACK/stg/containers"
    printf 'image' > "$FAKE_S3/$STACK/stg/containers/pic-sure-hpds-etl.tar.gz"
    cat > "$T/jh/workspace/Bash_Functions/role_functions.sh" << 'FUNCS'
assume_role() { aws sts assume-role --role-arn "$1" > /dev/null; export AWS_ACCESS_KEY_ID=fake; }
reset_role() { unset AWS_ACCESS_KEY_ID; echo reset_role >> "$FAKE_AWS_LOG"; }
get_stack() { echo stg; }
FUNCS
}

make_legacy
run_import auth "s3://legacy-src/pheno/final.tar"
[ "$rc" = 0 ] && ok "legacy auth exits 0" || { bad "legacy auth (rc=$rc)"; cat "$T/err"; }
check "legacy auth uploads javabins_rekeyed.tar" test -f "$STAGE/javabins_rekeyed.tar"
check "legacy auth tar holds the expected members" bash -c "tar -tf '$STAGE/javabins_rekeyed.tar' | sort | tr '\n' ' ' | grep -qx 'allObservationsStore.javabin columnMeta.javabin encryption_key metadata.json '"
check "legacy auth writes fence_mapping.json" cmp "$STAGE/fence_mapping.json" "$T/legacy-src/metadata.json"
check "legacy: the tar (staged marker) is the last upload, after fence_mapping.json" sh -c "grep 'aws s3 .*cp' '$FAKE_AWS_LOG' | tail -1 | grep -q 'javabins_rekeyed.tar'"
check "legacy auth assumes curated-datasets-s3-role" grep -q 'sts assume-role --role-arn arn:aws:iam::[0-9]*:role/curated-datasets-s3-role' "$FAKE_AWS_LOG"
check "legacy auth resets the role" grep -q '^reset_role' "$FAKE_AWS_LOG"
check "legacy auth does not run the removal" test "$(grep -c 'docker run' "$FAKE_DOCKER_LOG")" = 0
check "legacy auth does not write a manifest.tsv" test ! -e "$STAGE/javabins_rekeyed/manifest.tsv"

make_legacy
run_import open "s3://legacy-src/pheno/final.tar"
[ "$rc" = 0 ] && ok "legacy open exits 0" || { bad "legacy open (rc=$rc)"; cat "$T/err"; }
check "legacy open uploads destigmatized_javabins_rekeyed.tar" test -f "$STAGE/destigmatized_javabins_rekeyed.tar"
check "legacy open loads the ETL image" grep -q '^docker load' "$FAKE_DOCKER_LOG"
check "legacy open runs RemoveConceptFromMetadata" grep -q 'docker run .*LOADER_NAME=RemoveConceptFromMetadata fake-hpds-etl:1' "$FAKE_DOCKER_LOG"
check "legacy open copies conceptsToRemove.txt next to the data" test -f "$T/ws/local/hpds/conceptsToRemove.txt"
check "legacy open writes no fence_mapping.json" test ! -e "$STAGE/fence_mapping.json"

# legacy URLs that worked before the stricter URL check (+ % : = in the key) must still be accepted
make_legacy
odd="pheno/final+v1%3A2=a:b.tar"
cp "$FAKE_S3/legacy-src/pheno/final.tar" "$FAKE_S3/legacy-src/$odd"
run_import auth "s3://legacy-src/$odd"
[ "$rc" = 0 ] && ok "legacy .tar URL with + % : = passes the URL check and stages" || { bad "legacy odd URL (rc=$rc)"; cat "$T/err"; }
check "legacy odd URL: tar is staged" test -f "$STAGE/javabins_rekeyed.tar"
for badurl in "s3://legacy-src/pheno/a b.tar" 's3://legacy-src/pheno/a;b.tar' 's3://legacy-src/pheno/$'"(x).tar" "s3://legacy-src/pheno/a'b.tar"; do
    make_legacy
    run_import auth "$badurl"
    [ "$rc" != 0 ] && ok "URL check still refuses: $badurl" || bad "URL check accepted: $badurl"
done

make_legacy
run_import auth "s3://legacy-src/pheno/missing/"
[ "$rc" != 0 ] && ok "dataset-prefix path without manifest.json fails (not mistaken for legacy)" || bad "missing prefix"
make_legacy
run_import auth "s3://legacy-src/pheno/final.zip"
[ "$rc" != 0 ] && grep -q 'must end with' "$T/err" && ok "URL that is neither .tar nor a prefix is refused" || bad "bad url refusal"

# the legacy path assumes the same fixed role, whatever the environment holds
make_legacy
export curated_datasets_s3_role=arn:aws:iam::736265540791:role/curated-datasets-s3-role
run_import auth "s3://legacy-src/pheno/final.tar"
unset curated_datasets_s3_role
[ "$rc" = 0 ] && ok "legacy: staging with a curated_datasets_s3_role in the environment exits 0" || { bad "legacy role env (rc=$rc)"; cat "$T/err"; }
check "legacy: assume_role gets the fixed 515157839325 role, not the environment's" bash -c "grep -q 'sts assume-role --role-arn arn:aws:iam::515157839325:role/curated-datasets-s3-role\$' '$FAKE_AWS_LOG' && ! grep -q '736265540791' '$FAKE_AWS_LOG'"
check "legacy: the dataset-path helpers are not used (no profile, no identity check, no stream, no temporary file)" test "$(grep -cE 'get-caller-identity|aws s3 cp [^ ]+ - |aws s3 cp - ' "$FAKE_AWS_LOG")" = 0 -a "$(grep -c 'ident=source' "$FAKE_AWS_IDENTITY_LOG")" = 0 -a -z "$(ls -A "$T/tmp")"

# ================================================================ Import: legacy, both | derived keys | docker only when needed
# legacy tars for two variants (and a second auth tar) under a source bucket
legacy_sources() {
    cp "$FAKE_S3/legacy-src/pheno/final.tar" "$FAKE_S3/legacy-src/pheno/final-destig.tar"
    cp "$FAKE_S3/legacy-src/pheno/final.tar" "$FAKE_S3/legacy-src/pheno/final-v2.tar"
}
LEG="s3://legacy-src/pheno/final.tar"

make_legacy
run_import both "$LEG"
[ "$rc" = 0 ] && ok "legacy both exits 0" || { bad "legacy both (rc=$rc)"; cat "$T/err"; }
check "legacy both: both tars are staged" bash -c "test -f '$STAGE/javabins_rekeyed.tar' && test -f '$STAGE/destigmatized_javabins_rekeyed.tar'"
check "legacy both: fence_mapping.json is the auth tar's metadata.json and is written once" bash -c "cmp '$STAGE/fence_mapping.json' '$T/legacy-src/metadata.json' && test \$(grep -c 'fence_mapping.json' '$FAKE_AWS_LOG') = 1"
check "legacy both: the ETL image is loaded once" test "$(grep -c '^docker load' "$FAKE_DOCKER_LOG")" = 1
check "legacy both: the removal runs once (open only)" test "$(grep -c 'docker run' "$FAKE_DOCKER_LOG")" = 1
check "legacy both: the role is assumed and reset once per variant" bash -c "test \$(grep -c 'sts assume-role' '$FAKE_AWS_LOG') = 2 && test \$(grep -c '^reset_role' '$FAKE_AWS_LOG') = 2"
check "legacy both: the open tar has the expected members" bash -c "tar -tf '$STAGE/destigmatized_javabins_rekeyed.tar' | sort | tr '\n' ' ' | grep -qx 'allObservationsStore.javabin columnMeta.javabin encryption_key metadata.json '"
check "legacy both: summary lines" bash -c "grep -qx 'auth: staged (deploy key $C1)' '$T/out' && grep -qx 'open: staged (deploy key $C1)' '$T/out'"
check "legacy both: ends with the Next line" test "$(tail -1 "$T/out")" = "Next: run Check For Updates (or wait for the scheduled run) to deploy."

make_legacy
run_import auth "$LEG"
check "legacy auth: no docker image is loaded" test ! -s "$FAKE_DOCKER_LOG"

# docker and the image are only needed when the open variant still has to be staged
make_legacy
cfu_repo "$LEG" "$LEG"
mkdir -p "$STAGE"
: > "$STAGE/destigmatized_javabins_rekeyed.tar"
run_import_in_repo both
[ "$rc" = 0 ] && ok "legacy both with open already staged exits 0" || bad "legacy both, open staged (rc=$rc)"
check "legacy both, open staged: auth is staged, open skipped" bash -c "test -f '$STAGE/javabins_rekeyed.tar' && grep -q '^open: already staged, skipping' '$T/out'"
check "legacy both, open staged: docker is never used" test ! -s "$FAKE_DOCKER_LOG"
check "legacy both, open staged: the staged open tar is untouched (empty)" test ! -s "$STAGE/destigmatized_javabins_rekeyed.tar"

make_legacy
cfu_repo "$LEG" "$LEG"
mkdir -p "$STAGE"
: > "$STAGE/javabins_rekeyed.tar"
printf '{"m":1}' > "$STAGE/fence_mapping.json"
run_import_in_repo both
[ "$rc" = 0 ] && ok "legacy both with auth already staged exits 0" || bad "legacy both, auth staged (rc=$rc)"
check "legacy both, auth staged: open is staged with the removal" bash -c "test -s '$STAGE/destigmatized_javabins_rekeyed.tar' && grep -q 'docker run' '$FAKE_DOCKER_LOG'"
check "legacy both, auth staged: the role is assumed once" test "$(grep -c 'sts assume-role' "$FAKE_AWS_LOG")" = 1

# a bad open URL is refused before auth is staged (plan first)
make_legacy
run_import both "$LEG" 's3://legacy-src/pheno/a;b.tar'
[ "$rc" != 0 ] && grep -q 'is not an s3' "$T/err" && ok "both: a bad open URL is refused" || bad "bad open URL (rc=$rc)"
check "both: a bad open URL stages nothing, not even auth" bash -c "test ! -e '$STAGE' && ! grep -q 'aws s3 cp' '$FAKE_AWS_LOG'"

# differing legacy URLs and a later commit on the auth URL: each variant gets its own deploy key
make_legacy
legacy_sources
cfu_repo "s3://legacy-src/pheno/final.tar" "s3://legacy-src/pheno/final-destig.tar"
(
    cd "$REPO" || exit 1
    sed -i.bak 's|pheno/final.tar|pheno/final-v2.tar|' build-spec.json && rm -f build-spec.json.bak
    GIT_AUTHOR_DATE="2026-01-02T00:00:00Z" GIT_COMMITTER_DATE="2026-01-02T00:00:00Z" git commit -q -am bump
)
C2="$(git -C "$REPO" rev-parse HEAD)"
run_import_in_repo both
[ "$rc" = 0 ] && ok "stage job: legacy URLs with different blame commits stage" || { bad "differing legacy keys (rc=$rc)"; cat "$T/err"; }
check "stage job: auth is staged under the commit that changed the auth URL" test -f "$FAKE_S3/$STACK/data/$C2/javabins_rekeyed.tar"
check "stage job: open is staged under the older commit" test -f "$FAKE_S3/$STACK/data/$C1/destigmatized_javabins_rekeyed.tar"
check "stage job: nothing else is staged" test "$(find "$FAKE_S3/$STACK/data" -name '*.tar' | wc -l | tr -d ' ')" = 2

# ================================================================ Check For Updates: shell step (staged check)
run_cfu() {
    (cd "$REPO" && stack_s3_bucket="$STACK" bash "$T/cfu.sh" > "$T/out" 2> "$T/err")
    rc=$?
}
cfu_has() { [ "$(cat "$REPO/$1" 2> /dev/null)" = "$2" ]; }
cfu_lacks() { [ ! -e "$REPO/$1" ]; }
cfu_no_keys() { cfu_lacks datasetKey.txt && cfu_lacks destigmatizedDatasetKey.txt && cfu_lacks genomicDatasetKey.txt; }
# stage_manifest <key> <variant dir> : per-file marker;  stage_tar <key> <legacy name>
# The auth variant also gets data/<key>/fence_mapping.json, as Import writes it.
stage_manifest() {
    mkdir -p "$FAKE_S3/$STACK/data/$1/$2"
    : > "$FAKE_S3/$STACK/data/$1/$2/manifest.tsv"
    [ "$2" != javabins_rekeyed ] || printf '{"m":1}' > "$FAKE_S3/$STACK/data/$1/fence_mapping.json"
}
stage_tar() {
    mkdir -p "$FAKE_S3/$STACK/data/$1"
    : > "$FAKE_S3/$STACK/data/$1/$2.tar"
    [ "$2" != javabins_rekeyed ] || printf '{"m":1}' > "$FAKE_S3/$STACK/data/$1/fence_mapping.json"
}

PFX_A="s3://$SRC_BUCKET/data/hpds/pheno/datasets/$DATASET_ID/"

# nothing staged: fail fast, one ERROR per variant, no keys
reset_world
cfu_repo "$PFX_A" "$PFX_A"
run_cfu
[ "$rc" = 1 ] && ok "CFU: nothing staged exits 1" || { bad "CFU nothing staged (rc=$rc)"; cat "$T/err"; }
check "CFU: ERROR for auth with deploy key, source URL and hint" grep -qx "ERROR: auth dataset is not staged: deploy key $C1, source $PFX_A; run HPDS Data - Stage to Stack Bucket with HPDS_VARIANT=both" "$T/err"
check "CFU: ERROR for open with deploy key, source URL and hint" grep -qx "ERROR: open dataset is not staged: deploy key $C1, source $PFX_A; run HPDS Data - Stage to Stack Bucket with HPDS_VARIANT=both" "$T/err"
check "CFU: exactly one ERROR per variant" test "$(grep -c '^ERROR:' "$T/err")" = 2
check "CFU: nothing staged writes no key files" cfu_no_keys

# only auth missing
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_manifest "$C1" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 1 ] && ok "CFU: auth missing exits 1" || bad "CFU auth missing (rc=$rc)"
check "CFU: auth missing: ERROR names auth and HPDS_VARIANT=auth" grep -qx "ERROR: auth dataset is not staged: deploy key $C1, source $PFX_A; run HPDS Data - Stage to Stack Bucket with HPDS_VARIANT=auth" "$T/err"
check "CFU: auth missing: no ERROR for open" test "$(grep -c 'open dataset' "$T/err")" = 0
check "CFU: auth missing writes no key files" cfu_no_keys

# only open missing
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_manifest "$C1" javabins_rekeyed
run_cfu
[ "$rc" = 1 ] && ok "CFU: open missing exits 1" || bad "CFU open missing (rc=$rc)"
check "CFU: open missing: ERROR names open and HPDS_VARIANT=open" grep -qx "ERROR: open dataset is not staged: deploy key $C1, source $PFX_A; run HPDS Data - Stage to Stack Bucket with HPDS_VARIANT=open" "$T/err"
check "CFU: open missing: no ERROR for auth" test "$(grep -c 'auth dataset' "$T/err")" = 0
check "CFU: open missing writes no key files" cfu_no_keys

# both staged per-file
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_manifest "$C1" javabins_rekeyed
stage_manifest "$C1" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 0 ] && ok "CFU: both staged per-file exits 0" || { bad "CFU staged (rc=$rc)"; cat "$T/err"; }
check "CFU: writes the auth key" cfu_has datasetKey.txt "$C1"
check "CFU: writes the open key" cfu_has destigmatizedDatasetKey.txt "$C1"
check "CFU: writes the genomic key" cfu_has genomicDatasetKey.txt "$C1"
check "CFU: no ERROR when staged" test "$(grep -c '^ERROR' "$T/err")" = 0
check "CFU: writes no to-be/already-rekeyed files" bash -c "ls '$REPO' | grep -ciE 'rekeyed' | grep -qx 0"

# legacy tars
reset_world
cfu_repo "s3://example-bucket/legacy/final.tar" "s3://example-bucket/legacy/final-destig.tar"
stage_tar "$C1" javabins_rekeyed
stage_tar "$C1" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 0 ] && ok "CFU: both staged as legacy tars exits 0" || { bad "CFU legacy staged (rc=$rc)"; cat "$T/err"; }
check "CFU: legacy keys are written" bash -c "cd '$REPO' && test \"\$(cat datasetKey.txt)\" = $C1 && test \"\$(cat destigmatizedDatasetKey.txt)\" = $C1"

# mixed: auth legacy tar, open per-file
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_tar "$C1" javabins_rekeyed
stage_manifest "$C1" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 0 ] && ok "CFU: auth as legacy tar and open per-file exits 0" || bad "CFU mixed (rc=$rc)"
check "CFU: mixed writes both keys" bash -c "cd '$REPO' && test -s datasetKey.txt && test -s destigmatizedDatasetKey.txt && test -s genomicDatasetKey.txt"

# a partial stage (no manifest.tsv) is not staged
reset_world
cfu_repo "$PFX_A" "$PFX_A"
mkdir -p "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed"
: > "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed/columnMeta.javabin"
stage_manifest "$C1" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 1 ] && grep -q '^ERROR: auth dataset is not staged' "$T/err" && ok "CFU: a partial stage (no manifest.tsv) is not staged" || bad "CFU partial stage (rc=$rc)"

# list denied: head-object fallback decides
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_manifest "$C1" javabins_rekeyed
export FAKE_LIST_DENIED=1
run_cfu
unset FAKE_LIST_DENIED
[ "$rc" = 1 ] && ok "CFU: list denied, open missing exits 1" || bad "CFU list denied (rc=$rc)"
check "CFU: list denied: existing auth manifest.tsv is detected as staged via head-object (no auth ERROR)" test "$(grep -c 'auth dataset' "$T/err")" = 0
check "CFU: list denied: head-object was used for the auth manifest.tsv" grep -q "s3api head-object --bucket $STACK --key data/$C1/javabins_rekeyed/manifest.tsv" "$FAKE_AWS_LOG"
check "CFU: list denied: a missing open manifest.tsv (head 404) is 'not staged'" grep -q '^ERROR: open dataset is not staged' "$T/err"
stage_manifest "$C1" destigmatized_javabins_rekeyed
export FAKE_LIST_DENIED=1
run_cfu
unset FAKE_LIST_DENIED
[ "$rc" = 0 ] && ok "CFU: list denied, both staged exits 0" || bad "CFU list denied staged (rc=$rc)"

# Rollback: a build-spec.json whose lines come from the root (boundary) commit is blamed as ^<hash>; the ^ is not part of the key.
boundary_repo() { # <auth url> <open url> ; sets REPO, R1 (root commit); STAGE key is ${R1:0:39}
    cfu_repo "$1" "$2"
    (
        cd "$REPO" || exit 1
        git checkout -q --orphan rollback
        git rm -rq --cached . > /dev/null
        git add build-spec.json
        GIT_AUTHOR_DATE="2026-01-03T00:00:00Z" GIT_COMMITTER_DATE="2026-01-03T00:00:00Z" git commit -q -m 'root spec'
    )
    R1="$(git -C "$REPO" rev-parse HEAD)"
    RK="${R1:0:39}"
}
reset_world
boundary_repo "s3://example-bucket/legacy/final.tar" "s3://example-bucket/legacy/final-destig.tar"
check "boundary fixture: git blame marks the line with ^" bash -c "cd '$REPO' && git blame --abbrev=39 build-spec.json | grep -q '^\^'"
run_cfu
[ "$rc" = 1 ] && grep -q "deploy key $RK," "$T/err" && ok "CFU: boundary (^) blame commit is reported without the ^" || { bad "CFU boundary report (rc=$rc)"; cat "$T/err"; }
check "CFU: boundary ERROR carries no ^" test "$(grep -c '\^' "$T/err")" = 0
stage_tar "$RK" javabins_rekeyed
stage_tar "$RK" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 0 ] && ok "CFU: boundary (^) data staged under the hash without ^ passes" || { bad "CFU boundary staged (rc=$rc)"; cat "$T/err"; }
check "CFU: boundary auth key has no ^ and is a prefix of the commit" bash -c "k=\$(cat '$REPO/datasetKey.txt'); [[ \$k =~ ^[0-9a-f]{7,40}\$ ]] && [[ '$R1' == \$k* ]]"
check "CFU: boundary open key has no ^" bash -c "k=\$(cat '$REPO/destigmatizedDatasetKey.txt'); [[ \$k =~ ^[0-9a-f]{7,40}\$ ]]"
check "CFU: boundary genomic key has no ^" bash -c "k=\$(cat '$REPO/genomicDatasetKey.txt'); [[ \$k =~ ^[0-9a-f]{7,40}\$ ]]"
check "CFU: boundary keys carry no ^ anywhere" test "$(cat "$REPO"/*.txt | grep -c '\^')" = 0

# the hex check still stops garbage from becoming an S3 key segment (both jobs)
mkdir -p "$T/fakegit"
cat > "$T/fakegit/git" << 'FAKE_GIT'
#!/bin/bash
[ "$1" = blame ] && { echo 'zzzz (x 2026-01-01 1) "source_dataset_s3_url": "x"'; exit 0; }
exec /usr/bin/env -i PATH="$ORIG_PATH" git "$@"
FAKE_GIT
chmod +x "$T/fakegit/git"
reset_world
cfu_repo "s3://example-bucket/legacy/final.tar" "s3://example-bucket/legacy/final-destig.tar"
orig_path="$PATH"
fake_path="$T/fakegit:$PATH"
(cd "$REPO" && ORIG_PATH="$orig_path" PATH="$fake_path" stack_s3_bucket="$STACK" bash "$T/cfu.sh" > "$T/out" 2> "$T/err")
rc=$?
[ "$rc" != 0 ] && grep -q 'not a git hash' "$T/err" && ok "CFU: a non-hex blame commit is refused" || bad "CFU non-hex blame (rc=$rc)"
rm -rf "$T/ws"; cp -R "$REPO" "$T/ws"
(cd "$T/ws" && ORIG_PATH="$orig_path" PATH="$fake_path" HPDS_VARIANT=both stack_s3_bucket="$STACK" WORKSPACE="$T/ws" JENKINS_HOME="$T/jh" bash "$T/import.sh" > "$T/out" 2> "$T/err" < /dev/null)
rc=$?
[ "$rc" != 0 ] && grep -q 'not a git hash' "$T/err" && ok "stage job: a non-hex blame commit is refused" || bad "stage job non-hex blame (rc=$rc)"
check "stage job: non-hex blame commit stages nothing" test ! -d "$FAKE_S3/$STACK/data"

# differing dataset-prefix URLs and prefix-vs-tar
reset_world
cfu_repo "$PFX_A" "s3://$SRC_BUCKET/data/hpds/pheno/datasets/2026-11-05T0000Z/"
run_cfu
[ "$rc" != 0 ] && grep -q 'must be identical' "$T/err" && ok "CFU: differing dataset-prefix URLs fail" || bad "CFU URL mismatch (rc=$rc)"
check "CFU: URL mismatch writes no key files" cfu_no_keys
reset_world
cfu_repo "$PFX_A" "s3://example-bucket/legacy/final-destig.tar"
run_cfu
[ "$rc" != 0 ] && grep -q 'must be identical' "$T/err" && ok "CFU: dataset prefix on one side and .tar on the other fails" || bad "CFU prefix vs tar (rc=$rc)"
check "CFU: prefix vs tar writes no key files" cfu_no_keys
run_import_in_repo both
[ "$rc" != 0 ] && grep -q 'must be identical' "$T/err" && ok "stage job: dataset prefix on one side and .tar on the other fails" || bad "stage job prefix vs tar (rc=$rc)"
check "stage job: prefix vs tar stages nothing and calls no aws" test ! -s "$FAKE_AWS_LOG"

# legacy .tar URLs may differ; a later commit on the auth URL gives auth a new key and keeps the open key
reset_world
cfu_repo "s3://example-bucket/legacy/final.tar" "s3://example-bucket/legacy/final-destig.tar"
(
    cd "$REPO" || exit 1
    sed -i.bak 's|legacy/final.tar|legacy/final-v2.tar|' build-spec.json && rm -f build-spec.json.bak
    GIT_AUTHOR_DATE="2026-01-02T00:00:00Z" GIT_COMMITTER_DATE="2026-01-02T00:00:00Z" git commit -q -am bump
)
C2="$(git -C "$REPO" rev-parse HEAD)"
stage_tar "$C2" javabins_rekeyed
stage_tar "$C1" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 0 ] && ok "CFU: legacy .tar URLs may differ" || { bad "CFU legacy urls (rc=$rc)"; cat "$T/err"; }
check "CFU: auth key follows the commit that changed the auth URL" cfu_has datasetKey.txt "$C2"
check "CFU: open key stays at the older commit" cfu_has destigmatizedDatasetKey.txt "$C1"
stage_tar "$C1" javabins_rekeyed
rm -rf "$FAKE_S3/$STACK/data/$C2"
run_cfu
[ "$rc" = 1 ] && grep -q "auth dataset is not staged: deploy key $C2," "$T/err" && ok "CFU: data staged under the old auth key does not satisfy the new auth key" || bad "CFU stale key (rc=$rc)"

# ================================================================ Both jobs compute the same keys (parity)
# The shared helper block must be byte-identical in both job scripts.
shared_block() { sed -n '/^# ---- shared with/,/^# ---- end of shared block/p' "$1"; }
shared_block "$T/import.sh" > "$T/shared.import"
shared_block "$T/cfu.sh" > "$T/shared.cfu"
check "shared helper block exists in both jobs" test "$(wc -l < "$T/shared.cfu" | tr -d ' ')" -gt 40
check "shared helper block is identical in both jobs" cmp "$T/shared.import" "$T/shared.cfu"

# Behavioural parity: whatever key Import stages under, CFU (same repo) accepts and reports as the key.
# parity <label> ; REPO is the fixture, the fake S3 holds its sources
parity() {
    run_import_in_repo both
    [ "$rc" = 0 ] || { bad "parity $1: the stage job stages (rc=$rc)"; cat "$T/err"; return; }
    run_cfu
    [ "$rc" = 0 ] && ok "parity $1: CFU finds the data the stage job staged (same deploy keys)" || { bad "parity $1: CFU (rc=$rc)"; cat "$T/err"; return; }
    local ak ok_
    ak="$(cat "$REPO/datasetKey.txt")"
    ok_="$(cat "$REPO/destigmatizedDatasetKey.txt")"
    if [ -e "$FAKE_S3/$STACK/data/$ak/javabins_rekeyed/manifest.tsv" ] || [ -e "$FAKE_S3/$STACK/data/$ak/javabins_rekeyed.tar" ]; then ok "parity $1: auth data is under CFU's auth key"; else bad "parity $1: auth key $ak"; fi
    if [ -e "$FAKE_S3/$STACK/data/$ok_/destigmatized_javabins_rekeyed/manifest.tsv" ] || [ -e "$FAKE_S3/$STACK/data/$ok_/destigmatized_javabins_rekeyed.tar" ]; then ok "parity $1: open data is under CFU's open key"; else bad "parity $1: open key $ok_"; fi
}

reset_world
make_dataset
cfu_repo "$DATASET_URL" "$DATASET_URL"
parity "dataset prefix"

make_legacy
legacy_sources
cfu_repo "s3://legacy-src/pheno/final.tar" "s3://legacy-src/pheno/final-destig.tar"
(
    cd "$REPO" || exit 1
    sed -i.bak 's|pheno/final.tar|pheno/final-v2.tar|' build-spec.json && rm -f build-spec.json.bak
    GIT_AUTHOR_DATE="2026-01-02T00:00:00Z" GIT_COMMITTER_DATE="2026-01-02T00:00:00Z" git commit -q -am bump
)
parity "legacy, auth bumped by a later commit"
check "parity: the two variants really have different keys" test "$(cat "$REPO/datasetKey.txt")" != "$(cat "$REPO/destigmatizedDatasetKey.txt")"

make_legacy
legacy_sources
boundary_repo "s3://legacy-src/pheno/final.tar" "s3://legacy-src/pheno/final-destig.tar"
parity "boundary (^) commit"
check "parity: boundary key is the commit without ^" test "$(cat "$REPO/datasetKey.txt")" = "$RK"
check "parity: the stage job staged under the key without ^" test -f "$FAKE_S3/$STACK/data/$RK/javabins_rekeyed.tar"

# ================================================================ Check For Updates: builders and Groovy steps (static checks)
check "CFU: the shell step is the first builder" python3 -I - "$CFU_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
tags = [e.tag for e in r.find("builders")]
assert tags == ["hudson.tasks.Shell", "hudson.plugins.groovy.SystemGroovy", "hudson.plugins.groovy.SystemGroovy"], tags
PY
check "CFU first groovy step still builds Bash_Functions then PIC-SURE Pipeline" bash -c "grep -q 'getItemByFullName(\"Bash_Functions\")' '$T/cfu.groovy.first' && grep -q 'getItemByFullName(\"PIC-SURE Pipeline\")' '$T/cfu.groovy.first' && grep -q 'PIC-SURE Pipeline failed' '$T/cfu.groovy.first'"
check "CFU: no builder references HPDS Data - Stage to Stack Bucket as a job to run" test "$(cat "$T/cfu.groovy.first" "$T/cfu.groovy" | grep -c 'Stage to Stack Bucket')" = 0
check "CFU groovy: no Import, runImport, HPDS_VARIANT or rekey files" test "$(grep -cE 'Import|runImport|HPDS_VARIANT|toBeRekeyed|alreadyRekeyed|bucket_hash' "$T/cfu.groovy")" = 0
check "CFU shell: no toBeRekeyed/alreadyRekeyed files" test "$(grep -cE 'toBeRekeyed|alreadyRekeyed' "$T/cfu.sh")" = 0
check "CFU groovy: schedules Deployment Pipeline" grep -q 'getItemByFullName("Deployment Pipeline")' "$T/cfu.groovy"
for prm in deployment_git_hash dataset_s3_object_key destigmatized_dataset_s3_object_key genomic_dataset_s3_object_key; do
    check "CFU groovy: passes parameter $prm" grep -q "StringParameterValue(\"$prm\"" "$T/cfu.groovy"
done
check "CFU groovy: exactly four parameters" test "$(grep -c 'StringParameterValue(' "$T/cfu.groovy")" = 4
check "CFU groovy: reads datasetKey.txt, destigmatizedDatasetKey.txt and genomicDatasetKey.txt" bash -c "grep -q 'datasetKey.txt' '$T/cfu.groovy' && grep -q 'destigmatizedDatasetKey.txt' '$T/cfu.groovy' && grep -q 'genomicDatasetKey.txt' '$T/cfu.groovy'"
check "CFU groovy: a missing key file throws AbortException" bash -c "grep -q 'exists()' '$T/cfu.groovy' && grep -q 'throw new AbortException' '$T/cfu.groovy'"
check "CFU groovy: the key file names match what the shell step writes" bash -c "for f in datasetKey.txt destigmatizedDatasetKey.txt genomicDatasetKey.txt; do grep -q \"\$f\" '$T/cfu.sh' && grep -q \"\$f\" '$T/cfu.groovy' || exit 1; done"
check "CFU groovy: no removed parameters left" test "$(grep -cE 'isDestigmatized|output_file_name|disable_rekey' "$T/cfu.groovy")" = 0

# ================================================================ Stage job: DEPLOY_TO_STAGING_STACK (staging_deploy.properties)
# The shell step only writes staging_deploy.properties (the three deploy keys), after every check passed; the SystemGroovy step after
# it starts HPDS Data - Deploy to Staging Stack. The stage job looks up no stack: on the dataset path it sources no Bash_Functions,
# calls no get_stack and reads no stacks.json, whatever the flag.
python3 -I "$HERE/extract-shell.py" "$IMPORT_XML" --groovy --index 0 > "$T/import.groovy" || { echo "cannot extract import groovy"; exit 1; }
export SOURCED_LOG="$T/sourced.log"
export GET_STACK_CALLS="$T/get_stack.calls"
PROPS="$T/ws/staging_deploy.properties"

# lookup_traps <live stack> <staging stack>: a Bash_Functions workspace whose script logs when it is sourced and whose get_stack logs
# when it is called, and a stacks.json in the fake stack bucket. The stage job must touch none of them on the dataset path.
# Call after reset_world / make_legacy.
lookup_traps() {
    local bf="$T/jh/workspace/Bash_Functions"
    mkdir -p "$bf" "$FAKE_S3/$STACK/deployment_state_metadata"
    cat > "$bf/role_functions.sh" << 'FUNCS'
echo sourced >> "$SOURCED_LOG"
assume_role() { aws sts assume-role --role-arn "$1" > /dev/null; export AWS_ACCESS_KEY_ID=fake; }
reset_role() { unset AWS_ACCESS_KEY_ID; echo reset_role >> "$FAKE_AWS_LOG"; }
get_stack() { echo "$*" >> "$GET_STACK_CALLS"; echo stg; }
FUNCS
    printf '{"environments":{"prod":"%s","next_prod":"%s"}}\n' "$1" "$2" > "$FAKE_S3/$STACK/deployment_state_metadata/stacks.json"
    : > "$SOURCED_LOG"
    : > "$GET_STACK_CALLS"
}
BF_DIR="$T/jh/workspace/Bash_Functions"
flag_on() { export DEPLOY_TO_STAGING_STACK=true; }
flag_off() { unset DEPLOY_TO_STAGING_STACK; }
no_props() { [ ! -e "$PROPS" ] && [ ! -e "$PROPS.tmp" ]; }
props_is() { # auth_key open_key genomic_key
    [ "$(cat "$PROPS" 2> /dev/null)" = "$(printf 'auth_key=%s\nopen_key=%s\ngenomic_key=%s' "$1" "$2" "$3")" ]
}
no_lookup() { # the dataset path made no stack lookup of any kind
    [ ! -s "$SOURCED_LOG" ] && [ ! -s "$GET_STACK_CALLS" ] && [ "$(grep -c 'stacks.json\|deployment_state_metadata' "$FAKE_AWS_LOG")" = 0 ]
}
# bump_genomic: a later commit on the genomic URL line; sets G (the genomic deploy key)
bump_genomic() {
    (
        cd "$REPO" || exit 1
        sed -i.bak 's|example-bucket/genomic/|example-bucket/genomic-v2/|' build-spec.json && rm -f build-spec.json.bak
        GIT_AUTHOR_DATE="2026-01-03T00:00:00Z" GIT_COMMITTER_DATE="2026-01-03T00:00:00Z" git commit -q -am genomic
    )
    G="$(git -C "$REPO" rev-parse HEAD)"
}
refused_with() { [ "$rc" != 0 ] && grep -q "$1" "$T/err" && no_props; }

# The aws calls a flag-off run makes for a fresh `both` staging of the dataset-prefix fixture (sorted, unique: the open variant's
# second copy to fence_mapping.json is gone by design, the call itself is the auth variant's). Any new probe or copy makes the set differ.
expected_flag_off_calls() {
    local src="s3://$SRC_BUCKET/data/hpds/pheno/datasets/$DATASET_ID" dst="s3://$STACK/data/$C1" f
    local sse="--sse AES256" so="--only-show-errors"
    sz() { wc -c < "$DATASET_DIR/$1" | tr -d ' '; }
    echo "aws sts get-caller-identity --output text"
    echo "aws s3 cp $src/manifest.json dataset_work/manifest.json $so"
    for f in $AUTH_DIR $OPEN_DIR; do
        echo "aws s3 cp dataset_work/manifest.tsv $dst/$f/manifest.tsv $sse $so"
        echo "aws s3api list-objects-v2 --bucket $STACK --prefix data/$C1/$f/manifest.tsv --output json"
        echo "aws s3api list-objects-v2 --bucket $STACK --prefix data/$C1/$f.tar --output json"
    done
    # source reads (stream to stdout) and destination writes (stream from stdin, with the manifest bytes)
    for f in allObservationsStore.javabin columnMeta.javabin open/columnMeta.javabin encryption_key static/metadata.json static/conceptsToRemove.txt; do
        echo "aws s3 cp $src/$f - $so"
    done
    for f in allObservationsStore.javabin encryption_key; do
        echo "aws s3 cp - $dst/$AUTH_DIR/$f $sse --expected-size $(sz $f) $so"
        echo "aws s3 cp - $dst/$OPEN_DIR/$f $sse --expected-size $(sz $f) $so"
    done
    echo "aws s3 cp - $dst/$AUTH_DIR/columnMeta.javabin $sse --expected-size $(sz columnMeta.javabin) $so"
    echo "aws s3 cp - $dst/$OPEN_DIR/columnMeta.javabin $sse --expected-size $(sz open/columnMeta.javabin) $so"
    echo "aws s3 cp - $dst/$AUTH_DIR/metadata.json $sse --expected-size $(sz static/metadata.json) $so"
    echo "aws s3 cp - $dst/$OPEN_DIR/metadata.json $sse --expected-size $(sz static/metadata.json) $so"
    echo "aws s3 cp - $dst/fence_mapping.json $sse --expected-size $(sz static/metadata.json) $so"
    echo "aws s3 cp - $dst/$OPEN_DIR/conceptsToRemove.txt $sse --expected-size $(sz static/conceptsToRemove.txt) $so"
    for f in allObservationsStore.javabin columnMeta.javabin encryption_key metadata.json; do
        echo "aws s3api head-object --bucket $STACK --key data/$C1/$AUTH_DIR/$f"
        echo "aws s3api head-object --bucket $STACK --key data/$C1/$OPEN_DIR/$f"
    done
    echo "aws s3api head-object --bucket $STACK --key data/$C1/$OPEN_DIR/conceptsToRemove.txt"
    echo "aws s3api head-object --bucket $STACK --key data/$C1/fence_mapping.json"
}

# ---- flag off (the default): behaves as before, reads no stacks.json, sources nothing, writes no file
for mode in unset false; do
    reset_world
    make_dataset
    lookup_traps live-stk blue-stk
    cfu_repo "$DATASET_URL" "$DATASET_URL"
    [ "$mode" = false ] && export DEPLOY_TO_STAGING_STACK=false
    WS_SEED=staging_deploy.properties run_import_in_repo both
    [ "$rc" = 0 ] && ok "staging flag $mode: both stages (rc 0)" || { bad "staging flag $mode (rc=$rc)"; cat "$T/err"; }
    check "staging flag $mode: no staging_deploy.properties (a stale one is deleted)" no_props
    check "staging flag $mode: no stack lookup (stacks.json, Bash_Functions, get_stack)" no_lookup
    check "staging flag $mode: no fence_mapping.json existence probe (no list; one head, the byte check after the write)" bash -c "test \$(grep -E 'list-objects-v2' '$FAKE_AWS_LOG' | grep -c 'fence_mapping.json') = 0 && test \$(grep -E 'head-object' '$FAKE_AWS_LOG' | grep -c 'fence_mapping.json') = 1"
    expected_flag_off_calls | sort -u > "$T/aws.expected"
    sort -u "$FAKE_AWS_LOG" > "$T/aws.actual"
    check "staging flag $mode: the set of aws calls is exactly the staging calls (no other probe, list, head or copy)" diff "$T/aws.expected" "$T/aws.actual"
    check "staging flag $mode: fence_mapping.json is written once (auth only)" test "$(grep -c 's3://.*/fence_mapping.json' "$FAKE_AWS_LOG")" = 1
    if [ "$mode" = unset ]; then cp "$FAKE_AWS_LOG" "$T/aws.flag-unset.log"; else
        # The two sides of a stream (source read | destination write) run concurrently, so their log lines may
        # interleave in either order: compare the calls with their counts, not the line order.
        sort "$FAKE_AWS_LOG" > "$T/aws.flag-false.sorted"
        sort "$T/aws.flag-unset.log" > "$T/aws.flag-unset.sorted"
        check "staging flag false: the aws calls (with counts) are identical to those of an unset flag" cmp "$T/aws.flag-false.sorted" "$T/aws.flag-unset.sorted"
    fi
    check "staging flag $mode: no staging text in the output" test "$(grep -ci 'staging deploy\|staging stack' "$T/out")" = 0
    check "staging flag $mode: output still ends with the Next line" test "$(tail -1 "$T/out")" = "Next: run Check For Updates (or wait for the scheduled run) to deploy."
done

# a stale file is deleted whatever happens later in the build (here: an unknown variant is refused first)
reset_world
make_dataset
WS_SEED=staging_deploy.properties run_import neither "$DATASET_URL"
[ "$rc" != 0 ] && no_props && ok "stale staging_deploy.properties is deleted even when the build is refused early" || bad "stale file after early refusal (rc=$rc)"

reset_world
make_dataset
export DEPLOY_TO_STAGING_STACK=maybe
run_import both "$DATASET_URL"
[ "$rc" != 0 ] && grep -q "unknown DEPLOY_TO_STAGING_STACK" "$T/err" && ok "an unknown DEPLOY_TO_STAGING_STACK value is refused" || bad "unknown flag value (rc=$rc)"
check "unknown flag value: nothing staged, no aws call" test ! -s "$FAKE_AWS_LOG"

# ---- flag on, per-file, both: the file carries the three keys and nothing else
reset_world
make_dataset
lookup_traps live-stk blue-stk
cfu_repo "$DATASET_URL" "$DATASET_URL"
bump_genomic
flag_on
WS_SEED=staging_deploy.properties run_import_in_repo both
[ "$rc" = 0 ] && ok "staging flag on, per-file both: exits 0" || { bad "flag on per-file both (rc=$rc)"; cat "$T/err"; }
check "flag on: properties = auth key, open key, genomic key (stale file replaced)" props_is "$C1" "$C1" "$G"
check "flag on: the genomic key differs from the auth key (own blame commit)" test "$C1" != "$G"
check "flag on: the file has exactly three lines and no stack" bash -c "test \"\$(wc -l < '$PROPS' | tr -d ' ')\" = 3 && ! grep -q 'stack' '$PROPS'"
check "flag on: no temporary file is left" test ! -e "$PROPS.tmp"
check "flag on: both variants and the fence mapping are staged" bash -c "test -f '$STAGE/$AUTH_DIR/manifest.tsv' && test -f '$STAGE/$OPEN_DIR/manifest.tsv' && test -f '$STAGE/fence_mapping.json'"
check "flag on: no stack lookup (stacks.json, Bash_Functions, get_stack)" no_lookup
check "flag on: per-file staging only checks the source role (the same 2 get-caller-identity calls as with the flag off), no assume-role" test "$(grep -c 'sts get-caller-identity' "$FAKE_AWS_LOG")" = 2 -a "$(grep -c 'sts assume-role' "$FAKE_AWS_LOG")" = 0
check "flag on: nothing is read or written under any stack name" test "$(grep -c 'live-stk\|blue-stk' "$FAKE_AWS_LOG")" = 0
check "flag on: the build says the checks passed and that the next step starts the deploy job" grep -q "staging deploy: checks passed; the next build step starts HPDS Data - Deploy to Staging Stack with the deploy keys" "$T/out"
check "flag on: no 'Next: run Check For Updates' line" test "$(grep -c '^Next: run Check For Updates' "$T/out")" = 0
check "flag on: the shell step does not print the 'Deployed to the staging stack only' line (the Groovy step does, on success)" test "$(grep -c 'Deployed to the staging stack only' "$T/out")" = 0
check "flag on: the per-variant summary lines are still there" bash -c "grep -qx 'auth: staged (deploy key $C1)' '$T/out' && grep -qx 'open: staged (deploy key $C1)' '$T/out'"

# ---- flag on, everything already staged: nothing is staged again, the file is still written
flag_on
run_import_in_repo both
[ "$rc" = 0 ] && ok "flag on, both already staged: exits 0" || { bad "flag on already staged (rc=$rc)"; cat "$T/err"; }
check "flag on, already staged: file is written" props_is "$C1" "$C1" "$G"
check "flag on, already staged: both variants reported already staged" test "$(grep -c 'already staged, skipping' "$T/out")" = 2

# the keys in the file are the keys Check For Updates computes for the same checkout
run_cfu
[ "$rc" = 0 ] && ok "flag on: Check For Updates accepts what the staging deploy staged (fence mapping included)" || { bad "CFU after flag on (rc=$rc)"; cat "$T/err"; }
check "flag on: genomic key in the file = genomicDatasetKey.txt of Check For Updates" test "$(cat "$REPO/genomicDatasetKey.txt")" = "$(sed -n 's/^genomic_key=//p' "$PROPS")"
check "flag on: auth and open keys in the file = Check For Updates' keys" bash -c "test \"\$(cat '$REPO/datasetKey.txt')\" = \"\$(sed -n 's/^auth_key=//p' '$PROPS')\" && test \"\$(cat '$REPO/destigmatizedDatasetKey.txt')\" = \"\$(sed -n 's/^open_key=//p' '$PROPS')\""

# ---- flag on with HPDS_VARIANT=auth / open: the other variant must already be staged
reset_world
make_dataset
lookup_traps live-stk blue-stk
flag_off
run_import open "$DATASET_URL"
flag_on
run_import_in_repo auth
[ "$rc" = 0 ] && ok "flag on, HPDS_VARIANT=auth with open already staged: exits 0" || { bad "auth + staged open (rc=$rc)"; cat "$T/err"; }
check "flag on, auth + staged open: file is written" props_is "$C1" "$C1" "$C1"
reset_world
make_dataset
lookup_traps live-stk blue-stk
flag_off
run_import auth "$DATASET_URL"
flag_on
run_import_in_repo open
[ "$rc" = 0 ] && ok "flag on, HPDS_VARIANT=open with auth already staged: exits 0" || { bad "open + staged auth (rc=$rc)"; cat "$T/err"; }
check "flag on, open + staged auth: file is written" props_is "$C1" "$C1" "$C1"

reset_world
make_dataset
lookup_traps live-stk blue-stk
flag_on
WS_SEED=staging_deploy.properties run_import auth "$DATASET_URL"
refused_with "needs the open data, which is not staged for deploy key $C1; run this job with HPDS_VARIANT=open (or both)" \
    && ok "flag on, HPDS_VARIANT=auth, open not staged: refused with a clear message, no file" || { bad "auth, open missing (rc=$rc)"; cat "$T/err"; }
check "that refusal still staged the requested auth variant" test -f "$STAGE/$AUTH_DIR/manifest.tsv"
reset_world
make_dataset
lookup_traps live-stk blue-stk
flag_on
run_import open "$DATASET_URL"
refused_with "needs the auth data, which is not staged for deploy key $C1; run this job with HPDS_VARIANT=auth (or both) first" \
    && ok "flag on, HPDS_VARIANT=open, auth not staged: refused with a clear message, no file" || { bad "open, auth missing (rc=$rc)"; cat "$T/err"; }

# ---- flag on: no stack is looked up, so nothing about stacks can make the stage job refuse or change its file
for scenario in no-lookup-material stacks-json-without-staging stacks-json-null get-stack-fails; do
    reset_world
    make_dataset
    case "$scenario" in
        no-lookup-material) : ;;
        stacks-json-without-staging) lookup_traps live-stk blue-stk; printf '{"environments":{"prod":"live-stk"}}\n' > "$FAKE_S3/$STACK/deployment_state_metadata/stacks.json" ;;
        stacks-json-null) lookup_traps live-stk blue-stk; printf '{"environments":{"prod":"x","next_prod":null}}\n' > "$FAKE_S3/$STACK/deployment_state_metadata/stacks.json" ;;
        get-stack-fails)
            lookup_traps live-stk blue-stk
            cat > "$BF_DIR/role_functions.sh" << 'FAILING_FUNCS'
echo sourced >> "$SOURCED_LOG"
get_stack() { echo "$*" >> "$GET_STACK_CALLS"; echo "ERROR: boom" >&2; return 1; }
FAILING_FUNCS
            : > "$SOURCED_LOG"
            ;;
    esac
    flag_on
    WS_SEED=staging_deploy.properties run_import both "$DATASET_URL"
    [ "$rc" = 0 ] && props_is "$C1" "$C1" "$C1" && ok "flag on, $scenario: the stage job does not care and writes the three keys" || { bad "flag on, $scenario (rc=$rc)"; cat "$T/err"; }
    check "flag on, $scenario: nothing was sourced, called or read" no_lookup
done

# ---- flag on: fence mapping and genomic key
# per-file auth data without fence_mapping.json: restored, then the deploy file is written (whichever variant was requested)
for variant in both auth open; do
    reset_world
    make_dataset
    lookup_traps live-stk blue-stk
    flag_off
    run_import both "$DATASET_URL"
    rm -f "${STAGE:?}/fence_mapping.json"
    flag_on
    run_import_in_repo "$variant"
    [ "$rc" = 0 ] && ok "flag on, $variant: fence_mapping.json missing is restored and the build goes on" || { bad "flag on, $variant, fence missing (rc=$rc)"; cat "$T/err"; }
    check "flag on, $variant: restored from the staged metadata.json" cmp "$STAGE/fence_mapping.json" "$STAGE/javabins_rekeyed/metadata.json"
    check "flag on, $variant: the restore is announced once" test "$(grep -c '^fence_mapping.json restored from the staged metadata.json$' "$T/out")" = 1
    check "flag on, $variant: the properties file is written" props_is "$C1" "$C1" "$C1"
done

# the repair also happens with the flag off (stage only); the file is not written then
reset_world
make_dataset
flag_off
run_import both "$DATASET_URL"
rm -f "${STAGE:?}/fence_mapping.json"
run_import_in_repo auth
[ "$rc" = 0 ] && ok "flag off: a missing fence_mapping.json of per-file auth data is restored too" || { bad "flag off, fence missing (rc=$rc)"; cat "$T/err"; }
check "flag off, fence restored: no properties file" no_props
check "flag off, fence restored: it is the staged metadata.json" cmp "$STAGE/fence_mapping.json" "$STAGE/javabins_rekeyed/metadata.json"

# auth staged as a legacy tar without fence_mapping.json cannot be repaired: refused (flag on and off)
make_legacy
lookup_traps live-stk stg
cfu_repo "s3://legacy-src/pheno/final.tar" "s3://legacy-src/pheno/final-destig.tar"
mkdir -p "$STAGE"
: > "$STAGE/javabins_rekeyed.tar"
: > "$STAGE/destigmatized_javabins_rekeyed.tar"
flag_on
WS_SEED=staging_deploy.properties run_import_in_repo open
refused_with "restage under a new deploy key" && ok "flag on: a legacy tar without fence_mapping.json is refused with the restage hint, no file" || { bad "tar, fence missing (rc=$rc)"; cat "$T/err"; }
check "flag on, tar without fence: fence_mapping.json is not created" test ! -e "$STAGE/fence_mapping.json"
flag_off
run_import_in_repo auth
refused_with "restage under a new deploy key" && ok "flag off: a legacy auth tar without fence_mapping.json is refused too" || { bad "flag off, tar, fence missing (rc=$rc)"; cat "$T/err"; }

reset_world
make_dataset
lookup_traps live-stk blue-stk
cfu_repo "$DATASET_URL" "$DATASET_URL"
(
    cd "$REPO" || exit 1
    sed -i.bak 's|source_genomic_dataset_s3_url|other_field|' build-spec.json && rm -f build-spec.json.bak
    GIT_AUTHOR_DATE="2026-01-03T00:00:00Z" GIT_COMMITTER_DATE="2026-01-03T00:00:00Z" git commit -q -am nogenomic
)
flag_on
run_import_in_repo both
refused_with "no source_genomic_dataset_s3_url line" && ok "missing genomic line in build-spec.json is refused, no file" || { bad "genomic line missing (rc=$rc)"; cat "$T/err"; }

mkdir -p "$T/fakegit2"
cat > "$T/fakegit2/git" << 'FAKE_GIT2'
#!/bin/bash
# real git, except that git blame reports a non-hash for the genomic line
if [ "$1" = blame ]; then
    /usr/bin/env -i PATH="$ORIG_PATH" git "$@" | sed '/source_genomic_dataset_s3_url/s/^[^ ]*/zzzzzzz/'
    exit 0
fi
exec /usr/bin/env -i PATH="$ORIG_PATH" git "$@"
FAKE_GIT2
chmod +x "$T/fakegit2/git"
reset_world
make_dataset
lookup_traps live-stk blue-stk
cfu_repo "$DATASET_URL" "$DATASET_URL"
flag_on
op="$PATH"
PATH="$T/fakegit2:$PATH" ORIG_PATH="$op" run_import_in_repo both
refused_with "for source_genomic_dataset_s3_url is not a git hash" && ok "non-hex genomic blame commit is refused, no file" || { bad "genomic not hex (rc=$rc)"; cat "$T/err"; }

# a failed staging step ends the build before any checks: no file
reset_world
make_dataset
lookup_traps live-stk blue-stk
export FAKE_FAIL_COPY=encryption_key
flag_on
WS_SEED=staging_deploy.properties run_import both "$DATASET_URL"
unset FAKE_FAIL_COPY
[ "$rc" != 0 ] && no_props && ok "flag on: a failed staging copy fails the build and leaves no file" || bad "flag on, failed copy (rc=$rc)"

# ---- flag on, legacy .tar path
make_legacy
legacy_sources
lookup_traps live-stk stg
cfu_repo "s3://legacy-src/pheno/final.tar" "s3://legacy-src/pheno/final-destig.tar"
(
    cd "$REPO" || exit 1
    sed -i.bak 's|pheno/final.tar|pheno/final-v2.tar|' build-spec.json && rm -f build-spec.json.bak
    GIT_AUTHOR_DATE="2026-01-02T00:00:00Z" GIT_COMMITTER_DATE="2026-01-02T00:00:00Z" git commit -q -am bump
)
C2="$(git -C "$REPO" rev-parse HEAD)"
bump_genomic
flag_on
run_import_in_repo both
[ "$rc" = 0 ] && ok "flag on, legacy both: exits 0" || { bad "flag on legacy both (rc=$rc)"; cat "$T/err"; }
check "flag on, legacy: properties = auth key, open key, genomic key" props_is "$C2" "$C1" "$G"
check "flag on, legacy: the tars and the fence mappings are staged" bash -c "test -f '$FAKE_S3/$STACK/data/$C2/javabins_rekeyed.tar' && test -f '$FAKE_S3/$STACK/data/$C2/fence_mapping.json' && test -f '$FAKE_S3/$STACK/data/$C1/destigmatized_javabins_rekeyed.tar'"
check "flag on, legacy: Bash_Functions is sourced once, by the legacy path only" test "$(wc -l < "$SOURCED_LOG" | tr -d ' ')" = 1
check "flag on, legacy: get_stack is asked once, for the ETL image of the open variant, never by the deploy checks" test "$(cat "$GET_STACK_CALLS")" = staging
check "flag on, legacy: stacks.json is not read" test "$(grep -c 'stacks.json\|deployment_state_metadata' "$FAKE_AWS_LOG")" = 0
flag_on
: > "$SOURCED_LOG"
: > "$GET_STACK_CALLS"
run_import_in_repo both
[ "$rc" = 0 ] && props_is "$C2" "$C1" "$G" && ok "flag on, legacy, already staged: file is written again" || bad "flag on legacy already staged (rc=$rc)"
check "flag on, legacy, already staged: no Bash_Functions, no get_stack (nothing left to stage)" no_lookup

make_legacy
lookup_traps live-stk stg
flag_on
run_import auth "s3://legacy-src/pheno/final.tar"
refused_with "needs the open data" && ok "flag on, legacy HPDS_VARIANT=auth with open not staged: refused, no file" || { bad "legacy auth, open missing (rc=$rc)"; cat "$T/err"; }

# ---- the shell step and the deploy step agree on the file
check "shell step writes exactly the keys the deploy step requires" python3 -I - "$T/import.sh" "$T/import.groovy" << 'PY'
import re, sys
sh = open(sys.argv[1]).read()
gr = open(sys.argv[2]).read()
written = re.findall(r'echo "(\w+)=\$\{', sh.split("prepare_staging_deploy()")[1])
needed = re.findall(r'need\("(\w+)"', gr)
assert written == needed == ["auth_key", "open_key", "genomic_key"], (written, needed)
assert "staging_deploy.properties" in sh and "staging_deploy.properties" in gr
PY
check "shell step: no stack lookup in prepare_staging_deploy (no get_stack, stacks.json, Bash_Functions, stack variable)" python3 -I - "$T/import.sh" << 'PY'
import sys
sh = open(sys.argv[1]).read()
body = sh.split("prepare_staging_deploy() {")[1].split("\n}\n")[0]
for word in ("get_stack", "stacks.json", "Bash_Functions", "load_bash_functions", "target_stack", "staging_stack", "next_prod"):
    assert word not in body, word
# Bash_Functions is loaded only by the legacy path: the definition and its one call
assert sh.count("load_bash_functions") == 2, sh.count("load_bash_functions")
assert "load_bash_functions" in sh.split("stage_legacy() {")[1].split("\n}\n")[0]
PY
check "shell step: the success line is not in the shell step" test "$(grep -c 'Deployed to the staging stack only' "$T/import.sh")" = 0

# ================================================================ Stage job: the deploy step (static checks of the SystemGroovy source)
check "stage job: builders are the shell step, then one SystemGroovy deploy step" python3 -I - "$IMPORT_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
tags = [e.tag for e in r.find("builders")]
assert tags == ["hudson.tasks.Shell", "hudson.plugins.groovy.SystemGroovy"], tags
PY
check "deploy step: schedules exactly one job, HPDS Data - Deploy to Staging Stack, with exactly the three keys" python3 -I - "$T/import.groovy" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
assert 'def deployJobName = "HPDS Data - Deploy to Staging Stack"' in g
calls = re.findall(r'^deploy\((\w+), \[(.*?)\]\)', g, re.S | re.M)
assert len(calls) == 1 and calls[0][0] == "deployJobName", calls
params = dict(re.findall(r"(\w+)\s*:\s*(\w+)", calls[0][1]))
assert params == {"DATA_S3_OBJECT_KEY": "authKey", "DESTIGMATIZED_DATASET_S3_OBJECT_KEY": "openKey", "GENOMIC_DATASET_S3_OBJECT_KEY": "genomicKey"}, params
assert g.count("scheduleBuild2(") == 1
assert g.count("getItemByFullName(") == 1
PY
check "deploy step: the job is waited for and must end SUCCESS, else AbortException names the job" python3 -I - "$T/import.groovy" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
closure = g[g.index("def deploy = {"):g.index("deploy(deployJobName")]
assert closure.count("scheduleBuild2(") == 1 and closure.count("future.get()") == 1
assert re.search(r"getResult\(\) != Result\.SUCCESS\)\s*\{\s*throw new AbortException\(jobName \+", closure), closure
PY
check "deploy step: prints the number and URL of the deploy job's build" python3 -I - "$T/import.groovy" << 'PY'
import sys
g = open(sys.argv[1]).read()
closure = g[g.index("def deploy = {"):g.index("deploy(deployJobName")]
assert "waitForStart()" in closure and "getNumber()" in closure and "getUrl()" in closure
assert closure.index("waitForStart()") < closure.index("future.get()")
PY
check "deploy step: without the file the script returns before it reads or schedules anything; with the file it needs the flag" python3 -I - "$T/import.groovy" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
# indices come from code tokens, not from the file name (which also appears in the header comment)
read = g.index('build.workspace?.child("staging_deploy.properties")')
early = re.search(r'if \(propsFile == null \|\| !propsFile\.exists\(\)\) \{(.*?)\n\}\n', g, re.S)
assert early, "no early exit for a missing file"
body = early.group(1)
assert body.rstrip().endswith('println "staging deploy: not requested"\n    return'), body
assert body.count("return") == 1 and "scheduleBuild2" not in body and "readToString" not in body
assert 'throw new AbortException("DEPLOY_TO_STAGING_STACK is true' in body
# the early exit sits right after the file lookup and before anything reads or schedules
assert read < early.start() < g.index("props.load(") < g.index('String authKey = need(') < g.index("def deploy = {") < g.index("scheduleBuild2(")
assert g.index("readToString()") > early.end() and g.count("readToString()") == 1
# a file without the flag is not trusted
gate = re.search(r'if \(!"true"\.equals\(build\.buildVariables\?\.get\("DEPLOY_TO_STAGING_STACK"\)\)\) \{\s*throw new AbortException\(', g)
assert gate and early.end() <= gate.start() < g.index("props.load("), "no flag gate before the file is loaded"
PY
check "deploy step: the only values passed on are the three keys read from the file (no stack)" python3 -I - "$T/import.groovy" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
assert "TARGET_STACK" not in g and "target_stack" not in g
assert len(re.findall(r"^String \w+ = need\(", g, re.M)) == 3
PY
check "shell step: get_stack appears only in the legacy ETL image loader (definition comment, call, no live variable)" bash -c "! grep -qE 'get_stack.*live|live_stack' '$T/import.sh' && test \"\$(grep -c 'get_stack' '$T/import.sh')\" = 2 && grep -q 'stack=\$(get_stack \"staging\")' '$T/import.sh'"
check "deploy step: no stack, production or stack lookup in the source" test "$(grep -ciE 'prod|live|\bget_stack|stacks\.json|next_prod|Bash_Functions|assume_role' "$T/import.groovy")" = 0
check "deploy step: reads only staging_deploy.properties of this build's workspace (no hardcoded path, no other file)" bash -c "grep -q 'build.workspace' '$T/import.groovy' && ! grep -qE 'new File|/var/jenkins_home|JENKINS_HO|readFileFromWorkspace' '$T/import.groovy' && test \$(grep -c '\.child(' '$T/import.groovy') = 1 && test \$(grep -c 'child(.staging_deploy.properties.)' '$T/import.groovy') = 1"
check "deploy step: no dollar-brace in the source (no template or GString expansion)" test "$(grep -cF "$(printf '%s{' '$')" "$T/import.groovy")" = 0
check "deploy step: all three keys (auth, open, genomic) are validated, each with its own pattern" python3 -I - "$T/import.groovy" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
# the validator: a full match (==~) of the trimmed value, else AbortException
m = re.search(r"def need = \{ String name, String pattern ->(.*?)\n\}\n", g, re.S)
assert m, "no need closure"
body = m.group(1)
assert "==~ pattern" in body and "throw new AbortException(" in body and ".trim()" in body, body
bad_keys = ["", "abcdef", "ABCDEF0", "g" * 7, "0" * 41, "abc def0", "../abcdef0"]
wanted = {name: (r"[0-9a-f]{7,40}", ["abcdef0", "0" * 40], bad_keys) for name in ("auth_key", "open_key", "genomic_key")}
calls = re.findall(r'^(?:String|def)\s+\w+\s*=\s*need\("(\w+)",\s*/(.*?)/\)\s*$', g, re.M)
assert [c[0] for c in calls] == list(wanted), calls
for name, pattern in calls:
    expect, good, bad = wanted[name]
    assert pattern == expect, (name, pattern)
    for v in good:
        assert re.fullmatch(pattern, v), (name, v)
    for v in bad:
        assert not re.fullmatch(pattern, v), (name, v)
PY
check "deploy step: every parameter passed is defined by the deploy job, and the deploy job defines exactly those three" python3 -I - "$T/import.groovy" "$JOBS" << 'PY'
import re, sys, xml.etree.ElementTree as E
g = open(sys.argv[1]).read()
body = re.search(r'^deploy\(deployJobName, \[(.*?)\]\)', g, re.S | re.M).group(1)
passed = set(re.findall(r"(\w+)\s*:\s*\w+", body))
r = E.parse(sys.argv[2] + "/HPDS Data - Deploy to Staging Stack/config.xml").getroot()
defined = [p.findtext("name") for p in r.findall(".//parameterDefinitions/*")]
assert passed == set(defined) and len(defined) == 3, (sorted(passed), defined)
PY
check "deploy step: after the deploy job succeeded it prints exactly the 'Deployed to the staging stack only' line, once, as its last statement" python3 -I - "$T/import.groovy" "$T/import.desc" << 'PY'
import sys
line = 'println "Deployed to the staging stack only. A later Deployment Pipeline run rebuilds the staging stack from build-spec.json."'
g = open(sys.argv[1]).read()
assert g.count("Deployed to the staging stack only") == 1
assert g.rstrip("\n").split("\n")[-1] == line
assert g.index("deploy(deployJobName") < g.index(line)
assert "Deployed to the staging stack only. A later Deployment Pipeline run rebuilds the staging stack from build-spec.json." in open(sys.argv[2]).read()
PY
check "deploy step: without a request it prints exactly 'staging deploy: not requested' and returns" python3 -I - "$T/import.groovy" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
assert len(re.findall(r'^    println "staging deploy: not requested"\n    return$', g, re.M)) == 1
assert g.count("not requested") == 1
PY
check "deploy step: downstream builds carry the upstream cause" bash -c "grep -q 'new CauseAction(new Cause.UpstreamCause(build))' '$T/import.groovy'"
check "deploy step: DEPLOY_TO_STAGING_STACK=true without the file aborts" bash -c "grep -q 'throw new AbortException(\"DEPLOY_TO_STAGING_STACK is true' '$T/import.groovy'"
check "stage description: names the option, the deploy job and its locks, the three jobs, PSAMA/fence_mapping.json, the live stack and next_prod" bash -c "for w in DEPLOY_TO_STAGING_STACK 'starts HPDS Data - Deploy to Staging Stack (which takes the locks)' 'deployment-state lock and the stack lock' 'PIC-SURE HPDS Auth Deploy' 'PIC-SURE HPDS Open Deploy' 'PIC-SURE Auth Micro App Deploy' 'fence_mapping.json into its container' 'cannot be targeted' next_prod; do grep -qF -- \"\$w\" '$T/import.desc' || { echo missing: \$w; exit 1; }; done"
check "stage description: the old notes are gone (no overlap warning, no stack lookup, 'nothing else happens')" bash -c "! grep -qiE 'holds no deployment-state lock|stack swap is in progress|may be live by the end|get_stack staging|Only the staging stack is looked up|stage only, nothing else happens|before a build with DEPLOY_TO_STAGING_STACK|resolved once' '$T/import.desc'"
check "stage description: a flag-off run can still restore a missing fence_mapping.json or refuse a legacy auth tar without one" bash -c "grep -qF 'A flag-off run can still restore a missing data/<auth key>/fence_mapping.json' '$T/import.desc' && grep -qF 'refuse an auth variant that is staged as a legacy tar without one' '$T/import.desc'"
check "stage description: the success line, Deployment Pipeline rebuilding the staging stack, and the live stack changing only by a swap" bash -c "grep -qF 'Deployed to the staging stack only. A later Deployment Pipeline run rebuilds the staging stack from build-spec.json.' '$T/import.desc' && grep -qF 'the live stack changes only by a stack swap' '$T/import.desc'"
check "stage description: fence_mapping.json is written by the auth variant only, the open variant never writes it" bash -c "grep -qF 'written by the auth variant only' '$T/import.desc' && grep -qF 'The open variant never writes it' '$T/import.desc' && ! grep -qF 'rewritten by every variant' '$T/import.desc'"
check "stage description: the repair of a missing fence mapping and the refusal for a legacy tar are described" bash -c "grep -qF 'fence_mapping.json restored from the staged metadata.json' '$T/import.desc' && grep -qF 'data/<auth key>/javabins_rekeyed/metadata.json' '$T/import.desc' && grep -qF 'legacy tar without' '$T/import.desc' && grep -qF 'restage it under a new deploy key' '$T/import.desc'"
check "stage description: the deploy step runs on every build, so the script is approved before the first build whatever the flag" bash -c "grep -qF 'runs on EVERY build' '$T/import.desc' && grep -qF 'before the first build, whatever the flag is' '$T/import.desc'"
check "stage description: Bash_Functions is needed for a legacy run only" bash -c "grep -qF 'build Bash_Functions once before a legacy run.' '$T/import.desc'"
check "CFU description: the fence hint covers per-file data (restored by the stage job) and legacy tars (restage under a new deploy key)" bash -c "grep -qF 'restores it from the staged metadata.json' '$T/cfu.desc' && grep -qF 'legacy tar must be restaged under a new deploy key' '$T/cfu.desc'"
check "the description test looks at the <description> element only (the markup of the file is not in it)" bash -c "! grep -qE '<hudson|<builders|&lt;|&gt;' '$T/import.desc' && grep -qF 'data/<deploy key>/' '$T/import.desc'"

# ================================================================ Check For Updates: fence_mapping.json is part of "staged"
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_manifest "$C1" javabins_rekeyed
stage_manifest "$C1" destigmatized_javabins_rekeyed
rm -f "${STAGE:?}/fence_mapping.json"
run_cfu
[ "$rc" = 1 ] && ok "CFU: both staged but fence_mapping.json missing exits 1" || { bad "CFU fence missing (rc=$rc)"; cat "$T/err"; }
check "CFU: fence ERROR (per-file) names the variant, the deploy key, the file and the stage job hint" grep -qx "ERROR: auth dataset is staged but fence_mapping.json missing: deploy key $C1 (data/$C1/fence_mapping.json); run HPDS Data - Stage to Stack Bucket with HPDS_VARIANT=auth (restores it from the staged metadata.json)" "$T/err"
check "CFU: fence ERROR (per-file) does not tell to restage under a new deploy key" test "$(grep -c 'new deploy key' "$T/err")" = 0
check "CFU: fence missing says nothing was scheduled" grep -qx 'Nothing was scheduled.' "$T/err"
check "CFU: fence missing writes no key files" cfu_no_keys
stage_manifest "$C1" javabins_rekeyed
run_cfu
[ "$rc" = 0 ] && ok "CFU: fence_mapping.json present passes" || { bad "CFU fence present (rc=$rc)"; cat "$T/err"; }
check "CFU: fence present writes the key files" bash -c "cd '$REPO' && test -s datasetKey.txt && test -s destigmatizedDatasetKey.txt && test -s genomicDatasetKey.txt"

# auth staged as a legacy tar: no in-place repair, the hint says to restage under a new deploy key
reset_world
cfu_repo "s3://example-bucket/legacy/final.tar" "s3://example-bucket/legacy/final-destig.tar"
stage_tar "$C1" javabins_rekeyed
stage_tar "$C1" destigmatized_javabins_rekeyed
rm -f "${STAGE:?}/fence_mapping.json"
run_cfu
[ "$rc" = 1 ] && ok "CFU: legacy tar auth without fence_mapping.json exits 1" || { bad "CFU tar fence missing (rc=$rc)"; cat "$T/err"; }
check "CFU: fence ERROR (tar) says it cannot be restored and to restage under a new deploy key" grep -qx "ERROR: auth dataset is staged as a legacy tar but fence_mapping.json missing: deploy key $C1 (data/$C1/fence_mapping.json); it cannot be restored in place: restage under a new deploy key (commit a change to the source URL lines of build-spec.json, then run HPDS Data - Stage to Stack Bucket)" "$T/err"
check "CFU: fence ERROR (tar) does not point at HPDS_VARIANT=auth" test "$(grep -c 'HPDS_VARIANT' "$T/err")" = 0
check "CFU: fence missing (tar) writes no key files" cfu_no_keys

# per-file auth: Import restores the mapping, then CFU passes
reset_world
make_dataset
cfu_repo "$DATASET_URL" "$DATASET_URL"
run_import_in_repo both
[ "$rc" = 0 ] || { bad "repair fixture: stage both (rc=$rc)"; cat "$T/err"; }
rm -f "${STAGE:?}/fence_mapping.json"
run_cfu
[ "$rc" = 1 ] && grep -q 'restores it from the staged metadata.json' "$T/err" && ok "CFU: per-file staged data without fence_mapping.json is refused with the stage job hint" || bad "CFU before repair (rc=$rc)"
run_import_in_repo auth
[ "$rc" = 0 ] && ok "stage job HPDS_VARIANT=auth (the CFU hint) exits 0" || { bad "repair by the hinted stage job (rc=$rc)"; cat "$T/err"; }
run_cfu
[ "$rc" = 0 ] && ok "CFU passes after the repair" || { bad "CFU after repair (rc=$rc)"; cat "$T/err"; }
check "CFU after the repair writes the key files" bash -c "cd '$REPO' && test -s datasetKey.txt && test -s destigmatizedDatasetKey.txt && test -s genomicDatasetKey.txt"

# stale key files from an earlier build do not survive a fence failure
printf 'old\n' > "$REPO/datasetKey.txt"
rm -f "${STAGE:?}/fence_mapping.json"
run_cfu
[ "$rc" = 1 ] && cfu_no_keys && ok "CFU: fence missing also removes stale key files" || bad "CFU stale key files (rc=$rc)"

# fence_mapping.json is checked with the same list-first helper (list denied: head-object decides)
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_manifest "$C1" javabins_rekeyed
stage_manifest "$C1" destigmatized_javabins_rekeyed
export FAKE_LIST_DENIED=1
run_cfu
[ "$rc" = 0 ] && grep -q "head-object --bucket $STACK --key data/$C1/fence_mapping.json" "$FAKE_AWS_LOG" && ok "CFU: list denied: fence_mapping.json is found via head-object" || bad "CFU fence head-object (rc=$rc)"
rm -f "${STAGE:?}/fence_mapping.json"
run_cfu
unset FAKE_LIST_DENIED
[ "$rc" = 1 ] && grep -q 'fence_mapping.json missing' "$T/err" && ok "CFU: list denied: a missing fence_mapping.json (head 404) fails" || bad "CFU fence head-object missing (rc=$rc)"

# a variant that is not staged is reported as before (the fence check does not mask it)
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_manifest "$C1" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 1 ] && grep -q '^ERROR: auth dataset is not staged' "$T/err" && ok "CFU: auth not staged is still reported as not staged" || bad "CFU auth not staged (rc=$rc)"
check "CFU: auth not staged: no fence ERROR" test "$(grep -c 'fence_mapping' "$T/err")" = 0

# ================================================================ job definitions
check "Stage job: parameters are the HPDS_VARIANT choice both|auth|open (both is the default), the boolean DEPLOY_TO_STAGING_STACK (default false), the boolean ALLOW_OPEN_STIGVARS_NOT_REMOVED (default false) and the string COPY_PARALLEL (default 16)" python3 -I - "$IMPORT_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
names = [e.findtext("name") for e in r.findall(".//parameterDefinitions/*")]
assert names == ["HPDS_VARIANT", "DEPLOY_TO_STAGING_STACK", "ALLOW_OPEN_STIGVARS_NOT_REMOVED", "COPY_PARALLEL"], names
c = r.find(".//hudson.model.ChoiceParameterDefinition")
assert c.findtext("name") == "HPDS_VARIANT"
assert [s.text for s in c.iter("string")] == ["both", "auth", "open"]
bs = r.findall(".//hudson.model.BooleanParameterDefinition")
assert [b.findtext("name") for b in bs] == ["DEPLOY_TO_STAGING_STACK", "ALLOW_OPEN_STIGVARS_NOT_REMOVED"]
assert all(b.findtext("defaultValue") == "false" for b in bs)
cp = r.find(".//hudson.model.StringParameterDefinition")
assert cp.findtext("name") == "COPY_PARALLEL" and cp.findtext("defaultValue") == "16"
PY
check "Stage job: source_s3_url and destination_bucket_hash are gone from the job" test "$(grep -cE 'source_s3_url|destination_bucket_hash' "$IMPORT_XML")" = 0
check "Stage job: release-control checkout is still configured" bash -c "grep -q '<url>\${release_control_git_repo}</url>' '$IMPORT_XML' && grep -q '<name>\${release_control_git_hash}</name>' '$IMPORT_XML'"
check "Stage job: description names standalone use, the order and the rollback" bash -c "grep -q 'Run by hand' '$T/import.desc' && grep -q 'commit the new source URLs' '$T/import.desc' && grep -q 'Rollback' '$T/import.desc' && grep -q 'curated-datasets-s3-role' '$T/import.desc' && grep -q 'bdc-etl-data-d0d6191' '$T/import.desc'"
check "Stage job: removed parameters are gone from both jobs" test "$(grep -cE 'isDestigmatized|output_file_name|disable_rekey' "$IMPORT_XML" "$CFU_XML" | awk -F: '{s+=$2} END {print s}')" = 0
check "Run Rekey - Standalone is deleted" test ! -e "$JOBS/Run Rekey - Standalone"
check "no view or job references Run Rekey - Standalone" test "$(grep -rl --exclude-dir=tests 'Run Rekey - Standalone' "$HERE/.." | wc -l | tr -d ' ')" = 0
check "Stage job never references the legacy bucket" test "$(grep -c 'avillach-73-bdcatalyst-etl' "$IMPORT_XML" "$CFU_XML" | awk -F: '{s+=$2} END {print s}')" = 0

# ================================================================ renames
# The old job names are assembled here so that this file does not contain them either.
OLD_STAGE_NAME="Import_and_Rekey""_HPDS_Data"
OLD_RESTORE_NAME="Database PSQL - Dictionary Import dump ""and pg_restore"
NEW_STAGE_NAME="HPDS Data - Stage to Stack Bucket"
NEW_DEPLOY_NAME="HPDS Data - Deploy to Staging Stack"
NEW_RESTORE_NAME="Database PSQL - Dictionary Restore Dump"
if git -C "$HERE" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    check "renames: neither old job name is mentioned anywhere in the repository" bash -c "! git -C '$HERE' grep -qF --untracked -e '$OLD_STAGE_NAME' -e '$OLD_RESTORE_NAME' -- :/"
else
    echo "skip - not a git work tree, the old-name search was skipped"
fi
check "renames: the old job directories are gone" bash -c "test ! -e '$JOBS/$OLD_STAGE_NAME' && test ! -e '$JOBS/$OLD_RESTORE_NAME'"
check "renames: the new job directories exist and hold a config.xml" bash -c "test -f '$JOBS/$NEW_STAGE_NAME/config.xml' && test -f '$JOBS/$NEW_DEPLOY_NAME/config.xml' && test -f '$JOBS/$NEW_RESTORE_NAME/config.xml' && test -f '$JOBS/Check For Updates/config.xml'"
check "renames: Check For Updates keeps its name and the view list" python3 -I - "$HERE/../config.xml" "$NEW_STAGE_NAME" "$NEW_DEPLOY_NAME" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
views = {v.findtext("name"): [s.text for s in v.findall("jobNames/string")] for v in r.iter("listView")}
builds = views["PIC-SURE Builds"]
assert sys.argv[2] in builds and sys.argv[3] in builds, builds
assert builds.index(sys.argv[3]) == builds.index(sys.argv[2]) + 1, "the deploy job sits next to the stage job"
assert builds.count(sys.argv[2]) == 1 and builds.count(sys.argv[3]) == 1
assert "Check For Updates" in views["Deployment"]
PY
check "renames: the Dictionary Weights job names the renamed restore job" grep -qF "$NEW_RESTORE_NAME" "$JOBS/PIC-SURE Dictionary Weights Build and Run/config.xml"
check "renames: all four error hints in Check For Updates name the stage job, and none names another job to run" bash -c "test \"\$(grep -c 'ERROR: .*run $NEW_STAGE_NAME' '$T/cfu.sh')\" = 4 && test \"\$(grep 'ERROR: ' '$T/cfu.sh' | grep -o 'run [A-Z][A-Za-z]* [A-Za-z]*' | sort -u | tr '\\n' ,)\" = 'run HPDS Data,'"
check "renames: the descriptions point to the new names (Check For Updates to the stage job, the stage job to the deploy job)" bash -c "grep -qF '$NEW_STAGE_NAME' '$T/cfu.desc' && grep -qF '$NEW_DEPLOY_NAME' '$T/import.desc'"
LEGACY_BUCKET_WORD="avillach-73""-bdcatalyst-etl"
check "the new deploy job and the stage job never mention the legacy bucket" test "$(grep -c "$LEGACY_BUCKET_WORD" "$JOBS/$NEW_DEPLOY_NAME/config.xml" "$IMPORT_XML" | awk -F: '{s+=$2} END {print s}')" = 0

# ---- the stage job description: IAM of the dataset-prefix path
check "stage description: dataset prefixes are read through curated_datasets_s3_role, the role of the tar path" bash -c "grep -qF 'Dataset prefixes are read through curated_datasets_s3_role' '$T/import.desc' && grep -qF 'the same role as the legacy .tar path' '$T/import.desc' && grep -qF 'arn:aws:iam::515157839325:role/curated-datasets-s3-role' '$T/import.desc'"
check "stage description: the instance role writes and lists the stack bucket, the source role never touches it" bash -c "grep -qF 'the instance role writes and lists the stack bucket' '$T/import.desc' && grep -qF 'The source role is never used for the stack bucket' '$T/import.desc' && grep -qF 'sts:AssumeRole' '$T/import.desc'"
check "stage description: data streams through the Jenkins host, allow time and bandwidth" bash -c "grep -qF 'streams through the Jenkins host' '$T/import.desc' && grep -qF 'time and bandwidth' '$T/import.desc'"
check "stage description: the old server-side-copy and instance-role-reads text is gone" bash -c "! grep -qiE 'server-side copies of the|no assume_role|instance role of this Jenkins needs for the dataset-prefix path|source bucket \(bdc-etl-data-d0d6191\): s3:ListBucket' '$T/import.desc'"
check "stage description: the trust policy of the source role must allow the deploy-account instance role" bash -c "grep -qF 'trust policy of curated-datasets-s3-role in account 515157839325 must allow the deploy-account instance role' '$T/import.desc'"
check "stage description: the CLI gets the source credentials from the instance metadata (credential_source=Ec2InstanceMetadata), so IMDS must be reachable" bash -c "grep -qF 'credential_source=Ec2InstanceMetadata' '$T/import.desc' && grep -qF 'instance metadata service must be reachable from the Jenkins container' '$T/import.desc'"
check "stage job: no names, task ids or workspace notes in the description or the shell step" bash -c "! grep -qiE 'thomas|umbrella|forgejo|local forge|claude|\bT[0-9]{2}[a-z]?\b' '$T/import.desc' '$T/import.sh'"

# ================================================================ Release contract v2 (partitioned datasets)
# A v2 dataset prefix (.../data/hpds/pheno-partitioned/datasets/<id>/) has a manifest.json of schema bdc-hpds-pheno-release/2: one
# store per consent partition under phenotypic/<p>/, no removal object, no columnMeta.javabin destination. The open variant carries the
# full per-partition columnMeta (open.stigvars_removed=false) and is staged only with ALLOW_OPEN_STIGVARS_NOT_REMOVED=true.
DATASET_ID2=2026-11-17T0930Z
DATASET_URL2="s3://$SRC_BUCKET/data/hpds/pheno-partitioned/datasets/$DATASET_ID2/"
DATASET2_DIR="$FAKE_S3/$SRC_BUCKET/data/hpds/pheno-partitioned/datasets/$DATASET_ID2"
V2_OPEN_NOTE='OPEN: STIGMATIZED VARIABLES NOT REMOVED (dev only)'

# make_dataset_v2 [partitions, default 3]: a partitioned dataset with an auth and an open variant (same entries), no removal object.
# Partition names use only the placeholder accessions; with more than 3 partitions the rest are phs000000.cN.
make_dataset_v2() {
    local d="$DATASET2_DIR"
    rm -rf "$d"
    mkdir -p "$d/static"
    printf 'KEY0123' > "$d/encryption_key"
    printf '{"bio_data_catalyst":[]}' > "$d/static/metadata.json"
    printf '{"source_dataset_s3_url":"x"}\n' > "$d/build-spec.snippet.json"
    printf 'summary\n' > "$d/release-summary.txt"
    python3 -I - "$d" "${1:-3}" "$DATASET_ID2" "$DATASET_URL2" << 'PY' || { echo "cannot build the v2 fixture"; exit 1; }
import hashlib, json, os, sys
d, n, ds_id, url = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
names = ["phs000000.c1", "phs999999.c1", "phs123456.c1"][:n]
i = 2
while len(names) < n:
    names.append("phs000000.c%d" % i)
    i += 1
names.sort()

def entry(rel, **extra):
    data = open(os.path.join(d, rel), "rb").read()
    e = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "etag": '"etag-%s"' % rel}
    e.update(extra)
    return e

parts, files = [], []
for rel in ("encryption_key", "static/metadata.json", "build-spec.snippet.json", "release-summary.txt"):
    files.append(entry(rel, src=rel))
variant = [dict(src="encryption_key", dest="encryption_key", **entry("encryption_key")),
           dict(src="static/metadata.json", dest="metadata.json", **entry("static/metadata.json"))]
for p in names:
    os.makedirs(os.path.join(d, "partitions", p), exist_ok=True)
    pf = []
    for f, content in (("allObservationsStore.javabin", "AOS-" + p), ("columnMeta.javabin", "CM-" + p), ("columnMeta.csv", "concept\n")):
        with open(os.path.join(d, "partitions", p, f), "w") as fh:
            fh.write(content)
        rel = "partitions/%s/%s" % (p, f)
        pf.append(dict(name=f, **entry(rel)))
        if f != "columnMeta.csv":
            variant.append(dict(src=rel, dest="phenotypic/%s/%s" % (p, f), **entry(rel)))
    parts.append({"name": p, "rows": 1, "observations": 1, "concepts": 1, "files": pf})
key = open(os.path.join(d, "encryption_key"), "rb").read()
m = {
    "schema": "bdc-hpds-pheno-release/2", "layout": "partitioned", "dataset_id": ds_id, "url": url,
    "created_at": "2026-11-17T09:58:41Z", "created_by": {"job": "release", "build": "3"},
    "source": {"load_prefix": "s3://example/load/", "run_id": "run-1", "flow": "split", "load_manifest_sha256": "0" * 64,
               "requested_partitions": "", "loader": {"name": "CSVLoader", "jar_sha256": "0" * 64},
               "pic_sure": {"sha": "abc", "ref": "main"},
               "key": {"mode": "s3", "source": "s3://example/key", "sha256": hashlib.sha256(key).hexdigest()},
               "static_prefix": "s3://example/static/"},
    "static_set_sha256": "0" * 64,
    "totals": {"partitions": n, "rows": n, "observations": n},
    "consent_report": {"partitions": n, "fence_consents": 0, "partitions_without_fence": n, "fence_without_partition": 0},
    "open": {"stigvars_removed": False},
    "files": files, "partitions": parts,
    "variants": {"auth": variant, "open": json.loads(json.dumps(variant))},
}
with open(os.path.join(d, "manifest.json"), "w") as fh:
    json.dump(m, fh)
PY
}

# mutate_v2 <jq filter>: edit the fixture's manifest.json
mutate_v2() {
    jq "$1" "$DATASET2_DIR/manifest.json" > "$T/m2.json" && mv "$T/m2.json" "$DATASET2_DIR/manifest.json"
}
allow_flag() { export ALLOW_OPEN_STIGVARS_NOT_REMOVED=true; }
no_allow_flag() { unset ALLOW_OPEN_STIGVARS_NOT_REMOVED; }
# tsv_rows FILE: the rows of a manifest.tsv, i.e. the lines after the column header (every header line starts with #)
tsv_rows() { grep -v '^#' "$1" | tail -n +2; }
tsv_header_has() { grep -qxF -- "$2" <(grep '^#' "$1"); }

# ---- happy path: auth
reset_world
make_dataset_v2
check "v2 fixture: the manifest has no removal object (v2 never has one)" jq -e 'has("removal") | not' "$DATASET2_DIR/manifest.json"
run_import auth "$DATASET_URL2"
[ "$rc" = 0 ] && ok "v2 auth staging exits 0" || { bad "v2 auth staging (rc=$rc)"; cat "$T/err"; }
want_files="$( (jq -r '.variants.auth[].dest' "$DATASET2_DIR/manifest.json"; echo manifest.tsv) | sort | tr '\n' ' ')"
[ "$(stage_files $AUTH_DIR)" = "$want_files" ] && ok "v2 auth layout: encryption_key, metadata.json, phenotypic/<p>/{store,columnMeta}.javabin per partition, manifest.tsv" || bad "v2 auth layout: $(stage_files $AUTH_DIR)"
M2="$STAGE/$AUTH_DIR/manifest.tsv"
check "v2 manifest.tsv magic line is still bdc-hpds-deploy/1" test "$(sed -n 1p "$M2")" = "# bdc-hpds-deploy/1"
check "v2 manifest.tsv variant line" tsv_header_has "$M2" "# variant=auth"
check "v2 manifest.tsv has # layout=partitioned" tsv_header_has "$M2" "# layout=partitioned"
check "v2 manifest.tsv has # partitions=3" tsv_header_has "$M2" "# partitions=3"
check "v2 manifest.tsv has the dataset_id, source and manifest_sha256 lines" bash -c "grep -qxF '# dataset_id=$DATASET_ID2' '$M2' && grep -qxF '# source=$DATASET_URL2' '$M2' && grep -qxF '# manifest_sha256=$(sha "$DATASET2_DIR/manifest.json")' '$M2'"
check "v2 auth manifest.tsv has no stigvars lines" test "$(grep -c stigvars "$M2")" = 0
check "v2 manifest.tsv: header is 7 comment lines then the column header" test "$(grep -c '^#' "$M2")" = 7 -a "$(grep -v '^#' "$M2" | head -1)" = "$(printf 'dest\tbytes\tsha256\tetag\tsrc')"
check "v2 manifest.tsv: one row per variant entry (8 = key + metadata + 2 per partition), counted after the column header" test "$(tsv_rows "$M2" | wc -l | tr -d ' ')" = 8 -a "$(jq '.variants.auth | length' "$DATASET2_DIR/manifest.json")" = 8
check "v2 manifest.tsv: the rows are sorted by dest" bash -c "tsv_rows() { grep -v '^#' '$M2' | tail -n +2; }; tsv_rows | cut -f1 | LC_ALL=C sort -c"
check "v2 manifest.tsv: the sha256 column is a real digest in every row (never -)" test "$(tsv_rows "$M2" | cut -f3 | grep -cE '^[0-9a-f]{64}$')" = 8
check "v2 manifest.tsv: a nested row has dest, bytes, sha256, etag and src" grep -qxF "$(printf 'phenotypic/phs000000.c1/columnMeta.javabin\t%s\t%s\t"etag-partitions/phs000000.c1/columnMeta.javabin"\tpartitions/phs000000.c1/columnMeta.javabin' "$(wc -c < "$DATASET2_DIR/partitions/phs000000.c1/columnMeta.javabin" | tr -d ' ')" "$(sha "$DATASET2_DIR/partitions/phs000000.c1/columnMeta.javabin")")" "$M2"
check "v2 nested files are byte-identical to the partition files" cmp "$STAGE/$AUTH_DIR/phenotypic/phs999999.c1/allObservationsStore.javabin" "$DATASET2_DIR/partitions/phs999999.c1/allObservationsStore.javabin"
check "v2 columnMeta.csv is not staged" test "$(find "$STAGE" -name columnMeta.csv | wc -l | tr -d ' ')" = 0
check "v2 fence_mapping.json is the static metadata.json (from the dataset's metadata.json, as v1)" cmp "$STAGE/fence_mapping.json" "$DATASET2_DIR/static/metadata.json"
check "v2: the written manifest.tsv rows equal the variant entries (dest and src)" bash -c "diff <(jq -r '.variants.auth | sort_by(.dest)[] | [.dest, .src] | @tsv' '$DATASET2_DIR/manifest.json') <(grep -v '^#' '$M2' | tail -n +2 | cut -f1,5)"
check "v2: manifest.tsv is the last object written" bash -c "grep -E 'aws s3 cp (-|dataset_work/manifest.tsv) s3://' '$FAKE_AWS_LOG' | tail -1 | grep -q '/$AUTH_DIR/manifest.tsv'"
check "v2: every copy into the stack bucket uses --sse AES256" test "$(grep -E 'aws s3 cp [^ ]+ s3://' "$FAKE_AWS_LOG" | grep -vc -- '--sse AES256')" = 0
check "v2: every stream got exactly --expected-size bytes, and every v2 copy was a stream (8 files + fence_mapping.json)" test "$(grep -c '^stream ' "$FAKE_AWS_IDENTITY_LOG")" = 9
check "v2: streams are consistent with --expected-size" streams_consistent
check "v2: source reads ran as the source role, writes as the instance role, nothing leaked" test "$(count_without "$SRC_READ" "$SRC_ID")" = 0 -a "$(count_without "$DEST_WRITE" "$INST_ID")" = 0 -a "$(grep -c '^ident=leak' "$FAKE_AWS_IDENTITY_LOG")" = 0
check "v2: the byte check (head-object) ran for every file and fence_mapping.json" test "$(grep -c 's3api head-object' "$FAKE_AWS_LOG")" = 9
check "v2 auth prints no banner and writes no stigvars lines" bash -c "! grep -qF '$V2_OPEN_NOTE' '$T/out' && ! grep -q stigvars '$M2'"
run_import_in_repo auth
check "v2: a second run skips the staged variant" grep -q 'already staged, skipping' "$T/out"

# header lines and row count with more partitions: the rows are counted after the column header, not from a fixed line number
reset_world
make_dataset_v2 12
run_import auth "$DATASET_URL2"
[ "$rc" = 0 ] && ok "v2 with 12 partitions: auth staging exits 0" || { bad "v2 12 partitions (rc=$rc)"; cat "$T/err"; }
M2="$STAGE/$AUTH_DIR/manifest.tsv"
check "v2 12 partitions: # partitions=12 (distinct <p>)" tsv_header_has "$M2" "# partitions=12"
check "v2 12 partitions: 26 rows = key + metadata + 2 x 12" test "$(tsv_rows "$M2" | wc -l | tr -d ' ')" = 26
check "v2 12 partitions: the old fixed 'tail -n +7' count would be wrong (it would count the extra header lines as rows)" test "$(tail -n +7 "$M2" | wc -l | tr -d ' ')" = 28
check "v2 12 partitions: no row is a header line and no header line is a row" test "$(grep -c '^#' "$M2")" = 7 -a "$(grep -v '^#' "$M2" | wc -l | tr -d ' ')" = 27
# the row-count guard still holds for v2: a loop cut short must not publish a manifest.tsv
reset_world
make_dataset_v2
sed 's|< /dev/null||g' "$T/import.sh" > "$T/import-noredirect.sh"
export FAKE_AWS_EAT_STDIN=1 COPY_PARALLEL=1
IMPORT_SCRIPT="$T/import-noredirect.sh"
run_import auth "$DATASET_URL2"
IMPORT_SCRIPT="$T/import.sh"
unset FAKE_AWS_EAT_STDIN COPY_PARALLEL
[ "$rc" != 0 ] && grep -q 'data rows' "$T/err" && ok "v2: a short manifest.tsv is refused before upload" || bad "v2 short manifest.tsv guard (rc=$rc)"
check "v2: the short manifest.tsv was not uploaded" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv"
# a v2 stdin-eating aws does not end the loop either
reset_world
make_dataset_v2
export FAKE_AWS_EAT_STDIN=1
run_import auth "$DATASET_URL2"
unset FAKE_AWS_EAT_STDIN
[ "$rc" = 0 ] && ok "v2: aws that consumes stdin does not end the loop" || bad "v2 stdin-eating aws (rc=$rc)"

# ---- open guardrail
reset_world
make_dataset_v2
no_allow_flag
run_import open "$DATASET_URL2"
[ "$rc" != 0 ] && grep -q 'REFUSED: open: ' "$T/err" && ok "v2 open without ALLOW_OPEN_STIGVARS_NOT_REMOVED is refused" || bad "v2 open, flag off (rc=$rc)"
check "v2 open refusal names the parameter and the dataset" bash -c "grep -q 'ALLOW_OPEN_STIGVARS_NOT_REMOVED=true' '$T/err' && grep -qF '$DATASET_URL2' '$T/err'"
check "v2 open refusal copies nothing and stages nothing for open" bash -c "test ! -e '$STAGE/$OPEN_DIR' && test \$(grep -c 'aws s3 cp - ' '$FAKE_AWS_LOG') = 0"
check "v2 open refusal prints no banner" bash -c "! grep -qF '$V2_OPEN_NOTE' '$T/out'"
export ALLOW_OPEN_STIGVARS_NOT_REMOVED=false
run_import open "$DATASET_URL2"
no_allow_flag
[ "$rc" != 0 ] && grep -q 'REFUSED: open: ' "$T/err" && ok "v2 open with ALLOW_OPEN_STIGVARS_NOT_REMOVED=false is refused" || bad "v2 open, flag false (rc=$rc)"
export ALLOW_OPEN_STIGVARS_NOT_REMOVED=maybe
: > "$FAKE_AWS_LOG"
run_import auth "$DATASET_URL2"
no_allow_flag
[ "$rc" != 0 ] && grep -q "unknown ALLOW_OPEN_STIGVARS_NOT_REMOVED 'maybe'" "$T/err" && ok "an unknown ALLOW_OPEN_STIGVARS_NOT_REMOVED value is refused, for any variant" || bad "bad flag value (rc=$rc)"
check "a bad ALLOW_OPEN_STIGVARS_NOT_REMOVED makes no aws call" test ! -s "$FAKE_AWS_LOG"

reset_world
make_dataset_v2
allow_flag
run_import open "$DATASET_URL2"
no_allow_flag
[ "$rc" = 0 ] && ok "v2 open with ALLOW_OPEN_STIGVARS_NOT_REMOVED=true exits 0 (the manifest has no removal object)" || { bad "v2 open, flag on (rc=$rc)"; cat "$T/err"; }
OM2="$STAGE/$OPEN_DIR/manifest.tsv"
want_files="$( (jq -r '.variants.open[].dest' "$DATASET2_DIR/manifest.json"; echo manifest.tsv) | sort | tr '\n' ' ')"
[ "$(stage_files $OPEN_DIR)" = "$want_files" ] && ok "v2 open layout equals the auth layout: nested partitions, no conceptsToRemove.txt" || bad "v2 open layout: $(stage_files $OPEN_DIR)"
check "v2 open manifest.tsv: variant, layout and partitions lines" bash -c "grep -qxF '# variant=open' '$OM2' && grep -qxF '# layout=partitioned' '$OM2' && grep -qxF '# partitions=3' '$OM2'"
check "v2 open manifest.tsv has # stigvars_removed=false and # stigvars_override=true" bash -c "grep -qxF '# stigvars_removed=false' '$OM2' && grep -qxF '# stigvars_override=true' '$OM2'"
check "v2 open manifest.tsv: 9 comment lines, 8 rows counted after the column header" test "$(grep -c '^#' "$OM2")" = 9 -a "$(tsv_rows "$OM2" | wc -l | tr -d ' ')" = 8
check "v2 open: the open prefix carries the full per-partition columnMeta.javabin" cmp "$STAGE/$OPEN_DIR/phenotypic/phs000000.c1/columnMeta.javabin" "$DATASET2_DIR/partitions/phs000000.c1/columnMeta.javabin"
check "v2 open: a loud banner is printed" bash -c "grep -qF '$V2_OPEN_NOTE' '$T/out' && grep -q '^\*\*\*\*' '$T/out' && grep -qF 'FULL per-partition columnMeta' '$T/out'"
check "v2 open staging writes no fence_mapping.json" test ! -e "$STAGE/fence_mapping.json"
# both: auth without the stigvars lines, open with them
reset_world
make_dataset_v2
allow_flag
run_import both "$DATASET_URL2"
no_allow_flag
[ "$rc" = 0 ] && ok "v2 both with the override: exits 0" || { bad "v2 both, override (rc=$rc)"; cat "$T/err"; }
check "v2 both: auth manifest.tsv has no stigvars lines, open has both" bash -c "test \$(grep -c stigvars '$STAGE/$AUTH_DIR/manifest.tsv') = 0 && test \$(grep -c stigvars '$STAGE/$OPEN_DIR/manifest.tsv') = 2"
check "v2 both: auth first, then open (the open banner comes after the auth summary line was possible, the auth manifest first)" bash -c "
    a=\$(grep -n '/data/$C1/$AUTH_DIR/manifest.tsv' '$FAKE_AWS_LOG' | head -1 | cut -d: -f1)
    o=\$(grep -n '/data/$C1/$OPEN_DIR/' '$FAKE_AWS_LOG' | head -1 | cut -d: -f1)
    [ -n \"\$a\" ] && [ -n \"\$o\" ] && [ \"\$a\" -lt \"\$o\" ]"
check "v2 both: fence_mapping.json is written once, by auth" test "$(grep -c 's3://.*/fence_mapping.json' "$FAKE_AWS_LOG" | tr -d ' ')" = 1
# Check For Updates accepts what the stage job wrote
run_cfu
[ "$rc" = 0 ] && ok "CFU: v2 data staged by the stage job with the override passes" || { bad "CFU on v2 staged with the override (rc=$rc)"; cat "$T/err"; }
check "CFU: v2 staged data: the three keys are written" bash -c "cd '$REPO' && test -s datasetKey.txt && test -s destigmatizedDatasetKey.txt && test -s genomicDatasetKey.txt"
# the same without the override line: refused by CFU
grep -vx '# stigvars_override=true' "$STAGE/$OPEN_DIR/manifest.tsv" > "$T/open.tsv" && cp "$T/open.tsv" "$STAGE/$OPEN_DIR/manifest.tsv"
run_cfu
[ "$rc" = 1 ] && grep -q '^ERROR: open dataset is staged with stigmatized variables not removed' "$T/err" && ok "CFU: an open manifest.tsv with # stigvars_removed=false and no override line fails" || { bad "CFU without override (rc=$rc)"; cat "$T/err"; }
check "CFU: that failure names the deploy key and says nothing was scheduled" bash -c "grep -q 'deploy key $C1' '$T/err' && grep -qx 'Nothing was scheduled.' '$T/err'"
check "CFU: that failure writes no key files" cfu_no_keys
# header variants
cfu_open_header() { # <description> <expected rc> <header lines...>
    local d="$1" want="$2" l
    shift 2
    reset_world
    cfu_repo "$DATASET_URL2" "$DATASET_URL2"
    stage_manifest "$C1" javabins_rekeyed
    stage_manifest "$C1" destigmatized_javabins_rekeyed
    {
        for l in "# bdc-hpds-deploy/1" "# variant=open" "# layout=partitioned" "# partitions=3" "$@"; do printf '%s\n' "$l"; done
        printf 'dest\tbytes\tsha256\tetag\tsrc\n'
        printf 'metadata.json\t7\t%s\t"e"\tstatic/metadata.json\n' "$(printf '0%.0s' $(seq 1 64))"
    } > "$FAKE_S3/$STACK/data/$C1/$OPEN_DIR/manifest.tsv"
    run_cfu
    [ "$rc" = "$want" ] && ok "CFU: $d (rc $want)" || { bad "CFU: $d (rc=$rc, want $want)"; cat "$T/err"; }
}
cfu_open_header "open header with # stigvars_removed=false and # stigvars_override=true passes" 0 "# stigvars_removed=false" "# stigvars_override=true"
cfu_open_header "open header with # stigvars_override=true before # stigvars_removed=false passes" 0 "# stigvars_override=true" "# stigvars_removed=false"
cfu_open_header "open header with # stigvars_removed=false and no override fails" 1 "# stigvars_removed=false"
check "CFU: that failure writes no key files" cfu_no_keys
cfu_open_header "open header with # stigvars_removed=true passes (a later phase)" 0 "# stigvars_removed=true"
cfu_open_header "open header with neither line passes" 0
cfu_open_header "open header with only # stigvars_override=true passes" 0 "# stigvars_override=true"
cfu_open_header "# stigvars_removed=false as a longer value (=falsey) is not the marker" 0 "# stigvars_removed=falsey"
# only the open manifest.tsv is read: the same lines in the auth one do not matter
reset_world
cfu_repo "$DATASET_URL2" "$DATASET_URL2"
stage_manifest "$C1" javabins_rekeyed
stage_manifest "$C1" destigmatized_javabins_rekeyed
printf '# bdc-hpds-deploy/1\n# stigvars_removed=false\n' > "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed/manifest.tsv"
run_cfu
[ "$rc" = 0 ] && ok "CFU: only the open manifest.tsv header is checked" || bad "CFU auth header (rc=$rc)"
# the check is for per-file open data: a legacy open tar has no header to read
reset_world
cfu_repo "$DATASET_URL2" "$DATASET_URL2"
stage_manifest "$C1" javabins_rekeyed
stage_tar "$C1" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 0 ] && ok "CFU: an open legacy tar has no stigvars header and passes" || bad "CFU open tar (rc=$rc)"
check "CFU: an open legacy tar: the open manifest.tsv is not read" test "$(grep -c "cp s3://$STACK/data/$C1/$OPEN_DIR/manifest.tsv" "$FAKE_AWS_LOG")" = 0
# no legacy tar: the open manifest.tsv is read, whatever the listing says; the listing and the head both failing does not skip the check
reset_world
cfu_repo "$DATASET_URL2" "$DATASET_URL2"
stage_manifest "$C1" javabins_rekeyed
stage_manifest "$C1" destigmatized_javabins_rekeyed
printf '# bdc-hpds-deploy/1\n# stigvars_removed=false\n' > "$FAKE_S3/$STACK/data/$C1/$OPEN_DIR/manifest.tsv"
export FAKE_LIST_DENIED=1
run_cfu
unset FAKE_LIST_DENIED
[ "$rc" = 1 ] && grep -q '^ERROR: open dataset is staged with stigmatized variables not removed' "$T/err" && ok "CFU: with the listing denied the open manifest.tsv is still read and checked" || bad "CFU list denied, open header (rc=$rc)"
check "CFU: the open manifest.tsv is read once no legacy tar exists" test "$(grep -c "cp s3://$STACK/data/$C1/$OPEN_DIR/manifest.tsv -" "$FAKE_AWS_LOG")" = 1
# an unreadable open manifest.tsv fails closed
reset_world
cfu_repo "$DATASET_URL2" "$DATASET_URL2"
stage_manifest "$C1" javabins_rekeyed
stage_manifest "$C1" destigmatized_javabins_rekeyed
export FAKE_FAIL_READ="destigmatized_javabins_rekeyed/manifest.tsv"
run_cfu
unset FAKE_FAIL_READ
[ "$rc" = 1 ] && grep -q 'cannot read .*manifest.tsv to check its stigvars header' "$T/err" && ok "CFU: an open manifest.tsv that cannot be read fails closed" || bad "CFU unreadable open manifest.tsv (rc=$rc)"

# ---- the v1 open checks still apply to /1 and are not run for /2
reset_world
make_dataset
jq 'del(.removal)' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import open "$DATASET_URL"
[ "$rc" != 0 ] && grep -q 'REFUSED' "$T/err" && ok "v1 manifest without a removal object: open is still refused" || bad "v1 open without removal (rc=$rc)"
allow_flag
run_import open "$DATASET_URL"
no_allow_flag
[ "$rc" != 0 ] && grep -q 'open variant would ship the full columnMeta.javabin' "$T/err" && ok "v1 open without removal is refused even with ALLOW_OPEN_STIGVARS_NOT_REMOVED=true (the flag is v2 only)" || bad "v1 open, flag on (rc=$rc)"
reset_world
make_dataset same
allow_flag
run_import open "$DATASET_URL"
no_allow_flag
[ "$rc" != 0 ] && ok "v1 open with equal columnMeta shas is refused with the flag on" || bad "v1 equal shas, flag on (rc=$rc)"
reset_world
make_dataset
jq '.variants.auth += [{"src":"open/columnMeta.javabin","dest":"extra.javabin","bytes":15,"sha256":null,"etag":null}]' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && grep -q 'must not use files from open/' "$T/err" && ok "v1 auth with an open/ file is still refused" || bad "v1 auth open/ (rc=$rc)"
reset_world
make_dataset
jq '.variants.auth |= map(select(.dest != "columnMeta.javabin"))' "$DATASET_DIR/manifest.json" > "$T/m.json" && mv "$T/m.json" "$DATASET_DIR/manifest.json"
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && ok "v1 manifest without a columnMeta.javabin dest is still refused" || bad "v1 without columnMeta.javabin (rc=$rc)"
# a v1 open variant (rule (c) mixed form) is staged with its removal checks, next to a partitioned auth variant
reset_world
make_dataset
make_dataset_v2
run_import both "$DATASET_URL2" "$DATASET_URL"
[ "$rc" = 0 ] && ok "mixed form: v2 auth with a v1 open prefix stages (no flag needed, the open data is v1)" || { bad "mixed form (rc=$rc)"; cat "$T/err"; }
check "mixed form: auth is partitioned, open is the flat v1 layout" bash -c "grep -qxF '# layout=partitioned' '$STAGE/$AUTH_DIR/manifest.tsv' && ! grep -q '^# layout' '$STAGE/$OPEN_DIR/manifest.tsv' && test -f '$STAGE/$OPEN_DIR/columnMeta.javabin' && test -f '$STAGE/$AUTH_DIR/phenotypic/phs000000.c1/columnMeta.javabin'"
check "mixed form: the open manifest.tsv has the five v1 comment lines and no stigvars lines" test "$(grep -c '^#' "$STAGE/$OPEN_DIR/manifest.tsv")" = 5 -a "$(grep -c stigvars "$STAGE/$OPEN_DIR/manifest.tsv")" = 0
run_cfu
[ "$rc" = 0 ] && ok "mixed form: CFU accepts the staged data" || { bad "mixed form CFU (rc=$rc)"; cat "$T/err"; }
# class and schema must agree
reset_world
make_dataset
make_dataset_v2
cp "$DATASET2_DIR/manifest.json" "$DATASET_DIR/manifest.json"
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && grep -q 'is schema bdc-hpds-pheno-release/2 but the URL is not a partitioned' "$T/err" && ok "a v2 manifest at a v1 prefix is refused" || bad "v2 manifest, v1 URL (rc=$rc)"
check "a v2 manifest at a v1 prefix stages nothing" test ! -e "$STAGE/$AUTH_DIR"
make_dataset
cp "$DATASET_DIR/manifest.json" "$T/v1manifest.json"
make_dataset_v2
cp "$T/v1manifest.json" "$DATASET2_DIR/manifest.json"
run_import auth "$DATASET_URL2"
[ "$rc" != 0 ] && grep -q 'partitioned (v2) dataset prefix but its manifest.json is schema bdc-hpds-pheno-release/1' "$T/err" && ok "a v1 manifest at a v2 prefix is refused" || bad "v1 manifest, v2 URL (rc=$rc)"
check "a v1 manifest at a v2 prefix stages nothing" test ! -e "$STAGE/$AUTH_DIR"
reset_world
make_dataset_v2
mutate_v2 '.schema = "bdc-hpds-pheno-release/3"'
run_import auth "$DATASET_URL2"
[ "$rc" != 0 ] && grep -q "has schema 'bdc-hpds-pheno-release/3'" "$T/err" && ok "an unknown schema is refused with the schema named" || bad "schema /3 (rc=$rc)"

# ---- /2 refusals (the deploy-side subset of the validator); every one stages nothing and copies nothing
ZERO64="$(printf '0%.0s' $(seq 1 64))"
v2_refuses() { # <what> <variant> <override flag: true|""> <jq filter> [message fragment]
    local what="$1" v="$2" flag="$3" filter="$4" frag="${5:-not a valid bdc-hpds-pheno-release/2}" sd="$AUTH_DIR"
    [ "$v" != open ] || sd="$OPEN_DIR"
    reset_world
    make_dataset_v2
    mutate_v2 "$filter"
    if [ -n "$flag" ]; then allow_flag; else no_allow_flag; fi
    run_import "$v" "$DATASET_URL2"
    no_allow_flag
    if [ "$rc" != 0 ] && grep -q '^REFUSED: ' "$T/err" && grep -qF "$frag" "$T/err" && [ ! -e "$STAGE/$sd/manifest.tsv" ] && [ "$(grep -c 'aws s3 cp - ' "$FAKE_AWS_LOG")" = 0 ]; then
        ok "v2 refused ($v): $what"
    else
        bad "v2 refused ($v): $what (rc=$rc)"
        head -3 "$T/err"
    fi
}
v2_refuses "layout is not partitioned" auth "" '.layout = "flat"'
v2_refuses "no layout" auth "" 'del(.layout)'
v2_refuses "a store dest at the top level" auth "" '.variants.auth[2].dest = "allObservationsStore.javabin"'
v2_refuses "a columnMeta.javabin dest at the top level" auth "" '.variants.auth[3].dest = "columnMeta.javabin"'
v2_refuses "a columnMeta.csv entry" auth "" '.variants.auth += [{"src":"partitions/phs000000.c1/columnMeta.csv","dest":"phenotypic/phs000000.c1/columnMeta.csv","bytes":8,"sha256":.files[0].sha256,"etag":"\"x\""}]'
v2_refuses "an all/ dest" auth "" '.variants.auth[2].dest = "all/phs000000.c1/allObservationsStore.javabin"'
v2_refuses "a conceptsToRemove.txt entry" auth "" '.variants.auth += [{"src":"static/conceptsToRemove.txt","dest":"conceptsToRemove.txt","bytes":1,"sha256":.files[0].sha256,"etag":"\"x\""}]'
v2_refuses "an open/ src" auth "" '.variants.auth[3].src = "open/partitions/phs000000.c1/columnMeta.javabin"'
v2_refuses "a missing encryption_key entry" auth "" '.variants.auth |= map(select(.src != "encryption_key"))'
v2_refuses "a missing partition file entry" auth "" '.variants.auth |= .[0:7]'
v2_refuses "a duplicate entry" auth "" '.variants.auth += [.variants.auth[2]]'
v2_refuses "a null sha256 on a store" auth "" '.partitions[0].files[0].sha256 = null | .variants.auth[2].sha256 = null'
v2_refuses "a null sha256 on the key" auth "" '.files[0].sha256 = null | .variants.auth[0].sha256 = null'
v2_refuses "a sha256 that is not hex" auth "" '.partitions[0].files[0].sha256 = "xyz" | .variants.auth[2].sha256 = "xyz"'
v2_refuses "an uppercase sha256" auth "" '.partitions[0].files[1].sha256 |= ascii_upcase | .variants.auth[3].sha256 |= ascii_upcase'
v2_refuses "the encryption_key sha256 differs from source.key.sha256" auth "" ".source.key.sha256 = \"$ZERO64\""
v2_refuses "no source.key.sha256" auth "" 'del(.source.key.sha256)'
v2_refuses "an entry sha256 differs from its partitions[] entry" auth "" ".variants.auth[2].sha256 = \"$ZERO64\""
v2_refuses "an entry bytes differs from its partitions[] entry" auth "" '.variants.auth[2].bytes = 999'
v2_refuses "an entry etag differs from its partitions[] entry" auth "" '.variants.auth[2].etag = "\"other\""'
v2_refuses "a non-integer bytes" auth "" '.variants.auth[2].bytes = 1.5 | .partitions[0].files[0].bytes = 1.5'
v2_refuses "an empty etag" auth "" '.variants.auth[2].etag = "" | .partitions[0].files[0].etag = ""'
v2_refuses "a path traversal dest" auth "" '.variants.auth[2].dest = "phenotypic/../x"'
v2_refuses "a path traversal src" auth "" '.variants.auth[2].src = "partitions/../x"'
v2_refuses "an absolute dest" auth "" '.variants.auth[2].dest = "/phenotypic/phs000000.c1/allObservationsStore.javabin"'
v2_refuses "a partition name with .." auth "" '.partitions[0].name = ".."'
v2_refuses "a partition name that starts with a dot" auth "" '.partitions[0].name = ".hidden"'
v2_refuses "a partition name with a slash" auth "" '.partitions[0].name = "a/b"'
v2_refuses "a partition name longer than 128 characters" auth "" ".partitions[0].name = \"$(printf 'a%.0s' $(seq 1 129))\""
v2_refuses "a repeated partition name" auth "" '.partitions[1].name = .partitions[0].name'
v2_refuses "no partitions" auth "" '.partitions = [] | .variants.auth |= .[0:2]'
v2_refuses "a partition that is not in the variant" auth "" '.partitions += [{"name":"phs999999.c9","files":[]}]'
v2_refuses "a malformed dataset_id" auth "" '.dataset_id = "x"'
v2_refuses "open.stigvars_removed is true (a later phase; refused for auth too)" auth "" '.open.stigvars_removed = true'
v2_refuses "open.stigvars_removed is missing" auth "" 'del(.open.stigvars_removed)'
v2_refuses "open.stigvars_removed is a string" auth "" '.open.stigvars_removed = "false"'
v2_refuses "open.stigvars_removed is true for the open variant, flag on" open true '.open.stigvars_removed = true'
v2_refuses "no open object for the open variant, flag on" open true 'del(.open)'
v2_refuses "no variants.open for HPDS_VARIANT=open, flag on" open true 'del(.variants.open)'
v2_refuses "no variants.open and no open object for HPDS_VARIANT=open, flag on" open true 'del(.variants.open) | del(.open)'
v2_refuses "an open variant missing a partition file, flag on" open true '.variants.open |= .[0:7]'
v2_refuses "an open variant with a top-level store, flag on" open true '.variants.open[2].dest = "allObservationsStore.javabin"'
v2_refuses "an open variant with a columnMeta.javabin dest (v1 shape), flag on" open true '.variants.open += [{"src":"partitions/phs000000.c1/columnMeta.javabin","dest":"columnMeta.javabin","bytes":14,"sha256":.variants.open[3].sha256,"etag":.variants.open[3].etag}]'
# an invalid open variant is refused for auth too (the manifest is checked as a whole) and a valid auth next to a broken open is not staged in a refused run
v2_refuses "a broken open variant also refuses an auth run (subset D is a manifest check)" auth "" '.variants.open |= .[0:7]'
v2_refuses "an extra variant key" auth "" '.variants.extra = .variants.auth'
v2_refuses "an extra variant key next to auth only" auth "" 'del(.variants.open) | del(.open) | .variants.extra = .variants.auth'
v2_refuses "variants.open without an open object (auth run)" auth "" 'del(.open)'
v2_refuses "variants.open without an open object (open run, flag on)" open true 'del(.open)'
v2_refuses "an open object without variants.open (auth run)" auth "" 'del(.variants.open)'
v2_refuses "no variants.auth (auth run)" auth "" 'del(.variants.auth)'
v2_refuses "no variants.auth (open run, flag on)" open true 'del(.variants.auth)'
v2_refuses "variants.auth is null" open true '.variants.auth = null'
v2_refuses "variants is empty" auth "" '.variants = {}'
v2_refuses "variants.auth is not an array" auth "" '.variants.auth = {}'
# open variant only needs the override for open: auth next to a variants.open-less manifest is fine
reset_world
make_dataset_v2
mutate_v2 'del(.variants.open) | del(.open)'
run_import auth "$DATASET_URL2"
[ "$rc" = 0 ] && ok "v2 auth is staged from a manifest with no open variant" || { bad "v2 auth, no open variant (rc=$rc)"; cat "$T/err"; }
no_allow_flag
run_import_in_repo open
[ "$rc" != 0 ] && grep -q 'REFUSED' "$T/err" && ok "v2 open on a manifest with no open variant is refused" || bad "v2 open, no open variant (rc=$rc)"

# a v2 prefix without the override: the open refusal comes up front, before anything (auth included) is staged
reset_world
make_dataset_v2
no_allow_flag
run_import both "$DATASET_URL2"
[ "$rc" != 0 ] && grep -q 'REFUSED: open: ' "$T/err" && ok "v2 both without the override: the open refusal ends the build non-zero" || bad "v2 both, no override (rc=$rc)"
check "v2 both without the override: nothing is staged, not even auth, and no copy or source read is made (only the staged-marker lookups)" bash -c "test ! -e '$STAGE' && test \$(grep -c 'aws s3 cp\|sts ' '$FAKE_AWS_LOG') = 0 && test \$(grep -vc 's3api list-objects-v2' '$FAKE_AWS_LOG') = 0"
check "v2 both without the override: no Next line" test "$(grep -c '^Next:' "$T/out")" = 0
# an open variant that is already staged is skipped and needs no override, so auth can still be staged on its own run
reset_world
make_dataset_v2
allow_flag
run_import open "$DATASET_URL2"
no_allow_flag
run_import_in_repo both
[ "$rc" = 0 ] && ok "v2 both without the override, open already staged: auth is staged, open is skipped (rc 0)" || { bad "v2 both, open already staged (rc=$rc)"; cat "$T/err"; }
check "v2 both without the override, open already staged: both are staged" test -f "$STAGE/$AUTH_DIR/manifest.tsv" -a -f "$STAGE/$OPEN_DIR/manifest.tsv"
# the up-front refusal applies to a v2 prefix only: a v1 prefix for open needs no flag (mixed form)
reset_world
make_dataset
make_dataset_v2
no_allow_flag
run_import both "$DATASET_URL2" "$DATASET_URL"
[ "$rc" = 0 ] && ok "v2 auth with a v1 open prefix needs no override (rc 0)" || bad "mixed form without the override (rc=$rc)"

# fence_mapping.json repair works on v2 data (restored from the staged metadata.json)
reset_world
make_dataset_v2
run_import auth "$DATASET_URL2"
rm -f "${STAGE:?}/fence_mapping.json"
: > "$FAKE_AWS_LOG"
run_import_in_repo auth
[ "$rc" = 0 ] && grep -qx 'fence_mapping.json restored from the staged metadata.json' "$T/out" && ok "v2: a missing fence_mapping.json is restored from the staged metadata.json" || bad "v2 fence repair (rc=$rc)"
check "v2: the restored fence_mapping.json is the staged metadata.json" cmp "$STAGE/fence_mapping.json" "$STAGE/$AUTH_DIR/metadata.json"

# a failure in the middle of a v2 stage leaves no manifest.tsv, the retry completes it
reset_world
make_dataset_v2
export FAKE_FAIL_COPY=phs999999.c1/columnMeta.javabin
run_import auth "$DATASET_URL2"
unset FAKE_FAIL_COPY
[ "$rc" != 0 ] && ok "v2: a failing copy of one partition file fails the build" || bad "v2 failing copy (rc=$rc)"
check "v2 partial stage: no manifest.tsv, earlier files are there" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv" -a -f "$STAGE/$AUTH_DIR/encryption_key"
run_import_in_repo auth
[ "$rc" = 0 ] && test -f "$STAGE/$AUTH_DIR/manifest.tsv" && ok "v2: the retry over a partial stage succeeds" || bad "v2 retry (rc=$rc)"
reset_world
make_dataset_v2
export FAKE_CORRUPT_COPY=phs123456.c1/allObservationsStore.javabin
run_import auth "$DATASET_URL2"
unset FAKE_CORRUPT_COPY
[ "$rc" != 0 ] && grep -q 'manifest says' "$T/err" && ok "v2: a byte-count mismatch after a nested copy fails the build" || bad "v2 byte mismatch (rc=$rc)"
check "v2 byte mismatch: no manifest.tsv" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv"

# ---- the URL rule matrix (shared block of the stage job and Check For Updates)
V1A="$DATASET_URL"
V1B="s3://$SRC_BUCKET/data/hpds/pheno/datasets/2026-11-05T0000Z/"
V2A="$DATASET_URL2"
V2B="s3://$SRC_BUCKET/data/hpds/pheno-partitioned/datasets/2026-11-18T0000Z/"
TARA="s3://example-bucket/legacy/final.tar"
TARB="s3://example-bucket/legacy/final-destig.tar"
# run_cfu_keep: run_cfu, keeping its stderr (the stage job overwrites $T/err)
run_cfu_keep() { run_cfu; cp "$T/err" "$T/err.cfu"; }
url_rule_matrix() {
    local verdict="$1" a="$2" o="$3" label="$4"
    reset_world
    cfu_repo "$a" "$o"
    stage_manifest "$C1" javabins_rekeyed
    stage_manifest "$C1" destigmatized_javabins_rekeyed
    run_cfu_keep
    local cfu_rc=$rc
    : > "$FAKE_AWS_LOG"
    run_import_in_repo both
    local imp_rc=$rc
    if [ "$verdict" = allowed ]; then
        [ "$cfu_rc" = 0 ] && [ "$imp_rc" = 0 ] && ok "URL rule: $label is allowed (CFU and stage job)" || { bad "URL rule: $label allowed (CFU rc=$cfu_rc, stage rc=$imp_rc)"; cat "$T/err.cfu" "$T/err"; }
    else
        [ "$cfu_rc" != 0 ] && grep -q 'must be identical for a dataset prefix; allowed: ' "$T/err.cfu" && grep -qF "($a)" "$T/err.cfu" && grep -qF "($o)" "$T/err.cfu" && ok "URL rule: $label is refused naming both URLs and the allowed forms (CFU)" || bad "URL rule: $label refused (CFU rc=$cfu_rc)"
        [ "$imp_rc" != 0 ] && grep -q 'must be identical for a dataset prefix; allowed: ' "$T/err" && grep -qF "($a)" "$T/err" && grep -qF "($o)" "$T/err" && ok "URL rule: $label is refused naming both URLs and the allowed forms (stage job)" || bad "URL rule: $label refused (stage rc=$imp_rc)"
        [ ! -s "$FAKE_AWS_LOG" ] && ok "URL rule: $label: the stage job refuses before any aws call" || bad "URL rule: $label: the stage job made aws calls"
        cfu_no_keys && ok "URL rule: $label: CFU writes no key files" || bad "URL rule: $label: CFU wrote key files"
    fi
}
url_rule_matrix allowed "$V1A" "$V1A" "same v1 prefix twice (a)"
url_rule_matrix allowed "$V2A" "$V2A" "same v2 prefix twice (b)"
url_rule_matrix allowed "$V2A" "$V1A" "v2 auth with v1 open (c)"
url_rule_matrix allowed "$V2B" "$V1B" "another v2 auth with another v1 open (c)"
url_rule_matrix allowed "$TARA" "$TARB" "two different tars (no check)"
url_rule_matrix allowed "$TARA" "$TARA" "the same tar twice (no check)"
url_rule_matrix refused "$V1A" "$V2A" "v1 auth with v2 open"
url_rule_matrix refused "$V2A" "$V2B" "two different v2 prefixes"
url_rule_matrix refused "$V2A" "$TARA" "v2 auth with a tar"
url_rule_matrix refused "$TARA" "$V2A" "a tar with v2 open"
url_rule_matrix refused "$V1A" "$V1B" "two different v1 prefixes"
url_rule_matrix refused "$V1A" "$TARA" "v1 auth with a tar"
url_rule_matrix refused "$TARA" "$V1A" "a tar with v1 open"
url_rule_matrix refused "$V1A" "$V2B" "v1 auth with another v2 open"
BOTH_MARKERS="${V1A}${V2A#s3://}"
reset_world
cfu_repo "$BOTH_MARKERS" "$BOTH_MARKERS"
run_cfu
[ "$rc" != 0 ] && grep -q 'names both a v1 and a v2 dataset prefix' "$T/err" && ok "URL rule: one URL that names both a v1 and a v2 prefix is refused (CFU)" || bad "both markers, CFU (rc=$rc)"
run_import_in_repo both
[ "$rc" != 0 ] && grep -q 'names both a v1 and a v2 dataset prefix' "$T/err" && ok "URL rule: one URL that names both a v1 and a v2 prefix is refused (stage job)" || bad "both markers, stage (rc=$rc)"
check "the stage job and CFU print the same v2 rule text" bash -c "grep -F 'allowed: the same v1 prefix' '$T/shared.import' | head -1 | cmp -s - <(grep -F 'allowed: the same v1 prefix' '$T/shared.cfu' | head -1)"

# ---- descriptions and parameter
check "stage job: the ALLOW_OPEN_STIGVARS_NOT_REMOVED parameter says dev only, refuse by default, and what it writes" python3 -I - "$IMPORT_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
b = [e for e in r.findall(".//hudson.model.BooleanParameterDefinition") if e.findtext("name") == "ALLOW_OPEN_STIGVARS_NOT_REMOVED"][0]
d = " ".join(b.findtext("description").split())
assert b.findtext("defaultValue") == "false"
for w in ("Dev stacks only", "Default false", "refuses it", "stigvars_removed=false", "stigvars_override=true", "banner"):
    assert w in d, w
PY
check "stage description: names v2, the guardrail, the extra header lines, the URL pairs and the rollback" bash -c "for w in 'bdc-hpds-pheno-release/2' 'ALLOW_OPEN_STIGVARS_NOT_REMOVED (default false)' 'REFUSES to stage it' '# layout=partitioned' '# partitions=N' 'the same v2 prefix for both lines' 'a v2 prefix as source_dataset_s3_url with a v1 prefix' 'Rollback from v2' 'pheno-partitioned/datasets'; do grep -qF -- \"\$w\" '$T/import.desc' || { echo missing: \$w; exit 1; }; done"
check "CFU description: names the URL rule and the open header check" bash -c "for w in 'v2 (partitioned) prefix' '# stigvars_removed=false' '# stigvars_override=true' 'ALLOW_OPEN_STIGVARS_NOT_REMOVED'; do grep -qF -- \"\$w\" '$T/cfu.desc' || { echo missing: \$w; exit 1; }; done"
check "stage job: v2 adds no job step: the Groovy deploy step is the only SystemGroovy step (no new script to approve)" python3 -I - "$IMPORT_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
assert len(r.findall(".//builders/hudson.plugins.groovy.SystemGroovy")) == 1
PY
check "stage job: no personal names, task ids or notes in the v2 description or shell step" bash -c "! grep -qiE 'thomas|umbrella|forgejo|claude|/Users/' '$T/import.desc' '$T/import.sh' '$T/cfu.desc' '$T/cfu.sh'"
check "stage job: fixtures and shell step use no real accession (only phs000000, phs999999, phs123456)" bash -c "! grep -ohE 'phs[0-9]{6}' '$T/import.sh' '$T/cfu.sh' | grep -vE '^phs(000000|999999|123456)\$'"

# ================================================================ COPY_PARALLEL (the files of a variant are copied at the same time)
# tree_digest: every object of the fake stack bucket with its content digest (what was staged, byte for byte)
tree_digest() { (cd "$FAKE_S3/$STACK" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(sha "$f")"; done); }
# max_running FILE: the largest number of writes that were running at the same time (FAKE_CONC_LOG: start/end lines)
max_running() { awk '/^start/ { c++; if (c > m) m = c } /^end/ { c-- } END { print m + 0 }' "$1"; }
# stream_end_order: the destinations in the order their streams ended (the fence mapping copy is left out)
stream_end_order() { grep '^stream to=' "$FAKE_AWS_IDENTITY_LOG" | grep -v fence_mapping.json | sed 's|^stream to=s3://[^/]*/data/[^/]*/[^/]*/||; s| .*||'; }

# ---- v2: COPY_PARALLEL=1 and 32 stage the same objects and the same manifest.tsv, whatever order the copies end in
reset_world
make_dataset_v2 12
export COPY_PARALLEL=1
run_import auth "$DATASET_URL2"
[ "$rc" = 0 ] && ok "COPY_PARALLEL=1, v2 12 partitions: auth staging exits 0" || { bad "COPY_PARALLEL=1 v2 (rc=$rc)"; cat "$T/err"; }
tree_digest > "$T/tree.p1"
cp "$STAGE/$AUTH_DIR/manifest.tsv" "$T/manifest.p1"
check "COPY_PARALLEL=1: the summary line gives files, bytes, seconds and the parallelism" grep -q '^Copied 26 files, [0-9]* bytes, in [0-9]* s (COPY_PARALLEL=1)$' "$T/out"
rm -rf "$FAKE_S3/$STACK"
export COPY_PARALLEL=32 FAKE_SLOW_COPY=encryption_key FAKE_SLOW_SECS=3
: > "$FAKE_AWS_IDENTITY_LOG"
: > "$FAKE_AWS_LOG"
run_import_in_repo auth
unset FAKE_SLOW_COPY FAKE_SLOW_SECS
[ "$rc" = 0 ] && ok "COPY_PARALLEL=32, v2 12 partitions: auth staging exits 0" || { bad "COPY_PARALLEL=32 v2 (rc=$rc)"; cat "$T/err"; }
tree_digest > "$T/tree.p8"
check "COPY_PARALLEL 1 vs 32 (v2): the staged objects are identical (names and bytes, fence_mapping.json included)" cmp "$T/tree.p1" "$T/tree.p8"
check "COPY_PARALLEL 1 vs 32 (v2): the manifest.tsv files are byte-identical" cmp "$T/manifest.p1" "$STAGE/$AUTH_DIR/manifest.tsv"
check "COPY_PARALLEL=32 (v2): the staging tree has 26 files + manifest.tsv + fence_mapping.json" test "$(wc -l < "$T/tree.p8" | tr -d ' ')" = 28
check "COPY_PARALLEL=32 (v2): the rows are sorted by dest" bash -c "grep -v '^#' '$STAGE/$AUTH_DIR/manifest.tsv' | tail -n +2 | cut -f1 | LC_ALL=C sort -c"
check "COPY_PARALLEL=32 (v2): encryption_key is the first row although its copy ended last (rows follow the entries, not the completion order)" test "$(tsv_rows "$STAGE/$AUTH_DIR/manifest.tsv" | head -1 | cut -f1)" = encryption_key -a "$(stream_end_order | tail -1)" = encryption_key
check "COPY_PARALLEL=32 (v2): the copies did not end in manifest order" test "$(stream_end_order | head -3 | tr '\n' ' ')" != "$(tsv_rows "$STAGE/$AUTH_DIR/manifest.tsv" | head -3 | cut -f1 | tr '\n' ' ')"
check "COPY_PARALLEL=32 (v2): fence_mapping.json is the static metadata.json" cmp "$STAGE/fence_mapping.json" "$DATASET2_DIR/static/metadata.json"
check "COPY_PARALLEL=32 (v2): every file was byte checked (26 + fence_mapping.json head-object calls)" test "$(grep -c 's3api head-object' "$FAKE_AWS_LOG")" = 27
check "COPY_PARALLEL=32 (v2): source reads ran as the source role (private profile file), writes as the instance role, nothing leaked" test "$(count_without "$SRC_READ" "$SRC_ID")" = 0 -a "$(count_without "$DEST_WRITE" "$INST_ID")" = 0 -a "$(grep -c '^ident=leak' "$FAKE_AWS_IDENTITY_LOG")" = 0 -a "$(grep -c 'cfg=bad' "$FAKE_AWS_IDENTITY_LOG")" = 0
check "COPY_PARALLEL=32 (v2): every stream got --expected-size equal to its bytes" streams_consistent
check "COPY_PARALLEL=32 (v2): manifest.tsv is the last object written" bash -c "grep -E 'aws s3 cp (-|dataset_work/manifest.tsv) s3://' '$FAKE_AWS_LOG' | tail -1 | grep -q '/$AUTH_DIR/manifest.tsv'"
check "COPY_PARALLEL=32 (v2): the temporary profile file is gone" tmp_is_empty
# the log: one whole line per entry, and the summary
check "COPY_PARALLEL=32 (v2): one 'staging' line per entry (26), none twice, none cut" bash -c "test \$(grep -c '^staging .* -> .* ([0-9]* bytes)\$' '$T/out') = 26 && test -z \"\$(grep '^staging ' '$T/out' | sort | uniq -d)\" && test \$(grep -c '^staging ' '$T/out') = 26"
check "COPY_PARALLEL=32 (v2): every line of the build output is a whole known line" bash -c "! grep -vE '^(staging .* -> .* \([0-9]+ bytes\)|auth: staging .*|auth: staged .*|Copied 26 files, [0-9]+ bytes, in [0-9]+ s \(COPY_PARALLEL=32\)|Staged auth from .*|Next: .*)\$' '$T/out'"
check "COPY_PARALLEL=32 (v2): the summary names the files and the bytes of the variant" grep -qE "^Copied 26 files, $(jq '[.variants.auth[].bytes] | add' "$DATASET2_DIR/manifest.json") bytes, in [0-9]+ s \(COPY_PARALLEL=32\)\$" "$T/out"
check "COPY_PARALLEL=32 (v2): the summary comes before the Staged line" bash -c "test \$(grep -n '^Copied ' '$T/out' | cut -d: -f1) -lt \$(grep -n '^Staged auth' '$T/out' | cut -d: -f1)"
# random copy times instead of one slow file
rm -rf "$FAKE_S3/$STACK"
export COPY_PARALLEL=16 FAKE_JITTER=1
run_import_in_repo auth
unset FAKE_JITTER
[ "$rc" = 0 ] && ok "COPY_PARALLEL=16 with random copy times: auth staging exits 0" || { bad "COPY_PARALLEL=16 jitter (rc=$rc)"; cat "$T/err"; }
tree_digest > "$T/tree.p16"
check "COPY_PARALLEL=16 with random copy times: the staged objects are identical to those of COPY_PARALLEL=1" cmp "$T/tree.p1" "$T/tree.p16"
check "COPY_PARALLEL=16 with random copy times: manifest.tsv is byte-identical to that of COPY_PARALLEL=1" cmp "$T/manifest.p1" "$STAGE/$AUTH_DIR/manifest.tsv"
# the default (no COPY_PARALLEL, or an empty one): 16
unset COPY_PARALLEL
rm -rf "$FAKE_S3/$STACK"
run_import_in_repo auth
check "COPY_PARALLEL unset: 16 copies at a time, same manifest.tsv" bash -c "test $rc = 0 && grep -q '(COPY_PARALLEL=16)\$' '$T/out' && cmp '$T/manifest.p1' '$STAGE/$AUTH_DIR/manifest.tsv'"
export COPY_PARALLEL=""
rm -rf "$FAKE_S3/$STACK"
run_import_in_repo auth
check "COPY_PARALLEL empty: the default, 16" bash -c "test $rc = 0 && grep -q '(COPY_PARALLEL=16)\$' '$T/out'"
unset COPY_PARALLEL

# ---- v1 (flat): both variants; the manifest order is kept (it is not sorted), whatever order the copies end in
reset_world
make_dataset
export COPY_PARALLEL=1
run_import both "$DATASET_URL"
[ "$rc" = 0 ] && ok "COPY_PARALLEL=1, v1: both variants stage" || { bad "COPY_PARALLEL=1 v1 (rc=$rc)"; cat "$T/err"; }
tree_digest > "$T/tree.v1p1"
cp "$STAGE/$AUTH_DIR/manifest.tsv" "$T/manifest.v1p1.auth"
cp "$STAGE/$OPEN_DIR/manifest.tsv" "$T/manifest.v1p1.open"
rm -rf "$FAKE_S3/$STACK"
export COPY_PARALLEL=8 FAKE_SLOW_COPY=allObservationsStore.javabin
: > "$FAKE_AWS_LOG"
run_import_in_repo both
unset FAKE_SLOW_COPY COPY_PARALLEL
[ "$rc" = 0 ] && ok "COPY_PARALLEL=8, v1: both variants stage" || { bad "COPY_PARALLEL=8 v1 (rc=$rc)"; cat "$T/err"; }
tree_digest > "$T/tree.v1p8"
check "COPY_PARALLEL 1 vs 8 (v1): the staged objects are identical" cmp "$T/tree.v1p1" "$T/tree.v1p8"
check "COPY_PARALLEL 1 vs 8 (v1): the auth manifest.tsv files are byte-identical" cmp "$T/manifest.v1p1.auth" "$STAGE/$AUTH_DIR/manifest.tsv"
check "COPY_PARALLEL 1 vs 8 (v1): the open manifest.tsv files are byte-identical" cmp "$T/manifest.v1p1.open" "$STAGE/$OPEN_DIR/manifest.tsv"
check "COPY_PARALLEL=8 (v1): the auth rows keep the manifest order (not sorted by dest)" test "$(tsv_rows "$STAGE/$AUTH_DIR/manifest.tsv" | cut -f1 | tr '\n' ' ')" = "$(jq -r '.variants.auth[].dest' "$DATASET_DIR/manifest.json" | tr '\n' ' ')"
check "COPY_PARALLEL=8 (v1): the open rows keep the manifest order too" test "$(tsv_rows "$STAGE/$OPEN_DIR/manifest.tsv" | cut -f1 | tr '\n' ' ')" = "$(jq -r '.variants.open[].dest' "$DATASET_DIR/manifest.json" | tr '\n' ' ')"
check "COPY_PARALLEL=8 (v1): fence_mapping.json is written once, by auth" test "$(grep -c 's3://.*/fence_mapping.json' "$FAKE_AWS_LOG" | tr -d ' ')" = 1
check "COPY_PARALLEL=8 (v1): one summary line per variant" test "$(grep -c '^Copied [0-9]* files, [0-9]* bytes, in [0-9]* s (COPY_PARALLEL=8)$' "$T/out")" = 2

# ---- bounded parallelism: never more copies at the same time than COPY_PARALLEL, and really more than one
reset_world
make_dataset_v2 12
export FAKE_SLOW_COPY=phenotypic FAKE_CONC_LOG="$T/conc.log" COPY_PARALLEL=4
: > "$FAKE_CONC_LOG"
run_import auth "$DATASET_URL2"
[ "$rc" = 0 ] && ok "COPY_PARALLEL=4 with slow copies: exits 0" || { bad "COPY_PARALLEL=4 slow (rc=$rc)"; cat "$T/err"; }
m="$(max_running "$FAKE_CONC_LOG")"
[ "$m" -le 4 ] && [ "$m" -ge 2 ] && ok "COPY_PARALLEL=4: at most 4 copies at the same time (saw $m), and more than one" || bad "COPY_PARALLEL=4 concurrency (saw $m)"
export COPY_PARALLEL=1
: > "$FAKE_CONC_LOG"
rm -rf "$FAKE_S3/$STACK"
run_import_in_repo auth
check "COPY_PARALLEL=1: one copy at a time" test "$rc" = 0 -a "$(max_running "$FAKE_CONC_LOG")" = 1
check "COPY_PARALLEL=1: the staging lines are in manifest order" test "$(grep '^staging ' "$T/out" | sed 's/^staging .* -> \(.*\) (.*/\1/' | tr '\n' ' ')" = "$(tsv_rows "$STAGE/$AUTH_DIR/manifest.tsv" | cut -f1 | tr '\n' ' ')"
unset FAKE_SLOW_COPY FAKE_CONC_LOG COPY_PARALLEL

# ---- a failed copy among many fails the variant and publishes nothing
reset_world
make_dataset_v2 12
allow_flag
export COPY_PARALLEL=8 FAKE_FAIL_COPY=phenotypic/phs000000.c5/columnMeta.javabin
run_import both "$DATASET_URL2"
unset FAKE_FAIL_COPY COPY_PARALLEL
no_allow_flag
[ "$rc" != 0 ] && ok "COPY_PARALLEL=8: one failing copy among 26 fails the build" || bad "COPY_PARALLEL=8 failing copy (rc=$rc)"
check "COPY_PARALLEL=8 failing copy: the refusal names the file" grep -q "REFUSED: copy of s3://$SRC_BUCKET/data/hpds/pheno-partitioned/datasets/$DATASET_ID2/partitions/phs000000.c5/columnMeta.javabin to s3://$STACK/data/$C1/$AUTH_DIR/phenotypic/phs000000.c5/columnMeta.javabin failed" "$T/err"
check "COPY_PARALLEL=8 failing copy: the build says how many copies failed and which" grep -qF "REFUSED: 1 of 26 copies failed (phenotypic/phs000000.c5/columnMeta.javabin); no manifest.tsv written" "$T/err"
check "COPY_PARALLEL=8 failing copy: no manifest.tsv, no fence_mapping.json, open not started" bash -c "test ! -e '$STAGE/$AUTH_DIR/manifest.tsv' && test ! -e '$STAGE/fence_mapping.json' && test ! -e '$STAGE/$OPEN_DIR'"
check "COPY_PARALLEL=8 failing copy: the injected error text is shown" grep -q 'injected copy failure' "$T/err"
check "COPY_PARALLEL=8 failing copy: the work directory holds no manifest.tsv rows (only the header)" test "$(grep -vc '^#' "$T/ws/dataset_work/manifest.tsv")" = 1
check "COPY_PARALLEL=8 failing copy: the temporary profile file is gone" tmp_is_empty
check "COPY_PARALLEL=8 failing copy: the output lines are whole lines" bash -c "! grep -vE '^(staging .* -> .* \([0-9]+ bytes\)|auth: staging .*)\$' '$T/out'"
# after the first failure no new copy starts
reset_world
make_dataset_v2 12
export COPY_PARALLEL=2 FAKE_SLOW_COPY=phenotypic FAKE_FAIL_COPY=/encryption_key
run_import auth "$DATASET_URL2"
unset FAKE_FAIL_COPY FAKE_SLOW_COPY COPY_PARALLEL
[ "$rc" != 0 ] && ok "COPY_PARALLEL=2: the first entry failing fails the build" || bad "COPY_PARALLEL=2 first failing (rc=$rc)"
check "COPY_PARALLEL=2: after the failure no further copy was started (fewer than 24 partition files staged)" test "$(find "$STAGE" -path '*phenotypic*' -type f 2> /dev/null | wc -l | tr -d ' ')" -lt 24
check "COPY_PARALLEL=2: nothing is published" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv"
# a source read that dies in the middle of the stream, in parallel
reset_world
make_dataset_v2 12
export COPY_PARALLEL=8 FAKE_FAIL_READ=phs999999.c1/columnMeta.javabin
run_import auth "$DATASET_URL2"
unset FAKE_FAIL_READ COPY_PARALLEL
[ "$rc" != 0 ] && grep -q 'REFUSED: copy of .*phs999999.c1/columnMeta.javabin.* failed' "$T/err" && ok "COPY_PARALLEL=8: a source read failing mid-stream is a failed copy, named" || bad "COPY_PARALLEL=8 read failure (rc=$rc)"
check "COPY_PARALLEL=8 mid-stream read failure: nothing is published" bash -c "test ! -e '$STAGE/$AUTH_DIR/manifest.tsv' && test ! -e '$STAGE/fence_mapping.json'"
# several failures: they are counted and listed
reset_world
make_dataset_v2 12
export COPY_PARALLEL=8 FAKE_FAIL_COPY=columnMeta.javabin
run_import auth "$DATASET_URL2"
unset FAKE_FAIL_COPY COPY_PARALLEL
[ "$rc" != 0 ] && grep -q 'REFUSED: [0-9]* of 26 copies failed (phenotypic/' "$T/err" && ok "COPY_PARALLEL=8: several failing copies are counted and listed" || bad "COPY_PARALLEL=8 several failures (rc=$rc)"
check "COPY_PARALLEL=8 several failures: nothing is published" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv"

# ---- a byte mismatch on one entry is refused
reset_world
make_dataset_v2 12
export COPY_PARALLEL=8 FAKE_CORRUPT_COPY=phenotypic/phs999999.c1/allObservationsStore.javabin
run_import auth "$DATASET_URL2"
unset FAKE_CORRUPT_COPY COPY_PARALLEL
[ "$rc" != 0 ] && ok "COPY_PARALLEL=8: a byte mismatch on one entry fails the build" || bad "COPY_PARALLEL=8 byte mismatch (rc=$rc)"
check "COPY_PARALLEL=8 byte mismatch: the refusal names the entry and both sizes" grep -q "REFUSED: phenotypic/phs999999.c1/allObservationsStore.javabin: staged 3 bytes, manifest says 16" "$T/err"
check "COPY_PARALLEL=8 byte mismatch: the failure is counted, no manifest.tsv and no fence_mapping.json" bash -c "grep -q 'REFUSED: 1 of 26 copies failed (phenotypic/phs999999.c1/allObservationsStore.javabin)' '$T/err' && test ! -e '$STAGE/$AUTH_DIR/manifest.tsv' && test ! -e '$STAGE/fence_mapping.json'"
# the fence mapping copy runs after the parallel set: a mismatch there is refused and nothing is published
reset_world
make_dataset_v2
export COPY_PARALLEL=8 FAKE_CORRUPT_COPY=fence_mapping.json
run_import auth "$DATASET_URL2"
unset FAKE_CORRUPT_COPY COPY_PARALLEL
[ "$rc" != 0 ] && grep -q 'REFUSED: fence_mapping.json: staged 3 bytes' "$T/err" && ok "COPY_PARALLEL=8: a bad fence_mapping.json copy is refused" || bad "COPY_PARALLEL=8 fence mismatch (rc=$rc)"
check "COPY_PARALLEL=8 bad fence_mapping.json: no manifest.tsv" test ! -e "$STAGE/$AUTH_DIR/manifest.tsv"

# ---- the open variant (no fence mapping) in parallel
reset_world
make_dataset_v2 4
allow_flag
export COPY_PARALLEL=8
run_import open "$DATASET_URL2"
no_allow_flag
unset COPY_PARALLEL
[ "$rc" = 0 ] && ok "COPY_PARALLEL=8: the v2 open variant stages" || { bad "COPY_PARALLEL=8 v2 open (rc=$rc)"; cat "$T/err"; }
check "COPY_PARALLEL=8: the open variant writes no fence_mapping.json and has its 2 stigvars lines" bash -c "test ! -e '$STAGE/fence_mapping.json' && test \$(grep -c stigvars '$STAGE/$OPEN_DIR/manifest.tsv') = 2"

# ---- the workers never read the entries list, whatever their aws does with stdin
reset_world
make_dataset_v2 12
export COPY_PARALLEL=8 FAKE_AWS_EAT_STDIN=1
IMPORT_SCRIPT="$T/import-noredirect.sh"
run_import auth "$DATASET_URL2"
IMPORT_SCRIPT="$T/import.sh"
unset FAKE_AWS_EAT_STDIN COPY_PARALLEL
[ "$rc" = 0 ] && ok "COPY_PARALLEL=8: workers do not depend on the redirects of their aws calls (they never read the entries)" || { bad "COPY_PARALLEL=8 stdin (rc=$rc)"; cat "$T/err"; }
check "COPY_PARALLEL=8 stdin: all 26 rows are in manifest.tsv" test "$(tsv_rows "$STAGE/$AUTH_DIR/manifest.tsv" | wc -l | tr -d ' ')" = 26

# ---- COPY_PARALLEL validation
for v in 0 65 100 -1 abc 08 1.5 " 4" "4 " "1;2" 016; do
    reset_world
    make_dataset_v2 3
    export COPY_PARALLEL="$v"
    run_import auth "$DATASET_URL2"
    unset COPY_PARALLEL
    [ "$rc" != 0 ] && grep -qF "REFUSED: unknown COPY_PARALLEL '$v' (expected an integer from 1 to 64)" "$T/err" && ok "COPY_PARALLEL='$v' is refused" || bad "COPY_PARALLEL='$v' (rc=$rc)"
    check "COPY_PARALLEL='$v': nothing was called or staged" test ! -s "$FAKE_AWS_LOG" -a ! -e "$STAGE"
done
for v in 1 2 9 10 16 33 63 64; do
    reset_world
    make_dataset_v2 3
    export COPY_PARALLEL="$v"
    run_import auth "$DATASET_URL2"
    unset COPY_PARALLEL
    [ "$rc" = 0 ] && grep -q "(COPY_PARALLEL=$v)\$" "$T/out" && ok "COPY_PARALLEL=$v is accepted" || { bad "COPY_PARALLEL=$v (rc=$rc)"; cat "$T/err"; }
done
# a bad value is refused before any variant is looked at
reset_world
make_dataset
export COPY_PARALLEL=65
run_import both "$DATASET_URL"
unset COPY_PARALLEL
[ "$rc" != 0 ] && grep -q "unknown COPY_PARALLEL '65'" "$T/err" && ok "COPY_PARALLEL=65 is refused before any variant is looked at" || bad "COPY_PARALLEL=65 both (rc=$rc)"
# the job text
check "COPY_PARALLEL is described in the job description" bash -c "grep -qF 'COPY_PARALLEL (default 16, 1 to 64)' '$T/import.desc' && grep -qF 'byte-identical to the one of a run with 1' '$T/import.desc' && grep -qF 'The legacy .tar path ignores it' '$T/import.desc' && ! grep -qF 'one after the other (about 1,580' '$T/import.desc'"
check "the stage job XML is well-formed" python3 -I -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$IMPORT_XML"

# ---- optional: how the per-file loop scales (V2_SCALE_TEST=1 bash import-hpds.test.sh): 789 partitions = 1,580 files per variant
if [ "${V2_SCALE_TEST:-}" = 1 ]; then
    reset_world
    make_dataset_v2 789
    t0=$(date +%s)
    run_import auth "$DATASET_URL2"
    t1=$(date +%s)
    echo "scale: 789 partitions, auth only, fake aws: rc=$rc, $((t1 - t0)) s, $(grep -c 'aws ' "$FAKE_AWS_LOG") aws calls, $(tsv_rows "$STAGE/$AUTH_DIR/manifest.tsv" | wc -l | tr -d ' ') rows"
fi

if command -v shellcheck > /dev/null 2>&1; then
    check "shellcheck: stage shell step is clean" shellcheck -s bash "$T/import.sh"
    check "shellcheck: Check For Updates shell step is clean" shellcheck -s bash "$T/cfu.sh"
else
    echo "skip - shellcheck not installed"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
