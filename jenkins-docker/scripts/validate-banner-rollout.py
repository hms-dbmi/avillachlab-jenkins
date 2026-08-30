#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path


SHA = re.compile(r"^[0-9a-f]{40}$")
OPERATOR = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._@-]{2,127}$")
TARGET_STACK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{1,63}$")
ARTIFACT_PREFIX = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9_-]{1,63}/banner-rollout/rollback/[A-Za-z0-9][A-Za-z0-9_-]{2,127}/containers$"
)
CONTRACT_PATH = Path(__file__).with_name("banner-rollout-contract.json")
EXPECTED_CONTRACT_SHA256 = "f8cb265d735b757872391e04fdcd5b999b785eaa427ca13f8f2eefd493715359"
EXPECTED_COMPONENTS = {
    "backend": {
        "repository": "https://github.com/hms-dbmi/pic-sure.git",
        "commit": "0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8",
    },
    "frontend": {
        "repository": "https://github.com/hms-dbmi/PIC-SURE-Frontend.git",
        "commit": "7b69aa960ff98f97c1a2d026b7137b0e3dcdf603",
    },
    "infrastructure": {
        "repository": "https://github.com/hms-dbmi/pic-sure-bdc-infrastructure.git",
        "ref": "pic_sure_api_rewrite",
        "commit": "c18c56a4aeaf7b75a1f4feb4bc19c5c09a29c7c1",
    },
    "migrationsParity": {
        "repository": "https://github.com/hms-dbmi/PIC-SURE-Migrations.git",
        "commit": "05b1a77512dc0921570f0d442853fdcee75b8131",
    },
}
COMPONENT_COMMITS = {
    "backend": EXPECTED_COMPONENTS["backend"]["commit"],
    "frontend": EXPECTED_COMPONENTS["frontend"]["commit"],
    "infrastructure": EXPECTED_COMPONENTS["infrastructure"]["commit"],
    "migrationsParity": EXPECTED_COMPONENTS["migrationsParity"]["commit"],
}
EXPECTED_CONTRACT_SOURCE = {
    "repository": "https://github.com/hms-dbmi/pic-sure.git",
    "commit": "0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8",
    "path": ".github/banner-rollout-contract.json",
    "sha256": EXPECTED_CONTRACT_SHA256,
}
REQUIRED_SERVICES = ["PSAMA", "OPERATIONS", "GATEWAY"]
RELEASE_CONTROL_SOURCES = {
    "BDC": {
        "repository": "https://github.com/hms-dbmi/pic-sure-bdc-release-control.git",
        "ref": "als-12831/t21-fisma-rollout-order",
        "resolvedCommitSource": "JENKINS_CHECKED_OUT_GIT_COMMIT",
    },
    "AIM-AHEAD": {
        "visibility": "PRIVATE_FISMA_BOUNDARY",
        "operatorManaged": True,
        "resolvedCommitSource": "OPERATOR_ATTESTATION",
    },
}


class ContractError(ValueError):
    pass


def read_json(path: Path):
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read JSON {path}: {error}") from error


def parse_bool(value: str) -> bool:
    if value not in ("true", "false"):
        raise argparse.ArgumentTypeError("expected true or false")
    return value == "true"


def authoritative_contract() -> dict:
    try:
        encoded = CONTRACT_PATH.read_bytes()
    except OSError as error:
        raise ContractError(f"cannot read authoritative rollout contract: {error}") from error
    if hashlib.sha256(encoded).hexdigest() != EXPECTED_CONTRACT_SHA256:
        raise ContractError("bundled rollout contract does not match backend 0178bbd2")
    try:
        contract = json.loads(encoded)
    except json.JSONDecodeError as error:
        raise ContractError(f"bundled rollout contract is invalid JSON: {error}") from error
    return contract


def tuple_sha256(deployment: str, components: dict) -> str:
    payload = {"deployment": deployment, "components": components}
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def expected_components(jenkins_source_commit: str) -> dict:
    if not SHA.fullmatch(jenkins_source_commit):
        raise ContractError("running Jenkins source must be an exact 40-character commit")
    return {
        **EXPECTED_COMPONENTS,
        "jenkins": {
            "repository": "https://github.com/hms-dbmi/avillachlab-jenkins.git",
            "commit": jenkins_source_commit,
        },
    }


def expected_tuple_sha256(deployment: str, jenkins_source_commit: str) -> str:
    return tuple_sha256(deployment, expected_components(jenkins_source_commit))


