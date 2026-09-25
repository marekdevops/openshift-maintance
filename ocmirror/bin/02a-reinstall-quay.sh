#!/usr/bin/env bash
# 02a-reinstall-quay.sh — czysta (re)instalacja mini Quay (mirror registry for Red Hat OpenShift) jako root.
#
# Użycie:
#   sudo ./02a-reinstall-quay.sh -f config/mirror-vars.yaml -p pull-secret.txt [opcje]
#
# Opcje:
#   -f PLIK            plik zmiennych (registry.*, mirror.baseDir, mirror.authFile)
#   -p PLIK            pull secret z https://console.redhat.com/openshift/downloads
#   --plan             tylko pokaż, co zostanie usunięte i zainstalowane (nic nie zmienia)
#   --tarball PLIK     użyj lokalnego mirror-registry-amd64.tar.gz zamiast pobierać
#   --ssl-cert PLIK    certyfikat z PKI banku (razem z --ssl-key i --ssl-ca)
#   --ssl-key PLIK     klucz prywatny do certyfikatu
#   --ssl-ca PLIK      łańcuch CA, którym podpisano --ssl-cert (trafi do zaufanych i do registry.caFile)
#   --temp-ssh-root    jeśli sshd blokuje root@localhost, dopuść go TYLKO z 127.0.0.1/::1 na czas
#                      instalacji (plik w /etc/ssh/sshd_config.d/, usuwany automatycznie)
#   --yes              nie pytaj o potwierdzenie usunięcia (automatyzacja)
#
# Co robi:
#   1. Sprawdza wymagania (root, DNS, sshd, pull secret, miejsce)
#   2. Wykrywa istniejący Quay: kontenery, pod, usługi systemd, wolumeny, katalogi, zajęty port
#   3. Robi kopię konfiguracji i CA starej instalacji (/root/quay-backup-<data>.tgz)
#   4. Usuwa starą instalację (w tym zmirrorowane obrazy!)
#   5. Instaluje mini Quay od zera: nowe hasło użytkownika init, zapis do pliku (0600)
#   6. CA rejestru: zaufanie systemowe, /etc/containers/certs.d, kopia czytelna bez sudo
#   7. Otwiera port w firewalld
#   8. Buduje NOWY auth.json (pull secret Red Hat + init@Quay) i sprawdza logowanie do każdego rejestru
#   9. Weryfikuje działanie i wypisuje sekcję registry: do mirror-vars.yaml
#
# Pliki dla użytkownika uruchamiającego sudo (SUDO_USER) są zapisywane z jego właścicielem,
# aby dalsze skrypty (03, 04, 05) działały bez sudo.
# Kod wyjścia: 0 = OK, 2 = błąd

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

VARS_FILE=""
PULL_SECRET=""
PLAN_ONLY=0
TARBALL=""
SSL_CERT=""
SSL_KEY=""
SSL_CA=""
TEMP_SSH_ROOT=0
ASSUME_YES=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) VARS_FILE="$2"; shift 2 ;;
        -p) PULL_SECRET="$2"; shift 2 ;;
        --plan) PLAN_ONLY=1; shift ;;
        --tarball) TARBALL="$2"; shift 2 ;;
        --ssl-cert) SSL_CERT="$2"; shift 2 ;;
        --ssl-key) SSL_KEY="$2"; shift 2 ;;
        --ssl-ca) SSL_CA="$2"; shift 2 ;;
        --temp-ssh-root) TEMP_SSH_ROOT=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Nieznana opcja: $1"; usage 1 ;;
    esac
done
[[ -n "$VARS_FILE" ]] || usage 1
[[ $EUID -eq 0 ]] || die "Uruchom przez sudo: sudo $0 $*"
[[ $PLAN_ONLY -eq 1 || -n "$PULL_SECRET" ]] || die "Podaj pull secret Red Hat: -p pull-secret.txt"
if [[ -n "$SSL_CERT$SSL_KEY$SSL_CA" && ( -z "$SSL_CERT" || -z "$SSL_KEY" || -z "$SSL_CA" ) ]]; then
    die "Własny certyfikat wymaga wszystkich trzech opcji: --ssl-cert, --ssl-key, --ssl-ca"
fi

