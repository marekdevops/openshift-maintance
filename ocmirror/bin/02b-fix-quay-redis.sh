#!/usr/bin/env bash
# 02b-fix-quay-redis.sh — diagnoza i naprawa błędu Quay:
#   "Could not connect to Redis with values provided in BUILDLOGS_REDIS.
#    Error: WRONGPASS invalid username-password pair or user is disabled."
#
# Użycie:
#   sudo ./02b-fix-quay-redis.sh [-f config/mirror-vars.yaml] [opcje]
#
# Opcje:
#   -f PLIK        plik zmiennych (użyty tylko do znalezienia registry.quayRoot)
#   -c PLIK        wskaż wprost config.yaml Quay (zwykle <quayRoot>/quay-config/config.yaml)
#   --plan         tylko diagnoza — nie zmienia konfiguracji ani haseł (jeśli quay-redis
#                  jest zatrzymany, uruchomi go: bez działającego Redis nie da się
#                  sprawdzić, które hasło jest poprawne)
#   --reset        wymuś nowe hasło Redis nawet jeśli któreś z obecnych działa
#   --dump         wypisz surowe dowody (kontener, unit, redis.conf, procesy) i zakończ;
#                  hasła są maskowane, chyba że dodasz --show-secrets
#   --show-secrets wypisz hasła jawnie (domyślnie tylko skrót sha256 i długość)
#   --yes          nie pytaj o potwierdzenie
#
# Skąd ten błąd:
#   Hasła do Redis NIE pochodzą z naszych skryptów — generuje je instalator
#   mirror-registry. WRONGPASS oznacza dokładnie jedno: hasło zapisane w
#   config.yaml Quay (BUILDLOGS_REDIS / USER_EVENTS_REDIS) jest inne niż hasło,
#   z którym faktycznie wystartował kontener quay-redis.
#
# Gdzie skrypt szuka hasła Redis:
#   kontener : zmienna REDIS_PASSWORD, argumenty "podman run" (CreateCommand),
#              wiersze poleceń procesów w kontenerze (--requirepass),
#              pliki redis.conf widoczne w kontenerze (requirepass)
#   host     : quay-redis.service (-e/--env REDIS_PASSWORD=, Environment=,
#              --requirepass, --env-file) oraz pliki konfiguracyjne
#              podmontowane do kontenera (bind mount)
#
# Dane w Redis (logi buildów, zdarzenia UI) są ulotne — restart nic nie niszczy.
# Zmirrorowane obrazy leżą w quayStorage i NIE są ruszane.
#
# Kod wyjścia: 0 = OK, 2 = błąd

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

VARS_FILE=""
CONFIG_YAML=""
PLAN_ONLY=0
FORCE_RESET=0
SHOW_SECRETS=0
DUMP_ONLY=0
ASSUME_YES=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) VARS_FILE="$2"; shift 2 ;;
        -c) CONFIG_YAML="$2"; shift 2 ;;
        --plan) PLAN_ONLY=1; shift ;;
        --reset) FORCE_RESET=1; shift ;;
        --dump) DUMP_ONLY=1; shift ;;
        --show-secrets) SHOW_SECRETS=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Nieznana opcja: $1"; usage 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Uruchom przez sudo: sudo $0 $*"
require_cmd podman jq python3 systemctl
require_pyyaml

REDIS_UNIT="/etc/systemd/system/quay-redis.service"
APP_UNIT="/etc/systemd/system/quay-app.service"

# skrót hasła do bezpiecznego porównywania w logu
fp() {
    local v="$1"
    [[ -z "$v" ]] && { echo "<puste>"; return; }
    if (( SHOW_SECRETS )); then echo "$v"; else
        echo "sha256:$(printf '%s' "$v" | sha256sum | cut -c1-12) (dł. ${#v})"
    fi
}
# systemd traktuje %% jako literalne % — przy czytaniu unitu trzeba to odwrócić
unescape_systemd() { printf '%s' "${1//%%/%}"; }

log_header "DIAGNOZA REDIS W MINI QUAY$( (( PLAN_ONLY )) && echo ' (PLAN)')"

# ---------------------------------------------------------------------------
# 1. config.yaml Quay
# ---------------------------------------------------------------------------
log_section "1. Konfiguracja Quay"

