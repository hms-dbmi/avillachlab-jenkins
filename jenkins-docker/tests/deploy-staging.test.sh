#!/bin/bash
# shellcheck disable=SC2015  # "[ test ] && ok || bad" is the intended reporting idiom here
# Tests for the Pipeline job "HPDS Data - Deploy to Staging Stack".
#   1. static checks of the pipeline script (the XML is parsed and the script unescaped);
#   2. the staged-data re-check (the sh step), extracted and run against a fake `aws` (S3 = a directory tree);
#   3. the whole script run against a fake pipeline DSL when a `groovy` is on PATH (deploy-staging.harness.groovy), else skipped.
# No real AWS, Jenkins or Groovy runtime is needed for 1 and 2. Only placeholder data.
#
# usage: bash jenkins-docker/tests/deploy-staging.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
JOBS="$HERE/../jobs"
DEPLOY_XML="$JOBS/HPDS Data - Deploy to Staging Stack/config.xml"

T="$(mktemp -d "${TMPDIR:-/tmp}/deploy-staging-test.XXXXXX")"
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

# ---------------------------------------------------------------- extracted pieces
# pipeline_script: the unescaped Groovy of the flow definition
python3 -I - "$DEPLOY_XML" > "$T/pipeline.groovy" << 'PY' || { echo "cannot read the pipeline script"; exit 1; }
import sys, xml.etree.ElementTree as E
sys.stdout.write(E.parse(sys.argv[1]).getroot().find("definition/script").text)
PY
python3 -I - "$DEPLOY_XML" > "$T/deploy.desc" << 'PY' || { echo "cannot read the description"; exit 1; }
import sys, xml.etree.ElementTree as E
sys.stdout.write(" ".join((E.parse(sys.argv[1]).getroot().findtext("description") or "").split()))
PY
[ -s "$T/pipeline.groovy" ] && [ -s "$T/deploy.desc" ] || { echo "empty script or description"; exit 1; }

# the same script without its full-line comments: the static checks look at code only
grep -v '^[[:space:]]*//' "$T/pipeline.groovy" > "$T/pipeline.code" || true

# recheck_script: the body of the sh step, unescaped, between sh ''' and the closing '''
python3 -I - "$T/pipeline.groovy" > "$T/recheck.sh" << 'PY' || { echo "cannot extract the sh step"; exit 1; }
import re, sys
g = open(sys.argv[1]).read()
m = re.search(r"sh '''(.*?)'''", g, re.S)
assert m and g.count("sh '''") == 1
sys.stdout.write(m.group(1))
PY

# ================================================================ 1. static checks
check "XML is well formed and is a Pipeline (flow-definition) with a CpsFlowDefinition" python3 -I - "$DEPLOY_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
assert r.tag == "flow-definition", r.tag
assert r.find("definition").get("class") == "org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition"
PY
check "the script runs in the Groovy sandbox" python3 -I - "$DEPLOY_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
assert r.findtext("definition/sandbox") == "true"
PY
check "parameters are exactly DATA_S3_OBJECT_KEY, DESTIGMATIZED_DATASET_S3_OBJECT_KEY, GENOMIC_DATASET_S3_OBJECT_KEY: strings with no default, no stack" python3 -I - "$DEPLOY_XML" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
defs = r.findall(".//parameterDefinitions/*")
assert [d.findtext("name") for d in defs] == ["DATA_S3_OBJECT_KEY", "DESTIGMATIZED_DATASET_S3_OBJECT_KEY", "GENOMIC_DATASET_S3_OBJECT_KEY"]
for d in defs:
    assert d.tag == "hudson.model.StringParameterDefinition", d.tag
    assert (d.findtext("defaultValue") or "") == "", d.findtext("defaultValue")
