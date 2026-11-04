#!/bin/bash
# shellcheck disable=SC2015  # "[ test ] && ok || bad" is the intended reporting idiom here
# Tests for the HPDS_VARIANT staging in Import_and_Rekey_HPDS_Data and the staged check in Check For Updates.
# The job shell steps are extracted from the config.xml files and run against a fake `aws` (S3 = a directory tree)
# and a fake `docker` on PATH. No real AWS, docker or Jenkins is touched. Only placeholder data.
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
HASH=0123456789abcdef0123456789abcdef01234567

sha() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

# ---------------------------------------------------------------- extracted scripts
python3 -I "$HERE/extract-shell.py" "$IMPORT_XML" > "$T/import.sh" || { echo "cannot extract import shell"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$CFU_XML" > "$T/cfu.sh" || { echo "cannot extract check-for-updates shell"; exit 1; }
python3 -I "$HERE/extract-shell.py" "$CFU_XML" --groovy --index 1 > "$T/cfu.groovy" || { echo "cannot extract groovy"; exit 1; }

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
        printf '"removal":{"concepts_in_list":1,"full_columnmeta_sha256":"%s","open_columnmeta_sha256":"%s"},' "$(sha "$d/columnMeta.javabin")" "$open_sha"
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
    unset FAKE_FAIL_COPY FAKE_CORRUPT_COPY FAKE_LIST_DENIED
}

# run_import <variant> <source url> ; exit code in $rc, stderr in $T/err
run_import() {
    rm -rf "$T/ws"
    mkdir -p "$T/ws"
    (
        cd "$T/ws" || exit 99
        HPDS_VARIANT="$1" source_s3_url="$2" destination_bucket_hash="$HASH" stack_s3_bucket="$STACK" \
            WORKSPACE="$T/ws" JENKINS_HOME="$T/jh" bash "$T/import.sh" > "$T/out" 2> "$T/err"
    )
    rc=$?
}

STAGE="$FAKE_S3/$STACK/data/$HASH"
staged() { [ -e "$STAGE/$1" ]; }
stage_files() { (cd "$STAGE/$1" 2> /dev/null && find . -type f | sed 's|^\./||' | sort | tr '\n' ' '); }

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

# ================================================================ Import: refusals
reset_world
make_dataset same
run_import open "$DATASET_URL"
[ "$rc" != 0 ] && grep -q 'REFUSED' "$T/err" && ok "open refuses when full and open columnMeta shas are equal" || bad "open sha-equal refusal (rc=$rc)"
check "sha-equal refusal staged nothing" test ! -e "$STAGE/destigmatized_javabins_rekeyed"
run_import auth "$DATASET_URL"
[ "$rc" = 0 ] && ok "auth is unaffected by equal shas" || bad "auth with equal shas (rc=$rc)"

reset_world
make_dataset
mkdir -p "$STAGE/javabins_rekeyed"
printf 'old\n' > "$STAGE/javabins_rekeyed/manifest.tsv"
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && grep -q 'already exists' "$T/err" && ok "refuses when manifest.tsv already exists" || bad "existing manifest.tsv refusal (rc=$rc)"
check "existing stage prefix is untouched" test "$(stage_files javabins_rekeyed)" = "manifest.tsv " -a "$(cat "$STAGE/javabins_rekeyed/manifest.tsv")" = old
check "refusal happens before any copy" test "$(grep -c 'aws s3 cp' "$FAKE_AWS_LOG")" = 0

reset_world
make_dataset
run_import both "$DATASET_URL"
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
run_import auth "$DATASET_URL"
[ "$rc" != 0 ] && ok "after the retry the prefix is immutable (third run refused)" || bad "third run refusal"

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

make_legacy
run_import auth "s3://legacy-src/pheno/missing/"
[ "$rc" != 0 ] && ok "dataset-prefix path without manifest.json fails (not mistaken for legacy)" || bad "missing prefix"
make_legacy
run_import auth "s3://legacy-src/pheno/final.zip"
[ "$rc" != 0 ] && grep -q 'must end with' "$T/err" && ok "URL that is neither .tar nor a prefix is refused" || bad "bad url refusal"

