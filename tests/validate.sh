#!/usr/bin/env bash
# Runs validate/validate.sh on throwaway repositories: one carrying a defect
# for every check, which must fail on each of them, and a clean one, which
# must pass. Checks whose tool is missing here are not expected to fail.
set -euo pipefail

validate="$(cd "$(dirname "$0")/.." && pwd)/validate/validate.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
ok() { printf '  OK    %s\n' "$1"; }
ko() { printf '  FAIL  %s\n' "$1"; fail=1; }

# Runs the validation in $1, keeping its exit code and its uncoloured output.
run() {
  status=0
  out=$(cd "$1" && "$validate" 2>&1) || status=$?
  out=$(sed $'s/\033\\[[0-9;]*m//g' <<<"$out")
}
expect() {
  if grep -qF -- "$2" <<<"$out"; then ok "$1"; else ko "$1"; printf '%s\n' "$out" | sed 's/^/        /'; fi
}

has_compose=0; docker compose version >/dev/null 2>&1 && has_compose=1
has_yaml=0; { python3 -c 'import yaml' 2>/dev/null || command -v ruby >/dev/null; } && has_yaml=1
has_json=0; command -v python3 >/dev/null && has_json=1
has_shellcheck=0; command -v shellcheck >/dev/null && has_shellcheck=1

new_repo() {
  mkdir -p "$1/compose/app"
  git -C "$1" init -q
}

echo "Un défaut par contrôle"
bad="$work/bad"
new_repo "$bad"
# shellcheck disable=SC2016 # literal ${MISSING}, for Compose to interpolate
printf 'services:\n  app:\n    image: nginx:1.27\n    environment:\n      - X=${MISSING}\n' > "$bad/compose/app/docker-compose.yml"
printf 'A=1\n' > "$bad/.env"
printf 'TOKEN=en-clair\n' > "$bad/compose/app/.env.sops"
printf 'k: v\n' > "$bad/compose/app/secrets.yaml"
printf 'k: ENC[x]\nsops:\n  version: 3.13.3\n' > "$bad/compose/app/secrets.yaml.sops"
printf 'a: [\n' > "$bad/bad.yaml"
printf '{"a": \n' > "$bad/bad.json"
printf 'echo $1\n' > "$bad/script.sh"
printf 'cible=jeton-interdit-42\n' > "$bad/notes.txt"
printf '# commentaire ignoré\njeton-interdit-[0-9]+\n' > "$bad/.forbidden-patterns"
printf 'YAML_FILES=(bad.yaml)\nJSON_FILES=(bad.json)\nSHELL_FILES=(script.sh)\n' > "$bad/validate.conf"
git -C "$bad" add -A
run "$bad"
[ "$status" -ne 0 ] && ok "code de retour en échec" || ko "code de retour en échec"
[ "$has_compose" -eq 1 ] && expect "variable Compose absente de .env.example" "FAIL  compose/app : variable absente de .env.example"
[ "$has_yaml" -eq 1 ] && expect "YAML invalide" "FAIL  bad.yaml"
[ "$has_json" -eq 1 ] && expect "JSON invalide" "FAIL  bad.json"
expect ".env en clair suivi" "FAIL  un .env en clair est suivi par git"
expect ".sops non chiffré" "FAIL  compose/app/.env.sops N'EST PAS chiffré"
expect "YAML chiffré reconnu" "OK    compose/app/secrets.yaml.sops chiffré"
expect "version en clair suivie" "FAIL  compose/app/secrets.yaml : version en clair suivie par git"
[ "$has_shellcheck" -eq 1 ] && expect "script refusé par shellcheck" "FAIL  script.sh"
expect "motif interdit" "notes.txt:1:cible=jeton-interdit-42"

echo "Dépôt propre"
good="$work/good"
new_repo "$good"
# shellcheck disable=SC2016 # literal ${TOKEN}, for Compose to interpolate
printf 'services:\n  app:\n    image: nginx:1.27\n    environment:\n      - X=${TOKEN}\n' > "$good/compose/app/docker-compose.yml"
printf 'TOKEN=\n' > "$good/compose/app/.env.example"
printf 'TOKEN=ENC[x]\nsops_version=3.13.3\n' > "$good/compose/app/.env.sops"
printf '{"k": "ENC[x]", "sops": {"version": "3.13.3"}}\n' > "$good/compose/app/conf.json.sops"
printf 'a: [1]\n' > "$good/ok.yaml"
printf '{"a": 1}\n' > "$good/ok.json"
printf '#!/usr/bin/env bash\necho "$1"\n' > "$good/script.sh"
printf 'host=example.org\n' > "$good/notes.txt"
printf 'jeton-interdit-[0-9]+\n' > "$good/.forbidden-patterns"
printf 'YAML_FILES=(ok.yaml)\nJSON_FILES=(ok.json)\nSHELL_FILES=(script.sh)\n' > "$good/validate.conf"
git -C "$good" add -A
run "$good"
[ "$status" -eq 0 ] && ok "validation en succès" || { ko "validation en succès"; printf '%s\n' "$out" | sed 's/^/        /'; }
expect "dotenv chiffré reconnu" "OK    compose/app/.env.sops chiffré"
expect "JSON chiffré reconnu" "OK    compose/app/conf.json.sops chiffré"

exit "$fail"
