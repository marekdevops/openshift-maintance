#!/usr/bin/env bash
# 04-mirror.sh — mirror obrazów OpenShift do mini Quay przy użyciu oc-mirror v2.
#
# Użycie:
#   ./04-mirror.sh -f config/mirror-vars.yaml [-c imageset-config.yaml] [--step KROK] [--dry-run]
#
# Opcje:
#   -f PLIK       plik zmiennych (mirror-vars.yaml)
#   -c PLIK       ImageSetConfiguration (domyślnie <mirror.baseDir>/imageset-config.yaml,
#                 generowany przez 03-generate-imageset.py)
#   --step KROK   m2d  — mirror-to-disk: internet -> archiwum na dysku (+ cache)
#                 d2m  — disk-to-mirror: archiwum -> mini Quay
#                 m2m  — mirror-to-mirror: internet -> mini Quay bez archiwum
#                 all  — domyślnie: m2d + d2m (albo m2m, gdy mirror.workflow=m2m)
#   --dry-run     tylko lista obrazów do zmirrorowania (mapping.txt / missing.txt), bez kopiowania
#   --estimate    jak --dry-run, a na koniec oszacowanie rozmiaru: odpytuje rejestry o same
#                 manifesty (bez pobierania warstw) i sumuje warstwy, licząc każdą raz
#
# Struktura katalogów (mirror.baseDir):
#   cache/                 cache oc-mirror — RÓB KOPIĘ po każdym udanym mirrorze
#   archive/               archiwa mirror_*.tar + working-dir (m2d/d2m)
#   workspace/             working-dir dla m2m
#   results/<data>_<wer>/  kopia cluster-resources (IDMS, ITMS, CatalogSource, ...) — do 05-configure-cluster.sh
#   results/latest         dowiązanie do ostatniego wyniku
#   logs/                  logi każdego uruchomienia
#
# Kod wyjścia: 0 = OK, 1 = mirror zakończony, ale z błędami obrazów operatorów, 2 = błąd

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

VARS_FILE=""
ISC=""
STEP="all"
DRY_RUN=0
ESTIMATE=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) VARS_FILE="$2"; shift 2 ;;
        -c) ISC="$2"; shift 2 ;;
        --step) STEP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --estimate) DRY_RUN=1; ESTIMATE=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Nieznana opcja: $1"; usage 1 ;;
    esac
done
[[ -n "$VARS_FILE" ]] || usage 1

require_cmd oc-mirror jq python3 curl
require_pyyaml

REG_HOST=$(cfg registry.host)
REG_NS=$(cfg registry.namespace "ocp")
BASE_DIR=$(expand_path "$(cfg mirror.baseDir)")
AUTH_FILE=$(expand_path "$(cfg mirror.authFile "$BASE_DIR/auth/auth.json")")
WORKFLOW=$(cfg mirror.workflow "m2d-d2m")
PAR_IMAGES=$(cfg mirror.parallelImages 4)
PAR_LAYERS=$(cfg mirror.parallelLayers 5)
TARGET_VERSION=$(cfg platform.targetVersion)
ISC="${ISC:-$BASE_DIR/imageset-config.yaml}"

CACHE_DIR="$BASE_DIR/cache"
ARCHIVE_DIR="$BASE_DIR/archive"
WORKSPACE_DIR="$BASE_DIR/workspace"
RESULTS_DIR="$BASE_DIR/results"
LOG_DIR="$BASE_DIR/logs"
DESTINATION="docker://${REG_HOST}/${REG_NS}"

if [[ "$STEP" == "all" ]]; then
    case "$WORKFLOW" in
        m2d-d2m) STEPS=(m2d d2m) ;;
        m2m)     STEPS=(m2m) ;;
        *)       die "mirror.workflow='$WORKFLOW' — dozwolone: m2d-d2m, m2m" ;;
    esac
else
    [[ "$STEP" =~ ^(m2d|d2m|m2m)$ ]] || die "--step: dozwolone m2d, d2m, m2m, all"
    STEPS=("$STEP")
fi
# Dry-run d2m nie ma sensu bez archiwum; sprawdzamy kompletność na etapie m2d
(( DRY_RUN )) && [[ "${STEPS[*]}" == "m2d d2m" ]] && STEPS=(m2d)

umask 0022                       # wymaganie oc-mirror
mkdir -p "$CACHE_DIR" "$ARCHIVE_DIR" "$WORKSPACE_DIR" "$RESULTS_DIR" "$LOG_DIR"

