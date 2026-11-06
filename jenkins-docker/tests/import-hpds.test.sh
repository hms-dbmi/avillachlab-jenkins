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
echo "aws $*" >> "$FAKE_AWS_LOG"
# a CLI that reads stdin (FAKE_AWS_EAT_STDIN=1) would swallow the rest of a while-read loop's input
[ -z "${FAKE_AWS_EAT_STDIN:-}" ] || cat > /dev/null
bucket="" key="" prefix=""
pos=()
while [ $# -gt 0 ]; do
    case "$1" in
        --bucket) bucket="$2"; shift 2 ;;
        --key) key="$2"; shift 2 ;;
        --prefix) prefix="$2"; shift 2 ;;
        --sse | --query | --output | --role-arn | --role-session-name | --region | --profile) shift 2 ;;
        --*) shift ;;
        *) pos+=("$1"); shift ;;
    esac
done
loc() { case "$1" in s3://*) echo "$FAKE_S3/${1#s3://}" ;; *) echo "$1" ;; esac; }
case "${pos[0]}/${pos[1]}" in
    s3/cp)
        src="$(loc "${pos[2]}")"
        dst="$(loc "${pos[3]}")"
        [ -f "$src" ] || { echo "fake aws: missing source ${pos[2]}" >&2; exit 1; }
        if [ -n "${FAKE_FAIL_COPY:-}" ] && [[ "${pos[3]}" == *"$FAKE_FAIL_COPY"* ]]; then
            echo "fake aws: injected copy failure for ${pos[3]}" >&2
            exit 1
        fi
        if [ -n "${FAKE_NOOP_COPY:-}" ] && [[ "${pos[3]}" == *"$FAKE_NOOP_COPY"* ]]; then exit 0; fi
        if [ "${pos[3]}" = "-" ]; then cat "$src"; exit 0; fi
        mkdir -p "$(dirname "$dst")"
        if [ -n "${FAKE_CORRUPT_COPY:-}" ] && [[ "${pos[3]}" == *"$FAKE_CORRUPT_COPY"* ]]; then
            head -c 3 "$src" > "$dst"
        else
            cp "$src" "$dst"
        fi
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
    sts/assume-role)
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
chmod +x "$BIN/aws" "$BIN/docker"

export FAKE_S3="$T/s3"
export FAKE_AWS_LOG="$T/aws.log"
export FAKE_DOCKER_LOG="$T/docker.log"
export PATH="$BIN:$PATH"

SRC_BUCKET=bdc-etl-data-d0d6191
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
    rm -rf "$FAKE_S3" "$FAKE_AWS_LOG" "$FAKE_DOCKER_LOG" "$T/ws" "$T/jh"
    mkdir -p "$FAKE_S3" "$T/ws"
    : > "$FAKE_AWS_LOG"
    : > "$FAKE_DOCKER_LOG"
    unset FAKE_FAIL_COPY FAKE_NOOP_COPY FAKE_CORRUPT_COPY FAKE_LIST_DENIED FAKE_AWS_EAT_STDIN WS_SEED DEPLOY_TO_STAGING_STACK
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
            bash "$IMPORT_SCRIPT" > "$T/out" 2> "$T/err" < /dev/null
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
check "per-file path never assumes a role" test "$(grep -c 'assume-role' "$FAKE_AWS_LOG")" = 0

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
check "both: per-file path never assumes a role" test "$(grep -c 'assume-role' "$FAKE_AWS_LOG")" = 0

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
export FAKE_AWS_EAT_STDIN=1
IMPORT_SCRIPT="$T/import-noredirect.sh"
run_import auth "$DATASET_URL"
IMPORT_SCRIPT="$T/import.sh"
unset FAKE_AWS_EAT_STDIN
[ "$rc" != 0 ] && grep -q 'data rows' "$T/err" && ok "short manifest.tsv is refused before upload" || bad "short manifest.tsv guard (rc=$rc)"
check "short manifest.tsv was not uploaded" test ! -e "$STAGE/javabins_rekeyed/manifest.tsv"