# Instalator mirror-registry używa $HOME/.ssh/quay_installer i łączy się jako $USER@localhost
export HOME=/root USER=root
umask 0022

require_cmd podman jq openssl curl tar python3 ssh ssh-keygen sshd systemctl
require_pyyaml

OWNER="${SUDO_USER:-root}"
OWNER_GROUP=$(id -gn "$OWNER")

REG_HOST=$(cfg registry.host)
REG_FQDN="${REG_HOST%%:*}"
if [[ "$REG_HOST" == *:* ]]; then REG_PORT="${REG_HOST##*:}"; else REG_PORT=443; fi
QUAY_ROOT=$(expand_path "$(cfg registry.quayRoot "/root/quay-install")")
QUAY_STORAGE=$(expand_path "$(cfg registry.quayStorage "")")
SQLITE_STORAGE=$(expand_path "$(cfg registry.sqliteStorage "")")
VARS_CA=$(cfg registry.caFile "")
BASE_DIR=$(expand_path "$(cfg mirror.baseDir)")
AUTH_FILE=$(expand_path "$(cfg mirror.authFile "$BASE_DIR/auth/auth.json")")
AUTH_DIR=$(dirname "$AUTH_FILE")
PASS_FILE="$AUTH_DIR/quay-init-password"
CA_EXPORT="$AUTH_DIR/quay-rootCA.pem"
LOG_DIR="$BASE_DIR/logs"
MR_URL="https://mirror.openshift.com/pub/cgw/mirror-registry/latest"
case "$(uname -m)" in x86_64) GOARCH=amd64 ;; aarch64) GOARCH=arm64 ;; *) GOARCH="$(uname -m)" ;; esac

TMP_DIR=$(mktemp -d)
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-ocmirror-quay-install.conf"
cleanup() {
    rm -rf "$TMP_DIR"
    if [[ -f "$SSHD_DROPIN" ]]; then
        rm -f "$SSHD_DROPIN"
        systemctl reload sshd 2>/dev/null || true
        echo "  [INFO] Usunięto tymczasowe ustawienie sshd ($SSHD_DROPIN)"
    fi
}
trap cleanup EXIT

