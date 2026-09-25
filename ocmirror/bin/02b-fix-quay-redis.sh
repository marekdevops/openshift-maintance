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
#   --reset        wymuś nowe hasło Redis (config.yaml + usługa quay-redis) nawet jeśli
#                  któreś z obecnych haseł działa
#   --show-secrets wypisz hasła jawnie (domyślnie tylko skrót sha256 i długość)
#   --yes          nie pytaj o potwierdzenie
#
# Skąd ten błąd:
#   Hasła do Redis NIE pochodzą z naszych skryptów — generuje je instalator
#   mirror-registry. WRONGPASS oznacza dokładnie jedno: hasło zapisane w
#   config.yaml Quay (BUILDLOGS_REDIS / USER_EVENTS_REDIS) jest inne niż hasło,
#   z którym faktycznie wystartował kontener quay-redis.
#
# Co robi skrypt:
#   1. Znajduje config.yaml Quay i usługę/kontener quay-redis
#   2. Zbiera kandydatów na hasło: z config.yaml, z kontenera, z unitu systemd
#   3. Sprawdza każde hasło realnym AUTH do Redis (redis-cli PING)
#   4. Naprawia: albo wyrównuje config.yaml do działającego hasła Redis,
#      albo (--reset / brak działającego hasła) ustawia nowe hasło w obu miejscach
#   5. Restartuje quay-app i czeka, aż wstanie
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
ASSUME_YES=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) VARS_FILE="$2"; shift 2 ;;
        -c) CONFIG_YAML="$2"; shift 2 ;;
        --plan) PLAN_ONLY=1; shift ;;
        --reset) FORCE_RESET=1; shift ;;
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
#    kontener jest w pętli restartów i nie istnieje), d) z vars, e) typowe lokalizacje
if [[ -z "$CONFIG_YAML" ]] && podman container exists quay-app 2>/dev/null; then
    src=$(podman inspect quay-app \
        | jq -r '.[0].Mounts[] | select(.Destination == "/quay-registry/conf/stack") | .Source' | head -1)
    [[ -n "$src" && -f "$src/config.yaml" ]] && CONFIG_YAML="$src/config.yaml"
fi
if [[ -z "$CONFIG_YAML" && -f "$APP_UNIT" ]]; then
    src=$(grep -oP '(?<=-v )\S+(?=:/quay-registry/conf/stack)' "$APP_UNIT" | head -1 || true)
    [[ -n "$src" && -f "$src/config.yaml" ]] && CONFIG_YAML="$src/config.yaml"
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
# 2. Kontener i usługa quay-redis
# ---------------------------------------------------------------------------
log_section "2. Usługa quay-redis"

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

# Hasło, z którym kontener faktycznie wystartował
CT_ENV_PW=$(podman inspect quay-redis --format '{{range .Config.Env}}{{println .}}{{end}}' \
            | sed -n 's/^REDIS_PASSWORD=//p' | head -1 || true)
CT_ARG_PW=$(podman inspect quay-redis --format '{{json .Config.CreateCommand}}' 2>/dev/null \
            | python3 -c '
import json,sys
try: a=json.load(sys.stdin) or []
except Exception: a=[]
for i,v in enumerate(a):
    if v=="--requirepass" and i+1<len(a): print(a[i+1]); break
    if v.startswith("--requirepass="): print(v.split("=",1)[1]); break
' || true)

# Hasło zapisane w unicie systemd (może się różnić od działającego kontenera,
# np. gdy kontener został uruchomiony przed edycją unitu)
UNIT_ENV_PW=""; UNIT_ARG_PW=""
if [[ -f "$REDIS_UNIT" ]]; then
    UNIT_ENV_PW=$(grep -oP '(?<=-e REDIS_PASSWORD=)\S+' "$REDIS_UNIT" | head -1 || true)
    UNIT_ARG_PW=$(grep -oP '(?<=--requirepass[= ])\S+' "$REDIS_UNIT" | head -1 || true)
    UNIT_ENV_PW=$(unescape_systemd "$UNIT_ENV_PW")
    UNIT_ARG_PW=$(unescape_systemd "$UNIT_ARG_PW")
fi

[[ -n "$CT_ENV_PW"   ]] && log_info "kontener  REDIS_PASSWORD : $(fp "$CT_ENV_PW")"
[[ -n "$CT_ARG_PW"   ]] && log_info "kontener  --requirepass  : $(fp "$CT_ARG_PW")"
[[ -n "$UNIT_ENV_PW" ]] && log_info "unit      REDIS_PASSWORD : $(fp "$UNIT_ENV_PW")"
[[ -n "$UNIT_ARG_PW" ]] && log_info "unit      --requirepass  : $(fp "$UNIT_ARG_PW")"
[[ -z "$CT_ENV_PW$CT_ARG_PW$UNIT_ENV_PW$UNIT_ARG_PW" ]] \
    && log_warn "Nie znaleziono hasła Redis ani w kontenerze, ani w unicie — sprawdzę tylko hasło z config.yaml"

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
    REDIS_OUT="$out"
    grep -q 'PONG' <<<"$out"
}

