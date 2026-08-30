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
VALIDATOR = ROOT / "jenkins-docker/scripts/validate-banner-rollout.py"
CONTRACT = ROOT / "jenkins-docker/scripts/banner-rollout-contract.json"
GROOVY_GUARD_RUNNER = ROOT / "tests/fisma-banner-rollout/run_system_groovy_guard.groovy"


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
            check_for_updates.index("if (bannerRollout)")
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
        guard = first_script.index("buildSpec.banner_rollout")
        old_pipeline = first_script.index('getItemByFullName("PIC-SURE Pipeline")')
        self.assertLess(guard, old_pipeline)
        self.assertNotIn("if (!bannerRollout)", first_script)
        self.assertIn("scheduleBuild2(0, new ParametersAction([", first_script[old_pipeline:])
        self.assertIn("])).get()", first_script[old_pipeline:])
        deployment = final_script.index('getItemByFullName("Deployment Pipeline")')
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
        script = xml_script(PIPELINE)
        banner = script.index("if (bannerRolloutPresent)")
        validator = script.index("validate-banner-rollout.py", banner)
        guarded = script[banner:validator]
        self.assertIn("Deployment Pipeline", guarded)
        self.assertIn("MIGRATIONS_COMPLETED_UPSTREAM", guarded)
        self.assertIn("Cause$UpstreamCause", guarded)

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
        self.assertIn("BANNER_CONTROLLER_DEPLOYMENT", dockerfile)
        self.assertIn("--controller-deployment", script)
        retrieve = RETRIEVE_BUILD_SPEC.read_text(encoding="utf-8")
        self.assertIn("banner-rollout-attestation.json", retrieve)

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
