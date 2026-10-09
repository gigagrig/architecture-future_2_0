#!/usr/bin/env python3
"""Create the dev backend and scoped CI accounts without storing secrets in Git."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request


def save(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)
    print(f"Saved private configuration: {path}", flush=True)


class Cloud:
    def __init__(self, key_path: Path):
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        key = json.loads(key_path.read_text())
        encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b"=")
        now = int(time.time())
        header = encode(json.dumps({"alg": "PS256", "typ": "JWT", "kid": key["id"]}).encode())
        payload = encode(json.dumps({"iss": key["service_account_id"], "aud": "https://iam.api.cloud.yandex.net/iam/v1/tokens", "iat": now, "exp": now + 600}).encode())
        body = header + b"." + payload
        private = serialization.load_pem_private_key(key["private_key"].encode(), None)
        signature = private.sign(body, padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32), hashes.SHA256())
        self.token = None
        result = self.request("iam", "iam/v1/tokens", {"jwt": (body + b"." + encode(signature)).decode()})
        self.token = result["iamToken"]

    def request(self, service: str, route: str, body: dict | None = None, method: str | None = None) -> dict:
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(f"https://{service}.api.cloud.yandex.net/{route}", headers=headers, data=json.dumps(body).encode() if body is not None else None, method=method)
        try:
            with urllib.request.urlopen(request, timeout=40) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # API bodies may contain credential fields; never print them.
            raise RuntimeError(f"{service} {route.split('?')[0]}: HTTP {error.code}") from None
        except urllib.error.URLError:
            raise RuntimeError(f"Connection failed: {service}") from None

    def wait(self, operation: dict) -> dict:
        deadline = time.monotonic() + 600
        while not operation.get("done"):
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Operation still pending: {operation['id']}; rerun after checking cloud console")
            time.sleep(5)
            operation = self.request("operation", "operations/" + operation["id"])
        if operation.get("error"):
            raise RuntimeError(f"Cloud operation {operation.get('id')} failed, code={operation['error'].get('code')}; inspect console")
        return operation.get("response", {})

    def bind(self, service: str, route: str, account: str, role: str) -> None:
        result = self.request(service, route + ":updateAccessBindings", {"accessBindingDeltas": [{"action": "ADD", "accessBinding": {"roleId": role, "subject": {"id": account, "type": "serviceAccount"}}}]})
        self.wait(result)
        print(f"Assigned {role} to {account} on {route}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, epilog="Example: python3 bootstrap.py --key /secure/admin.json --folder-id FOLDER --subnet-id SUBNET --output-dir /secure/task2 --apply. Outputs: deploy-key.json, backend-key.json, github-variables.json, resources.json and SSH keys, all outside the repository. Exit 0: success; 1: error. Requires boto3 and cryptography. Does not create VMs or remove resources.")
    parser.add_argument("--key", required=True, type=Path, help="Authorized bootstrap key; never copied into CI")
    parser.add_argument("--folder-id", required=True, help="Existing target folder")
    parser.add_argument("--subnet-id", required=True, help="Existing dev subnet")
    parser.add_argument("--output-dir", required=True, type=Path, help="Private directory outside the repository")
    parser.add_argument("--prefix", default="future-tf-dev", help="Names for new dev resources (default: future-tf-dev)")
    parser.add_argument("--apply", action="store_true", help="Create resources and keys; without this flag only inspect prerequisites")
    args = parser.parse_args()
    print(f"Start bootstrap: folder={args.folder_id}, subnet={args.subnet_id}, output={args.output_dir}, apply={args.apply}", flush=True)
    if not re.fullmatch(r"[a-z][a-z0-9-]{2,25}", args.prefix):
        parser.error("prefix must contain 3–26 lowercase letters, digits or hyphens")
    destination = args.output_dir.resolve()
    repository = Path(__file__).resolve().parents[2]
    if destination.is_relative_to(repository):
        parser.error("output-dir must be outside the repository")
    try:
        import boto3
        from botocore.config import Config
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        cloud = Cloud(args.key)
        folder = cloud.request("resource-manager", "resource-manager/v1/folders/" + args.folder_id)
        subnet = cloud.request("vpc", "vpc/v1/subnets/" + args.subnet_id)
        if subnet["folderId"] != args.folder_id:
            raise RuntimeError("Subnet belongs to a different folder")
        print(f"Confirmed folder {folder['name']}, zone {subnet['zoneId']}", flush=True)
        if not args.apply:
            print("Complete: read-only preflight. Use --apply to create backend resources.")
            return 0
        os.umask(0o077)
        destination.mkdir(parents=True, exist_ok=True, mode=0o700)
        destination.chmod(0o700)
        print(f"Private output directory: {destination}", flush=True)
        inventory_path = destination / "resources.json"
        inventory = json.loads(inventory_path.read_text()) if inventory_path.exists() else {"folder_id": args.folder_id, "prefix": args.prefix}
        if inventory["folder_id"] != args.folder_id or inventory["prefix"] != args.prefix:
            raise RuntimeError("Existing inventory belongs to a different folder or prefix")

        def account(suffix: str) -> str:
            name = args.prefix + "-" + suffix
            accounts = cloud.request("iam", f"iam/v1/serviceAccounts?folderId={args.folder_id}&pageSize=100").get("serviceAccounts", [])
            matches = [item for item in accounts if item["name"] == name]
            if matches:
                resource = matches[0]
            else:
                print(f"Creating service account {name}", flush=True)
                resource = cloud.wait(cloud.request("iam", "iam/v1/serviceAccounts", {"folderId": args.folder_id, "name": name, "description": "Task2Advanced dev CI"}))
            inventory[suffix + "_account_id"] = resource["id"]
            save(inventory_path, inventory)
            return resource["id"]

        deploy_sa = account("deploy")
        backend_sa = account("backend")
        cloud.bind("resource-manager", "resource-manager/v1/folders/" + args.folder_id, deploy_sa, "compute.editor")
        # YDB editor grants Document API access; no IAM administration is given to CI.
        cloud.bind("resource-manager", "resource-manager/v1/folders/" + args.folder_id, backend_sa, "ydb.editor")
        deploy_key = destination / "deploy-key.json"
        if not deploy_key.exists():
            result = cloud.request("iam", "iam/v1/keys", {"serviceAccountId": deploy_sa, "keyAlgorithm": "RSA_2048", "description": "Task2Advanced dev deployment"})
            save(deploy_key, {"id": result["key"]["id"], "service_account_id": deploy_sa, "created_at": result["key"]["createdAt"], "public_key": result["key"]["publicKey"], "private_key": result["privateKey"]})
        backend_key = destination / "backend-key.json"
        if not backend_key.exists():
            result = cloud.request("iam", "iam/aws-compatibility/v1/accessKeys", {"serviceAccountId": backend_sa, "description": "Task2Advanced dev state"})
            save(backend_key, {"access_key_id": result["accessKey"]["keyId"], "secret_access_key": result["secret"], "id": result["accessKey"]["id"]})

        bucket_name = args.prefix + "-" + args.folder_id
        buckets = cloud.request("storage", f"storage/v1/buckets?folderId={args.folder_id}").get("buckets", [])
        if not any(item["name"] == bucket_name for item in buckets):
            print(f"Creating private versioned bucket {bucket_name}", flush=True)
            cloud.wait(cloud.request("storage", "storage/v1/buckets", {"name": bucket_name, "folderId": args.folder_id, "defaultStorageClass": "STANDARD", "maxSize": str(1024**3), "versioning": "VERSIONING_ENABLED", "anonymousAccessFlags": {"read": False, "list": False, "configRead": False}}))
        inventory["bucket"] = bucket_name
        save(inventory_path, inventory)
        bucket = cloud.request("storage", "storage/v1/buckets/" + bucket_name)
        grants = bucket.get("acl", {}).get("grants", [])
        for permission in ("PERMISSION_READ", "PERMISSION_WRITE"):
            grant = {"permission": permission, "grantType": "GRANT_TYPE_ACCOUNT", "granteeId": backend_sa}
            if grant not in grants:
                grants.append(grant)
        cloud.wait(cloud.request("storage", "storage/v1/buckets/" + bucket_name, {"updateMask": "acl", "acl": {"grants": grants}}, method="PATCH"))
        print(f"Granted bucket read/write ACL to {backend_sa}; no folder-wide storage role", flush=True)

        databases = cloud.request("ydb", f"ydb/v1/databases?folderId={args.folder_id}").get("databases", [])
        found = [item for item in databases if item["name"] == args.prefix + "-locks"]
        if found:
            database = cloud.request("ydb", "ydb/v1/databases/" + found[0]["id"])
        else:
            print("Creating YDB Serverless: 10 RU/s limit, no provisioned capacity, 1 GiB limit", flush=True)
            database = cloud.wait(cloud.request("ydb", "ydb/v1/databases", {"folderId": args.folder_id, "name": args.prefix + "-locks", "locationId": "ru-central1", "serverlessDatabase": {"throttlingRcuLimit": "10", "enableThrottlingRcuLimit": True, "provisionedRcuLimit": "0", "storageSizeLimit": str(1024**3)}, "deletionProtection": True}))
        inventory["database_id"] = database["id"]
        save(inventory_path, inventory)
        endpoint = database["documentApiEndpoint"]
        credentials = json.loads(backend_key.read_text())
        dynamodb = boto3.client("dynamodb", endpoint_url=endpoint, region_name="ru-central1", aws_access_key_id=credentials["access_key_id"], aws_secret_access_key=credentials["secret_access_key"], config=Config(retries={"max_attempts": 5, "mode": "standard"}))
        for attempt in range(12):
            try:
                tables = dynamodb.list_tables()["TableNames"]
                break
            except Exception:
                if attempt == 11:
                    raise RuntimeError("Cannot access YDB Document API with backend key; inspect roles and endpoint") from None
                time.sleep(5)
        if "terraform-locks" not in tables:
            print("Creating Document API table terraform-locks", flush=True)
            dynamodb.create_table(TableName="terraform-locks", KeySchema=[{"AttributeName": "LockID", "KeyType": "HASH"}], AttributeDefinitions=[{"AttributeName": "LockID", "AttributeType": "S"}], BillingMode="PAY_PER_REQUEST")
            dynamodb.get_waiter("table_exists").wait(TableName="terraform-locks", WaiterConfig={"Delay": 3, "MaxAttempts": 40})

        groups = cloud.request("vpc", f"vpc/v1/securityGroups?folderId={args.folder_id}").get("securityGroups", [])
        found = [item for item in groups if item["name"] == args.prefix + "-private"]
        if found:
            group = found[0]
        else:
            print("Creating private VM security group: SSH within subnet; outbound traffic", flush=True)
            group = cloud.wait(cloud.request("vpc", "vpc/v1/securityGroups", {"folderId": args.folder_id, "networkId": subnet["networkId"], "name": args.prefix + "-private", "ruleSpecs": [{"direction": "INGRESS", "protocolName": "TCP", "ports": {"fromPort": "22", "toPort": "22"}, "cidrBlocks": {"v4CidrBlocks": subnet["v4CidrBlocks"]}}, {"direction": "EGRESS", "protocolName": "ANY", "cidrBlocks": {"v4CidrBlocks": ["0.0.0.0/0"]}}]}))
        inventory["security_group_id"] = group["id"]
        save(inventory_path, inventory)
        image = cloud.request("compute", "compute/v1/images:latestByFamily?folderId=standard-images&family=ubuntu-2404-lts")
        ssh_private = destination / "vm-ed25519"
        ssh_public = destination / "vm-ed25519.pub"
        if not ssh_private.exists():
            private = Ed25519PrivateKey.generate()
            ssh_private.write_bytes(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH, serialization.NoEncryption()))
            print(f"Created private SSH key: {ssh_private}", flush=True)
        else:
            private = serialization.load_ssh_private_key(ssh_private.read_bytes(), password=None)
        ssh_public.write_bytes(private.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH) + b" future-task2-dev\n")
        print(f"Saved public SSH key: {ssh_public}", flush=True)
        variables = {"YC_FOLDER_ID": args.folder_id, "YC_ZONE": subnet["zoneId"], "YC_IMAGE_ID": image["id"], "YC_SUBNET_ID": subnet["id"], "YC_SECURITY_GROUP_IDS": json.dumps([group["id"]]), "VM_SSH_PUBLIC_KEY": ssh_public.read_text().strip(), "TF_STATE_BUCKET": bucket_name, "YDB_DOCUMENT_API_ENDPOINT": endpoint, "TF_LOCK_TABLE": "terraform-locks"}
        recovery_public = destination / "recovery-public.asc"
        if recovery_public.exists():
            variables["TF_RECOVERY_PUBLIC_KEY"] = recovery_public.read_text()
        save(destination / "github-variables.json", variables)
        print("Complete: dev backend, CI accounts and network settings are ready; no VM created.", flush=True)
        return 0
    except Exception as error:
        # Do not stringify arbitrary SDK errors, which can embed sensitive data.
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"Bootstrap failed: {message}. Private output directory: {destination}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
