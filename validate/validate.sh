#!/usr/bin/env bash
# Shared repository checks: Compose files, YAML and JSON syntax, secrets
# hygiene, shell lint and forbidden patterns. Used by CI, the pre-push hook and
# `make validate` of every consuming repository, so a rule is fixed once.
#
# Usage: validate.sh [repository root]
#
# The repository describes its layout in <root>/validate.conf, a bash file
# sourced after the defaults below, with globs expanded from the root.
# Must stay compatible with bash 3.2, the one macOS ships.
set -euo pipefail

root=${1:-$(git rev-parse --show-toplevel)}
cd "$root"

shopt -s nullglob

# Defaults: a repository without validate.conf still gets the generic checks.
COMPOSE_DIRS=(compose/*/)
YAML_FILES=(.github/workflows/*.yml .github/workflows/*.yaml)
JSON_FILES=()
SHELL_FILES=(scripts/*.sh .githooks/*)
FORBIDDEN_PATTERNS_FILE=.forbidden-patterns

if [ -f validate.conf ]; then
  # shellcheck source=/dev/null
  . ./validate.conf
fi

fail=0
pass() { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

yaml_parser=""
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  yaml_parser=python
elif command -v ruby >/dev/null; then
  yaml_parser=ruby
fi

parse_yaml() {
  case $yaml_parser in
    # The parser error says where; the Python traceback around it does not.
    python) python3 -c '
import sys, yaml
try:
    yaml.safe_load(open(sys.argv[1]))
except yaml.YAMLError as e:
    sys.exit(str(e))' "$1" ;;
    ruby)   ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$1" ;;
  esac
}

compose_file() {
  local f
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [ -f "$1/$f" ] && { echo "$1/$f"; return 0; }
  done
  return 1
}

echo "Compose"
if [ ${#COMPOSE_DIRS[@]} -eq 0 ]; then
  warn "aucun dossier compose"
else
  has_compose=0
  docker compose version >/dev/null 2>&1 && has_compose=1
  [ "$has_compose" -eq 1 ] || warn "docker compose absent : validation limitée à la syntaxe YAML"

  for d in "${COMPOSE_DIRS[@]}"; do
    d=${d%/}
    if ! f=$(compose_file "$d"); then
      bad "$d : aucun fichier compose"
      continue
    fi
    if [ "$has_compose" -eq 1 ]; then
      args=(-f "$f")
      # .env.example must list every variable a stack references, so the
      # config resolves with no real secret present.
      [ -f "$d/.env.example" ] && args+=(--env-file "$d/.env.example")
      if ! out=$(docker compose "${args[@]}" config 2>&1); then
        bad "$d"
      # An undefined variable is only a warning to Compose, which still exits
      # 0. Left unchecked, a stack would silently start with an empty value.
      elif grep -q 'variable is not set' <<<"$out"; then
        bad "$d : variable absente de .env.example"
      else
        pass "$d"
      fi
    elif [ -z "$yaml_parser" ]; then
      warn "$f : ni python3-yaml ni ruby"
    elif parse_yaml "$f"; then
      pass "$f"
    else
      bad "$f"
    fi
  done
fi

echo "YAML"
if [ ${#YAML_FILES[@]} -eq 0 ]; then
  warn "aucun fichier YAML"
elif [ -z "$yaml_parser" ]; then
  warn "ni python3-yaml ni ruby : YAML non vérifié"
else
  for f in "${YAML_FILES[@]}"; do
    if parse_yaml "$f"; then pass "$f"; else bad "$f"; fi
  done
fi

echo "JSON"
if [ ${#JSON_FILES[@]} -eq 0 ]; then
  warn "aucun fichier JSON"
elif ! command -v python3 >/dev/null; then
  warn "python3 absent : JSON non vérifié"
else
  for f in "${JSON_FILES[@]}"; do
    if python3 -c 'import sys,json; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
      pass "$f"
    else
      bad "$f"
    fi
  done
fi

echo "Secrets"
if git ls-files | grep -qE '(^|/)\.env$'; then
  bad "un .env en clair est suivi par git"
else
  pass "aucun .env en clair suivi"
fi
git ls-files '*.sops' > "$tmp/sops"
while IFS= read -r f; do
  # A file that failed to encrypt looks like ordinary plaintext: only the sops
  # metadata tells them apart. dotenv carries sops_* keys, YAML a top-level
  # sops: key, JSON and binary a "sops" object.
  if grep -qE '^sops_|^sops:|"sops"[[:space:]]*:' "$f"; then
    pass "$f chiffré"
  else
    bad "$f N'EST PAS chiffré"
  fi
  # The plaintext lives next to its ciphertext and must never be tracked.
  if git ls-files --error-unmatch "${f%.sops}" >/dev/null 2>&1; then
    bad "${f%.sops} : version en clair suivie par git"
  fi
done < "$tmp/sops"

echo "Shell"
if [ ${#SHELL_FILES[@]} -eq 0 ]; then
  warn "aucun script"
elif ! command -v shellcheck >/dev/null; then
  warn "shellcheck absent"
else
  for f in "${SHELL_FILES[@]}"; do
    [ -f "$f" ] || continue
    if shellcheck -S warning "$f"; then pass "$f"; else bad "$f"; fi
  done
fi

echo "Motifs interdits"
if [ ! -f "$FORBIDDEN_PATTERNS_FILE" ]; then
  warn "pas de $FORBIDDEN_PATTERNS_FILE"
else
  grep -vE '^[[:space:]]*(#|$)' "$FORBIDDEN_PATTERNS_FILE" > "$tmp/patterns" || true
  if [ ! -s "$tmp/patterns" ]; then
    warn "$FORBIDDEN_PATTERNS_FILE est vide"
  # git grep only sees tracked files and does not descend into submodules, so
  # a consumer never scans the toolkit it embeds.
  elif hits=$(git grep -nIE -f "$tmp/patterns" -- . ":(exclude)$FORBIDDEN_PATTERNS_FILE"); then
    bad "motif interdit trouvé :"
    printf '%s\n' "$hits" | head -20 | sed 's/^/          /'
  else
    pass "aucun motif de $FORBIDDEN_PATTERNS_FILE"
  fi
fi

echo
[ "$fail" -eq 0 ] && echo "Validation OK" || echo "Validation en échec"
exit "$fail"
