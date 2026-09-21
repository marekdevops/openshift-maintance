#!/usr/bin/env bash
# 05-configure-cluster.sh — przełączenie klastra na obrazy z mini Quay (bastion).
#
# Użycie:
#   ./05-configure-cluster.sh -f config/mirror-vars.yaml --stage ETAPY [opcje]
#
# Etapy (--stage, można podać kilka po przecinku):
#   trust       CA rejestru -> image.config.openshift.io (additionalTrustedCA)       [bez restartu węzłów]
#   pullsecret  poświadczenia (tylko do odczytu!) do rejestru -> globalny pull secret  [bez restartu węzłów]
#   mirrors     IDMS/ITMS + podpisy release z oc-mirror                               [możliwy rolling drain/reboot]
#   catalogs    CatalogSource z mirrora, przepięcie Subscription, wyłączenie katalogów domyślnych
#   verify      test: węzeł pobiera obraz release z mirrora (crictl pull), stan katalogów
#   osus        lokalny OpenShift Update Service + przełączenie CVO na lokalny graf
#   disconnect  usunięcie cloud.openshift.com z pull secret (Telemetry/Insights) — PO odcięciu internetu
#   all         = trust,pullsecret,mirrors,catalogs,verify
#
# Opcje:
#   -f PLIK            plik zmiennych (mirror-vars.yaml)
#   -r KATALOG         katalog cluster-resources (domyślnie <baseDir>/results/latest/cluster-resources)
#   --catalog-tag TAG  linia katalogów dla Subscription, np. v4.21 (domyślnie: bieżąca wersja klastra)
#   --dry-run          walidacja po stronie serwera (--dry-run=server), bez zmian
#   --yes              nie pytaj o potwierdzenia (do automatyzacji)
#
# Zmienne środowiskowe (etap pullsecret):
#   MIRROR_PULL_USER, MIRROR_PULL_PASSWORD — konto robota Quay z prawem TYLKO do odczytu.
#   Brak zmiennych = pytanie interaktywne.

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

VARS_FILE=""
RES_DIR=""
STAGES=""
CATALOG_TAG=""
DRY_RUN=0
ASSUME_YES=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) VARS_FILE="$2"; shift 2 ;;
        -r) RES_DIR="$2"; shift 2 ;;
        --stage) STAGES="$2"; shift 2 ;;
        --catalog-tag) CATALOG_TAG="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Nieznana opcja: $1"; usage 1 ;;
    esac
done
[[ -n "$VARS_FILE" && -n "$STAGES" ]] || usage 1
export ASSUME_YES

require_cmd oc jq python3
require_pyyaml
require_oc_login

REG_HOST=$(cfg registry.host)
REG_NS=$(cfg registry.namespace "ocp")
BASE_DIR=$(expand_path "$(cfg mirror.baseDir)")
CA_FILE=$(expand_path "$(cfg registry.caFile)")
OSUS_NS=$(cfg osus.namespace "openshift-update-service")
OSUS_CHANNEL=$(cfg osus.channel "v1")
RES_DIR="${RES_DIR:-$BASE_DIR/results/latest/cluster-resources}"

CURRENT=$(oc get clusterversion version -o json \
    | jq -r '[.status.history[] | select(.state=="Completed")][0].version // .status.desired.version')
CATALOG_TAG="${CATALOG_TAG:-v$(cut -d. -f1-2 <<<"$CURRENT")}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
chmod 700 "$TMP_DIR"

STAGES="${STAGES//all/trust,pullsecret,mirrors,catalogs,verify}"

# ---------------------------------------------------------------------------
# Pomocnicze
# ---------------------------------------------------------------------------
# oc_mut: każda zmiana w klastrze idzie przez tę funkcję (obsługa --dry-run)
oc_mut() {
    if (( DRY_RUN )); then oc "$@" --dry-run=server; else oc "$@"; fi
}

