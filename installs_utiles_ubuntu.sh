#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# Installation renforcée pour Ubuntu 26.04 LTS.
# Architectures : amd64 / arm64.
#
# Lancement :
#   chmod +x install-ubuntu.sh
#   ./install-ubuntu.sh
#
# Le script refuse de s'exécuter en root.
# Aucun autoremove automatique.
# Murmure est facultatif et nécessite une confirmation.
# Zoom et Cursor ne sont pas installés automatiquement.

log() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

warn() {
    printf '\nATTENTION : %s\n' "$*" >&2
}

die() {
    printf '\nERREUR : %s\n' "$*" >&2
    exit 1
}

confirm() {
    local answer
    read -r -p "$1 [o/N] " answer
    [[ "$answer" == "o" || "$answer" == "O" ]]
}

# 1. Contrôles préalables

[[ "$EUID" -ne 0 ]] ||
    die "Ne lance pas ce script avec sudo."

command -v sudo >/dev/null 2>&1 ||
    die "sudo est requis."

[[ -r /etc/os-release ]] ||
    die "Impossible de lire /etc/os-release."

# shellcheck disable=SC1091
. /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] ||
    die "Ce script est réservé à Ubuntu."

[[ "${VERSION_ID:-}" == "26.04" ]] ||
    die "Version détectée : ${VERSION_ID:-inconnue}. Ubuntu 26.04 est requis."

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64) ;;
    *) die "Architecture non prise en charge : $ARCH" ;;
esac

command -v dpkg-deb >/dev/null 2>&1 ||
    die "dpkg-deb est requis."

log "Environnement validé : Ubuntu ${VERSION_ID}, architecture ${ARCH}"

# Demander l'authentification sudo avant de commencer.
sudo -v

# Répertoire temporaire privé et nettoyage à la sortie.
TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

# 2. Mise à jour et outils nécessaires

log "Actualisation des index APT"

sudo apt-get update

log "Installation des outils de base"

sudo env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gpg \
    python3 \
    python3-venv \
    python3-pip \
    sqlite3 \
    cmake \
    clang \
    g++ \
    nodejs \
    npm \
    vim \
    vlc \
    ffmpeg \
    gpaste-2 \
    gnome-shell-extension-gpaste \
    gnome-boxes \
    easyeffects \
    pavucontrol

# ClamTk est facultatif : ne pas faire échouer toute
# l'installation si le paquet n'existe pas dans les dépôts.
if apt-cache show clamtk >/dev/null 2>&1; then
    log "Installation de ClamTk"
    sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y clamtk
else
    warn "ClamTk n'est pas disponible dans les dépôts configurés."
    warn "Aucun dépôt supplémentaire ne sera ajouté pour ce logiciel."
fi

# 3. Configuration du dépôt officiel Brave

log "Configuration du dépôt Brave"

sudo install -d -m 0755 /usr/share/keyrings

sudo curl -fsSL --proto '=https' \
    --tlsv1.2 \
    -o /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg

sudo chmod 0644 \
    /usr/share/keyrings/brave-browser-archive-keyring.gpg

sudo curl -fsSL --proto '=https' \
    --tlsv1.2 \
    -o /etc/apt/sources.list.d/brave-browser-release.sources \
    https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

# 4. Configuration du dépôt officiel VS Code

log "Configuration du dépôt Microsoft VS Code"

curl -fsSL --proto '=https' \
    --tlsv1.2 \
    https://packages.microsoft.com/keys/microsoft.asc \
    -o "$TMP_DIR/microsoft.asc"

gpg --batch --yes \
    --dearmor \
    --output "$TMP_DIR/microsoft.gpg" \
    "$TMP_DIR/microsoft.asc"

# Vérifier que le trousseau contient au moins une clé lisible.
gpg --show-keys "$TMP_DIR/microsoft.gpg" >/dev/null ||
    die "Impossible de lire la clé Microsoft téléchargée."