# ================================================================ Check For Updates: shell step
# cfu_repo <auth url> <open url> : git repo whose last commit adds build-spec.json; sets REPO and C1 (that commit).
cfu_repo() {
    REPO="$T/release-control"
    rm -rf "$REPO"
    mkdir -p "$REPO"
    (
        cd "$REPO" || exit 1
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
}

run_cfu() {
    (cd "$REPO" && stack_s3_bucket="$STACK" bash "$T/cfu.sh" > "$T/out" 2> "$T/err")
    rc=$?
}
cfu_has() { [ "$(cat "$REPO/$1" 2> /dev/null)" = "$2" ]; }
cfu_lacks() { [ ! -e "$REPO/$1" ]; }

PFX_A="s3://$SRC_BUCKET/data/hpds/pheno/datasets/$DATASET_ID/"

reset_world
cfu_repo "$PFX_A" "$PFX_A"
run_cfu
[ "$rc" = 0 ] && ok "CFU: dataset prefix, nothing staged exits 0" || { bad "CFU nothing staged (rc=$rc)"; cat "$T/err"; }
check "CFU: auth is to be staged" cfu_has toBeRekeyed.txt "$C1"
check "CFU: open is to be staged" cfu_has destigmatized_toBeRekeyed.txt "$C1"
check "CFU: no already-staged markers" cfu_lacks alreadyRekeyed.txt
check "CFU: genomic key is written" cfu_has genomicDatasetKey.txt "$C1"

reset_world
cfu_repo "$PFX_A" "$PFX_A"
mkdir -p "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed" "$FAKE_S3/$STACK/data/$C1/destigmatized_javabins_rekeyed"
: > "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed/manifest.tsv"
: > "$FAKE_S3/$STACK/data/$C1/destigmatized_javabins_rekeyed/manifest.tsv"
run_cfu
check "CFU: manifest.tsv marks auth as staged" cfu_has alreadyRekeyed.txt "$C1"
check "CFU: manifest.tsv marks open as staged" cfu_has destigmatized_alreadyRekeyed.txt "$C1"
check "CFU: staged variants are not scheduled" cfu_lacks toBeRekeyed.txt
check "CFU: staged open is not scheduled" cfu_lacks destigmatized_toBeRekeyed.txt

reset_world
cfu_repo "$PFX_A" "$PFX_A"
: > /dev/null
mkdir -p "$FAKE_S3/$STACK/data/$C1"
: > "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed.tar"
mkdir -p "$FAKE_S3/$STACK/data/$C1/destigmatized_javabins_rekeyed"
: > "$FAKE_S3/$STACK/data/$C1/destigmatized_javabins_rekeyed/manifest.tsv"
run_cfu
check "CFU: legacy tar marks auth as staged" cfu_has alreadyRekeyed.txt "$C1"
check "CFU: open staged by manifest.tsv only" cfu_has destigmatized_alreadyRekeyed.txt "$C1"

reset_world
cfu_repo "$PFX_A" "$PFX_A"
mkdir -p "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed"
: > "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed/columnMeta.javabin"
run_cfu
check "CFU: a partial stage (no manifest.tsv) is not staged" cfu_has toBeRekeyed.txt "$C1"

reset_world
cfu_repo "$PFX_A" "$PFX_A"
mkdir -p "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed"
: > "$FAKE_S3/$STACK/data/$C1/javabins_rekeyed/manifest.tsv"
export FAKE_LIST_DENIED=1
run_cfu
unset FAKE_LIST_DENIED
check "CFU: list denied falls back to head-object (manifest.tsv head 404 is 'not staged')" cfu_has destigmatized_toBeRekeyed.txt "$C1"

reset_world
cfu_repo "$PFX_A" "s3://$SRC_BUCKET/data/hpds/pheno/datasets/2026-11-05T0000Z/"
run_cfu
[ "$rc" != 0 ] && grep -q 'must be identical' "$T/err" && ok "CFU: differing dataset-prefix URLs fail" || bad "CFU URL mismatch (rc=$rc)"
check "CFU: URL mismatch writes no markers" cfu_lacks toBeRekeyed.txt

reset_world
cfu_repo "$PFX_A" "s3://example-bucket/legacy/final-destig.tar"
run_cfu
[ "$rc" != 0 ] && ok "CFU: dataset prefix on one side and .tar on the other fails" || bad "CFU prefix vs tar"

reset_world
cfu_repo "s3://example-bucket/legacy/final.tar" "s3://example-bucket/legacy/final-destig.tar"
run_cfu
[ "$rc" = 0 ] && ok "CFU: legacy .tar URLs may differ" || { bad "CFU legacy urls (rc=$rc)"; cat "$T/err"; }
check "CFU: legacy auth to be staged" cfu_has toBeRekeyed.txt "$C1"
# a later commit that touches only the auth URL gives auth a new deploy key and keeps the open key
(
    cd "$REPO" || exit 1
    sed -i.bak 's|legacy/final.tar|legacy/final-v2.tar|' build-spec.json && rm -f build-spec.json.bak
    git commit -q -am bump
)
C2="$(git -C "$REPO" rev-parse HEAD)"
rm -f "$REPO"/*.txt
run_cfu
check "CFU: auth key follows the commit that changed the auth URL" cfu_has toBeRekeyed.txt "$C2"
check "CFU: open key stays at the older commit" cfu_has destigmatized_toBeRekeyed.txt "$C1"

# ================================================================ Check For Updates: Groovy step (static checks)
check "CFU groovy: passes HPDS_VARIANT auth" grep -q 'runImport("auth"' "$T/cfu.groovy"
check "CFU groovy: passes HPDS_VARIANT open" grep -q 'runImport("open"' "$T/cfu.groovy"
check "CFU groovy: sets the HPDS_VARIANT parameter" grep -q 'StringParameterValue("HPDS_VARIANT", variant)' "$T/cfu.groovy"
check "CFU groovy: checks the Import result against SUCCESS" grep -q 'run.getResult() != Result.SUCCESS' "$T/cfu.groovy"
check "CFU groovy: aborts when an Import is not SUCCESS" grep -q 'throw new AbortException("Import_and_Rekey_HPDS_Data' "$T/cfu.groovy"
check "CFU groovy: SUCCESS check comes before Deployment Pipeline is scheduled" \
    test "$(grep -n 'Result.SUCCESS' "$T/cfu.groovy" | head -1 | cut -d: -f1)" -lt "$(grep -n 'getItemByFullName("Deployment Pipeline")' "$T/cfu.groovy" | head -1 | cut -d: -f1)"
check "CFU groovy: no removed parameters left" test "$(grep -cE 'isDestigmatized|output_file_name|disable_rekey' "$T/cfu.groovy")" = 0

# ================================================================ job definitions
check "Import job: HPDS_VARIANT is a choice parameter with auth and open" python3 -I - "$IMPORT_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
names = [e.findtext("name") for e in r.findall(".//parameterDefinitions/*")]
assert names == ["source_s3_url", "HPDS_VARIANT", "destination_bucket_hash"], names
c = r.find(".//hudson.model.ChoiceParameterDefinition")
assert c.findtext("name") == "HPDS_VARIANT"
assert [s.text for s in c.iter("string")] == ["auth", "open"]
PY
check "Import job: removed parameters are gone from both jobs" test "$(grep -cE 'isDestigmatized|output_file_name|disable_rekey' "$IMPORT_XML" "$CFU_XML" | awk -F: '{s+=$2} END {print s}')" = 0
check "Run Rekey - Standalone is deleted" test ! -e "$JOBS/Run Rekey - Standalone"
check "no view or job references Run Rekey - Standalone" test "$(grep -rl --exclude-dir=tests 'Run Rekey - Standalone' "$HERE/.." | wc -l | tr -d ' ')" = 0
check "Import job never references the legacy bucket" test "$(grep -c 'avillach-73-bdcatalyst-etl' "$IMPORT_XML" "$CFU_XML" | awk -F: '{s+=$2} END {print s}')" = 0

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
