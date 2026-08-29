#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
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
        "commit": "5d2ba9f59f161ace5e807c82a0580518a9d44d16",
    },
    "migrationsParity": {
        "repository": "https://github.com/hms-dbmi/PIC-SURE-Migrations.git",
        "commit": "05b1a77512dc0921570f0d442853fdcee75b8131",
    },
}
EXPECTED_CONTRACT = {
    "source": {
        "repository": "https://github.com/hms-dbmi/pic-sure.git",
        "commit": "0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8",
        "path": ".github/banner-rollout-contract.json",
        "sha256": "f8cb265d735b757872391e04fdcd5b999b785eaa427ca13f8f2eefd493715359",
    },
    "deploymentWideCacheRefresh": "PSAMA_PROCESS_RESTART",
    "forwardPhases": [
        "APPLY_AUTHORIZATION_AND_PIC_SURE_MIGRATIONS",
        "RECREATE_PSAMA",
        "VERIFY_OPERATIONS_AND_GATEWAY_HEALTH",
        "PUBLISH_FRONTEND_ACTIVE_V2",
    ],
    "rollbackPhases": [
        "FREEZE_BANNER_MANAGEMENT_WRITES",
        "ROLL_BACK_FRONTEND",
        "DISABLE_ACTIVE_AND_SCHEDULED_TARGETED_BANNERS_BEFORE_LEGACY_ACTIVE_FEED_BACKEND",
        "ROLL_BACK_OPERATIONS_AND_GATEWAY",
        "KEEP_BANNER_MANAGEMENT_WRITES_FROZEN_BELOW_TARGETING_CAPABLE_BACKEND",
        "RECREATE_PSAMA",
    ],
    "rollbackStateContract": {
        "freezeRequiredBeforeFrontendRollback": True,
        "ordinaryManagementWritesAllowedWhileFrozen": False,
        "targetedDisableAllowedWhileFrozen": True,
        "legacyBackendTransitionRequiresTargetedClear": True,
        "freezeRetainedBelowTargetingBackend": True,
        "frontendFirstRollbackAloneSafe": False,
        "schemaRollback": "KEEP_FORWARD_SCHEMA",
        "downMigrationAllowed": False,
    },
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


def tuple_sha256(deployment: str, components: dict) -> str:
    payload = {"deployment": deployment, "components": components}
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def validate_components(components: object):
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
    if not SHA.fullmatch(str(jenkins.get("commit", ""))):
        raise ContractError("banner_rollout.components.jenkins.commit must be an exact 40-character commit")
    if set(components) != {*EXPECTED_COMPONENTS, "jenkins"}:
        raise ContractError("banner_rollout.components contains an unexpected or omitted component")


def validate_release_input(spec: object, deployment: str, selections: dict[str, bool]) -> str:
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
    if rollout.get("contract") != EXPECTED_CONTRACT:
        raise ContractError("banner_rollout.contract does not match backend 0178bbd2")

    components = rollout.get("components")
    validate_components(components)
    expected_tuple = tuple_sha256(deployment, components)
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

    for option, selected in selections.items():
        if not selected:
            raise ContractError(f"{option} must be true for a banner rollout")
    return expected_tuple


def validate_attestation(attestation: object):
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
    for field in ("operator", "attestedAtUtc"):
        value = attestation.get(field)
        if not isinstance(value, str) or not value or value.startswith("__"):
            raise ContractError(f"operator attestation is incomplete: {field}")
    checks = attestation.get("checks")
    required_checks = (
        "privateReleaseControlPinsRequiredTuple",
        "publicInfrastructureRefResolvesToRequiredCommit",
        "forwardOrderAccepted",
        "rollbackFreezeAndTargetedDisableBoundaryAccepted",
        "forwardSchemaRetainedAndDownMigrationsForbidden",
    )
    if not isinstance(checks, dict) or any(checks.get(check) is not True for check in required_checks):
        raise ContractError("operator attestation is incomplete: every required check must be true")
    release_input = attestation.get("requiredReleaseInput")
    validate_release_input(
        release_input,
        "AIM-AHEAD",
        {
            "--run-database-migrations": True,
            "--include-api": True,
            "--include-psama": True,
            "--include-frontend": True,
        },
    )


def validate_rollback_attestation(attestation: object):
    if not isinstance(attestation, dict) or attestation.get("schemaVersion") != 1:
        raise ContractError("rollback attestation is incomplete: schemaVersion must be 1")
    if attestation.get("deployment") not in ("BDC", "AIM-AHEAD"):
        raise ContractError("rollback attestation is incomplete: deployment must be BDC or AIM-AHEAD")
    if not SHA256.fullmatch(str(attestation.get("tupleSha256", ""))):
        raise ContractError("rollback attestation is incomplete: tupleSha256 must identify the exact rollout")
    for field in ("operator", "attestedAtUtc"):
        value = attestation.get(field)
        if not isinstance(value, str) or not value or value.startswith("__"):
            raise ContractError(f"rollback attestation is incomplete: {field}")
    phases = attestation.get("phases")
    expected_phases = EXPECTED_CONTRACT["rollbackPhases"]
    if not isinstance(phases, list) or [entry.get("phase") for entry in phases if isinstance(entry, dict)] != expected_phases:
        raise ContractError("rollback attestation is incomplete: phases must match backend 0178bbd2 in order")
    if any(entry.get("attested") is not True for entry in phases):
        raise ContractError("rollback attestation is incomplete: every rollback phase must be attested")
    state = attestation.get("state")
    expected_state = {
        "managementWritesFrozen": True,
        "targetedActiveOrScheduledRemaining": 0,
        "forwardSchemaRetained": True,
        "downMigrationRun": False,
        "psamaRecreated": True,
    }
    if state != expected_state:
        raise ContractError("rollback attestation is incomplete: rollback state does not fail closed")


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--build-spec", type=Path)
    mode.add_argument("--attestation", type=Path)
    mode.add_argument("--rollback-attestation", type=Path)
    parser.add_argument("--deployment", choices=("BDC", "AIM-AHEAD"))
    parser.add_argument("--run-database-migrations", type=parse_bool)
    parser.add_argument("--include-api", type=parse_bool)
    parser.add_argument("--include-psama", type=parse_bool)
    parser.add_argument("--include-frontend", type=parse_bool)
    args = parser.parse_args()
    try:
        if args.attestation:
            validate_attestation(read_json(args.attestation))
            return 0
        if args.rollback_attestation:
            validate_rollback_attestation(read_json(args.rollback_attestation))
            return 0
        if not args.deployment:
            raise ContractError("--deployment is required with --build-spec")
        selections = {
            "--run-database-migrations": args.run_database_migrations,
            "--include-api": args.include_api,
            "--include-psama": args.include_psama,
            "--include-frontend": args.include_frontend,
        }
        if any(value is None for value in selections.values()):
            raise ContractError("all four service-selection options are required")
        digest = validate_release_input(read_json(args.build_spec), args.deployment, selections)
        print(digest)
        return 0
    except ContractError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
