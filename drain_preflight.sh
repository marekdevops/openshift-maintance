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
DEPLOYMENTS=$(oc get deployment -n "$NAMESPACE" -o json 2>/dev/null || true)
[[ -z "$DEPLOYMENTS" ]] && DEPLOYMENTS='{"items":[]}'
DEPLOY_COUNT=$(echo "$DEPLOYMENTS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get('items', [])))
except Exception:
    print(0)
")

PDBS=$(oc get pdb -n "$NAMESPACE" -o json 2>/dev/null || true)
[[ -z "$PDBS" ]] && PDBS='{"items":[]}'
PDB_COUNT=$(echo "$PDBS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get('items', [])))
except Exception:
    print(0)
")

_info "Deploymentów: ${DEPLOY_COUNT}, PDB: ${PDB_COUNT}"

# Dla każdego PDB sprawdź czy disruptionsAllowed > 0 i spójność selektora
echo "$PDBS" | python3 - <<'PYEOF'
import sys, json, os

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    data = {'items': []}
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
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    data = {'items': []}

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
    if r.returncode != 0 or not r.stdout.strip():
        return {'items': []}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {'items': []}

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

if [[ -n "$TARGET_NODE" ]]; then
    PODS_JSON=$(oc get pods -n "$NAMESPACE" --field-selector="spec.nodeName=${TARGET_NODE}" -o json 2>/dev/null || true)
else
    PODS_JSON=$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null || true)
fi
[[ -z "$PODS_JSON" ]] && PODS_JSON='{"items":[]}'

echo "$PODS_JSON" | python3 <<'PYEOF'
import sys, json

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    data = {'items': []}

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
    if r.returncode != 0 or not r.stdout.strip():
        return {'items': []}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {'items': []}

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

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    data = {'items': []}

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
    if r.returncode != 0 or not r.stdout.strip():
        return {'items': []}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {'items': []}

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
# 5. StatefulSets — repliki i pokrycie PDB
# ---------------------------------------------------------------------------
_section "5. StatefulSets — repliki i pokrycie PDB"

python3 <<PYEOF_STS
import subprocess, json

ns     = "${NAMESPACE}"
RED    = '\033[0;31m'
YELLOW = '\033[1;33m'
GREEN  = '\033[0;32m'
CYAN   = '\033[0;36m'
RESET  = '\033[0m'

def oc_json(args):
    r = subprocess.run(['oc'] + args, capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return {'items': []}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {'items': []}

stss = oc_json(['get', 'statefulset', '-n', ns, '-o', 'json'])
pdbs = oc_json(['get', 'pdb',         '-n', ns, '-o', 'json'])

if not stss['items']:
    print(f"  {GREEN}[OK]{RESET}  Brak StatefulSetów w namespace")

def pdb_for(sts_labels):
    for pdb in pdbs['items']:
        sel = pdb.get('spec', {}).get('selector', {}).get('matchLabels', {})
        if sel and all(sts_labels.get(k) == v for k, v in sel.items()):
            return pdb
    return None

for sts in stss['items']:
    name           = sts['metadata']['name']
    replicas       = sts.get('spec', {}).get('replicas', 1)
    ready          = sts.get('status', {}).get('readyReplicas', 0)
    labels         = sts.get('spec', {}).get('selector', {}).get('matchLabels', {})
    pod_mgmt       = sts.get('spec', {}).get('podManagementPolicy', 'OrderedReady')
    update_strat   = sts.get('spec', {}).get('updateStrategy', {}).get('type', 'RollingUpdate')
    pdb            = pdb_for(labels)
    pdb_name       = pdb['metadata']['name'] if pdb else None

    pdb_disruptions = pdb.get('status', {}).get('disruptionsAllowed', 0) if pdb else None
    pdb_min_avail   = pdb.get('spec', {}).get('minAvailable') if pdb else None
    pdb_max_unavail = pdb.get('spec', {}).get('maxUnavailable') if pdb else None

    # Zidentyfikuj typ komponentu po labelach (Strimzi, inne operatory)
    component_hint = ''
    for k, v in labels.items():
        if 'strimzi' in k:
            role = labels.get('strimzi.io/component-type', labels.get('strimzi.io/kind', ''))
            component_hint = f' [Strimzi:{role}]'
            break

    print(f"\n  {CYAN}StatefulSet '{name}'{component_hint}{RESET}"
          f"  replicas={replicas} ready={ready}  podManagement={pod_mgmt}")

    # Niegotowe repliki
    if ready < replicas:
        print(f"  {RED}[ERR]{RESET}  Nie wszystkie repliki gotowe ({ready}/{replicas})"
              f" — drain na tym etapie zwiększa ryzyko utraty kworum")

    # Pojedyncza replika
    if replicas == 1:
        if pdb_name:
            print(f"  {YELLOW}[WARN]{RESET} replicas=1, PDB='{pdb_name}'"
                  f" — drain spowoduje downtime; sprawdź czy minAvailable != 1")
        else:
            print(f"  {RED}[ERR]{RESET}  replicas=1, brak PDB"
                  f" — drain PRZERWIE działanie serwisu (brak HA)")
    else:
        if pdb_name:
            if pdb_disruptions == 0:
                print(f"  {RED}[ERR]{RESET}  PDB='{pdb_name}': disruptionsAllowed=0"
                      f" — drain ZABLOKOWANY do czasu powrotu wszystkich replik do Ready")
            else:
                print(f"  {GREEN}[OK]{RESET}  replicas={replicas}, PDB='{pdb_name}'"
                      f" disruptionsAllowed={pdb_disruptions}")
            # Wykryj maxUnavailable=0 w PDB
            if pdb_max_unavail == 0 or pdb_max_unavail == '0':
                print(f"  {RED}[ERR]{RESET}  PDB '{pdb_name}': maxUnavailable=0"
                      f" — każda ewakuacja poda blokuje drain")
            # Wykryj minAvailable >= replicas
            if isinstance(pdb_min_avail, int) and pdb_min_avail >= replicas:
                print(f"  {RED}[ERR]{RESET}  PDB '{pdb_name}': minAvailable={pdb_min_avail} >= replicas={replicas}"
                      f" — drain niemożliwy bez naruszenia PDB")
        else:
            print(f"  {YELLOW}[WARN]{RESET} replicas={replicas}, brak PDB"
                  f" — ewakuacja podów bez kontroli; możliwe przerwy w serwisie")

    # OrderedReady + drain = wolniejsza relokacja
    if pod_mgmt == 'OrderedReady':
        print(f"  {CYAN}[INFO]{RESET} podManagementPolicy=OrderedReady"
              f" — Kubernetes poczeka aż każdy pod będzie Ready przed ewakuacją kolejnego;"
              f" drain może trwać znacznie dłużej")

PYEOF_STS

# ---------------------------------------------------------------------------
# 6. Strimzi / Kafka — analiza specyficzna
# ---------------------------------------------------------------------------
_section "6. Strimzi / Kafka — analiza ryzyka drain"

python3 <<PYEOF_KAFKA
import subprocess, json, sys

ns          = "${NAMESPACE}"
node_filter = "${TARGET_NODE}"
RED    = '\033[0;31m'
YELLOW = '\033[1;33m'
GREEN  = '\033[0;32m'
CYAN   = '\033[0;36m'
BOLD   = '\033[1m'
RESET  = '\033[0m'

def oc_json(args):
    r = subprocess.run(['oc'] + args, capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return {'items': []}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {'items': []}

# Wykryj czy namespace zawiera Strimzi
kafka_crs = oc_json(['get', 'kafka', '-n', ns, '-o', 'json'])
if not kafka_crs['items']:
    print(f"  {GREEN}[OK]{RESET}  Brak zasobów Strimzi Kafka w namespace — sekcja pominięta")
    sys.exit(0)

pods  = oc_json(['get', 'pods',  '-n', ns, '-o', 'json'])
pdbs  = oc_json(['get', 'pdb',   '-n', ns, '-o', 'json'])
stss  = oc_json(['get', 'statefulset', '-n', ns, '-o', 'json'])
nodes = oc_json(['get', 'nodes', '-o', 'json'])

node_map = {n['metadata']['name']: n for n in nodes.get('items', [])}

# ── Dla każdego klastra Kafka ────────────────────────────────────────────────
for kafka in kafka_crs['items']:
    cluster = kafka['metadata']['name']
    spec    = kafka.get('spec', {})
    status  = kafka.get('status', {})

    kafka_spec  = spec.get('kafka', {})
    zk_spec     = spec.get('zookeeper', {})

    kafka_replicas = kafka_spec.get('replicas', 0)
    zk_replicas    = zk_spec.get('replicas', 0)

    print(f"\n  {BOLD}{CYAN}Klaster Kafka: '{cluster}'{RESET}")
    print(f"  {CYAN}[INFO]{RESET} Kafka brokerów: {kafka_replicas}   ZooKeeper: {zk_replicas}")

    # ── Quorum ZooKeeper ────────────────────────────────────────────────────
    if zk_replicas > 0:
        if zk_replicas < 3:
            print(f"  {RED}[ERR]{RESET}  ZooKeeper replicas={zk_replicas} < 3"
                  f" — brak kworum HA; drain jednego węzła ZK może zatrzymać cały klaster Kafka")
        elif zk_replicas % 2 == 0:
            print(f"  {YELLOW}[WARN]{RESET} ZooKeeper replicas={zk_replicas} (parzysta liczba)"
                  f" — ryzyko split-brain; zalecane 3 lub 5")
        else:
            tolerable = (zk_replicas - 1) // 2
            print(f"  {GREEN}[OK]{RESET}  ZooKeeper replicas={zk_replicas}"
                  f" — toleruje utratę {tolerable} węzła/węzłów bez utraty kworum")

    # ── Liczba brokerów vs bezpieczeństwo drain ─────────────────────────────
    if kafka_replicas < 3:
        print(f"  {RED}[ERR]{RESET}  Kafka brokerów={kafka_replicas} < 3"
              f" — drain jednego brokera może naruszyć replikację partycji")
    else:
        print(f"  {GREEN}[OK]{RESET}  Kafka brokerów={kafka_replicas}"
              f" — drain jednego brokera bezpieczny jeśli replication.factor >= 3")

    # ── min.insync.replicas z config Kafka ──────────────────────────────────
    kafka_config = kafka_spec.get('config', {})
    min_isr = kafka_config.get('min.insync.replicas')
    default_rf = kafka_config.get('default.replication.factor')
    offsets_rf = kafka_config.get('offsets.topic.replication.factor')

    if min_isr is not None:
        min_isr = int(min_isr)
        if kafka_replicas - 1 < min_isr:
            print(f"  {RED}[ERR]{RESET}  min.insync.replicas={min_isr}: po drain jednego brokera"
                  f" pozostałoby {kafka_replicas-1} brokerów < min.insync.replicas"
                  f" — PRODUCENCI ZACZNĄ DOSTAWAĆ NotEnoughReplicas")
        else:
            print(f"  {GREEN}[OK]{RESET}  min.insync.replicas={min_isr}"
                  f" — po drain jednego brokera pozostaje {kafka_replicas-1} >= {min_isr}")
    else:
        print(f"  {YELLOW}[WARN]{RESET} min.insync.replicas: nie ustawione w spec.kafka.config"
              f" — domyślnie 1 (niebezpieczne dla produkcji); zweryfikuj ręcznie")

    if default_rf:
        print(f"  {CYAN}[INFO]{RESET} default.replication.factor={default_rf}")
    if offsets_rf:
        print(f"  {CYAN}[INFO]{RESET} offsets.topic.replication.factor={offsets_rf}")

    # ── PDB dla brokerów i ZooKeepera ───────────────────────────────────────
    for role, label_val in [('kafka', 'kafka'), ('zookeeper', 'zookeeper')]:
        matched_pdb = None
        for pdb in pdbs['items']:
            sel = pdb.get('spec', {}).get('selector', {}).get('matchLabels', {})
            strimzi_name = sel.get('strimzi.io/cluster') or sel.get('strimzi.io/name', '')
            strimzi_kind = sel.get('strimzi.io/component-type', sel.get('strimzi.io/kind', ''))
            if (sel.get('strimzi.io/cluster') == cluster and
                    label_val in strimzi_kind.lower()):
                matched_pdb = pdb
                break
            # fallback: szukaj po nazwie poda
            if f'{cluster}-{label_val}' in strimzi_name:
                matched_pdb = pdb
                break

        if matched_pdb:
            da  = matched_pdb.get('status', {}).get('disruptionsAllowed', 0)
            exp = matched_pdb.get('status', {}).get('expectedPods', '?')
            mxu = matched_pdb.get('spec', {}).get('maxUnavailable')
            mna = matched_pdb.get('spec', {}).get('minAvailable')
            pdb_n = matched_pdb['metadata']['name']
            if da == 0:
                print(f"  {RED}[ERR]{RESET}  PDB '{pdb_n}' ({role}): disruptionsAllowed=0"
                      f" — drain ZABLOKOWANY; poczekaj aż wszystkie pody {role} będą Ready")
            else:
                print(f"  {GREEN}[OK]{RESET}  PDB '{pdb_n}' ({role}): disruptionsAllowed={da}"
                      f" (expectedPods={exp})"
                      + (f" maxUnavailable={mxu}" if mxu is not None else "")
                      + (f" minAvailable={mna}" if mna is not None else ""))
        else:
            print(f"  {YELLOW}[WARN]{RESET} Brak PDB dla {role} klastra '{cluster}'"
                  f" — Strimzi powinien tworzyć PDB automatycznie; sprawdź uprawnienia operatora")

    # ── Pody brokerów i ZK na drenowanym węźle ──────────────────────────────
    if node_filter:
        print(f"\n  {CYAN}[INFO]{RESET} Pody Kafka/ZK na węźle '{node_filter}':")
        found_on_node = False
        for pod in pods.get('items', []):
            pod_name  = pod['metadata']['name']
            pod_node  = pod.get('spec', {}).get('nodeName', '')
            pod_phase = pod.get('status', {}).get('phase', '')
            pod_labels = pod.get('metadata', {}).get('labels', {})
            if pod_node != node_filter:
                continue
            if pod_labels.get('strimzi.io/cluster') != cluster:
                continue
            role_label = pod_labels.get('strimzi.io/component-type',
                         pod_labels.get('strimzi.io/kind', 'unknown'))
            if 'kafka' in role_label.lower() or 'zookeeper' in role_label.lower():
                print(f"    {RED}[ERR]{RESET}  Pod '{pod_name}' ({role_label}, {pod_phase})"
                      f" JEST na drenowanym węźle — będzie ewakuowany")
                found_on_node = True
        if not found_on_node:
            print(f"    {GREEN}[OK]{RESET}  Brak podów Kafka/ZK na węźle '{node_filter}'")

# ── Kafka Connect / MirrorMaker / Bridge ────────────────────────────────────
for kind, label in [('kafkaconnect', 'KafkaConnect'),
                    ('kafkamirrormaker2', 'KafkaMirrorMaker2'),
                    ('kafkabridge', 'KafkaBridge')]:
    resources = oc_json(['get', kind, '-n', ns, '-o', 'json'])
    for res in resources.get('items', []):
        res_name = res['metadata']['name']
        replicas = res.get('spec', {}).get('replicas', 1)
        ready    = res.get('status', {}).get('readyReplicas', 0)
        if replicas == 1:
            print(f"  {YELLOW}[WARN]{RESET} {label} '{res_name}': replicas=1"
                  f" — drain spowoduje przerwę w działaniu (brak HA)")
        else:
            status_str = f"ready={ready}/{replicas}"
            if ready < replicas:
                print(f"  {RED}[ERR]{RESET}  {label} '{res_name}': {status_str}"
                      f" — nie wszystkie repliki gotowe przed drain")
            else:
                print(f"  {GREEN}[OK]{RESET}  {label} '{res_name}': {status_str}")

PYEOF_KAFKA

# ---------------------------------------------------------------------------
# 7. PVC ReadWriteOnce (RWO) — analiza stref i węzłów
# ---------------------------------------------------------------------------
_section "7. PVC ReadWriteOnce (RWO) — strefy i węzły"

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
    if r.returncode != 0 or not r.stdout.strip():
        return {'items': []}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {'items': []}

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
_section "8. terminationGracePeriodSeconds"

GRACE_THRESHOLD=120  # sekundy — powyżej tego progu sygnalizujemy ostrzeżenie
GRACE_CRITICAL=600   # sekundy — powyżej tego progu sygnalizujemy błąd

echo "$PODS_JSON" | python3 - <<PYEOF7
import sys, json

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    data = {'items': []}

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
_section "9. Symulacja drain (oc adm drain --dry-run)"

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
    echo ""
    echo -e "  ${BOLD}Ogólne zalecenia:${RESET}"
    echo -e "    • Napraw PDB: maxUnavailable >= 1 lub minAvailable < replicas"
    echo -e "    • Upewnij się że wszystkie pody są w stanie Ready przed drain"
    echo -e "    • Zwiększ liczbę replik do minimum 2 dla usług produkcyjnych"
    echo -e "    • Usuń/zmigruj dane z hostPath i local PV zanim ruszysz węzeł"
    echo ""
    echo -e "  ${BOLD}Jeśli namespace zawiera Strimzi/Kafka:${RESET}"
    echo -e "    • Sprawdź czy wszystkie brokery Kafka są w ISR (In-Sync Replicas)"
    echo -e "      oc exec <kafka-pod> -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe | grep -v 'Isr:.*Leader'"
    echo -e "    • Sprawdź under-replicated partitions PRZED drain:"
    echo -e "      oc exec <kafka-pod> -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions"
    echo -e "    • Po drain brokera poczekaj na pełną resynchronizację ISR zanim dreenujesz kolejny węzeł"
    echo -e "    • ZooKeeper: nigdy nie drenuj więcej niż (replicas-1)/2 węzłów jednocześnie"
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}WYNIK: OSTRZEŻENIA — ${WARNINGS} ostrzeżenie(ń)${RESET}"
    echo -e "  ${YELLOW}Drain jest możliwy, ale wymaga uwagi na powyższe punkty.${RESET}"
    echo ""
    echo -e "  ${BOLD}Przed drain zweryfikuj:${RESET}"
    echo -e "    • Czy PDB dla każdego StatefulSet/Deployment ma disruptionsAllowed >= 1"
    echo -e "    • Czy pody z RWO PVC mogą zostać zaplanowane na innym węźle w tej samej strefie"
    echo -e "    • Czas terminacji podów (sekcja 8) — uwzględnij go w oknie maintenance"
else
    echo -e "  ${GREEN}${BOLD}WYNIK: OK — Namespace gotowy na drain${RESET}"
    echo -e "  ${GREEN}Nie wykryto krytycznych problemów. Możesz kontynuować.${RESET}"
fi

echo ""
[[ $ERRORS -gt 0 ]] && exit 2
[[ $WARNINGS -gt 0 ]] && exit 1
exit 0
