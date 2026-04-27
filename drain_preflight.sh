#!/usr/bin/env bash
# drain_preflight.sh — Pasywna analiza Namespace pod kątem gotowości na oc adm node drain
#
# Użycie:
#   ./drain_preflight.sh <namespace> [node]
#
# Argumenty:
#   namespace  — obowiązkowy; namespace do przeanalizowania
#   node       — opcjonalny; jeśli podany, sprawdzane są tylko pody na tym węźle
#
# Skrypt jest TYLKO DO ODCZYTU — nie modyfikuje klastra, nie usuwa podów.
# Wyjście: raport w stdout + kod wyjścia: 0=OK, 1=ostrzeżenia, 2=błędy krytyczne

set -euo pipefail

# ---------------------------------------------------------------------------
# Kolory i pomocnicze funkcje wydruku
# ---------------------------------------------------------------------------

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

WARNINGS=0
ERRORS=0

_header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"; echo -e "${BOLD}${CYAN}  $*${RESET}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"; }
_section() { echo -e "\n${BOLD}▶ $*${RESET}"; }
_ok()      { echo -e "  ${GREEN}[OK]${RESET}  $*"; }
_warn()    { echo -e "  ${YELLOW}[WARN]${RESET} $*"; (( WARNINGS++ )) || true; }
_error()   { echo -e "  ${RED}[ERR]${RESET}  $*"; (( ERRORS++ )) || true; }
_info()    { echo -e "  ${CYAN}[INFO]${RESET} $*"; }

# ---------------------------------------------------------------------------
# Walidacja argumentów i wymagań
# ---------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
    echo "Użycie: $0 <namespace> [node]"
    echo "  namespace — namespace do analizy (wymagany)"
    echo "  node      — węzeł do drenażu (opcjonalny; filtruje pody)"
    exit 1
fi

NAMESPACE="$1"
TARGET_NODE="${2:-}"

# Sprawdź czy oc jest dostępne i zalogowane
if ! oc whoami &>/dev/null; then
    echo -e "${RED}BŁĄD: Brak aktywnej sesji oc. Zaloguj się przez 'oc login'.${RESET}"
    exit 2
fi

# Sprawdź czy namespace istnieje
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}BŁĄD: Namespace '${NAMESPACE}' nie istnieje.${RESET}"
    exit 2
fi

# ---------------------------------------------------------------------------
# Nagłówek raportu
# ---------------------------------------------------------------------------

_header "OCP DRAIN PREFLIGHT — Namespace: ${NAMESPACE}"
echo -e "  Klaster : $(oc whoami --show-server)"
echo -e "  Użytkownik: $(oc whoami)"
echo -e "  Data    : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
[[ -n "$TARGET_NODE" ]] && echo -e "  Węzeł   : ${TARGET_NODE}"

# ---------------------------------------------------------------------------
# 1. Pod Disruption Budgets
# ---------------------------------------------------------------------------
_section "1. Pod Disruption Budgets (PDB)"

