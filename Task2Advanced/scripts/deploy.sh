#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Run Terraform against the remote Yandex Object Storage/YDB backend.' \
    'Usage: bash deploy.sh --environment dev|stage|prod --operation plan|apply|destroy [--confirm ENV] [--logs-dir DIR]' \
    'Options: -h, --help; --confirm must equal ENV for apply/destroy; --logs-dir defaults to ./log.' \
    'Required environment: YC_SERVICE_ACCOUNT_KEY_FILE, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,' \
    'TF_VAR_folder_id, TF_VAR_zone, TF_VAR_image_id, TF_VAR_subnet_id, TF_VAR_security_group_ids,' \
    'TF_VAR_ssh_public_key, STATE_BUCKET, LOCK_ENDPOINT, LOCK_TABLE.' \
    'Example: bash deploy.sh --environment dev --operation plan' \
    'Example: bash deploy.sh --environment dev --operation apply --confirm dev --logs-dir /secure/run' \
    'Output: private logs, binary plan and summary.json in a unique run directory. Exit 0: success; nonzero: failure.'
}
fail() { printf 'Error: %s\n' "$*"; exit 1; }
environment='' operation='' confirmation='' logs_dir='./log'
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --environment|--operation|--confirm|--logs-dir)
      [[ $# -ge 2 ]] || fail "Missing value for $1"
      case "$1" in
        --environment) environment=$2 ;; --operation) operation=$2 ;;
        --confirm) confirmation=$2 ;; --logs-dir) logs_dir=$2 ;;
      esac
      shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ "$environment" =~ ^(dev|stage|prod)$ ]] || fail 'Select dev, stage or prod.'
[[ "$operation" =~ ^(plan|apply|destroy)$ ]] || fail 'Select plan, apply or destroy.'
[[ "$operation" == plan || "$confirmation" == "$environment" ]] || fail 'Confirmation must equal the environment.'
for tool in terraform jq mktemp date; do command -v "$tool" >/dev/null || fail "Missing executable: $tool"; done
for setting in YC_SERVICE_ACCOUNT_KEY_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_VAR_folder_id TF_VAR_zone TF_VAR_image_id TF_VAR_subnet_id TF_VAR_security_group_ids TF_VAR_ssh_public_key STATE_BUCKET LOCK_ENDPOINT LOCK_TABLE; do
  [[ -n "${!setting:-}" ]] || fail "Missing setting: $setting"
done
[[ -r "$YC_SERVICE_ACCOUNT_KEY_FILE" ]] || fail 'Provider key file is not readable.'
[[ "$STATE_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail 'Invalid state bucket name.'
[[ "$LOCK_TABLE" =~ ^[A-Za-z0-9_.-]+$ ]] || fail 'Invalid lock table name.'
[[ "$LOCK_ENDPOINT" =~ ^https://docapi\.serverless\.yandexcloud\.net/[A-Za-z0-9_/-]+$ ]] || fail 'Invalid YDB Document API endpoint.'
# Set by the caller and checked through the required-settings loop above.
# shellcheck disable=SC2154
printf '%s' "$TF_VAR_security_group_ids" | jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' >/dev/null || fail 'Security groups must be a nonempty JSON array.'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/../terraform" && pwd)
umask 077
mkdir -p -- "$logs_dir"
run_dir=$(mktemp -d "$logs_dir/terraform_${environment}_${operation}_XXXXXXXX")
run_dir=$(cd -- "$run_dir" && pwd)
printf 'Start: environment=%s operation=%s root=%s\nCreated run directory: %s\n' "$environment" "$operation" "$root" "$run_dir"
export TF_IN_AUTOMATION=true TF_INPUT=false AWS_EC2_METADATA_DISABLED=true
export TF_VAR_environment="$environment"
# Each run gets its own backend metadata; changing environments cannot reuse old settings.
export TF_DATA_DIR="$run_dir/backend"
export TF_WORKSPACE=default
unset TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply
stamp=$(date -u +%Y%m%d_%H%M%S)
invoke() {
  local stage=$1
  shift
  local logfile="$run_dir/terraform_${stamp}_${environment}_${stage}_$$.log"
  printf 'Terraform %s for %s; log: %s\n' "$stage" "$root" "$logfile"
  if terraform "-chdir=$root" "$@" >"$logfile" 2>&1; then
    return 0
  else
    local status=$?
    printf 'Terraform failed (%s); private diagnostic log: %s\n' "$status" "$logfile"
    return "$status"
  fi
}
invoke version version -json
version_file="$run_dir/terraform_${stamp}_${environment}_version_$$.log"
[[ $(jq -r '.terraform_version' "$version_file") == '1.11.4' ]] || fail 'Terraform 1.11.4 is required.'
invoke init init -input=false -reconfigure -lockfile=readonly \
  "-backend-config=bucket=$STATE_BUCKET" \
  "-backend-config=key=future-2-0/$environment/terraform.tfstate" \
  "-backend-config=endpoints={s3=\"https://storage.yandexcloud.net\",dynamodb=\"$LOCK_ENDPOINT\"}" \
  "-backend-config=dynamodb_table=$LOCK_TABLE"
invoke validate validate -no-color
plan_args=()
[[ "$operation" != destroy ]] || plan_args+=(-destroy)
invoke plan plan -input=false -no-color -lock-timeout=120s \
  "-var-file=../envs/$environment.tfvars" "-out=$run_dir/deployment.tfplan" "${plan_args[@]}"
# Publish only action counts; show output can contain all sensitive plan attributes.
show_log="$run_dir/terraform_${stamp}_${environment}_show_$$.log"
printf 'Creating action summary: %s/summary.json; diagnostic log: %s\n' "$run_dir" "$show_log"
terraform "-chdir=$root" show -json "$run_dir/deployment.tfplan" 2>"$show_log" |
  jq '[.resource_changes[]?.change.actions | join("+")] | group_by(.) | map({action: .[0], count: length})' >"$run_dir/summary.json"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Environment: %s; operation: %s; commit: %s\n' "$environment" "$operation" "${GITHUB_SHA:-local}" >>"$GITHUB_STEP_SUMMARY"
  jq -r '.[] | "- \(.action): \(.count)"' "$run_dir/summary.json" >>"$GITHUB_STEP_SUMMARY"
fi
if [[ "$operation" != plan ]]; then
  invoke apply apply -input=false -no-color -lock-timeout=120s "$run_dir/deployment.tfplan"
fi
printf 'Complete: %s for %s. Private files retained in %s\n' "$operation" "$environment" "$run_dir"
