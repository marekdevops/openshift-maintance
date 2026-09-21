#!/usr/bin/env bash
# 00-inspect-quay.sh — inwentaryzacja istniejącego mini Quay na bastionie i wartości do mirror-vars.yaml.
#
# Użycie:
#   ./00-inspect-quay.sh [-f config/mirror-vars.yaml] [-o fragment.yaml] [--export-ca PLIK]
#
# Opcje:
#   -f PLIK            porównaj wykryte wartości z istniejącym plikiem zmiennych
#   -o PLIK            zapisz wykrytą sekcję "registry:" do pliku (domyślnie tylko na ekran)
#   --export-ca PLIK   skopiuj CA rejestru w miejsce czytelne dla użytkownika bez sudo
#                      (np. /data/oc-mirror/auth/quay-rootCA.pem) i użyj go jako registry.caFile
#
# Co sprawdza (TYLKO ODCZYT — nie zmienia Quay ani systemu):
#   1. Kontenery i usługi systemd (quay-app, quay-redis, quay-pod) — rootful (sudo) lub rootless
#   2. Katalogi: quayRoot, quayStorage, sqliteStorage (z punktów montowania kontenera quay-app)
#   3. config.yaml: SERVER_HOSTNAME, baza, CREATE_NAMESPACE_ON_PUSH, superużytkownicy (bez sekretów)
#   4. Certyfikat TLS: SAN, wystawca, ważność, łańcuch do CA
#   5. DNS, port, firewall, /health/instance z weryfikacją TLS
#   6. Poświadczenia w pliku auth.json i repozytoria widoczne dla tego konta (_catalog)
#   7. Wolne miejsce na dysku z danymi
#
# Podman uruchamiany przez sudo jest wykrywany automatycznie.
# Kod wyjścia: 0 = OK, 1 = ostrzeżenia, 2 = błędy

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

VARS_FILE=""
OUT_FILE=""
EXPORT_CA=""

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) VARS_FILE="$2"; shift 2 ;;
        -o) OUT_FILE="$2"; shift 2 ;;
        --export-ca) EXPORT_CA="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Nieznana opcja: $1"; usage 1 ;;
    esac
done

require_cmd podman jq openssl curl python3
require_pyyaml

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
chmod 700 "$TMP_DIR"

# ---------------------------------------------------------------------------
# Tryb pracy Podman: rootless (bieżący użytkownik) czy rootful (sudo)
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    podman container exists quay-app 2>/dev/null || die "Brak kontenera quay-app (root). Czy mini Quay jest zainstalowany?"
    SUDO=""; MODE="rootful (root)"; SYSTEMCTL=(systemctl)
elif podman container exists quay-app 2>/dev/null; then
    SUDO=""; MODE="rootless ($(id -un))"; SYSTEMCTL=(systemctl --user)
elif sudo podman container exists quay-app 2>/dev/null; then
    SUDO="sudo"; MODE="rootful (sudo podman)"; SYSTEMCTL=(systemctl)
else
    die "Nie znaleziono kontenera quay-app ani dla $(id -un), ani przez sudo. Czy mini Quay jest zainstalowany?"
fi
P() { $SUDO podman "$@"; }
rcat() { $SUDO cat "$@"; }          # odczyt plików należących do root

log_header "INWENTARYZACJA MINI QUAY — $(hostname -f 2>/dev/null || hostname)"
echo "  Tryb Podman: $MODE"

# ---------------------------------------------------------------------------
# 1. Kontenery i usługi
# ---------------------------------------------------------------------------
log_section "1. Kontenery i usługi"

P inspect quay-app >"$TMP_DIR/quay-app.json"
QUAY_IMAGE=$(jq -r '.[0].ImageName' "$TMP_DIR/quay-app.json")
QUAY_STATE=$(jq -r '.[0].State.Status' "$TMP_DIR/quay-app.json")
if [[ "$QUAY_STATE" == "running" ]]; then
    log_ok "quay-app: running od $(jq -r '.[0].State.StartedAt' "$TMP_DIR/quay-app.json" | cut -d. -f1)"
else
    log_error "quay-app: $QUAY_STATE"
fi
log_info "Obraz Quay: $QUAY_IMAGE"

for c in quay-redis quay-postgres; do
    if P container exists "$c" 2>/dev/null; then
        st=$(P inspect "$c" --format '{{.State.Status}}')
        if [[ "$c" == "quay-postgres" ]]; then
            log_warn "Kontener quay-postgres — to instalacja mirror-registry 1.x; zalecana aktualizacja do 2.x (SQLite)"
        elif [[ "$st" == "running" ]]; then
            log_ok "$c: running"
        else
            log_error "$c: $st"
        fi
    fi
