#!/usr/bin/env bash
# Refuses keys, tokens, private keys, env files and databases in git.
#   scripts/check-secrets.sh          checks what is staged (used by the pre-commit hook)
#   scripts/check-secrets.sh --all    checks every tracked file (used in CI)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [[ "${1:-}" == "--all" ]]; then
  files=$(git ls-files)
  content() { cat -- "$1" 2>/dev/null || true; }
else
  files=$(git diff --cached --name-only --diff-filter=ACMR)
  content() { git show ":$1" 2>/dev/null || true; }
fi

fail=0
# Files that must never be committed, whatever they contain.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.env.example) ;;
    .env|*/.env|.env.*|*/.env.*|*.db|*.db-*|*.sqlite|*.pem|*.key|*.p8|*.p12|*.mobileprovision|*.cer)
      echo "BLOCKED file: $f"; fail=1 ;;
  esac
done <<< "$files"

# Known key formats, private keys, and assignments of long values to secret-named variables.
pattern='shpat_[0-9a-fA-F]{16,}|shpss_[0-9a-fA-F]{16,}|shpca_[0-9a-fA-F]{16,}|sk-ant-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abpr]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(TOKEN|SECRET|PASSWORD|API_KEY|ACCESS_KEY)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_./+=-]{20,}'
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in *package-lock.json|*.png|*.ico|*.jpg|*.pdf) continue ;; esac
  if hits=$(content "$f" | grep -nEI "$pattern"); then
    echo "BLOCKED possible secret in $f:"; echo "$hits" | cut -d: -f1 | sed 's/^/  line /'; fail=1
  fi
done <<< "$files"

if [[ $fail -ne 0 ]]; then
  echo "Secrets go in Railway variables or a local .env, never in git. Nothing was committed."
  exit 1
fi
echo "check-secrets: clean"
