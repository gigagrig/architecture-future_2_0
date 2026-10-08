#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf '%s\n' 'Test deployment confirmation, backend isolation and encrypted recovery without cloud credentials.' 'Usage: bash test-scripts.sh [-h|--help]' 'Example: bash Task2Advanced/tests/test-scripts.sh' 'Requires bash, jq, gpg, tar. Creates a private test directory under TMPDIR (/tmp by default); prints its path. Exit 0: all checks passed; nonzero: failure.'
  exit 0
fi
[[ $# == 0 ]] || { printf 'Unknown arguments; use -h.\n'; exit 1; }
for tool in jq gpg tar mktemp; do command -v "$tool" >/dev/null || { printf 'Missing executable: %s\n' "$tool"; exit 1; }; done
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
umask 077
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/future-task2-tests.XXXXXXXX")
printf 'Start script tests. Created private test directory: %s\n' "$test_dir"
mkdir -p "$test_dir/bin" "$test_dir/gnupg" "$test_dir/runs" "$test_dir/recovery-tools"
cp "$root/tests/fixtures/terraform" "$test_dir/bin/terraform"
chmod 700 "$test_dir/bin/terraform" "$test_dir/gnupg"
export PATH="$test_dir/bin:$PATH"
export FAKE_TERRAFORM_TRACE="$test_dir/commands.log"
export YC_SERVICE_ACCOUNT_KEY_FILE="$test_dir/key.json"
printf '{}\n' >"$YC_SERVICE_ACCOUNT_KEY_FILE"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export TF_VAR_folder_id=test TF_VAR_zone=ru-central1-a TF_VAR_image_id=test TF_VAR_subnet_id=test
export TF_VAR_security_group_ids='["test"]' TF_VAR_ssh_public_key='ssh-ed25519 TEST'
export STATE_BUCKET=future-test LOCK_ENDPOINT=https://docapi.serverless.yandexcloud.net/test LOCK_TABLE=terraform-locks
export GITHUB_STEP_SUMMARY="$test_dir/summary.log"
deploy=(bash "$root/scripts/deploy.sh" --logs-dir "$test_dir/runs")
printf 'Checking confirmation rejection; log: %s/reject.log\n' "$test_dir"
if "${deploy[@]}" --environment dev --operation apply >"$test_dir/reject.log" 2>&1; then
  printf 'FAIL: unconfirmed apply was accepted.\n'; exit 1
fi
[[ ! -e "$FAKE_TERRAFORM_TRACE" ]] || { printf 'FAIL: Terraform was invoked before confirmation.\n'; exit 1; }
printf 'Checking plan and backend isolation; log: %s/plan.log\n' "$test_dir"
"${deploy[@]}" --environment dev --operation plan >"$test_dir/plan.log" 2>&1
grep -q 'key=future-2-0/dev/terraform.tfstate' "$FAKE_TERRAFORM_TRACE"
if grep -q '^apply' "$FAKE_TERRAFORM_TRACE"; then printf 'FAIL: plan called apply.\n'; exit 1; fi
"${deploy[@]}" --environment stage --operation plan >"$test_dir/stage.log" 2>&1
grep -q 'key=future-2-0/stage/terraform.tfstate' "$FAKE_TERRAFORM_TRACE"
[[ $(find "$test_dir/runs" -maxdepth 1 -type d -name 'terraform_*' | wc -l) == 2 ]]
if grep -q PRIVATE_SENTINEL "$GITHUB_STEP_SUMMARY" "$test_dir/plan.log"; then printf 'FAIL: sensitive plan content leaked.\n'; exit 1; fi
printf 'Checking destroy plan and apply; log: %s/destroy.log\n' "$test_dir"
"${deploy[@]}" --environment dev --operation destroy --confirm dev >"$test_dir/destroy.log" 2>&1
grep -q '^plan .* -destroy' "$FAKE_TERRAFORM_TRACE"
grep -q '^apply .*deployment.tfplan' "$FAKE_TERRAFORM_TRACE"
printf 'Simulating backend write failure; log: %s/failure.log\n' "$test_dir"
if FAKE_APPLY_FAIL=true "${deploy[@]}" --environment dev --operation apply --confirm dev >"$test_dir/failure.log" 2>&1; then
  printf 'FAIL: failed apply returned success.\n'; exit 1
fi
[[ $(find "$test_dir/runs" -name errored.tfstate | wc -l) == 1 ]]
printf 'Generating temporary recovery key; log: %s/gpg.log\n' "$test_dir"
gpg --homedir "$test_dir/gnupg" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key task2-test-recovery rsa2048 encr 1d >"$test_dir/gpg.log" 2>&1
gpg --homedir "$test_dir/gnupg" --batch --armor --output "$test_dir/recovery.asc" --export >>"$test_dir/gpg.log" 2>&1
recovery=(bash "$root/scripts/recovery.sh" --public-key "$test_dir/recovery.asc" --logs-dir "$test_dir/recovery-tools")
printf 'Testing recovery preflight and encryption; log: %s/recovery.log\n' "$test_dir"
"${recovery[@]}" --check-only --output "$test_dir/check.gpg" >"$test_dir/recovery.log" 2>&1
"${recovery[@]}" --source "$test_dir/runs" --output "$test_dir/recovery.tar.gz.gpg" >>"$test_dir/recovery.log" 2>&1
gpg --homedir "$test_dir/gnupg" --batch --output "$test_dir/recovery.tar.gz" --decrypt "$test_dir/recovery.tar.gz.gpg" >>"$test_dir/gpg.log" 2>&1
tar -tzf "$test_dir/recovery.tar.gz" >"$test_dir/archive.list"
grep -q 'errored.tfstate' "$test_dir/archive.list"
state_path=$(grep 'errored.tfstate$' "$test_dir/archive.list")
tar -xOzf "$test_dir/recovery.tar.gz" "$state_path" | jq -e '.serial == 7 and .test == "PRIVATE_SENTINEL"' >/dev/null
if grep -q 'key.json' "$test_dir/archive.list"; then printf 'FAIL: provider key was archived.\n'; exit 1; fi
printf 'Complete: confirmation, plan-only, environment isolation, destroy, failed apply and encrypted recovery round-trip passed. Logs: %s\n' "$test_dir"
