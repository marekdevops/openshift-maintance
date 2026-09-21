#!/usr/bin/env bash
# 02-setup-bastion.sh — przygotowanie bastionu: narzędzia, mini Quay, CA, poświadczenia.
#
# Użycie:
#   ./02-setup-bastion.sh -f config/mirror-vars.yaml -p pull-secret.txt [--update-tools] [--skip-registry]
#
# Opcje:
#   -f PLIK          plik zmiennych (mirror-vars.yaml)
#   -p PLIK          pull secret pobrany z https://console.redhat.com/openshift/downloads
#                    (wymagany przy pierwszym uruchomieniu, gdy nie ma jeszcze authFile)
#   --update-tools   pobierz ponownie oc, oc-mirror i opm, nawet jeśli są zainstalowane
#   --skip-registry  pomiń instalację mini Quay (np. używasz istniejącego rejestru)
#
# Uruchamiaj jako dedykowany użytkownik (np. "mirror"), NIE jako root.
# Kroki wymagające uprawnień (instalacja binariów, zaufanie CA, firewall) idą przez sudo.
#
# Skrypt jest idempotentny: można go uruchamiać wielokrotnie, pomija kroki już wykonane.
#
# Zmienne środowiskowe:
#   QUAY_INIT_PASSWORD  hasło użytkownika "init" mini Quay (min. 8 znaków); jeśli brak —
#                       generowane i zapisywane w <baseDir>/auth/quay-init-password (0600)

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

VARS_FILE=""
PULL_SECRET=""
UPDATE_TOOLS=0
SKIP_REGISTRY=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) VARS_FILE="$2"; shift 2 ;;
        -p) PULL_SECRET="$2"; shift 2 ;;
        --update-tools) UPDATE_TOOLS=1; shift ;;
        --skip-registry) SKIP_REGISTRY=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Nieznana opcja: $1"; usage 1 ;;
    esac
done
[[ -n "$VARS_FILE" ]] || usage 1
[[ $EUID -ne 0 ]] || die "Nie uruchamiaj jako root — użyj dedykowanego użytkownika z dostępem do sudo."

require_cmd python3 curl tar sudo
require_pyyaml

REG_HOST=$(cfg registry.host)                       # np. bastion.bank.local:8443
REG_FQDN="${REG_HOST%:*}"
QUAY_ROOT=$(expand_path "$(cfg registry.quayRoot "$HOME/quay-install")")
QUAY_STORAGE=$(expand_path "$(cfg registry.quayStorage "")")
SQLITE_STORAGE=$(expand_path "$(cfg registry.sqliteStorage "")")
CA_FILE=$(expand_path "$(cfg registry.caFile "$QUAY_ROOT/quay-rootCA/rootCA.pem")")
BASE_DIR=$(expand_path "$(cfg mirror.baseDir)")
AUTH_FILE=$(expand_path "$(cfg mirror.authFile "$BASE_DIR/auth/auth.json")")
CLIENT_CHANNEL=$(cfg tools.clientChannel "stable")

CLIENTS_URL="https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/${CLIENT_CHANNEL}"
MIRROR_REGISTRY_URL="https://mirror.openshift.com/pub/cgw/mirror-registry/latest"
RHEL_MAJOR=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
case "$(uname -m)" in                                 # nazewnictwo plików na mirror.openshift.com
    x86_64)  GOARCH=amd64 ;;
    aarch64) GOARCH=arm64 ;;
    *)       GOARCH="$(uname -m)" ;;
esac

umask 0022   # wymaganie oc-mirror
mkdir -p "$BASE_DIR"/{tools,auth,logs}
chmod 700 "$BASE_DIR/auth"

log_header "PRZYGOTOWANIE BASTIONU — ${REG_HOST}"