PY
check "the three keys are validated (7 to 40 lowercase hex) before the deployment-state lock is taken, outside the timeout and the try" python3 -I - "$T/pipeline.code" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
val = g.index("/[0-9a-f]{7,40}/")
# each key comes from its own parameter, trimmed
assert re.search(r"^def authKey = \(params\.DATA_S3_OBJECT_KEY \?: ''\)\.trim\(\)$", g, re.M)
assert re.search(r"^def openKey = \(params\.DESTIGMATIZED_DATASET_S3_OBJECT_KEY \?: ''\)\.trim\(\)$", g, re.M)
assert re.search(r"^def genomicKey = \(params\.GENOMIC_DATASET_S3_OBJECT_KEY \?: ''\)\.trim\(\)$", g, re.M)
# the validated list holds exactly the three [parameter name, variable] pairs, in this order: no key reaches a deploy job unchecked
m = re.search(r"^for \(entry in \[(.*)\]\) \{$", g, re.M)
assert m, "no validation loop"
pairs = re.findall(r"\['(\w+)', (\w+)\]", m.group(1))
assert pairs == [("DATA_S3_OBJECT_KEY", "authKey"), ("DESTIGMATIZED_DATASET_S3_OBJECT_KEY", "openKey"), ("GENOMIC_DATASET_S3_OBJECT_KEY", "genomicKey")], pairs
assert re.sub(r"\['\w+', \w+\]", "", m.group(1)).replace(",", "").strip() == "", m.group(1)
assert m.start() < val
assert val < g.index("build job: 'Retrieve Deployment State'")
assert val < g.index("try {") < g.index("timeout(")
assert re.search(r"if \(!\(entry\[1\] ==~ /\[0-9a-f\]\{7,40\}/\)\) \{\s*error\(", g)
PY
check "the 4 hour timeout wraps everything after the validation: lock, stacks.json, the re-check and the three deploys" python3 -I - "$T/pipeline.code" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
t = g.index("timeout(time: 4, unit: 'HOURS') {")
assert g.count("timeout(") == 1
# brace matching from the opening brace of the timeout block
i = g.index("{", t)
depth, j = 0, i
while True:
    c = g[j]
    depth += (c == "{") - (c == "}")
    if depth == 0:
        break
    j += 1
body = g[i:j]
for needle in ("build job: 'Retrieve Deployment State'", "copyArtifacts", "next_prod", 'lock("stack-', "sh '''", "build job: 'PIC-SURE HPDS Auth Deploy'", "build job: 'PIC-SURE HPDS Open Deploy'", "build job: 'PIC-SURE Auth Micro App Deploy'"):
    assert needle in body, needle
assert "build job: 'Unlock Deployment State'" not in body
assert g.index("/[0-9a-f]{7,40}/") < t
PY
check "the lock is taken by building Retrieve Deployment State, then stacks.json is copied from that very build and parsed with JsonSlurperClassic" python3 -I - "$T/pipeline.code" << 'PY'
import sys
g = open(sys.argv[1]).read()
assert g.startswith("import groovy.json.JsonSlurperClassic")
r = g.index("build job: 'Retrieve Deployment State'")
c = g.index("copyArtifacts filter: 'stacks.json', projectName: 'Retrieve Deployment State', selector: specific(\"\" + retrieved.number)")
p = g.index("new JsonSlurperClassic().parseText(readFile('stacks.json'))")
assert r < c < p
assert g.count("build job: 'Retrieve Deployment State'") == 1 and g.count("JsonSlurperClassic()") == 1
PY
check "lockAcquired is false at the start and set to true once, right after Retrieve Deployment State succeeded, before anything else can fail" python3 -I - "$T/pipeline.code" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
assert g.count("def lockAcquired = false") == 1
sets = [m.start() for m in re.finditer(r"\blockAcquired = true\b", g)]
assert len(sets) == 1, sets
r = g.index("build job: 'Retrieve Deployment State'")
assert r < sets[0] < g.index("copyArtifacts")
# between the Retrieve call and the flag there is only the catch block of the call: it reports and rethrows, it does not unlock
between = g[r:sets[0]]
assert re.fullmatch(r"build job: 'Retrieve Deployment State'\n\s*\} catch \(Exception retrieveError\) \{\n\s*echo \"[^\"$]*\"\n\s*throw retrieveError\n\s*\}\n\s*", between), between
assert "put-object-legal-hold" in between and "Unlock Deployment State by hand" in between
assert re.search(r"retrieved = build job: 'Retrieve Deployment State'", g)
PY
check "the staging stack is environments.next_prod read after Retrieve Deployment State; environments.prod and the prod stack are never read" python3 -I - "$T/pipeline.code" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
assert g.index("build job: 'Retrieve Deployment State'") < g.index("next_prod")
assert g.count("next_prod") == 2 and g.count("stacks?.environments?.next_prod") == 1  # the read and the error text
assert not re.search(r"environments\??\.prod\b", g) and not re.search(r"\bprod\b", g), "prod is referenced"
assert not re.search(r"get\(['\"]prod", g) and "live_stack" not in g
PY
check "an empty, null or not plain stack name is refused before the stack lock" python3 -I - "$T/pipeline.code" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
m = re.search(r"if \(!\(candidate instanceof String\) \|\| candidate == 'null' \|\| !\(candidate ==~ /(.*?)/\)\) \{\s*error\(", g)
assert m and m.group(1) == "[A-Za-z0-9._-]+", m and m.group(1)
assert m.start() < g.index("stagingStack = candidate") < g.index('lock("stack-')
PY
check "lock(\"stack-\${...}\") is the same resource name as the Build and Deploy jobs and wraps the re-check and all three deploys, and only those" python3 -I - "$T/pipeline.code" "$JOBS" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
assert len(re.findall(r'lock\("stack-\$\{stagingStack\}"\)', g)) == 1 and g.count("lock(") == 1
# the Build and Deploy jobs use the same resource name
b = open(sys.argv[2] + "/PIC-SURE HPDS Auth Build and Deploy/config.xml").read()
assert 'lock(&quot;stack-${targetStack}&quot;)' in b
i = g.index('lock("stack-${stagingStack}") {')
i = g.index(") {", i) + 2  # the opening brace of the lock block, not the one of ${stagingStack}
depth, j = 0, i
while True:
    c = g[j]
    depth += (c == "{") - (c == "}")
    if depth == 0:
        break
    j += 1
