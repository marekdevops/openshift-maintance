# ocmirror — aktualizacja OpenShift 4.20+ bez dostępu klastra do internetu

Zestaw skryptów i procedura do aktualizacji klastra OpenShift, który **traci dostęp do internetu**.
Wszystkie obrazy (release OpenShift, operatory, graf aktualizacji) są pobierane przez **bastion**
i udostępniane klastrowi z lokalnego rejestru **mirror registry for Red Hat OpenShift**
(„mini Quay” uruchomiony w Podman).

Podejście jest zgodne z metodami **preferowanymi przez Red Hat** dla środowisk disconnected
(dokumentacja OCP 4.21, *Disconnected environments*, rozdz. 1.2):

| Obszar | Wybrana metoda | Dlaczego |
|---|---|---|
| Mirror obrazów | **oc-mirror plugin v2** | preferowane narzędzie od 4.18; generuje IDMS/ITMS zamiast przestarzałego ICSP; cache i wznawianie |
| Rejestr | **mirror registry for Red Hat OpenShift** (mini Quay) | w cenie subskrypcji OCP; wspierany dla obrazów release i operatorów Red Hat |
| Aktualizacje | **lokalny OpenShift Update Service (OSUS)** | klaster dostaje te same rekomendacje i ostrzeżenia co online |
| Workflow | **mirror-to-disk + disk-to-mirror** (na bastionie) | cache → wznowienie po awarii, przyrostowość, kasowanie starych obrazów; archiwum jako artefakt audytowy |

## Architektura

```
         INTERNET                         SIEĆ BANKU (bez internetu dla klastra)
 ┌──────────────────────────┐     ┌───────────────────────────────────────────────────────┐
 │ registry.redhat.io       │     │  BASTION (RHEL 9)                                     │
 │ quay.io / cdn*.quay.io   │ 443 │  ┌──────────────┐   ┌──────────────────────────────┐  │
 │ registry.connect.redhat  │◄────┼──┤  oc-mirror v2 ├──►│ mini Quay :8443 (Podman)     │  │
 │ api.openshift.com (graf) │     │  │  cache/archive│   │ /data/quay  (≈0,5–1 TB)      │  │
 │ mirror.openshift.com     │     │  └──────────────┘   └──────────────┬───────────────┘  │
 └──────────────────────────┘     │  oc (cluster-admin)                │ 8443/tcp         │
                                  │        │ 6443/tcp                  │                  │
                                  │        ▼                           ▼                  │
                                  │  ┌──────────────────────────────────────────────┐     │
                                  │  │ KLASTER OpenShift                            │     │
                                  │  │  IDMS/ITMS: quay.io, registry.redhat.io ...  │     │
                                  │  │     → bastion:8443/ocp/...                   │     │
                                  │  │  CatalogSource cs-* → indeksy z mirrora      │     │
                                  │  │  OSUS → graf z obrazu graph-image            │     │
                                  │  └──────────────────────────────────────────────┘     │
                                  └───────────────────────────────────────────────────────┘
```

Klaster **nie zmienia nazw obrazów** — nadal prosi o `quay.io/openshift-release-dev/...`
czy `registry.redhat.io/...`. Obiekty **ImageDigestMirrorSet (IDMS)** / **ImageTagMirrorSet (ITMS)**
mówią CRI-O na każdym węźle: „zanim pójdziesz do internetu, pobierz to z `bastion:8443/ocp/...`”.

## Zawartość

```
ocmirror/
├── bin/
│   ├── 00-inspect-quay.sh        # inwentaryzacja istniejącego mini Quay (też z sudo) -> sekcja registry: (tylko odczyt)
│   ├── 01-preflight.sh           # analiza klastra + graf aktualizacji Red Hat + szkic zmiennych (tylko odczyt)
│   ├── 02a-reinstall-quay.sh     # (sudo) czysta reinstalacja mini Quay: usuwa starą, nowe hasło init, CA, auth.json
│   ├── 02b-fix-quay-redis.sh     # (sudo) diagnoza i naprawa błędu Quay "WRONGPASS" / "Could not connect to Redis"
│   ├── 02-setup-bastion.sh       # oc, oc-mirror, opm, mini Quay, CA, firewall, auth.json (idempotentny)
│   ├── 03-generate-imageset.py   # mirror-vars.yaml -> ImageSetConfiguration (walidacja reguł oc-mirror)
│   ├── 04-mirror.sh              # oc-mirror v2: m2d / d2m / m2m, logi, kopia cluster-resources
│   └── 05-configure-cluster.sh   # etapy: trust, pullsecret, mirrors, catalogs, verify, osus, disconnect
├── lib/
│   ├── common.sh                 # logowanie, walidacja, odczyt zmiennych
│   ├── ocp_graph.py              # klient grafu aktualizacji (api.openshift.com lub lokalny OSUS)
│   ├── yamlq.py / yaml2json.py   # odczyt YAML bez zewnętrznych narzędzi (yq)
├── config/
│   └── mirror-vars.example.yaml  # JEDYNE źródło prawdy: wersje, operatory, rejestr — z opisem pól
└── docs/
    └── INSTRUKCJA.md             # pełna procedura krok po kroku (dla osób mniej znających OpenShift)
```