reset_world
make_dataset
export FAKE_CORRUPT_COPY=columnMeta.javabin
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && grep -q 'manifest says' "$T/err" && ok "byte-count mismatch after copy fails the job" || bad "byte mismatch (rc=$rc)"
check "byte mismatch: no manifest.tsv" test ! -e "$STAGE/javabins_rekeyed/manifest.tsv"
unset FAKE_CORRUPT_COPY

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
    local sse="--sse AES256 --only-show-errors"
    echo "aws s3 cp $src/manifest.json dataset_work/manifest.json --only-show-errors"
    for f in $AUTH_DIR $OPEN_DIR; do
        echo "aws s3 cp dataset_work/manifest.tsv $dst/$f/manifest.tsv $sse"
        echo "aws s3api list-objects-v2 --bucket $STACK --prefix data/$C1/$f/manifest.tsv --output json"
        echo "aws s3api list-objects-v2 --bucket $STACK --prefix data/$C1/$f.tar --output json"
    done
    for f in allObservationsStore.javabin encryption_key; do
        echo "aws s3 cp $src/$f $dst/$AUTH_DIR/$f $sse"
        echo "aws s3 cp $src/$f $dst/$OPEN_DIR/$f $sse"
    done
    echo "aws s3 cp $src/columnMeta.javabin $dst/$AUTH_DIR/columnMeta.javabin $sse"
    echo "aws s3 cp $src/open/columnMeta.javabin $dst/$OPEN_DIR/columnMeta.javabin $sse"
    echo "aws s3 cp $src/static/metadata.json $dst/$AUTH_DIR/metadata.json $sse"
    echo "aws s3 cp $src/static/metadata.json $dst/$OPEN_DIR/metadata.json $sse"
    echo "aws s3 cp $src/static/metadata.json $dst/fence_mapping.json $sse"
    echo "aws s3 cp $src/static/conceptsToRemove.txt $dst/$OPEN_DIR/conceptsToRemove.txt $sse"
    for f in allObservationsStore.javabin columnMeta.javabin encryption_key metadata.json; do
        echo "aws s3api head-object --bucket $STACK --key data/$C1/$AUTH_DIR/$f"
        echo "aws s3api head-object --bucket $STACK --key data/$C1/$OPEN_DIR/$f"
    done
    echo "aws s3api head-object --bucket $STACK --key data/$C1/$OPEN_DIR/conceptsToRemove.txt"
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
    check "staging flag $mode: no fence_mapping.json existence probe (list or head) is made" test "$(grep -E 'list-objects-v2|head-object' "$FAKE_AWS_LOG" | grep -c 'fence_mapping.json')" = 0
    expected_flag_off_calls | sort -u > "$T/aws.expected"
    sort -u "$FAKE_AWS_LOG" > "$T/aws.actual"
    check "staging flag $mode: the set of aws calls is exactly the staging calls (no other probe, list, head or copy)" diff "$T/aws.expected" "$T/aws.actual"
    check "staging flag $mode: fence_mapping.json is written once (auth only)" test "$(grep -c 's3://.*/fence_mapping.json' "$FAKE_AWS_LOG")" = 1
    if [ "$mode" = unset ]; then cp "$FAKE_AWS_LOG" "$T/aws.flag-unset.log"; else check "staging flag false: the aws calls are identical, in order, to those of an unset flag" cmp "$FAKE_AWS_LOG" "$T/aws.flag-unset.log"; fi
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
check "flag on: per-file staging still never assumes a role" test "$(grep -c 'assume-role' "$FAKE_AWS_LOG")" = 0
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
check "Stage job: parameters are the HPDS_VARIANT choice both|auth|open (both is the default) and the boolean DEPLOY_TO_STAGING_STACK (default false)" python3 -I - "$IMPORT_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
names = [e.findtext("name") for e in r.findall(".//parameterDefinitions/*")]
assert names == ["HPDS_VARIANT", "DEPLOY_TO_STAGING_STACK"], names
c = r.find(".//hudson.model.ChoiceParameterDefinition")
assert c.findtext("name") == "HPDS_VARIANT"
assert [s.text for s in c.iter("string")] == ["both", "auth", "open"]
b = r.find(".//hudson.model.BooleanParameterDefinition")
assert b.findtext("name") == "DEPLOY_TO_STAGING_STACK"
assert b.findtext("defaultValue") == "false"
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

if command -v shellcheck > /dev/null 2>&1; then
    check "shellcheck: stage shell step is clean" shellcheck -s bash "$T/import.sh"
    check "shellcheck: Check For Updates shell step is clean" shellcheck -s bash "$T/cfu.sh"
else
    echo "skip - shellcheck not installed"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