# Wszystkie dokumenty z cluster-resources jako JSON (jeden na linię).
# Dla sygnatur oc-mirror zapisuje ten sam obiekt jako .json i .yaml — bierzemy jeden.
load_resources() {
    [[ -d "$RES_DIR" ]] || die "Brak katalogu $RES_DIR — uruchom najpierw 04-mirror.sh"
    local f
    : >"$TMP_DIR/resources.jsonl"
    for f in "$RES_DIR"/*.yaml "$RES_DIR"/*.yml "$RES_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        if [[ "$f" == *.json && -e "${f%.json}.yaml" ]]; then continue; fi
        yaml2json "$f" >>"$TMP_DIR/resources.jsonl"
    done
    log_info "Zasoby z oc-mirror ($RES_DIR): $(jq -rs 'group_by(.kind) | map("\(.[0].kind)=\(length)") | join(", ")' "$TMP_DIR/resources.jsonl")"
}

# resources_of_kind <Kind> — wypisuje dokumenty danego typu (JSON, jeden na linię)
resources_of_kind() { jq -c --arg k "$1" 'select(.kind == $k)' "$TMP_DIR/resources.jsonl"; }

# Nazwa pliku indeksu katalogu, np. .../redhat/redhat-operator-index:v4.21 -> redhat-operator-index
index_basename() { sed -E 's/[@:][^/]*$//; s|.*/||' <<<"$1"; }

wait_for() {   # wait_for <opis> <sekundy> <polecenie...>
    local what="$1" timeout="$2"; shift 2
    local end=$((SECONDS + timeout))
    until "$@" &>/dev/null; do
        (( SECONDS < end )) || { log_error "Przekroczono czas oczekiwania: $what"; return 1; }
        sleep 10
    done
    log_ok "$what"
}

# ---------------------------------------------------------------------------
# Etap: trust — zaufanie klastra do CA rejestru
# ---------------------------------------------------------------------------
stage_trust() {
    log_section "Etap trust: CA rejestru ${REG_HOST}"
    [[ -f "$CA_FILE" ]] || die "Brak pliku CA: $CA_FILE (registry.caFile)"

    # Klucz w ConfigMap: host..port (dwukropek zamieniony na dwie kropki — wymóg OpenShift)
    local key="${REG_HOST/:/..}" cm
    cm=$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.additionalTrustedCA.name}')

    if [[ -n "$cm" ]]; then
        log_info "Klaster używa już ConfigMap '$cm' — dopisuję klucze (pozostałe bez zmian)"
        oc_mut set data configmap/"$cm" -n openshift-config \
            --from-file="${key}=${CA_FILE}" --from-file="updateservice-registry=${CA_FILE}"
    else
        cm="mirror-registry-ca"
        oc_mut create configmap "$cm" -n openshift-config \
            --from-file="${key}=${CA_FILE}" --from-file="updateservice-registry=${CA_FILE}"
        oc_mut patch image.config.openshift.io/cluster --type=merge \
            -p "{\"spec\":{\"additionalTrustedCA\":{\"name\":\"${cm}\"}}}"
    fi
    log_ok "CA w openshift-config/$cm (klucze: $key, updateservice-registry)"
    log_info "Klucz 'updateservice-registry' jest wymagany przez OpenShift Update Service."
}

# ---------------------------------------------------------------------------
# Etap: pullsecret — poświadczenia do rejestru w globalnym pull secret
# ---------------------------------------------------------------------------
stage_pullsecret() {
    log_section "Etap pullsecret: poświadczenia do ${REG_HOST}"

    local user="${MIRROR_PULL_USER:-}" pass="${MIRROR_PULL_PASSWORD:-}"
    if [[ -z "$user" || -z "$pass" ]]; then
        [[ -t 0 ]] || die "Ustaw MIRROR_PULL_USER i MIRROR_PULL_PASSWORD (tryb nieinteraktywny)"
        read -r -p "  Użytkownik (robot Quay, tylko odczyt, np. ocp+cluster_pull): " user
        read -r -s -p "  Hasło/token: " pass; echo
    fi
    if [[ "$user" == "init" ]]; then
        log_warn "Użytkownik 'init' ma prawo ZAPISU do rejestru — Red Hat zaleca konto tylko do odczytu"
        confirm "Kontynuować mimo to?" || die "Przerwano"
    fi

    oc get secret/pull-secret -n openshift-config \
        --template='{{index .data ".dockerconfigjson" | base64decode}}' >"$TMP_DIR/pull-secret.json"
    jq --arg r "$REG_HOST" --arg a "$(printf '%s:%s' "$user" "$pass" | base64 -w0)" \
        '.auths[$r] = {auth: $a}' "$TMP_DIR/pull-secret.json" >"$TMP_DIR/pull-secret.new.json"

    if cmp -s <(jq -S . "$TMP_DIR/pull-secret.json") <(jq -S . "$TMP_DIR/pull-secret.new.json"); then
        log_ok "Pull secret zawiera już te poświadczenia — bez zmian"
        return 0
    fi
    oc_mut set data secret/pull-secret -n openshift-config \
        --from-file=.dockerconfigjson="$TMP_DIR/pull-secret.new.json"
    log_ok "Zaktualizowano globalny pull secret (MCO rozpropaguje go na węzły bez restartu)"
}

