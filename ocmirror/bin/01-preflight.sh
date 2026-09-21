#!/usr/bin/env bash
# 01-preflight.sh — pasywna analiza klastra przed aktualizacją offline OpenShift.
#
# Użycie:
#   ./01-preflight.sh [-o KATALOG] [-t WERSJA|latest] [-c KANAŁ] [-g GRAPH_URL] [--cacert PLIK]
#
# Opcje:
#   -o KATALOG     katalog na raport i szkic zmiennych (domyślnie ./reports/<klaster>-<data>)
#   -t WERSJA      wersja docelowa, np. 4.21.32; domyślnie "latest" = najnowsza osiągalna
#                  rekomendowaną ścieżką w kanale docelowym
#   -c KANAŁ       kanał docelowy (domyślnie: <prefiks bieżącego kanału>-<następna wersja minor>)
#   -g GRAPH_URL   API grafu aktualizacji; domyślnie Red Hat (api.openshift.com).
#                  Po odcięciu internetu wskaż lokalny OSUS (.../api/upgrades_info/v1/graph)
#   --cacert PLIK  CA do weryfikacji TLS dla -g (np. CA routera ingress z lokalnym OSUS)
#
# Co robi (TYLKO ODCZYT — niczego nie zmienia w klastrze):
#   1. Wersja, kanał, platforma, historia aktualizacji
#   2. Kondycja: ClusterOperators, węzły, MachineConfigPools, PDB, admin-gates
#   3. Zainstalowane operatory (OLM): pakiet, kanał, katalog, wersja, maxOpenShiftVersion
#   4. Bieżąca konfiguracja mirrorów (IDMS/ITMS/ICSP, katalogi, CA, pull secret)
#   5. Możliwe aktualizacje wg grafu Red Hat + rekomendowana ścieżka
#   6. Zapisuje: raport, dane JSON i szkic mirror-vars.yaml dla 03-generate-imageset.py
#
# Kod wyjścia: 0 = OK, 1 = ostrzeżenia, 2 = błędy krytyczne

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

OUT_DIR=""
TARGET="latest"
TARGET_CHANNEL=""
GRAPH_URL=""
GRAPH_CACERT=""

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) OUT_DIR="$2"; shift 2 ;;
        -t) TARGET="$2"; shift 2 ;;
        -c) TARGET_CHANNEL="$2"; shift 2 ;;
        -g) GRAPH_URL="$2"; shift 2 ;;
        --cacert) GRAPH_CACERT="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Nieznana opcja: $1"; usage 1 ;;
    esac
done

require_cmd oc jq python3
require_oc_login

# ---------------------------------------------------------------------------
# Zbieranie danych (jedno wywołanie API na typ zasobu)
# ---------------------------------------------------------------------------
CV=$(oc get clusterversion version -o json)
INFRA=$(oc get infrastructure cluster -o json)
CLUSTER_NAME=$(jq -r '.status.infrastructureName // "cluster"' <<<"$INFRA")

OUT_DIR="${OUT_DIR:-./reports/${CLUSTER_NAME}-$(timestamp)}"
mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/preflight-report.txt"

# Raport: ekran (z kolorami) + plik (bez kodów kolorów)
exec > >(tee >(sed -r 's/\x1b\[[0-9;]*m//g' >"$REPORT")) 2>&1

CURRENT=$(jq -r '[.status.history[] | select(.state=="Completed")][0].version // .status.desired.version' <<<"$CV")
CHANNEL=$(jq -r '.spec.channel // ""' <<<"$CV")
MINOR=$(cut -d. -f1-2 <<<"$CURRENT")
NEXT_MINOR="$(cut -d. -f1 <<<"$CURRENT").$(( $(cut -d. -f2 <<<"$CURRENT") + 1 ))"

NODES=$(oc get nodes -o json)
ARCH=$(jq -r '.items[0].status.nodeInfo.architecture' <<<"$NODES")
[[ "$(jq -r '.status.desired.architecture // ""' <<<"$CV")" == "Multi" ]] && ARCH="multi"

log_header "OCP OFFLINE UPDATE PREFLIGHT — ${CLUSTER_NAME}"
echo "  API       : $(oc whoami --show-server)"
echo "  Użytkownik: $(oc whoami)"
echo "  Data      : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "  Raport    : $REPORT"