body = g[i:j]
assert body.count("sh '''") == 1
builds = re.findall(r"build job: '([^']+)'", body)
assert builds == ["PIC-SURE HPDS Auth Deploy", "PIC-SURE HPDS Open Deploy", "PIC-SURE Auth Micro App Deploy"], builds
outside = g[:i] + g[j:]
assert "sh '''" not in outside
assert [b for b in re.findall(r"build job: '([^']+)'", outside)] == ["Retrieve Deployment State", "Unlock Deployment State"]
assert body.index("sh '''") < body.index("build job: 'PIC-SURE HPDS Auth Deploy'")
PY
check "the three deploys: order, TARGET_STACK = the staging stack, and exactly the parameters each job defines (checked against their XML)" python3 -I - "$T/pipeline.code" "$JOBS" << 'PY'
import re, sys, xml.etree.ElementTree as E
g = open(sys.argv[1]).read()
calls = re.findall(r"build job: '(PIC-SURE [^']+)', parameters: \[(.*?)\n\s*\]", g, re.S)
assert [c[0] for c in calls] == ["PIC-SURE HPDS Auth Deploy", "PIC-SURE HPDS Open Deploy", "PIC-SURE Auth Micro App Deploy"], calls
expected = {
    "PIC-SURE HPDS Auth Deploy": {"TARGET_STACK": "stagingStack", "DATA_S3_OBJECT_KEY": "authKey", "GENOMIC_DATASET_S3_OBJECT_KEY": "genomicKey"},
    "PIC-SURE HPDS Open Deploy": {"TARGET_STACK": "stagingStack", "DESTIGMATIZED_DATASET_S3_OBJECT_KEY": "openKey"},
    "PIC-SURE Auth Micro App Deploy": {"TARGET_STACK": "stagingStack", "DATASET_S3_OBJECT_KEY": "authKey"},
}
for job, body in calls:
    got = dict(re.findall(r"name: '(\w+)', value: (\w+)", body))
    assert got == expected[job], (job, got)
    assert len(re.findall(r"\$class: 'StringParameterValue'", body)) == len(got)
    defined = {p.findtext("name") for p in E.parse(sys.argv[2] + "/" + job + "/config.xml").getroot().findall(".//parameterDefinitions/*")}
    assert set(got) <= defined, (job, set(got) - defined)
    assert "propagate" not in body
assert "propagate" not in g  # default propagate: a failed deploy fails the build, later jobs are not started
PY
check "bucket parameters of the deploy jobs are not passed: they default to the stack bucket" python3 -I - "$T/pipeline.code" "$JOBS" << 'PY'
import sys, xml.etree.ElementTree as E
g = open(sys.argv[1]).read()
assert "S3_BUCKET_NAME" not in g and "S3_STACK_BUCKET" not in g and "STACK_S3_BUCKET" not in g
for job, name in (("PIC-SURE HPDS Auth Deploy", "S3_BUCKET_NAME"), ("PIC-SURE HPDS Open Deploy", "S3_BUCKET_NAME"), ("PIC-SURE Auth Micro App Deploy", "S3_STACK_BUCKET")):
    d = [p for p in E.parse(sys.argv[2] + "/" + job + "/config.xml").getroot().findall(".//parameterDefinitions/*") if p.findtext("name") == name]
    assert len(d) == 1 and d[0].findtext("defaultValue") == "${stack_s3_bucket}", (job, name)
PY
check "Unlock Deployment State is built once, in the finally block, only if lockAcquired; a failed unlock fails the build and says what to do" python3 -I - "$T/pipeline.code" << 'PY'
import re, sys
g = open(sys.argv[1]).read()
assert g.count("build job: 'Unlock Deployment State'") == 1 and g.count("finally") == 1
f = g.index("} finally {")
assert f > g.index("timeout(") and g.index("try {") < g.index("timeout(")
tail = g[f:]
assert tail.count("if (") == 1 and tail.count("lockAcquired") == 1
# brace-match the guard: the Unlock call and its catch are inside the block of "if (lockAcquired) {" and nothing else is
gi = tail.index("if (lockAcquired) {")
i = tail.index("{", gi)
depth, j = 0, i
while True:
    c = tail[j]
    depth += (c == "{") - (c == "}")
    if depth == 0:
        break
    j += 1
