#!/usr/bin/env bash
# Round trip through sops/sops-files.sh with a throwaway age key: dotenv, YAML
# and JSON, permissions of the decrypted files, and a failed decryption that
# must leave the existing plaintext untouched. Needs sops and age.
set -euo pipefail

sops_files="$(cd "$(dirname "$0")/.." && pwd)/sops/sops-files.sh"
for tool in sops age-keygen jq; do
  command -v "$tool" >/dev/null || { echo "  SKIP  $tool absent"; exit 0; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

fail=0
ok() { printf '  OK    %s\n' "$1"; }
ko() { printf '  FAIL  %s\n' "$1"; fail=1; }

age-keygen -o key.txt 2>/dev/null
export SOPS_AGE_KEY_FILE="$work/key.txt"
printf 'creation_rules:\n  - age: %s\n' "$(age-keygen -y key.txt)" > .sops.yaml

mkdir c
printf 'TOKEN=abc\nURL=https://example.org/?a=1&b=2\n' > c/.env
printf 'k: secret\nnombre: 1\n' > c/secrets.yaml
printf '{"k": "secret", "n": 1}\n' > c/conf.json
for f in c/.env c/secrets.yaml c/conf.json; do cp "$f" "$f.orig"; done

echo "Chiffrement"
"$sops_files" encrypt c/.env c/secrets.yaml c/conf.json c/absent.env >/dev/null
for f in c/.env c/secrets.yaml c/conf.json; do
  if [ -f "$f.sops" ] && ! grep -q secret "$f.sops" && ! grep -q TOKEN=abc "$f.sops"; then
    ok "$f.sops chiffré"
  else
    ko "$f.sops chiffré"
  fi
done
[ -e c/absent.env.sops ] && ko "source absente ignorée" || ok "source absente ignorée"

echo "Déchiffrement"
rm c/.env c/secrets.yaml c/conf.json
"$sops_files" decrypt c/.env c/secrets.yaml c/conf.json >/dev/null
cmp -s c/.env c/.env.orig && ok "dotenv identique" || ko "dotenv identique"
cmp -s c/secrets.yaml c/secrets.yaml.orig && ok "YAML identique" || ko "YAML identique"
[ "$(jq -S . c/conf.json)" = "$(jq -S . c/conf.json.orig)" ] && ok "JSON identique" || ko "JSON identique"
case $(ls -l c/.env) in
  -rw-------*) ok "droits 600" ;;
  *) ko "droits 600" ;;
esac

echo "Échec de déchiffrement"
if SOPS_AGE_KEY_FILE="$work/absente.txt" "$sops_files" decrypt c/.env >/dev/null 2>&1; then
  ko "échec signalé"
else
  ok "échec signalé"
fi
cmp -s c/.env c/.env.orig && ok "fichier existant intact" || ko "fichier existant intact"
leftovers=$(find c -name '*.??????' ! -name '*.orig' ! -name '*.sops' ! -name 'conf.json' ! -name 'secrets.yaml')
[ -z "$leftovers" ] && ok "aucun fichier temporaire laissé" || ko "aucun fichier temporaire laissé : $leftovers"

exit "$fail"