# Pobierz wszystkie pody w namespace z ich labelami
# Dla każdego Deploymentu sprawdź czy jest PDB
DEPLOYMENTS=$(oc get deployment -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
DEPLOY_COUNT=$(echo "$DEPLOYMENTS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('items',[])))")

PDBS=$(oc get pdb -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
PDB_COUNT=$(echo "$PDBS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('items',[])))")

_info "Deploymentów: ${DEPLOY_COUNT}, PDB: ${PDB_COUNT}"

# Dla każdego PDB sprawdź czy disruptionsAllowed > 0 i spójność selektora
echo "$PDBS" | python3 - <<'PYEOF'
import sys, json, os

data = json.load(sys.stdin)
RED    = '\033[0;31m'
YELLOW = '\033[1;33m'
GREEN  = '\033[0;32m'
RESET  = '\033[0m'

for pdb in data.get('items', []):
    name   = pdb['metadata']['name']
    spec   = pdb.get('spec', {})
    status = pdb.get('status', {})

    min_available      = spec.get('minAvailable')
    max_unavailable    = spec.get('maxUnavailable')
    disruptions_allowed = status.get('disruptionsAllowed', 0)
    current_healthy    = status.get('currentHealthy', 0)
    desired_healthy    = status.get('desiredHealthy', 0)
    expected_pods      = status.get('expectedPods', 0)

    # Wykryj blokujące PDB (disruptionsAllowed == 0)
    if disruptions_allowed == 0:
        print(f"  {RED}[ERR]{RESET}  PDB '{name}': disruptionsAllowed=0 — drain ZABLOKOWANY"
              f" (currentHealthy={current_healthy}, desiredHealthy={desired_healthy})")
    else:
        print(f"  {GREEN}[OK]{RESET}  PDB '{name}': disruptionsAllowed={disruptions_allowed}"
              f" (expectedPods={expected_pods})")

    # Wykryj PDB z minAvailable == replicas (zablokuje drain przy jednej replice)
    if isinstance(min_available, int) and min_available >= expected_pods > 0:
        print(f"  {YELLOW}[WARN]{RESET} PDB '{name}': minAvailable={min_available} >= expectedPods={expected_pods}"
              f" — niemożliwy drain bez naruszenia PDB")

    # Wykryj błędny maxUnavailable: 0
    if max_unavailable == 0 or max_unavailable == "0":
        print(f"  {RED}[ERR]{RESET}  PDB '{name}': maxUnavailable=0 — drain ZABLOKOWANY")

PYEOF

# Sprawdź Deploymenty bez PDB
echo "$DEPLOYMENTS" | python3 - <<PYEOF2
import sys, json

ns_env = """${NAMESPACE}"""
data = json.load(sys.stdin)

YELLOW = '\033[1;33m'
RESET  = '\033[0m'

for dep in data.get('items', []):
    name = dep['metadata']['name']
    replicas = dep.get('spec', {}).get('replicas', 1)
    labels = dep.get('spec', {}).get('selector', {}).get('matchLabels', {})
    # Wykryj brak PDB — sygnalizujemy, właściwa analiza selektorów wymaga korelacji z PDB
    # Tutaj uproszczenie: jeśli deployment ma replicas>1 bez PDB to WARN
    # (pełna korelacja selektor→PDB poniżej w sekcji 4)
    pass  # rzeczywista detekcja w sekcji PDB vs Deploy poniżej

PYEOF2

# Korelacja: które Deploymenty nie mają pasującego PDB
python3 <<PYEOF3
import subprocess, json, sys

ns = "${NAMESPACE}"
YELLOW = '\033[1;33m'
GREEN  = '\033[0;32m'
RESET  = '\033[0m'

def oc_json(args):
    r = subprocess.run(['oc'] + args, capture_output=True, text=True)
    if r.returncode != 0:
        return {'items': []}
    return json.loads(r.stdout)

deployments = oc_json(['get', 'deployment', '-n', ns, '-o', 'json'])
pdbs        = oc_json(['get', 'pdb',        '-n', ns, '-o', 'json'])

def labels_match(selector, pod_labels):
    return all(pod_labels.get(k) == v for k, v in selector.items())

for dep in deployments['items']:
    dep_name = dep['metadata']['name']
    dep_sel  = dep.get('spec', {}).get('selector', {}).get('matchLabels', {})
    replicas = dep.get('spec', {}).get('replicas', 1)

    matched_pdb = None
    for pdb in pdbs['items']:
        pdb_sel = pdb.get('spec', {}).get('selector', {}).get('matchLabels', {})
        if pdb_sel and labels_match(pdb_sel, dep_sel):
            matched_pdb = pdb['metadata']['name']
            break

    if matched_pdb is None:
        if replicas > 1:
            print(f"  {YELLOW}[WARN]{RESET} Deployment '{dep_name}' (replicas={replicas}): brak PDB — pody mogą zostać przerwane bez kontroli")
        else:
            print(f"  {YELLOW}[WARN]{RESET} Deployment '{dep_name}' (replicas=1): brak PDB i pojedyncza replika — chwilowy downtime podczas drain")
    else:
        print(f"  {GREEN}[OK]{RESET}  Deployment '{dep_name}' pokryty przez PDB '{matched_pdb}'")

PYEOF3

# ---------------------------------------------------------------------------
# 2. Local Storage — emptyDir i Local PV
# ---------------------------------------------------------------------------
_section "2. Local Storage (emptyDir / local PV)"

PODS_JSON=$(oc get pods -n "$NAMESPACE" \
    ${TARGET_NODE:+--field-selector="spec.nodeName=${TARGET_NODE}"} \
    -o json 2>/dev/null || echo '{"items":[]}')

echo "$PODS_JSON" | python3 <<'PYEOF'
import sys, json

data = json.load(sys.stdin)

YELLOW = '\033[1;33m'
RED    = '\033[0;31m'
GREEN  = '\033[0;32m'
RESET  = '\033[0m'

found = False
for pod in data.get('items', []):
    pod_name = pod['metadata']['name']
    phase    = pod.get('status', {}).get('phase', '')
    if phase not in ('Running', 'Pending'):
        continue

    volumes = pod.get('spec', {}).get('volumes', [])
    for vol in volumes:
        # emptyDir bez limitu rozmiaru
        if 'emptyDir' in vol:
            ed = vol['emptyDir']
            size_limit = ed.get('sizeLimit')
            if not size_limit:
                print(f"  {YELLOW}[WARN]{RESET} Pod '{pod_name}': emptyDir '{vol['name']}' bez sizeLimit — dane utracone po drain, może zajmować nieograniczone miejsce na hoście")
            else:
                print(f"  {GREEN}[OK]{RESET}  Pod '{pod_name}': emptyDir '{vol['name']}' z sizeLimit={size_limit}")
            found = True

        # hostPath — dane powiązane z konkretnym węzłem
        if 'hostPath' in vol:
            hp = vol['hostPath']
            print(f"  {RED}[ERR]{RESET}  Pod '{pod_name}': hostPath '{vol['name']}' → {hp.get('path','?')} — dane TYLKO na tym węźle, drain przerwie dostęp")
            found = True

if not found:
    print(f"  \033[0;32m[OK]\033[0m  Brak woluminów emptyDir/hostPath w działających podach")
PYEOF

# Local PV — PV z storageClassName "local-*" lub volumeMode Block powiązane z namespace
_info "Sprawdzam Local PersistentVolumes..."
python3 <<PYEOF4
import subprocess, json

ns    = "${NAMESPACE}"
RED   = '\033[0;31m'
YELLOW= '\033[1;33m'
GREEN = '\033[0;32m'
RESET = '\033[0m'

def oc_json(args):
    r = subprocess.run(['oc'] + args, capture_output=True, text=True)
    if r.returncode != 0:
        return {'items': []}
    return json.loads(r.stdout)

pvcs = oc_json(['get', 'pvc', '-n', ns, '-o', 'json'])
pvs  = oc_json(['get', 'pv', '-o', 'json'])

pv_map = {pv['metadata']['name']: pv for pv in pvs.get('items', [])}

found = False
for pvc in pvcs.get('items', []):
    pvc_name = pvc['metadata']['name']
    pv_name  = pvc.get('spec', {}).get('volumeName', '')
    if not pv_name:
        continue
    pv = pv_map.get(pv_name, {})
    sc = pv.get('spec', {}).get('storageClassName', '')
    local = pv.get('spec', {}).get('local')
    node_aff = pv.get('spec', {}).get('nodeAffinity', {})

    if local or (sc and 'local' in sc.lower()):
        node_values = []
        for req in node_aff.get('required', {}).get('nodeSelectorTerms', []):
            for expr in req.get('matchExpressions', []):
                if expr.get('key') == 'kubernetes.io/hostname':
                    node_values = expr.get('values', [])
        print(f"  {RED}[ERR]{RESET}  PVC '{pvc_name}' → PV '{pv_name}' (local): dane przywiązane do węzła {node_values} — pod nie może być zaplanowany na innym węźle")
        found = True

if not found:
    print(f"  {GREEN}[OK]{RESET}  Brak lokalnych PV powiązanych z namespace")
PYEOF4

# ---------------------------------------------------------------------------
# 3. PodAntiAffinity requiredDuringScheduling
# ---------------------------------------------------------------------------
_section "3. PodAntiAffinity (requiredDuringScheduling)"

echo "$PODS_JSON" | python3 <<'PYEOF'
import sys, json

data = json.load(sys.stdin)

RED    = '\033[0;31m'
YELLOW = '\033[1;33m'
GREEN  = '\033[0;32m'
RESET  = '\033[0m'

found = False
for pod in data.get('items', []):
    pod_name = pod['metadata']['name']
    phase    = pod.get('status', {}).get('phase', '')
    if phase not in ('Running', 'Pending'):
        continue

    affinity = pod.get('spec', {}).get('affinity', {})
    anti     = affinity.get('podAntiAffinity', {})
    required = anti.get('requiredDuringSchedulingIgnoredDuringExecution', [])

    for rule in required:
        topology = rule.get('topologyKey', '')
        selector = rule.get('labelSelector', {})
        sel_labels = selector.get('matchLabels', {})
        sel_exprs  = selector.get('matchExpressions', [])

        # Reguła per-node (kubernetes.io/hostname) = max 1 pod na węzeł
        if topology == 'kubernetes.io/hostname':
            print(f"  {RED}[ERR]{RESET}  Pod '{pod_name}': requiredAntiAffinity topologyKey=hostname"
                  f" (selector={sel_labels or sel_exprs}) — jeśli klaster ma za mało węzłów,"
                  f" pod NIE może być przeniesiony przed usunięciem oryginału")
        elif topology in ('topology.kubernetes.io/zone', 'topology.kubernetes.io/region'):
            print(f"  {YELLOW}[WARN]{RESET} Pod '{pod_name}': requiredAntiAffinity topologyKey={topology}"
                  f" — ogranicza rozmieszczenie do różnych stref; drain może się nie powieść w strefie z tylko jednym węzłem")
        else:
            print(f"  {YELLOW}[WARN]{RESET} Pod '{pod_name}': requiredAntiAffinity topologyKey={topology}"
                  f" — niestandardowa topologia; zweryfikuj dostępność węzłów")
        found = True

if not found:
    print(f"  \033[0;32m[OK]\033[0m  Brak reguł requiredDuringScheduling PodAntiAffinity")
PYEOF

# ---------------------------------------------------------------------------
# 4. Deploymenty z replicas: 1
# ---------------------------------------------------------------------------
_section "4. Single-replica Deployments (replicas=1)"

python3 <<PYEOF5
import subprocess, json

ns     = "${NAMESPACE}"
RED    = '\033[0;31m'
YELLOW = '\033[1;33m'
GREEN  = '\033[0;32m'
RESET  = '\033[0m'

def oc_json(args):
    r = subprocess.run(['oc'] + args, capture_output=True, text=True)
    if r.returncode != 0:
        return {'items': []}
    return json.loads(r.stdout)

deployments = oc_json(['get', 'deployment', '-n', ns, '-o', 'json'])
pdbs        = oc_json(['get', 'pdb',        '-n', ns, '-o', 'json'])

def pdb_for(dep_labels):
    for pdb in pdbs['items']:
        sel = pdb.get('spec', {}).get('selector', {}).get('matchLabels', {})
        if sel and all(dep_labels.get(k) == v for k, v in sel.items()):
            return pdb
    return None

single = []
multi  = []
for dep in deployments['items']:
    name     = dep['metadata']['name']
    replicas = dep.get('spec', {}).get('replicas', 1)
    dep_labels = dep.get('spec', {}).get('selector', {}).get('matchLabels', {})
    pdb      = pdb_for(dep_labels)

    if replicas == 1:
        single.append((name, pdb['metadata']['name'] if pdb else None))
    else:
        multi.append((name, replicas, pdb['metadata']['name'] if pdb else None))

for name, pdb_name in single:
    if pdb_name:
        print(f"  {YELLOW}[WARN]{RESET} Deployment '{name}': replicas=1, PDB='{pdb_name}' — drain spowoduje chwilowy downtime; PDB może zablokować jeśli minAvailable=1")
    else:
        print(f"  {RED}[ERR]{RESET}  Deployment '{name}': replicas=1, brak PDB — drain PRZERWIE działanie serwisu")

for name, reps, pdb_name in multi:
    if pdb_name:
        print(f"  {GREEN}[OK]{RESET}  Deployment '{name}': replicas={reps}, PDB='{pdb_name}'")
    else:
        print(f"  {YELLOW}[WARN]{RESET} Deployment '{name}': replicas={reps}, brak PDB — możliwe przerwy podczas drain")

if not single and not multi:
    print(f"  {GREEN}[OK]{RESET}  Brak Deploymentów w namespace")
PYEOF5

# ---------------------------------------------------------------------------
# 5. PVC ReadWriteOnce (RWO) — analiza stref i węzłów
# ---------------------------------------------------------------------------
_section "5. PVC ReadWriteOnce (RWO) — strefy i węzły"

python3 <<PYEOF6
import subprocess, json

ns     = "${NAMESPACE}"
node_filter = "${TARGET_NODE}"
RED    = '\033[0;31m'
YELLOW = '\033[1;33m'
GREEN  = '\033[0;32m'
RESET  = '\033[0m'

def oc_json(args):
    r = subprocess.run(['oc'] + args, capture_output=True, text=True)
    if r.returncode != 0:
        return {'items': []}
    return json.loads(r.stdout)

pvcs   = oc_json(['get', 'pvc', '-n', ns, '-o', 'json'])
pods   = oc_json(['get', 'pods', '-n', ns, '-o', 'json'])
pvs    = oc_json(['get', 'pv', '-o', 'json'])
nodes  = oc_json(['get', 'nodes', '-o', 'json'])

pv_map   = {pv['metadata']['name']: pv for pv in pvs.get('items', [])}
node_map = {n['metadata']['name']: n  for n in nodes.get('items', [])}

# Mapa: pvc_name → lista podów używających PVC
pvc_to_pods = {}
for pod in pods.get('items', []):
    pod_name  = pod['metadata']['name']
    pod_node  = pod.get('spec', {}).get('nodeName', '')
    pod_phase = pod.get('status', {}).get('phase', '')
    if pod_phase not in ('Running', 'Pending'):
        continue
    for vol in pod.get('spec', {}).get('volumes', []):
        pvc_ref = vol.get('persistentVolumeClaim', {}).get('claimName')
        if pvc_ref:
            pvc_to_pods.setdefault(pvc_ref, []).append({'pod': pod_name, 'node': pod_node})

for pvc in pvcs.get('items', []):
    pvc_name   = pvc['metadata']['name']
    access     = pvc.get('spec', {}).get('accessModes', [])
    pv_name    = pvc.get('spec', {}).get('volumeName', '')
    sc_name    = pvc.get('spec', {}).get('storageClassName', '')
    phase      = pvc.get('status', {}).get('phase', '')

    if 'ReadWriteOnce' not in access:
        continue  # RWX / ROX nie blokują drain

    pv  = pv_map.get(pv_name, {})
    pv_node_aff = pv.get('spec', {}).get('nodeAffinity', {})

    # Ustal węzeł(y), do których PV jest przypisany (nodeAffinity)
    pv_nodes = []
    for term in pv_node_aff.get('required', {}).get('nodeSelectorTerms', []):
        for expr in term.get('matchExpressions', []):
            if expr.get('key') == 'kubernetes.io/hostname':
                pv_nodes = expr.get('values', [])

    # Strefa węzła, gdzie PV jest zamontowany
    pv_zones = []
    for pv_node_name in pv_nodes:
        n = node_map.get(pv_node_name, {})
        zone = n.get('metadata', {}).get('labels', {}).get('topology.kubernetes.io/zone', '')
        if zone:
            pv_zones.append(zone)

    using_pods = pvc_to_pods.get(pvc_name, [])

    if not using_pods:
        print(f"  {GREEN}[OK]{RESET}  PVC '{pvc_name}' (RWO, {sc_name}): nieużywane przez żaden pod")
        continue

    for info in using_pods:
        pod_name = info['pod']
        pod_node = info['node']
        pod_zone = node_map.get(pod_node, {}).get('metadata', {}).get('labels', {}).get('topology.kubernetes.io/zone', 'unknown')

        # Sprawdź czy PV jest przypisany do innego węzła niż docelowy po drenie
        if pv_nodes and pod_node and pod_node not in pv_nodes:
            print(f"  {RED}[ERR]{RESET}  PVC '{pvc_name}' (RWO): Pod '{pod_name}' na węźle {pod_node}"
                  f" ale PV '{pv_name}' przywiązany do {pv_nodes} — relokacja NIEMOŻLIWA bez zmiany węzła storage")
        elif pv_nodes:
            print(f"  {YELLOW}[WARN]{RESET} PVC '{pvc_name}' (RWO): Pod '{pod_name}' na {pod_node}"
                  f", PV na {pv_nodes} — po drain pod MUSI wrócić na ten sam węzeł (lub ten z PV)")
        else:
            # Brak nodeAffinity w PV — sprawdź strefę
            if pv_zones and pod_zone not in pv_zones:
                print(f"  {RED}[ERR]{RESET}  PVC '{pvc_name}' (RWO): Pod w strefie {pod_zone}"
                      f" ale PV w strefach {pv_zones} — cross-zone relokacja przerwie dostęp")
            else:
                print(f"  {YELLOW}[WARN]{RESET} PVC '{pvc_name}' (RWO): Pod '{pod_name}' używa RWO — po drain scheduler MUSI"
                      f" przydzielić pod do węzła w tej samej strefie ({pod_zone})")

        # Jeśli filtrujemy po węźle i pod jest na tym węźle
        if node_filter and pod_node == node_filter:
            print(f"           → Pod jest na drenowanym węźle {node_filter} — wymaga relokacji RWO")

PYEOF6

# ---------------------------------------------------------------------------
# 6. terminationGracePeriodSeconds
# ---------------------------------------------------------------------------
_section "6. terminationGracePeriodSeconds"

GRACE_THRESHOLD=120  # sekundy — powyżej tego progu sygnalizujemy ostrzeżenie
GRACE_CRITICAL=600   # sekundy — powyżej tego progu sygnalizujemy błąd

echo "$PODS_JSON" | python3 - <<PYEOF7
import sys, json

data = json.load(sys.stdin)

THRESHOLD = ${GRACE_THRESHOLD}
CRITICAL  = ${GRACE_CRITICAL}

RED    = '\033[0;31m'
YELLOW = '\033[1;33m'
GREEN  = '\033[0;32m'
RESET  = '\033[0m'

long_grace = []
ok_pods    = 0

for pod in data.get('items', []):
    pod_name = pod['metadata']['name']
    phase    = pod.get('status', {}).get('phase', '')
    if phase not in ('Running', 'Pending'):
        continue

    grace = pod.get('spec', {}).get('terminationGracePeriodSeconds', 30)  # domyślnie 30s

    if grace >= CRITICAL:
        print(f"  {RED}[ERR]{RESET}  Pod '{pod_name}': terminationGracePeriodSeconds={grace}s (>{CRITICAL}s)"
              f" — drain będzie zablokowany na {grace}s jeśli app nie zakończy się wcześniej")
        long_grace.append(pod_name)
    elif grace > THRESHOLD:
        print(f"  {YELLOW}[WARN]{RESET} Pod '{pod_name}': terminationGracePeriodSeconds={grace}s (>{THRESHOLD}s)"
              f" — drain może trwać dłużej niż oczekiwano")
        long_grace.append(pod_name)
    else:
        ok_pods += 1

if ok_pods > 0:
    print(f"  {GREEN}[OK]{RESET}  {ok_pods} pod(ów) z terminationGracePeriodSeconds ≤ {THRESHOLD}s")
if not long_grace and ok_pods == 0:
    print(f"  {GREEN}[OK]{RESET}  Brak działających podów do sprawdzenia")

PYEOF7

# ---------------------------------------------------------------------------
# 7. Symulacja drain — co zostałoby wyparte (--dry-run)
# ---------------------------------------------------------------------------
_section "7. Symulacja drain (oc adm drain --dry-run)"

if [[ -n "$TARGET_NODE" ]]; then
    _info "Uruchamianie: oc adm drain ${TARGET_NODE} --ignore-daemonsets --delete-emptydir-data --dry-run"
    echo ""
    oc adm drain "$TARGET_NODE" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --dry-run=client \
        2>&1 | sed 's/^/  /' || true
else
    _info "Pomiń symulację drain — nie podano węzła (argument 2)"
    _info "Aby uruchomić symulację: $0 ${NAMESPACE} <node-name>"
fi

# ---------------------------------------------------------------------------
# Podsumowanie
# ---------------------------------------------------------------------------
_header "PODSUMOWANIE"

TOTAL=$((WARNINGS + ERRORS))

if [[ $ERRORS -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}WYNIK: KRYTYCZNE PROBLEMY — ${ERRORS} błąd(ów), ${WARNINGS} ostrzeżenie(ń)${RESET}"
    echo -e "  ${RED}Drain może spowodować outage lub zakończyć się błędem.${RESET}"
    echo -e "  Zalecenia:"
    echo -e "    1. Napraw konfigurację PDB (minAvailable, maxUnavailable)"
    echo -e "    2. Usuń lub zmigruj dane z hostPath/local PV przed drain"
    echo -e "    3. Zwiększ liczbę replik Deploymentów produkcyjnych ≥ 2"
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}WYNIK: OSTRZEŻENIA — ${WARNINGS} ostrzeżenie(ń)${RESET}"
    echo -e "  ${YELLOW}Drain jest możliwy, ale wymaga uwagi na powyższe punkty.${RESET}"
else
    echo -e "  ${GREEN}${BOLD}WYNIK: OK — Namespace gotowy na drain${RESET}"
fi

echo ""
[[ $ERRORS -gt 0 ]] && exit 2
[[ $WARNINGS -gt 0 ]] && exit 1
exit 0
