#!/usr/bin/env python3
import json
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PIPELINE = ROOT / "jenkins-docker/jobs/PIC-SURE Pipeline Build and Deploy/config.xml"
LEGACY_PIPELINE = ROOT / "jenkins-docker/jobs/PIC-SURE Pipeline/config.xml"
DEPLOYMENT_PIPELINE = ROOT / "jenkins-docker/jobs/Deployment Pipeline/config.xml"
TEARDOWN_REBUILD = ROOT / "jenkins-docker/jobs/Teardown and Rebuild Stage Environment/config.xml"
AWAIT_INITIALIZATION = ROOT / "jenkins-docker/jobs/Await Initialization/config.xml"
CHECK_FOR_UPDATES = ROOT / "jenkins-docker/jobs/Check For Updates/config.xml"
RETRIEVE_BUILD_SPEC = ROOT / "jenkins-docker/jobs/Retrieve Build Spec/config.xml"
FRONTEND_BUILD = ROOT / "jenkins-docker/jobs/PIC-SURE Frontend Build/config.xml"
WILDFLY = ROOT / "jenkins-docker/jobs/PIC-SURE Wildfly Stack Deploy/config.xml"
FRONTEND = ROOT / "jenkins-docker/jobs/PIC-SURE Frontend Deploy/config.xml"
QUERY_IMAGE = ROOT / "jenkins-docker/jobs/PIC-SURE HPDS Query Service Image/config.xml"
RENDER_SERVICE_CONFIG = (
    ROOT / "jenkins-docker/jobs/Render PIC-SURE Service Config Templates/config.xml"
)
VALIDATOR = ROOT / "jenkins-docker/scripts/validate-banner-rollout.py"
CONTRACT = ROOT / "jenkins-docker/scripts/banner-rollout-contract.json"
GROOVY_GUARD_RUNNER = ROOT / "tests/fisma-banner-rollout/run_system_groovy_guard.groovy"
CHECK_FOR_UPDATES_RUNNER = ROOT / "tests/fisma-banner-rollout/run_check_for_updates_wait.groovy"
PIPELINE_VALIDATION_RUNNER = ROOT / "tests/fisma-banner-rollout/run_pipeline_validation.groovy"
CRITICAL_IMAGE_JOBS = (
    ROOT / "jenkins-docker/jobs/PIC-SURE Gateway Image/config.xml",
    ROOT / "jenkins-docker/jobs/PIC-SURE Operations Service Image/config.xml",
    ROOT / "jenkins-docker/jobs/PIC-SURE HPDS Query Service Image/config.xml",
    ROOT / "jenkins-docker/jobs/PIC-SURE Auth Micro App Image/config.xml",
    FRONTEND_BUILD,
)


def current_jenkins_commit() -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def xml_script(path: Path) -> str:
    root = ET.parse(path).getroot()
    script = root.find(".//script")
    if script is None or script.text is None:
        raise AssertionError(f"Missing Groovy script in {path}")
    return script.text


def xml_shell(path: Path) -> str:
    root = ET.parse(path).getroot()
    command = root.find(".//command")
    if command is None or command.text is None:
        raise AssertionError(f"Missing shell command in {path}")
    return command.text


def xml_shells(path: Path) -> list[str]:
    root = ET.parse(path).getroot()
    return [node.text for node in root.findall(".//hudson.tasks.Shell/command") if node.text]


