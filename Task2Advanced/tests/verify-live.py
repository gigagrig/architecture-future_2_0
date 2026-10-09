#!/usr/bin/env python3
"""Verify dev remote state and locks, optionally create and remove the dev VM."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, epilog="Example: python3 verify-live.py --config-dir /secure/task2 --logs-dir /secure/log --lifecycle. Requires Terraform 1.11.4, jq, boto3 and cryptography. Reads bootstrap output, writes private logs; never prints secrets. --lifecycle creates paid dev resources and destroys them after successful apply, including when a later verification fails. Exit 0: success; nonzero: failure; inspect private logs before retrying.")
    parser.add_argument("--config-dir", required=True, type=Path, help="Private bootstrap output directory")
    parser.add_argument("--logs-dir", default=Path("log"), type=Path, help="Private log directory (default: ./log)")
    parser.add_argument("--lifecycle", action="store_true", help="Create, check and destroy dev resources")
    args = parser.parse_args()
    print(f"Start live verification: config={args.config_dir}, logs={args.logs_dir}, lifecycle={args.lifecycle}", flush=True)
    os.umask(0o077)
    directory = args.logs_dir.resolve() / ("live_" + uuid.uuid4().hex[:12])
    directory.mkdir(parents=True)
    print(f"Created private log directory: {directory}", flush=True)
    root = Path(__file__).resolve().parents[2]
    scripts = root / "Task2Advanced/scripts"
    sys.path.insert(0, str(scripts))
    from bootstrap import Cloud
    import boto3
    variables = json.loads((args.config_dir / "github-variables.json").read_text())
    key = json.loads((args.config_dir / "backend-key.json").read_text())
    env = os.environ.copy()
    env.update({"YC_SERVICE_ACCOUNT_KEY_FILE": str((args.config_dir / "deploy-key.json").resolve()), "AWS_ACCESS_KEY_ID": key["access_key_id"], "AWS_SECRET_ACCESS_KEY": key["secret_access_key"], "AWS_EC2_METADATA_DISABLED": "true", "STATE_BUCKET": variables["TF_STATE_BUCKET"], "LOCK_ENDPOINT": variables["YDB_DOCUMENT_API_ENDPOINT"], "LOCK_TABLE": variables["TF_LOCK_TABLE"]})
    for name, source in {"folder_id": "YC_FOLDER_ID", "zone": "YC_ZONE", "image_id": "YC_IMAGE_ID", "subnet_id": "YC_SUBNET_ID", "security_group_ids": "YC_SECURITY_GROUP_IDS", "ssh_public_key": "VM_SSH_PUBLIC_KEY"}.items():
        env["TF_VAR_" + name] = variables[source]
    clients = {"region_name": "ru-central1", "aws_access_key_id": key["access_key_id"], "aws_secret_access_key": key["secret_access_key"]}
    s3 = boto3.client("s3", endpoint_url="https://storage.yandexcloud.net", **clients)
    ddb = boto3.client("dynamodb", endpoint_url=variables["YDB_DOCUMENT_API_ENDPOINT"], **clients)
    bucket = variables["TF_STATE_BUCKET"]
    state_key = "future-2-0/dev/terraform.tfstate"
    table = variables["TF_LOCK_TABLE"]

    def run(label: str, command: list[str], run_env: dict | None = None, expect_failure: bool = False) -> Path:
        log = directory / f"{label}_{datetime.now(timezone.utc):%Y%m%d_%H%M%S}_{os.getpid()}.log"
        print(f"Running {label}; private log: {log}", flush=True)
        with log.open("w") as output:
            result = subprocess.run(command, cwd=root, env=run_env or env, stdout=output, stderr=subprocess.STDOUT)
        if expect_failure and result.returncode == 0:
            raise RuntimeError(f"{label}: expected rejection, got success; see {log}")
        if not expect_failure and result.returncode:
            raise RuntimeError(f"{label}: failed with code {result.returncode}; see {log}")
        return log

    def deploy(operation: str, environment: str = "dev") -> Path:
        target = directory / (environment + "_" + operation)
        run(environment + "_" + operation, ["bash", str(scripts / "deploy.sh"), "--environment", environment, "--operation", operation, "--confirm", environment, "--logs-dir", str(target)])
        return next(target.glob("terraform_*"))

    def state() -> tuple[dict, str]:
        response = s3.get_object(Bucket=bucket, Key=state_key)
        return json.loads(response["Body"].read()), response.get("VersionId", "")

    applied = False
    try:
        plan_dir = deploy("plan")
        if not args.lifecycle:
            print("Complete: remote init/plan succeeded; no resources applied.", flush=True)
            return 0
        # Do not run lifecycle tests against a pre-existing deployment.
        try:
            existing, _ = state()
        except s3.exceptions.NoSuchKey:
            existing = {}
        if existing.get("resources"):
            raise RuntimeError("Dev state already contains resources; refusing lifecycle test")
        run_dir = deploy("apply")
        applied = True
        current, version = state()
        if not version or version == "null":
            raise RuntimeError("State object is not versioned")
        resources = current.get("resources", [])
        if sorted(item["type"] for item in resources) != ["yandex_compute_disk", "yandex_compute_instance"]:
            raise RuntimeError("Remote state has unexpected resources")
        instance = next(item for item in resources if item["type"] == "yandex_compute_instance")["instances"][0]["attributes"]
        cloud = Cloud(args.config_dir / "deploy-key.json")
        vm = cloud.request("compute", "compute/v1/instances/" + instance["id"])
        if vm["status"] != "RUNNING" or any("oneToOneNat" in nic for nic in vm["networkInterfaces"]):
            raise RuntimeError("VM is not running privately")
        if int(vm["resources"]["cores"]) != 2 or int(vm["resources"]["memory"]) != 4 * 1024**3 or len(vm.get("secondaryDisks", [])) != 1:
            raise RuntimeError("Unexpected VM size or attached disk count")
        print("Verified: private RUNNING VM, 2 vCPU, 4 GiB RAM, attached data disk; versioned remote state.", flush=True)
        no_change = deploy("plan")
        summary = json.loads((no_change / "summary.json").read_text())
        if any(item["action"] != "no-op" for item in summary):
            raise RuntimeError("Repeat plan has changes")
        print("Verified: repeat plan has no changes.", flush=True)

        lock_id = bucket + "/" + state_key
        info = json.dumps({"ID": str(uuid.uuid4()), "Operation": "OperationTypeApply", "Info": "Task2 controlled lock test", "Who": "task2-live-test", "Version": "1.11.4", "Created": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"), "Path": lock_id})
        ddb.put_item(TableName=table, Item={"LockID": {"S": lock_id}, "Info": {"S": info}}, ConditionExpression="attribute_not_exists(LockID)")
        try:
            locked_env = {**env, "TF_DATA_DIR": str(run_dir / "backend"), "TF_VAR_environment": "dev", "TF_INPUT": "false", "TF_WORKSPACE": "default"}
            log = run("occupied_lock", ["terraform", "-chdir=Task2Advanced/terraform", "plan", "-no-color", "-input=false", "-lock-timeout=3s", "-var-file=../envs/dev.tfvars"], locked_env, expect_failure=True)
            if "Error acquiring the state lock" not in log.read_text():
                raise RuntimeError("Plan failed for a reason other than occupied state lock")
        finally:
            ddb.delete_item(TableName=table, Key={"LockID": {"S": lock_id}}, ConditionExpression="Info = :expected", ExpressionAttributeValues={":expected": {"S": info}})
        print("Verified: Terraform refuses a lock held in YDB; only the test lock was removed.", flush=True)
        _, before_stage = state()
        deploy("plan", "stage")
        _, after_stage = state()
        if before_stage != after_stage:
            raise RuntimeError("Stage plan changed the dev state object")
        print("Verified: stage plan uses its own state key and leaves dev state unchanged.", flush=True)
    except Exception as error:
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"Live verification failed: {message}", flush=True)
        return 1
    finally:
        if applied:
            deploy("destroy")
            remaining, _ = state()
            if remaining.get("resources"):
                raise RuntimeError("Cleanup did not empty the dev state")
            print("Cleanup verified: dev VM and disks removed; remote backend retained.", flush=True)
    print(f"Complete: all live backend checks passed. Private logs: {directory}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
