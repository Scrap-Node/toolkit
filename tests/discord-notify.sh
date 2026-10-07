#!/usr/bin/env bash
# Checks the embed built by actions/discord-notify without sending anything:
# the defaults, and that oversized input stays within Discord's limits.
set -euo pipefail
cd "$(dirname "$0")/.."

notify=actions/discord-notify/notify.sh
fail=0
check() {
  if jq -e "$2" >/dev/null <<<"$payload"; then
    printf '  OK    %s\n' "$1"
  else
    printf '  FAIL  %s\n' "$1"
    fail=1
  fi
}

export DRY_RUN=true GITHUB_REPOSITORY=owner/repo GITHUB_REF_NAME=main \
  GITHUB_SHA=0123456789abcdef GITHUB_EVENT_NAME=push GITHUB_RUN_ID=42 GITHUB_WORKFLOW=CI

echo "Valeurs par défaut"
payload=$(STATUS=success "$notify")
check "couleur verte"            '.embeds[0].color == 3066993'
check "titre du workflow"        '.embeds[0].title == "Réussite — CI"'
check "lien vers l'exécution"    '.embeds[0].url == "https://github.com/owner/repo/actions/runs/42"'
check "commit court"             '.embeds[0].fields[] | select(.name == "Commit") | .value == "01234567"'
check "pas de description vide"  '.embeds[0] | has("description") | not'

echo "Limites de Discord"
# Over every Discord limit, yet under the 128 KiB Linux allows for a single
# environment variable, which is how the action passes its inputs.
long=$(head -c 9000 /dev/zero | tr '\0' 'x')
value=$(head -c 2000 /dev/zero | tr '\0' 'y')
fields=$(jq -n --arg v "$value" '[range(30) | {name: "champ \(.)", value: $v}]')
payload=$(STATUS=failure TITLE="$long" DESCRIPTION="$long" FIELDS="$fields" "$notify")
check "titre ≤ 256"              '.embeds[0].title | length <= 256'
check "25 champs au plus"        '.embeds[0].fields | length <= 25'
check "valeurs ≤ 1024"           'all(.embeds[0].fields[]; .value | length <= 1024)'
check "description ≤ 4096"       '(.embeds[0].description // "") | length <= 4096'
check "embed entier ≤ 6000"      '.embeds[0] | (.title | length) + ((.description // "") | length)
                                    + ([.fields[] | (.name | length) + (.value | length)] | add) <= 6000'
check "champs par défaut gardés" '[.embeds[0].fields[].name] | index("Commit") != null'

payload=$(STATUS=failure DESCRIPTION="$long" "$notify")
check "description seule tronquée à 4096" '.embeds[0].description | length == 4096'

echo "Entrées invalides"
if STATUS=success FIELDS='{"pas":"un tableau"}' "$notify" >/dev/null 2>&1; then
  printf '  FAIL  %s\n' "fields non tableau refusé"; fail=1
else
  printf '  OK    %s\n' "fields non tableau refusé"
fi

exit "$fail"