guarded = tail[i:j]
assert "build job: 'Unlock Deployment State'" in guarded and "catch (Exception unlockError)" in guarded
assert tail[:gi].count("build job") == 0 and tail[j:].count("build job") == 0, "a build outside the guard"
assert re.search(r"catch \(Exception unlockError\) \{\s*def earlier = failureText \? \" The deployment itself failed before: \$\{failureText\}\" : ''\s*error\(\"Unlock Deployment State failed .*Run the job Unlock Deployment State\.\$\{earlier\}\"\)", guarded)
# failureText is filled by a catch around the timeout that rethrows
assert re.search(r"\} catch \(Exception failure\) \{\s*failureText = failure\.message \?: failure\.toString\(\)\s*throw failure\s*\} finally \{", g)
assert "Write Stack State" not in g  # stacks.json is not modified
assert g.index("build job: 'Unlock Deployment State'") > g.index("build job: 'PIC-SURE Auth Micro App Deploy'")
PY
check "the last statement prints 'staging stack <name>: HPDS auth, HPDS open, PSAMA deployed', after the finally block" python3 -I - "$T/pipeline.code" "$T/deploy.desc" << 'PY'
import sys
g = open(sys.argv[1]).read().rstrip("\n").split("\n")
assert g[-1] == 'echo "staging stack ${stagingStack}: HPDS auth, HPDS open, PSAMA deployed"', g[-1]
assert g[-2] == "" and g[-3] == "}"
assert "staging stack <name>: HPDS auth, HPDS open, PSAMA deployed" in open(sys.argv[2]).read()
PY
check "the jobs it builds exist" bash -c "for j in 'Retrieve Deployment State' 'Unlock Deployment State' 'PIC-SURE HPDS Auth Deploy' 'PIC-SURE HPDS Open Deploy' 'PIC-SURE Auth Micro App Deploy'; do test -f \"$JOBS/\$j/config.xml\" || exit 1; done"
check "Retrieve Deployment State archives stacks.json and Unlock Deployment State takes no parameter (what the script relies on)" python3 -I - "$JOBS" << 'PY'
import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1] + "/Retrieve Deployment State/config.xml").getroot()
assert r.findtext(".//hudson.tasks.ArtifactArchiver/artifacts") == "stacks.json"
u = E.parse(sys.argv[1] + "/Unlock Deployment State/config.xml").getroot()
assert not u.findall(".//parameterDefinitions/*")
PY
check "description: what it does, the two locks and their order, the 4 hour limit, never the live stack, Deployment Pipeline rebuild, IAM, and how it is started" bash -c "
    for s in 'STAGING stack' 'DEPLOY_TO_STAGING_STACK=true' 'by hand with the three keys' 'deployment-state lock is taken first' 'fails fast' 'stack lock' 'WAITS' '4 hours' 'environments.next_prod' 'The live stack is never targeted' 'A later Deployment Pipeline run rebuilds the staging stack' 's3:ListBucket (prefix data/*)' 's3:GetObject on data/*' 'Unlock Deployment State' 'does NOT run Unlock Deployment State' 'fails at once' 'put-object-legal-hold' 'abort this job itself' 'staging stack <name>: HPDS auth, HPDS open, PSAMA deployed'; do
        grep -qF -- \"\$s\" '$T/deploy.desc' || { echo \"description lacks: \$s\"; exit 1; }
    done"
check "description: the deployment-state lock is described before the stack lock" python3 -I - "$T/deploy.desc" << 'PY'
import sys
d = open(sys.argv[1]).read()
assert d.index("deployment-state lock is taken first") < d.index("The stack lock") if "The stack lock" in d else d.index("deployment-state lock is taken first") < d.index("stack lock stack-")
PY

# ================================================================ 2. the staged-data re-check, run against a fake aws
check "the sh step has no backslash (Groovy would treat it as an escape inside the string)" bash -c "! grep -q '\\\\' '$T/recheck.sh'"
check "the sh step takes the stack bucket from stack_s3_bucket and the keys from AUTH_KEY and OPEN_KEY" bash -c "grep -q 'stack_s3_bucket' '$T/recheck.sh' && grep -q 'AUTH_KEY' '$T/recheck.sh' && grep -q 'OPEN_KEY' '$T/recheck.sh'"
check "the Groovy string of the sh step is single quoted: no interpolation of stack_s3_bucket or the keys by Groovy" python3 -I - "$T/pipeline.code" << 'PY'
import sys
g = open(sys.argv[1]).read()
assert "sh '''" in g and 'sh """' not in g
assert 'withEnv(["AUTH_KEY=${authKey}", "OPEN_KEY=${openKey}"])' in g
PY
if command -v shellcheck > /dev/null 2>&1; then
    check "shellcheck: the sh step is clean" shellcheck -s bash "$T/recheck.sh"