# Ścieżki, których skrypt nigdy nie usunie w całości
is_protected_path() {
    local p="${1%/}"
    [[ -z "$p" || "$p" != /* ]] && return 0
    case "$p" in
        /|/root|/home|/data|/opt|/var|/var/lib|/etc|/usr|/srv|/tmp|/mnt|/boot) return 0 ;;
    esac
    [[ "$p" =~ ^/home/[^/]+$ ]] && return 0          # katalog domowy użytkownika
    # katalog roboczy oc-mirror (cache, archiwa, poświadczenia) oraz wszystko, co go zawiera
    local keep
    for keep in "$BASE_DIR" "$AUTH_DIR"; do
        [[ "$keep/" == "$p/"* ]] && return 0
    done
    [[ "$(tr -cd '/' <<<"$p" | wc -c)" -lt 2 ]]    # wymagamy głębokości >= 2, np. /data/quay
}

log_header "REINSTALACJA MINI QUAY — ${REG_HOST}$( (( PLAN_ONLY )) && echo ' (PLAN)')"
echo "  Właściciel plików roboczych: $OWNER"

# ---------------------------------------------------------------------------
# 1. Wymagania
# ---------------------------------------------------------------------------
log_section "1. Wymagania"

if getent hosts "$REG_FQDN" >/dev/null; then
    log_ok "DNS: $REG_FQDN -> $(getent hosts "$REG_FQDN" | awk '{print $1}' | paste -sd' ' -)"
else
    die "$REG_FQDN nie rozwiązuje się w DNS — mini Quay wymaga FQDN w DNS (węzły klastra też muszą go rozwiązywać)"
fi
# Katalogi Quay i oc-mirror muszą być rozłączne (reinstalacja Quay kasuje swoje katalogi)
for d in "$QUAY_ROOT" "$QUAY_STORAGE" "$SQLITE_STORAGE"; do
    [[ -n "$d" ]] || continue
    if [[ "$BASE_DIR/" == "${d%/}/"* || "${d%/}/" == "$BASE_DIR/"* ]]; then
        die "registry.* ($d) i mirror.baseDir ($BASE_DIR) nakładają się — rozdziel je w $VARS_FILE (np. /data/quay i /data/oc-mirror)"
    fi
done
[[ "$REG_PORT" == "8443" ]] || log_info "Port rejestru: $REG_PORT (standardowo 8443)"

systemctl is-active --quiet sshd || die "sshd nie działa — instalator mirror-registry łączy się przez SSH z localhost"
log_ok "sshd działa"

if [[ -n "$PULL_SECRET" ]]; then
    [[ -r "$PULL_SECRET" ]] || die "Nie można odczytać $PULL_SECRET"
    jq -e '.auths["registry.redhat.io"] and .auths["quay.io"]' "$PULL_SECRET" &>/dev/null \
        || die "$PULL_SECRET nie wygląda na pull secret Red Hat (brak registry.redhat.io / quay.io)"
    log_ok "Pull secret: $(jq -r '.auths | keys | join(", ")' "$PULL_SECRET")"
fi

for d in "$QUAY_STORAGE" "$BASE_DIR"; do
    [[ -n "$d" ]] || continue
    parent="$d"; while [[ ! -d "$parent" ]]; do parent=$(dirname "$parent"); done
    avail=$(df -BG --output=avail "$parent" | tail -1 | tr -dc '0-9')
    if (( avail < 200 )); then log_warn "$d: wolne ${avail} GB (zalecane ≥ 500 GB)"; else log_ok "$d: wolne ${avail} GB"; fi
done

for f in "$SSL_CERT" "$SSL_KEY" "$SSL_CA"; do
    [[ -z "$f" || -r "$f" ]] || die "Nie można odczytać $f"
done
if [[ -n "$SSL_CERT" ]]; then
    openssl x509 -in "$SSL_CERT" -noout -checkhost "$REG_FQDN" | grep -q "does match" \
        || die "Certyfikat $SSL_CERT nie obejmuje $REG_FQDN (SAN)"
    openssl verify -CAfile "$SSL_CA" "$SSL_CERT" >/dev/null || die "$SSL_CERT nie weryfikuje się względem $SSL_CA"
    log_ok "Własny certyfikat: obejmuje $REG_FQDN, łańcuch do $SSL_CA poprawny"
fi

# ---------------------------------------------------------------------------
# 2. Istniejąca instalacja
# ---------------------------------------------------------------------------
log_section "2. Istniejąca instalacja Quay"

OLD_CONTAINERS=(); OLD_UNITS=(); OLD_VOLUMES=(); OLD_DIRS=()
for c in quay-app quay-redis quay-postgres ansible_runner_instance; do
    podman container exists "$c" 2>/dev/null && OLD_CONTAINERS+=("$c")
done
OLD_POD=0
podman pod exists quay-pod 2>/dev/null && OLD_POD=1
for u in /etc/systemd/system/quay-*.service; do [[ -e "$u" ]] && OLD_UNITS+=("$(basename "$u")"); done
for v in quay-storage sqlite-storage pg-storage; do
    podman volume exists "$v" 2>/dev/null && OLD_VOLUMES+=("$v")
done

# Katalogi: z punktów montowania działającego kontenera + domyślne lokalizacje 1.x/2.x + ścieżki z vars
if podman container exists quay-app 2>/dev/null; then
    while IFS=$'\t' read -r type src dest; do
        [[ "$type" == "bind" ]] || continue
        case "$dest" in
            /quay-registry/conf/stack) OLD_DIRS+=("$(dirname "$src")") ;;
            /datastorage|/sqlite)      OLD_DIRS+=("$src") ;;
        esac
    done < <(podman inspect quay-app | jq -r '.[0].Mounts[] | [.Type, .Source, .Destination] | @tsv')
fi
for d in /etc/quay-install /root/quay-install "$QUAY_ROOT" "$QUAY_STORAGE" "$SQLITE_STORAGE"; do
    [[ -n "$d" && -e "$d" ]] && OLD_DIRS+=("$d")
done
mapfile -t OLD_DIRS < <(printf '%s\n' "${OLD_DIRS[@]}" | awk 'NF && !seen[$0]++')

# Rootless Quay u użytkownika sudo — tego skrypt nie usuwa (inny użytkownik, inne systemd)
if [[ "$OWNER" != "root" ]]; then
    OWNER_UID=$(id -u "$OWNER")
    if sudo -u "$OWNER" XDG_RUNTIME_DIR="/run/user/$OWNER_UID" podman container exists quay-app 2>/dev/null; then
        log_error "Użytkownik $OWNER ma własny (rootless) Quay. Usuń go najpierw jako $OWNER: ./mirror-registry uninstall --autoApprove -v"
    fi
fi

if (( ${#OLD_CONTAINERS[@]} + ${#OLD_UNITS[@]} + ${#OLD_VOLUMES[@]} + ${#OLD_DIRS[@]} + OLD_POD == 0 )); then
    log_ok "Brak poprzedniej instalacji — czysta instalacja"
else
    [[ ${#OLD_CONTAINERS[@]} -gt 0 ]] && log_info "Kontenery : ${OLD_CONTAINERS[*]}"
    (( OLD_POD )) && log_info "Pod       : quay-pod"
    [[ ${#OLD_UNITS[@]} -gt 0 ]] && log_info "Usługi    : ${OLD_UNITS[*]}"
    [[ ${#OLD_VOLUMES[@]} -gt 0 ]] && log_info "Wolumeny  : ${OLD_VOLUMES[*]}"
    for d in "${OLD_DIRS[@]}"; do
        if is_protected_path "$d"; then
            log_warn "Katalog $d jest chroniony — NIE zostanie usunięty (usuń ręcznie jego zawartość związaną z Quay)"
        else
            log_info "Katalog   : $d ($(du -sh "$d" 2>/dev/null | cut -f1))"
        fi
    done
    podman container exists quay-app 2>/dev/null \
        && log_info "Obecny SERVER_HOSTNAME: $(podman exec quay-app sh -c 'grep ^SERVER_HOSTNAME /quay-registry/conf/stack/config.yaml' 2>/dev/null | cut -d' ' -f2 || echo '?')"
fi
(( ERRORS == 0 )) || die "Popraw błędy powyżej"

if (( PLAN_ONLY )); then
    log_header "PLAN — nic nie zostało zmienione"
    echo "  Zostanie zainstalowane: quayHostname=$REG_HOST quayRoot=$QUAY_ROOT"
    echo "                          quayStorage=${QUAY_STORAGE:-<wolumen quay-storage>} sqliteStorage=${SQLITE_STORAGE:-<wolumen sqlite-storage>}"
    echo "  Nowe pliki: $AUTH_FILE, $PASS_FILE, $CA_EXPORT (właściciel $OWNER)"
    exit 0
fi

if (( ${#OLD_CONTAINERS[@]} + ${#OLD_UNITS[@]} + ${#OLD_VOLUMES[@]} + ${#OLD_DIRS[@]} + OLD_POD > 0 )); then
    echo ""
    log_warn "Usunięcie starej instalacji skasuje WSZYSTKIE obrazy w tym Quay (zmirrorowane dane oc-mirror)."
    log_info "Cache oc-mirror ($BASE_DIR/cache, archive/) zostaje — obrazy wrócą przez 04-mirror.sh --step d2m."
    if [[ "$ASSUME_YES" != "1" ]]; then
        read -r -p "$(echo -e "${YELLOW}?${RESET} Aby potwierdzić, wpisz nazwę rejestru (${REG_FQDN}): ")" answer </dev/tty
        # Tolerancja: wielkość liter, spacje, końcowa kropka; akceptujemy FQDN, FQDN:port lub krótką nazwę
        norm() { tr -d '[:space:]\r' <<<"$1" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//'; }
        typed=$(norm "$answer")
        accepted=("$(norm "$REG_FQDN")" "$(norm "$REG_HOST")" "$(norm "${REG_FQDN%%.*}")")
        if [[ ! " ${accepted[*]} " == *" ${typed} "* || -z "$typed" ]]; then
            die "Przerwano — nic nie zostało zmienione.
       Wpisano: '${answer}'. Oczekiwano jednej z: ${accepted[*]} (z registry.host w $VARS_FILE)"
        fi
        log_ok "Potwierdzono: $typed"
    fi

    # -----------------------------------------------------------------------
    # 3. Kopia zapasowa konfiguracji i CA
    # -----------------------------------------------------------------------
    log_section "3. Kopia konfiguracji starej instalacji"
    BACKUP="/root/quay-backup-$(timestamp).tgz"
    BACKUP_ITEMS=()
    for d in "${OLD_DIRS[@]}"; do
        for sub in quay-config quay-rootCA; do [[ -d "$d/$sub" ]] && BACKUP_ITEMS+=("$d/$sub"); done
    done
    if [[ ${#BACKUP_ITEMS[@]} -gt 0 ]]; then
        tar -czf "$BACKUP" "${BACKUP_ITEMS[@]}" 2>/dev/null
        chmod 600 "$BACKUP"
        log_ok "Kopia: $BACKUP (${BACKUP_ITEMS[*]})"
    else
        log_info "Brak konfiguracji do skopiowania"
    fi

    # -----------------------------------------------------------------------
    # 4. Usunięcie starej instalacji
    # -----------------------------------------------------------------------
    log_section "4. Usuwanie starej instalacji"
    for u in quay-app quay-redis quay-postgres quay-pod; do
        systemctl stop "$u" 2>/dev/null || true
        systemctl disable "$u" 2>/dev/null || true
    done
    for u in "${OLD_UNITS[@]}"; do rm -f "/etc/systemd/system/$u"; done
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
    log_ok "Usługi systemd zatrzymane i usunięte"

    for c in "${OLD_CONTAINERS[@]}"; do podman rm -f "$c" >/dev/null 2>&1 || true; done
    podman pod rm -f quay-pod >/dev/null 2>&1 || true
    for v in "${OLD_VOLUMES[@]}"; do podman volume rm -f "$v" >/dev/null 2>&1 || true; done
    log_ok "Kontenery, pod i wolumeny usunięte"

    for d in "${OLD_DIRS[@]}"; do
        if is_protected_path "$d"; then continue; fi
        rm -rf --one-file-system "$d"
        log_ok "Usunięto $d"
    done

    rm -f /etc/pki/ca-trust/source/anchors/mirror-registry-*.pem
    rm -rf "/etc/containers/certs.d/${REG_HOST}"
    update-ca-trust extract
    log_ok "Usunięto stare CA rejestru z zaufanych"
fi

if ss -ltn "sport = :${REG_PORT}" | grep -q LISTEN; then
    die "Port ${REG_PORT} nadal zajęty: $(ss -ltnp "sport = :${REG_PORT}" | tail -n +2 | awk '{print $NF}')"
fi
log_ok "Port ${REG_PORT}/tcp wolny"

# ---------------------------------------------------------------------------
# 5. Instalacja
# ---------------------------------------------------------------------------
log_section "5. Instalacja mirror-registry"

install -d -m 0755 -o "$OWNER" -g "$OWNER_GROUP" "$BASE_DIR" "$LOG_DIR"
install -d -m 0700 -o "$OWNER" -g "$OWNER_GROUP" "$AUTH_DIR"
MR_DIR="$BASE_DIR/tools/mirror-registry"
rm -rf "$MR_DIR"; mkdir -p "$MR_DIR"
if [[ -n "$TARBALL" ]]; then
    MR_TGZ="$MR_DIR/$(basename "$TARBALL")"
    cp "$TARBALL" "$MR_TGZ"
    log_info "Instalator z pliku: $TARBALL"
else
    MR_TGZ="$MR_DIR/mirror-registry-${GOARCH}.tar.gz"
    curl -fsSI --max-time 20 -o /dev/null "$MR_URL/sha256sum.txt" \
        || die "Brak dostępu do mirror.openshift.com. Jeśli wychodzisz przez proxy (sudo je czyści):
       sudo --preserve-env=https_proxy,no_proxy,HTTPS_PROXY,NO_PROXY $0 ...   albo użyj --tarball PLIK"
    download_verified "$MR_URL" "mirror-registry-${GOARCH}.tar.gz" "$MR_DIR"
    log_ok "Pobrano i zweryfikowano (SHA256) mirror-registry-${GOARCH}.tar.gz"
fi
tar -xzf "$MR_TGZ" -C "$MR_DIR"
log_info "Wersja instalatora: $("$MR_DIR/mirror-registry" --version 2>/dev/null | tail -1 || echo '?')"

for d in "$QUAY_STORAGE" "$SQLITE_STORAGE"; do [[ -n "$d" ]] && mkdir -p "$d"; done
mkdir -p "$(dirname "$QUAY_ROOT")"

# Hasło: tylko litery i cyfry (instalator przekazuje je w linii poleceń ansible)
PASSWORD=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')
install -m 0600 -o "$OWNER" -g "$OWNER_GROUP" /dev/null "$PASS_FILE"
printf '%s\n' "$PASSWORD" >"$PASS_FILE"
log_ok "Nowe hasło użytkownika init zapisane: $PASS_FILE (0600, $OWNER)"

# SSH root@localhost — wymagane przez instalator
mkdir -p /root/.ssh && chmod 700 /root/.ssh
[[ -f /root/.ssh/quay_installer ]] || ssh-keygen -q -b 2048 -t rsa -N '' -f /root/.ssh/quay_installer
grep -qF "$(cut -d' ' -f2 /root/.ssh/quay_installer.pub)" /root/.ssh/authorized_keys 2>/dev/null \
    || (umask 077 && cat /root/.ssh/quay_installer.pub >>/root/.ssh/authorized_keys)
restorecon -R /root/.ssh 2>/dev/null || true

ssh_ok() {
    ssh -i /root/.ssh/quay_installer -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@localhost true 2>/dev/null
}
if ssh_ok; then
    log_ok "SSH root@localhost kluczem quay_installer: OK"
elif (( TEMP_SSH_ROOT )); then
    # Sprawdzamy, że zmiana NIE dotyczy połączeń spoza localhost (porównanie efektywnej konfiguracji)
    remote_before=$(sshd -T -C user=root,host=remote.example,addr=192.0.2.10 2>/dev/null | sort)
    cat >"$SSHD_DROPIN" <<'EOF'
# Tymczasowo, na czas instalacji mirror-registry (02a-reinstall-quay.sh). Plik usuwany automatycznie.
Match Address 127.0.0.1,::1
    PermitRootLogin prohibit-password
    PubkeyAuthentication yes
    AllowUsers root
EOF
    chmod 600 "$SSHD_DROPIN"
    sshd -t || { rm -f "$SSHD_DROPIN"; die "Konfiguracja sshd z tymczasowym plikiem jest niepoprawna — wycofano"; }
    if [[ "$(sshd -T -C user=root,host=remote.example,addr=192.0.2.10 2>/dev/null | sort)" != "$remote_before" ]]; then
        rm -f "$SSHD_DROPIN"
        die "Tymczasowa zmiana sshd wpływałaby na połączenia spoza localhost — wycofano. Dopuść root@localhost ręcznie."
    fi
    systemctl reload sshd
    ssh_ok || die "SSH root@localhost nadal nie działa — sprawdź sshd (journalctl -u sshd)"
    log_ok "Tymczasowo dopuszczono root@localhost (tylko 127.0.0.1/::1) — zostanie cofnięte po instalacji"
else
    die "SSH root@localhost nie działa (np. PermitRootLogin no). Instalator mirror-registry tego wymaga.
       Uruchom ponownie z --temp-ssh-root (dopuszcza root TYLKO z localhost na czas instalacji)."
fi

INSTALL_ARGS=(install -v --targetHostname localhost --targetUsername root
              --quayHostname "$REG_HOST" --quayRoot "$QUAY_ROOT"
              --initUser init --initPassword "$PASSWORD")
[[ -n "$QUAY_STORAGE" ]] && INSTALL_ARGS+=(--quayStorage "$QUAY_STORAGE")
[[ -n "$SQLITE_STORAGE" ]] && INSTALL_ARGS+=(--sqliteStorage "$SQLITE_STORAGE")
[[ -n "$SSL_CERT" ]] && INSTALL_ARGS+=(--sslCert "$(readlink -f "$SSL_CERT")" --sslKey "$(readlink -f "$SSL_KEY")")

INSTALL_LOG="$LOG_DIR/mirror-registry-install-$(timestamp).log"
log_info "Instalacja trwa kilka minut. Log (hasło zamaskowane): $INSTALL_LOG"
if ! (cd "$MR_DIR" && ./mirror-registry "${INSTALL_ARGS[@]}") 2>&1 \
        | sed -u "s/${PASSWORD}/********/g" | tee "$INSTALL_LOG"; then
    if grep -qi 'WRONGPASS\|Could not connect to Redis' "$INSTALL_LOG"; then
        die "Instalacja mirror-registry nie powiodła się: Quay nie łączy się z Redis (WRONGPASS).
       Hasło w quay-config/config.yaml jest inne niż to, z którym wystartował kontener quay-redis.
       Nie trzeba instalować od nowa — zdiagnozuj i napraw:
         sudo $(dirname "$(readlink -f "$0")")/02b-fix-quay-redis.sh -f $VARS_FILE --plan
       Szczegóły instalacji: $INSTALL_LOG"
    fi
    die "Instalacja mirror-registry nie powiodła się — szczegóły w $INSTALL_LOG"
fi
chown "$OWNER:$OWNER_GROUP" "$INSTALL_LOG"
log_ok "mirror-registry zainstalowany"

# Tymczasowy dostęp SSH nie jest już potrzebny
if [[ -f "$SSHD_DROPIN" ]]; then rm -f "$SSHD_DROPIN"; systemctl reload sshd; log_ok "Cofnięto tymczasowe ustawienie sshd"; fi

# ---------------------------------------------------------------------------
# 6. CA rejestru
# ---------------------------------------------------------------------------
log_section "6. Certyfikat CA rejestru"

CA_SRC="${SSL_CA:-$QUAY_ROOT/quay-rootCA/rootCA.pem}"
[[ -f "$CA_SRC" ]] || die "Nie znaleziono CA: $CA_SRC"
openssl verify -CAfile "$CA_SRC" "$QUAY_ROOT/quay-config/ssl.cert" >/dev/null \
    || die "Certyfikat Quay nie weryfikuje się względem $CA_SRC"

install -m 0644 -o "$OWNER" -g "$OWNER_GROUP" "$CA_SRC" "$CA_EXPORT"
log_ok "CA czytelne bez sudo: $CA_EXPORT (dla registry.caFile)"
install -m 0644 "$CA_SRC" "/etc/pki/ca-trust/source/anchors/mirror-registry-${REG_FQDN}.pem"
update-ca-trust extract
log_ok "CA w zaufanych systemu (update-ca-trust)"
install -d "/etc/containers/certs.d/${REG_HOST}"
install -m 0644 "$CA_SRC" "/etc/containers/certs.d/${REG_HOST}/ca.crt"
log_ok "CA dla podman/skopeo: /etc/containers/certs.d/${REG_HOST}/ca.crt"
log_info "Certyfikat ważny do: $(openssl x509 -in "$QUAY_ROOT/quay-config/ssl.cert" -noout -enddate | cut -d= -f2)"

# ---------------------------------------------------------------------------
# 7. Firewall
# ---------------------------------------------------------------------------
log_section "7. Firewall"
if systemctl is-active --quiet firewalld; then
    if ! firewall-cmd --query-port="${REG_PORT}/tcp" &>/dev/null; then
        firewall-cmd --permanent --add-port="${REG_PORT}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
    fi
    log_ok "firewalld: port ${REG_PORT}/tcp otwarty"
else
    log_info "firewalld nie działa — sprawdź inne zapory między węzłami klastra a bastionem"
fi

# ---------------------------------------------------------------------------
# 8. Nowy auth.json i logowanie
# ---------------------------------------------------------------------------
log_section "8. Poświadczenia ($AUTH_FILE)"

[[ -e "$AUTH_FILE" ]] && mv "$AUTH_FILE" "${AUTH_FILE}.old-$(timestamp)" && log_info "Poprzedni plik przeniesiony do ${AUTH_FILE}.old-*"
jq --arg r "$REG_HOST" --arg a "$(printf 'init:%s' "$PASSWORD" | base64 -w0)" \
    '.auths[$r] = {auth: $a}' "$PULL_SECRET" >"$TMP_DIR/auth.json"
install -m 0600 -o "$OWNER" -g "$OWNER_GROUP" "$TMP_DIR/auth.json" "$AUTH_FILE"
log_ok "Utworzono: pull secret Red Hat + init@${REG_HOST} (0600, $OWNER)"

# Czekamy, aż Quay po instalacji odpowie
end=$((SECONDS + 180))
until curl -fsS --noproxy "$REG_FQDN" --cacert "$CA_EXPORT" -o /dev/null "https://${REG_HOST}/health/instance" 2>/dev/null; do
    (( SECONDS < end )) || die "Quay nie odpowiada na https://${REG_HOST}/health/instance po 3 min"
    sleep 5
done
log_ok "https://${REG_HOST}/health/instance — OK (TLS zweryfikowany)"

# Logowanie sprawdzane tak, jak zrobi to oc-mirror: istniejące dane z pliku, bez podawania hasła
LOGIN_TOOL=podman; command -v skopeo &>/dev/null && LOGIN_TOOL=skopeo
check_login() {
    local reg="$1" out
    if out=$("$LOGIN_TOOL" login --authfile "$AUTH_FILE" "$reg" </dev/null 2>&1); then
        log_ok "Logowanie do $reg: OK"
    else
        log_error "Logowanie do $reg: $(grep -viE '^(WARN|time=.*level=warn)|^Authenticating' <<<"$out" | tr '\n' ' ' | head -c 250)"
        return 1
    fi
}
check_login "$REG_HOST" || true
RH_FAILED=0
for reg in registry.redhat.io quay.io registry.connect.redhat.com; do
    jq -e --arg r "$reg" '.auths[$r]' "$AUTH_FILE" &>/dev/null || continue
    check_login "$reg" || RH_FAILED=1
done
if (( RH_FAILED )); then
    log_info "Jeśli bastion wychodzi do internetu przez proxy: sudo czyści https_proxy. Uruchom ponownie z:"
    log_info "  sudo --preserve-env=https_proxy,http_proxy,no_proxy,HTTPS_PROXY,HTTP_PROXY,NO_PROXY $0 ..."
fi

# ---------------------------------------------------------------------------
# 9. Weryfikacja końcowa
# ---------------------------------------------------------------------------
log_section "9. Weryfikacja"
for svc in quay-pod quay-app quay-redis; do
    if systemctl is-active --quiet "$svc" && systemctl is-enabled --quiet "$svc"; then
        log_ok "usługa $svc: active, enabled"
    else
        log_error "usługa $svc: $(systemctl is-active "$svc" 2>/dev/null), $(systemctl is-enabled "$svc" 2>/dev/null)"
    fi
done
chown "$OWNER:$OWNER_GROUP" "$BASE_DIR" "$LOG_DIR"

log_header "SEKCJA registry DO mirror-vars.yaml"
cat <<EOF
registry:
  host: ${REG_HOST}
  namespace: $(cfg registry.namespace ocp)
  quayRoot: ${QUAY_ROOT}
  quayStorage: "${QUAY_STORAGE}"
  sqliteStorage: "${SQLITE_STORAGE}"
  caFile: ${CA_EXPORT}
EOF
[[ "$(expand_path "$VARS_CA")" == "$CA_EXPORT" ]] \
    || log_warn "W $VARS_FILE registry.caFile = '${VARS_CA}' — zmień na ${CA_EXPORT} (czytelne bez sudo)"

log_header "GOTOWE — ostrzeżenia: ${WARNINGS}, błędy: ${ERRORS}"
cat <<EOF
  UI Quay        : https://${REG_HOST}   (użytkownik: init, hasło: ${PASS_FILE})
  Poświadczenia  : ${AUTH_FILE}
  CA rejestru    : ${CA_EXPORT}

  Następne kroki (jako ${OWNER}, bez sudo):
    1. W UI Quay: organizacja '$(cfg registry.namespace ocp)' + robot tylko do odczytu (INSTRUKCJA 4.7)
    2. bin/02-setup-bastion.sh -f ${VARS_FILE}      # narzędzia oc/oc-mirror/opm; Quay zostanie pominięty
    3. bin/00-inspect-quay.sh -f ${VARS_FILE}       # kontrola
  Jeśli klaster był już skonfigurowany ze starym Quay: nowe CA i nowy robot ->
    bin/05-configure-cluster.sh -f ${VARS_FILE} --stage trust,pullsecret
EOF
(( ERRORS == 0 )) || exit 2