def validate_components(components: object, jenkins_source_commit: str):
    if not isinstance(components, dict):
        raise ContractError("banner_rollout.components must be an object")
    for name, expected in EXPECTED_COMPONENTS.items():
        if components.get(name) != expected:
            raise ContractError(f"banner_rollout.components.{name} does not match the reviewed source")
    jenkins = components.get("jenkins")
    if not isinstance(jenkins, dict):
        raise ContractError("banner_rollout.components.jenkins is required")
    if jenkins.get("repository") != "https://github.com/hms-dbmi/avillachlab-jenkins.git":
        raise ContractError("banner_rollout.components.jenkins.repository is not the public Jenkins source")
    if not SHA.fullmatch(jenkins_source_commit):
        raise ContractError("running Jenkins source must be an exact 40-character commit")
    if jenkins.get("commit") != jenkins_source_commit:
        raise ContractError("banner_rollout Jenkins source does not match the running Jenkins image")
    if jenkins != expected_components(jenkins_source_commit)["jenkins"]:
        raise ContractError("banner_rollout.components.jenkins contains an unexpected field")
    if set(components) != {*EXPECTED_COMPONENTS, "jenkins"}:
        raise ContractError("banner_rollout.components contains an unexpected or omitted component")


def validate_release_input(
    spec: object,
    deployment: str,
    selections: dict[str, bool],
    jenkins_source_commit: str,
    attestation: object | None = None,
    operation: str = "FORWARD",
    release_control_commit: str | None = None,
    controller_deployment: str | None = None,
    build_spec_sha256: str | None = None,
) -> str:
    if not isinstance(spec, dict):
        raise ContractError("build spec must be a JSON object")
    rollout = spec.get("banner_rollout")
    if not isinstance(rollout, dict):
        raise ContractError("banner_rollout metadata is required")
    if rollout.get("schemaVersion") != 3:
        raise ContractError("banner_rollout.schemaVersion must be 3")
    if rollout.get("deployment") != deployment:
        raise ContractError(f"banner_rollout.deployment must be {deployment}")
    if rollout.get("requiredServices") != REQUIRED_SERVICES:
        raise ContractError("banner_rollout.requiredServices must contain PSAMA, Operations, and Gateway exactly once")
    if rollout.get("releaseControl") != RELEASE_CONTROL_SOURCES[deployment]:
        raise ContractError("banner_rollout.releaseControl does not identify the deployment release-control source")
    if rollout.get("contractSource") != EXPECTED_CONTRACT_SOURCE:
        raise ContractError("banner_rollout.contractSource does not identify backend 0178bbd2")
    if rollout.get("contract") != authoritative_contract():
        raise ContractError("banner_rollout.contract does not match backend 0178bbd2")

    components = rollout.get("components")
    validate_components(components, jenkins_source_commit)
    expected_tuple = expected_tuple_sha256(deployment, jenkins_source_commit)
    if rollout.get("tupleSha256") != expected_tuple:
        raise ContractError(f"banner_rollout.tupleSha256 must be {expected_tuple}")

    application = spec.get("application")
    if not isinstance(application, list):
        raise ContractError("application must be an array")
    hashes = {
        item.get("project_job_git_key"): item.get("git_hash")
        for item in application
        if isinstance(item, dict)
    }
    if hashes.get("PSA") != components["backend"]["commit"]:
        raise ContractError("application PSA git_hash must pin the reviewed backend commit")
    if hashes.get("PSF") != components["frontend"]["commit"]:
        raise ContractError("application PSF git_hash must pin the reviewed frontend commit")
    if spec.get("infrastructure_git_hash") != components["infrastructure"]["commit"]:
        raise ContractError("infrastructure_git_hash must pin the reviewed infrastructure commit")

    if operation == "FORWARD":
        for option, selected in selections.items():
            if not selected:
                raise ContractError(f"{option} must be true for a forward banner rollout")
    elif operation == "NON_BANNER_COMPONENTS":
        for option, selected in selections.items():
            if selected:
                raise ContractError(f"{option} must be false for a non-banner component run")
    else:
        raise ContractError(f"unsupported banner rollout operation: {operation}")
    if normalize_controller_deployment(controller_deployment) != deployment:
        raise ContractError("build input deployment does not match this Jenkins controller")
    if not isinstance(release_control_commit, str) or not SHA.fullmatch(release_control_commit):
        raise ContractError("checked-out release-control commit must be exact")
    if deployment == "AIM-AHEAD":
        if attestation is None:
            raise ContractError("AIM-AHEAD requires its private release-control attestation")
        validate_attestation(
            attestation,
            release_control_commit,
            expected_tuple,
            build_spec_sha256,
            jenkins_source_commit,
        )
    elif attestation is not None:
        raise ContractError("BDC does not accept an AIM-AHEAD attestation")
    return expected_tuple