# oc-mirror v2 otwiera wiele plików równolegle — zbyt niski limit kończy się błędami
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

log_header "OC-MIRROR v2 — kroki: ${STEPS[*]}$( (( DRY_RUN )) && echo ' (DRY-RUN)')"
echo "  ImageSetConfiguration: $ISC"
echo "  Rejestr docelowy     : $DESTINATION"
echo "  Katalog roboczy      : $BASE_DIR"

# ---------------------------------------------------------------------------
# Walidacja wstępna
# ---------------------------------------------------------------------------
log_section "Walidacja wstępna"

[[ -s "$ISC" ]] || die "Brak $ISC — uruchom najpierw 03-generate-imageset.py"
log_ok "ImageSetConfiguration: $(grep -c 'catalog:' "$ISC" || true) katalog(i) operatorów"

[[ -s "$AUTH_FILE" ]] || die "Brak pliku poświadczeń $AUTH_FILE — uruchom 02-setup-bastion.sh"
[[ "$(stat -c '%a' "$AUTH_FILE")" =~ ^6[04]0$ ]] || log_warn "Plik $AUTH_FILE ma zbyt szerokie uprawnienia (zalecane 600)"
for reg in registry.redhat.io quay.io "$REG_HOST"; do
    jq -e --arg r "$reg" '.auths[$r]' "$AUTH_FILE" &>/dev/null || die "Brak poświadczeń dla $reg w $AUTH_FILE"
done
log_ok "Poświadczenia: registry.redhat.io, quay.io, $REG_HOST"

if [[ " ${STEPS[*]} " =~ " d2m " || " ${STEPS[*]} " =~ " m2m " ]]; then
    if [[ -n "${https_proxy:-${HTTPS_PROXY:-}}" ]] && ! in_no_proxy "${REG_HOST%%:*}"; then
        die "Ustawione https_proxy, a ${REG_HOST%%:*} nie jest w no_proxy — oc-mirror wysyłałby obrazy przez proxy banku.
       Dopisz: export no_proxy=\"\${no_proxy:+\$no_proxy,}${REG_HOST%%:*}\" NO_PROXY=\"\$no_proxy\""
    fi
    curl -fsS -o /dev/null "https://${REG_HOST}/health/instance" \
        || die "Rejestr https://${REG_HOST} nie odpowiada lub jego CA nie jest zaufane (02-setup-bastion.sh)"
    log_ok "Rejestr $REG_HOST odpowiada (TLS zaufany)"
fi

AVAIL=$(df -BG --output=avail "$BASE_DIR" | tail -1 | tr -dc '0-9')
if (( AVAIL < 100 )); then die "Za mało miejsca w $BASE_DIR: ${AVAIL} GB"; fi
(( AVAIL >= 300 )) && log_ok "Wolne miejsce: ${AVAIL} GB" || log_warn "Wolne miejsce: ${AVAIL} GB — może nie wystarczyć"