else
    echo "skip - shellcheck not installed"
fi

BIN="$T/bin"
mkdir -p "$BIN"
cat > "$BIN/aws" << 'FAKE_AWS'
#!/bin/bash
# fake aws: bucket/key lives at $FAKE_S3/<bucket>/<key>; every call is logged. Only read calls exist.
echo "aws $*" >> "$FAKE_AWS_LOG"
bucket="" key="" prefix=""
pos=()
while [ $# -gt 0 ]; do
    case "$1" in
        --bucket) bucket="$2"; shift 2 ;;
        --key) key="$2"; shift 2 ;;
        --prefix) prefix="$2"; shift 2 ;;
        --output | --query | --region | --profile) shift 2 ;;
        --*) shift ;;
        *) pos+=("$1"); shift ;;
    esac
done
case "${pos[0]}/${pos[1]}" in
    s3api/head-object)
        f="$FAKE_S3/$bucket/$key"
        [ -f "$f" ] || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254; }
        printf '{"ContentLength": %s}\n' "$(wc -c < "$f" | tr -d ' ')"
        ;;
    s3api/list-objects-v2)
        [ -z "${FAKE_LIST_DENIED:-}" ] || { echo "An error occurred (AccessDenied) when calling the ListObjectsV2 operation" >&2; exit 255; }
        (cd "$FAKE_S3/$bucket" 2> /dev/null && find . -type f | sed 's|^\./||' | sort) | while IFS= read -r k; do
            case "$k" in "$prefix"*) printf '%s\n' "$k" ;; esac
        done | jq -R -s -c 'split("\n") | map(select(length > 0)) | if length == 0 then empty else {Contents: map({Key: .})} end'
        ;;
    *)
        echo "fake aws: unsupported: ${pos[*]}" >&2
        exit 2
        ;;
esac
FAKE_AWS
chmod +x "$BIN/aws"
export FAKE_S3="$T/s3"
export FAKE_AWS_LOG="$T/aws.log"
export PATH="$BIN:$PATH"
STACK=stack-bucket
A=abcdef1
O=0123456
AUTH_DIR=javabins_rekeyed
OPEN_DIR=destigmatized_javabins_rekeyed

world() { rm -rf "$FAKE_S3"; mkdir -p "$FAKE_S3/$STACK"; : > "$FAKE_AWS_LOG"; unset FAKE_LIST_DENIED; }
put() { mkdir -p "$(dirname "$FAKE_S3/$STACK/$1")"; printf 'x' > "$FAKE_S3/$STACK/$1"; }
stage_all() { # per-file auth and open data and the fence mapping
    put "data/$A/$AUTH_DIR/manifest.tsv"
    put "data/$O/$OPEN_DIR/manifest.tsv"
    put "data/$A/fence_mapping.json"
}
recheck() { # run the sh step: exit code in $rc, stderr in $T/err, stdout in $T/out
    AUTH_KEY="$A" OPEN_KEY="$O" stack_s3_bucket="$STACK" bash "$T/recheck.sh" > "$T/out" 2> "$T/err" < /dev/null
    rc=$?
}

world
stage_all
recheck
[ "$rc" = 0 ] && ok "re-check: per-file auth, per-file open and the fence mapping staged: passes" || { bad "re-check, all staged (rc=$rc)"; cat "$T/err"; }
check "re-check: says what it checked" grep -qx "staged data re-checked in s3://$STACK: auth $A, open $O, fence_mapping.json" "$T/out"
check "re-check: only list and head calls, only on the stack bucket" bash -c "test -s '$FAKE_AWS_LOG' && ! grep -vE '^aws s3api (list-objects-v2|head-object) --bucket $STACK ' '$FAKE_AWS_LOG'"

world
put "data/$A/$AUTH_DIR.tar"
put "data/$O/$OPEN_DIR.tar"
put "data/$A/fence_mapping.json"
recheck
[ "$rc" = 0 ] && ok "re-check: legacy tars for both variants count as staged" || { bad "re-check, tars (rc=$rc)"; cat "$T/err"; }

world
stage_all
rm "$FAKE_S3/$STACK/data/$A/$AUTH_DIR/manifest.tsv"
recheck
[ "$rc" = 1 ] && grep -q "ERROR: auth dataset is not staged: deploy key $A" "$T/err" && grep -q 'Nothing was deployed' "$T/err" && ok "re-check: auth not staged: fails and names the key" || { bad "re-check, auth missing (rc=$rc)"; cat "$T/err"; }
check "re-check, auth missing: the open dataset and the fence mapping are not reported" test "$(grep -c '^ERROR' "$T/err")" = 1