# ---------------------------------------------------------------------------
# Etap: mirrors — IDMS / ITMS / podpisy release
# ---------------------------------------------------------------------------
stage_mirrors() {
    log_section "Etap mirrors: ImageDigestMirrorSet / ImageTagMirrorSet / podpisy release"
    local kind obj name n_changes=0

    resources_of_kind ImageDigestMirrorSet >"$TMP_DIR/idms.jsonl"
    resources_of_kind ImageTagMirrorSet >"$TMP_DIR/itms.jsonl"
    [[ -s "$TMP_DIR/idms.jsonl" ]] || die "Brak IDMS w $RES_DIR — mirror nie jest kompletny"

    # Pokaż różnice i oceń wpływ na węzły (zasady MCO z dokumentacji OpenShift 4.21)
    for kind in idms itms; do
        while read -r obj; do
            [[ -n "$obj" ]] || continue
            name=$(jq -r '.metadata.name' <<<"$obj")
            if ! oc get "$kind" "$name" &>/dev/null; then
                log_info "$kind/$name: NOWY"
                [[ "$kind" == "itms" ]] && log_warn "Utworzenie ITMS $name spowoduje drain i restart węzłów (rolling)"
                (( n_changes++ )) || true
            elif ! oc diff -f - <<<"$obj" >"$TMP_DIR/diff.txt" 2>&1; then
                log_warn "$kind/$name: ZMIANA — MCO wykona rolling drain/restart węzłów (chyba że dochodzą tylko nowe wpisy digest-only)"
                sed 's/^/         /' "$TMP_DIR/diff.txt" | head -40
                (( n_changes++ )) || true
            else
                log_ok "$kind/$name: bez zmian"
            fi
        done <"$TMP_DIR/$kind.jsonl"
    done

    if (( n_changes > 0 )) && (( ! DRY_RUN )); then
        confirm "Zastosować zmiany mirrorów ($n_changes)? Wykonuj w oknie serwisowym." || die "Przerwano"
    fi

    cat "$TMP_DIR/idms.jsonl" "$TMP_DIR/itms.jsonl" | jq -s '{apiVersion: "v1", kind: "List", items: .}' \
        | oc_mut apply -f -

    # Podpisy release — CVO weryfikuje nimi obraz release przy aktualizacji
    resources_of_kind ConfigMap | jq -s '{apiVersion: "v1", kind: "List", items: .}' >"$TMP_DIR/cm.json"
    if [[ "$(jq '.items | length' "$TMP_DIR/cm.json")" -gt 0 ]]; then
        oc_mut apply -f "$TMP_DIR/cm.json"
        log_ok "Podpisy release zastosowane (openshift-config-managed)"
    else
        log_warn "Brak ConfigMap z podpisami release — CVO nie zweryfikuje obrazu docelowego"
    fi

    log_info "Stan MachineConfigPool (zmiany rozchodzą się kilka-kilkanaście minut):"
    oc get mcp | sed 's/^/         /'
    log_info "Obserwuj: watch oc get mcp   — kontynuuj, gdy wszystkie pule mają UPDATED=True"
}