# ---------------------------------------------------------------------------
# 1. System i pakiety
# ---------------------------------------------------------------------------
log_section "1. System operacyjny i pakiety"
log_info "$(. /etc/os-release && echo "$PRETTY_NAME"), użytkownik: $(id -un)"
[[ "$(. /etc/os-release && echo "$ID")" == "rhel" ]] || log_warn "Mirror registry jest wspierany na RHEL 8/9 — ten system nie jest RHEL"

MISSING_PKGS=()
for pkg in podman openssl jq; do command -v "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg"); done
python3 -c 'import yaml' &>/dev/null || MISSING_PKGS+=(python3-pyyaml)
if (( ${#MISSING_PKGS[@]} > 0 )); then
    log_info "Instaluję: ${MISSING_PKGS[*]}"
    sudo dnf install -y "${MISSING_PKGS[@]}"
fi
log_ok "podman $(podman --version | awk '{print $3}'), jq, openssl, python3-pyyaml"

# Rootless Podman musi działać po wylogowaniu (usługi systemd --user mini Quay)
if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != "yes" ]]; then
    sudo loginctl enable-linger "$(id -un)"
    log_ok "Włączono linger dla $(id -un) (usługi Quay przetrwają wylogowanie)"
else
    log_ok "Linger już włączony"
fi

# ---------------------------------------------------------------------------
# 2. DNS
# ---------------------------------------------------------------------------
log_section "2. DNS"
if getent hosts "$REG_FQDN" >/dev/null; then
    log_ok "$REG_FQDN -> $(getent hosts "$REG_FQDN" | awk '{print $1}' | paste -sd' ' -)"
else
    die "$REG_FQDN nie rozwiązuje się w DNS. Mirror registry wymaga FQDN w DNS (nie /etc/hosts, nie IP)."
fi
log_info "Węzły klastra też muszą rozwiązywać $REG_FQDN i mieć dostęp do portu ${REG_HOST##*:}/tcp."

# ---------------------------------------------------------------------------
# 3. Narzędzia: oc, oc-mirror, opm (z weryfikacją sumy SHA256)
# ---------------------------------------------------------------------------
log_section "3. Narzędzia oc, oc-mirror, opm (${CLIENT_CHANNEL})"

download_verified() {   # download_verified <url_katalogu> <plik> <katalog_docelowy>
    local base="$1" file="$2" dest="$3" sum
    curl -fsSL -o "$dest/$file" "$base/$file"
    sum=$(curl -fsSL "$base/sha256sum.txt" | awk -v f="$file" '$2==f {print $1}')
    [[ -n "$sum" ]] || die "Brak sumy kontrolnej dla $file w $base/sha256sum.txt"
    echo "$sum  $dest/$file" | sha256sum -c --quiet - || die "Niezgodna suma SHA256: $file"
}

TOOLS_DIR="$BASE_DIR/tools"
if [[ $UPDATE_TOOLS -eq 1 ]] || ! command -v oc &>/dev/null; then
    download_verified "$CLIENTS_URL" "openshift-client-linux-${GOARCH}-rhel${RHEL_MAJOR}.tar.gz" "$TOOLS_DIR"
    tar -xzf "$TOOLS_DIR/openshift-client-linux-${GOARCH}-rhel${RHEL_MAJOR}.tar.gz" -C "$TOOLS_DIR" oc kubectl
    sudo install -m 0755 "$TOOLS_DIR/oc" "$TOOLS_DIR/kubectl" /usr/local/bin/
fi
log_ok "oc: $(oc version --client 2>/dev/null | head -1)"

if [[ $UPDATE_TOOLS -eq 1 ]] || ! command -v oc-mirror &>/dev/null; then
    download_verified "$CLIENTS_URL" "oc-mirror.rhel${RHEL_MAJOR}.tar.gz" "$TOOLS_DIR"
    tar -xzf "$TOOLS_DIR/oc-mirror.rhel${RHEL_MAJOR}.tar.gz" -C "$TOOLS_DIR" oc-mirror
    sudo install -m 0755 "$TOOLS_DIR/oc-mirror" /usr/local/bin/oc-mirror   # nazwy pliku nie zmieniać
fi
# opm — do podglądu zawartości katalogów operatorów (kanały, wersje)
if [[ $UPDATE_TOOLS -eq 1 ]] || ! command -v opm &>/dev/null; then
    download_verified "$CLIENTS_URL" "opm-linux-rhel${RHEL_MAJOR}.tar.gz" "$TOOLS_DIR"
    tar -xzf "$TOOLS_DIR/opm-linux-rhel${RHEL_MAJOR}.tar.gz" -C "$TOOLS_DIR"
    sudo install -m 0755 "$(find "$TOOLS_DIR" -maxdepth 1 -type f -name 'opm*' ! -name '*.tar.gz' | head -1)" /usr/local/bin/opm
fi
log_ok "opm: zainstalowany"
log_ok "oc-mirror: $(oc-mirror --v2 version 2>/dev/null | grep -oE 'GitVersion:"[^"]+"' | head -1 || echo zainstalowany)"

# ---------------------------------------------------------------------------
# 4. Mirror registry for Red Hat OpenShift (mini Quay w Podman)
# ---------------------------------------------------------------------------
log_section "4. Mirror registry (mini Quay)"

if [[ $SKIP_REGISTRY -eq 1 ]]; then
    log_info "Pominięto (--skip-registry)"
elif systemctl --user is-active --quiet quay-app 2>/dev/null; then
    log_ok "Mini Quay już działa (systemctl --user status quay-app)"
    log_info "Aktualizacja wersji rejestru: ./mirror-registry upgrade -v (patrz docs/INSTRUKCJA.md)"
else
    MR_DIR="$TOOLS_DIR/mirror-registry"
    mkdir -p "$MR_DIR"
    download_verified "$MIRROR_REGISTRY_URL" "mirror-registry-${GOARCH}.tar.gz" "$MR_DIR"
    tar -xzf "$MR_DIR/mirror-registry-${GOARCH}.tar.gz" -C "$MR_DIR"

    PASS_FILE="$BASE_DIR/auth/quay-init-password"
    if [[ -n "${QUAY_INIT_PASSWORD:-}" ]]; then
        printf '%s' "$QUAY_INIT_PASSWORD" >"$PASS_FILE"
    elif [[ ! -s "$PASS_FILE" ]]; then
        openssl rand -base64 24 | tr -d '/+=' | head -c 24 >"$PASS_FILE"
    fi
    chmod 600 "$PASS_FILE"

    INSTALL_ARGS=(install -v --quayHostname "$REG_HOST" --quayRoot "$QUAY_ROOT"
                  --initUser init --initPassword "$(cat "$PASS_FILE")")
    [[ -n "$QUAY_STORAGE" ]] && INSTALL_ARGS+=(--quayStorage "$QUAY_STORAGE")
    [[ -n "$SQLITE_STORAGE" ]] && INSTALL_ARGS+=(--sqliteStorage "$SQLITE_STORAGE")
    for d in "$QUAY_ROOT" "$QUAY_STORAGE" "$SQLITE_STORAGE"; do
        [[ -n "$d" ]] && { mkdir -p "$d" 2>/dev/null || sudo install -d -o "$(id -un)" -g "$(id -gn)" "$d"; }
    done

    log_info "Instaluję mini Quay (to potrwa kilka minut)..."
    (cd "$MR_DIR" && ./mirror-registry "${INSTALL_ARGS[@]}") | tee "$BASE_DIR/logs/mirror-registry-install-$(timestamp).log"
    log_ok "Mini Quay zainstalowany: https://${REG_HOST} (użytkownik: init, hasło: $PASS_FILE)"
fi

# ---------------------------------------------------------------------------
# 5. Zaufanie do CA rejestru i firewall
# ---------------------------------------------------------------------------
log_section "5. Certyfikat CA i firewall"

if [[ -f "$CA_FILE" ]]; then
    ANCHOR="/etc/pki/ca-trust/source/anchors/mirror-registry-${REG_FQDN}.pem"
    if ! sudo cmp -s "$CA_FILE" "$ANCHOR" 2>/dev/null; then
        sudo cp "$CA_FILE" "$ANCHOR"
        sudo update-ca-trust extract
        log_ok "CA rejestru dodane do zaufanych: $ANCHOR"
    else
        log_ok "CA rejestru już zaufane"
    fi
    log_info "Ważność certyfikatu CA: $(openssl x509 -in "$CA_FILE" -noout -enddate | cut -d= -f2)"
else
    log_warn "Brak pliku CA: $CA_FILE (sprawdź registry.caFile)"
fi

if systemctl is-active --quiet firewalld; then
    PORT="${REG_HOST##*:}"
    if ! sudo firewall-cmd --query-port="${PORT}/tcp" &>/dev/null; then
        sudo firewall-cmd --permanent --add-port="${PORT}/tcp"
        sudo firewall-cmd --reload
        log_ok "Otwarto port ${PORT}/tcp w firewalld"
    else
        log_ok "Port ${PORT}/tcp otwarty w firewalld"
    fi
fi

# ---------------------------------------------------------------------------
# 6. Plik poświadczeń dla oc-mirror (pull secret Red Hat + mini Quay)
# ---------------------------------------------------------------------------
log_section "6. Poświadczenia oc-mirror ($AUTH_FILE)"

if [[ ! -s "$AUTH_FILE" ]]; then
    [[ -n "$PULL_SECRET" ]] || die "Brak $AUTH_FILE — podaj pull secret z console.redhat.com: -p pull-secret.txt"
    jq . "$PULL_SECRET" >"$AUTH_FILE" || die "Plik $PULL_SECRET nie jest poprawnym JSON"
    chmod 600 "$AUTH_FILE"
fi
for reg in registry.redhat.io quay.io; do
    jq -e --arg r "$reg" '.auths[$r]' "$AUTH_FILE" &>/dev/null \
        && log_ok "Poświadczenia dla $reg" || log_error "Brak poświadczeń dla $reg w $AUTH_FILE"
done

if ! jq -e --arg r "$REG_HOST" '.auths[$r]' "$AUTH_FILE" &>/dev/null; then
    PASS_FILE="$BASE_DIR/auth/quay-init-password"
    [[ -s "$PASS_FILE" ]] || die "Brak hasła do rejestru ($PASS_FILE). Zaloguj się ręcznie: podman login --authfile $AUTH_FILE $REG_HOST"
    podman login --authfile "$AUTH_FILE" -u init --password-stdin "$REG_HOST" <"$PASS_FILE"
fi
log_ok "Poświadczenia dla $REG_HOST"

# ---------------------------------------------------------------------------
# 7. Weryfikacja
# ---------------------------------------------------------------------------
log_section "7. Weryfikacja"
if curl -fsS "https://${REG_HOST}/health/instance" >/dev/null; then
    log_ok "Rejestr odpowiada po HTTPS z zaufanym certyfikatem: https://${REG_HOST}/health/instance"
else
    log_error "Rejestr nie odpowiada lub certyfikat nie jest zaufany: https://${REG_HOST}/health/instance"
fi
AVAIL=$(df -BG --output=avail "$BASE_DIR" | tail -1 | tr -dc '0-9')
(( AVAIL >= 500 )) && log_ok "Wolne miejsce w $BASE_DIR: ${AVAIL} GB" \
                   || log_warn "Wolne miejsce w $BASE_DIR: ${AVAIL} GB (zalecane min. 500 GB)"
log_info "Hasło mini Quay przechowuj w sejfie haseł banku; plik $BASE_DIR/auth/ ma prawa 700."

log_header "GOTOWE — ostrzeżenia: ${WARNINGS}, błędy: ${ERRORS}"
echo "  Następny krok: bin/03-generate-imageset.py -f $VARS_FILE"
(( ERRORS == 0 )) || exit 2
