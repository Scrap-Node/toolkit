#!/usr/bin/env bash
# Brings a fresh Debian host to the point where a repository deployed with
# Docker Compose and sops can run: packages, sops, Docker, optionally
# Tailscale, then a clone of the repository owned by the invoking user.
# Idempotent: safe to re-run after a partial failure.
#
# Usage: REPO=git@github.com:<owner>/<repo>.git DEST=/opt/<repo> [TAILSCALE=1] debian.sh
set -euo pipefail

: "${REPO:?REPO requis, par exemple git@github.com:<owner>/<repo>.git}"
: "${DEST:?DEST requis, par exemple /opt/<repo>}"
TAILSCALE=${TAILSCALE:-0}

# Pinned like every other dependency: a moving "latest" would change what a
# rebuild installs without any line of this repository changing. Checksums
# from sops-v<version>.checksums.txt on the release page.
SOPS_VERSION=3.13.3
SOPS_SHA256_amd64=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
SOPS_SHA256_arm64=53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77

# git must run as the invoking user: the deploy key lives in their ~/.ssh, and
# the clone must belong to them.
[ "$(id -u)" -ne 0 ] || { echo "Lancer en utilisateur normal, pas en root." >&2; exit 1; }
command -v sudo >/dev/null || { echo "sudo requis" >&2; exit 1; }

# shellcheck source=/dev/null
. /etc/os-release
[ "${ID:-}" = debian ] || { echo "Debian uniquement (trouvé : ${ID:-inconnu})" >&2; exit 1; }
codename=$VERSION_CODENAME
arch=$(dpkg --print-architecture)

echo "== Paquets =="
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates git curl age gnupg make rsync

echo "== sops $SOPS_VERSION =="
if [ "$(sops --version --disable-version-check 2>/dev/null | awk '{print $2; exit}')" != "$SOPS_VERSION" ]; then
  case $arch in
    amd64) sum=$SOPS_SHA256_amd64 ;;
    arm64) sum=$SOPS_SHA256_arm64 ;;
    *) echo "Architecture non prise en charge : $arch" >&2; exit 1 ;;
  esac
  tmp=$(mktemp)
  curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${arch}" -o "$tmp"
  if ! echo "$sum  $tmp" | sha256sum -c --quiet -; then
    rm -f "$tmp"
    echo "Somme de contrôle de sops invalide : téléchargement refusé." >&2
    exit 1
  fi
  sudo install -m 0755 "$tmp" /usr/local/bin/sops
  rm -f "$tmp"
fi

echo "== Docker =="
# Docker's apt repository rather than the get.docker.com script, which Docker
# itself advises against on production hosts. Same packages, signed source.
if ! command -v docker >/dev/null; then
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $codename stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo usermod -aG docker "$USER"

if [ "$TAILSCALE" = 1 ]; then
  echo "== Tailscale =="
  if ! command -v tailscale >/dev/null; then
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/$codename.noarmor.gpg" \
      | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/$codename.tailscale-keyring.list" \
      | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq tailscale
  fi
fi

echo "== Dépôt =="
# Checked up front so the failure names the cause instead of surfacing as an
# opaque git error. Only SSH remotes need a key.
case $REPO in
  git@* | ssh://*)
    if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 \
         | grep -q 'successfully authenticated'; then
      echo "Accès SSH à GitHub refusé pour $USER." >&2
      echo "Générer une clé (ssh-keygen -t ed25519) et l'ajouter en deploy key du dépôt." >&2
      exit 1
    fi
    ;;
esac

if [ ! -d "$DEST" ]; then
  sudo mkdir -p "$DEST"
  sudo chown "$USER:$USER" "$DEST"
fi

if [ -d "$DEST/.git" ]; then
  git -C "$DEST" pull --ff-only
  git -C "$DEST" submodule update --init --recursive
else
  git clone --recurse-submodules "$REPO" "$DEST"
fi

next_tailscale=""
[ "$TAILSCALE" = 1 ] && next_tailscale="  - sudo tailscale up
"
cat <<NEXT

Reste à faire, à la main :
${next_tailscale}  - déposer la clé age dans ~/.config/sops/age/keys.txt
  - suivre le README de $DEST

Se déconnecter puis se reconnecter pour que le groupe docker prenne effet.
NEXT