# ---------------------------------------------------------------------------
# 1. Wersja i kanał
# ---------------------------------------------------------------------------
log_section "1. Wersja klastra"
log_info "Wersja bieżąca : ${BOLD}${CURRENT}${RESET}"
log_info "Kanał          : ${CHANNEL:-<brak>}"
log_info "Architektura   : ${ARCH}"
log_info "Platforma      : $(jq -r '.status.platformStatus.type // .status.platform' <<<"$INFRA")"
log_info "Topologia CP   : $(jq -r '.status.controlPlaneTopology // "-"' <<<"$INFRA")"
log_info "Cluster ID     : $(jq -r '.spec.clusterID' <<<"$CV")"
log_info "Upstream (OSUS): $(jq -r '.spec.upstream // "domyślny Red Hat (api.openshift.com)"' <<<"$CV")"

echo "  Ostatnie aktualizacje:"
jq -r '.status.history[:5][] | "    \(.version)\t\(.state)\t\(.startedTime) -> \(.completionTime // "w toku")"' <<<"$CV"

if [[ "$(jq -r '.status.history[0].state' <<<"$CV")" != "Completed" ]]; then
    log_error "Aktualizacja w toku lub nieukończona ($(jq -r '.status.history[0].version' <<<"$CV")). Najpierw ją zakończ."
fi

# ---------------------------------------------------------------------------
# 2. Kondycja klastra
# ---------------------------------------------------------------------------
log_section "2. Kondycja klastra"

# Warunki ClusterVersion
while IFS=$'\t' read -r type status msg; do
    case "$type:$status" in
        Failing:True)       log_error "ClusterVersion Failing: $msg" ;;
        Upgradeable:False)  log_warn  "ClusterVersion Upgradeable=False (blokuje aktualizację minor): $msg" ;;
        RetrievedUpdates:False) log_warn "CVO nie pobiera grafu aktualizacji: $msg" ;;
    esac
done < <(jq -r '.status.conditions[] | [.type, .status, (.message // "" | gsub("\n"; " "))] | @tsv' <<<"$CV")

