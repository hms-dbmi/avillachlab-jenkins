#!/bin/bash
# shellcheck disable=SC2015  # "[ test ] && ok || bad" is the intended reporting idiom here
# Tests for the standalone staging job Import_and_Rekey_HPDS_Data (HPDS_VARIANT both|auth|open, source URL and deploy key
# derived from build-spec.json) and for the staged check in Check For Updates (fails fast unless the data is staged).
# The job shell steps are extracted from the config.xml files and run against a fake `aws` (S3 = a directory tree)
# and a fake `docker` on PATH, in a throwaway git repo standing in for the release-control checkout.
# No real AWS, docker or Jenkins is touched. Only placeholder data.
#
# usage: bash jenkins-docker/tests/import-hpds.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
JOBS="$HERE/../jobs"
IMPORT_XML="$JOBS/Import_and_Rekey_HPDS_Data/config.xml"
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
python3 -I "$HERE/extract-shell.py" "$IMPORT_XML" > "$T/import.sh" || { echo "cannot extract import shell"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$CFU_XML" > "$T/cfu.sh" || { echo "cannot extract check-for-updates shell"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$CFU_XML" --groovy --index 0 > "$T/cfu.groovy.first" || { echo "cannot extract first groovy"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$CFU_XML" --groovy --index 1 > "$T/cfu.groovy" || { echo "cannot extract last groovy"; exit 1; }

# ---------------------------------------------------------------- fixtures
# make_dataset [same_sha] : dataset prefix with auth + open variants. same_sha -> open columnMeta sha == full sha.
make_dataset() {
    local d="$DATASET_DIR" same="${1:-}" open_sha
    rm -rf "$d"
    mkdir -p "$d/static" "$d/open"
    printf 'AOS-DATA' > "$d/allObservationsStore.javabin"
    printf 'FULL-COLUMNMETA' > "$d/columnMeta.javabin"
    printf 'a,b\n' > "$d/columnMeta.csv"
    printf 'KEY0123' > "$d/encryption_key"
    printf '{"m":1}' > "$d/static/metadata.json"
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
        entry static/metadata.json metadata.json; printf ','
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
    unset FAKE_FAIL_COPY FAKE_CORRUPT_COPY FAKE_LIST_DENIED FAKE_AWS_EAT_STDIN
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
[ "$rc" != 0 ] && grep -q 'must be identical' "$T/err" && ok "Import: differing dataset-prefix URLs are refused" || bad "Import URL mismatch (rc=$rc)"
check "Import: URL mismatch stages nothing and calls no aws" test ! -s "$FAKE_AWS_LOG"

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
run_import_in_repo auth
[ "$rc" = 0 ] && grep -q 'already staged, skipping' "$T/out" && ok "auth with an existing legacy tar is skipped" || bad "existing tar skip (rc=$rc)"
check "legacy tar skip leaves the tar alone and stages nothing else" test "$(find "$STAGE" -type f | wc -l | tr -d ' ')" = 1 -a "$(cat "$STAGE/javabins_rekeyed.tar")" = old-tar
check "legacy tar skip makes no copy" test "$(grep -c 'aws s3 cp' "$FAKE_AWS_LOG")" = 0

reset_world
make_dataset
cfu_repo "$DATASET_URL" "$DATASET_URL"
mkdir -p "$STAGE/javabins_rekeyed"
printf 'partial\n' > "$STAGE/javabins_rekeyed/columnMeta.javabin"
run_import_in_repo auth
[ "$rc" = 0 ] && staged javabins_rekeyed/manifest.tsv && ok "a partial stage (no manifest.tsv) is not 'staged': the variant is staged now" || bad "partial stage restage (rc=$rc)"

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

# legacy URLs that worked before the stricter URL check (+ % : = in the key) must still be accepted
make_legacy
odd="pheno/final+v1%3A2=a:b.tar"
cp "$FAKE_S3/legacy-src/pheno/final.tar" "$FAKE_S3/legacy-src/$odd"
run_import auth "s3://legacy-src/$odd"
[ "$rc" = 0 ] && ok "legacy .tar URL with + % : = passes the URL check and stages" || { bad "legacy odd URL (rc=$rc)"; cat "$T/err"; }
check "legacy odd URL: tar is staged" test -f "$STAGE/javabins_rekeyed.tar"
for badurl in "s3://legacy-src/pheno/a b.tar" 's3://legacy-src/pheno/a;b.tar' 's3://legacy-src/pheno/$(x).tar' "s3://legacy-src/pheno/a'b.tar"; do
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
[ "$rc" = 0 ] && ok "Import: legacy URLs with different blame commits stage" || { bad "differing legacy keys (rc=$rc)"; cat "$T/err"; }
check "Import: auth is staged under the commit that changed the auth URL" test -f "$FAKE_S3/$STACK/data/$C2/javabins_rekeyed.tar"
check "Import: open is staged under the older commit" test -f "$FAKE_S3/$STACK/data/$C1/destigmatized_javabins_rekeyed.tar"
check "Import: nothing else is staged" test "$(find "$FAKE_S3/$STACK/data" -name '*.tar' | wc -l | tr -d ' ')" = 2

# ================================================================ Check For Updates: shell step (staged check)
run_cfu() {
    (cd "$REPO" && stack_s3_bucket="$STACK" bash "$T/cfu.sh" > "$T/out" 2> "$T/err")
    rc=$?
}
cfu_has() { [ "$(cat "$REPO/$1" 2> /dev/null)" = "$2" ]; }
cfu_lacks() { [ ! -e "$REPO/$1" ]; }
cfu_no_keys() { cfu_lacks datasetKey.txt && cfu_lacks destigmatizedDatasetKey.txt && cfu_lacks genomicDatasetKey.txt; }
# stage_manifest <key> <variant dir> : per-file marker;  stage_tar <key> <legacy name>
stage_manifest() { mkdir -p "$FAKE_S3/$STACK/data/$1/$2"; : > "$FAKE_S3/$STACK/data/$1/$2/manifest.tsv"; }
stage_tar() { mkdir -p "$FAKE_S3/$STACK/data/$1"; : > "$FAKE_S3/$STACK/data/$1/$2.tar"; }

PFX_A="s3://$SRC_BUCKET/data/hpds/pheno/datasets/$DATASET_ID/"

# nothing staged: fail fast, one ERROR per variant, no keys
reset_world
cfu_repo "$PFX_A" "$PFX_A"
run_cfu
[ "$rc" = 1 ] && ok "CFU: nothing staged exits 1" || { bad "CFU nothing staged (rc=$rc)"; cat "$T/err"; }
check "CFU: ERROR for auth with deploy key, source URL and hint" grep -qx "ERROR: auth dataset is not staged: deploy key $C1, source $PFX_A; run Import_and_Rekey_HPDS_Data with HPDS_VARIANT=both" "$T/err"
check "CFU: ERROR for open with deploy key, source URL and hint" grep -qx "ERROR: open dataset is not staged: deploy key $C1, source $PFX_A; run Import_and_Rekey_HPDS_Data with HPDS_VARIANT=both" "$T/err"
check "CFU: exactly one ERROR per variant" test "$(grep -c '^ERROR:' "$T/err")" = 2
check "CFU: nothing staged writes no key files" cfu_no_keys

# only auth missing
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_manifest "$C1" destigmatized_javabins_rekeyed
run_cfu
[ "$rc" = 1 ] && ok "CFU: auth missing exits 1" || bad "CFU auth missing (rc=$rc)"
check "CFU: auth missing: ERROR names auth and HPDS_VARIANT=auth" grep -qx "ERROR: auth dataset is not staged: deploy key $C1, source $PFX_A; run Import_and_Rekey_HPDS_Data with HPDS_VARIANT=auth" "$T/err"
check "CFU: auth missing: no ERROR for open" test "$(grep -c 'open dataset' "$T/err")" = 0
check "CFU: auth missing writes no key files" cfu_no_keys

# only open missing
reset_world
cfu_repo "$PFX_A" "$PFX_A"
stage_manifest "$C1" javabins_rekeyed
run_cfu
[ "$rc" = 1 ] && ok "CFU: open missing exits 1" || bad "CFU open missing (rc=$rc)"
check "CFU: open missing: ERROR names open and HPDS_VARIANT=open" grep -qx "ERROR: open dataset is not staged: deploy key $C1, source $PFX_A; run Import_and_Rekey_HPDS_Data with HPDS_VARIANT=open" "$T/err"
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
(cd "$REPO" && ORIG_PATH="$PATH" PATH="$T/fakegit:$PATH" stack_s3_bucket="$STACK" bash "$T/cfu.sh" > "$T/out" 2> "$T/err")
rc=$?
[ "$rc" != 0 ] && grep -q 'not a git hash' "$T/err" && ok "CFU: a non-hex blame commit is refused" || bad "CFU non-hex blame (rc=$rc)"
rm -rf "$T/ws"; cp -R "$REPO" "$T/ws"
(cd "$T/ws" && ORIG_PATH="$PATH" PATH="$T/fakegit:$PATH" HPDS_VARIANT=both stack_s3_bucket="$STACK" WORKSPACE="$T/ws" JENKINS_HOME="$T/jh" bash "$T/import.sh" > "$T/out" 2> "$T/err" < /dev/null)
rc=$?
[ "$rc" != 0 ] && grep -q 'not a git hash' "$T/err" && ok "Import: a non-hex blame commit is refused" || bad "Import non-hex blame (rc=$rc)"
check "Import: non-hex blame commit stages nothing" test ! -d "$FAKE_S3/$STACK/data"

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
[ "$rc" != 0 ] && grep -q 'must be identical' "$T/err" && ok "Import: dataset prefix on one side and .tar on the other fails" || bad "Import prefix vs tar (rc=$rc)"
check "Import: prefix vs tar stages nothing and calls no aws" test ! -s "$FAKE_AWS_LOG"

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
    [ "$rc" = 0 ] || { bad "parity $1: Import stages (rc=$rc)"; cat "$T/err"; return; }
    run_cfu
    [ "$rc" = 0 ] && ok "parity $1: CFU finds the data Import staged (same deploy keys)" || { bad "parity $1: CFU (rc=$rc)"; cat "$T/err"; return; }
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
check "parity: Import staged under the key without ^" test -f "$FAKE_S3/$STACK/data/$RK/javabins_rekeyed.tar"

# ================================================================ Check For Updates: builders and Groovy steps (static checks)
check "CFU: the shell step is the first builder" python3 -I - "$CFU_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
tags = [e.tag for e in r.find("builders")]
assert tags == ["hudson.tasks.Shell", "hudson.plugins.groovy.SystemGroovy", "hudson.plugins.groovy.SystemGroovy"], tags
PY
check "CFU first groovy step still builds Bash_Functions then PIC-SURE Pipeline" bash -c "grep -q 'getItemByFullName(\"Bash_Functions\")' '$T/cfu.groovy.first' && grep -q 'getItemByFullName(\"PIC-SURE Pipeline\")' '$T/cfu.groovy.first' && grep -q 'PIC-SURE Pipeline failed' '$T/cfu.groovy.first'"
check "CFU: no builder references Import_and_Rekey_HPDS_Data as a job to run" test "$(cat "$T/cfu.groovy.first" "$T/cfu.groovy" | grep -c 'Import_and_Rekey')" = 0
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

# ================================================================ job definitions
check "Import job: the only parameter is the HPDS_VARIANT choice both|auth|open (both is the default)" python3 -I - "$IMPORT_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
names = [e.findtext("name") for e in r.findall(".//parameterDefinitions/*")]
assert names == ["HPDS_VARIANT"], names
c = r.find(".//hudson.model.ChoiceParameterDefinition")
assert c.findtext("name") == "HPDS_VARIANT"
assert [s.text for s in c.iter("string")] == ["both", "auth", "open"]
PY
check "Import job: source_s3_url and destination_bucket_hash are gone from the job" test "$(grep -cE 'source_s3_url|destination_bucket_hash' "$IMPORT_XML")" = 0
check "Import job: release-control checkout is still configured" bash -c "grep -q '<url>\${release_control_git_repo}</url>' '$IMPORT_XML' && grep -q '<name>\${release_control_git_hash}</name>' '$IMPORT_XML'"
check "Import job: description names standalone use, the order and the rollback" bash -c "grep -q 'Run by hand' '$IMPORT_XML' && grep -q 'commit the new source URLs' '$IMPORT_XML' && grep -q 'Rollback' '$IMPORT_XML' && grep -q 'curated-datasets-s3-role' '$IMPORT_XML' && grep -q 'bdc-etl-data-d0d6191' '$IMPORT_XML'"
check "Import job: removed parameters are gone from both jobs" test "$(grep -cE 'isDestigmatized|output_file_name|disable_rekey' "$IMPORT_XML" "$CFU_XML" | awk -F: '{s+=$2} END {print s}')" = 0
check "Run Rekey - Standalone is deleted" test ! -e "$JOBS/Run Rekey - Standalone"
check "no view or job references Run Rekey - Standalone" test "$(grep -rl --exclude-dir=tests 'Run Rekey - Standalone' "$HERE/.." | wc -l | tr -d ' ')" = 0
check "Import job never references the legacy bucket" test "$(grep -c 'avillach-73-bdcatalyst-etl' "$IMPORT_XML" "$CFU_XML" | awk -F: '{s+=$2} END {print s}')" = 0

if command -v shellcheck > /dev/null 2>&1; then
    check "shellcheck: Import shell step is clean" shellcheck -s bash "$T/import.sh"
    check "shellcheck: Check For Updates shell step is clean" shellcheck -s bash "$T/cfu.sh"
else
    echo "skip - shellcheck not installed"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