world
stage_all
rm "$FAKE_S3/$STACK/data/$O/$OPEN_DIR/manifest.tsv"
recheck
[ "$rc" = 1 ] && grep -q "ERROR: open dataset is not staged: deploy key $O" "$T/err" && ok "re-check: open not staged: fails and names the key" || { bad "re-check, open missing (rc=$rc)"; cat "$T/err"; }

world
stage_all
rm "$FAKE_S3/$STACK/data/$A/fence_mapping.json"
recheck
[ "$rc" = 1 ] && grep -q "ERROR: data/$A/fence_mapping.json is missing" "$T/err" && ok "re-check: fence_mapping.json missing: fails" || { bad "re-check, fence missing (rc=$rc)"; cat "$T/err"; }

world
put "data/$O/fence_mapping.json"
recheck
[ "$rc" = 1 ] && [ "$(grep -c '^ERROR' "$T/err")" = 3 ] && ok "re-check: nothing staged (the open key's fence mapping does not count): all three problems are reported" || { bad "re-check, empty (rc=$rc)"; cat "$T/err"; }

world
rm -rf "$FAKE_S3"
recheck
[ "$rc" = 1 ] && grep -q 'Nothing was deployed' "$T/err" && ok "re-check: an empty listing (no bucket content) means absent" || { bad "re-check, no bucket (rc=$rc)"; cat "$T/err"; }

world
put "data/$A/$AUTH_DIR/manifest.tsv.bak"
put "data/$A/$AUTH_DIR/manifest.tsv2"
put "data/$O/$OPEN_DIR.tar.gz"
put "data/$A/fence_mapping.json.old"
recheck
[ "$rc" = 1 ] && [ "$(grep -c '^ERROR' "$T/err")" = 3 ] && ok "re-check: keys that only share the prefix do not count (exact match)" || { bad "re-check, prefix collisions (rc=$rc)"; cat "$T/err"; }

world
stage_all
export FAKE_LIST_DENIED=1
recheck
[ "$rc" = 0 ] && ok "re-check: list denied: falls back to head-object and passes when everything is staged" || { bad "re-check, list denied, staged (rc=$rc)"; cat "$T/err"; }
check "re-check, list denied: head-object was used" grep -q 'head-object' "$FAKE_AWS_LOG"
rm "$FAKE_S3/$STACK/data/$A/fence_mapping.json"
recheck
[ "$rc" = 1 ] && ok "re-check: list denied: fails when the fence mapping is missing" || { bad "re-check, list denied, fence missing (rc=$rc)"; cat "$T/err"; }
unset FAKE_LIST_DENIED

# ================================================================ 3. the whole script against a fake pipeline DSL
HARNESS="$HERE/deploy-staging.harness.groovy"
if command -v groovy > /dev/null 2>&1; then
    STACKS_OK='{"environments":{"prod":"live-stk","next_prod":"blue-stk"}}'
    # scen <name> [VAR=value ...]: runs the script with the default scenario plus the overrides; trace in $T/<name>.trace, exit code in $rc
    scen() {
        local name="$1"
        shift
        (
            export SCEN_AUTH="$A" SCEN_OPEN="$O" SCEN_GENOMIC=fedcba9 SCEN_STACKS="$STACKS_OK"
            for kv in "$@"; do export "${kv?}"; done
            groovy "$HARNESS" "$T/pipeline.groovy" 2> /dev/null | grep -E '^(T|RESULT): ' > "$T/$name.trace"
            exit "${PIPESTATUS[0]}"
        )
        rc=$?
    }
    traced() { grep -qxF -- "T: $2" "$T/$1.trace"; }
    has() { grep -qF -- "$2" "$T/$1.trace"; }
    count() { grep -cF -- "$2" "$T/$1.trace"; }
    line_of() { grep -nF -- "$2" "$T/$1.trace" | head -1 | cut -d: -f1; }

    scen success
    [ "$rc" = 0 ] && ok "script: success: exit 0" || { bad "script: success (rc=$rc)"; cat "$T/success.trace"; }
    check "script: success: the staging stack is next_prod and the live stack name never appears" bash -c "grep -q 'lock stack-blue-stk enter' '$T/success.trace' && ! grep -q 'live-stk' '$T/success.trace'"
    check "script: success: order is timeout, Retrieve, copy, parse, lock, re-check, Auth, Open, PSAMA, unlock lock, Unlock, success line" python3 -I - "$T/success.trace" << 'PY'
