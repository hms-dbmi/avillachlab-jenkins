#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PIPELINE = ROOT / "jenkins-docker/jobs/PIC-SURE Pipeline Build and Deploy/config.xml"
WILDFLY = ROOT / "jenkins-docker/jobs/PIC-SURE Wildfly Stack Deploy/config.xml"
FRONTEND = ROOT / "jenkins-docker/jobs/PIC-SURE Frontend Deploy/config.xml"
VALIDATOR = ROOT / "jenkins-docker/scripts/validate-banner-rollout.py"


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


def run_shell_guard(path: Path, extra_env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temp:
        home = Path(temp)
        (home / "workspace/Bash_Functions").mkdir(parents=True)
        env = {
            "PATH": os.environ["PATH"],
            "JENKINS_HOME": str(home),
            "TARGET_STACK": "staging",
            "S3_BUCKET_NAME": "synthetic-bucket",
            "stack_s3_bucket": "synthetic-bucket",
            **extra_env,
        }
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
    def test_backend_health_finishes_before_frontend_publication(self):
        script = xml_script(PIPELINE)
        backend = script.index("build job: 'PIC-SURE Wildfly Stack Deploy'")
        frontend = script.index("build job: 'PIC-SURE Frontend Deploy'")
        self.assertLess(backend, frontend)
        self.assertIsNone(containing_parallel(script, backend))
        self.assertIsNone(containing_parallel(script, frontend))
        self.assertIn("BANNER_BACKEND_HEALTH_ATTESTATION", script[backend:frontend + 800])

    def test_pipeline_invokes_executable_tuple_and_service_validator(self):
        script = xml_script(PIPELINE)
        self.assertIn("validate-banner-rollout.py", script)
        for selection in (
            "RUN_DATABASE_MIGRATIONS",
            "INCLUDE_PIC_SURE_API",
            "INCLUDE_PIC_SURE_AUTH_MICRO_APP",
            "INCLUDE_PIC_SURE_FRONTEND",
        ):
            self.assertIn(selection, script)
        dockerfile = (ROOT / "jenkins-docker/Dockerfile").read_text(encoding="utf-8")
        self.assertIn("validate-banner-rollout.py", dockerfile)


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

    def test_wildfly_banner_mode_rejects_omitted_psama(self):
        result = run_shell_guard(
            WILDFLY,
            {
                "BANNER_ROLLOUT": "true",
                "BANNER_ROLLOUT_TUPLE_SHA256": "a" * 64,
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
                "BANNER_ROLLOUT_TUPLE_SHA256": "a" * 64,
                "BANNER_BACKEND_HEALTH_ATTESTATION": "",
            },
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("verified Operations, Gateway, and PSAMA health", result.stderr)


class ExecutableContractTest(unittest.TestCase):
    def setUp(self):
        self.release_control = Path(
            os.environ.get(
                "BDC_RELEASE_CONTROL_ROOT",
                ROOT.parent / "pic-sure-bdc-release-control",
            )
        )
        self.infrastructure = Path(
            os.environ.get(
                "BDC_INFRASTRUCTURE_ROOT",
                ROOT.parent / "pic-sure-bdc-infrastructure",
            )
        )

    def validate(self, deployment: str, spec: Path, *selections: str):
        return subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                "--deployment",
                deployment,
                "--build-spec",
                str(spec),
                *selections,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

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
            ["python3", str(VALIDATOR), "--rollback-attestation", str(template)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("rollback attestation is incomplete", result.stderr)


if __name__ == "__main__":
    unittest.main()