def run_render_service_config(
    infrastructure: Path, operations_override: str
) -> tuple[subprocess.CompletedProcess[str], list[str], str]:
    secret = "synthetic-render-logging-key"
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        home = root / "jenkins-home"
        bash_functions = home / "workspace/Bash_Functions"
        bash_functions.mkdir(parents=True)
        effects = root / "effects.log"
        (bash_functions / "functions.sh").write_text(
            "assume_role() { printf 'assume-role\\n' >> \"$FAKE_EFFECTS\"; }\n"
            "reset_role() { printf 'reset-role\\n' >> \"$FAKE_EFFECTS\"; }\n"
            "fetch_secret() { printf '{\"username\":\"synthetic-user\",\"password\":\"synthetic-password\"}'; }\n"
            "extract_field() { if [[ \"$2\" == username ]]; then printf 'synthetic-user'; else printf 'synthetic-password'; fi; }\n"
            "initialize_shared_db_config() { :; }\n"
            "get_token_by_uuid() { printf 'synthetic-introspection-token'; }\n"
            "unset_shared_db_config() { :; }\n",
            encoding="utf-8",
        )

        workspace = root / "workspace"
        renderer = workspace / "app-infrastructure/template-renderer"
        shutil.copytree(infrastructure / "app-infrastructure/template-renderer", renderer)
        fake_s3 = root / "s3"
        (fake_s3 / "configs/pic-sure-logging").mkdir(parents=True)
        (fake_s3 / "configs/pic-sure-logging/logging.env").write_text(
            f"LOGGING_API_KEY={secret}\n", encoding="utf-8"
        )
        override = fake_s3 / "configs/operations/templates/staging/operations.env.tftpl"
        override.parent.mkdir(parents=True)
        override.write_text(operations_override, encoding="utf-8")

        fake_bin = root / "bin"
        fake_bin.mkdir()
        aws = fake_bin / "aws"
        aws.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "[[ \"$1 $2\" == 's3 cp' ]] || exit 64\n"
            "key=${3#s3://*/}\n"
            "source=$FAKE_S3/$key\n"
            "if [[ ! -f \"$source\" ]]; then echo 'An error occurred (404)' >&2; exit 1; fi\n"
            "cp \"$source\" \"$4\"\n",
            encoding="utf-8",
        )
        aws.chmod(0o755)
        grep = fake_bin / "grep"
        grep.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ \"${1:-}\" == -oP ]]; then sed -n 's/^LOGGING_API_KEY=//p' \"$3\"; exit 0; fi\n"
            "exec /usr/bin/grep \"$@\"\n",
            encoding="utf-8",
        )
        grep.chmod(0o755)
        terraform = fake_bin / "terraform"
        terraform.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf 'terraform-%s\\n' \"$1\" >> \"$FAKE_EFFECTS\"\n"
            "[[ \"$1\" == apply ]] || exit 0\n"
            "logging_key=\n"
            "target_stack=\n"
            "for argument in \"$@\"; do\n"
            "  case \"$argument\" in\n"
            "    -var=logging_api_key=*) logging_key=${argument#-var=logging_api_key=} ;;\n"
            "    -var=target_stack=*) target_stack=${argument#-var=target_stack=} ;;\n"
            "  esac\n"
            "done\n"
            "destination=$FAKE_S3/configs/operations/$target_stack/operations.env\n"
            "mkdir -p \"$(dirname \"$destination\")\"\n"
            "sed \"s/\\${logging_api_key}/$logging_key/g\" templates/operations.env.tftpl > \"$destination\"\n",
            encoding="utf-8",
        )
        terraform.chmod(0o755)

        shell = xml_shell(RENDER_SERVICE_CONFIG) + "\nprintf 'success\\n' >> \"$FAKE_EFFECTS\"\n"
        environment = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "FAKE_EFFECTS": str(effects),
            "FAKE_S3": str(fake_s3),
            "JENKINS_HOME": str(home),
            "TARGET_STACK": "staging",
            "database_app_user_secret_name": "synthetic-app-user",
            "database_host_address": "synthetic-db:3306",
            "application_id_for_base_query": "synthetic-app",
            "stack_s3_bucket": "synthetic-bucket",
            "environment_name": "synthetic",
            "env_private_dns_name": "synthetic.invalid",
            "include_open_hpds": "false",
            "TMPDIR": str(root),
        }
        result = subprocess.run(
            ["bash", "-c", shell],
            cwd=workspace,
            env=environment,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        recorded = effects.read_text(encoding="utf-8").splitlines() if effects.exists() else []
        return result, recorded, secret


def xml_system_scripts(path: Path) -> list[str]:
    root = ET.parse(path).getroot()
    return [
        node.text
        for node in root.findall(".//hudson.plugins.groovy.SystemGroovy/source/script/script")
        if node.text
    ]


def run_system_groovy_guard(guard: str, fixture: dict) -> subprocess.CompletedProcess[str]:
    groovy_jar = Path(os.environ["JENKINS_GROOVY_JAR"])
    with tempfile.TemporaryDirectory() as temp:
        temp_path = Path(temp)
        guard_path = temp_path / "guard.groovy"
        fixture_path = temp_path / "fixture.json"
        guard_path.write_text(guard, encoding="utf-8")
        fixture_path.write_text(json.dumps(fixture), encoding="utf-8")
        return subprocess.run(
            [
                "java",
                "-cp",
                str(groovy_jar),
                "groovy.ui.GroovyMain",
                str(GROOVY_GUARD_RUNNER),
                str(fixture_path),
                str(guard_path),
            ],
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )


def run_check_for_updates_wait(
    script: str, banner_rollout: bool, child_result: str
) -> subprocess.CompletedProcess[str]:
    groovy_jar = Path(os.environ["JENKINS_GROOVY_JAR"])
    setup_end = script.index("def buildSpec")
    start = script.index("def deploymentFuture")
    deployment_script = script[:setup_end] + script[start:]
    with tempfile.TemporaryDirectory() as temp:
        script_path = Path(temp) / "check-for-updates.groovy"
        script_path.write_text(deployment_script, encoding="utf-8")
        return subprocess.run(
            [
                "java",
                "-cp",
                str(groovy_jar),
                "groovy.ui.GroovyMain",
                str(CHECK_FOR_UPDATES_RUNNER),
                str(script_path),
                str(banner_rollout).lower(),
                child_result,
            ],
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )


def pipeline_validation_snippet(
    path: Path, pipeline: str, source: str | None = None
) -> str:
    script = source if source is not None else xml_script(path)
    if pipeline == "parent":
        start = script.index("if (banner_rollout_present != params.BANNER_ROLLOUT)")
        end_marker = (
            "banner_forward = banner_rollout_present && "
            "params.BANNER_ROLLOUT_OPERATION == 'FORWARD'"
        )
        end = script.index(end_marker, start) + len(end_marker)
        validation = script[start:end]
        dispatch_stage = script.index(
            "stage('Banner Rollout: Build, Backend, then Frontend')", end
        )
        dispatch_script = script.index("script {", dispatch_stage)
        dispatch_start = script.index("\n", dispatch_script) + 1
        dispatch_end = script.index(
            "\n                }",
            dispatch_start,
        )
        return f"{validation}\n{script[dispatch_start:dispatch_end]}"
    if pipeline == "child":
        start = script.index(
            "validatedArtifactBucket = String.valueOf(params.STACK_S3_BUCKET)"
        )
        stage_marker = "\n    stage('Retrieve Stack')"
        stage = script.index(stage_marker, start)
        end = script.rindex("\n          }", start, stage) + len("\n          }")
        return script[start:end]
    raise AssertionError(f"Unknown pipeline validation snippet: {pipeline}")


def pipeline_entry_parts(path: Path, source: str | None = None) -> tuple[str, str]:
    script = source if source is not None else xml_script(path)
    helper_start = script.index("@NonCPS\ndef requireTrustedBannerParent")
    helper_end = script.index("\ndef retrieveBuildSpecId", helper_start)
    helper = "import com.cloudbees.groovy.cps.NonCPS\n" + script[helper_start:helper_end]
    entry_stage = script.index("stage('Verify Supported Banner Entrypoint')")
    entry_script = script.index("script {", entry_stage)
    guard_start = script.index("\n", entry_script) + 1
    guard_end = script.index("\n        }", guard_start)
    retrieve_stage = script.index("stage('Retrieve Build Spec')", guard_end)
    retrieve_script = script.index("script {", retrieve_stage)
    effect_start = script.index("\n", retrieve_script) + 1
    effect_marker = "retrieveBuildSpecId = result.number"
    effect_end = script.index(effect_marker, effect_start) + len(effect_marker)
    guard = script[guard_start:guard_end]
    return f"{helper}\n{guard}", script[effect_start:effect_end]


def pipeline_entry_snippet(path: Path, source: str | None = None) -> str:
    guard, first_effect = pipeline_entry_parts(path, source)
    return f"{guard}\n{first_effect}"


def run_pipeline_validation(snippet: str, fixture: dict) -> dict:
    groovy_jar = Path(os.environ["JENKINS_GROOVY_JAR"])
    with tempfile.TemporaryDirectory() as temp:
        workspace = Path(temp)
        home = workspace / "jenkins-home"
        banner_home = home / "banner-rollout"
        banner_home.mkdir(parents=True)
        shutil.copy2(VALIDATOR, banner_home / "validate-banner-rollout.py")
        shutil.copy2(CONTRACT, banner_home / "banner-rollout-contract.json")
        shutil.copy2(Path(fixture["buildSpec"]), workspace / "build-spec.json")
        runtime_path = banner_home / "aim-ahead-operator-attestation.json"
        if "runtimeOriginal" in fixture:
            runtime_path.write_text(fixture["runtimeOriginal"], encoding="utf-8")
        snippet_path = workspace / "validation.groovy"
        fixture_path = workspace / "fixture.json"
        snippet_path.write_text(snippet, encoding="utf-8")
        runner_fixture = {
            **fixture,
            "workspace": str(workspace),
            "jenkinsHome": str(home),
            "runtimePath": str(runtime_path),
        }
        fixture_path.write_text(json.dumps(runner_fixture), encoding="utf-8")
        result = subprocess.run(
            [
                "java",
                "-cp",
                str(groovy_jar),
                "groovy.ui.GroovyMain",
                str(PIPELINE_VALIDATION_RUNNER),
                str(fixture_path),
                str(snippet_path),
            ],
            cwd=workspace,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stdout + result.stderr)
        output = json.loads(result.stdout)
        output["maliciousEffect"] = bool(
            fixture.get("maliciousEffect")
            and Path(fixture["maliciousEffect"]).exists()
        )
        return output


def banner_validation_fixture(
    pipeline: str,
    deployment: str,
    bucket: str,
    attestation_json: str = "",
) -> dict:
    release_control = Path(os.environ["BDC_RELEASE_CONTROL_ROOT"])
    infrastructure = Path(os.environ["BDC_INFRASTRUCTURE_ROOT"])
    if deployment == "BDC":
        spec_path = release_control / "build-spec.json"
        release_commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=release_control,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
        controller = "bdc"
    else:
        spec_path = infrastructure / "tests/fisma-banner-rollout/aim-ahead-required-release-input.json"
        release_commit = "a" * 40
        controller = "aim-ahead"
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    parent = pipeline == "parent"
    params = {
        "BANNER_ROLLOUT": True,
        "BANNER_EXPECTED_DEPLOYMENT": deployment,
        "BANNER_EXPECTED_TUPLE_SHA256": spec["banner_rollout"]["tupleSha256"],
        "BANNER_MANUAL_OPERATOR_MODE": False,
        "BANNER_ROLLOUT_OPERATION": "FORWARD" if parent else "NON_BANNER_COMPONENTS",
        "STACK_S3_BUCKET": bucket,
        "MIGRATIONS_COMPLETED_UPSTREAM": False,
        "RUN_DATABASE_MIGRATIONS": False,
        "INCLUDE_PIC_SURE_API": False,
        "INCLUDE_PIC_SURE_AUTH_MICRO_APP": False,
        "INCLUDE_PIC_SURE_FRONTEND": False,
        "BANNER_AIM_ATTESTATION_JSON": attestation_json,
        "deployment_git_hash": "a" * 40,
        "dataset_s3_object_key": "synthetic-dataset",
        "destigmatized_dataset_s3_object_key": "synthetic-destigmatized-dataset",
        "genomic_dataset_s3_object_key": "synthetic-genomic-dataset",
    }
    return {
        "buildSpec": str(spec_path),
        "bannerRolloutPresent": True,
        "bannerDeployment": deployment,
        "bannerTupleSha256": spec["banner_rollout"]["tupleSha256"],
        "releaseControlCommit": release_commit,
        "params": params,
        "env": {
            "JENKINS_SOURCE_COMMIT": current_jenkins_commit(),
            "BANNER_CONTROLLER_DEPLOYMENT": controller,
            "stack_s3_bucket": bucket,
        },
        "causes": [],
    }


def fresh_aim_attestation_json() -> str:
    infrastructure = Path(os.environ["BDC_INFRASTRUCTURE_ROOT"])
    attestation = json.loads(
        (
            infrastructure
            / "tests/fisma-banner-rollout/fixtures/aim-ahead-completed-attestation.synthetic.json"
        ).read_text(encoding="utf-8")
    )
    attestation["attestedAtUtc"] = datetime.now(timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )
    return json.dumps(attestation, sort_keys=True, separators=(",", ":"))


def run_standard_writer(
    path: Path, component_commit: str, shell: str | None = None
) -> tuple[subprocess.CompletedProcess[str], str]:
    with tempfile.TemporaryDirectory() as temp:
        home = Path(temp)
        (home / "banner-rollout").mkdir()
        shutil.copy2(VALIDATOR, home / "banner-rollout/validate-banner-rollout.py")
        shutil.copy2(CONTRACT, home / "banner-rollout/banner-rollout-contract.json")
        fake_bin = home / "bin"
        fake_bin.mkdir()
        effects = home / "effects.log"
        for command in ("aws", "docker"):
            executable = fake_bin / command
            executable.write_text(
                "#!/usr/bin/env bash\n"
                f"printf '%s\\n' '{command}' >> \"$FAKE_EFFECTS\"\n"
                "if [[ \"$1\" == \"save\" ]]; then printf 'synthetic-image'; fi\n"
                "if [[ \"$1 $2\" == \"s3api get-object\" ]]; then : > \"${@: -1}\"; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            executable.chmod(0o755)

        job_shell = shell if shell is not None else xml_shell(path)
        job_shell = job_shell.replace("/var/jenkins_home", str(home))
        env = {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "FAKE_EFFECTS": str(effects),
            "JENKINS_HOME": str(home),
            "JENKINS_SOURCE_COMMIT": current_jenkins_commit(),
            "BANNER_CONTROLLER_DEPLOYMENT": "bdc",
            "BANNER_ROLLOUT_RUN_ID": "",
            "BANNER_ROLLBACK": "false",
            "BANNER_ROLLBACK_ATTESTATION_JSON": "",
            "TARGET_STACK": "staging",
            "S3_BUCKET_NAME": "synthetic-bucket",
            "THEME": "synthetic",
            "DATASOURCE_URL": "jdbc:synthetic",
            "DATASOURCE_USERNAME": "synthetic",
            "STACK_SPECIFIC_APPLICATION_ID": "synthetic",
            "GIT_BRANCH": "origin/reviewed",
            "GIT_COMMIT": component_commit,
        }
        if path != FRONTEND_BUILD:
            module_match = re.search(r'^MODULE="([^"]+)"$', job_shell, re.MULTILINE)
            if module_match is None:
                raise AssertionError(f"Missing MODULE in {path}")
            module = module_match.group(1)
            maven = home / "workspace/PIC-SURE Maven Build - staging"
            target = maven / module / "target"
            target.mkdir(parents=True)
            (target / "synthetic.jar").write_text("synthetic", encoding="utf-8")
            build_info = maven / "build-info"
            build_info.mkdir()
            (build_info / f"{module.replace('/', '_')}.txt").write_text(
                f"GIT_COMMIT_FULL={component_commit}\n"
                f"GIT_COMMIT_SHORT={component_commit[:7]}\n"
                "GIT_BRANCH_SHORT=reviewed\n",
                encoding="utf-8",
            )
            if "pic-sure-auth-microapp" in module:
                auth_target = (
                    maven
                    / "services/pic-sure-auth-microapp/pic-sure-auth-services/target"
                )
                auth_target.mkdir(parents=True, exist_ok=True)
                (auth_target / "pic-sure-auth-services-synthetic.jar").write_text(
                    "synthetic", encoding="utf-8"
                )
            else:
                jar_name = {
                    "services/pic-sure-gateway": "pic-sure-gateway-synthetic.jar",
                    "services/pic-sure-operations-service": "pic-sure-operations-service-synthetic.jar",
                    "services/pic-sure-hpds-query-service": "pic-sure-hpds-query-service-synthetic.jar",
                }[module]
                (target / jar_name).write_text("synthetic", encoding="utf-8")
        result = subprocess.run(
            ["bash", "-c", job_shell],
            cwd=home,
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        return result, effects.read_text(encoding="utf-8") if effects.exists() else ""


def run_shell_guard(
    path: Path,
    extra_env: dict[str, str],
    artifact_commit: str | None = None,
    artifact_run: str = "standard",
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temp:
        home = Path(temp)
        (home / "workspace/Bash_Functions").mkdir(parents=True)
        (home / "banner-rollout").mkdir()
        shutil.copy2(VALIDATOR, home / "banner-rollout/validate-banner-rollout.py")
        shutil.copy2(CONTRACT, home / "banner-rollout/banner-rollout-contract.json")
        fake_bin = home / "bin"
        fake_bin.mkdir()
        (home / "workspace/Bash_Functions/functions.sh").write_text(
            "assume_role() { :; }\n"
            "reset_role() { :; }\n"
            "wait_for_command() { :; }\n"
            "wait_for_spring_boot_ssm_logs() { :; }\n",
            encoding="utf-8",
        )
        (fake_bin / "aws").write_text(
            "#!/usr/bin/env bash\n"
            "if [[ \"$1 $2\" == \"s3api head-object\" ]]; then\n"
            "  printf '{\"commit\":\"%s\",\"run\":\"%s\",\"etag\":\"fake-etag\"}\\n' "
            "\"${FAKE_ARTIFACT_COMMIT:-None}\" \"${FAKE_ARTIFACT_RUN:-standard}\"\n"
            "  exit 0\n"
            "fi\n"
            "exit 99\n",
            encoding="utf-8",
        )
        (fake_bin / "aws").chmod(0o755)
        env = {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "JENKINS_HOME": str(home),
            "TARGET_STACK": "staging",
            "S3_BUCKET_NAME": "synthetic-bucket",
            "stack_s3_bucket": "synthetic-bucket",
            "JENKINS_SOURCE_COMMIT": current_jenkins_commit(),
            "FAKE_ARTIFACT_RUN": artifact_run,
            **extra_env,
        }
        if artifact_commit is not None:
            env["FAKE_ARTIFACT_COMMIT"] = artifact_commit
        return subprocess.run(
            ["bash", "-c", xml_shell(path)],
            cwd=home,
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )


class JenkinsOrderTest(unittest.TestCase):
    def test_ssm_only_guard_recursively_rejects_copied_and_parent_cause_trees(self):
        guard = xml_system_scripts(AWAIT_INITIALIZATION)[0]

        self.assertIn("collectCauseTree", guard)
        self.assertIn("collected << nestedCause", guard)
        self.assertIn("nestedCause instanceof hudson.model.Cause.UpstreamCause", guard)
        self.assertIn("collected.addAll(collectCauseTree", guard)
        self.assertIn("cause.upstreamCauses", guard)
        self.assertIn("upstreamBuild.getCauses()", guard)
        self.assertIn("copiedCauseTree.isEmpty()", guard)
        self.assertIn("parentCauseTree.isEmpty()", guard)

    def test_ssm_only_guard_jenkins_shaped_cause_fixtures(self):
        _, check_for_updates = xml_system_scripts(CHECK_FOR_UPDATES)
        deployment_call = check_for_updates[
            check_for_updates.index('getItemByFullName("Deployment Pipeline")') :
            check_for_updates.index("def deploymentRun")
        ]
        self.assertIn(".scheduleBuild2(0, new ParametersAction([", deployment_call)
        self.assertNotIn("CauseAction", deployment_call)

        def upstream(build=41, nested=None):
            return {
                "type": "upstream",
                "upstreamProject": "Deployment Pipeline",
                "upstreamBuild": build,
                "upstreamCauses": [] if nested is None else nested,
            }

        def user(user_id="synthetic-operator"):
            return {"type": "user", "userId": user_id}

        def cause(cause_type):
            return {"type": cause_type}

        downstream_parameters = {
            "WAIT_FOR_TARGET_GROUP_HEALTH": False,
            "BANNER_VALIDATED_UPSTREAM_RUN_ID": "deployment-41",
            "deployment_git_hash": "a" * 40,
            "git_hash": "b" * 40,
            "BANNER_VALIDATED_INFRASTRUCTURE_COMMIT": "b" * 40,
            "BANNER_VALIDATED_DEPLOYMENT": "BDC",
            "BANNER_VALIDATED_TUPLE_SHA256": "c" * 64,
        }
        valid_parent = {
            "number": 41,
            "building": True,
            "causes": [],
            "parameters": {
                "BANNER_ROLLOUT": True,
                "BANNER_ROLLOUT_OPERATION": "FORWARD",
                "deployment_git_hash": "a" * 40,
                "BANNER_MANUAL_OPERATOR_MODE": False,
                "BANNER_EXPECTED_DEPLOYMENT": "BDC",
                "BANNER_EXPECTED_TUPLE_SHA256": "c" * 64,
            },
        }
        fixtures = {
            "automated_action_only": ([upstream()], valid_parent, "ACCEPT"),
            "manual_operator": (
                [upstream(nested=[user()])],
                {
                    **valid_parent,
                    "causes": [user()],
                    "parameters": {
                        **valid_parent["parameters"],
                        "BANNER_MANUAL_OPERATOR_MODE": True,
                    },
                },
                "ACCEPT",
            ),
            "direct": ([], valid_parent, "REJECT"),
            "nested_replay": ([upstream(nested=[cause("replay")])], valid_parent, "REJECT"),
            "deeply_nested_replay": (
                [upstream(nested=[upstream(nested=[cause("replay")])])],
                valid_parent,
                "REJECT",
            ),
            "replayed_parent": (
                [upstream(nested=[cause("replay")])],
                {**valid_parent, "causes": [cause("replay")]},
                "REJECT",
            ),
            "manual_mixed_replay": (
                [upstream(nested=[user(), cause("replay")])],
                {
                    **valid_parent,
                    "causes": [user(), cause("replay")],
                    "parameters": {
                        **valid_parent["parameters"],
                        "BANNER_MANUAL_OPERATOR_MODE": True,
                    },
                },
                "REJECT",
            ),
            "manual_user_mismatch": (
                [upstream(nested=[user("copied-operator")])],
                {
                    **valid_parent,
                    "causes": [user("live-operator")],
                    "parameters": {
                        **valid_parent["parameters"],
                        "BANNER_MANUAL_OPERATOR_MODE": True,
                    },
                },
                "REJECT",
            ),
            "manual_missing_user": (
                [upstream(nested=[user(None)])],
                {
                    **valid_parent,
                    "causes": [user(None)],
                    "parameters": {
                        **valid_parent["parameters"],
                        "BANNER_MANUAL_OPERATOR_MODE": True,
                    },
                },
                "REJECT",
            ),
            "unexpected_timer": (
                [upstream(nested=[cause("timer")])],
                {**valid_parent, "causes": [cause("timer")]},
                "REJECT",
            ),
            "unexpected_remote": (
                [upstream(nested=[cause("remote")])],
                {**valid_parent, "causes": [cause("remote")]},
                "REJECT",
            ),
            "unexpected_rebuild": (
                [upstream(nested=[cause("rebuild")])],
                {**valid_parent, "causes": [cause("rebuild")]},
                "REJECT",
            ),
            "manual_flag_without_user": (
                [upstream()],
                {
                    **valid_parent,
                    "parameters": {
                        **valid_parent["parameters"],
                        "BANNER_MANUAL_OPERATOR_MODE": True,
                    },
                },
                "REJECT",
            ),
            "mixed_top_level": ([upstream(), user()], valid_parent, "REJECT"),
            "other_parent_job": (
                [
                    {
                        **upstream(),
                        "upstreamProject": "Other Pipeline",
                    }
                ],
                valid_parent,
                "REJECT",
            ),
            "deleted_parent": ([upstream()], None, "REJECT"),
            "stale_parent": ([upstream()], {**valid_parent, "number": 40}, "REJECT"),
            "completed_parent": ([upstream()], {**valid_parent, "building": False}, "REJECT"),
            "mismatched_run": (
                [upstream()],
                valid_parent,
                "REJECT",
                {"BANNER_VALIDATED_UPSTREAM_RUN_ID": "deployment-40"},
            ),
            "mismatched_release_input": (
                [upstream()],
                valid_parent,
                "REJECT",
                {"deployment_git_hash": "d" * 40},
            ),
            "mismatched_infrastructure": (
                [upstream()],
                valid_parent,
                "REJECT",
                {"git_hash": "d" * 40},
            ),
            "mismatched_deployment": (
                [upstream()],
                {
                    **valid_parent,
                    "parameters": {
                        **valid_parent["parameters"],
                        "BANNER_EXPECTED_DEPLOYMENT": "AIM-AHEAD",
                    },
                },
                "REJECT",
            ),
            "mismatched_tuple": (
                [upstream()],
                {
                    **valid_parent,
                    "parameters": {
                        **valid_parent["parameters"],
                        "BANNER_EXPECTED_TUPLE_SHA256": "d" * 64,
                    },
                },
                "REJECT",
            ),
        }
        for scenario, fixture_values in fixtures.items():
            with self.subTest(scenario=scenario):
                downstream_causes, parent, expected, *parameter_overrides = fixture_values
                result = run_system_groovy_guard(
                    xml_system_scripts(AWAIT_INITIALIZATION)[0],
                    {
                        "downstream": {
                            "causes": downstream_causes,
                            "parameters": {
                                **downstream_parameters,
                                **(parameter_overrides[0] if parameter_overrides else {}),
                            },
                        },
                        "parent": parent,
                    },
                )
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual(expected, result.stdout.strip(), result.stderr)

    def test_ssm_only_guard_fixtures_detect_polarity_and_control_flow_mutations(self):
        guard = xml_system_scripts(AWAIT_INITIALIZATION)[0]
        invalid_direct_fixture = {
            "downstream": {
                "causes": [],
                "parameters": {"WAIT_FOR_TARGET_GROUP_HEALTH": False},
            },
            "parent": None,
        }
        result = run_system_groovy_guard(guard, invalid_direct_fixture)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("REJECT", result.stdout.strip(), result.stderr)

        polarity_mutation = guard.replace(
            "!waitForTargetHealth.toString().toBoolean()",
            "waitForTargetHealth.toString().toBoolean()",
            1,
        )
        self.assertNotEqual(guard, polarity_mutation)
        polarity_result = run_system_groovy_guard(polarity_mutation, invalid_direct_fixture)
        self.assertEqual(0, polarity_result.returncode, polarity_result.stdout + polarity_result.stderr)
        self.assertEqual("ACCEPT", polarity_result.stdout.strip(), polarity_result.stderr)

        control_flow_mutation = guard.replace(
            'throw new hudson.AbortException("SSM-only readiness requires the active validated forward Deployment Pipeline run")',
            "return",
            1,
        )
        self.assertNotEqual(guard, control_flow_mutation)
        control_flow_result = run_system_groovy_guard(control_flow_mutation, invalid_direct_fixture)
        self.assertEqual(
            0,
            control_flow_result.returncode,
            control_flow_result.stdout + control_flow_result.stderr,
        )
        self.assertEqual("ACCEPT", control_flow_result.stdout.strip(), control_flow_result.stderr)

    def test_ssm_only_await_requires_exact_validated_deployment_upstream(self):
        deployment = xml_script(DEPLOYMENT_PIPELINE)
        await_job = AWAIT_INITIALIZATION.read_text(encoding="utf-8")
        guards = xml_system_scripts(AWAIT_INITIALIZATION)

        for parameter in (
            "BANNER_VALIDATED_UPSTREAM_RUN_ID",
            "deployment_git_hash",
            "BANNER_VALIDATED_INFRASTRUCTURE_COMMIT",
            "BANNER_VALIDATED_DEPLOYMENT",
            "BANNER_VALIDATED_TUPLE_SHA256",
        ):
            with self.subTest(parameter=parameter):
                self.assertIn(parameter, deployment)
                self.assertIn(parameter, await_job)

        self.assertEqual(1, len(guards))
        guard = guards[0]
        self.assertIn("WAIT_FOR_TARGET_GROUP_HEALTH", guard)
        self.assertIn("!waitForTargetHealth.toString().toBoolean()", guard)
        self.assertIn("Cause.UpstreamCause", guard)
        self.assertIn("causes.size() != 1", guard)
        self.assertIn("instanceof hudson.model.Cause.UpstreamCause", guard)
        self.assertIn('cause.upstreamProject != "Deployment Pipeline"', guard)
        self.assertIn('"deployment-${cause.upstreamBuild}"', guard)
        self.assertIn("getBuildByNumber", guard)
        self.assertIn("upstreamBuild == null", guard)
        self.assertIn("!upstreamBuild.isBuilding()", guard)
        self.assertIn('getParameter("BANNER_ROLLOUT")', guard)
        self.assertIn('getParameter("BANNER_ROLLOUT_OPERATION")', guard)
        self.assertIn('getParameter("deployment_git_hash")', guard)
        self.assertIn('getParameter("git_hash")', guard)
        self.assertIn("deploymentInput", guard)
        self.assertIn("validatedInfrastructureCommit", guard)
        self.assertIn("BANNER_MANUAL_OPERATOR_MODE", guard)
        self.assertIn("BANNER_EXPECTED_DEPLOYMENT", guard)
        self.assertIn("BANNER_EXPECTED_TUPLE_SHA256", guard)
        self.assertIn("automatedCauseContext", guard)
        self.assertIn("manualCauseContext", guard)
        self.assertIn("Cause.UserIdCause", guard)
        self.assertIn("AbortException", guard)
        rejection_checks = {
            "direct": "cause == null",
            "other_parent": 'cause.upstreamProject != "Deployment Pipeline"',
            "replayed_with_extra_cause": "causes.size() != 1",
            "deleted_parent": "upstreamBuild == null",
            "replayed_or_stale_parent": "!upstreamBuild.isBuilding()",
            "mismatched_run": 'validatedRunId != "deployment-${cause.upstreamBuild}"',
            "mismatched_deployment": "deploymentInput != upstreamDeploymentCommit",
            "mismatched_infrastructure": "gitHash != validatedInfrastructureCommit",
        }
        for scenario, check in rejection_checks.items():
            with self.subTest(rejected_scenario=scenario):
                self.assertIn(check, guard)
        self.assertLess(
            await_job.index("<hudson.plugins.groovy.SystemGroovy"),
            await_job.index("<hudson.tasks.Shell>"),
        )

    def test_suppressed_hosts_are_ready_before_immutable_deploy_and_final_health(self):
        deployment = xml_script(DEPLOYMENT_PIPELINE)
        await_job = AWAIT_INITIALIZATION.read_text(encoding="utf-8")
        await_shell = "\n".join(xml_shells(AWAIT_INITIALIZATION))

        self.assertIn("WAIT_FOR_TARGET_GROUP_HEALTH", await_job)
        self.assertIn("describe-instance-information", await_job)
        self.assertIn("PingStatus", await_job)
        self.assertIn(
            'if [ "$WAIT_FOR_TARGET_GROUP_HEALTH" != "true" ]; then',
            await_shell,
        )
        self.assertIn(
            "Skipping target registration until immutable banner artifacts are deployed.",
            await_shell,
        )
        self.assertIn(
            "name: 'WAIT_FOR_TARGET_GROUP_HEALTH', value: !banner_forward",
            deployment,
        )
        self.assertIn("stage('Banner Rollout: Confirm Final Health')", deployment)
        self.assertIn(
            "name: 'WAIT_FOR_TARGET_GROUP_HEALTH', value: true",
            deployment,
        )

        rebuild = deployment.index("stage('Teardown and Rebuild Stage Environment')")
        host_ready = deployment.index("stage('Await Initialization')")
        immutable = deployment.index("stage('Banner Rollout: Build, Backend, then Frontend')")
        final_health = deployment.index("stage('Banner Rollout: Confirm Final Health')")
        sensor = deployment.index("stage('Falcon Sensor Check')")
        self.assertLess(rebuild, host_ready)
        self.assertLess(host_ready, immutable)
        self.assertLess(immutable, final_health)
        self.assertLess(final_health, sensor)

    def test_false_bootstrap_suppression_requires_validated_deployment_upstream(self):
        deployment = xml_script(DEPLOYMENT_PIPELINE)
        teardown = TEARDOWN_REBUILD.read_text(encoding="utf-8")
        guards = xml_system_scripts(TEARDOWN_REBUILD)

        self.assertIn("BANNER_VALIDATED_UPSTREAM_RUN_ID", deployment)
        self.assertIn("BANNER_VALIDATED_UPSTREAM_RUN_ID", teardown)
        validation = deployment.index("stage('Validate Banner Rollout Input')")
        validated_forward = deployment.index("banner_forward = banner_rollout_present")
        rebuild = deployment.index("stage('Teardown and Rebuild Stage Environment')")
        self.assertLess(validation, validated_forward)
        self.assertLess(validated_forward, rebuild)
        suppression_parameter = teardown.index(
            "<name>BOOTSTRAP_STANDARD_CRITICAL_ARTIFACTS</name>"
        )
        self.assertIn(
            "<defaultValue>true</defaultValue>",
            teardown[suppression_parameter : suppression_parameter + 500],
        )
        self.assertEqual(1, len(guards))
        guard = guards[0]
        self.assertIn("BOOTSTRAP_STANDARD_CRITICAL_ARTIFACTS", guard)
        self.assertIn("!bootstrapStandard.toString().toBoolean()", guard)
        self.assertIn("Cause.UpstreamCause", guard)
        self.assertIn('cause.upstreamProject != "Deployment Pipeline"', guard)
        self.assertIn('"deployment-${cause.upstreamBuild}"', guard)
        self.assertIn('getParameter("BANNER_ROLLOUT")', guard)
        self.assertIn('getParameter("BANNER_ROLLOUT_OPERATION")', guard)
        self.assertIn('getParameter("deployment_git_hash")', guard)
        self.assertIn('getParameter("infrastructure_git_hash")', guard)
        self.assertIn("AbortException", guard)

    def test_all_banner_system_groovy_guards_execute_and_detect_mutations(self):
        leaf_jobs = (*CRITICAL_IMAGE_JOBS, WILDFLY, FRONTEND)
        valid_leaf = {
            "downstream": {
                "causes": [
                    {
                        "type": "upstream",
                        "upstreamProject": "PIC-SURE Pipeline Build and Deploy",
                        "upstreamBuild": 17,
                        "upstreamCauses": [],
                    }
                ],
                "parameters": {"BANNER_ROLLOUT_RUN_ID": "combined-17"},
            },
            "parent": None,
        }
        direct_leaf = {
            "downstream": {
                "causes": [],
                "parameters": {"BANNER_ROLLOUT_RUN_ID": "combined-17"},
            },
            "parent": None,
        }
        for job in leaf_jobs:
            with self.subTest(job=job.name, scenario="valid"):
                guard = xml_system_scripts(job)[0]
                valid = run_system_groovy_guard(guard, valid_leaf)
                self.assertEqual(0, valid.returncode, valid.stdout + valid.stderr)
                self.assertEqual("ACCEPT", valid.stdout.strip(), valid.stderr)
            with self.subTest(job=job.name, scenario="direct"):
                direct = run_system_groovy_guard(guard, direct_leaf)
                self.assertEqual(0, direct.returncode, direct.stdout + direct.stderr)
                self.assertEqual("REJECT", direct.stdout.strip(), direct.stderr)
            with self.subTest(job=job.name, scenario="wrong-parent"):
                wrong_parent = json.loads(json.dumps(valid_leaf))
                wrong_parent["downstream"]["causes"][0]["upstreamProject"] = "Other Pipeline"
                result = run_system_groovy_guard(guard, wrong_parent)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual("REJECT", result.stdout.strip(), result.stderr)
            with self.subTest(job=job.name, scenario="polarity-mutation"):
                mutation = guard.replace("if (rolloutRunId)", "if (!rolloutRunId)", 1)
                self.assertNotEqual(guard, mutation)
                result = run_system_groovy_guard(mutation, direct_leaf)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual("ACCEPT", result.stdout.strip(), result.stderr)
            with self.subTest(job=job.name, scenario="control-flow-mutation"):
                mutation = guard.replace("throw new hudson.AbortException", "return // ", 1)
                self.assertNotEqual(guard, mutation)
                result = run_system_groovy_guard(mutation, direct_leaf)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual("ACCEPT", result.stdout.strip(), result.stderr)

        teardown_guard = xml_system_scripts(TEARDOWN_REBUILD)[0]
        valid_teardown = {
            "downstream": {
                "causes": [
                    {
                        "type": "upstream",
                        "upstreamProject": "Deployment Pipeline",
                        "upstreamBuild": 41,
                        "upstreamCauses": [],
                    }
                ],
                "parameters": {
                    "BOOTSTRAP_STANDARD_CRITICAL_ARTIFACTS": False,
                    "BANNER_VALIDATED_UPSTREAM_RUN_ID": "deployment-41",
                    "deployment_git_hash": "a" * 40,
                    "infrastructure_git_hash": "b" * 40,
                    "BANNER_VALIDATED_INFRASTRUCTURE_COMMIT": "b" * 40,
                },
            },
            "parent": {
                "number": 41,
                "building": True,
                "causes": [],
                "parameters": {
                    "BANNER_ROLLOUT": True,
                    "BANNER_ROLLOUT_OPERATION": "FORWARD",
                    "deployment_git_hash": "a" * 40,
                },
            },
        }
        valid = run_system_groovy_guard(teardown_guard, valid_teardown)
        self.assertEqual(0, valid.returncode, valid.stdout + valid.stderr)
        self.assertEqual("ACCEPT", valid.stdout.strip(), valid.stderr)
        direct_teardown = json.loads(json.dumps(valid_teardown))
        direct_teardown["downstream"]["causes"] = []
        rejected = run_system_groovy_guard(teardown_guard, direct_teardown)
        self.assertEqual(0, rejected.returncode, rejected.stdout + rejected.stderr)
        self.assertEqual("REJECT", rejected.stdout.strip(), rejected.stderr)
        wrong_parent_teardown = json.loads(json.dumps(valid_teardown))
        wrong_parent_teardown["downstream"]["causes"][0]["upstreamProject"] = "Other Pipeline"
        wrong_parent_teardown["resolveAnyParentProject"] = True
        rejected = run_system_groovy_guard(teardown_guard, wrong_parent_teardown)
        self.assertEqual(0, rejected.returncode, rejected.stdout + rejected.stderr)
        self.assertEqual("REJECT", rejected.stdout.strip(), rejected.stderr)
        project_comparison = teardown_guard.replace(
            'cause.upstreamProject != "Deployment Pipeline" ||',
            "false ||",
            1,
        )
        self.assertNotEqual(teardown_guard, project_comparison)
        mutated = run_system_groovy_guard(project_comparison, wrong_parent_teardown)
        self.assertEqual(0, mutated.returncode, mutated.stdout + mutated.stderr)
        self.assertEqual("ACCEPT", mutated.stdout.strip(), mutated.stderr)
        polarity = teardown_guard.replace(
            "!bootstrapStandard.toString().toBoolean()",
            "bootstrapStandard.toString().toBoolean()",
            1,
        )
        mutated = run_system_groovy_guard(polarity, direct_teardown)
        self.assertEqual(0, mutated.returncode, mutated.stdout + mutated.stderr)
        self.assertEqual("ACCEPT", mutated.stdout.strip(), mutated.stderr)
        control_flow = teardown_guard.replace("throw new hudson.AbortException", "return // ", 1)
        mutated = run_system_groovy_guard(control_flow, direct_teardown)
        self.assertEqual(0, mutated.returncode, mutated.stdout + mutated.stderr)
        self.assertEqual("ACCEPT", mutated.stdout.strip(), mutated.stderr)

    def test_check_for_updates_waits_and_propagates_for_both_rollout_modes(self):
        script = xml_system_scripts(CHECK_FOR_UPDATES)[1]
        for banner in (False, True):
            with self.subTest(banner=banner, child="success"):
                result = run_check_for_updates_wait(script, banner, "SUCCESS")
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual("WAITED", result.stdout.strip(), result.stderr)
            with self.subTest(banner=banner, child="failure"):
                result = run_check_for_updates_wait(script, banner, "FAILURE")
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual("REJECT_WAITED", result.stdout.strip(), result.stderr)

        wait_block = """def deploymentRun = deploymentFuture.get()
if (deploymentRun.getResult() != Result.SUCCESS) {
    throw new AbortException("Deployment Pipeline failed")
}"""
        control_flow = script.replace(
            wait_block,
            """if (bannerRollout) {
    def deploymentRun = deploymentFuture.get()
    if (deploymentRun.getResult() != Result.SUCCESS) {
        throw new AbortException("Deployment Pipeline failed")
    }
}""",
            1,
        )
        self.assertNotEqual(script, control_flow)
        mutation = run_check_for_updates_wait(control_flow, False, "SUCCESS")
        self.assertEqual(0, mutation.returncode, mutation.stdout + mutation.stderr)
        self.assertEqual("NOT_WAITED", mutation.stdout.strip(), mutation.stderr)

    def test_intervening_standard_writer_cannot_reach_banner_bootstrap(self):
        legacy = xml_script(LEGACY_PIPELINE)
        deployment = xml_script(DEPLOYMENT_PIPELINE)
        teardown = TEARDOWN_REBUILD.read_text(encoding="utf-8")
        infrastructure = Path(os.environ["BDC_INFRASTRUCTURE_ROOT"])
        variables = (infrastructure / "app-infrastructure/variables.tf").read_text(encoding="utf-8")
        wildfly_instance = (infrastructure / "app-infrastructure/wildfly-instance.tf").read_text(encoding="utf-8")
        httpd_instance = (infrastructure / "app-infrastructure/httpd-instance.tf").read_text(encoding="utf-8")
        wildfly_user_data = (
            infrastructure / "app-infrastructure/scripts/wildfly-user_data.sh"
        ).read_text(encoding="utf-8")
        httpd_user_data = (
            infrastructure / "app-infrastructure/scripts/httpd-user_data.sh"
        ).read_text(encoding="utf-8")

        for writer in ("gateway", "operations", "query", "psama", "frontend"):
            with self.subTest(writer=writer):
                self.assertIn(f"branches['{writer}']", legacy)

        bootstrap_parameter = "BOOTSTRAP_STANDARD_CRITICAL_ARTIFACTS"
        self.assertIn(
            f"name: '{bootstrap_parameter}', value: !banner_forward",
            deployment,
        )
        self.assertIn(f"<name>{bootstrap_parameter}</name>", teardown)
        self.assertEqual(3, teardown.count("bootstrap_standard_critical_artifacts="))
        self.assertIn('variable "bootstrap_standard_critical_artifacts"', variables)
        self.assertIn("default     = true", variables)
        for instance in (wildfly_instance, httpd_instance):
            self.assertIn(
                "bootstrap_standard_critical_artifacts = tostring(var.bootstrap_standard_critical_artifacts)",
                instance,
            )

        guard = re.compile(
            r'if \[\[ "\$bootstrap_standard_critical_artifacts" == "true" \]\]; then\n.*?\nfi',
            re.DOTALL,
        )
        wildfly_guards = guard.findall(wildfly_user_data)
        self.assertEqual(2, len(wildfly_guards))
        guarded_wildfly = "\n".join(wildfly_guards)
        unguarded_wildfly = guard.sub("", wildfly_user_data)
        for script in ("operations", "query", "psama", "gateway"):
            command = f"sudo /opt/picsure/deploy-{script}.sh"
            with self.subTest(critical_bootstrap=script):
                self.assertIn(command, guarded_wildfly)
                self.assertNotIn(command, unguarded_wildfly)
        for script in ("dictionary", "logging", "visualization"):
            with self.subTest(unrelated_bootstrap=script):
                self.assertIn(f"sudo /opt/picsure/deploy-{script}.sh", unguarded_wildfly)

        httpd_guards = guard.findall(httpd_user_data)
        self.assertEqual(1, len(httpd_guards))
        self.assertIn("sudo /opt/picsure/deploy-httpd.sh", httpd_guards[0])
        self.assertIn("confirming gateway resolvable", httpd_guards[0])
        self.assertNotIn("sudo /opt/picsure/deploy-httpd.sh", guard.sub("", httpd_user_data))

    def test_banner_bootstrap_withholds_critical_images_and_uses_one_release_input(self):
        first_script, final_script = xml_system_scripts(CHECK_FOR_UPDATES)
        legacy = xml_script(LEGACY_PIPELINE)
        deployment = xml_script(DEPLOYMENT_PIPELINE)
        infrastructure = Path(os.environ["BDC_INFRASTRUCTURE_ROOT"])
        wildfly_user_data = (
            infrastructure / "app-infrastructure/scripts/wildfly-user_data.sh"
        ).read_text(encoding="utf-8")
        httpd_user_data = (
            infrastructure / "app-infrastructure/scripts/httpd-user_data.sh"
        ).read_text(encoding="utf-8")

        exact_input = 'new StringParameterValue("RELEASE_CONTROL_BRANCH", envVars["GIT_COMMIT"].trim())'
        self.assertIn(exact_input, first_script)
        self.assertIn("name: 'RELEASE_CONTROL_BRANCH', value: params.RELEASE_CONTROL_BRANCH", legacy)
        self.assertIn("pipelineBuildId != params.RELEASE_CONTROL_BRANCH", legacy)

        banner_filter = legacy.index("if (!bannerRolloutPresent)")
        unrelated_wave = legacy.index("branches['hpds']")
        parallel_call = legacy.index("parallel branches")
        self.assertLess(banner_filter, unrelated_wave)
        self.assertLess(unrelated_wave, parallel_call)
        for critical in ("gateway", "operations", "query", "psama", "frontend"):
            with self.subTest(critical=critical):
                self.assertIn(f"branches['{critical}']", legacy[banner_filter:unrelated_wave])
        for unrelated in ("hpds", "logging", "visualization", "dictionary"):
            with self.subTest(unrelated=unrelated):
                self.assertIn(f"branches['{unrelated}']", legacy[unrelated_wave:parallel_call])

        rebuild = deployment.index("stage('Teardown and Rebuild Stage Environment')")
        immutable = deployment.index("build job: 'PIC-SURE Pipeline Build and Deploy'")
        self.assertLess(rebuild, immutable)
        for deploy_script in (
            "deploy-operations.sh",
            "deploy-query.sh",
            "deploy-psama.sh",
            "deploy-gateway.sh",
        ):
            with self.subTest(deploy_script=deploy_script):
                self.assertIn(deploy_script, wildfly_user_data)
        self.assertIn("deploy-httpd.sh", httpd_user_data)

        combined = xml_script(PIPELINE)
        backend = combined.index("build job: 'PIC-SURE Wildfly Stack Deploy'")
        frontend = combined.index("build job: 'PIC-SURE Frontend Deploy'")
        self.assertLess(backend, frontend)
        self.assertIn("BANNER_BACKEND_HEALTH_RECEIPT", combined[frontend:])
        self.assertIn(exact_input, first_script)
        self.assertIn(
            'new StringParameterValue("deployment_git_hash", envVars["GIT_COMMIT"].trim())',
            final_script,
        )

    def test_normal_path_routes_banner_input_through_deployment_pipeline(self):
        first_script, final_script = xml_system_scripts(CHECK_FOR_UPDATES)
        old_pipeline = first_script.index('getItemByFullName("PIC-SURE Pipeline")')
        self.assertNotIn("buildSpec.banner_rollout", first_script)
        self.assertNotIn("if (!bannerRollout)", first_script)
        self.assertIn("scheduleBuild2(0, new ParametersAction([", first_script[old_pipeline:])
        self.assertIn("])).get()", first_script[old_pipeline:])
        guard = final_script.index("buildSpec.banner_rollout")
        deployment = final_script.index('getItemByFullName("Deployment Pipeline")')
        self.assertLess(guard, deployment)
        self.assertNotIn('getItemByFullName("PIC-SURE Pipeline Build and Deploy")', final_script)
        self.assertIn("BANNER_ROLLOUT", final_script[deployment:])
        self.assertIn("BANNER_ROLLOUT_OPERATION", final_script[deployment:])
        self.assertIn('new BooleanParameterValue("BANNER_MANUAL_OPERATOR_MODE", false)', final_script)
        self.assertIn("BANNER_EXPECTED_DEPLOYMENT", final_script[deployment:])
        self.assertIn("BANNER_EXPECTED_TUPLE_SHA256", final_script[deployment:])
        for required in (
            "deployment_git_hash",
            "dataset_s3_object_key",
            "destigmatized_dataset_s3_object_key",
            "genomic_dataset_s3_object_key",
        ):
            self.assertIn(required, final_script[deployment:])

    def test_deployment_pipeline_preserves_controls_and_calls_hardened_job(self):
        script = xml_script(DEPLOYMENT_PIPELINE)
        validation = script.index("stage('Validate Banner Rollout Input')")
        backup = script.index("stage('Create Auth & Picsure Database Backups')")
        migrations = script.index("stage('Database Migrations')")
        rebuild = script.index("stage('Teardown and Rebuild Stage Environment')")
        initialize = script.index("stage('Await Initialization')")
        hardened = script.index("build job: 'PIC-SURE Pipeline Build and Deploy'")
        sensor = script.index("stage('Falcon Sensor Check')")
        self.assertLess(validation, backup)
        self.assertLess(script.index("currentBuild.getBuildCauses()"), backup)
        self.assertLess(script.index("Banner operator context must match"), backup)
        self.assertIn("BANNER_MANUAL_OPERATOR_MODE", script[validation:backup])
        self.assertIn("hudson.model.Cause$UserIdCause", script[validation:backup])
        self.assertIn("buildCauses.size() != 1", script[validation:backup])
        self.assertIn("manualUserCauses.size() != 1", script[validation:backup])
        validation_body = script[validation:backup]
        self.assertIn("banner_rollout_present != params.BANNER_ROLLOUT", validation_body)
        self.assertIn("if (banner_rollout_present)", validation_body)
        self.assertLess(backup, migrations)
        self.assertLess(migrations, rebuild)
        self.assertLess(rebuild, initialize)
        self.assertLess(initialize, hardened)
        self.assertLess(hardened, sensor)
        for retained in (
            "Retrieve Deployment State",
            "Update PIC-SURE Token Introspection Token",
            "Render PIC-SURE Service Config Templates",
            "Write Stack State",
        ):
            self.assertIn(retained, script)
        self.assertIn("BANNER_ROLLOUT_OPERATION", script)
        self.assertIn("MIGRATIONS_COMPLETED_UPSTREAM", script)
        self.assertIn("name: 'TARGET_STACK', value: 'staging'", script)

    def test_build_spec_is_parsed_once_into_serializable_values(self):
        script = xml_script(PIPELINE)
        self.assertIn("@NonCPS\ndef parseBuildSpec", script)
        self.assertEqual(1, script.count("readFile('build-spec.json')"))
        self.assertEqual(1, script.count("new JsonSlurper().parseText"))
        self.assertNotIn("bannerRollout = new JsonSlurper", script)
        self.assertIn("bannerRolloutPresent: spec.banner_rollout != null", script)
        self.assertIn("bannerRolloutPresent = parsedBuildSpec.bannerRolloutPresent", script)

    def test_deployment_pipeline_does_not_hold_lazy_json_across_cps_steps(self):
        script = xml_script(DEPLOYMENT_PIPELINE)
        self.assertIn("@NonCPS\ndef parseBuildSpec", script)
        self.assertEqual(1, script[: script.index("pipeline {")].count("new JsonSlurper().parseText"))
        self.assertNotIn("new JsonSlurper().parse(new File", script)
        self.assertIn("parseBuildSpec(readFile('build-spec.json'))", script)
        self.assertIn("def retrieveBuildSpecId", script)

    def test_forward_banner_combined_job_requires_deployment_pipeline_parent(self):
        entry = pipeline_entry_snippet(PIPELINE)
        self.assertIn("Deployment Pipeline", entry)
        self.assertIn("MIGRATIONS_COMPLETED_UPSTREAM", entry)
        self.assertIn("Cause.UpstreamCause", entry)
        self.assertIn("getBuildByNumber", entry)

    def test_backend_health_finishes_before_frontend_publication(self):
        script = xml_script(PIPELINE)
        backend = script.index("build job: 'PIC-SURE Wildfly Stack Deploy'")
        frontend = script.index("build job: 'PIC-SURE Frontend Deploy'")
        self.assertLess(backend, frontend)
        branch_start = script.index("deployBranches['banner_backend_then_frontend']")
        next_branch = script.index("deployBranches['hpds_auth_deploy']")
        parallel_call = script.index("parallel deployBranches")
        self.assertLess(branch_start, backend)
        self.assertLess(backend, frontend)
        self.assertLess(frontend, next_branch)
        self.assertLess(next_branch, parallel_call)
        self.assertIn("deployBranches['banner_backend_then_frontend']", script[branch_start:backend])
        self.assertIn("parallel deployBranches", script[next_branch:])
        self.assertIn("BANNER_BACKEND_HEALTH_RECEIPT", script[frontend:])

    def test_frontend_is_built_from_reviewed_commit_before_deploy(self):
        script = xml_script(PIPELINE)
        build = script.index("build job: 'PIC-SURE Frontend Build'")
        deploy = script.index("build job: 'PIC-SURE Frontend Deploy'")
        self.assertLess(build, deploy)
        self.assertIn("build_hashes['PSF']", script[build:deploy])
        frontend_build_shell = xml_shell(FRONTEND_BUILD)
        self.assertIn("git-commit=${GIT_COMMIT}", frontend_build_shell)

    def test_banner_artifacts_use_one_combined_run_prefix_and_explicit_bucket(self):
        script = xml_script(PIPELINE)
        self.assertIn("BANNER_ROLLOUT_RUN_ID", script)
        self.assertIn("STACK_S3_BUCKET", script)
        for job in (
            "PIC-SURE Operations Service Image",
            "PIC-SURE Gateway Image",
            "PIC-SURE HPDS Query Service Image",
            "PIC-SURE Auth Micro App Image",
            "PIC-SURE Frontend Build",
            "PIC-SURE Wildfly Stack Deploy",
            "PIC-SURE Frontend Deploy",
        ):
            with self.subTest(job=job):
                job_path = ROOT / f"jenkins-docker/jobs/{job}/config.xml"
                text = job_path.read_text(encoding="utf-8")
                self.assertIn("BANNER_ROLLOUT_RUN_ID", text)
                self.assertIn("S3_BUCKET_NAME", text)
        query_image = QUERY_IMAGE.read_text(encoding="utf-8")
        self.assertIn("--metadata", query_image)
        self.assertIn("git-commit=${GIT_COMMIT_FULL}", query_image)

    def test_banner_artifacts_are_no_overwrite_and_downloaded_by_verified_etag(self):
        for job in (
            "PIC-SURE Operations Service Image",
            "PIC-SURE Gateway Image",
            "PIC-SURE HPDS Query Service Image",
            "PIC-SURE Auth Micro App Image",
            "PIC-SURE Frontend Build",
        ):
            with self.subTest(job=job):
                shell = xml_shell(ROOT / f"jenkins-docker/jobs/{job}/config.xml")
                self.assertIn("/banner-rollout/forward/", shell)
                self.assertIn("s3api put-object", shell)
                self.assertIn("--if-none-match '*'", shell)
        for job in (WILDFLY, FRONTEND):
            with self.subTest(job=job):
                shell = xml_shell(job)
                self.assertIn("ETag", shell)
                self.assertIn("_artifact_etag" if job == WILDFLY else "--artifact_etag", shell)
                self.assertIn("'${frontend_etag}'" if job == FRONTEND else "'${operations_artifact_etag}'", shell)

    def test_non_banner_component_operation_does_not_enable_banner_leaf_guards(self):
        script = xml_script(PIPELINE)
        self.assertIn("bannerForward = bannerRolloutPresent && params.BANNER_ROLLOUT_OPERATION == 'FORWARD'", script)
        self.assertIn("name: 'BANNER_ROLLOUT', value: bannerForward", script)
        self.assertIn("name: 'BANNER_ROLLOUT_RUN_ID', value: bannerForward ? bannerRolloutRunId : ''", script)

    def test_unrelated_deploy_legs_remain_parallel_with_backend_sequence(self):
        script = xml_script(PIPELINE)
        backend = script.index("build job: 'PIC-SURE Wildfly Stack Deploy'")
        frontend = script.index("build job: 'PIC-SURE Frontend Deploy'")
        hpds = script.index("build job: 'PIC-SURE HPDS Auth Deploy'")
        logging = script.index("build job: 'PIC-SURE Logging Deploy'")
        parallel_call = script.index("parallel deployBranches")
        for offset in (backend, frontend, hpds, logging):
            self.assertLess(offset, parallel_call)
        self.assertIn("deployBranches['banner_backend_then_frontend']", script[:backend])
        self.assertIn("deployBranches['hpds_auth_deploy']", script[frontend:hpds])
        self.assertIn("deployBranches['logging_deploy']", script[hpds:logging])
        self.assertLess(backend, frontend)

    def test_pipeline_invokes_executable_tuple_and_service_validator(self):
        script = xml_script(PIPELINE)
        self.assertIn("validate-banner-rollout.py", script)
        self.assertIn("--jenkins-source-commit", script)
        self.assertIn("aim-ahead-operator-attestation.json", script)
        self.assertIn("${aimAttestation}", script)
        for selection in (
            "RUN_DATABASE_MIGRATIONS",
            "INCLUDE_PIC_SURE_API",
            "INCLUDE_PIC_SURE_AUTH_MICRO_APP",
            "INCLUDE_PIC_SURE_FRONTEND",
        ):
            self.assertIn(selection, script)
        dockerfile = (ROOT / "jenkins-docker/Dockerfile").read_text(encoding="utf-8")
        self.assertIn("validate-banner-rollout.py", dockerfile)
        self.assertIn("JENKINS_SOURCE_COMMIT", dockerfile)
        self.assertIn("BANNER_CONTROLLER_DEPLOYMENT", dockerfile)
        self.assertIn("--controller-deployment", script)
        retrieve = RETRIEVE_BUILD_SPEC.read_text(encoding="utf-8")
        self.assertNotIn("banner-rollout-attestation.json", retrieve)

    def test_bucket_is_bound_before_disruptive_banner_stages(self):
        script = xml_script(DEPLOYMENT_PIPELINE)
        validation = script.index("stage('Validate Banner Rollout Input')")
        bucket_check = script.index("--controller-artifact-bucket", validation)
        for stage in (
            "stage('Create Auth & Picsure Database Backups')",
            "stage('Database Migrations')",
            "stage('Teardown and Rebuild Stage Environment')",
            "stage('Banner Rollout: Build, Backend, then Frontend')",
        ):
            with self.subTest(stage=stage):
                self.assertLess(bucket_check, script.index(stage))

    def test_bucket_blocks_execute_before_shell_or_disruptive_effects(self):
        snippets = {
            "parent": pipeline_validation_snippet(DEPLOYMENT_PIPELINE, "parent"),
            "child": pipeline_validation_snippet(PIPELINE, "child"),
        }
        with tempfile.TemporaryDirectory() as temp:
            for pipeline, snippet in snippets.items():
                with self.subTest(pipeline=pipeline):
                    effect = Path(temp) / f"{pipeline}-disruptive"
                    fixture = banner_validation_fixture(pipeline, "BDC", "caller-bucket")
                    fixture["env"]["stack_s3_bucket"] = "controller-bucket"
                    fixture["disruptiveEffect"] = str(effect)
                    result = run_pipeline_validation(snippet, fixture)
                    self.assertEqual("REJECT", result["status"], result)
                    self.assertEqual([], result["shellCalls"], result)
                    self.assertFalse(effect.exists())

    def test_bucket_whitespace_is_rejected_before_shell_or_disruptive_effects(self):
        snippets = {
            "parent": pipeline_validation_snippet(DEPLOYMENT_PIPELINE, "parent"),
            "child": pipeline_validation_snippet(PIPELINE, "child"),
        }
        with tempfile.TemporaryDirectory() as temp:
            for pipeline, snippet in snippets.items():
                for caller_bucket, controller_bucket in (
                    (" controller-bucket", "controller-bucket"),
                    ("controller-bucket ", "controller-bucket"),
                    ("controller-bucket", " controller-bucket"),
                    ("controller-bucket", "controller-bucket "),
                ):
                    with self.subTest(
                        pipeline=pipeline,
                        caller_bucket=caller_bucket,
                        controller_bucket=controller_bucket,
                    ):
                        effect = Path(temp) / f"{pipeline}-{caller_bucket!r}-{controller_bucket!r}"
                        fixture = banner_validation_fixture(pipeline, "BDC", caller_bucket)
                        fixture["env"]["stack_s3_bucket"] = controller_bucket
                        fixture["disruptiveEffect"] = str(effect)
                        result = run_pipeline_validation(snippet, fixture)
                        self.assertEqual("REJECT", result["status"], result)
                        self.assertEqual([], result["shellCalls"], result)
                        self.assertFalse(effect.exists())

    def test_only_the_validated_bucket_reaches_the_child_and_leaf_jobs(self):
        parent = pipeline_validation_snippet(DEPLOYMENT_PIPELINE, "parent")
        child = xml_script(PIPELINE)
        self.assertIn(
            "name: 'STACK_S3_BUCKET', value: validated_artifact_bucket",
            parent,
        )
        self.assertNotIn("value: params.STACK_S3_BUCKET", parent)
        self.assertEqual(1, child.count("String.valueOf(params.STACK_S3_BUCKET)"))
        self.assertEqual(6, child.count("value: validatedArtifactBucket"))

    def test_parent_validation_snippet_reaches_actual_child_dispatch(self):
        parent = pipeline_validation_snippet(DEPLOYMENT_PIPELINE, "parent")
        self.assertIn("build job: 'PIC-SURE Pipeline Build and Deploy'", parent)

    def test_pipeline_validation_runner_filters_requested_cause_class(self):
        fixture = banner_validation_fixture("parent", "BDC", "synthetic-bucket")
        fixture["causes"] = [
            {
                "className": "hudson.model.Cause$UserIdCause",
                "userId": "synthetic-operator",
            },
            {
                "className": "hudson.model.Cause$UpstreamCause",
                "upstreamProject": "Deployment Pipeline",
            },
        ]
        snippet = """
if (currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause').size() != 1) {
    error('UserIdCause filter returned the wrong causes')
}
if (currentBuild.getBuildCauses('hudson.model.Cause$UpstreamCause').size() != 1) {
    error('UpstreamCause filter returned the wrong causes')
}
"""
        result = run_pipeline_validation(snippet, fixture)
        self.assertEqual("ACCEPT", result["status"], result)

    def test_forward_banner_child_rejects_every_extra_top_level_cause(self):
        snippet = pipeline_entry_snippet(PIPELINE)
        upstream = {
            "className": "hudson.model.Cause$UpstreamCause",
            "upstreamProject": "Deployment Pipeline",
            "upstreamBuild": 41,
        }
        extras = (
            {
                "className": "hudson.model.Cause$UserIdCause",
                "userId": "synthetic-operator",
            },
            {"className": "com.sonyericsson.rebuild.RebuildCause"},
            {"className": "org.jenkinsci.plugins.workflow.cps.replay.ReplayCause"},
            {"className": "synthetic.OtherCause"},
        )

        def forward_fixture(
            causes: list[dict],
            parent_causes: list[dict] | None = None,
            manual: bool = False,
        ) -> dict:
            fixture = banner_validation_fixture("child", "BDC", "synthetic-bucket")
            fixture["params"]["MIGRATIONS_COMPLETED_UPSTREAM"] = True
            fixture["causes"] = causes
            fixture["parent"] = {
                "number": 41,
                "building": True,
                "causes": parent_causes or [],
                "parameters": {
                    "BANNER_ROLLOUT": True,
                    "BANNER_ROLLOUT_OPERATION": "FORWARD",
                    "BANNER_MANUAL_OPERATOR_MODE": manual,
                },
            }
            return fixture

        for extra in extras:
            with self.subTest(extra=extra["className"]):
                result = run_pipeline_validation(
                    snippet, forward_fixture([upstream, extra])
                )
                self.assertEqual("REJECT", result["status"], result)
                self.assertEqual([], result["scheduledBuilds"], result)

        manual_cause = {
            "className": "hudson.model.Cause$UserIdCause",
            "userId": "synthetic-operator",
        }
        manual_parent = {**upstream, "upstreamCauses": [manual_cause]}
        for scenario, fixture, expected in (
            ("trusted_automated_parent", forward_fixture([upstream]), "ACCEPT"),
            (
                "trusted_manual_parent",
                forward_fixture([manual_parent], [manual_cause], manual=True),
                "ACCEPT",
            ),
            ("direct", forward_fixture([]), "REJECT"),
            (
                "wrong_parent",
                forward_fixture(
                    [{**upstream, "upstreamProject": "Other Pipeline"}]
                ),
                "REJECT",
            ),
        ):
            with self.subTest(scenario=scenario):
                result = run_pipeline_validation(snippet, fixture)
                self.assertEqual(expected, result["status"], result)
                if expected == "ACCEPT":
                    self.assertEqual(1, len(result["scheduledBuilds"]), result)
                else:
                    self.assertEqual([], result["scheduledBuilds"], result)

        mutation = snippet.replace("directCauses.size() != 1 || ", "", 1)
        self.assertNotEqual(snippet, mutation)
        mutated = run_pipeline_validation(
            mutation, forward_fixture([upstream, extras[0]])
        )
        self.assertEqual("ACCEPT", mutated["status"], mutated)
        self.assertEqual(1, len(mutated["scheduledBuilds"]), mutated)

        non_banner = banner_validation_fixture("child", "BDC", "synthetic-bucket")
        non_banner["causes"] = [upstream, extras[0]]
        non_banner_result = run_pipeline_validation(snippet, non_banner)
        self.assertEqual("ACCEPT", non_banner_result["status"], non_banner_result)
        self.assertEqual(1, len(non_banner_result["scheduledBuilds"]), non_banner_result)

    def test_complete_banner_entry_guard_is_before_the_first_effect(self):
        entry = pipeline_entry_snippet(PIPELINE)
        self.assertIn("getBuildByNumber", entry)
        self.assertIn("getLastBuild", entry)
        self.assertEqual("false", ET.parse(PIPELINE).findtext(".//definition/sandbox"))
        self.assertLess(
            entry.index("getBuildByNumber"),
            entry.index("build job: 'Retrieve Build Spec'"),
        )

    def test_banner_entry_rejects_untrusted_parent_before_effects(self):
        entry = pipeline_entry_snippet(PIPELINE)
        upstream = {
            "className": "hudson.model.Cause$UpstreamCause",
            "upstreamProject": "Deployment Pipeline",
            "upstreamBuild": 41,
        }

        def fixture_for(
            cause: dict = upstream,
            *,
            parent_causes: list[dict] | None = None,
            parent_exists: bool = True,
            parent_building: bool = True,
            last_parent_build: int = 41,
            manual: bool = False,
        ) -> dict:
            fixture = banner_validation_fixture("child", "BDC", "synthetic-bucket")
            fixture["params"]["MIGRATIONS_COMPLETED_UPSTREAM"] = True
            fixture["causes"] = [cause]
            fixture["lastParentBuildNumber"] = last_parent_build
            if parent_exists:
                fixture["parent"] = {
                    "number": 41,
                    "building": parent_building,
                    "causes": parent_causes or [],
                    "parameters": {
                        "BANNER_ROLLOUT": True,
                        "BANNER_ROLLOUT_OPERATION": "FORWARD",
                        "BANNER_MANUAL_OPERATOR_MODE": manual,
                    },
                }
            return fixture

        replay = {
            "className": "org.jenkinsci.plugins.workflow.cps.replay.ReplayCause"
        }
        rebuild = {"className": "com.sonyericsson.rebuild.RebuildCause"}
        remote = {"className": "hudson.model.Cause$RemoteCause"}
        timer = {"className": "hudson.triggers.TimerTrigger$TimerTriggerCause"}
        other = {"className": "synthetic.OtherCause"}
        operator = {
            "className": "hudson.model.Cause$UserIdCause",
            "userId": "synthetic-operator",
        }
        second_operator = {**operator, "userId": "different-operator"}
        blank_operator = {**operator, "userId": ""}
        scenarios = {
            "deleted_parent": fixture_for(parent_exists=False),
            "inactive_parent": fixture_for(parent_building=False),
            "noncurrent_parent": fixture_for(last_parent_build=42),
            "copied_nested_replay": fixture_for(
                {**upstream, "upstreamCauses": [replay]}
            ),
            "copied_nested_rebuild": fixture_for(
                {**upstream, "upstreamCauses": [rebuild]}
            ),
            "copied_nested_remote": fixture_for(
                {**upstream, "upstreamCauses": [remote]}
            ),
            "copied_nested_timer": fixture_for(
                {**upstream, "upstreamCauses": [timer]}
            ),
            "copied_nested_other": fixture_for(
                {**upstream, "upstreamCauses": [other]}
            ),
            "copied_nested_mixed": fixture_for(
                {**upstream, "upstreamCauses": [operator, replay]},
                parent_causes=[operator],
                manual=True,
            ),
            "parent_nested_replay": fixture_for(parent_causes=[replay]),
            "parent_nested_rebuild": fixture_for(parent_causes=[rebuild]),
            "parent_nested_mixed": fixture_for(
                {**upstream, "upstreamCauses": [operator]},
                parent_causes=[operator, replay],
                manual=True,
            ),
            "manual_user_mismatch": fixture_for(
                {**upstream, "upstreamCauses": [operator]},
                parent_causes=[second_operator],
                manual=True,
            ),
            "manual_blank_user": fixture_for(
                {**upstream, "upstreamCauses": [blank_operator]},
                parent_causes=[blank_operator],
                manual=True,
            ),
        }
        for scenario, fixture in scenarios.items():
            with self.subTest(scenario=scenario):
                result = run_pipeline_validation(entry, fixture)
                self.assertEqual("REJECT", result["status"], result)
                self.assertEqual([], result["scheduledBuilds"], result)

        nested_fixture = scenarios["copied_nested_replay"]
        removed = entry.replace("requireTrustedBannerParent(currentBuild)", "true", 1)
        self.assertNotEqual(entry, removed)
        removed_result = run_pipeline_validation(removed, nested_fixture)
        self.assertEqual("ACCEPT", removed_result["status"], removed_result)
        self.assertEqual(1, len(removed_result["scheduledBuilds"]), removed_result)

        guard, first_effect = pipeline_entry_parts(PIPELINE)
        reordered_result = run_pipeline_validation(
            f"{first_effect}\n{guard}", nested_fixture
        )
        self.assertEqual("REJECT", reordered_result["status"], reordered_result)
        self.assertEqual(1, len(reordered_result["scheduledBuilds"]), reordered_result)

        nested_mutation = entry.replace(
            "(!automatedCauseContext && !manualCauseContext)", "false", 1
        )
        self.assertNotEqual(entry, nested_mutation)
        nested_result = run_pipeline_validation(nested_mutation, nested_fixture)
        self.assertEqual("ACCEPT", nested_result["status"], nested_result)
        self.assertEqual(1, len(nested_result["scheduledBuilds"]), nested_result)

        inactive_mutation = entry.replace("!upstreamBuild.isBuilding()", "false", 1)
        self.assertNotEqual(entry, inactive_mutation)
        inactive_result = run_pipeline_validation(
            inactive_mutation, scenarios["inactive_parent"]
        )
        self.assertEqual("ACCEPT", inactive_result["status"], inactive_result)
        self.assertEqual(1, len(inactive_result["scheduledBuilds"]), inactive_result)

    def test_validator_catches_typed_bucket_guard_mismatch_mutations(self):
        snippets = {
            "parent": pipeline_validation_snippet(DEPLOYMENT_PIPELINE, "parent"),
            "child": pipeline_validation_snippet(PIPELINE, "child"),
        }
        comparisons = {
            "parent": "requested_artifact_bucket != controller_artifact_bucket",
            "child": "requestedArtifactBucket != controllerArtifactBucket",
        }
        with tempfile.TemporaryDirectory() as temp:
            for pipeline, snippet in snippets.items():
                with self.subTest(pipeline=pipeline):
                    mutation = snippet.replace(comparisons[pipeline], "false", 1)
                    self.assertNotEqual(snippet, mutation)
                    effect = Path(temp) / f"{pipeline}-typed-guard-mutation"
                    fixture = banner_validation_fixture(
                        pipeline, "BDC", "requested-bucket"
                    )
                    fixture["env"]["stack_s3_bucket"] = "controller-bucket"
                    fixture["disruptiveEffect"] = str(effect)
                    result = run_pipeline_validation(mutation, fixture)
                    self.assertEqual("REJECT", result["status"], result)
                    self.assertEqual(1, len(result["shellCalls"]), result)
                    self.assertFalse(effect.exists())

    def test_bucket_values_never_enter_parent_or_child_shell_source(self):
        snippets = {
            "parent": pipeline_validation_snippet(DEPLOYMENT_PIPELINE, "parent"),
            "child": pipeline_validation_snippet(PIPELINE, "child"),
        }
        with tempfile.TemporaryDirectory() as temp:
            for pipeline, snippet in snippets.items():
                with self.subTest(pipeline=pipeline):
                    malicious_effect = Path(temp) / f"{pipeline}-injected"
                    hostile = f"synthetic' ; touch '{malicious_effect}' ; #"
                    fixture = banner_validation_fixture(pipeline, "BDC", hostile)
                    fixture["maliciousEffect"] = str(malicious_effect)
                    result = run_pipeline_validation(snippet, fixture)
                    self.assertEqual("ACCEPT", result["status"], result)
                    self.assertFalse(result["maliciousEffect"], result)
                    self.assertEqual(1, len(result["shellCalls"]), result)
                    shell_call = result["shellCalls"][0]
                    self.assertNotIn(hostile, shell_call["script"])
                    self.assertEqual(hostile, shell_call["environment"]["BANNER_ARTIFACT_BUCKET"])
                    self.assertEqual(
                        hostile,
                        shell_call["environment"]["BANNER_CONTROLLER_ARTIFACT_BUCKET"],
                    )

    def test_aim_runtime_attestation_is_read_once_and_propagated_byte_for_byte(self):
        parent_snippet = pipeline_validation_snippet(DEPLOYMENT_PIPELINE, "parent")
        child_snippet = pipeline_validation_snippet(PIPELINE, "child")
        original = fresh_aim_attestation_json()
        replacement = '{"replacement":true}'

        parent_fixture = banner_validation_fixture("parent", "AIM-AHEAD", "synthetic-bucket")
        parent_fixture["runtimeOriginal"] = original
        parent_fixture["runtimeReplacement"] = replacement
        parent = run_pipeline_validation(parent_snippet, parent_fixture)
        self.assertEqual("ACCEPT", parent["status"], parent)
        self.assertEqual(1, len(parent["reads"]), parent)
        self.assertEqual(original, parent["propagatedAttestation"])
        self.assertEqual(original, parent["writes"]["aim-ahead-operator-attestation.json"])
        self.assertEqual(1, len(parent["scheduledBuilds"]), parent)
        dispatched = {
            parameter["name"]: parameter["value"]
            for parameter in parent["scheduledBuilds"][0]["parameters"]
        }
        self.assertEqual(
            "PIC-SURE Pipeline Build and Deploy",
            parent["scheduledBuilds"][0]["job"],
        )
        self.assertEqual(original, dispatched["BANNER_AIM_ATTESTATION_JSON"])

        child_fixture = banner_validation_fixture(
            "child", "AIM-AHEAD", "synthetic-bucket", parent["propagatedAttestation"]
        )
        child_fixture["params"].update(
            {
                "BANNER_ROLLOUT_OPERATION": "FORWARD",
                "MIGRATIONS_COMPLETED_UPSTREAM": True,
                "RUN_DATABASE_MIGRATIONS": True,
                "INCLUDE_PIC_SURE_API": True,
                "INCLUDE_PIC_SURE_AUTH_MICRO_APP": True,
                "INCLUDE_PIC_SURE_FRONTEND": True,
            }
        )
        child_fixture["causes"] = [{"upstreamProject": "Deployment Pipeline"}]
        child_fixture["runtimeOriginal"] = replacement
        child = run_pipeline_validation(child_snippet, child_fixture)
        self.assertEqual("ACCEPT", child["status"], child)
        self.assertEqual([], child["reads"], child)
        self.assertEqual(original, child["writes"]["aim-ahead-operator-attestation.json"])

        reread_parent = parent_snippet.replace(
            "aim_attestation_json = readFile(runtime_attestation)",
            "aim_attestation_json = readFile(runtime_attestation)\n"
            "                            aim_attestation_json = readFile(runtime_attestation)",
            1,
        )
        self.assertNotEqual(parent_snippet, reread_parent)
        mutated_parent = run_pipeline_validation(reread_parent, parent_fixture)
        self.assertEqual("REJECT", mutated_parent["status"], mutated_parent)
        self.assertEqual(2, len(mutated_parent["reads"]), mutated_parent)

        dispatch_reread = parent_snippet.replace(
            "name: 'BANNER_AIM_ATTESTATION_JSON', value: aim_attestation_json",
            "name: 'BANNER_AIM_ATTESTATION_JSON', "
            'value: readFile("${env.JENKINS_HOME}/banner-rollout/'
            'aim-ahead-operator-attestation.json")',
            1,
        )
        self.assertNotEqual(parent_snippet, dispatch_reread)
        mutated_dispatch = run_pipeline_validation(dispatch_reread, parent_fixture)
        self.assertEqual("ACCEPT", mutated_dispatch["status"], mutated_dispatch)
        self.assertEqual(2, len(mutated_dispatch["reads"]), mutated_dispatch)
        mutated_parameters = {
            parameter["name"]: parameter["value"]
            for parameter in mutated_dispatch["scheduledBuilds"][0]["parameters"]
        }
        self.assertEqual(
            replacement,
            mutated_parameters["BANNER_AIM_ATTESTATION_JSON"],
            mutated_dispatch,
        )
        self.assertNotEqual(
            original,
            mutated_parameters["BANNER_AIM_ATTESTATION_JSON"],
            mutated_dispatch,
        )

        parent_source = xml_script(DEPLOYMENT_PIPELINE)
        build_call = "build job: 'PIC-SURE Pipeline Build and Deploy'"
        late_reread_source = parent_source.replace(
            build_call,
            'aim_attestation_json = readFile("${env.JENKINS_HOME}/banner-rollout/'
            'aim-ahead-operator-attestation.json")\n                    '
            + build_call,
            1,
        )
        self.assertNotEqual(parent_source, late_reread_source)
        late_reread_snippet = pipeline_validation_snippet(
            DEPLOYMENT_PIPELINE,
            "parent",
            source=late_reread_source,
        )
        late_reread = run_pipeline_validation(late_reread_snippet, parent_fixture)
        with self.assertRaises(AssertionError):
            self.assertEqual(1, len(late_reread["reads"]), late_reread)
        late_parameters = {
            parameter["name"]: parameter["value"]
            for parameter in late_reread["scheduledBuilds"][0]["parameters"]
        }
        self.assertEqual(
            replacement,
            late_parameters["BANNER_AIM_ATTESTATION_JSON"],
            late_reread,
        )

        runtime_reread = child_snippet.replace(
            "writeFile file: 'aim-ahead-operator-attestation.json', text: params.BANNER_AIM_ATTESTATION_JSON",
            "writeFile file: 'aim-ahead-operator-attestation.json', "
            'text: readFile("${env.JENKINS_HOME}/banner-rollout/aim-ahead-operator-attestation.json")',
            1,
        )
        self.assertNotEqual(child_snippet, runtime_reread)
        mutated_child = run_pipeline_validation(runtime_reread, child_fixture)
        self.assertEqual("REJECT", mutated_child["status"], mutated_child)
        self.assertEqual(1, len(mutated_child["reads"]), mutated_child)

    def test_standalone_aim_non_banner_operation_uses_explicit_snapshot_parameter(self):
        child_snippet = pipeline_validation_snippet(PIPELINE, "child")
        attestation = fresh_aim_attestation_json()
        fixture = banner_validation_fixture(
            "child", "AIM-AHEAD", "synthetic-bucket", attestation
        )
        result = run_pipeline_validation(child_snippet, fixture)
        self.assertEqual("ACCEPT", result["status"], result)
        self.assertEqual([], result["reads"], result)
        self.assertEqual(attestation, result["writes"]["aim-ahead-operator-attestation.json"])

        missing = banner_validation_fixture(
            "child", "AIM-AHEAD", "synthetic-bucket", ""
        )
        rejected = run_pipeline_validation(child_snippet, missing)
        self.assertEqual("REJECT", rejected["status"], rejected)
        self.assertIn("Deployment Pipeline snapshot", rejected["failure"])
        self.assertIn("standalone AIM-AHEAD NON_BANNER_COMPONENTS", rejected["failure"])
        self.assertEqual([], rejected["reads"], rejected)
        self.assertEqual([], rejected["shellCalls"], rejected)

        combined = PIPELINE.read_text(encoding="utf-8")
        parameter = combined.index("<name>BANNER_AIM_ATTESTATION_JSON</name>")
        description = combined[parameter : parameter + 700]
        self.assertIn("standalone AIM-AHEAD NON_BANNER_COMPONENTS", description)
        self.assertIn("Deployment Pipeline snapshot", description)

    def test_backend_runs_real_aggregate_health_probe(self):
        shell = xml_shell(WILDFLY)
        logs = shell.index("wait_for_spring_boot_ssm_logs")
        probe = shell.rindex("/system/status")
        self.assertLess(logs, probe)
        self.assertIn("RUNNING", shell[probe:])
        self.assertIn("get-command-invocation", shell[probe:])
        self.assertIn("StandardErrorContent", shell[probe:])
        self.assertIn("if ! (wait_for_command", shell[probe:])


class FailClosedStandaloneTest(unittest.TestCase):
    def test_forward_leaf_jobs_require_the_real_combined_upstream_run(self):
        for job in (WILDFLY, FRONTEND, FRONTEND_BUILD):
            with self.subTest(job=job):
                guards = xml_system_scripts(job)
                self.assertTrue(guards)
                guard = "\n".join(guards)
                self.assertIn("Cause.UpstreamCause", guard)
                self.assertIn("PIC-SURE Pipeline Build and Deploy", guard)
                self.assertIn("BANNER_ROLLOUT_RUN_ID", guard)

    def test_reviewed_critical_commits_cannot_reach_standard_writer_side_effects(self):
        def component_commit(name: str) -> str:
            return subprocess.run(
                ["python3", str(VALIDATOR), "--component-commit", name],
                text=True,
                capture_output=True,
                check=True,
            ).stdout.strip()

        backend_commit = component_commit("backend")
        frontend_commit = component_commit("frontend")
        for job in CRITICAL_IMAGE_JOBS:
            reviewed_commit = frontend_commit if job == FRONTEND_BUILD else backend_commit
            with self.subTest(job=job.name):
                result, effects = run_standard_writer(job, reviewed_commit)
                self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                self.assertIn("immutable banner rollout namespace", result.stderr)
                self.assertEqual("", effects)

                shell = xml_shell(job)
                mutation = shell.replace(
                    '"${reviewed_component_commit}"', '"not-${reviewed_component_commit}"', 1
                )
                self.assertNotEqual(shell, mutation)
                mutated, mutated_effects = run_standard_writer(job, reviewed_commit, mutation)
                self.assertNotEqual("", mutated_effects, mutated.stdout + mutated.stderr)

    def test_service_wrappers_propagate_banner_mode_to_fail_closed_backend(self):
        for job in (
            "PIC-SURE Operations Service Deploy",
            "PIC-SURE Gateway Deploy",
            "PIC-SURE Auth Micro App Deploy",
        ):
            with self.subTest(job=job):
                script = xml_script(ROOT / f"jenkins-docker/jobs/{job}/config.xml")
                self.assertIn("BANNER_ROLLOUT", script)
                self.assertIn("BANNER_ROLLOUT_TUPLE_SHA256", script)
        for job in (WILDFLY, FRONTEND):
            with self.subTest(job=job):
                shell = xml_shell(job)
                self.assertIn("--tuple-sha256", shell)
                self.assertIn("BANNER_ROLLOUT_DEPLOYMENT", shell)

    def test_wildfly_banner_mode_rejects_omitted_psama(self):
        result = run_shell_guard(
            WILDFLY,
            {
                "BANNER_ROLLOUT": "true",
                "BANNER_ROLLOUT_RUN_ID": "combined-1",
                "BANNER_ROLLOUT_TUPLE_SHA256": "0" * 64,
                "DEPLOY_OPERATIONS": "true",
                "DEPLOY_GATEWAY": "true",
                "DEPLOY_PSAMA": "false",
            },
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("banner rollout requires Operations, PSAMA, and Gateway", result.stderr)

    def test_frontend_banner_mode_rejects_missing_backend_health_attestation(self):
        result = run_shell_guard(
            FRONTEND,
            {
                "BANNER_ROLLOUT": "true",
                "BANNER_ROLLOUT_RUN_ID": "combined-1",
                "BANNER_ROLLOUT_TUPLE_SHA256": "0" * 64,
                "BANNER_BACKEND_HEALTH_RECEIPT": "",
            },
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("backend health receipt", result.stderr)

    def test_frontend_artifact_provenance_cannot_bypass_banner_guard(self):
        result = run_shell_guard(
            FRONTEND,
            {"BANNER_ROLLOUT": "false"},
            artifact_commit="7b69aa960ff98f97c1a2d026b7137b0e3dcdf603",
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("combined banner pipeline", result.stderr)

    def test_wildfly_rejects_a_forged_tuple_at_the_entrypoint(self):
        result = run_shell_guard(
            WILDFLY,
            {
                "BANNER_ROLLOUT": "true",
                "BANNER_ROLLOUT_RUN_ID": "combined-1",
                "BANNER_ROLLOUT_DEPLOYMENT": "BDC",
                "BANNER_ROLLOUT_TUPLE_SHA256": "0" * 64,
                "DEPLOY_OPERATIONS": "true",
                "DEPLOY_GATEWAY": "true",
                "DEPLOY_PSAMA": "true",
            },
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("tupleSha256 does not match", result.stderr)

    def test_backend_artifact_provenance_cannot_bypass_banner_guard(self):
        result = run_shell_guard(
            WILDFLY,
            {
                "BANNER_ROLLOUT": "false",
                "DEPLOY_OPERATIONS": "true",
                "DEPLOY_GATEWAY": "true",
                "DEPLOY_PSAMA": "true",
                "DEPLOY_QUERY": "false",
                "DEPLOY_DICTIONARY": "false",
                "DEPLOY_VISUALIZATION": "false",
            },
            artifact_commit="0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8",
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("combined banner pipeline", result.stderr)

    def test_backend_rollback_requires_the_attested_artifact_commit(self):
        infrastructure = Path(os.environ["BDC_INFRASTRUCTURE_ROOT"])
        release_control = Path(os.environ["BDC_RELEASE_CONTROL_ROOT"])
        attestation = json.loads(
            (infrastructure / "tests/fisma-banner-rollout/rollback-operator-attestation.json").read_text(
                encoding="utf-8"
            )
        )
        release_spec = json.loads((release_control / "build-spec.json").read_text(encoding="utf-8"))
        components = release_spec["banner_rollout"]["components"]
        components["infrastructure"]["commit"] = subprocess.run(
            ["python3", str(VALIDATOR), "--component-commit", "infrastructure"],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
        components["jenkins"]["commit"] = current_jenkins_commit()
        tuple_sha = hashlib.sha256(
            json.dumps({"deployment": "BDC", "components": components}, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        attestation.update(
            {
                "deployment": "BDC",
                "controllerDeployment": "BDC",
                "targetStack": "staging",
                "artifactPrefix": "staging/banner-rollout/rollback/rollback-fixture/containers",
                "artifacts": {"frontendCommit": "1" * 40, "backendCommit": "2" * 40},
                "tupleSha256": tuple_sha,
                "stage": "BACKEND_ALLOWED",
                "operator": "synthetic-operator",
                "attestedAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            }
        )
        for phase, accepted in zip(attestation["phases"], (True, True, True, False, False, False)):
            phase["attested"] = accepted
        attestation["state"] = {
            "managementWritesFrozen": True,
            "frontendRolledBack": True,
            "targetedActiveOrScheduledRemaining": 0,
            "forwardSchemaRetained": True,
            "downMigrationRun": False,
            "psamaRecreated": False,
        }
        base_env = {
            "BANNER_ROLLBACK": "true",
            "BANNER_ROLLBACK_ATTESTATION_JSON": json.dumps(attestation),
            "BANNER_CONTROLLER_DEPLOYMENT": "bdc",
            "DEPLOY_OPERATIONS": "true",
            "DEPLOY_GATEWAY": "true",
            "DEPLOY_PSAMA": "false",
            "DEPLOY_QUERY": "false",
            "DEPLOY_DICTIONARY": "false",
            "DEPLOY_VISUALIZATION": "false",
        }
        matching = run_shell_guard(
            WILDFLY,
            base_env,
            artifact_commit="2" * 40,
            artifact_run="rollback-fixture",
        )
        self.assertNotEqual(2, matching.returncode, matching.stdout + matching.stderr)
        self.assertNotIn("combined banner pipeline", matching.stderr)
        mismatched = run_shell_guard(
            WILDFLY,
            base_env,
            artifact_commit="3" * 40,
            artifact_run="rollback-fixture",
        )
        self.assertEqual(2, mismatched.returncode, mismatched.stdout + mismatched.stderr)
        self.assertIn("does not match", mismatched.stderr)

    def test_frontend_build_rejects_rollback_with_forward_run_identity(self):
        result = run_shell_guard(
            FRONTEND_BUILD,
            {
                "BANNER_ROLLBACK": "true",
                "BANNER_ROLLOUT_RUN_ID": "combined-1",
                "BANNER_ROLLBACK_ATTESTATION_JSON": "",
            },
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("forward run identity", result.stderr)

    def test_frontend_deploy_uses_bash_and_quotes_host_arguments(self):
        shell = xml_shell(FRONTEND)
        self.assertIn('sudo /bin/bash /opt/picsure/deploy-httpd.sh', shell)
        self.assertIn('--stack_s3_bucket "${stack_s3_bucket}"', shell)
        self.assertIn('--target_stack "${TARGET_STACK}"', shell)
        self.assertIn('--artifact_prefix "${artifact_prefix}"', shell)

    def test_rollback_entrypoints_reject_missing_stage_attestations(self):
        frontend = run_shell_guard(
            FRONTEND,
            {"BANNER_ROLLBACK": "true", "BANNER_ROLLBACK_ATTESTATION_JSON": ""},
        )
        self.assertEqual(2, frontend.returncode, frontend.stdout + frontend.stderr)
        self.assertIn("FRONTEND_ALLOWED", frontend.stderr)
        backend = run_shell_guard(
            WILDFLY,
            {
                "BANNER_ROLLBACK": "true",
                "BANNER_ROLLBACK_ATTESTATION_JSON": "",
                "DEPLOY_OPERATIONS": "true",
                "DEPLOY_GATEWAY": "true",
                "DEPLOY_PSAMA": "false",
            },
        )
        self.assertEqual(2, backend.returncode, backend.stdout + backend.stderr)
        self.assertIn("operator attestation", backend.stderr)
        psama_wrapper = xml_script(ROOT / "jenkins-docker/jobs/PIC-SURE Auth Micro App Deploy/config.xml")
        self.assertIn("BANNER_ROLLBACK", psama_wrapper)
        self.assertIn("BANNER_ROLLBACK_ATTESTATION_JSON", psama_wrapper)

    def test_frontend_rollback_builds_and_deploys_the_attested_immutable_artifact(self):
        build = FRONTEND_BUILD.read_text(encoding="utf-8")
        deploy = FRONTEND.read_text(encoding="utf-8")
        self.assertIn("BANNER_ROLLBACK", build)
        self.assertIn("BANNER_ROLLBACK_ATTESTATION_JSON", build)
        self.assertIn("--required-rollback-stage FRONTEND_ALLOWED", build)
        self.assertIn("artifactPrefix", build)
        self.assertIn("artifactPrefix", deploy)
        self.assertIn("--artifact_prefix", deploy)

    def test_backend_rollback_images_build_the_attested_immutable_artifacts(self):
        for job in (
            "PIC-SURE Operations Service Image",
            "PIC-SURE Gateway Image",
            "PIC-SURE HPDS Query Service Image",
            "PIC-SURE Auth Micro App Image",
        ):
            with self.subTest(job=job):
                text = (ROOT / f"jenkins-docker/jobs/{job}/config.xml").read_text(encoding="utf-8")
                self.assertIn("BANNER_ROLLBACK", text)
                self.assertIn("BANNER_ROLLBACK_ATTESTATION_JSON", text)
                self.assertIn("--required-rollback-stage BACKEND_ALLOWED", text)
                self.assertIn("artifactPrefix", text)
                self.assertIn("artifacts.backendCommit", text)


class ExecutableContractTest(unittest.TestCase):
    def setUp(self):
        self.release_control = Path(os.environ["BDC_RELEASE_CONTROL_ROOT"])
        self.infrastructure = Path(os.environ["BDC_INFRASTRUCTURE_ROOT"])

    def validate(self, deployment: str, spec: Path, *selections: str):
        release_control_commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.release_control,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
        deployment_args = [
            "--release-control-commit",
            release_control_commit,
            "--controller-deployment",
            "bdc",
        ]
        attestation_handle = None
        if deployment == "AIM-AHEAD":
            attestation = json.loads(
                (self.infrastructure / "tests/fisma-banner-rollout/fixtures/aim-ahead-completed-attestation.synthetic.json").read_text(
                    encoding="utf-8"
                )
            )
            attestation["attestedAtUtc"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            attestation_handle = tempfile.NamedTemporaryFile("w", suffix=".json")
            json.dump(attestation, attestation_handle)
            attestation_handle.flush()
            deployment_args = [
                "--attestation",
                attestation_handle.name,
                "--release-control-commit",
                "a" * 40,
                "--controller-deployment",
                "aim-ahead",
            ]
        try:
            return subprocess.run(
                [
                "python3",
                str(VALIDATOR),
                "--deployment",
                deployment,
                "--build-spec",
                str(spec),
                "--jenkins-source-commit",
                self.current_jenkins_commit(),
                "--artifact-bucket",
                "synthetic-bucket",
                "--controller-artifact-bucket",
                "synthetic-bucket",
                *deployment_args,
                *selections,
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
        finally:
            if attestation_handle is not None:
                attestation_handle.close()

    def current_jenkins_commit(self):
        return current_jenkins_commit()

    def bdc_tuple(self):
        spec = json.loads((self.release_control / "build-spec.json").read_text(encoding="utf-8"))
        return spec["banner_rollout"]["tupleSha256"]

    def test_render_rejects_hostile_operations_override_before_reset_or_success(self):
        hostile_overrides = {
            "missing": "SPRING_DATASOURCE_URL=jdbc:synthetic\n",
            "wrong URL": (
                "LOGGING_SERVICE_URL=http://wrong-logging\n"
                "LOGGING_API_KEY=${logging_api_key}\n"
            ),
            "duplicate key": (
                "LOGGING_SERVICE_URL=http://pic-sure-logging\n"
                "LOGGING_API_KEY=${logging_api_key}\n"
                "LOGGING_API_KEY=${logging_api_key}\n"
            ),
            "mismatched key": (
                "LOGGING_SERVICE_URL=http://pic-sure-logging\n"
                "LOGGING_API_KEY=wrong-key\n"
            ),
        }
        for label, override in hostile_overrides.items():
            with self.subTest(label=label):
                result, effects, secret = run_render_service_config(
                    self.infrastructure,
                    override,
                )

                self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertIn("terraform-apply", effects)
                self.assertNotIn("reset-role", effects)
                self.assertNotIn("success", effects)
                self.assertNotIn(secret, result.stdout)
                self.assertNotIn(secret, result.stderr)

    def test_render_accepts_exact_operations_logging_values_without_printing_secret(self):
        result, effects, secret = run_render_service_config(
            self.infrastructure,
            "LOGGING_SERVICE_URL=http://pic-sure-logging\n"
            "LOGGING_API_KEY=${logging_api_key}\n",
        )

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertLess(effects.index("terraform-apply"), effects.index("reset-role"))
        self.assertLess(effects.index("reset-role"), effects.index("success"))
        self.assertNotIn(secret, result.stdout)
        self.assertNotIn(secret, result.stderr)

    def required_selections(self):
        return (
            "--run-database-migrations",
            "true",
            "--include-api",
            "true",
            "--include-psama",
            "true",
            "--include-frontend",
            "true",
        )

    def test_bdc_release_tuple_passes(self):
        result = self.validate(
            "BDC",
            self.release_control / "build-spec.json",
            *self.required_selections(),
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertRegex(result.stdout.strip(), r"^[0-9a-f]{64}$")

    def test_validator_accepts_logging_capable_executable_infrastructure(self):
        spec = json.loads((self.release_control / "build-spec.json").read_text(encoding="utf-8"))
        logging_commit = "d10cecdeb89f14f8c672a81347ffa70d9b001ab3"
        spec["infrastructure_git_hash"] = logging_commit
        spec["banner_rollout"]["components"]["infrastructure"]["commit"] = logging_commit
        components = spec["banner_rollout"]["components"]
        payload = {"deployment": "BDC", "components": components}
        spec["banner_rollout"]["tupleSha256"] = hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(spec, handle)
            handle.flush()
            result = self.validate("BDC", Path(handle.name), *self.required_selections())
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_reviewed_executable_infrastructure_contains_operations_logging_wiring(self):
        logging_commit = "d10cecdeb89f14f8c672a81347ffa70d9b001ab3"
        validator = VALIDATOR.read_text(encoding="utf-8")
        self.assertIn(f'"commit": "{logging_commit}"', validator)
        for relative, required in (
            (
                "app-infrastructure/template-renderer/templates/operations.env.tftpl",
                ("LOGGING_SERVICE_URL=http://pic-sure-logging", "LOGGING_API_KEY=${logging_api_key}"),
            ),
            (
                "app-infrastructure/template-renderer/main.tf",
                ("logging_api_key              = var.logging_api_key",),
            ),
        ):
            with self.subTest(relative=relative):
                result = subprocess.run(
                    ["git", "show", f"{logging_commit}:{relative}"],
                    cwd=self.infrastructure,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(0, result.returncode, result.stderr)
                for value in required:
                    self.assertIn(value, result.stdout)

    def test_previous_executable_infrastructure_lacks_operations_logging_wiring(self):
        previous = "c18c56a4aeaf7b75a1f4feb4bc19c5c09a29c7c1"
        result = subprocess.run(
            [
                "git",
                "show",
                f"{previous}:app-infrastructure/template-renderer/templates/operations.env.tftpl",
            ],
            cwd=self.infrastructure,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("LOGGING_SERVICE_URL", result.stdout)
        self.assertNotIn("LOGGING_API_KEY", result.stdout)

    def test_aim_ahead_public_tuple_passes_separately(self):
        result = self.validate(
            "AIM-AHEAD",
            self.infrastructure / "tests/fisma-banner-rollout/aim-ahead-required-release-input.json",
            *self.required_selections(),
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_banner_release_rejects_each_required_omission(self):
        selections = list(self.required_selections())
        for option in (
            "--run-database-migrations",
            "--include-api",
            "--include-psama",
            "--include-frontend",
        ):
            omitted = selections.copy()
            omitted[omitted.index(option) + 1] = "false"
            with self.subTest(option=option):
                result = self.validate("BDC", self.release_control / "build-spec.json", *omitted)
                self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                self.assertIn(option, result.stderr)

    def test_non_banner_component_operation_accepts_no_banner_selections(self):
        result = subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                "--deployment",
                "BDC",
                "--operation",
                "NON_BANNER_COMPONENTS",
                "--build-spec",
                str(self.release_control / "build-spec.json"),
                "--jenkins-source-commit",
                self.current_jenkins_commit(),
                "--release-control-commit",
                subprocess.run(
                    ["git", "rev-parse", "HEAD"],
                    cwd=self.release_control,
                    text=True,
                    capture_output=True,
                    check=True,
                ).stdout.strip(),
                "--controller-deployment",
                "bdc",
                "--artifact-bucket",
                "synthetic-bucket",
                "--controller-artifact-bucket",
                "synthetic-bucket",
                "--run-database-migrations",
                "false",
                "--include-api",
                "false",
                "--include-psama",
                "false",
                "--include-frontend",
                "false",
            ],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_aim_operator_template_fails_until_manually_attested(self):
        template = self.infrastructure / "tests/fisma-banner-rollout/aim-ahead-operator-attestation.json"
        result = subprocess.run(
            ["python3", str(VALIDATOR), "--attestation", str(template)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("requires the exact --build-spec", result.stderr)

    def test_rollback_template_fails_until_every_phase_is_attested(self):
        template = self.infrastructure / "tests/fisma-banner-rollout/rollback-operator-attestation.json"
        result = subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                "--rollback-attestation",
                str(template),
                "--jenkins-source-commit",
                self.current_jenkins_commit(),
                "--controller-deployment",
                "bdc",
                "--target-stack",
                "staging",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("rollback attestation is incomplete", result.stderr)

    def test_completed_rollback_attestation_passes_in_owner_suite(self):
        template = json.loads(
            (self.infrastructure / "tests/fisma-banner-rollout/rollback-operator-attestation.json").read_text(encoding="utf-8")
        )
        template["deployment"] = "BDC"
        template["controllerDeployment"] = "BDC"
        template["targetStack"] = "staging"
        template["artifactPrefix"] = "staging/banner-rollout/rollback/rollback-fixture/containers"
        template["artifacts"] = {
            "frontendCommit": "1" * 40,
            "backendCommit": "2" * 40,
        }
        template["tupleSha256"] = self.bdc_tuple()
        template["stage"] = "COMPLETE"
        for phase in template["phases"]:
            phase["attested"] = True
        template["state"] = {
            "managementWritesFrozen": True,
            "frontendRolledBack": True,
            "targetedActiveOrScheduledRemaining": 0,
            "forwardSchemaRetained": True,
            "downMigrationRun": False,
            "psamaRecreated": True,
        }
        template["operator"] = "synthetic-operator"
        template["attestedAtUtc"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(template, handle)
            handle.flush()
            result = subprocess.run(
                [
                    "python3",
                    str(VALIDATOR),
                    "--rollback-attestation",
                    handle.name,
                    "--jenkins-source-commit",
                    self.current_jenkins_commit(),
                    "--controller-deployment",
                    "bdc",
                    "--target-stack",
                    "staging",
                ],
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_rollback_attestation_rejects_a_forward_run_prefix(self):
        template = json.loads(
            (self.infrastructure / "tests/fisma-banner-rollout/rollback-operator-attestation.json").read_text(encoding="utf-8")
        )
        template.update(
            {
                "deployment": "BDC",
                "controllerDeployment": "BDC",
                "targetStack": "staging",
                "artifactPrefix": "staging/banner-rollout/forward/combined-57/containers",
                "artifacts": {"frontendCommit": "1" * 40, "backendCommit": "2" * 40},
                "tupleSha256": self.bdc_tuple(),
                "stage": "COMPLETE",
                "operator": "synthetic-operator",
                "attestedAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            }
        )
        for phase in template["phases"]:
            phase["attested"] = True
        template["state"] = {
            "managementWritesFrozen": True,
            "frontendRolledBack": True,
            "targetedActiveOrScheduledRemaining": 0,
            "forwardSchemaRetained": True,
            "downMigrationRun": False,
            "psamaRecreated": True,
        }
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(template, handle)
            handle.flush()
            result = subprocess.run(
                [
                    "python3",
                    str(VALIDATOR),
                    "--rollback-attestation",
                    handle.name,
                    "--jenkins-source-commit",
                    self.current_jenkins_commit(),
                    "--controller-deployment",
                    "bdc",
                    "--target-stack",
                    "staging",
                ],
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("rollback namespace", result.stderr)

    def test_tuple_verifier_rejects_a_forged_leaf_receipt(self):
        result = subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                "--deployment",
                "BDC",
                "--tuple-sha256",
                "0" * 64,
                "--jenkins-source-commit",
                self.current_jenkins_commit(),
            ],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("tupleSha256 does not match", result.stderr)

    def test_authoritative_contract_is_byte_checked_and_exact(self):
        backend_root = os.environ.get("BACKEND_ROOT")
        self.assertIsNotNone(backend_root, "BACKEND_ROOT must identify pic-sure@0178bbd2")
        authoritative = Path(backend_root) / ".github/banner-rollout-contract.json"
        self.assertEqual(authoritative.read_bytes(), CONTRACT.read_bytes())

    def test_arbitrary_jenkins_commit_is_rejected(self):
        spec = json.loads((self.release_control / "build-spec.json").read_text(encoding="utf-8"))
        spec["banner_rollout"]["components"]["jenkins"]["commit"] = "a" * 40
        components = spec["banner_rollout"]["components"]
        payload = {"deployment": "BDC", "components": components}
        spec["banner_rollout"]["tupleSha256"] = hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(spec, handle)
            handle.flush()
            result = self.validate("BDC", Path(handle.name), *self.required_selections())
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("Jenkins source", result.stderr)

    def test_extra_nested_component_fields_are_rejected_before_work(self):
        spec = json.loads((self.release_control / "build-spec.json").read_text(encoding="utf-8"))
        spec["banner_rollout"]["components"]["jenkins"]["extra"] = "accepted-by-old-validator"
        components = spec["banner_rollout"]["components"]
        payload = {"deployment": "BDC", "components": components}
        spec["banner_rollout"]["tupleSha256"] = hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(spec, handle)
            handle.flush()
            result = self.validate("BDC", Path(handle.name), *self.required_selections())
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("unexpected", result.stderr)

    def test_aim_attestation_binds_checked_out_commit_tuple_and_build_input(self):
        spec = self.infrastructure / "tests/fisma-banner-rollout/aim-ahead-required-release-input.json"
        result = self.validate("AIM-AHEAD", spec, *self.required_selections())
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_release_input_rejects_wrong_controller_artifact_bucket(self):
        result = self.validate(
            "BDC",
            self.release_control / "build-spec.json",
            *self.required_selections(),
            "--artifact-bucket",
            "wrong-bucket",
            "--controller-artifact-bucket",
            "controller-bucket",
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("artifact bucket", result.stderr)

    def test_explicit_false_is_not_treated_as_an_omitted_incompatible_flag(self):
        for option in (
            "--run-database-migrations",
            "--include-api",
            "--include-psama",
            "--include-frontend",
        ):
            for spelling in ([option, "false"], [f"{option}=false"]):
                with self.subTest(option=option, spelling=spelling):
                    component = subprocess.run(
                        [
                            "python3",
                            str(VALIDATOR),
                            "--component-commit",
                            "backend",
                            *spelling,
                        ],
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertEqual(
                        2, component.returncode, component.stdout + component.stderr
                    )
                    self.assertIn("cannot be combined", component.stderr)

        abbreviation = subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                "--component-commit",
                "backend",
                "--include-a",
                "false",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(2, abbreviation.returncode, abbreviation.stdout + abbreviation.stderr)
        self.assertIn("unrecognized arguments", abbreviation.stderr)

        tuple_digest = self.bdc_tuple()
        tuple_result = subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                "--tuple-sha256",
                tuple_digest,
                "--deployment",
                "BDC",
                "--jenkins-source-commit",
                self.current_jenkins_commit(),
                "--include-frontend=false",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(2, tuple_result.returncode, tuple_result.stdout + tuple_result.stderr)
        self.assertIn("cannot be combined", tuple_result.stderr)

    def test_first_check_for_updates_script_has_no_dead_banner_parse(self):
        first_script = xml_system_scripts(CHECK_FOR_UPDATES)[0]
        self.assertNotIn("bannerRollout", first_script)

    def test_stale_rollback_attestation_is_rejected(self):
        template = json.loads(
            (self.infrastructure / "tests/fisma-banner-rollout/rollback-operator-attestation.json").read_text(encoding="utf-8")
        )
        template.update(
            {
                "deployment": "BDC",
                "controllerDeployment": "BDC",
                "targetStack": "staging",
                "artifactPrefix": "staging/banner-rollout/rollback/old-run/containers",
                "tupleSha256": self.bdc_tuple(),
                "stage": "COMPLETE",
                "operator": "synthetic-operator",
                "attestedAtUtc": "2000-01-01T00:00:00Z",
            }
        )
        for phase in template["phases"]:
            phase["attested"] = True
        template["state"] = {
            "managementWritesFrozen": True,
            "frontendRolledBack": True,
            "targetedActiveOrScheduledRemaining": 0,
            "forwardSchemaRetained": True,
            "downMigrationRun": False,
            "psamaRecreated": True,
        }
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(template, handle)
            handle.flush()
            result = subprocess.run(
                [
                    "python3",
                    str(VALIDATOR),
                    "--rollback-attestation",
                    handle.name,
                    "--jenkins-source-commit",
                    self.current_jenkins_commit(),
                    "--controller-deployment",
                    "bdc",
                    "--target-stack",
                    "staging",
                ],
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("fresh", result.stderr)

    def test_validator_rejects_ignored_attestation_arguments(self):
        attestation = self.infrastructure / "tests/fisma-banner-rollout/fixtures/aim-ahead-completed-attestation.synthetic.json"
        result = subprocess.run(
            ["python3", str(VALIDATOR), "--attestation", str(attestation), "--deployment", "BDC"],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)

    def test_backend_root_is_the_clean_reviewed_commit(self):
        backend_root = Path(os.environ["BACKEND_ROOT"])
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=backend_root, text=True, capture_output=True, check=True
        ).stdout.strip()
        status = subprocess.run(
            ["git", "status", "--porcelain"], cwd=backend_root, text=True, capture_output=True, check=True
        ).stdout
        self.assertEqual("0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8", head)
        self.assertEqual("", status)


if __name__ == "__main__":
    unittest.main()
