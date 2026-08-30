#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PIPELINE = ROOT / "jenkins-docker/jobs/PIC-SURE Pipeline Build and Deploy/config.xml"
CHECK_FOR_UPDATES = ROOT / "jenkins-docker/jobs/Check For Updates/config.xml"
RETRIEVE_BUILD_SPEC = ROOT / "jenkins-docker/jobs/Retrieve Build Spec/config.xml"
FRONTEND_BUILD = ROOT / "jenkins-docker/jobs/PIC-SURE Frontend Build/config.xml"
WILDFLY = ROOT / "jenkins-docker/jobs/PIC-SURE Wildfly Stack Deploy/config.xml"
FRONTEND = ROOT / "jenkins-docker/jobs/PIC-SURE Frontend Deploy/config.xml"
VALIDATOR = ROOT / "jenkins-docker/scripts/validate-banner-rollout.py"
CONTRACT = ROOT / "jenkins-docker/scripts/banner-rollout-contract.json"


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


def xml_system_scripts(path: Path) -> list[str]:
    root = ET.parse(path).getroot()
    return [
        node.text
        for node in root.findall(".//hudson.plugins.groovy.SystemGroovy/source/script/script")
        if node.text
    ]


def containing_parallel(script: str, offset: int):
    for start in (index for index in range(len(script)) if script.startswith("parallel (", index)):
        depth = 0
        quote = None
        escaped = False
        for index in range(start + len("parallel "), len(script)):
            char = script[index]
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
                continue
            if char in "'\"":
                quote = char
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    if start < offset < index:
                        return (start, index)
                    break
    return None


def run_shell_guard(
    path: Path,
    extra_env: dict[str, str],
    artifact_commit: str | None = None,
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
            "  printf '%s\\n' \"${FAKE_ARTIFACT_COMMIT:-None}\"\n"
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
    def test_normal_path_routes_banner_input_to_hardened_pipeline(self):
        first_script, final_script = xml_system_scripts(CHECK_FOR_UPDATES)
        guard = first_script.index("buildSpec.banner_rollout")
        old_pipeline = first_script.index('getItemByFullName("PIC-SURE Pipeline")')
        self.assertLess(guard, old_pipeline)
        self.assertIn("if (!bannerRollout)", first_script[guard:old_pipeline])
        hardened = final_script.index('getItemByFullName("PIC-SURE Pipeline Build and Deploy")')
        legacy = final_script.index('getItemByFullName("Deployment Pipeline")')
        self.assertLess(hardened, legacy)
        self.assertIn("if (bannerRollout)", final_script[:hardened])
        for required in (
            "RUN_DATABASE_MIGRATIONS",
            "INCLUDE_PIC_SURE_API",
            "INCLUDE_PIC_SURE_AUTH_MICRO_APP",
            "INCLUDE_PIC_SURE_FRONTEND",
        ):
            self.assertIn(required, final_script[hardened:legacy])

    def test_build_spec_is_parsed_once_into_serializable_values(self):
        script = xml_script(PIPELINE)
        self.assertIn("@NonCPS\ndef parseBuildSpec", script)
        self.assertEqual(1, script.count("readFile('build-spec.json')"))
        self.assertEqual(1, script.count("new JsonSlurper().parseText"))
        self.assertNotIn("bannerRollout = new JsonSlurper", script)
        self.assertIn("bannerRolloutPresent: spec.banner_rollout != null", script)
        self.assertIn("bannerRolloutPresent = parsedBuildSpec.bannerRolloutPresent", script)

    def test_backend_health_finishes_before_frontend_publication(self):
        script = xml_script(PIPELINE)
        backend = script.index("build job: 'PIC-SURE Wildfly Stack Deploy'")
        frontend = script.index("build job: 'PIC-SURE Frontend Deploy'")
        self.assertLess(backend, frontend)
        self.assertEqual(containing_parallel(script, backend), containing_parallel(script, frontend))
        self.assertIn("BANNER_BACKEND_HEALTH_RECEIPT", script[frontend:])

    def test_frontend_is_built_from_reviewed_commit_before_deploy(self):
        script = xml_script(PIPELINE)
        build = script.index("build job: 'PIC-SURE Frontend Build'")
        deploy = script.index("build job: 'PIC-SURE Frontend Deploy'")
        self.assertLess(build, deploy)
        self.assertIn("build_hashes['PSF']", script[build:deploy])
        frontend_build_shell = xml_shell(FRONTEND_BUILD)
        self.assertIn('"git-commit=${GIT_COMMIT}"', frontend_build_shell)

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
        self.assertIn("banner-rollout-attestation.json", script)
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
        retrieve = RETRIEVE_BUILD_SPEC.read_text(encoding="utf-8")
        self.assertIn("banner-rollout-attestation.json", retrieve)

    def test_backend_runs_real_aggregate_health_probe(self):
        shell = xml_shell(WILDFLY)
        logs = shell.index("wait_for_spring_boot_ssm_logs")
        probe = shell.rindex("/system/status")
        self.assertLess(logs, probe)
        self.assertIn("RUNNING", shell[probe:])


class FailClosedStandaloneTest(unittest.TestCase):
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


class ExecutableContractTest(unittest.TestCase):
    def setUp(self):
        self.release_control = Path(os.environ["BDC_RELEASE_CONTROL_ROOT"])
        self.infrastructure = Path(os.environ["BDC_INFRASTRUCTURE_ROOT"])

    def validate(self, deployment: str, spec: Path, *selections: str):
        attestation = []
        if deployment == "AIM-AHEAD":
            attestation = [
                "--attestation",
                str(self.infrastructure / "tests/fisma-banner-rollout/aim-ahead-completed-attestation.synthetic.json"),
            ]
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
                *attestation,
                *selections,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

    def current_jenkins_commit(self):
        return current_jenkins_commit()

    def bdc_tuple(self):
        spec = json.loads((self.release_control / "build-spec.json").read_text(encoding="utf-8"))
        return spec["banner_rollout"]["tupleSha256"]

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
        self.assertIn("operator attestation is incomplete", result.stderr)

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
        template["attestedAtUtc"] = "2026-08-29T00:00:00Z"
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
                ],
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

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
        import hashlib
        spec["banner_rollout"]["tupleSha256"] = hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(spec, handle)
            handle.flush()
            result = self.validate("BDC", Path(handle.name), *self.required_selections())
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("Jenkins source", result.stderr)


if __name__ == "__main__":
    unittest.main()