# ClusterOperators
CO=$(oc get clusteroperators -o json)
CO_BAD=$(jq -r '.items[] | . as $co
    | (([(.status.conditions // [])[] | {(.type): .status}] | add) // {}) as $c
    | select($c.Available != "True" or $c.Degraded == "True")
    | "\($co.metadata.name) (Available=\($c.Available), Degraded=\($c.Degraded))"' <<<"$CO")
if [[ -z "$CO_BAD" ]]; then
    log_ok "Wszystkie ClusterOperators: Available=True, Degraded=False ($(jq '.items|length' <<<"$CO"))"
else
    while read -r l; do log_error "ClusterOperator: $l"; done <<<"$CO_BAD"
fi
while read -r l; do [[ -n "$l" ]] && log_warn "Upgradeable=False: $l"; done < <(jq -r '.items[]
    | .metadata.name as $n | (.status.conditions // [])[]
    | select(.type=="Upgradeable" and .status=="False") | "\($n): \(.message // "" | gsub("\n"; " "))"' <<<"$CO")

# Węzły
NOT_READY=$(jq -r '.items[] | select(any(.status.conditions[]; .type=="Ready" and .status!="True")) | .metadata.name' <<<"$NODES")
UNSCHED=$(jq -r '.items[] | select(.spec.unschedulable==true) | .metadata.name' <<<"$NODES")
log_info "Węzły: $(jq '.items|length' <<<"$NODES")"
[[ -z "$NOT_READY" ]] && log_ok "Wszystkie węzły Ready" || while read -r n; do log_error "Węzeł NotReady: $n"; done <<<"$NOT_READY"
[[ -n "$UNSCHED" ]] && while read -r n; do log_warn "Węzeł cordoned (SchedulingDisabled): $n"; done <<<"$UNSCHED"

# MachineConfigPools
while IFS=$'\t' read -r name paused updated degraded machines ready; do
    if [[ "$paused" == "true" ]]; then log_warn "MCP $name jest wstrzymany (paused) — jego węzły NIE zostaną zaktualizowane"; fi
    if [[ "$degraded" == "True" ]]; then log_error "MCP $name Degraded"; fi
    if [[ "$updated" != "True" ]]; then log_warn "MCP $name nie jest Updated ($ready/$machines gotowych)"; fi
    [[ "$paused" != "true" && "$degraded" != "True" && "$updated" == "True" ]] && log_ok "MCP $name: $ready/$machines zaktualizowanych"
done < <(oc get mcp -o json | jq -r '.items[] | [.metadata.name, (.spec.paused // false | tostring),
        ((.status.conditions // [])[] | select(.type=="Updated") | .status),
        ((.status.conditions // [])[] | select(.type=="Degraded") | .status),
        (.status.machineCount // 0), (.status.readyMachineCount // 0)] | @tsv')

# MachineHealthChecks — dokumentacja zaleca ich wstrzymanie na czas aktualizacji
MHC=$(oc get machinehealthcheck -n openshift-machine-api -o name 2>/dev/null || true)
if [[ -n "$MHC" ]]; then
    log_info "MachineHealthCheck ($(wc -l <<<"$MHC")): przed aktualizacją wstrzymaj (annotacja cluster.x-k8s.io/paused)"
fi

# PodDisruptionBudgets blokujące drenowanie węzłów
PDB_BLOCK=$(oc get pdb -A -o json | jq -r '.items[]
    | select((.status.expectedPods // 0) > 0 and (.status.disruptionsAllowed // 0) == 0)
    | "\(.metadata.namespace)/\(.metadata.name) (expectedPods=\(.status.expectedPods))"')
if [[ -z "$PDB_BLOCK" ]]; then
    log_ok "Brak PDB z disruptionsAllowed=0"
else
    while read -r l; do log_warn "PDB blokuje drain węzła: $l"; done <<<"$PDB_BLOCK"
fi

# Admin gates — potwierdzenia administratora wymagane przed aktualizacją minor
GATES=$(oc get cm admin-gates -n openshift-config-managed -o json 2>/dev/null | jq -r '.data // {} | keys[]' || true)
if [[ -n "$GATES" ]]; then
    ACKS=$(oc get cm admin-acks -n openshift-config -o json 2>/dev/null | jq -c '.data // {}' || echo '{}')
    while read -r g; do
        if [[ "$(jq -r --arg g "$g" '.[$g] // ""' <<<"$ACKS")" == "true" ]]; then
            log_ok "Admin-ack potwierdzony: $g"
        else
            log_warn "Wymagane potwierdzenie administratora (admin-ack): $g"
            log_info "  oc -n openshift-config patch cm admin-acks --type=merge -p '{\"data\":{\"$g\":\"true\"}}'"
        fi
    done <<<"$GATES"
fi

# Obrazy zapisane krótką nazwą (bez rejestru) — 4.21 ich nie akceptuje (ryzyko ShortNameImageReferences)
SHORT=$(oc get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns
    | [(.spec.containers // [])[], (.spec.initContainers // [])[]][].image
    | select((contains("/") | not)
             or ((split("/")[0] | test("[.:]") | not) and split("/")[0] != "localhost"))
    | "\($ns): \(.)"' | sort -u)
if [[ -z "$SHORT" ]]; then
    log_ok "Brak podów z obrazami w krótkiej nazwie (bez rejestru)"
else
    log_warn "Pody z obrazami bez nazwy rejestru — w 4.21 przestaną się uruchamiać:"
    while read -r l; do echo "         $l"; done <<<"$SHORT"
fi

log_info "Przypomnienie: przed aktualizacją wykonaj backup etcd (cluster-backup.sh na węźle control plane)."

# ---------------------------------------------------------------------------
# 3. Operatory (OLM)
# ---------------------------------------------------------------------------
log_section "3. Zainstalowane operatory (OLM)"

# Dane trafiają do plików i jq czyta je przez --slurpfile: JSON z dużego klastra
# przekracza limit długości argumentów (ARG_MAX), gdyby podać go przez --argjson.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
oc get subscriptions.operators.coreos.com -A -o json >"$TMP_DIR/subs.json"
# Bez kopii CSV (label olm.copiedFrom) — operatory AllNamespaces mają kopię w każdym namespace
oc get csv -A -l '!olm.copiedFrom' -o json >"$TMP_DIR/csvs.json"
oc get catalogsources.operators.coreos.com -A -o json >"$TMP_DIR/catsrc.json"

# Łączymy Subscription + CSV + CatalogSource w jeden obiekt na operator.
# Obraz indeksu mapujemy na nazwę kanoniczną w registry.redhat.io, dzięki czemu
# działa to także wtedy, gdy klaster korzysta już z katalogów z mirrora.
OPERATORS_JSON=$(jq -n --slurpfile subs "$TMP_DIR/subs.json" --slurpfile csvs "$TMP_DIR/csvs.json" \
                       --slurpfile cs "$TMP_DIR/catsrc.json" '
  def canonical_index:
    (sub("[@:][^/]*$"; "") | split("/") | last) as $base
    | if ($base | IN("redhat-operator-index","certified-operator-index","redhat-marketplace-index","community-operator-index"))
      then "registry.redhat.io/redhat/" + $base
      else sub("[@:][^/]*$"; "") end;
  $subs[0] as $subs | $csvs[0] as $csvs | $cs[0] as $cs
  | [ $subs.items[] as $s
    | ($csvs.items | map(select(.metadata.namespace == $s.metadata.namespace
                                 and .metadata.name == ($s.status.installedCSV // ""))) | first) as $csv
    | ($cs.items | map(select(.metadata.name == $s.spec.source
                               and .metadata.namespace == $s.spec.sourceNamespace)) | first) as $src
    | {
        namespace:   $s.metadata.namespace,
        package:     $s.spec.name,
        channel:     ($s.spec.channel // ""),
        source:      $s.spec.source,
        approval:    ($s.spec.installPlanApproval // "Automatic"),
        installedCSV: ($s.status.installedCSV // ""),
        version:     ($csv.spec.version // ""),
        phase:       ($csv.status.phase // "Brak CSV"),
        maxOCP:      (($csv.metadata.annotations["operators.operatorframework.io/properties"] // "{}")
                      | fromjson? // {} | (.properties // [])
                      | map(select(.type == "olm.maxOpenShiftVersion") | .value | tostring) | first // ""),
        indexImage:  ($src.spec.image // ""),
        catalog:     (($src.spec.image // "") | if . == "" then "" else canonical_index end)
      } ]')
echo "$OPERATORS_JSON" >"$OUT_DIR/operators.json"

OP_COUNT=$(jq 'length' <<<"$OPERATORS_JSON")
if [[ "$OP_COUNT" -eq 0 ]]; then
    log_info "Brak operatorów zainstalowanych przez OLM (Subscription)."
else
    {
        printf "  %-28s %-34s %-14s %-16s %-10s %s\n" "NAMESPACE" "PAKIET" "KANAŁ" "WERSJA" "APPROVAL" "KATALOG"
        jq -r '.[] | [.namespace, .package, .channel, .version, .approval, .source] | map(if . == "" then "-" else . end) | @tsv' <<<"$OPERATORS_JSON" \
            | while IFS=$'\t' read -r ns pkg ch ver appr src; do
                printf "  %-28s %-34s %-14s %-16s %-10s %s\n" "${ns:0:28}" "${pkg:0:34}" "${ch:0:14}" "${ver:0:16}" "$appr" "$src"
            done
    }
    while IFS=$'\t' read -r pkg phase; do
        log_error "Operator $pkg: CSV w fazie '$phase' (oczekiwano Succeeded)"
    done < <(jq -r '.[] | select(.phase != "Succeeded") | [.package, .phase] | @tsv' <<<"$OPERATORS_JSON")
    while IFS=$'\t' read -r pkg maxocp; do
        log_warn "Operator $pkg ma olm.maxOpenShiftVersion=$maxocp — zablokuje aktualizację do $NEXT_MINOR; najpierw zaktualizuj operator"
    done < <(jq -r --arg m "$MINOR" '.[] | select(.maxOCP != "" and .maxOCP == $m) | [.package, .maxOCP] | @tsv' <<<"$OPERATORS_JSON")
    while read -r pkg; do
        log_warn "Operator $pkg: nie ustalono obrazu katalogu (CatalogSource bez spec.image) — dopisz go ręcznie do mirror-vars.yaml"
    done < <(jq -r '.[] | select(.catalog == "") | .package' <<<"$OPERATORS_JSON")
fi

if oc get crd clusterextensions.olm.operatorframework.io &>/dev/null; then
    CE=$(oc get clusterextensions -o json | jq -r '.items[] | "\(.metadata.name) (pakiet: \(.spec.source.catalog.packageName // "?"))"')
    [[ -n "$CE" ]] && while read -r l; do log_warn "OLM v1 ClusterExtension: $l — dodaj pakiet ręcznie do mirror-vars.yaml"; done <<<"$CE"
fi

# ---------------------------------------------------------------------------
# 4. Bieżąca konfiguracja mirrorów i źródeł obrazów
# ---------------------------------------------------------------------------
log_section "4. Konfiguracja źródeł obrazów"

for kind in imagedigestmirrorset imagetagmirrorset imagecontentsourcepolicy; do
    names=$(oc get "$kind" -o name 2>/dev/null | sed 's|.*/||' | paste -sd, - || true)
    if [[ -n "$names" ]]; then
        log_info "$kind: $names"
        [[ "$kind" == "imagecontentsourcepolicy" ]] && log_warn "ICSP jest przestarzały — migruj do IDMS (oc adm migrate icsp)"
    else
        log_info "$kind: brak"
    fi
done

DISABLED_DEFAULTS=$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}' 2>/dev/null || true)
log_info "OperatorHub disableAllDefaultSources: ${DISABLED_DEFAULTS:-false}"
jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)\t\(.spec.image // "-")\t\(.status.connectionState.lastObservedState // "?")"' "$TMP_DIR/catsrc.json" \
    | while IFS=$'\t' read -r n img state; do log_info "CatalogSource $n [$state] $img"; done

IMG_CFG=$(oc get image.config.openshift.io cluster -o json)
log_info "additionalTrustedCA: $(jq -r '.spec.additionalTrustedCA.name // "brak"' <<<"$IMG_CFG")"
jq -e '.spec.registrySources.allowedRegistries // .spec.registrySources.blockedRegistries' <<<"$IMG_CFG" &>/dev/null \
    && log_warn "Ustawione allowed/blockedRegistries — upewnij się, że rejestr mirrora jest dozwolony"

PULL_REGS=$(oc get secret pull-secret -n openshift-config -o json \
    | jq -r '.data[".dockerconfigjson"] | @base64d | fromjson | .auths | keys | join(", ")')
log_info "Rejestry w globalnym pull secret: $PULL_REGS"

PROXY=$(oc get proxy cluster -o jsonpath='{.spec.httpsProxy}' 2>/dev/null || true)
[[ -n "$PROXY" ]] && log_info "Cluster-wide proxy: $PROXY (pamiętaj o noProxy dla rejestru mirrora)"

# ---------------------------------------------------------------------------
# 5. Możliwości aktualizacji wg grafu Red Hat
# ---------------------------------------------------------------------------
log_section "5. Możliwe aktualizacje (graf OpenShift Update Service)"

PREFIX="${CHANNEL%-*}"
[[ "$PREFIX" =~ ^(stable|fast|candidate)$ ]] || PREFIX="stable"
TARGET_CHANNEL="${TARGET_CHANNEL:-${PREFIX}-${NEXT_MINOR}}"
log_info "Kanał bieżący: ${CHANNEL:-brak}, kanał docelowy: ${TARGET_CHANNEL}, cel: ${TARGET}"

GRAPH_ARGS=(--current "$CURRENT" --arch "$ARCH" --target "$TARGET" --summary-file "$OUT_DIR/update-path.json")
[[ -n "$CHANNEL" && "$CHANNEL" != "$TARGET_CHANNEL" ]] && GRAPH_ARGS+=(--channel "$CHANNEL")
GRAPH_ARGS+=(--channel "$TARGET_CHANNEL")
[[ -n "$GRAPH_URL" ]] && GRAPH_ARGS+=(--graph-url "$GRAPH_URL")
[[ -n "$GRAPH_CACERT" ]] && GRAPH_ARGS+=(--cacert "$GRAPH_CACERT")

if ! python3 "$LIB_DIR/ocp_graph.py" "${GRAPH_ARGS[@]}"; then
    log_warn "Nie wyznaczono ścieżki aktualizacji — sprawdź dostęp do API grafu i kanał docelowy"
fi

# Porównanie z tym, co widzi sam klaster (CVO), dopóki ma dostęp do internetu
CVO_UPDATES=$(jq -r '[.status.availableUpdates // [] | .[].version] | sort_by(split(".") | map(tonumber? // 0)) | join(", ")' <<<"$CV")
CVO_COND=$(jq -r '[.status.conditionalUpdates // [] | .[] | "\(.release.version) [\([.risks[].name] | join(","))]"] | join(", ")' <<<"$CV")
log_info "CVO (kanał ${CHANNEL:-brak}) — dostępne aktualizacje: ${CVO_UPDATES:-brak}"
[[ -n "$CVO_COND" ]] && log_info "CVO — aktualizacje warunkowe: $CVO_COND"

TARGET_VERSION=$(jq -r '.target // empty' "$OUT_DIR/update-path.json" 2>/dev/null || true)
TARGET_PAYLOAD=$(jq -r '.targetPayload // empty' "$OUT_DIR/update-path.json" 2>/dev/null || true)
if [[ -n "$TARGET_VERSION" && "$(cut -d. -f1-2 <<<"$TARGET_VERSION")" == "$NEXT_MINOR" ]]; then
    log_warn "4.21+: mirror MUSI zawierać podpisy Sigstore release (nie używaj --remove-signatures w oc-mirror)"
fi

# ---------------------------------------------------------------------------
# 6. Szkic mirror-vars.yaml
# ---------------------------------------------------------------------------
log_section "6. Szkic pliku zmiennych"

VARS_DRAFT="$OUT_DIR/mirror-vars.yaml"
TARGET_MINOR=$(cut -d. -f1-2 <<<"${TARGET_VERSION:-$CURRENT}")
CATALOG_TAGS=$(jq -rn --arg a "v$MINOR" --arg b "v$TARGET_MINOR" '[$a, $b] | unique | join(", ")')

{
    cat <<EOF
# Szkic wygenerowany przez 01-preflight.sh ($(date -u '+%Y-%m-%d %H:%M UTC'))
# Klaster: ${CLUSTER_NAME}, API: $(oc whoami --show-server)
# PRZEJRZYJ przed użyciem: uzupełnij sekcję registry, usuń zbędne operatory.
# Opis wszystkich pól: config/mirror-vars.example.yaml

cluster:
  name: ${CLUSTER_NAME}
  architecture: ${ARCH}

platform:
  channel: ${TARGET_CHANNEL}
  currentVersion: "${CURRENT}"
  targetVersion: "${TARGET_VERSION:-UZUPEŁNIJ}"
  shortestPath: true
  graph: true

registry:
  host: ${MIRROR_REGISTRY:-UZUPEŁNIJ-fqdn-bastionu:8443}
  namespace: ocp
  quayRoot: /data/quay/quay-install
  quayStorage: /data/quay/storage
  sqliteStorage: /data/quay/sqlite
  caFile: /data/quay/quay-install/quay-rootCA/rootCA.pem

mirror:
  workflow: m2d-d2m
  baseDir: /data/oc-mirror
  authFile: /data/oc-mirror/auth/auth.json
  parallelImages: 4
  parallelLayers: 5
  archiveSizeGiB: 10

tools:
  clientChannel: stable-${TARGET_MINOR}

osus:
  channel: v1
  namespace: openshift-update-service

operators:
EOF
    # Grupowanie po katalogu; cincinnati-operator (OSUS) dodawany do katalogu Red Hat.
    jq -r --arg tags "$CATALOG_TAGS" '
        (map(select(.catalog != "")) + [{catalog: "registry.redhat.io/redhat/redhat-operator-index",
                                          package: "cincinnati-operator", channel: "v1", version: "", namespace: "(OSUS)"}])
        | unique_by([.catalog, .package]) | group_by(.catalog)[]
        | "  - catalog: \(.[0].catalog)\n    versions: [\($tags)]\n    packages:",
          (.[] | "      - name: \(.package)\n        channel: \(.channel)"
                 + (if .version != "" then "\n        # minVersion: \"\(.version)\"   # zainstalowana (\(.namespace)) — odkomentuj, by zmirrorować pełną ścieżkę aktualizacji" else "" end))
    ' <<<"$OPERATORS_JSON"
    echo ""
    echo "additionalImages: []"
} >"$VARS_DRAFT"

log_ok "Zapisano szkic: $VARS_DRAFT"
log_ok "Dane operatorów: $OUT_DIR/operators.json"
log_ok "Ścieżka aktualizacji: $OUT_DIR/update-path.json"

# ---------------------------------------------------------------------------
# Podsumowanie
# ---------------------------------------------------------------------------
log_header "PODSUMOWANIE"
echo "  Wersja bieżąca : $CURRENT ($CHANNEL)"
echo "  Wersja docelowa: ${TARGET_VERSION:-nie wyznaczono} ($TARGET_CHANNEL)"
[[ -n "$TARGET_PAYLOAD" ]] && echo "  Obraz release  : $TARGET_PAYLOAD"
echo "  Operatory OLM  : $OP_COUNT"
echo -e "  Ostrzeżenia    : ${YELLOW}${WARNINGS}${RESET}"
echo -e "  Błędy          : ${RED}${ERRORS}${RESET}"
echo ""
echo "  Następne kroki:"
echo "    1. Przejrzyj $VARS_DRAFT i skopiuj go do config/mirror-vars.yaml"
echo "    2. bin/03-generate-imageset.py -f config/mirror-vars.yaml"
echo "    3. bin/04-mirror.sh -f config/mirror-vars.yaml --dry-run"

if (( ERRORS > 0 )); then exit 2; elif (( WARNINGS > 0 )); then exit 1; else exit 0; fi