import sys
t = [l.rstrip("\n") for l in open(sys.argv[1])]
want = [
    "T: timeout 4 HOURS",
    "T: build Retrieve Deployment State",
    "T: copyArtifacts Retrieve Deployment State stacks.json specific:101",
    "T: readFile stacks.json",
    "T: lock stack-blue-stk enter",
    "T: sh",
    "T: build PIC-SURE HPDS Auth Deploy TARGET_STACK=blue-stk,DATA_S3_OBJECT_KEY=abcdef1,GENOMIC_DATASET_S3_OBJECT_KEY=fedcba9",
    "T: build PIC-SURE HPDS Open Deploy TARGET_STACK=blue-stk,DESTIGMATIZED_DATASET_S3_OBJECT_KEY=0123456",
    "T: build PIC-SURE Auth Micro App Deploy TARGET_STACK=blue-stk,DATASET_S3_OBJECT_KEY=abcdef1",
    "T: lock stack-blue-stk exit",
    "T: build Unlock Deployment State",
    "T: echo staging stack blue-stk: HPDS auth, HPDS open, PSAMA deployed",
    "RESULT: ok",
]
got = [l for l in t if not l.startswith(("T: stage ", "T: node", "T: withEnv", "T: echo staging stack: "))]
assert got == want, got
PY
    check "script: success: the sh step gets the auth and open keys as environment" has success "T: withEnv AUTH_KEY=$A OPEN_KEY=$O"
    check "script: success: the success line is the last line the script prints before RESULT" test "$(tail -2 "$T/success.trace" | head -1)" = "T: echo staging stack blue-stk: HPDS auth, HPDS open, PSAMA deployed"

    scen retrieve_fails SCEN_FAIL_JOBS="Retrieve Deployment State"
    [ "$rc" = 1 ] && ok "script: Retrieve Deployment State fails (lock held): the build fails" || bad "script: retrieve fails (rc=$rc)"
    check "script: lock held: nothing else is built, no stack lock, and Unlock is NOT run" bash -c "test \"\$(grep -c '^T: build ' '$T/retrieve_fails.trace')\" = 1 && ! grep -q 'lock stack-' '$T/retrieve_fails.trace' && ! grep -q 'build Unlock' '$T/retrieve_fails.trace'"
    check "script: Retrieve fails: the build log tells the operator to check put-object-legal-hold and unlock by hand; the failure is the original one" bash -c "grep -q 'T: echo Retrieve Deployment State did not finish.*put-object-legal-hold.*Unlock Deployment State by hand' '$T/retrieve_fails.trace' && grep -q 'RESULT: failed: job failed: Retrieve Deployment State' '$T/retrieve_fails.trace'"

    for job in "PIC-SURE HPDS Auth Deploy" "PIC-SURE HPDS Open Deploy" "PIC-SURE Auth Micro App Deploy"; do
        n="deploy_fails_$(printf '%s' "$job" | tr -c 'A-Za-z' '_')"
        scen "$n" SCEN_FAIL_JOBS="$job"
        [ "$rc" = 1 ] && ok "script: $job fails: the build fails" || bad "script: $job fails (rc=$rc)"
        check "script: $job fails: the lock is released after the stack lock, no success line" bash -c "
            tr='$T/$n.trace'
            test \"\$(grep -n 'lock stack-blue-stk exit' \$tr | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'build Unlock Deployment State' \$tr | cut -d: -f1)\" && ! grep -q 'deployed\$' \$tr"
    done
    check "script: Auth Deploy fails: Open and PSAMA are not started" bash -c "! grep -q 'build PIC-SURE HPDS Open Deploy\|build PIC-SURE Auth Micro App Deploy' '$T/deploy_fails_PIC_SURE_HPDS_Auth_Deploy.trace'"
    check "script: Open Deploy fails: Auth ran, PSAMA is not started" bash -c "grep -q 'build PIC-SURE HPDS Auth Deploy' '$T/deploy_fails_PIC_SURE_HPDS_Open_Deploy.trace' && ! grep -q 'build PIC-SURE Auth Micro App Deploy' '$T/deploy_fails_PIC_SURE_HPDS_Open_Deploy.trace'"
    check "script: PSAMA Deploy fails: Auth and Open ran" bash -c "grep -q 'build PIC-SURE HPDS Auth Deploy' '$T/deploy_fails_PIC_SURE_Auth_Micro_App_Deploy.trace' && grep -q 'build PIC-SURE HPDS Open Deploy' '$T/deploy_fails_PIC_SURE_Auth_Micro_App_Deploy.trace'"

    scen recheck_fails SCEN_SH_FAIL=1
    [ "$rc" = 1 ] && ok "script: the staged-data re-check fails: the build fails" || bad "script: re-check fails (rc=$rc)"
    check "script: re-check fails: no deploy job is built, the lock is released" bash -c "! grep -q 'build PIC-SURE' '$T/recheck_fails.trace' && grep -q 'build Unlock Deployment State' '$T/recheck_fails.trace' && grep -q 'lock stack-blue-stk exit' '$T/recheck_fails.trace'"

    scen interrupted SCEN_INTERRUPT_AT_SH=1
    [ "$rc" = 1 ] && ok "script: an abort or the timeout (InterruptedException) during the deploy: the build fails" || bad "script: interrupted (rc=$rc)"
    check "script: interrupted: Unlock Deployment State is still built, no deploy job started, no success line" bash -c "grep -q 'build Unlock Deployment State' '$T/interrupted.trace' && ! grep -q 'build PIC-SURE' '$T/interrupted.trace' && ! grep -q 'deployed\$' '$T/interrupted.trace'"

    scen unlock_fails SCEN_FAIL_JOBS="Unlock Deployment State"
    [ "$rc" = 1 ] && ok "script: Unlock Deployment State fails after a good deploy: the build fails" || bad "script: unlock fails (rc=$rc)"
    check "script: unlock fails: the message tells the operator to run Unlock Deployment State, and there is no success line" bash -c "grep -q 'RESULT: failed: error: Unlock Deployment State failed (.*); the deployment-state lock is still held. Run the job Unlock Deployment State.' '$T/unlock_fails.trace' && ! grep -q 'deployed\$' '$T/unlock_fails.trace'"
    check "script: unlock fails: the three deploys had run" test "$(count unlock_fails 'build PIC-SURE')" = 3
    check "script: unlock fails after a good deploy: no earlier failure is mentioned" bash -c "! grep -q 'failed before' '$T/unlock_fails.trace'"
    scen both_fail SCEN_FAIL_JOBS="PIC-SURE HPDS Open Deploy,Unlock Deployment State"
    [ "$rc" = 1 ] && ok "script: a deploy and the unlock both fail: the build fails" || bad "script: deploy and unlock fail (rc=$rc)"
    check "script: deploy and unlock both fail: the message names the unlock and repeats the deploy failure" bash -c "grep -q 'RESULT: failed: error: Unlock Deployment State failed (.*); the deployment-state lock is still held. Run the job Unlock Deployment State. The deployment itself failed before: job failed: PIC-SURE HPDS Open Deploy' '$T/both_fail.trace'"

    # stacks.json that does not name a plain staging stack: the lock was taken, so it is released; nothing is deployed
    for case_ in missing:'{"environments":{"prod":"live-stk"}}' nullvalue:'{"environments":{"prod":"live-stk","next_prod":null}}' empty:'{"environments":{"prod":"live-stk","next_prod":""}}' nullword:'{"environments":{"next_prod":"null"}}' space:'{"environments":{"next_prod":"a b"}}' slash:'{"environments":{"next_prod":"a/b"}}' number:'{"environments":{"next_prod":12}}' list:'{"environments":{"next_prod":["blue-stk"]}}' noenv:'{}' semicolon:'{"environments":{"next_prod":"a;rm"}}'; do
        name="stack_${case_%%:*}"
        scen "$name" SCEN_STACKS="${case_#*:}"
        [ "$rc" = 1 ] && has "$name" 'not a plain stack name' && ok "script: stacks.json '${case_%%:*}': refused" || { bad "script: stacks.json ${case_%%:*} (rc=$rc)"; cat "$T/$name.trace"; }
        check "script: stacks.json '${case_%%:*}': no stack lock, no deploy, Unlock runs (the lock was taken)" bash -c "! grep -q 'lock stack-\|build PIC-SURE\|sh\$' '$T/$name.trace' && grep -q 'build Unlock Deployment State' '$T/$name.trace'"
    done
    scen stack_prod_only SCEN_STACKS='{"environments":{"prod":"live-stk"}}'
    check "script: only environments.prod present: the live stack is never used as a fallback" bash -c "! grep -q 'lock stack-' '$T/stack_prod_only.trace'"

    # bad keys: refused before anything is built; no Unlock
    for param in AUTH OPEN GENOMIC; do
        for badkey in "" ABCDEF0 abcdef ../abcdef0 "abc def0" "abcdef0;id" "0000000000000000000000000000000000000000a" "abcdefg"; do
            scen "badkey" "SCEN_$param=$badkey"
            if [ "$rc" = 1 ] && [ "$(grep -c '^T: ' "$T/badkey.trace")" = 0 ] && grep -q 'must be a deploy key of 7 to 40 lowercase hex characters' "$T/badkey.trace"; then
                ok "script: $param key '$badkey': refused before any step (no Retrieve, no Unlock)"
            else
                bad "script: $param key '$badkey' (rc=$rc)"
                cat "$T/badkey.trace"
            fi
        done
    done
    for good in abcdef0 0123456789abcdef0123456789abcdef01234567; do
        scen goodkey SCEN_AUTH="$good"
        [ "$rc" = 0 ] && ok "script: a key of ${#good} hex characters is accepted" || bad "script: good key $good (rc=$rc)"
    done
else
    echo "skip - no groovy on PATH: the script was only checked statically and its sh step was run (sections 1 and 2)"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