done

for svc in quay-pod quay-app quay-redis; do
    active=$("${SYSTEMCTL[@]}" is-active "$svc" 2>/dev/null || true)
    enabled=$("${SYSTEMCTL[@]}" is-enabled "$svc" 2>/dev/null || true)
    if [[ "$active" == "active" && "$enabled" == "enabled" ]]; then
        log_ok "usługa $svc: active, enabled (${SYSTEMCTL[*]})"
    else
        log_warn "usługa $svc: ${active:-?}, ${enabled:-?} (${SYSTEMCTL[*]}) — Quay może nie wstać po restarcie bastionu"
    fi
done
if [[ -z "$SUDO" && $EUID -ne 0 ]]; then
    [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" == "yes" ]] \
        && log_ok "linger włączony (usługi --user działają po wylogowaniu)" \
        || log_warn "linger wyłączony — rootless Quay zatrzyma się po wylogowaniu: sudo loginctl enable-linger $(id -un)"
fi

# ---------------------------------------------------------------------------
# 2. Katalogi (z punktów montowania kontenera — tak jak ustawił je instalator)
# ---------------------------------------------------------------------------
log_section "2. Katalogi danych"

mount_of() {   # mount_of <ścieżka w kontenerze> -> "typ<TAB>źródło<TAB>nazwa wolumenu"
    jq -r --arg d "$1" '.[0].Mounts[] | select(.Destination == $d) | [.Type, .Source, (.Name // "")] | @tsv' \
        "$TMP_DIR/quay-app.json"
}

IFS=$'\t' read -r _ CONF_SRC _ <<<"$(mount_of /quay-registry/conf/stack)"
[[ -n "${CONF_SRC:-}" ]] || die "quay-app nie ma zamontowanej konfiguracji (/quay-registry/conf/stack)"
QUAY_ROOT=$(dirname "$CONF_SRC")
log_ok "quayRoot      : $QUAY_ROOT (konfiguracja: $CONF_SRC)"

describe_storage() {   # describe_storage <etykieta> <ścieżka w kontenerze> <zmienna wynikowa>
    local label="$1" dest="$2" type src name
    IFS=$'\t' read -r type src name <<<"$(mount_of "$dest")"
    if [[ "$type" == "volume" ]]; then
        log_info "$label: wolumen Podman '$name' ($src) — w vars zostaw puste (domyślny wolumen)"
        printf -v "$3" '%s' ""
    else
        log_ok "$label: $src"
        printf -v "$3" '%s' "$src"
    fi
    printf -v "${3}_PATH" '%s' "$src"
}
describe_storage "quayStorage   " /datastorage QUAY_STORAGE
describe_storage "sqliteStorage " /sqlite SQLITE_STORAGE

# ---------------------------------------------------------------------------
# 3. Konfiguracja Quay (config.yaml) — wyłącznie klucze nieposiadające sekretów
# ---------------------------------------------------------------------------
log_section "3. Konfiguracja Quay (config.yaml)"

rcat "$CONF_SRC/config.yaml" >"$TMP_DIR/config.yaml"
chmod 600 "$TMP_DIR/config.yaml"
yaml2json "$TMP_DIR/config.yaml" | jq '{
    SERVER_HOSTNAME, PREFERRED_URL_SCHEME, CREATE_NAMESPACE_ON_PUSH, FEATURE_ANONYMOUS_ACCESS,
    FEATURE_USER_CREATION, SUPER_USERS, DEFAULT_TAG_EXPIRATION,
    DB: (.DB_URI // "" | sub(":.*"; "")),
    STORAGE: (.DISTRIBUTED_STORAGE_CONFIG // {} | tostring)
  }' >"$TMP_DIR/cfg.json"
rm -f "$TMP_DIR/config.yaml"

REG_HOST=$(jq -r '.SERVER_HOSTNAME // ""' "$TMP_DIR/cfg.json")
[[ -n "$REG_HOST" ]] || die "Brak SERVER_HOSTNAME w config.yaml"
# registry.host = dokładnie SERVER_HOSTNAME (z portem lub bez — tak klaster będzie adresował obrazy)
REG_FQDN="${REG_HOST%%:*}"
if [[ "$REG_HOST" == *:* ]]; then REG_PORT="${REG_HOST##*:}"; else REG_PORT=443; fi

log_ok "SERVER_HOSTNAME        : $(jq -r .SERVER_HOSTNAME "$TMP_DIR/cfg.json")  -> registry.host"
log_info "Baza danych            : $(jq -r .DB "$TMP_DIR/cfg.json")"
log_info "Superużytkownicy       : $(jq -r '(.SUPER_USERS // []) | join(", ")' "$TMP_DIR/cfg.json")"
if [[ "$(jq -r .CREATE_NAMESPACE_ON_PUSH "$TMP_DIR/cfg.json")" == "true" ]]; then
    log_ok "CREATE_NAMESPACE_ON_PUSH: true (organizacja powstanie przy pierwszym push oc-mirror)"
else
    log_warn "CREATE_NAMESPACE_ON_PUSH != true — organizację registry.namespace utwórz ręcznie w UI przed mirrorem"
fi
[[ "$(jq -r .FEATURE_ANONYMOUS_ACCESS "$TMP_DIR/cfg.json")" == "true" ]] \
    && log_info "FEATURE_ANONYMOUS_ACCESS: true (dotyczy tylko repozytoriów publicznych; oc-mirror tworzy prywatne)"

# ---------------------------------------------------------------------------
# 4. Certyfikat TLS i CA
# ---------------------------------------------------------------------------
log_section "4. Certyfikat TLS"

rcat "$CONF_SRC/ssl.cert" >"$TMP_DIR/ssl.cert" 2>/dev/null || die "Brak $CONF_SRC/ssl.cert"
openssl x509 -in "$TMP_DIR/ssl.cert" -noout >/dev/null 2>&1 || die "$CONF_SRC/ssl.cert nie jest certyfikatem PEM"

log_info "Podmiot  : $(openssl x509 -in "$TMP_DIR/ssl.cert" -noout -subject | sed 's/^subject=//')"
log_info "Wystawca : $(openssl x509 -in "$TMP_DIR/ssl.cert" -noout -issuer | sed 's/^issuer=//')"
log_info "SAN      : $(openssl x509 -in "$TMP_DIR/ssl.cert" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | xargs)"
log_info "Ważny do : $(openssl x509 -in "$TMP_DIR/ssl.cert" -noout -enddate | cut -d= -f2)"

if openssl x509 -in "$TMP_DIR/ssl.cert" -noout -checkhost "$REG_FQDN" 2>/dev/null | grep -q "does match"; then
    log_ok "Certyfikat obejmuje $REG_FQDN"
else
    log_error "Certyfikat NIE obejmuje $REG_FQDN (SAN) — klaster odrzuci połączenie"
fi
if ! openssl x509 -in "$TMP_DIR/ssl.cert" -noout -checkend 0 >/dev/null; then
    log_error "Certyfikat wygasł"
elif ! openssl x509 -in "$TMP_DIR/ssl.cert" -noout -checkend $((60*86400)) >/dev/null; then
    log_warn "Certyfikat wygasa w ciągu 60 dni — zaplanuj rotację (INSTRUKCJA 12.3)"
fi

# Który plik CA podpisuje certyfikat? Kandydaci: CA wygenerowane przez instalator, zaufanie systemowe.
CA_FILE=""
CA_SRC="$QUAY_ROOT/quay-rootCA/rootCA.pem"
if $SUDO test -f "$CA_SRC"; then
    rcat "$CA_SRC" >"$TMP_DIR/rootCA.pem"
    if openssl verify -CAfile "$TMP_DIR/rootCA.pem" "$TMP_DIR/ssl.cert" >/dev/null 2>&1; then
        CA_FILE="$CA_SRC"
        log_ok "Certyfikat podpisany przez CA instalatora: $CA_SRC"
        log_info "CA ważne do: $(openssl x509 -in "$TMP_DIR/rootCA.pem" -noout -enddate | cut -d= -f2)"
    fi
fi
if [[ -z "$CA_FILE" ]]; then
    if openssl verify "$TMP_DIR/ssl.cert" >/dev/null 2>&1; then
        log_info "Certyfikat z zewnętrznego PKI, zaufany przez system bastionu."
        log_warn "Wskaż w registry.caFile plik z łańcuchem CA banku (root + pośrednie) — klaster go potrzebuje"
    else
        log_error "Nie da się zbudować łańcucha zaufania dla certyfikatu (brak rootCA.pem instalatora i CA w systemie)"
    fi
fi

# CA musi być czytelne dla skryptów 02/05 uruchamianych bez sudo
if [[ -n "$CA_FILE" && -n "$EXPORT_CA" ]]; then
    install -D -m 0644 "$TMP_DIR/rootCA.pem" "$EXPORT_CA"
    CA_FILE="$EXPORT_CA"
    log_ok "Skopiowano CA do $EXPORT_CA (0644) — ten plik wpisz jako registry.caFile"
elif [[ -n "$CA_FILE" ]] && ! [[ -r "$CA_FILE" ]]; then
    log_warn "$CA_FILE jest czytelny tylko dla root — skrypty 02/05 go nie odczytają."
    log_info "  Uruchom ponownie z: --export-ca /data/oc-mirror/auth/quay-rootCA.pem"
fi

# ---------------------------------------------------------------------------
# 5. Sieć: DNS, port, firewall, health
# ---------------------------------------------------------------------------
log_section "5. Sieć"

if getent hosts "$REG_FQDN" >/dev/null; then
    RESOLVED=$(getent hosts "$REG_FQDN" | awk '{print $1}' | paste -sd' ' -)
    log_ok "DNS: $REG_FQDN -> $RESOLVED"
    LOCAL_IPS=" $(hostname -I 2>/dev/null) "
    for ip in $RESOLVED; do
        [[ "$LOCAL_IPS" == *" $ip "* ]] || log_warn "$ip nie jest adresem tego hosta — sprawdź, czy DNS wskazuje bastion"
    done
else
    log_error "DNS: $REG_FQDN nie rozwiązuje się (wymóg mini Quay i węzłów klastra)"
fi

if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${REG_PORT}\$"; then
    log_ok "Port ${REG_PORT}/tcp nasłuchuje"
else
    log_error "Nic nie nasłuchuje na porcie ${REG_PORT}/tcp"
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
    if sudo firewall-cmd --query-port="${REG_PORT}/tcp" &>/dev/null; then
        log_ok "firewalld: port ${REG_PORT}/tcp otwarty"
    else
        log_warn "firewalld: port ${REG_PORT}/tcp zamknięty — węzły klastra nie połączą się z rejestrem"
    fi
fi

if curl -fsS -o /dev/null --max-time 10 "https://${REG_HOST}/health/instance"; then
    log_ok "https://${REG_HOST}/health/instance — OK, TLS zaufany przez system bastionu"
elif curl -fsSk -o /dev/null --max-time 10 "https://${REG_HOST}/health/instance"; then
    log_warn "Quay odpowiada, ale bastion NIE ufa certyfikatowi — dodaj CA: sudo cp <caFile> /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust"
else
    log_error "https://${REG_HOST}/health/instance nie odpowiada"
fi

# ---------------------------------------------------------------------------
# 6. Poświadczenia i zawartość rejestru
# ---------------------------------------------------------------------------
log_section "6. Poświadczenia i repozytoria"

AUTH_CANDIDATES=()
[[ -n "$VARS_FILE" ]] && AUTH_CANDIDATES+=("$(expand_path "$(cfg mirror.authFile "")")")
AUTH_CANDIDATES+=("${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json" "$HOME/.docker/config.json")

AUTH_FILE=""
for f in "${AUTH_CANDIDATES[@]}"; do
    if [[ -n "$f" && -r "$f" ]] && jq -e --arg r "$REG_HOST" '.auths[$r]' "$f" &>/dev/null; then
        AUTH_FILE="$f"; break
    fi
done

if [[ -z "$AUTH_FILE" ]]; then
    log_info "Brak zapisanych poświadczeń dla $REG_HOST (sprawdzone: ${AUTH_CANDIDATES[*]})"
    log_info "  Zaloguj się: podman login --authfile /data/oc-mirror/auth/auth.json $REG_HOST"
else
    CREDS=$(jq -r --arg r "$REG_HOST" '.auths[$r].auth' "$AUTH_FILE" | base64 -d)
    log_info "Poświadczenia: $AUTH_FILE (użytkownik: ${CREDS%%:*})"
    # Token dla /v2/_catalog (standard Docker Registry v2, obsługiwany przez Quay)
    TOKEN=$(curl -fsS --max-time 10 -u "$CREDS" \
        "https://${REG_HOST}/v2/auth?service=${REG_FQDN}&scope=registry:catalog:*" 2>/dev/null | jq -r '.token // empty' || true)
    if [[ -z "$TOKEN" ]]; then
        log_error "Logowanie jako ${CREDS%%:*} nie powiodło się (złe hasło/token?)"
    else
        log_ok "Logowanie jako ${CREDS%%:*}: OK"
        if ! curl -fsS --max-time 30 -H "Authorization: Bearer $TOKEN" "https://${REG_HOST}/v2/_catalog?n=10000" \
                | jq -r '.repositories // [] | .[]' >"$TMP_DIR/repos.txt" 2>/dev/null; then
            : >"$TMP_DIR/repos.txt"
            log_info "Nie udało się pobrać listy repozytoriów (/v2/_catalog) — sprawdź w UI Quay"
        elif [[ -s "$TMP_DIR/repos.txt" ]]; then
            log_info "Repozytoria widoczne dla konta: $(wc -l <"$TMP_DIR/repos.txt")"
            log_info "Organizacje (kandydaci na registry.namespace): $(cut -d/ -f1 "$TMP_DIR/repos.txt" | sort | uniq -c | awk '{printf "%s (%s repo) ", $2, $1}')"
            for r in openshift/release-images openshift/release openshift/graph-image redhat/redhat-operator-index; do
                grep -q "/${r}\$" "$TMP_DIR/repos.txt" && log_ok "Jest już mirror: */$r"
            done
        else
            log_info "Rejestr pusty (lub konto nie widzi żadnych repozytoriów) — pierwszy mirror dopiero przed Tobą"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 7. Dysk
# ---------------------------------------------------------------------------
log_section "7. Miejsce na dysku"
for d in "$QUAY_STORAGE_PATH" "$SQLITE_STORAGE_PATH"; do
    [[ -n "$d" ]] || continue
    read -r size avail usep target < <($SUDO df -BG --output=size,avail,pcent,target "$d" | tail -1)
    msg="$d: system plików $target, rozmiar $size, wolne $avail ($usep zajęte)"
    if (( ${avail%G} < 200 )); then log_warn "$msg — mało miejsca na kolejne wersje"; else log_ok "$msg"; fi
done
log_info "Zajętość danych Quay: $($SUDO du -sh "$QUAY_STORAGE_PATH" 2>/dev/null | cut -f1)"

# ---------------------------------------------------------------------------
# Wynik: sekcja registry do mirror-vars.yaml
# ---------------------------------------------------------------------------
NAMESPACE_GUESS=$( [[ -s "$TMP_DIR/repos.txt" ]] && grep -E '/openshift/release-images$' "$TMP_DIR/repos.txt" \
                   | head -1 | sed 's|/openshift/release-images$||' || true)

cat >"$TMP_DIR/fragment.yaml" <<EOF
# Wykryte przez 00-inspect-quay.sh ($(date '+%Y-%m-%d %H:%M')) — tryb Podman: ${MODE}
registry:
  host: ${REG_HOST}
  namespace: ${NAMESPACE_GUESS:-ocp}
  quayRoot: ${QUAY_ROOT}
  quayStorage: "${QUAY_STORAGE}"
  sqliteStorage: "${SQLITE_STORAGE}"
  caFile: ${CA_FILE:-UZUPEŁNIJ-plik-z-łańcuchem-CA}
EOF

log_header "SEKCJA registry DO mirror-vars.yaml"
cat "$TMP_DIR/fragment.yaml"
[[ -n "$OUT_FILE" ]] && cp "$TMP_DIR/fragment.yaml" "$OUT_FILE" && echo -e "\n  Zapisano: $OUT_FILE"

# Porównanie z istniejącym plikiem zmiennych
if [[ -n "$VARS_FILE" ]]; then
    log_section "Porównanie z $VARS_FILE"
    for key in host namespace quayRoot quayStorage sqliteStorage caFile; do
        have=$(cfg "registry.$key" "")
        want=$(python3 "$LIB_DIR/yamlq.py" "$TMP_DIR/fragment.yaml" "registry.$key" "")
        if [[ "$have" == "$want" ]]; then
            log_ok "registry.$key = ${have:-<puste>}"
        else
            log_warn "registry.$key: w pliku '${have:-<puste>}', wykryto '${want:-<puste>}'"
        fi
    done
fi

if [[ -n "$SUDO" ]]; then
    echo ""
    log_info "Quay działa jako root (sudo podman). Skrypt 02-setup-bastion.sh wykryje go i nie będzie instalował ponownie."
    log_info "Aktualizacja/rotacja certyfikatu mini Quay: sudo ./mirror-registry upgrade ... (INSTRUKCJA 12.3-12.4)."
fi

log_header "WYNIK — ostrzeżenia: ${WARNINGS}, błędy: ${ERRORS}"
if (( ERRORS > 0 )); then exit 2; elif (( WARNINGS > 0 )); then exit 1; else exit 0; fi
