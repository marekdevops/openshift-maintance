#!/usr/bin/env bash
# common.sh — wspólne funkcje dla skryptów ocmirror.
#
# Plik jest dołączany przez `source`, nie uruchamiaj go bezpośrednio.

[[ -n "${_OFFLINE_COMMON_LOADED:-}" ]] && return 0
_OFFLINE_COMMON_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Kolory (wyłączane, gdy wyjście nie jest terminalem lub ustawiono NO_COLOR)
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

WARNINGS=0
ERRORS=0

log_header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
                echo -e "${BOLD}${CYAN}  $*${RESET}"
                echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"; }
log_section() { echo -e "\n${BOLD}▶ $*${RESET}"; }
log_ok()      { echo -e "  ${GREEN}[OK]${RESET}   $*"; }
log_info()    { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
log_warn()    { echo -e "  ${YELLOW}[WARN]${RESET} $*"; (( WARNINGS++ )) || true; }
log_error()   { echo -e "  ${RED}[ERR]${RESET}  $*"; (( ERRORS++ )) || true; }
die()         { echo -e "${RED}BŁĄD: $*${RESET}" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Wymagania
# ---------------------------------------------------------------------------
require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" &>/dev/null || die "Brak wymaganego narzędzia: '$c'. Zainstaluj je i uruchom ponownie."
    done
}

require_pyyaml() {
    python3 -c 'import yaml' &>/dev/null \
        || die "Brak modułu Python 'yaml'. Na RHEL: sudo dnf install -y python3-pyyaml"
}

require_oc_login() {
    oc whoami &>/dev/null || die "Brak aktywnej sesji oc. Zaloguj się: oc login <api-url>"
}

# ---------------------------------------------------------------------------
# Plik zmiennych (mirror-vars.yaml)
# ---------------------------------------------------------------------------
# Użycie: cfg <klucz.z.kropkami> [wartość_domyślna]
# Bez wartości domyślnej brak klucza kończy skrypt błędem.
cfg() {
    [[ -n "${VARS_FILE:-}" ]] || die "Nie ustawiono VARS_FILE (opcja -f)."
    if [[ $# -ge 2 ]]; then
        python3 "$LIB_DIR/yamlq.py" "$VARS_FILE" "$1" "$2"
    else
        python3 "$LIB_DIR/yamlq.py" "$VARS_FILE" "$1" \
            || die "W pliku $VARS_FILE brakuje wymaganego klucza: $1"
    fi
}

# Zamienia "~" i $HOME w ścieżkach z pliku zmiennych
expand_path() {
    local p="$1"
    p="${p/#\~/$HOME}"
    echo "${p//\$HOME/$HOME}"
}

# YAML/JSON -> JSON (jeden dokument na linię), do dalszej obróbki w jq
yaml2json() { python3 "$LIB_DIR/yaml2json.py" "$@"; }

# ---------------------------------------------------------------------------
# Interakcja
# ---------------------------------------------------------------------------
# confirm "pytanie" — zwraca 0 przy odpowiedzi "tak"; ASSUME_YES=1 pomija pytanie
confirm() {
    [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
    local answer
    read -r -p "$(echo -e "${YELLOW}?${RESET} $1 [tak/NIE]: ")" answer
    [[ "$answer" =~ ^(t|tak|y|yes)$ ]]
}

# in_no_proxy <host> — czy host jest objęty $no_proxy/$NO_PROXY (dokładnie, domena ".x" lub "*").
# Lokalny rejestr musi tam być: bez tego podman/oc-mirror idą do niego przez proxy banku.
in_no_proxy() {
    local host="$1" entry list
    IFS=',' read -r -a list <<<"${no_proxy:-${NO_PROXY:-}}"
    for entry in "${list[@]}"; do
        entry="${entry// /}"; entry="${entry%%:*}"
        [[ -z "$entry" ]] && continue
        if [[ "$entry" == "*" || "$host" == "$entry" || "$host" == *".${entry#.}" ]]; then return 0; fi
    done
    return 1
}

timestamp() { date '+%Y%m%d-%H%M%S'; }