# a) wskazana wprost, b) z kontenera quay-app, c) z unitu quay-app (działa też gdy
#    kontener jest w pętli restartów), d) z vars, e) typowe lokalizacje
if [[ -z "$CONFIG_YAML" ]] && podman container exists quay-app 2>/dev/null; then
    src=$(podman inspect quay-app \
        | jq -r '.[0].Mounts[] | select(.Destination == "/quay-registry/conf/stack") | .Source' | head -1) || true
    [[ -n "${src:-}" && -f "$src/config.yaml" ]] && CONFIG_YAML="$src/config.yaml"
fi
if [[ -z "$CONFIG_YAML" && -f "$APP_UNIT" ]]; then
    src=$(grep -oP '(?<=-v )\S+(?=:/quay-registry/conf/stack)' "$APP_UNIT" | head -1) || true
    [[ -n "${src:-}" && -f "$src/config.yaml" ]] && CONFIG_YAML="$src/config.yaml"
fi
if [[ -z "$CONFIG_YAML" && -n "$VARS_FILE" ]]; then
    qr=$(expand_path "$(cfg registry.quayRoot "/root/quay-install")")
    [[ -f "$qr/quay-config/config.yaml" ]] && CONFIG_YAML="$qr/quay-config/config.yaml"
fi
if [[ -z "$CONFIG_YAML" ]]; then
    for c in /data/*/quay-install/quay-config/config.yaml /etc/quay-install/quay-config/config.yaml \
             /root/quay-install/quay-config/config.yaml; do
        [[ -f "$c" ]] && { CONFIG_YAML="$c"; break; }
    done
fi
[[ -n "$CONFIG_YAML" && -f "$CONFIG_YAML" ]] \
    || die "Nie znaleziono config.yaml Quay. Wskaż go: -c <quayRoot>/quay-config/config.yaml"
log_ok "config.yaml: $CONFIG_YAML"

read_cfg_redis() {   # read_cfg_redis <KLUCZ> <pole> — pusto, gdy brak
    python3 - "$CONFIG_YAML" "$1" "$2" <<'PY'
import sys, yaml
path, key, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
block = cfg.get(key)
if isinstance(block, dict) and block.get(field) is not None:
    print(block[field])
PY
}

CFG_BUILDLOGS_PW=$(read_cfg_redis BUILDLOGS_REDIS password)
CFG_USEREVENTS_PW=$(read_cfg_redis USER_EVENTS_REDIS password)
R_HOST=$(read_cfg_redis BUILDLOGS_REDIS host); R_HOST="${R_HOST:-localhost}"
R_PORT=$(read_cfg_redis BUILDLOGS_REDIS port); R_PORT="${R_PORT:-6379}"

log_info "BUILDLOGS_REDIS   : ${R_HOST}:${R_PORT}, hasło $(fp "$CFG_BUILDLOGS_PW")"
log_info "USER_EVENTS_REDIS : hasło $(fp "$CFG_USEREVENTS_PW")"
if [[ "$CFG_BUILDLOGS_PW" != "$CFG_USEREVENTS_PW" ]]; then
    log_warn "BUILDLOGS_REDIS i USER_EVENTS_REDIS mają RÓŻNE hasła — w mirror-registry powinny być identyczne"
fi

# ---------------------------------------------------------------------------
# 2. Kontener quay-redis i wszystkie miejsca, gdzie może być hasło
# ---------------------------------------------------------------------------
log_section "2. Skąd Redis bierze hasło"

[[ -f "$REDIS_UNIT" ]] || log_warn "Brak $REDIS_UNIT — instalacja niekompletna?"

ensure_redis_running() {
    if podman container exists quay-redis 2>/dev/null \
       && [[ "$(podman inspect quay-redis --format '{{.State.Status}}')" == "running" ]]; then
        return 0
    fi
    log_info "quay-redis nie działa — uruchamiam (quay-pod, quay-redis); bez tego nie sprawdzę hasła"
    systemctl start quay-pod 2>/dev/null || true
    systemctl start quay-redis 2>/dev/null || true
    local end=$((SECONDS + 60))
    until podman container exists quay-redis 2>/dev/null \
          && [[ "$(podman inspect quay-redis --format '{{.State.Status}}')" == "running" ]]; do
        (( SECONDS < end )) || return 1
        sleep 3
    done
}
ensure_redis_running || die "Nie udało się uruchomić quay-redis. Sprawdź: systemctl status quay-redis; journalctl -u quay-redis -n 50"
log_ok "quay-redis: running (obraz $(podman inspect quay-redis --format '{{.ImageName}}'))"

# --- kandydaci na hasło (kolejność = kolejność sprawdzania) -----------------
CAND_PW=(); CAND_DESC=()
add_cand() {   # add_cand <hasło> <opis> — pomija puste i duplikaty
    local pw="$1" desc="$2" e
    [[ -n "$pw" ]] || return 0
    for e in ${CAND_PW[@]+"${CAND_PW[@]}"}; do [[ "$e" == "$pw" ]] && return 0; done
    CAND_PW+=("$pw"); CAND_DESC+=("$desc")
    log_info "znaleziono hasło — $desc: $(fp "$pw")"
}

# 2a. kontener: zmienne środowiskowe
CT_ENV=$(podman inspect quay-redis --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null) || CT_ENV=""
add_cand "$(sed -n 's/^REDIS_PASSWORD=//p' <<<"$CT_ENV" | head -1)" "kontener: REDIS_PASSWORD"

# 2b. kontener: argumenty "podman run" oraz Cmd/Entrypoint obrazu
scan_args_for_requirepass() {   # czyta JSON-ową listę argumentów ze stdin
    python3 -c '
import json, sys
try: a = json.load(sys.stdin) or []
except Exception: a = []
a = [str(x) for x in a]
for i, v in enumerate(a):
    if v == "--requirepass" and i + 1 < len(a): print(a[i + 1]); break
    if v.startswith("--requirepass="): print(v.split("=", 1)[1]); break
'
}
for f in '{{json .Config.CreateCommand}}' '{{json .Config.Cmd}}' '{{json .Config.Entrypoint}}'; do
    val=$(podman inspect quay-redis --format "$f" 2>/dev/null | scan_args_for_requirepass) || val=""
    add_cand "$val" "kontener: --requirepass w ${f//[\{\}.jsonCfig ]/}"
done

# 2c. kontener: wiersze poleceń działających procesów (redis-server --requirepass ...)
CT_CMDLINES=$(podman exec quay-redis sh -c '
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        tr "\0" "\n" < "$d/cmdline" 2>/dev/null
        echo "==="
    done' 2>/dev/null) || CT_CMDLINES=""
add_cand "$(awk '/^--requirepass=/{sub(/^--requirepass=/,""); print; exit}
                 /^--requirepass$/{getline; print; exit}' <<<"$CT_CMDLINES")" \
         "kontener: --requirepass w wierszu poleceń procesu"

# 2d. kontener: pliki redis.conf (ścieżki z wiersza poleceń + typowe lokalizacje)
CONF_PATHS=$( { grep -E '\.conf$' <<<"$CT_CMDLINES" || true
                printf '%s\n' /etc/redis.conf /etc/redis/redis.conf /opt/app-root/etc/redis.conf \
                              /var/lib/redis/redis.conf /usr/share/container-scripts/redis/redis.conf
              } | awk 'NF && !seen[$0]++')
# wartość z wiersza "requirepass <hasło>" (obsługa cudzysłowów)
conf_requirepass() { sed -n 's/^[[:space:]]*requirepass[[:space:]]\+//p' | tail -1 | sed 's/^["'"'"']//; s/["'"'"']$//'; }
REDIS_CONF_FOUND=""
while read -r p; do
    [[ -n "$p" ]] || continue
    txt=$(podman exec quay-redis sh -c "cat '$p' 2>/dev/null" 2>/dev/null) || txt=""
    [[ -n "$txt" ]] || continue
    val=$(conf_requirepass <<<"$txt")
    if [[ -n "$val" ]]; then
        REDIS_CONF_FOUND="$p"
        add_cand "$val" "kontener: requirepass w $p"
    fi
done <<<"$CONF_PATHS"

# 2e. host: unit systemd — -e/--env REDIS_PASSWORD=, Environment=, --requirepass, --env-file
UNIT_TXT=""
if [[ -f "$REDIS_UNIT" ]]; then
    UNIT_TXT=$(cat "$REDIS_UNIT")
    for pat in '(?<=-e )REDIS_PASSWORD=\K[^"'"'"'\s]+' '(?<=--env )REDIS_PASSWORD=\K[^"'"'"'\s]+' \
               '(?<=-e ")REDIS_PASSWORD=\K[^"]+' '(?<=--env=)REDIS_PASSWORD=\K[^"'"'"'\s]+' \
               '(?<=^Environment=)REDIS_PASSWORD=\K\S+' '(?<=--requirepass )\K[^"'"'"'\s]+' \
               '(?<=--requirepass=)\K[^"'"'"'\s]+'; do
        val=$(grep -oP "$pat" <<<"$UNIT_TXT" | head -1) || val=""
        add_cand "$(unescape_systemd "$val")" "unit: $REDIS_UNIT"
    done
    # --env-file: hasło w osobnym pliku (podman czyta go wprost, bez %%)
    ENV_FILE=$(grep -oP '(?<=--env-file[= ])\S+' <<<"$UNIT_TXT" | head -1) || ENV_FILE=""
    if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
        add_cand "$(sed -n 's/^REDIS_PASSWORD=//p' "$ENV_FILE" | head -1 | sed 's/^["'"'"']//; s/["'"'"']$//')" \
                 "host: $ENV_FILE (--env-file)"
    fi
fi

# 2f. host: pliki podmontowane do kontenera (bind mount) zawierające requirepass
HOST_CONF=""
MOUNTS=$(podman inspect quay-redis | jq -r '.[0].Mounts[]? | [.Type, .Source, .Destination] | @tsv') || MOUNTS=""
while IFS=$'\t' read -r mtype msrc mdst; do
    [[ "$mtype" == "bind" && -n "$msrc" ]] || continue
    while read -r hf; do
        [[ -f "$hf" ]] || continue
        val=$(conf_requirepass <"$hf") || val=""
        if [[ -n "$val" ]]; then
            HOST_CONF="$hf"
            add_cand "$val" "host: requirepass w $hf (montowane jako $mdst)"
        fi
    done < <(if [[ -f "$msrc" ]]; then echo "$msrc"; else find "$msrc" -maxdepth 2 -type f -name '*.conf' 2>/dev/null; fi)
done <<<"$MOUNTS"

# 2g. na końcu hasła z config.yaml — sprawdzamy je jako pierwsze, ale dodajemy tu,
#     żeby komunikat "znaleziono hasło" dotyczył tylko źródeł po stronie Redis
if [[ -n "$CFG_BUILDLOGS_PW" ]]; then
    CAND_PW=("$CFG_BUILDLOGS_PW" ${CAND_PW[@]+"${CAND_PW[@]}"})
    CAND_DESC=("hasło z config.yaml (BUILDLOGS_REDIS)" ${CAND_DESC[@]+"${CAND_DESC[@]}"})
fi
if [[ -n "$CFG_USEREVENTS_PW" && "$CFG_USEREVENTS_PW" != "$CFG_BUILDLOGS_PW" ]]; then
    CAND_PW+=("$CFG_USEREVENTS_PW"); CAND_DESC+=("hasło z config.yaml (USER_EVENTS_REDIS)")
fi

if (( ${#CAND_PW[@]} == 0 )); then
    log_error "Nie znalazłem żadnego hasła — ani w config.yaml, ani po stronie Redis"
elif [[ -n "$CFG_BUILDLOGS_PW" ]] && (( ${#CAND_PW[@]} == 1 )); then
    log_warn "Poza config.yaml nie znalazłem hasła Redis w żadnym ze sprawdzanych miejsc"
fi

# ---------------------------------------------------------------------------
# Dowody — do wklejenia, gdy trzeba dojść, skąd Redis bierze hasło
# ---------------------------------------------------------------------------
mask() {   # maskuje wszystkie znane hasła w tekście ze stdin
    local i out; out=$(cat)
    if (( ! SHOW_SECRETS )); then
        for i in ${CAND_PW[@]+"${CAND_PW[@]}"}; do
            [[ ${#i} -ge 6 ]] && out="${out//"$i"/<hasło $(fp "$i")>}"
        done
    fi
    printf '%s\n' "$out"
}
dump_evidence() {
    log_section "DOWODY (hasła zamaskowane$( (( SHOW_SECRETS )) && echo ' — WYŁĄCZONE przez --show-secrets'))"
    echo "--- podman inspect quay-redis: Env / CreateCommand / Cmd / Entrypoint ---"
    podman inspect quay-redis --format '{{json .Config.Env}}{{"\n"}}{{json .Config.CreateCommand}}{{"\n"}}{{json .Config.Cmd}}{{"\n"}}{{json .Config.Entrypoint}}' 2>&1 | mask | sed 's/^/  /'
    echo "--- podman inspect quay-redis: Mounts ---"
    printf '%s\n' "${MOUNTS:-<brak>}" | mask | sed 's/^/  /'
    echo "--- procesy w kontenerze ---"
    printf '%s\n' "${CT_CMDLINES:-<brak>}" | tr '\n' ' ' | sed 's/=== /\n  /g' | mask
    echo "--- unit $REDIS_UNIT ---"
    printf '%s\n' "${UNIT_TXT:-<brak pliku>}" | grep -E '^(Exec|Environment)' | mask | sed 's/^/  /'
    echo "--- redis.conf widoczne w kontenerze (linie requirepass / include / aclfile) ---"
    while read -r p; do
        [[ -n "$p" ]] || continue
        out=$(podman exec quay-redis sh -c "grep -nEs '^[[:space:]]*(requirepass|include|aclfile|user )' '$p' 2>/dev/null" 2>/dev/null) || out=""
        [[ -n "$out" ]] && { echo "  [$p]"; mask <<<"$out" | sed 's/^/    /'; }
    done <<<"$CONF_PATHS"
    echo "--- pod i sieć ---"
    podman ps --filter pod=quay-pod --format '  {{.Names}}  {{.Status}}  {{.Ports}}' 2>/dev/null || true
}

if (( DUMP_ONLY )); then
    dump_evidence
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Realny test AUTH
# ---------------------------------------------------------------------------
log_section "3. Test logowania do Redis (${R_HOST}:${R_PORT})"

REDIS_OUT=""
redis_ping() {   # redis_ping <hasło|""> — 0 gdy PONG
    local pw="$1" out=""
    if [[ -z "$pw" ]]; then
        out=$(podman exec quay-redis redis-cli -h "$R_HOST" -p "$R_PORT" PING 2>&1) || true
    else
        # REDISCLI_AUTH nie pokazuje hasła w liście procesów kontenera
        out=$(podman exec -e REDISCLI_AUTH="$pw" quay-redis \
                redis-cli -h "$R_HOST" -p "$R_PORT" PING 2>&1) || true
        if ! grep -q 'PONG' <<<"$out"; then
            out=$(podman exec quay-redis redis-cli --no-auth-warning \
                    -h "$R_HOST" -p "$R_PORT" -a "$pw" PING 2>&1) || true
        fi
    fi
    REDIS_OUT=$(tr -d '\r' <<<"$out" | tr '\n' ' ')
    grep -q 'PONG' <<<"$out"
}

podman exec quay-redis sh -c 'command -v redis-cli' >/dev/null 2>&1 \
    || die "W kontenerze quay-redis nie ma redis-cli — nie mogę zweryfikować hasła.
       Podaj wynik: sudo podman exec quay-redis redis-cli PING"

NOAUTH=0
if redis_ping ""; then
    NOAUTH=1
    log_warn "Redis odpowiada BEZ hasła, a config.yaml hasło podaje — dlatego Quay dostaje błąd"
else
    # rozróżniamy "wymaga hasła" od "nie da się połączyć" — to zupełnie inne problemy
    if grep -qi 'NOAUTH\|WRONGPASS\|Authentication required' <<<"$REDIS_OUT"; then
        log_info "Redis wymaga hasła (spodziewane): ${REDIS_OUT:0:80}"
    else
        log_error "Redis nie odpowiada na PING bez hasła, ale też nie żąda hasła: ${REDIS_OUT:0:160}"
        log_info "To nie wygląda na problem z hasłem — sprawdź, czy quay-redis nasłuchuje na ${R_HOST}:${R_PORT}"
    fi
fi

WORKING_PW=""; WORKING_SRC=""
for i in "${!CAND_PW[@]}"; do
    [[ -n "$WORKING_PW" ]] && break
    if redis_ping "${CAND_PW[$i]}"; then
        WORKING_PW="${CAND_PW[$i]}"; WORKING_SRC="${CAND_DESC[$i]}"
        log_ok "${CAND_DESC[$i]} — AUTH OK (PONG)"
    else
        # nieudany kandydat to normalny wynik diagnozy — nie podbijamy licznika błędów
        echo -e "  ${RED}[nie]${RESET}  ${CAND_DESC[$i]} — ${REDIS_OUT:0:150}"
    fi
done

# ---------------------------------------------------------------------------
# 4. Rozpoznanie
# ---------------------------------------------------------------------------
log_section "4. Rozpoznanie"

NEED_FIX=0
if (( NOAUTH )) && [[ -n "$CFG_BUILDLOGS_PW" ]]; then
    log_error "Redis działa bez hasła, Quay wysyła hasło → trzeba usunąć hasło z config.yaml albo ustawić je w Redis"
    NEED_FIX=1; FORCE_RESET=1
elif [[ -n "$WORKING_PW" && "$WORKING_PW" == "$CFG_BUILDLOGS_PW" && "$CFG_BUILDLOGS_PW" == "$CFG_USEREVENTS_PW" ]]; then
    log_ok "Hasło z config.yaml działa — przyczyną nie jest niezgodność haseł"
    log_info "Jeśli quay-app nadal nie wstaje, sprawdź: journalctl -u quay-app -n 100 --no-pager"
elif [[ -n "$WORKING_PW" ]]; then
    log_error "Niezgodność haseł: config.yaml ≠ hasło działającego Redis (działa: $WORKING_SRC)"
    NEED_FIX=1
else
    log_error "Żadne ze znalezionych haseł nie pasuje do działającego Redis"
    log_info "Redis ma hasło, którego nie ma ani w unicie, ani w kontenerze — najpewniej"
    log_info "kontener quay-redis został z poprzedniej instalacji (stare hasło w pamięci/konfiguracji)."
    log_info "Naprawa polega wtedy na odtworzeniu samego kontenera Redis z nowym hasłem."
    NEED_FIX=1; FORCE_RESET=1
fi

if (( PLAN_ONLY )); then
    (( NEED_FIX )) && dump_evidence
    log_header "PLAN — nic nie zostało zmienione"
    (( NEED_FIX )) && echo "  Naprawa: sudo $0${VARS_FILE:+ -f $VARS_FILE}${CONFIG_YAML:+ -c $CONFIG_YAML}$( (( FORCE_RESET )) && echo ' --reset' )"
    exit 0
fi
if (( ! NEED_FIX && ! FORCE_RESET )); then
    log_header "GOTOWE — nic do naprawy (ostrzeżenia: ${WARNINGS})"
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. Naprawa
# ---------------------------------------------------------------------------
log_section "5. Naprawa"

# Od tego miejsca licznik dotyczy samej naprawy (błędy z diagnozy już opisaliśmy)
ERRORS=0; WARNINGS=0

set_cfg_redis_password() {   # set_cfg_redis_password <nowe_hasło>
    python3 - "$CONFIG_YAML" "$1" <<'PY'
import sys, os, stat, tempfile, yaml
path, newpw = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
changed = []
for key in ("BUILDLOGS_REDIS", "USER_EVENTS_REDIS"):
    blk = cfg.get(key)
    if isinstance(blk, dict):
        if blk.get("password") != newpw:
            blk["password"] = newpw
            changed.append(key)
    else:
        print("BRAK_BLOKU:" + key, file=sys.stderr)
st = os.stat(path)
d = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(dir=d)
with os.fdopen(fd, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
os.chmod(tmp, stat.S_IMODE(st.st_mode))
os.chown(tmp, st.st_uid, st.st_gid)
os.replace(tmp, path)
print(",".join(changed))
PY
}

# Wpisuje hasło w unicie / pliku --env-file / podmontowanym redis.conf.
# Zwraca opis zmienionego miejsca; kod 1 = nie ma gdzie wpisać.
set_host_redis_password() {   # set_host_redis_password <nowe_hasło> <plik_unitu> <host_conf>
    python3 - "$1" "$2" "$3" <<'PY'
import os, re, sys
newpw, unit, hostconf = sys.argv[1], sys.argv[2], sys.argv[3]
esc = newpw.replace("%", "%%")          # w unicie systemd %% oznacza literalne %
src = ""
if unit and os.path.isfile(unit):
    src = open(unit).read()
    out = src
    n = 0
    for pat in (r'((?:-e|--env)[= ]"?REDIS_PASSWORD=)([^"\s]+)', r'(--requirepass[= ])([^"\s]+)',
                r'(?m)^(Environment=REDIS_PASSWORD=)(\S+)'):
        out, k = re.subn(pat, lambda m: m.group(1) + esc, out)
        n += k
    if n:
        open(unit, "w").write(out)
        print("%s (%d miejsc)" % (unit, n)); sys.exit(0)
    # --env-file: podman czyta ten plik wprost, więc bez %%
    m = re.search(r'--env-file[= ](\S+)', src)
    if m and os.path.isfile(m.group(1)):
        p = m.group(1)
        env, k = re.subn(r'(?m)^(REDIS_PASSWORD=).*$', lambda mm: mm.group(1) + newpw, open(p).read())
        if k:
            open(p, "w").write(env); print(p); sys.exit(0)
# podmontowany redis.conf na hoście
if hostconf and os.path.isfile(hostconf):
    conf, k = re.subn(r'(?m)^([ \t]*requirepass[ \t]+).*$', lambda mm: mm.group(1) + newpw, open(hostconf).read())
    if k:
        open(hostconf, "w").write(conf); print(hostconf); sys.exit(0)
sys.exit(1)
PY
}

BACKUP_CFG="${CONFIG_YAML}.bak-$(timestamp)"
cp -a "$CONFIG_YAML" "$BACKUP_CFG"
log_ok "Kopia konfiguracji: $BACKUP_CFG"

if (( FORCE_RESET )); then
    NEW_PW=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(32)))')
    log_info "Ustawiam NOWE hasło Redis w config.yaml i w Redis: $(fp "$NEW_PW")"
    confirm "Odtworzyć kontener quay-redis z nowym hasłem i zrestartować quay-app?" \
        || die "Przerwano — nic nie zostało zmienione (poza kopią $BACKUP_CFG)"

    systemctl stop quay-app 2>/dev/null || true

    if HOST_PATCHED=$(set_host_redis_password "$NEW_PW" "$REDIS_UNIT" "$HOST_CONF"); then
        log_ok "Zaktualizowano hasło po stronie hosta: $HOST_PATCHED"
        systemctl daemon-reload
        systemctl stop quay-redis 2>/dev/null || true
        podman rm -f quay-redis >/dev/null 2>&1 || true
        systemctl start quay-redis
    else
        # Nigdzie na hoście nie ma hasła => kontener dostał je przy "podman run" i od tamtej
        # pory nikt go nie zapisał. Odtwarzamy kontener z tymi samymi parametrami + REDIS_PASSWORD.
        log_warn "Hasła nie ma ani w $REDIS_UNIT, ani w podmontowanej konfiguracji"
        log_info "Odtwarzam kontener quay-redis z jego własnych parametrów + REDIS_PASSWORD"
        RECREATE=$(podman inspect quay-redis --format '{{json .Config.CreateCommand}}' \
            | python3 -c '
import json, sys
a = [str(x) for x in (json.load(sys.stdin) or [])]
print(json.dumps(a))
') || RECREATE="[]"
        [[ "$RECREATE" != "[]" ]] \
            || die "Nie mam z czego odtworzyć kontenera (pusty CreateCommand).
       Pokaż dowody i zdecydujemy ręcznie: sudo $0${VARS_FILE:+ -f $VARS_FILE} --dump
       Ostatecznie zadziała czysta reinstalacja: bin/02a-reinstall-quay.sh"
        mapfile -t RUN_ARGS < <(python3 - "$RECREATE" "$NEW_PW" <<'PY'
import json, sys
a = json.loads(sys.argv[1]); newpw = sys.argv[2]
# usuwamy stare REDIS_PASSWORD/--requirepass, dokładamy nowe tuż po "run"
out, i = [], 0
while i < len(a):
    v = a[i]
    if v in ("-e", "--env") and i + 1 < len(a) and a[i + 1].startswith("REDIS_PASSWORD="):
        i += 2; continue
    if v.startswith(("-e=REDIS_PASSWORD=", "--env=REDIS_PASSWORD=")):
        i += 1; continue
    if v == "--requirepass" and i + 1 < len(a):
        i += 2; continue
    if v.startswith("--requirepass="):
        i += 1; continue
    out.append(v); i += 1
if out and out[0].endswith("podman"):
    out[0] = "podman"
try:
    j = out.index("run")
except ValueError:
    j = 0
out[j + 1:j + 1] = ["-e", "REDIS_PASSWORD=" + newpw]
if "-d" not in out and "--detach" not in out:
    out[j + 1:j + 1] = ["-d"]
print("\n".join(out))
PY
)
        systemctl stop quay-redis 2>/dev/null || true
        podman rm -f quay-redis >/dev/null 2>&1 || true
        log_info "Uruchamiam: ${RUN_ARGS[0]} ${RUN_ARGS[1]} ... (${#RUN_ARGS[@]} argumentów)"
        "${RUN_ARGS[@]}" >/dev/null || die "Nie udało się odtworzyć kontenera quay-redis.
       Pokaż dowody: sudo $0${VARS_FILE:+ -f $VARS_FILE} --dump"
        log_warn "Kontener odtworzony poza systemd — po restarcie bastionu sprawdź: systemctl status quay-redis"
    fi

    ensure_redis_running || die "quay-redis nie wstał po zmianie hasła — journalctl -u quay-redis -n 50"
    redis_ping "$NEW_PW" || die "Redis nadal nie przyjmuje nowego hasła: ${REDIS_OUT:0:200}
       Kopia poprzedniego config.yaml: $BACKUP_CFG"
    log_ok "Redis przyjmuje nowe hasło (PONG)"
    changed=$(set_cfg_redis_password "$NEW_PW")
    log_ok "Zaktualizowano config.yaml${changed:+ (${changed})}"
else
    log_info "Wyrównuję config.yaml do hasła działającego Redis ($WORKING_SRC)"
    confirm "Zapisać to hasło w config.yaml i zrestartować quay-app?" \
        || die "Przerwano — nic nie zostało zmienione (poza kopią $BACKUP_CFG)"
    changed=$(set_cfg_redis_password "$WORKING_PW")
    log_ok "Zaktualizowano config.yaml${changed:+ (${changed})}"
    systemctl stop quay-app 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 6. Start Quay i weryfikacja
# ---------------------------------------------------------------------------
log_section "6. Start quay-app"

systemctl start quay-app
log_info "Quay wstaje zwykle 1-2 min (migracje bazy) — czekam maks. 4 min"
START_WAIT=$SECONDS; end=$((SECONDS + 240)); next_note=$((SECONDS + 60))
while (( SECONDS < end )); do
    APP_STATE=$(systemctl is-active quay-app 2>/dev/null || true)
    [[ "$APP_STATE" == "failed" ]] && break
    if [[ "$APP_STATE" == "active" ]] && podman container exists quay-app 2>/dev/null \
       && [[ "$(podman inspect quay-app --format '{{.State.Status}}')" == "running" ]]; then
        # kontener musi przeżyć 30 s — inaczej to tylko kolejny obrót pętli restartów
        sleep 30
        [[ "$(systemctl is-active quay-app 2>/dev/null || true)" == "active" ]] && break
    fi
    if (( SECONDS >= next_note )); then
        log_info "  ... quay-app: ${APP_STATE:-?} ($((SECONDS - START_WAIT)) s)"
        next_note=$((SECONDS + 60))
    fi
    sleep 5
done

if podman logs --tail 200 quay-app 2>&1 | grep -qi 'WRONGPASS\|Could not connect to Redis'; then
    log_error "W logach quay-app nadal jest błąd Redis"
    podman logs --tail 50 quay-app 2>&1 | grep -i 'redis' | tail -5 | sed 's/^/      /'
    die "Naprawa nie zadziałała. Kopia poprzedniej konfiguracji: $BACKUP_CFG
       Pokaż dowody: sudo $0${VARS_FILE:+ -f $VARS_FILE} --dump
       Oraz: sudo journalctl -u quay-app -n 100 --no-pager"
fi

if [[ "$(systemctl is-active quay-app 2>/dev/null || true)" == "active" ]]; then
    log_ok "quay-app: active, brak błędów Redis w logach"
else
    log_error "quay-app: $(systemctl is-active quay-app 2>/dev/null || echo '?') — sprawdź: journalctl -u quay-app -n 100 --no-pager"
fi

for svc in quay-pod quay-redis quay-app; do
    log_info "$svc: $(systemctl is-active "$svc" 2>/dev/null || echo '?'), $(systemctl is-enabled "$svc" 2>/dev/null || echo '?')"
done

log_header "GOTOWE — ostrzeżenia: ${WARNINGS}, błędy: ${ERRORS}"
cat <<EOF
  Kopia poprzedniego config.yaml : $BACKUP_CFG
  Kontrola                       : bin/00-inspect-quay.sh ${VARS_FILE:+-f $VARS_FILE}

  Uwaga: config.yaml został przepisany przez parser YAML — wartości są te same,
  ale komentarze i formatowanie mogły się zmienić. Oryginał jest w kopii powyżej.
EOF
(( ERRORS == 0 )) || exit 2
