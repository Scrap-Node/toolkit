#!/usr/bin/env bash
# Encrypts or decrypts files with sops. The ciphertext lives next to its
# plaintext as <file>.sops, and is the only one of the two tracked by git.
#
# Usage: sops-files.sh encrypt|decrypt <plaintext path>...
#
# Paths whose source is missing are skipped, so one list can serve hosts that
# only hold part of the secrets.
set -euo pipefail

mode=${1:?usage : sops-files.sh encrypt|decrypt <fichier en clair>...}
shift

# sops picks the format from the extension, and reads *.sops as binary: a
# dotenv or YAML file would fail to decrypt. The format is therefore taken
# from the plaintext name and passed explicitly, both ways.
format_of() {
  case $1 in
    *.env)         echo dotenv ;;
    *.yaml | *.yml) echo yaml ;;
    *.json)        echo json ;;
    *.ini)         echo ini ;;
    *)             echo binary ;;
  esac
}

# Decrypted secrets are readable by their owner only.
umask 077

for plain in "$@"; do
  fmt=$(format_of "$plain")
  case $mode in
    decrypt) src="$plain.sops"; dst="$plain"; flag=-d; verb="déchiffré" ;;
    encrypt) src="$plain";      dst="$plain.sops"; flag=-e; verb="chiffré" ;;
    *) echo "mode inconnu : $mode (encrypt ou decrypt)" >&2; exit 2 ;;
  esac
  [ -f "$src" ] || continue

  # Written aside then renamed: a failed sops run must not leave a truncated
  # file where a working one was.
  tmp=$(mktemp "$dst.XXXXXX")
  if ! sops "$flag" --input-type "$fmt" --output-type "$fmt" "$src" > "$tmp"; then
    rm -f "$tmp"
    echo "échec sur $src" >&2
    exit 1
  fi
  mv "$tmp" "$dst"
  echo "$verb $plain"
done