## Szybki start

Wszystko uruchamiasz **na bastionie**, jako dedykowany użytkownik (np. `mirror`) z `sudo`,
zalogowany do klastra (`oc login`) jako `cluster-admin`.

```bash
# (mini Quay od zera / reinstalacja jako root — usuwa poprzednią instalację i jej obrazy)
sudo bin/02a-reinstall-quay.sh -f config/mirror-vars.yaml -p ~/pull-secret.txt --plan   # podgląd
sudo bin/02a-reinstall-quay.sh -f config/mirror-vars.yaml -p ~/pull-secret.txt

# (jeśli mini Quay już działa na bastionie — np. uruchomiony przez sudo)
bin/00-inspect-quay.sh --export-ca /data/oc-mirror/auth/quay-rootCA.pem
#    -> gotowa sekcja registry: do mirror-vars.yaml

# 0. Analiza klastra i możliwych aktualizacji (tylko odczyt)
bin/01-preflight.sh
#    -> reports/<klaster>-<data>/{preflight-report.txt, mirror-vars.yaml, operators.json, update-path.json}

# 1. Zmienne: przejrzyj szkic, uzupełnij sekcję registry, zapisz jako config/mirror-vars.yaml
cp reports/<klaster>-<data>/mirror-vars.yaml config/mirror-vars.yaml && vi config/mirror-vars.yaml

# 2. Bastion: narzędzia + mini Quay + zaufanie CA + auth.json
bin/02-setup-bastion.sh -f config/mirror-vars.yaml -p ~/pull-secret.txt

# 3. ImageSetConfiguration
bin/03-generate-imageset.py -f config/mirror-vars.yaml

# 4. Mirror (najpierw dry-run, potem właściwy)
bin/04-mirror.sh -f config/mirror-vars.yaml --dry-run
bin/04-mirror.sh -f config/mirror-vars.yaml

# 5. Klaster -> mirror (klaster JESZCZE ma internet — bezpieczny moment na test)
export MIRROR_PULL_USER='ocp+cluster_pull' MIRROR_PULL_PASSWORD='...'   # robot Quay, tylko odczyt
bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage all --dry-run
bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage all
bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage osus

# 6. Po odcięciu internetu klastrowi
bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage disconnect
```

Aktualizację samego klastra (`oc adm upgrade ...`) wykonuje człowiek, w oknie serwisowym —
patrz [docs/INSTRUKCJA.md](docs/INSTRUKCJA.md), rozdział 8.

## Wymagania

- Bastion: **RHEL 9** (lub 8), Podman ≥ 3.4.2, min. 4 vCPU / 16 GB RAM, **≥ 1 TB** na `/data`
- FQDN bastionu w **DNS** (nie `/etc/hosts`, nie IP), rozwiązywalny też z węzłów klastra
- Ruch: bastion → internet 443 (lista domen w instrukcji), węzły → bastion 8443/tcp, bastion → API 6443/tcp
- Pull secret z <https://console.redhat.com/openshift/downloads>
- Pakiety: `jq`, `python3-pyyaml`, `curl`, `openssl` (02-setup-bastion.sh doinstaluje brakujące)

## Konwencje skryptów

- `set -euo pipefail`, jeden plik = jedno zadanie, numeracja = kolejność.
- Kody wyjścia: `0` OK, `1` ostrzeżenia, `2` błąd.
- Skrypty zmieniające klaster mają `--dry-run` (walidacja po stronie API) i pytają o potwierdzenie
  przed zmianami, które mogą restartować węzły (`--yes` dla automatyzacji).
- Idempotencja: każdy krok można powtórzyć; wykonane kroki są pomijane.
- Sekrety nie trafiają do logów ani do repozytorium (`auth/` ma prawa `700`, pliki `600`).