# ---------------------------------------------------------------------------
# Etap: catalogs — katalogi operatorów z mirrora
# ---------------------------------------------------------------------------
stage_catalogs() {
    log_section "Etap catalogs: katalogi operatorów (linia ${CATALOG_TAG})"

    resources_of_kind CatalogSource >"$TMP_DIR/cs.jsonl"
    [[ -s "$TMP_DIR/cs.jsonl" ]] || die "Brak CatalogSource w $RES_DIR"
    jq -r '"\(.metadata.name)\t\(.spec.image)"' "$TMP_DIR/cs.jsonl" \
        | while IFS=$'\t' read -r n img; do log_info "CatalogSource $n -> $img"; done
    grep -q ":${CATALOG_TAG}\"" "$TMP_DIR/cs.jsonl" \
        || die "Żaden zmirrorowany katalog nie ma tagu ${CATALOG_TAG} — sprawdź operators[].versions"

    # 1. Katalogi z mirrora (wszystkie linie; nazwy i obrazy dokładnie jak z oc-mirror)
    jq -s '{apiVersion: "v1", kind: "List", items: .}' "$TMP_DIR/cs.jsonl" | oc_mut apply -f -
    if oc get crd clustercatalogs.olm.operatorframework.io &>/dev/null; then
        resources_of_kind ClusterCatalog | jq -s '{apiVersion: "v1", kind: "List", items: .}' >"$TMP_DIR/cc.json"
        [[ "$(jq '.items | length' "$TMP_DIR/cc.json")" -gt 0 ]] && oc_mut apply -f "$TMP_DIR/cc.json"
    fi

    if (( ! DRY_RUN )); then
        local n
        for n in $(jq -r '.metadata.name' "$TMP_DIR/cs.jsonl"); do
            wait_for "CatalogSource $n READY" 600 \
                bash -c "oc get catalogsource $n -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' | grep -qx READY"
        done
    fi

    # 2. Przepięcie Subscription na katalog z mirrora (ta sama rodzina indeksu, linia CATALOG_TAG)
    local plan
    oc get subscriptions.operators.coreos.com -A -o json >"$TMP_DIR/subs.json"
    oc get catalogsources.operators.coreos.com -A -o json >"$TMP_DIR/catsrc.json"
    plan=$(jq -r --slurpfile subs "$TMP_DIR/subs.json" --slurpfile cs "$TMP_DIR/catsrc.json" \
               --arg tag "$CATALOG_TAG" -s '
        . as $mirrored | $subs[0] as $subs | $cs[0] as $cs
        | def base: sub("[@:][^/]*$"; "") | split("/") | last;
          def default_base: {"redhat-operators": "redhat-operator-index", "certified-operators": "certified-operator-index",
                             "redhat-marketplace": "redhat-marketplace-index", "community-operators": "community-operator-index"};
        $subs.items[]
        | . as $s
        | ([$cs.items[] | select(.metadata.name == $s.spec.source and .metadata.namespace == $s.spec.sourceNamespace)
            | .spec.image // "" | select(. != "") | base] | first
           // (default_base | .[$s.spec.source]) // "") as $family
        | ([$mirrored[] | select((.spec.image | base) == $family and (.spec.image | endswith(":" + $tag)))
            | .metadata.name] | first // "") as $target
        | [$s.metadata.namespace, $s.metadata.name, $s.spec.source, $family, $target] | @tsv' "$TMP_DIR/cs.jsonl")

    local ns name src family target
    while IFS=$'\t' read -r ns name src family target; do
        [[ -n "$ns" ]] || continue
        if [[ -z "$target" ]]; then
            log_warn "Subscription $ns/$name (źródło $src, indeks '${family:-?}'): brak katalogu w mirrorze — przepnij ręcznie"
        elif [[ "$src" == "$target" ]]; then
            log_ok "Subscription $ns/$name już używa $target"
        else
            oc_mut patch subscriptions.operators.coreos.com "$name" -n "$ns" --type=merge \
                -p "{\"spec\":{\"source\":\"$target\",\"sourceNamespace\":\"openshift-marketplace\"}}" >/dev/null
            log_ok "Subscription $ns/$name: $src -> $target"
        fi
    done <<<"$plan"

    # 3. Wyłączenie katalogów domyślnych (wymagane w środowisku disconnected)
    if [[ "$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}')" == "true" ]]; then
        log_ok "Katalogi domyślne już wyłączone"
    else
        oc_mut patch operatorhub cluster --type=merge -p '{"spec":{"disableAllDefaultSources":true}}' >/dev/null
        log_ok "Wyłączono katalogi domyślne (OperatorHub disableAllDefaultSources=true)"
    fi
}

# ---------------------------------------------------------------------------
# Etap: verify — czy węzeł realnie pobiera obrazy z mirrora
# ---------------------------------------------------------------------------
stage_verify() {
    log_section "Etap verify: test pobrania z mirrora"
    local digest node img
    digest=$(oc get clusterversion version -o jsonpath='{.status.desired.image}' | sed -n 's/.*@//p')
    img="${REG_HOST}/${REG_NS}/openshift/release-images@${digest}"
    node=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
    node="${node:-$(oc get nodes -o jsonpath='{.items[0].metadata.name}')}"

    log_info "Węzeł $node: crictl pull $img"
    log_info "(sprawdza jednocześnie DNS, zaufanie do CA, pull secret i obecność bieżącego release w mirrorze)"
    if oc debug "node/$node" --quiet -- chroot /host crictl pull "$img" >"$TMP_DIR/pull.txt" 2>&1; then
        log_ok "Węzeł pobrał obraz release z mirrora"
    else
        log_error "Węzeł NIE pobrał obrazu z mirrora:"
        sed 's/^/         /' "$TMP_DIR/pull.txt" | tail -5
    fi

    oc get catalogsources.operators.coreos.com -n openshift-marketplace -o json | jq -r '.items[]
        | "\(.metadata.name)\t\(.status.connectionState.lastObservedState // "?")"' \
        | while IFS=$'\t' read -r n st; do
            if [[ "$st" == "READY" ]]; then log_ok "CatalogSource $n: READY"; else log_warn "CatalogSource $n: $st"; fi
        done

    oc get mcp -o json | jq -r '.items[] | "\(.metadata.name)\t\([.status.conditions[] | select(.type=="Updated")][0].status)"' \
        | while IFS=$'\t' read -r n st; do
            if [[ "$st" == "True" ]]; then log_ok "MCP $n: Updated"; else log_warn "MCP $n: w trakcie aktualizacji"; fi
        done
    log_info "Pełny test przed odcięciem internetu: docs/INSTRUKCJA.md, rozdział 'Weryfikacja'."
}

# ---------------------------------------------------------------------------
# Etap: osus — lokalny OpenShift Update Service
# ---------------------------------------------------------------------------
stage_osus() {
    log_section "Etap osus: lokalny OpenShift Update Service (namespace ${OSUS_NS})"

    local us source
    us=$(resources_of_kind UpdateService | head -1)
    [[ -n "$us" ]] || die "Brak UpdateService w $RES_DIR — ustaw platform.graph: true i zmirroruj ponownie"
    source=$(jq -rs --arg tag "$CATALOG_TAG" '[.[] | select(.kind == "CatalogSource"
                 and (.spec.image | test("/redhat-operator-index:" + $tag + "$"))) | .metadata.name] | first // empty' \
             "$TMP_DIR/resources.jsonl")
    [[ -n "$source" ]] || die "Brak katalogu redhat-operator-index:${CATALOG_TAG} z pakietem cincinnati-operator"

    oc_mut apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${OSUS_NS}
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: update-service-operator-group
  namespace: ${OSUS_NS}
spec:
  targetNamespaces:
  - ${OSUS_NS}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: update-service-subscription
  namespace: ${OSUS_NS}
spec:
  channel: ${OSUS_CHANNEL}
  installPlanApproval: Automatic
  name: cincinnati-operator
  source: ${source}
  sourceNamespace: openshift-marketplace
EOF
    (( DRY_RUN )) && { log_info "Dry-run: pomijam oczekiwanie na operator i konfigurację CVO"; return 0; }

    wait_for "Operator OSUS zainstalowany (CSV Succeeded)" 900 bash -c \
        "oc get csv -n $OSUS_NS -o json | jq -e '.items[] | select(.metadata.name | startswith(\"update-service-operator\")) | select(.status.phase==\"Succeeded\")'"

    jq --arg ns "$OSUS_NS" '.metadata.namespace = $ns' <<<"$us" | oc apply -f -
    local us_name uri
    us_name=$(jq -r '.metadata.name' <<<"$us")
    wait_for "UpdateService $us_name udostępnia policyEngineURI" 900 bash -c \
        "oc get updateservice $us_name -n $OSUS_NS -o jsonpath='{.status.policyEngineURI}' | grep -q '^http'"
    uri="$(oc get updateservice "$us_name" -n "$OSUS_NS" -o jsonpath='{.status.policyEngineURI}')/api/upgrades_info/v1/graph"

    log_info "Lokalny graf: $uri"
    confirm "Przełączyć Cluster Version Operator na lokalny OSUS?" || { log_info "Pominięto zmianę CVO"; return 0; }
    oc patch clusterversion version --type=merge -p "{\"spec\":{\"upstream\":\"${uri}\"}}"
    log_ok "CVO używa lokalnego grafu aktualizacji"

    wait_for "CVO pobrał graf z lokalnego OSUS (RetrievedUpdates=True)" 300 bash -c \
        "oc get clusterversion version -o json | jq -e '.status.conditions[] | select(.type==\"RetrievedUpdates\" and .status==\"True\")'" \
        || log_info "Jeśli błąd x509: dodaj CA routera ingress do zaufanych (docs/INSTRUKCJA.md, 'OSUS i certyfikaty')"
}

# ---------------------------------------------------------------------------
# Etap: disconnect — wyłączenie Telemetry/Insights (po odcięciu internetu)
# ---------------------------------------------------------------------------
stage_disconnect() {
    log_section "Etap disconnect: usunięcie cloud.openshift.com z pull secret"
    oc get secret/pull-secret -n openshift-config \
        --template='{{index .data ".dockerconfigjson" | base64decode}}' >"$TMP_DIR/pull-secret.json"
    if ! jq -e '.auths["cloud.openshift.com"]' "$TMP_DIR/pull-secret.json" &>/dev/null; then
        log_ok "cloud.openshift.com już usunięte"
        return 0
    fi
    log_info "Bez tego wpisu klaster przestaje wysyłać Telemetry, a Insights Operator nie przechodzi w Degraded."
    confirm "Usunąć cloud.openshift.com z globalnego pull secret?" || { log_info "Pominięto"; return 0; }
    jq 'del(.auths["cloud.openshift.com"])' "$TMP_DIR/pull-secret.json" >"$TMP_DIR/pull-secret.new.json"
    oc_mut set data secret/pull-secret -n openshift-config \
        --from-file=.dockerconfigjson="$TMP_DIR/pull-secret.new.json"
    log_ok "Usunięto cloud.openshift.com (sprawdź: oc get co insights)"
}

# ---------------------------------------------------------------------------
# Główna pętla
# ---------------------------------------------------------------------------
log_header "KONFIGURACJA KLASTRA DLA MIRRORA ${REG_HOST}$( (( DRY_RUN )) && echo ' (DRY-RUN)')"
echo "  Klaster : $(oc whoami --show-server) (wersja $CURRENT)"
echo "  Etapy   : $STAGES"
echo "  Zasoby  : $RES_DIR"

load_resources

IFS=',' read -r -a STAGE_LIST <<<"$STAGES"
for stage in "${STAGE_LIST[@]}"; do
    case "$stage" in
        trust|pullsecret|mirrors|catalogs|verify|osus|disconnect) "stage_${stage}" ;;
        *) die "Nieznany etap: $stage" ;;
    esac
done

log_header "ZAKOŃCZONO — ostrzeżenia: ${WARNINGS}, błędy: ${ERRORS}"
(( ERRORS == 0 )) || exit 2