# Czy w ogóle da się wykonać redis-cli w kontenerze
if ! podman exec quay-redis sh -c 'command -v redis-cli' >/dev/null 2>&1; then
    die "W kontenerze quay-redis nie ma redis-cli — nie mogę zweryfikować hasła.
       Podaj wynik: sudo podman exec quay-redis redis-cli PING"
fi

WORKING_PW=""; WORKING_SRC=""; NOAUTH=0
try_pw() {   # try_pw <hasło> <opis>
    local pw="$1" desc="$2"
    [[ -n "$pw" ]] || return 0
    [[ -n "$WORKING_PW" ]] && return 0
    if redis_ping "$pw"; then
        WORKING_PW="$pw"; WORKING_SRC="$desc"
        log_ok "$desc — AUTH OK (PONG)"
    else
        # nieudany kandydat to normalny wynik diagnozy — nie podbijamy licznika błędów
        echo -e "  ${RED}[nie]${RESET}  $desc — $(tr -d '\r' <<<"$REDIS_OUT" | tr '\n' ' ' | head -c 160)"
    fi
}

if redis_ping ""; then
    NOAUTH=1
    log_warn "Redis odpowiada BEZ hasła, a config.yaml hasło podaje — dlatego Quay dostaje błąd"
else
    log_info "Redis wymaga hasła (spodziewane)"
fi

try_pw "$CFG_BUILDLOGS_PW" "hasło z config.yaml (BUILDLOGS_REDIS)"
[[ "$CFG_USEREVENTS_PW" != "$CFG_BUILDLOGS_PW" ]] && try_pw "$CFG_USEREVENTS_PW" "hasło z config.yaml (USER_EVENTS_REDIS)"
try_pw "$CT_ENV_PW"   "hasło z kontenera (REDIS_PASSWORD)"
try_pw "$CT_ARG_PW"   "hasło z kontenera (--requirepass)"
try_pw "$UNIT_ENV_PW" "hasło z unitu systemd (REDIS_PASSWORD)"
try_pw "$UNIT_ARG_PW" "hasło z unitu systemd (--requirepass)"

# ---------------------------------------------------------------------------
# 4. Rozpoznanie
# ---------------------------------------------------------------------------
log_section "4. Rozpoznanie"

NEED_FIX=0
if (( NOAUTH )) && [[ -n "$CFG_BUILDLOGS_PW" ]]; then
    log_error "Redis działa bez hasła, Quay wysyła hasło → wymagany reset (--reset)"
    NEED_FIX=1; FORCE_RESET=1
elif [[ -n "$WORKING_PW" && "$WORKING_PW" == "$CFG_BUILDLOGS_PW" && "$CFG_BUILDLOGS_PW" == "$CFG_USEREVENTS_PW" ]]; then
    log_ok "Hasło z config.yaml działa — przyczyną WRONGPASS nie jest już niezgodność haseł"
    log_info "Jeśli quay-app nadal nie wstaje, sprawdź: journalctl -u quay-app -n 100 --no-pager"
elif [[ -n "$WORKING_PW" ]]; then
    log_error "Niezgodność haseł: config.yaml ≠ hasło działającego Redis (działa: $WORKING_SRC)"
    log_info "To klasyczny efekt instalatora mirror-registry: config.yaml i kontener Redis"
    log_info "dostały dwa różne wygenerowane hasła (albo config.yaml został z poprzedniej instalacji)."
    NEED_FIX=1