def validate_attestation(
    attestation: object,
    release_control_commit: str,
    expected_tuple: str,
    build_spec_sha256: str | None,
    jenkins_source_commit: str,
):
    if not isinstance(attestation, dict) or attestation.get("schemaVersion") != 1:
        raise ContractError("operator attestation is incomplete: schemaVersion must be 1")
    if attestation.get("deployment") != "AIM-AHEAD":
        raise ContractError("operator attestation is incomplete: deployment must be AIM-AHEAD")
    release_control = attestation.get("privateReleaseControl")
    if not isinstance(release_control, dict):
        raise ContractError("operator attestation is incomplete: privateReleaseControl is required")
    for field in ("repository", "ref", "resolvedCommit"):
        value = release_control.get(field)
        if not isinstance(value, str) or not value or value.startswith("__"):
            raise ContractError(f"operator attestation is incomplete: privateReleaseControl.{field}")
    if not SHA.fullmatch(release_control["resolvedCommit"]):
        raise ContractError("operator attestation is incomplete: private release-control commit is not exact")
    if release_control["resolvedCommit"] != release_control_commit:
        raise ContractError("operator attestation does not match the checked-out private release-control commit")
    validate_operator_metadata(attestation, "operator attestation")
    release_input = attestation.get("releaseInput")
    expected_release_input = {
        "buildSpecSha256": build_spec_sha256,
        "tupleSha256": expected_tuple,
        "jenkinsSourceCommit": jenkins_source_commit,
    }
    if release_input != expected_release_input:
        raise ContractError("operator attestation does not match the exact build input and tuple")
    checks = attestation.get("checks")
    required_checks = (
        "privateReleaseControlPinsRequiredTuple",
        "publicInfrastructureRefContainsRequiredCommit",
        "forwardOrderAccepted",
        "rollbackFreezeAndTargetedDisableBoundaryAccepted",
        "forwardSchemaRetainedAndDownMigrationsForbidden",
    )
    if not isinstance(checks, dict) or any(checks.get(check) is not True for check in required_checks):
        raise ContractError("operator attestation is incomplete: every required check must be true")


def validate_operator_metadata(attestation: dict, label: str):
    operator = attestation.get("operator")
    if not isinstance(operator, str) or not OPERATOR.fullmatch(operator):
        raise ContractError(f"{label} is incomplete: operator must identify the attesting person")
    timestamp = attestation.get("attestedAtUtc")
    if not isinstance(timestamp, str) or not timestamp.endswith("Z"):
        raise ContractError(f"{label} is incomplete: attestedAtUtc must be an ISO-8601 UTC timestamp")
    try:
        parsed = datetime.datetime.fromisoformat(timestamp[:-1] + "+00:00")
    except ValueError as error:
        raise ContractError(f"{label} is incomplete: attestedAtUtc must be an ISO-8601 UTC timestamp") from error
    if parsed.tzinfo != datetime.timezone.utc:
        raise ContractError(f"{label} is incomplete: attestedAtUtc must be UTC")
    now = datetime.datetime.now(datetime.timezone.utc)
    if parsed > now + datetime.timedelta(minutes=5) or now - parsed > datetime.timedelta(hours=24):
        raise ContractError(f"{label} is not fresh within the allowed 24-hour window")


def normalize_controller_deployment(value: str | None) -> str | None:
    return {
        "bdc": "BDC",
        "BDC": "BDC",
        "aim-ahead": "AIM-AHEAD",
        "AIM-AHEAD": "AIM-AHEAD",
    }.get(value)


