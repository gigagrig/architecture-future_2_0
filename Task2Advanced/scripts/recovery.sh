#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Preflight recovery encryption or encrypt Terraform diagnostics and emergency state.' \
    'Usage: bash recovery.sh --public-key FILE --output FILE.gpg [--check-only] [--logs-dir DIR] [--source DIR ...]' \
    'Options: -h, --help; --source may repeat; --logs-dir defaults to ./log.' \
    'Example: bash recovery.sh --public-key recovery.asc --output /secure/check.gpg --check-only' \
    'Example: bash recovery.sh --public-key recovery.asc --output /secure/recovery.tar.gz.gpg --source /secure/run --source ../terraform' \
    'The key file must contain exactly one public primary key and no private keys.' \
    'Output: encrypted archive of *.log, *.tfplan, *.tfstate* and summary.json; no plaintext archive.' \
    'Exit 0: success; nonzero: encryption/configuration error. Decrypt with: gpg --output recovery.tar.gz --decrypt FILE.gpg'
}
fail() { printf 'Error: %s\n' "$*"; exit 1; }
key_file='' output='' check_only=false logs_dir='./log'
sources=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check-only) check_only=true; shift ;;
    --public-key|--output|--source|--logs-dir)
      [[ $# -ge 2 ]] || fail "Missing value for $1"
      case "$1" in
        --public-key) key_file=$2 ;; --output) output=$2 ;;
        --source) sources+=("$2") ;; --logs-dir) logs_dir=$2 ;;
      esac
      shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ -r "$key_file" && -n "$output" ]] || fail 'Readable public key and output path are required.'
[[ ! -e "$output" ]] || fail "Output already exists: $output"
[[ "$check_only" == true || ${#sources[@]} -gt 0 ]] || fail 'At least one source directory is required.'
for tool in gpg tar find mktemp date; do command -v "$tool" >/dev/null || fail "Missing executable: $tool"; done
umask 077
mkdir -p -- "$logs_dir" "$(dirname -- "$output")"
work=$(mktemp -d "$logs_dir/recovery_XXXXXXXX")
work=$(cd -- "$work" && pwd)
printf 'Start recovery encryption. Created private working directory: %s\nOutput: %s\n' "$work" "$output"
mkdir -m 700 "$work/gnupg"
gpg_args=(--homedir "$work/gnupg" --batch --no-tty)
logfile="$work/gpg_$(date -u +%Y%m%d_%H%M%S)_recovery_$$.log"
printf 'Importing public key; log: %s\n' "$logfile"
gpg "${gpg_args[@]}" --import "$key_file" >"$logfile" 2>&1 || fail "Cannot import key; see $logfile"
key_list=$(gpg "${gpg_args[@]}" --with-colons --list-keys 2>>"$logfile")
secret_list=$(gpg "${gpg_args[@]}" --with-colons --list-secret-keys 2>>"$logfile")
[[ "$secret_list" != *'sec:'* ]] || fail 'Private recovery keys must never be supplied to CI.'
fingerprint='' count=0 need_fingerprint=false
while IFS=: read -r record _ _ _ _ _ _ _ _ value _; do
  if [[ "$record" == pub ]]; then count=$((count + 1)); need_fingerprint=true; fi
  if [[ "$record" == fpr && "$need_fingerprint" == true ]]; then fingerprint=$value; need_fingerprint=false; fi
done <<<"$key_list"
[[ "$count" == 1 && -n "$fingerprint" ]] || fail 'Exactly one public primary key is required.'
encrypt=(gpg "${gpg_args[@]}" --trust-model always --encrypt --recipient "$fingerprint" --output "$output")
if [[ "$check_only" == true ]]; then
  printf 'Terraform recovery encryption preflight\n' | "${encrypt[@]}" >>"$logfile" 2>&1 || fail "Encryption failed; see $logfile"
else
  manifest="$work/files.list"
  : >"$manifest"
  for source in "${sources[@]}"; do
    [[ -d "$source" ]] || fail "Source directory does not exist: $source"
    source=$(cd -- "$source" && pwd)
    printf 'Collecting recovery files from %s\n' "$source"
    # State can appear in the Terraform root or its isolated backend directory.
    find "$source" -type f \( -name '*.log' -o -name '*.tfplan' -o -name '*.tfstate' -o -name '*.tfstate.*' -o -name 'summary.json' \) -printf '%P\0' |
      while IFS= read -r -d '' relative; do printf '%s\0' "${source#/}/$relative"; done >>"$manifest"
  done
  [[ -s "$manifest" ]] || fail 'No recovery files found.'
  printf 'Encrypting archive; tar/gpg log: %s\n' "$logfile"
  tar -czf - -C / --null --verbatim-files-from -T "$manifest" 2>>"$logfile" |
    "${encrypt[@]}" >>"$logfile" 2>&1 || fail "Recovery export failed; see $logfile"
fi
printf 'Complete: encrypted recovery file created at %s\n' "$output"