else
    log_error "Żadne ze znalezionych haseł nie pasuje do działającego Redis → wymagany reset hasła"
    NEED_FIX=1; FORCE_RESET=1
fi

if (( PLAN_ONLY )); then
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

BACKUP_CFG="${CONFIG_YAML}.bak-$(timestamp)"
cp -a "$CONFIG_YAML" "$BACKUP_CFG"
log_ok "Kopia konfiguracji: $BACKUP_CFG"

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

set_unit_redis_password() {   # set_unit_redis_password <nowe_hasło> — 0 gdy podmieniono
    python3 - "$REDIS_UNIT" "$1" <<'PY'
import os, re, sys
path, newpw = sys.argv[1], sys.argv[2]
esc = newpw.replace("%", "%%")          # w unicie systemd %% oznacza literalne %
try:
    src = open(path).read()
except OSError:
    sys.exit(1)
out, n1 = re.subn(r'(-e\s+REDIS_PASSWORD=)(\S+)', lambda m: m.group(1) + esc, src)
out, n2 = re.subn(r'(--requirepass[= ])(\S+)', lambda m: m.group(1) + esc, out)
if n1 + n2:
    open(path, "w").write(out)
    print("%s (%d miejsc)" % (path, n1 + n2))
    sys.exit(0)
# wariant z --env-file: hasło jest w osobnym pliku, ktory podman czyta wprost (bez %%)
m = re.search(r'--env-file[= ](\S+)', src)
if m and os.path.isfile(m.group(1)):
    envpath = m.group(1)
    env, n3 = re.subn(r'(?m)^(REDIS_PASSWORD=).*$', lambda mm: mm.group(1) + newpw, open(envpath).read())
    if n3:
        open(envpath, "w").write(env)
        print(envpath)
        sys.exit(0)
sys.exit(1)
PY
}

if (( FORCE_RESET )); then
    NEW_PW=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(32)))')
    log_info "Ustawiam NOWE hasło Redis w config.yaml i w usłudze quay-redis: $(fp "$NEW_PW")"
    confirm "Zrestartować quay-redis i quay-app z nowym hasłem?" || die "Przerwano — nic nie zostało zmienione"

    if ! UNIT_PATCHED=$(set_unit_redis_password "$NEW_PW"); then
        die "Nie znalazłem miejsca z hasłem Redis (-e REDIS_PASSWORD=, --requirepass ani --env-file) w $REDIS_UNIT.
       Pokaż zawartość unitu: sudo cat $REDIS_UNIT
       Jeśli hasła tam nie ma, najprościej zainstalować Quay od nowa: bin/02a-reinstall-quay.sh"
    fi
    log_ok "Zaktualizowano ${UNIT_PATCHED}"
    changed=$(set_cfg_redis_password "$NEW_PW")
    log_ok "Zaktualizowano config.yaml${changed:+ (${changed})}"

    systemctl daemon-reload
    systemctl stop quay-app 2>/dev/null || true
    systemctl stop quay-redis 2>/dev/null || true
    podman rm -f quay-redis >/dev/null 2>&1 || true
    systemctl start quay-redis
    ensure_redis_running || die "quay-redis nie wstał po zmianie hasła — journalctl -u quay-redis -n 50"
    redis_ping "$NEW_PW" || die "Redis nadal nie przyjmuje nowego hasła: $(tr '\n' ' ' <<<"$REDIS_OUT" | head -c 200)"
    log_ok "Redis przyjmuje nowe hasło (PONG)"
else
    log_info "Wyrównuję config.yaml do hasła działającego Redis ($WORKING_SRC)"
    confirm "Zapisać to hasło w config.yaml i zrestartować quay-app?" || die "Przerwano — nic nie zostało zmienione"
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
    podman logs --tail 30 quay-app 2>&1 | grep -i 'redis' | tail -5 | sed 's/^/      /'
    die "Naprawa nie zadziałała. Kopia poprzedniej konfiguracji: $BACKUP_CFG
       Pokaż: sudo journalctl -u quay-app -n 100 --no-pager"
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