def validate_rollback_attestation(
    attestation: object,
    jenkins_source_commit: str,
    controller_deployment: str,
    target_stack: str,
    required_stage: str | None = None,
):
    if not isinstance(attestation, dict) or attestation.get("schemaVersion") != 1:
        raise ContractError("rollback attestation is incomplete: schemaVersion must be 1")
    if attestation.get("deployment") not in ("BDC", "AIM-AHEAD"):
        raise ContractError("rollback attestation is incomplete: deployment must be BDC or AIM-AHEAD")
    expected_tuple = expected_tuple_sha256(attestation["deployment"], jenkins_source_commit)
    if attestation.get("tupleSha256") != expected_tuple:
        raise ContractError("rollback attestation is incomplete: tupleSha256 does not match the deployment")
    validate_operator_metadata(attestation, "rollback attestation")
    normalized_controller = normalize_controller_deployment(controller_deployment)
    if normalized_controller != attestation["deployment"] or attestation.get("controllerDeployment") != normalized_controller:
        raise ContractError("rollback attestation does not match this Jenkins controller tenant")
    if not TARGET_STACK.fullmatch(target_stack) or attestation.get("targetStack") != target_stack:
        raise ContractError("rollback attestation does not match the target stack")
    artifact_prefix = attestation.get("artifactPrefix")
    if not isinstance(artifact_prefix, str) or not ARTIFACT_PREFIX.fullmatch(artifact_prefix):
        raise ContractError("rollback attestation artifactPrefix must use the rollback namespace")
    if not artifact_prefix.startswith(f"{target_stack}/banner-rollout/rollback/"):
        raise ContractError("rollback attestation artifactPrefix does not match the target stack")
    artifacts = attestation.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != {"frontendCommit", "backendCommit"}:
        raise ContractError("rollback attestation must identify the exact frontend and backend artifacts")
    if not all(isinstance(value, str) and SHA.fullmatch(value) for value in artifacts.values()):
        raise ContractError("rollback attestation artifact commits must be exact")
    if artifacts["frontendCommit"] == COMPONENT_COMMITS["frontend"] or artifacts["backendCommit"] == COMPONENT_COMMITS["backend"]:
        raise ContractError("rollback attestation must select artifacts older than the reviewed forward tuple")
    phases = attestation.get("phases")
    expected_phases = authoritative_contract()["rollbackPhases"]
    if not isinstance(phases, list) or any(not isinstance(entry, dict) for entry in phases):
        raise ContractError("rollback attestation is incomplete: every phase must be an object")
    if [entry.get("phase") for entry in phases] != expected_phases:
        raise ContractError("rollback attestation is incomplete: phases must match backend 0178bbd2 in order")
    stage = attestation.get("stage")
    expected_attested = {
        "FRONTEND_ALLOWED": [True, False, False, False, False, False],
        "BACKEND_ALLOWED": [True, True, True, False, False, False],
        "PSAMA_ALLOWED": [True, True, True, True, True, False],
        "COMPLETE": [True, True, True, True, True, True],
    }
    if stage not in expected_attested:
        raise ContractError("rollback attestation is incomplete: stage is not recognized")
    if required_stage is not None and stage != required_stage:
        raise ContractError(f"rollback attestation stage must be {required_stage} for this entrypoint")
    if [entry.get("attested") for entry in phases] != expected_attested[stage]:
        raise ContractError("rollback attestation is incomplete: phase attestations do not match the stage")
    state = attestation.get("state")
    expected_states = {
        "FRONTEND_ALLOWED": {
            "managementWritesFrozen": True,
            "frontendRolledBack": False,
            "targetedActiveOrScheduledRemaining": None,
            "forwardSchemaRetained": True,
            "downMigrationRun": False,
            "psamaRecreated": False,
        },
        "BACKEND_ALLOWED": {
            "managementWritesFrozen": True,
            "frontendRolledBack": True,
            "targetedActiveOrScheduledRemaining": 0,
            "forwardSchemaRetained": True,
            "downMigrationRun": False,
            "psamaRecreated": False,
        },
        "PSAMA_ALLOWED": {
            "managementWritesFrozen": True,
            "frontendRolledBack": True,
            "targetedActiveOrScheduledRemaining": 0,
            "forwardSchemaRetained": True,
            "downMigrationRun": False,
            "psamaRecreated": False,
        },
        "COMPLETE": {
            "managementWritesFrozen": True,
            "frontendRolledBack": True,
            "targetedActiveOrScheduledRemaining": 0,
            "forwardSchemaRetained": True,
            "downMigrationRun": False,
            "psamaRecreated": True,
        },
    }
    if state != expected_states[stage]:
        raise ContractError("rollback attestation is incomplete: rollback state does not fail closed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-spec", type=Path)
    parser.add_argument("--attestation", type=Path)
    parser.add_argument("--rollback-attestation", type=Path)
    parser.add_argument("--tuple-sha256")
    parser.add_argument("--component-commit", choices=tuple(COMPONENT_COMMITS))
    parser.add_argument("--required-rollback-stage", choices=("FRONTEND_ALLOWED", "BACKEND_ALLOWED", "PSAMA_ALLOWED", "COMPLETE"))
    parser.add_argument("--deployment", choices=("BDC", "AIM-AHEAD"))
    parser.add_argument("--operation", choices=("FORWARD", "NON_BANNER_COMPONENTS"), default="FORWARD")
    parser.add_argument("--jenkins-source-commit")
    parser.add_argument("--release-control-commit")
    parser.add_argument("--controller-deployment")
    parser.add_argument("--target-stack")
    parser.add_argument("--run-database-migrations", type=parse_bool)
    parser.add_argument("--include-api", type=parse_bool)
    parser.add_argument("--include-psama", type=parse_bool)
    parser.add_argument("--include-frontend", type=parse_bool)
    args = parser.parse_args()
    try:
        if args.component_commit:
            if any(
                (
                    args.build_spec,
                    args.attestation,
                    args.rollback_attestation,
                    args.tuple_sha256,
                    args.required_rollback_stage,
                    args.deployment,
                    args.jenkins_source_commit,
                    args.release_control_commit,
                    args.controller_deployment,
                    args.target_stack,
                    args.run_database_migrations,
                    args.include_api,
                    args.include_psama,
                    args.include_frontend,
                )
            ) or args.operation != "FORWARD":
                raise ContractError("component commit lookup cannot be combined with a release input")
            print(COMPONENT_COMMITS[args.component_commit])
            return 0
        if args.rollback_attestation:
            if any(
                (
                    args.build_spec,
                    args.attestation,
                    args.tuple_sha256,
                    args.component_commit,
                    args.deployment,
                    args.release_control_commit,
                    args.run_database_migrations,
                    args.include_api,
                    args.include_psama,
                    args.include_frontend,
                )
            ) or args.operation != "FORWARD":
                raise ContractError("rollback attestation cannot be combined with a release input")
            if not args.jenkins_source_commit:
                raise ContractError("--jenkins-source-commit is required with --rollback-attestation")
            if not args.controller_deployment or not args.target_stack:
                raise ContractError("--controller-deployment and --target-stack are required with --rollback-attestation")
            validate_rollback_attestation(
                read_json(args.rollback_attestation),
                args.jenkins_source_commit,
                args.controller_deployment,
                args.target_stack,
                args.required_rollback_stage,
            )
            return 0
        if args.tuple_sha256:
            if any(
                (
                    args.build_spec,
                    args.attestation,
                    args.rollback_attestation,
                    args.component_commit,
                    args.required_rollback_stage,
                    args.release_control_commit,
                    args.controller_deployment,
                    args.target_stack,
                    args.run_database_migrations,
                    args.include_api,
                    args.include_psama,
                    args.include_frontend,
                )
            ) or args.operation != "FORWARD":
                raise ContractError("tuple verification cannot be combined with a release input")
            if not args.deployment or not args.jenkins_source_commit:
                raise ContractError("--deployment and --jenkins-source-commit are required with --tuple-sha256")
            expected_tuple = expected_tuple_sha256(args.deployment, args.jenkins_source_commit)
            if args.tuple_sha256 != expected_tuple:
                raise ContractError("tupleSha256 does not match the deployment and running Jenkins source")
            print(expected_tuple)
            return 0
        if args.attestation and not args.build_spec:
            raise ContractError("--attestation requires the exact --build-spec and release-control binding")
        if not args.build_spec:
            raise ContractError("one of --build-spec, --attestation, or --rollback-attestation is required")
        if not args.deployment:
            raise ContractError("--deployment is required with --build-spec")
        if not args.jenkins_source_commit:
            raise ContractError("--jenkins-source-commit is required with --build-spec")
        if args.required_rollback_stage or args.target_stack:
            raise ContractError("rollback-only arguments cannot be combined with --build-spec")
        selections = {
            "--run-database-migrations": args.run_database_migrations,
            "--include-api": args.include_api,
            "--include-psama": args.include_psama,
            "--include-frontend": args.include_frontend,
        }
        if any(value is None for value in selections.values()):
            raise ContractError("all four service-selection options are required")
        digest = validate_release_input(
            read_json(args.build_spec),
            args.deployment,
            selections,
            args.jenkins_source_commit,
            read_json(args.attestation) if args.attestation else None,
            args.operation,
            args.release_control_commit,
            args.controller_deployment,
            hashlib.sha256(args.build_spec.read_bytes()).hexdigest(),
        )
        print(digest)
        return 0
    except ContractError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
