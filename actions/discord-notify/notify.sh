#!/usr/bin/env bash
# Builds a Discord embed from the workflow context and posts it to a webhook.
#
# Environment: STATUS (required), WEBHOOK_URL (required unless DRY_RUN=true),
# TITLE, DESCRIPTION, FIELDS (JSON array), LINK, DRY_RUN, plus the GITHUB_*
# variables every Actions job provides. Needs curl and jq.
set -euo pipefail

: "${STATUS:?STATUS requis}"
FIELDS=${FIELDS:-[]}

case $STATUS in
  success)   color=3066993;  label="Réussite" ;;   # 0x2ECC71
  failure)   color=15158332; label="Échec" ;;      # 0xE74C3C
  cancelled) color=9807270;  label="Annulé" ;;     # 0x95A5A6
  skipped)   color=9807270;  label="Ignoré" ;;
  *)         color=9807270;  label=$STATUS ;;
esac

if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$FIELDS"; then
  echo "fields doit être un tableau JSON" >&2
  exit 1
fi

sha=${GITHUB_SHA:-}
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

payload=$(jq -n \
  --arg label "$label" \
  --arg title "${TITLE:-${GITHUB_WORKFLOW:-Workflow}}" \
  --arg desc "${DESCRIPTION:-}" \
  --arg url "${LINK:-$run_url}" \
  --argjson color "$color" \
  --argjson extra "$FIELDS" \
  --arg repo "${GITHUB_REPOSITORY:-}" \
  --arg ref "${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}" \
  --arg sha "${sha:0:8}" \
  --arg event "${GITHUB_EVENT_NAME:-}" '
  # Discord limits: title 256, description 4096, 25 fields of 256 (name) and
  # 1024 (value), and 6000 characters for the whole embed. Over any of them,
  # the message is rejected rather than truncated, so truncation happens here.
  def cut($n): if length > $n then .[0:([$n - 1, 0] | max)] + "…" else . end;

  ("\($label) — \($title)" | cut(256)) as $t
  | ([ {name: "Dépôt",     value: $repo,  inline: true},
       {name: "Branche",   value: $ref,   inline: true},
       {name: "Commit",    value: $sha,   inline: true},
       {name: "Événement", value: $event, inline: true} ] + $extra
     | map({name: (.name | tostring | cut(256)),
            value: (.value | tostring | cut(1024)),
            inline: (.inline // false)})
     | map(select(.name != "" and .value != ""))
     | .[0:25]) as $candidates
  # Fields are kept in order while they fit, so the default ones always do;
  # the description gets whatever room is left.
  | (reduce $candidates[] as $x ({fields: [], room: (6000 - ($t | length))};
      (($x.name | length) + ($x.value | length)) as $n
      | if $n <= .room then .fields += [$x] | .room -= $n else . end)) as $fit
  | $fit.room as $room
  | {embeds: [
      {title: $t, url: $url, color: $color, fields: $fit.fields}
      + (if $desc == "" or $room == 0 then {} else {description: ($desc | cut([$room, 4096] | min))} end)
    ]}')

if [ "${DRY_RUN:-false}" = true ]; then
  printf '%s\n' "$payload"
  exit 0
fi

: "${WEBHOOK_URL:?WEBHOOK_URL requis}"
echo "::add-mask::$WEBHOOK_URL"

resp=$(mktemp)
trap 'rm -f "$resp"' EXIT

# Discord answers 429 with the wait it expects, in seconds, under retry_after.
for _ in 1 2 3; do
  code=$(curl -sS -o "$resp" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary @- "$WEBHOOK_URL" <<<"$payload")
  case $code in
    2??) exit 0 ;;
    429) sleep "$(jq -r '.retry_after // 1' "$resp")" ;;
    *)   echo "Discord a répondu $code : $(head -c 500 "$resp")" >&2; exit 1 ;;
  esac
done

echo "Discord limite toujours le débit après 3 essais." >&2
exit 1