sudo install -m 0644 \
    "$TMP_DIR/microsoft.gpg" \
    /usr/share/keyrings/microsoft.gpg

# Restreindre le dépôt à l'architecture détectée.
sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: ${ARCH}
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF

# 5. Configuration du dépôt officiel Proton VPN

log "Téléchargement du paquet de configuration Proton VPN"

PROTON_FILE="protonvpn-stable-release_1.0.8_all.deb"
PROTON_URL="https://repo.protonvpn.com/debian/dists/stable/main/binary-all/${PROTON_FILE}"
PROTON_SHA256="0b14e71586b22e498eb20926c48c7b434b751149b1f2af9902ef1cfe6b03e180"

curl -fL --retry 3 --proto '=https' --tlsv1.2 \
    "$PROTON_URL" \
    -o "$TMP_DIR/$PROTON_FILE"

printf '%s  %s\n' \
    "$PROTON_SHA256" "$TMP_DIR/$PROTON_FILE" |
    sha256sum --check - ||
    die "Empreinte SHA-256 Proton VPN incorrecte."

log "Empreinte Proton VPN validée"

# Vérification de l'identité du paquet avant installation.
[[ "$(dpkg-deb -f "$TMP_DIR/$PROTON_FILE" Package)" \
    == "protonvpn-stable-release" ]] ||
    die "Le paquet téléchargé n'a pas le nom attendu."

[[ "$(dpkg-deb -f "$TMP_DIR/$PROTON_FILE" Architecture)" \
    == "all" ]] ||
    die "Architecture inattendue pour le paquet Proton VPN."

# Ce paquet installe la configuration du dépôt et ses clés.
# Son empreinte est vérifiée avant toute exécution de ses scripts.
sudo dpkg -i "$TMP_DIR/$PROTON_FILE"

# 6. Actualisation des index des dépôts configurés

log "Actualisation APT après ajout des dépôts tiers"

sudo apt-get update

# 7. Installation des applications depuis APT

log "Installation de Brave, VS Code et Proton VPN"

# APT vérifie les métadonnées signées des dépôts configurés.
# Ne pas utiliser --allow-unauthenticated ou des options
# qui désactivent les vérifications de signature.

sudo env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y \
    brave-browser \
    code \
    proton-vpn-gnome-desktop

# 8. Murmure : téléchargement, vérification et confirmation

if [[ "$ARCH" != "amd64" ]]; then
    warn "Murmure ne prend en charge que x86_64 selon son installateur."
    warn "Il ne sera pas installé automatiquement sur cette architecture."
else
    if confirm "Souhaites-tu télécharger et examiner Murmure ?"; then
        log "Récupération des métadonnées de la dernière publication GitHub"

        RELEASE_JSON="$TMP_DIR/murmure-release.json"

        curl -fL --retry 3 \
            --proto '=https' --tlsv1.2 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            -H 'User-Agent: ubuntu-install-script' \
            https://api.github.com/repos/Kieirra/murmure/releases/latest \
            -o "$RELEASE_JSON"

        # Récupérer le tag, l'URL officielle de l'asset et
        # le digest SHA-256 publié dans les métadonnées GitHub.
        RELEASE_INFO="$(
            python3 - "$RELEASE_JSON" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    release = json.load(f)

if release.get("draft") or release.get("prerelease"):
    raise SystemExit("La dernière publication n'est pas une version stable.")

tag = release.get("tag_name", "")

if not re.fullmatch(r"[A-Za-z0-9._-]+", tag):
    raise SystemExit("Tag de publication invalide.")

assets = [
    a for a in release.get("assets", [])
    if a.get("name") == "Murmure_amd64.deb"
]

if len(assets) != 1:
    raise SystemExit("Asset Murmure_amd64.deb absent ou ambigu.")

asset = assets[0]
digest = asset.get("digest", "")
url = asset.get("browser_download_url", "")

if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
    raise SystemExit("Digest SHA-256 absent ou invalide.")