log_info "oc-mirror: $(oc-mirror --v2 version 2>/dev/null | grep -oE 'GitVersion:"[^"]+"' | head -1 || echo '?')"

# ---------------------------------------------------------------------------
# Uruchomienie oc-mirror
# ---------------------------------------------------------------------------
COMMON_ARGS=(--v2 -c "$ISC" --authfile "$AUTH_FILE"
             --parallel-images "$PAR_IMAGES" --parallel-layers "$PAR_LAYERS"
             --image-timeout 30m --retry-times 5 --retry-delay 10s)
(( DRY_RUN )) && COMMON_ARGS+=(--dry-run)

run_oc_mirror() {   # run_oc_mirror <krok> <argumenty...>
    local step="$1" log; shift
    log="$LOG_DIR/oc-mirror-${step}-$(timestamp).log"
    log_section "Krok ${step}: oc-mirror $*"
    log_info "Log: $log"
    touch "$RUN_MARKER"          # check_mirror_errors raportuje tylko logi z tego kroku
    local start=$SECONDS
    if ! oc-mirror "${COMMON_ARGS[@]}" "$@" 2>&1 | tee "$log"; then
        die "oc-mirror ($step) zakończył się błędem — szczegóły w $log"
    fi
    log_ok "Krok ${step} zakończony w $(( (SECONDS - start) / 60 )) min"
}

# Po d2m/m2m: kopiujemy cluster-resources do katalogu wyników (ślad audytowy + wejście dla 05)
collect_results() {   # collect_results <working-dir>
    local wd="$1" dest
    [[ -d "$wd/cluster-resources" ]] || die "Brak $wd/cluster-resources — oc-mirror nie wygenerował zasobów"
    dest="$RESULTS_DIR/$(timestamp)_${TARGET_VERSION}"
    mkdir -p "$dest"
    cp -a "$wd/cluster-resources" "$dest/"
    cp -a "$ISC" "$dest/imageset-config.yaml"
    cp -a "$VARS_FILE" "$dest/mirror-vars.yaml"
    ln -sfn "$dest" "$RESULTS_DIR/latest"
    log_ok "Zasoby dla klastra: $dest/cluster-resources"
    ls -1 "$dest/cluster-resources" | sed 's/^/         /'
}

# Błędy obrazów operatorów nie przerywają oc-mirror — trzeba je wyłowić z logów
check_mirror_errors() {   # check_mirror_errors <working-dir>
    local errs
    errs=$(find "$1/logs" -name 'mirroring_error*' -newer "$RUN_MARKER" 2>/dev/null || true)
    if [[ -n "$errs" ]]; then
        log_error "oc-mirror zgłosił błędy mirrorowania obrazów:"
        while read -r f; do echo "         $f ($(wc -l <"$f") linii)"; done <<<"$errs"
        log_info "Operatory z brakującymi obrazami będą niekompletne. Ponów krok (cache pominie gotowe obrazy)."
    fi
}

RUN_MARKER="$LOG_DIR/.step-start"

# estimate_size <mapping.txt> — ile to zajmie; tylko przy --estimate, bo odpytuje rejestry
estimate_size() {
    (( ESTIMATE )) || return 0
    local mapping="$1"
    [[ -s "$mapping" ]] || { log_warn "Brak $mapping — nie ma z czego liczyć rozmiaru"; return 0; }
    command -v skopeo &>/dev/null || { log_warn "Brak skopeo — oszacowanie rozmiaru pominięte (sudo dnf install -y skopeo)"; return 0; }
    log_section "Oszacowanie rozmiaru"
    python3 "$LIB_DIR/estimate_size.py" --mapping "$mapping" \
        --authfile "$AUTH_FILE" --arch "$(cfg cluster.architecture amd64)" \
        || log_warn "Oszacowanie rozmiaru nie powiodło się (mirror to nie blokuje)"
}

for step in "${STEPS[@]}"; do
    case "$step" in
        m2d)
            run_oc_mirror m2d --cache-dir "$CACHE_DIR" "file://$ARCHIVE_DIR"
            check_mirror_errors "$ARCHIVE_DIR/working-dir"
            if (( DRY_RUN )); then
                MAPPING="$ARCHIVE_DIR/working-dir/dry-run/mapping.txt"
                log_info "Lista obrazów: $MAPPING ($(wc -l <"$MAPPING" 2>/dev/null || echo 0))"
                log_info "Brak w cache : $ARCHIVE_DIR/working-dir/dry-run/missing.txt"
                estimate_size "$MAPPING"
            else
                log_info "Archiwa: $(ls -1 "$ARCHIVE_DIR"/mirror_*.tar 2>/dev/null | wc -l) plik(ów), $(du -sh "$ARCHIVE_DIR" | cut -f1)"
            fi
            ;;
        d2m)
            ls "$ARCHIVE_DIR"/mirror_*.tar &>/dev/null || die "Brak archiwów w $ARCHIVE_DIR — najpierw krok m2d"
            run_oc_mirror d2m --cache-dir "$CACHE_DIR" --from "file://$ARCHIVE_DIR" "$DESTINATION"
            check_mirror_errors "$ARCHIVE_DIR/working-dir"
            (( DRY_RUN )) || collect_results "$ARCHIVE_DIR/working-dir"
            ;;
        m2m)
            run_oc_mirror m2m --workspace "file://$WORKSPACE_DIR" "$DESTINATION"
            check_mirror_errors "$WORKSPACE_DIR/working-dir"
            (( DRY_RUN )) || collect_results "$WORKSPACE_DIR/working-dir"
            ;;
    esac
done

log_header "MIRROR ZAKOŃCZONY — ostrzeżenia: ${WARNINGS}, błędy: ${ERRORS}"
if (( ! DRY_RUN )); then
    echo "  1. Zrób kopię cache (wymóg dokumentacji Red Hat): $CACHE_DIR"
    echo "  2. Skonfiguruj klaster: bin/05-configure-cluster.sh -f $VARS_FILE --stage all"
fi
(( ERRORS == 0 )) || exit 1