expected_prefix = (
    "https://github.com/Kieirra/murmure/releases/download/"
    + tag + "/"
)

if not url.startswith(expected_prefix):
    raise SystemExit("URL de téléchargement inattendue.")

if not url.endswith("/Murmure_amd64.deb"):
    raise SystemExit("Nom de fichier inattendu.")

print(tag, digest.lower(), url, sep="\t")
PY
        )" || die "Impossible de valider les métadonnées Murmure."

        IFS=$'\t' read -r \
            MURMURE_VERSION MURMURE_DIGEST MURMURE_URL \
            <<< "$RELEASE_INFO"

        printf 'Version Murmure : %s\n' "$MURMURE_VERSION"
        printf 'Digest publié   : %s\n' "$MURMURE_DIGEST"

        MURMURE_DEB="$TMP_DIR/Murmure_amd64.deb"

        log "Téléchargement du paquet Murmure"

        curl -fL --retry 3 \
            --proto '=https' --tlsv1.2 \
            "$MURMURE_URL" \
            -o "$MURMURE_DEB"

        printf '%s  %s\n' \
            "${MURMURE_DIGEST#sha256:}" "$MURMURE_DEB" |
            sha256sum --check - ||
            die "Le digest Murmure ne correspond pas à celui de GitHub."

        [[ "$(dpkg-deb -f "$MURMURE_DEB" Package)" == "murmure" ]] ||
            die "Nom de paquet Murmure inattendu."

        [[ "$(dpkg-deb -f "$MURMURE_DEB" Architecture)" == "amd64" ]] ||
            die "Architecture du paquet Murmure inattendue."

        log "Extraction des scripts de maintenance pour inspection"

        MURMURE_CONTROL="$TMP_DIR/murmure-control"
        mkdir -m 700 "$MURMURE_CONTROL"

        dpkg-deb -e "$MURMURE_DEB" "$MURMURE_CONTROL"

        for script in preinst postinst prerm postrm config; do
            if [[ -f "$MURMURE_CONTROL/$script" ]]; then
                printf '\n--- Script de maintenance : %s ---\n' "$script"
                cat "$MURMURE_CONTROL/$script"
                printf '\n'
            fi
        done

        warn "Le digest provient de l'API GitHub : il ne constitue pas une signature indépendante."
        warn "Les scripts affichés ci-dessus doivent être examinés avant installation."

        if confirm "As-tu examiné les scripts et souhaites-tu installer Murmure ?"; then
            # Ne pas forcer la résolution des dépendances avec -y.
            # APT peut présenter les changements à confirmer.
            unset DEBIAN_FRONTEND
            sudo apt-get install "$MURMURE_DEB"
        else
            log "Murmure téléchargé et vérifié, mais non installé."
        fi
    else
        log "Installation de Murmure ignorée."
    fi
fi

# 9. Zoom et Cursor

log "Zoom et Cursor ne sont pas installés automatiquement"

cat <<'EOF'
Zoom :
  Télécharge le paquet Linux depuis le site officiel :
  https://zoom.us/download

Cursor :
  Télécharge le paquet adapté à ton architecture :
  https://cursor.com/download

Avant d'installer un paquet téléchargé manuellement,
vérifie son origine, son intégrité et les mécanismes
de signature disponibles auprès de l'éditeur.
EOF

# 10. Fin : aucune suppression automatique

log "Installation terminée"

cat <<'EOF'
Applications demandées installées si elles étaient disponibles :
Brave, VS Code, Proton VPN, VLC, SQLite, Python 3,
CMake, g++, Node.js, npm, Vim et éventuellement ClamTk.

Murmure a été traité séparément, avec contrôle du digest
et confirmation avant installation.

Aucun apt autoremove automatique n'a été exécuté.
Pour examiner les dépendances devenues inutiles :
  sudo apt autoremove

Lis attentivement la liste affichée avant de confirmer.
EOF