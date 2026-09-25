# Aktualizacja OpenShift offline — instrukcja krok po kroku

> Dotyczy: OpenShift Container Platform **4.20 → 4.21+**, oc-mirror **v2**,
> mirror registry for Red Hat OpenShift **2.0.x** (mini Quay), bastion **RHEL 9**.
> Podstawa: oficjalna dokumentacja Red Hat OCP 4.21 *Disconnected environments*
> (rozdz. 2, 4, 5, 10, 11) — odnośniki na końcu dokumentu.

## Spis treści

1. [Jak czytać tę instrukcję](#1-jak-czytać-tę-instrukcję)
2. [Słowniczek](#2-słowniczek)
3. [Plan całości](#3-plan-całości)
4. [Faza A — bastion i mini Quay](#4-faza-a--bastion-i-mini-quay)
5. [Faza B — preflight: stan klastra i ścieżka aktualizacji](#5-faza-b--preflight-stan-klastra-i-ścieżka-aktualizacji)
6. [Faza C — plik zmiennych i ImageSetConfiguration](#6-faza-c--plik-zmiennych-i-imagesetconfiguration)
7. [Faza D — mirror obrazów](#7-faza-d--mirror-obrazów)
8. [Faza E — przełączenie klastra na mirror](#8-faza-e--przełączenie-klastra-na-mirror)
9. [Faza F — odcięcie internetu](#9-faza-f--odcięcie-internetu)
10. [Faza G — aktualizacja klastra](#10-faza-g--aktualizacja-klastra)
11. [Kolejne aktualizacje (cykl stały)](#11-kolejne-aktualizacje-cykl-stały)
12. [Utrzymanie mini Quay](#12-utrzymanie-mini-quay)
13. [Rozwiązywanie problemów](#13-rozwiązywanie-problemów)
14. [Źródła](#14-źródła)

---

## 1. Jak czytać tę instrukcję

- Kroki wykonuj **po kolei**. Każda faza kończy się sekcją **„Gotowe, gdy…”** — nie przechodź dalej,
  dopóki warunki nie są spełnione.
- Bloki `bash` to polecenia do wykonania na **bastionie**, w katalogu `ocmirror/`,
  jako użytkownik `mirror` (chyba że napisano inaczej).
- Oznaczenia wpływu na klaster:
  - 🟢 tylko odczyt — można w dowolnej chwili,
  - 🟡 zmiana bez restartu węzłów,
  - 🔴 zmiana, która **może drenować i restartować węzły** (rolling, pula po puli) — tylko w oknie serwisowym.
- Faz A–E nie trzeba robić jednego dnia. **Fazy E i F wykonaj, zanim bank odetnie internet** —
  wtedy każdy błąd konfiguracji mirrora jest niegroźny, bo klaster wciąż może sięgnąć do źródła.

## 2. Słowniczek

| Pojęcie | Co to jest |
|---|---|
| **Release image** | Jeden obraz opisujący całą wersję OpenShift (np. 4.21.32) i ~190 obrazów komponentów. Aktualizacja klastra = wskazanie nowego release image. |
| **Kanał** (`stable-4.21`, `fast-4.21`, `eus-4.20`) | Lista wersji, które Red Hat uznał za gotowe. Kanał `stable-4.21` zawiera też wersje 4.20.z, z których prowadzą krawędzie do 4.21. |
| **Graf aktualizacji** | Mapa „z wersji X wolno przejść na Y”. Publikowany przez Red Hat (OpenShift Update Service, `api.openshift.com`). Krawędzie **warunkowe** = dozwolone, ale ze znanym ryzykiem. |
| **CVO** (Cluster Version Operator) | Komponent klastra, który pobiera graf i przeprowadza aktualizację. |
| **OSUS** (OpenShift Update Service) | Lokalna kopia usługi grafu. Działa w klastrze, dane bierze z obrazu `graph-image` zmirrorowanego przez oc-mirror. |
| **MCO / MCP** | Machine Config Operator / Machine Config Pool — zmienia konfigurację systemu węzłów, pula po puli (`master`, `worker`). Niektóre zmiany wymagają drenowania i restartu węzła. |
| **OLM** | Operator Lifecycle Manager — instaluje i aktualizuje operatory. |
| **CatalogSource** | Katalog operatorów (obraz „indeksu”, np. `redhat-operator-index:v4.21`). |
| **Subscription** | „Chcę operator X z kanału Y z katalogu Z” — OLM pilnuje aktualizacji. |
| **IDMS / ITMS** | ImageDigestMirrorSet / ImageTagMirrorSet — reguły „obraz ze źródła A pobieraj z mirrora B” (odpowiednio: obrazy po digest / po tagu). Następcy przestarzałego ICSP. |
| **Pull secret** | Poświadczenia do rejestrów, z których węzły pobierają obrazy (`openshift-config/pull-secret`). |
| **mini Quay** | *mirror registry for Red Hat OpenShift* — mały Quay w Podman, instalowany jednym poleceniem, w cenie subskrypcji OCP. |
| **oc-mirror v2** | Narzędzie Red Hat: czyta `ImageSetConfiguration`, kopiuje obrazy i generuje zasoby dla klastra (IDMS, ITMS, CatalogSource, UpdateService, podpisy). |
| **cache / workspace** | Katalogi oc-mirror: cache = pobrane warstwy obrazów (umożliwia przyrostowość i wznowienie), workspace/working-dir = wygenerowane zasoby i logi. |

## 3. Plan całości

| Faza | Co | Gdzie | Wpływ | Szac. czas |
|---|---|---|---|---|
| A | Bastion: narzędzia, mini Quay, konto robota | bastion | — | 1–2 h |
| B | Preflight: stan klastra, operatory, ścieżka | bastion → klaster, internet | 🟢 | 10 min |
| C | Plik zmiennych, ImageSetConfiguration | bastion | — | 30 min |
| D | Mirror obrazów | bastion ↔ internet | — | 2–8 h (łącze, liczba operatorów) |
| E | Klaster → mirror (CA, pull secret, IDMS, katalogi, OSUS) | bastion → klaster | 🟡 / 🔴 | 1–2 h + rollout MCP |
| F | Odcięcie internetu, wyłączenie Telemetry | klaster | 🟡 | 15 min |
| G | Aktualizacja klastra | klaster | 🔴 | 1–3 h na krok |

Zasada naczelna: **klaster pobiera wszystko z bastionu, bastion pobiera wszystko z internetu.**
Bastion ma internet na stałe, więc preflight i mirror zawsze korzystają z aktualnego grafu Red Hat.

---

## 4. Faza A — bastion i mini Quay

### 4.1. Wymagania bastionu

| Zasób | Wartość | Uwagi |
|---|---|---|
| System | RHEL 9 (lub 8), subskrypcja | Podman ≥ 3.4.2, OpenSSL |
| CPU / RAM | min. 4 vCPU / 16 GB | Red Hat: min. 2 vCPU / 8 GB dla samego rejestru; oc-mirror potrzebuje więcej |
| Dysk | **≥ 1 TB** na `/data` (osobny system plików, XFS) | Red Hat: ~12 GB na jedną wersję release, ~358 GB z operatorami Red Hat; zalecane do 1 TB na strumień. Obrazy są w Quay **i** w cache oc-mirror. |
| DNS | FQDN bastionu w DNS | wymóg mini Quay; musi się rozwiązywać także na **węzłach** klastra |
| Użytkownik | `mirror` (nie root) z `sudo` | mini Quay działa jako rootless Podman + `systemd --user` |

Przygotowanie (jako root, jednorazowo):

```bash
useradd -m mirror && passwd mirror
echo 'mirror ALL=(ALL) ALL' > /etc/sudoers.d/mirror      # lub zgodnie z polityką banku
mkdir -p /data/quay /data/oc-mirror && chown -R mirror:mirror /data/quay /data/oc-mirror
```

> Jeśli używasz Podman 5 / RHEL 9.5+ i pojawia się błąd `pasta failed ... External interface not usable`,
> ustaw w `~/.config/containers/containers.conf` sekcję `[network]` z
> `default_rootless_network_cmd = "slirp4netns"` i wykonaj `podman system migrate`
> (dokumentacja, rozdz. 4.3).

### 4.2. Firewall

**Bastion → internet (443/tcp)** — lista z dokumentacji *Configuring your firewall*:

| Domena | Po co |
|---|---|
| `registry.redhat.io` | obrazy Red Hat, katalogi operatorów |
| `registry.access.redhat.com`, `access.redhat.com` (lub `*.access.redhat.com`) | obrazy, magazyn podpisów |
| `quay.io`, `cdn.quay.io`, `cdn01..06.quay.io` (lub `*.quay.io`) | obrazy release OpenShift |
| `quayio-production-s3.s3.amazonaws.com` | warstwy obrazów quay.io |
| `registry.connect.redhat.com` | operatory certyfikowane (partnerzy) |
| `api.openshift.com` | graf aktualizacji |
| `mirror.openshift.com` | narzędzia (oc, oc-mirror, mini Quay), podpisy release, dane grafu |
| `console.redhat.com`, `sso.redhat.com` | pull secret / uwierzytelnianie |

> Rejestry przekierowują na CDN — nie blokuj `*.quay.io`, gdy zezwalasz na `quay.io`.
> Jeśli wychodzisz przez proxy, ustaw `https_proxy` / `no_proxy` dla użytkownika `mirror`
> (oc-mirror v2 respektuje systemowe ustawienia proxy). W `no_proxy` umieść FQDN bastionu i API klastra.

**Wewnątrz sieci banku:**

| Źródło | Cel | Port |
|---|---|---|
| wszystkie węzły klastra | bastion (mini Quay) | 8443/tcp |
| bastion | API klastra | 6443/tcp |
| bastion | router ingress klastra (weryfikacja OSUS) | 443/tcp |

### 4.3. Pull secret Red Hat

Pobierz z <https://console.redhat.com/openshift/downloads> → *Tokens* → *Pull secret*
i zapisz na bastionie jako `~/pull-secret.txt` (prawa `600`).

### 4.4. Czysta instalacja / reinstalacja mini Quay jako root (skrypt 02a)

Gdy Quay ma działać jako root (`sudo podman`) albo trzeba zacząć od zera (np. nieznane hasło `init`),
użyj `02a-reinstall-quay.sh`. **Usuwa poprzednią instalację razem z obrazami** (cache i archiwa
oc-mirror w `mirror.baseDir` zostają — obrazy wrócą przez `bin/04-mirror.sh --step d2m`).

```bash
sudo bin/02a-reinstall-quay.sh -f config/mirror-vars.yaml -p ~/pull-secret.txt --plan   # tylko podgląd
sudo bin/02a-reinstall-quay.sh -f config/mirror-vars.yaml -p ~/pull-secret.txt
```

| Krok | Co się dzieje |
|---|---|
| wymagania | DNS dla FQDN, sshd, pull secret, wolne miejsce, rozłączność katalogów Quay i oc-mirror |
| wykrycie | kontenery `quay-app/redis/postgres`, pod `quay-pod`, usługi `quay-*.service`, wolumeny, katalogi (z punktów montowania), port |
| potwierdzenie | trzeba **wpisać FQDN rejestru** (`--yes` pomija — tylko automatyzacja) |
| kopia | `quay-config` i `quay-rootCA` starej instalacji → `/root/quay-backup-<data>.tgz` |
| usunięcie | usługi, kontenery, pod, wolumeny, katalogi, stare CA z zaufanych; katalogi systemowe i `mirror.baseDir` są chronione |
| instalacja | `mirror-registry install --targetHostname localhost --targetUsername root --quayHostname <host:port> --quayRoot ... --initUser init --initPassword <nowe>` |
| hasło | losowe, 24 znaki, w `<katalog authFile>/quay-init-password` (0600, właściciel = użytkownik, który wywołał sudo); w logu zamaskowane |
| CA | zaufanie systemowe (`update-ca-trust`), `/etc/containers/certs.d/<host:port>/ca.crt`, kopia `quay-rootCA.pem` czytelna bez sudo |
| auth.json | **nowy**: pull secret Red Hat + `init@<host:port>`; stary plik → `auth.json.old-<data>` |
| weryfikacja | `/health/instance` z weryfikacją TLS, logowanie do Quay, registry.redhat.io, quay.io, registry.connect.redhat.com, usługi systemd |

Uwagi:

- **SSH:** instalator mirror-registry zawsze łączy się przez SSH, także lokalnie (tu: `root@localhost`
  kluczem `/root/.ssh/quay_installer`). Jeśli polityka banku ma `PermitRootLogin no`, dodaj
  `--temp-ssh-root`: skrypt tymczasowo dopuszcza roota **tylko z 127.0.0.1/::1**, sprawdza (`sshd -T`),
  że połączeń z zewnątrz to nie zmienia, i usuwa ustawienie po instalacji (także przy błędzie).
- **Certyfikat z PKI banku:** `--ssl-cert plik.crt --ssl-key plik.key --ssl-ca łańcuch-ca.pem`.
- **Proxy:** `sudo` czyści `https_proxy`. Jeśli bastion wychodzi przez proxy:
  `sudo --preserve-env=https_proxy,no_proxy,HTTPS_PROXY,NO_PROXY bin/02a-reinstall-quay.sh ...`
  (albo `--tarball` z wcześniej pobranym instalatorem).
- Po reinstalacji: nowa organizacja i robot (rozdz. 4.7), a jeśli klaster był już skonfigurowany —
  `05-configure-cluster.sh --stage trust,pullsecret` (nowe CA i nowy token robota).

### 4.4a. Quay nie wstaje: „Could not connect to Redis ... WRONGPASS" (skrypt 02b)

Objaw — instalacja `mirror-registry` kończy się `Quay did not become alive`, a w logach
`quay-app` (i w raporcie `HealthCheck` playbooka) widać:

```
| Redis | Could not connect to Redis with values provided in BUILDLOGS_REDIS.
          Error: WRONGPASS invalid username-password pair or user is disabled.
| Redis | Could not connect to Redis with values provided in USER_EVENTS_REDIS. ...
```

`quay-app.service` zostaje w pętli `activating (auto-restart)`.

Hasła do Redis **nie pochodzą z naszych skryptów** — generuje je instalator mirror-registry.
`WRONGPASS` znaczy dokładnie jedno: hasło zapisane w `<quayRoot>/quay-config/config.yaml`
(`BUILDLOGS_REDIS` / `USER_EVENTS_REDIS`) jest inne niż to, z którym wystartował kontener
`quay-redis`. Typowe przyczyny: instalator wygenerował dwa różne hasła (config i kontener),
albo `config.yaml` został z poprzedniej instalacji, albo kontener Redis przetrwał reinstalację.

```bash
sudo bin/02b-fix-quay-redis.sh -f config/mirror-vars.yaml --plan   # sama diagnoza, nic nie zmienia
sudo bin/02b-fix-quay-redis.sh -f config/mirror-vars.yaml          # diagnoza + naprawa
```

| Krok | Co się dzieje |
|---|---|
| konfiguracja | `config.yaml` z montowania `quay-app`, z unitu `quay-app.service` (działa też, gdy kontener jest w pętli restartów), z `registry.quayRoot` lub z typowych lokalizacji |
| kandydaci | hasła z `config.yaml`, z kontenera `quay-redis` (`REDIS_PASSWORD`, `--requirepass`) i z `quay-redis.service` |
| test | realne `AUTH` do Redis (`redis-cli PING`) dla każdego kandydata — w logu tylko skrót `sha256`, nie hasło |
| naprawa A | działa hasło Redis inne niż w `config.yaml` → wpis do `config.yaml` (obie sekcje) + restart `quay-app` |
| naprawa B | nie działa żadne (albo Redis bez hasła) → **nowe** hasło w `config.yaml` **i** w usłudze `quay-redis` (`--reset`), restart Redis i Quay |
| weryfikacja | `quay-app` wstaje i utrzymuje się, w logach nie ma już `WRONGPASS` |

Uwagi:

- Dane w Redis (logi buildów, zdarzenia UI) są ulotne — restart niczego nie niszczy.
  **Zmirrorowane obrazy w `quayStorage` nie są ruszane** — to naprawa zamiast reinstalacji.
- Poprzedni `config.yaml` trafia do `config.yaml.bak-<data>`. Plik jest przepisywany
  parserem YAML: wartości te same, komentarze i formatowanie mogą się zmienić.
- `--show-secrets` wypisuje hasła jawnie (domyślnie tylko `sha256:` i długość).
- Jeśli hasła nie ma ani w unicie, ani w pliku `--env-file`, zostaje czysta reinstalacja (4.4).

### 4.5. Mini Quay już zainstalowany? Inwentaryzacja (skrypt 00)

Jeśli mini Quay działa już na bastionie (np. zainstalowany i uruchamiany przez `sudo podman`),
nie instaluj go ponownie. Odczytaj jego ustawienia:

```bash
bin/00-inspect-quay.sh --export-ca /data/oc-mirror/auth/quay-rootCA.pem
# porównanie z istniejącym plikiem zmiennych:
bin/00-inspect-quay.sh -f config/mirror-vars.yaml -a /data/oc-mirror/auth/auth.json --export-ca /data/oc-mirror/auth/quay-rootCA.pem
```

Skrypt 🟢 tylko czyta. Sam wykrywa, czy Quay działa jako root (`sudo podman`), czy rootless, i sprawdza:

| Obszar | Skąd | Do którego pola |
|---|---|---|
| hostname:port | `SERVER_HOSTNAME` w `quay-config/config.yaml` | `registry.host` |
| katalog instalacji | punkt montowania `/quay-registry/conf/stack` kontenera `quay-app` | `registry.quayRoot` |
| dane obrazów / SQLite | punkty montowania `/datastorage`, `/sqlite` (wolumen Podman = pole puste) | `registry.quayStorage`, `registry.sqliteStorage` |
| CA | `<quayRoot>/quay-rootCA/rootCA.pem`, sprawdzone `openssl verify` względem `ssl.cert` | `registry.caFile` |
| organizacje z obrazami | `/v2/_catalog` z poświadczeniami z `auth.json` | `registry.namespace` |

Dodatkowo: stan kontenerów i usług systemd, SAN i termin ważności certyfikatu, DNS, port, firewall,
`/health/instance` z weryfikacją TLS, wolne miejsce. Sekrety z `config.yaml` nie są wypisywane.

> **Instalacja przez sudo:** pliki Quay (w tym CA) leżą wtedy w katalogu root (np. `/root/quay-install`),
> nieczytelnym dla użytkownika `mirror`. Opcja `--export-ca` kopiuje CA (to certyfikat publiczny)
> do wskazanego pliku z prawami `0644` — ten plik wpisz jako `registry.caFile`.
> Pozostałe skrypty uruchamiaj jak dotąd, jako `mirror`. `02-setup-bastion.sh` wykryje działający
> Quay i pominie instalację.

### 4.6. Narzędzia i instalacja rootless (skrypt 02)

Najpierw skopiuj przykładowe zmienne i uzupełnij sekcje `registry`, `mirror`, `tools`
(resztę uzupełni preflight w fazie B):

```bash
cp config/mirror-vars.example.yaml config/mirror-vars.yaml
vi config/mirror-vars.yaml
bin/02-setup-bastion.sh -f config/mirror-vars.yaml -p ~/pull-secret.txt
```

Co robi skrypt (każdy krok jest pomijany, jeśli już wykonany):

1. doinstalowuje `podman jq openssl python3-pyyaml`, włącza *linger* (usługi Quay działają po wylogowaniu),
2. sprawdza DNS dla FQDN rejestru,
3. pobiera `oc`, `oc-mirror`, `opm` z `mirror.openshift.com` i **weryfikuje sumy SHA256**,
4. instaluje mini Quay: `mirror-registry install --quayHostname <fqdn:8443> --quayRoot ... --quayStorage ... --sqliteStorage ...`
   (hasło użytkownika `init` w `/data/oc-mirror/auth/quay-init-password`, prawa `600`),
5. dodaje CA rejestru do zaufanych na bastionie (`update-ca-trust`), otwiera port w firewalld,
6. buduje `auth.json` = pull secret Red Hat + login do mini Quay (`podman login --authfile`),
7. weryfikuje `https://<fqdn>:8443/health/instance` z pełną weryfikacją TLS.

> **Certyfikat:** instalator generuje własne CA (`<quayRoot>/quay-rootCA/rootCA.pem`).
> W banku zwykle wymagany jest certyfikat z wewnętrznego PKI — wymień go zgodnie z rozdz. 12.3
> i wskaż łańcuch CA w `registry.caFile`.

### 4.7. Organizacja i konto robota (ręcznie, w przeglądarce) — PRZED pierwszym mirrorem

Klaster **nie może** używać konta `init` — ma ono prawo zapisu (ostrzeżenie w dokumentacji,
rozdz. 5.3.2). Tworzymy konto robota tylko do odczytu:

1. Otwórz `https://<fqdn>:8443`, zaloguj się jako `init`.
2. **Create New Organization** → nazwa = `registry.namespace` z pliku zmiennych (domyślnie `ocp`).
3. W organizacji: **Robot Accounts → Create Robot Account** → `cluster_pull`.
   Pełna nazwa robota: `ocp+cluster_pull`. Skopiuj token (hasło).
4. W organizacji: **Default Permissions → Create Default Permission** →
   *Anyone who creates a repository* → robot `ocp+cluster_pull` → **Read**.
   Dzięki temu robot dostanie odczyt do **każdego** repozytorium, które utworzy oc-mirror.
5. Zapisz login i token robota w sejfie haseł banku.

> Jeśli mirror był już wykonany wcześniej: w *Robot Accounts* → robot → *Set repository permissions*
> zaznacz wszystkie repozytoria i nadaj **Read**.

### Gotowe, gdy…

- `curl -fsS https://<fqdn>:8443/health/instance` zwraca JSON bez błędu TLS,
- `systemctl --user status quay-app` → `active (running)`,
- istnieje organizacja `ocp` i robot `ocp+cluster_pull` z domyślnym uprawnieniem *Read*,
- `oc-mirror --v2 --help` działa.

---

## 5. Faza B — preflight: stan klastra i ścieżka aktualizacji

🟢 Tylko odczyt. Uruchamiaj przed **każdą** aktualizacją.

```bash
oc login https://api.<klaster>.<domena>:6443      # cluster-admin
MIRROR_REGISTRY=bastion.bank.local:8443 bin/01-preflight.sh
# opcjonalnie: -t 4.21.30 (konkretna wersja), -c eus-4.22 (inny kanał docelowy)
```

Wynik w `reports/<klaster>-<data>/`:

| Plik | Zawartość |
|---|---|
| `preflight-report.txt` | pełny raport (to, co na ekranie) — załącz do wniosku o zmianę |
| `mirror-vars.yaml` | **szkic zmiennych**: wersja bieżąca i docelowa, kanał, operatory z ich kanałami |
| `operators.json` | operatory: pakiet, kanał, katalog, zainstalowana wersja, `maxOpenShiftVersion` |
| `update-path.json` | ścieżka aktualizacji i obraz release (digest) wersji docelowej |

### 5.1. Co sprawdza raport i co zrobić

| Komunikat | Znaczenie | Działanie |
|---|---|---|
| `ClusterOperator ... Degraded=True` | klaster nie jest zdrowy | napraw przed aktualizacją (aktualizacja niezdrowego klastra to ryzyko) |
| `Upgradeable=False` | CVO zablokuje zmianę wersji **minor** | przeczytaj komunikat — najczęściej operator z `maxOpenShiftVersion` albo brak admin-ack |
| `olm.maxOpenShiftVersion=4.20` | operator nie wspiera 4.21 | zaktualizuj operator **przed** aktualizacją klastra (rozdz. 10.2) |
| `Wymagane potwierdzenie administratora (admin-ack)` | np. usunięte API Kubernetes w nowej wersji | sprawdź, czy nic nie używa usuwanych API (`oc get apirequestcounts`), potem wykonaj podane `oc patch` |
| `MCP ... paused` | węzły tej puli nie zostaną zaktualizowane | odpauzuj (chyba że świadomie robisz *canary update*) |
| `PDB blokuje drain` | PodDisruptionBudget z `disruptionsAllowed=0` | uzgodnij z właścicielem aplikacji (skalowanie / zmiana PDB); w repo jest też `drain_preflight.sh` |
| `Pody z obrazami bez nazwy rejestru` | 4.21 **nie akceptuje** krótkich nazw (`nginx:latest`) — ryzyko `ShortNameImageReferences` | zmień na pełne nazwy (`registry.example.com/nginx:latest`) przed aktualizacją |
| `ICSP jest przestarzały` | stara konfiguracja mirrorów | `oc adm migrate icsp <plik.yaml> --dest-dir <katalog>` → IDMS (bez restartu) |
| `Aktualizacje warunkowe` | przejście możliwe, ale ze znanym ryzykiem | domyślnie wybierana jest ścieżka **rekomendowana**; ryzyka czytaj pod linkami |

### 5.2. Jak czytać sekcję „Możliwe aktualizacje”

```
Kanał stable-4.21: 69 wersji, najnowsza: 4.21.32
  Rekomendowane bezpośrednie aktualizacje z 4.20.12 (18): 4.20.13 ... 4.20.37
  Aktualizacje warunkowe: 4.20.12 -> 4.21.0  (EtcdStorageVersion3Migration, ShortNameImageReferences, ...)
Ścieżka 4.20.12 -> 4.21.32 w kanale stable-4.21 (2 krok(i)):
  4.20.12 -> 4.20.37 -> 4.21.32
  Obraz release docelowy: quay.io/openshift-release-dev/ocp-release@sha256:51a2...
```

- Z 4.20.12 nie ma bezpośredniej krawędzi do 4.21.32 — trzeba najpierw przejść na **4.20.37**.
  oc-mirror z `shortestPath: true` zmirroruje dokładnie te wersje, które są na ścieżce.
- Ścieżka jest liczona **tylko po krawędziach rekomendowanych**. Aby uwzględnić warunkowe:
  `python3 lib/ocp_graph.py --current 4.20.12 --channel stable-4.21 --allow-conditional`.
- Dane pochodzą z tego samego API co w klastrze online; raport pokazuje też, co widzi sam CVO.

### Gotowe, gdy…

Raport nie ma `[ERR]`, a każde `[WARN]` jest wyjaśnione lub świadomie zaakceptowane.

---

## 6. Faza C — plik zmiennych i ImageSetConfiguration

### 6.1. Plik zmiennych

`config/mirror-vars.yaml` to **jedyne** miejsce, w którym decydujesz, co trafia do mirrora.
Wszystkie pola opisano w `config/mirror-vars.example.yaml`. Weź szkic z preflight:

```bash
cp reports/<klaster>-<data>/mirror-vars.yaml config/mirror-vars.yaml
vi config/mirror-vars.yaml          # uzupełnij registry.*, przejrzyj operators
```

Na co zwrócić uwagę:

- **`platform.channel`** — kanał wersji **docelowej** (`stable-4.21`), a nie bieżącej.
- **`platform.currentVersion`** musi zostać zmirrorowana: po odcięciu internetu nowe/odtwarzane
  węzły i restartowane pody nadal potrzebują obrazów bieżącej wersji.
- **`operators[].versions`** — przy zmianie wersji minor mirroruj **obie** linie katalogu
  (`[v4.20, v4.21]`): v4.20 do podniesienia operatorów przed aktualizacją klastra, v4.21 po niej.
- **`minVersion`** (zakomentowana w szkicu) — odkomentuj dla operatorów krytycznych: zmirrorowane
  zostaną wszystkie wersje od zainstalowanej do najnowszej w kanale, więc OLM ma pełną ścieżkę
  aktualizacji. Bez `minVersion` mirrorowana jest tylko najnowsza wersja z kanału (mniej GB;
  zwykle wystarcza, bo nowe wersje deklarują `skipRange`).
- **Zależności operatorów** — oc-mirror v2 ich **nie dociąga** (dokumentacja, rozdz. 5.12).
  Jeśli operator wymaga innego (np. OpenShift Logging wymaga Loki Operatora), wpisz oba.
- **`cincinnati-operator`** (OSUS) musi być na liście, gdy `graph: true` — szkic dodaje go sam.
- **Operatory spoza katalogów Red Hat** (katalog bez `spec.image`, własne indeksy) preflight
  zaznacza ostrzeżeniem — dopisz je ręcznie.
- **`additionalImages`** — tylko pełne nazwy z rejestrem, najlepiej po digest. Obraz po tagu
  powoduje wygenerowanie ITMS, a **utworzenie ITMS restartuje węzły**.

Czy kanał istnieje w katalogu docelowym? Sprawdź przed mirrorem (opm pobiera sam indeks):

```bash
export REGISTRY_AUTH_FILE=/data/oc-mirror/auth/auth.json
opm render registry.redhat.io/redhat/redhat-operator-index:v4.21 --output=json \
  | jq -r 'select(.schema=="olm.channel" and .package=="local-storage-operator") | .name'
```

### 6.2. Generowanie ImageSetConfiguration

```bash
bin/03-generate-imageset.py -f config/mirror-vars.yaml
# -> /data/oc-mirror/imageset-config.yaml
```

Generator waliduje reguły oc-mirror v2 (m.in. filtr wersji na poziomie kanału, `defaultChannel`,
pełne nazwy obrazów) i nie zapisze pliku, jeśli są błędy. Przykładowy wynik:

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
archiveSize: 10
mirror:
  platform:
    architectures: [amd64]
    channels:
    - name: stable-4.21
      minVersion: 4.20.12
      maxVersion: 4.21.32
      shortestPath: true
    graph: true
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.20
    packages:
    - name: cincinnati-operator
      channels: [{name: v1}]
      defaultChannel: v1
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.21
    packages: [...]
```

Plik zmiennych i wygenerowany plik trzymaj w Git — to jest opis zmiany dla audytu.

---

## 7. Faza D — mirror obrazów

### 7.1. Dry-run

```bash
bin/04-mirror.sh -f config/mirror-vars.yaml --dry-run
```

Sprawdza konfigurację i wypisuje listę obrazów bez kopiowania:
`/data/oc-mirror/archive/working-dir/dry-run/mapping.txt` (wszystkie obrazy)
i `missing.txt` (brakujące w cache). Błędy typu „channel not found” wychodzą właśnie tutaj.

### 7.2. Mirror właściwy

```bash
bin/04-mirror.sh -f config/mirror-vars.yaml          # m2d, potem d2m
```

Co się dzieje:

1. **m2d** (`oc-mirror --v2 -c ... --cache-dir /data/oc-mirror/cache file:///data/oc-mirror/archive`)
   — pobiera obrazy z internetu do cache i pakuje do `archive/mirror_*.tar`,
2. **d2m** (`oc-mirror --v2 -c ... --from file:///data/oc-mirror/archive docker://<fqdn>:8443/ocp`)
   — wypycha obrazy do mini Quay i generuje zasoby dla klastra,
3. skrypt kopiuje `working-dir/cluster-resources` do `results/<data>_<wersja>/` (+ ImageSetConfiguration
   i plik zmiennych) i ustawia dowiązanie `results/latest`.

Kroki można uruchamiać osobno (`--step m2d`, `--step d2m`). Po awarii (łącze, timeout) uruchom
ponownie ten sam krok — cache pominie gotowe obrazy.

Zasoby wygenerowane przez oc-mirror v2:

| Plik | Zasób | Do czego |
|---|---|---|
| `idms-oc-mirror.yaml` | `ImageDigestMirrorSet` `idms-release-0`, `idms-operator-0` | przekierowanie obrazów po digest |
| `itms-oc-mirror.yaml` | `ImageTagMirrorSet` | przekierowanie obrazów po tagu (tylko, gdy były) |
| `cs-redhat-operator-index-v4-21.yaml` | `CatalogSource` | katalog operatorów z mirrora (OLM) |
| `cc-*.yaml` | `ClusterCatalog` | to samo dla OLM v1 |
| `signature-configmap.{json,yaml}` | `ConfigMap mirrored-release-signatures` | podpisy release dla CVO |
| `updateService.yaml` | `UpdateService update-service-oc-mirror` | lokalny OSUS |

> **Nie edytuj** pól `spec.imageDigestMirrors`, `spec.imageTagMirrors`, `spec.image`,
> `binaryData`, `spec.graphDataImage`, `spec.releases` w tych plikach (dokumentacja, rozdz. 5.5.1).

> **4.21 wymaga podpisów Sigstore** release na mirrorze (ryzyko `SigstoreSignatureMirroring`).
> oc-mirror v2 mirroruje je domyślnie — **nie używaj** `--remove-signatures`.

### 7.3. Po mirrorze

- Sprawdź, czy skrypt nie zgłosił `[ERR]` o błędach obrazów (`working-dir/logs/mirroring_error*`).
  Błąd obrazu release przerywa mirror; błąd obrazu operatora — nie, ale ten operator będzie niekompletny.
- **Zrób kopię `/data/oc-mirror/cache`** — dokumentacja wymaga backupu cache po każdym udanym
  mirrorze; bez niego następny mirror pobierze wszystko od nowa.
- Archiwa `archive/mirror_*.tar` możesz zarchiwizować / przeskanować narzędziem bezpieczeństwa banku.

### Gotowe, gdy…

`results/latest/cluster-resources/` zawiera IDMS, CatalogSource, podpisy i `updateService.yaml`,
a w UI Quay w organizacji `ocp` widać repozytoria `openshift/release-images`, `openshift/release`,
`openshift/graph-image`, `redhat/redhat-operator-index` itd.

---

## 8. Faza E — przełączenie klastra na mirror

Wykonuj, **gdy klaster jeszcze ma internet**. Reguły IDMS mają domyślnie
`AllowContactingSource` — jeśli czegoś brakuje w mirrorze, węzeł pobierze to ze źródła,
a Ty zobaczysz to w logach, zanim stanie się problemem.

```bash
export MIRROR_PULL_USER='ocp+cluster_pull'
export MIRROR_PULL_PASSWORD='<token robota>'

bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage all --dry-run   # walidacja w API
bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage all
```

`--stage all` = `trust,pullsecret,mirrors,catalogs,verify`. Każdy etap można uruchomić osobno.

### 8.1. Etap `trust` 🟡

Dodaje CA rejestru do ConfigMap w `openshift-config` (klucz `<fqdn>..8443` — dwukropek zamieniony
na `..`, oraz `updateservice-registry` dla OSUS) i wskazuje ją w
`image.config.openshift.io/cluster` → `spec.additionalTrustedCA`.
Jeśli klaster ma już taką ConfigMap, skrypt **dopisuje** klucze, nie nadpisuje istniejących.

### 8.2. Etap `pullsecret` 🟡

Dopisuje token robota do globalnego pull secret (pozostałe wpisy bez zmian).
MCO rozsyła go na węzły **bez restartu**. Uwaga: dla mirrorów działa **tylko globalny** pull secret —
nie da się go ustawić per projekt.

### 8.3. Etap `mirrors` 🔴

Stosuje IDMS/ITMS i podpisy release. Przed zmianą skrypt pokazuje `oc diff` i ocenia wpływ.
Zasady MCO (dokumentacja 4.21, rozdz. 11.4.5):

| Zmiana | Skutek na węzłach |
|---|---|
| utworzenie IDMS | bez drenowania i restartu |
| dodanie nowych wpisów digest-only do istniejącego IDMS | bez drenowania |
| **utworzenie ITMS** | drenowanie + restart (rolling) |
| **modyfikacja / usunięcie** IDMS, ITMS, ICSP | drenowanie + restart (rolling) |

Obserwuj rollout: `watch oc get mcp` — kontynuuj, gdy wszystkie pule mają `UPDATED=True`.

### 8.4. Etap `catalogs` 🟡

1. Tworzy CatalogSource z mirrora **dokładnie tak, jak wygenerował je oc-mirror**
   (`cs-redhat-operator-index-v4-20`, `cs-redhat-operator-index-v4-21`, ...) i czeka na `READY`.
2. **Przepina istniejące Subscription** na katalog z mirrora z tej samej rodziny indeksu
   i linii `--catalog-tag` (domyślnie = bieżąca wersja klastra, np. `v4.20`).
   Przykład: `redhat-operators` → `cs-redhat-operator-index-v4-20`. Operatory nie są reinstalowane.
3. Wyłącza katalogi domyślne: `OperatorHub cluster` → `disableAllDefaultSources: true`
   (wymóg dokumentacji dla środowisk disconnected).

Subscription, dla której nie znaleziono katalogu w mirrorze, jest zgłaszana `[WARN]` — przepnij ją
ręcznie albo dopisz operator do pliku zmiennych i zmirroruj ponownie.

### 8.5. Etap `verify` 🟢 — weryfikacja

Skrypt uruchamia na węźle `crictl pull <fqdn>:8443/ocp/openshift/release-images@<digest bieżącej wersji>`.
Udany pull potwierdza naraz: DNS, zaufanie do CA, pull secret i obecność bieżącej wersji w mirrorze.
Sprawdza też stan katalogów i MCP.

Dodatkowo, przed odcięciem internetu, sprawdź ręcznie, **skąd** węzły faktycznie pobierają obrazy
(dokumentacja: `crictl images` pokazuje nazwę źródłową, prawdę mówią logi CRI-O):

```bash
oc debug node/<węzeł> -- chroot /host journalctl -u crio --since "-1h" | grep "Trying to access"
# oczekiwane: "Trying to access \"<fqdn>:8443/ocp/...\""
# jeśli widzisz quay.io / registry.redhat.io — tego obrazu brakuje w mirrorze
```

Sprawdzenie na węźle, że reguły trafiły do konfiguracji CRI-O:

```bash
oc debug node/<węzeł> -- chroot /host cat /etc/containers/registries.conf
```

### 8.6. Etap `osus` 🟡 — lokalny OpenShift Update Service

```bash
bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage osus
```

1. Instaluje operator OSUS (`cincinnati-operator`) z katalogu z mirrora
   (namespace `openshift-update-service`, OperatorGroup, Subscription).
2. Tworzy `UpdateService` z pliku wygenerowanego przez oc-mirror (obraz `graph-image` z mirrora).
3. Po potwierdzeniu przełącza CVO: `clusterversion/version` → `spec.upstream` = lokalny graf.
4. Czeka na `RetrievedUpdates=True`.

**OSUS i certyfikaty.** CVO łączy się z OSUS przez route klastra. Jeśli `RetrievedUpdates=False`
z błędem x509, CVO nie ufa certyfikatowi routera ingress. Dodaj CA ingress do zaufanego bundla
klastra (dokumentacja: *Configuring the cluster-wide proxy*) — **zachowując** istniejące certyfikaty:

```bash
oc get cm default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > ingress-ca.crt
oc get cm user-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' > bundle.crt 2>/dev/null || : > bundle.crt
cat ingress-ca.crt >> bundle.crt
oc create cm user-ca-bundle -n openshift-config --from-file=ca-bundle.crt=bundle.crt --dry-run=client -o yaml | oc apply -f -
oc patch proxy/cluster --type=merge -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'
```

> Zmiana zaufanego bundla jest rozsyłana przez MCO — zaplanuj ją w oknie serwisowym.

Weryfikacja: `oc adm upgrade` pokazuje listę dostępnych aktualizacji bez błędu pobierania grafu.

### Gotowe, gdy…

- `verify` bez `[ERR]`, wszystkie MCP `UPDATED=True`,
- wszystkie CatalogSource `READY`, wszystkie Subscription wskazują `cs-*`,
- logi CRI-O pokazują pobieranie z `<fqdn>:8443`,
- `oc adm upgrade` pokazuje aktualizacje z lokalnego OSUS.

---

## 9. Faza F — odcięcie internetu

1. Bank odcina klastrowi internet (firewall).
2. Wyłącz Telemetry/Insights — bez tego Insights Operator przejdzie w `Degraded`
   (dokumentacja, rozdz. 2.8):

   ```bash
   bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage disconnect
   ```

3. Opcjonalnie, jeśli nie używacie przykładowych ImageStreams (Samples Operator nie pobierze ich offline):

   ```bash
   oc patch configs.samples.operator.openshift.io cluster --type merge -p '{"spec":{"managementState":"Removed"}}'
   ```

4. Po 30–60 min: `oc get co` — wszystkie `Available=True`, `Degraded=False`;
   `oc get pods -A | grep -E 'ImagePull|ErrImage'` — puste.

**Powrót do trybu online** (gdyby był potrzebny): przywróć ruch, usuń IDMS/ITMS utworzone przez
oc-mirror (`oc get idms -o jsonpath='{.items[?(@.metadata.annotations.createdBy=="oc-mirror v2")].metadata.name}'`)
— spowoduje to rolling restart węzłów — i ustaw `disableAllDefaultSources: false`.

---

## 10. Faza G — aktualizacja klastra

### 10.1. Lista kontrolna przed aktualizacją

| # | Czynność | Polecenie |
|---|---|---|
| 1 | Świeży preflight bez `[ERR]` | `bin/01-preflight.sh` |
| 2 | Wersje ze ścieżki są w mirrorze | `results/latest/imageset-config.yaml` (min/max) |
| 3 | Podpisy release zastosowane | `oc get cm -n openshift-config-managed -l release.openshift.io/verification-signatures` |
| 4 | **Backup etcd** | `oc debug --as-root node/<master> -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup` — skopiuj katalog poza klaster |
| 5 | Wstrzymane MachineHealthCheck | `oc -n openshift-machine-api annotate mhc <nazwa> cluster.x-k8s.io/paused=""` |
| 6 | Admin-ack (jeśli wymagany) | polecenie z raportu preflight |
| 7 | Żadna MCP nie jest wstrzymana | `oc get mcp` |

> Aktualizacji OpenShift **nie da się cofnąć** — jedyną drogą powrotu jest odtworzenie etcd z backupu.

### 10.2. Operatory przed zmianą wersji minor

Operatory muszą być w wersjach wspierających wersję docelową (brak `maxOpenShiftVersion=4.20`).
Przy `installPlanApproval: Manual` zatwierdź oczekujące InstallPlany:

```bash
oc get installplan -A | grep -v true
oc patch installplan <nazwa> -n <namespace> --type merge -p '{"spec":{"approved":true}}'
```

### 10.3. Aktualizacja z lokalnym OSUS (zalecana)

```bash
oc adm upgrade channel stable-4.21     # kanał docelowy
oc adm upgrade                         # lista rekomendowanych wersji z lokalnego OSUS
oc adm upgrade --to=4.20.37            # krok 1 ścieżki z preflight
# ... czekaj na zakończenie, potem:
oc adm upgrade --to=4.21.32            # krok 2
```

### 10.4. Aktualizacja bez OSUS (alternatywa)

Obraz release wskazujesz po **digest** (jest w `update-path.json` i raporcie preflight). Dzięki
IDMS można użyć kanonicznej nazwy `quay.io/...` — węzły i tak pobiorą z mirrora:

```bash
oc adm upgrade --allow-explicit-upgrade \
  --to-image quay.io/openshift-release-dev/ocp-release@sha256:<digest>
```

### 10.5. Obserwacja

```bash
oc adm upgrade                  # postęp i komunikaty CVO
oc get clusterversion
oc get co                       # operatory przechodzą kolejno na nową wersję
watch oc get mcp                # na końcu restartują się węzły, pula po puli
```

Aktualizacja jest zakończona, gdy `oc get clusterversion` pokazuje nową wersję z
`PROGRESSING=False`, a wszystkie MCP mają `UPDATED=True`.

### 10.6. Po aktualizacji

```bash
# 1. Katalogi operatorów na nową linię
bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage catalogs --catalog-tag v4.21
# 2. Zatwierdź aktualizacje operatorów (Manual)
# 3. Wznów MachineHealthCheck
oc -n openshift-machine-api annotate mhc <nazwa> cluster.x-k8s.io/paused-
# 4. Kontrolny preflight
bin/01-preflight.sh
```

---

## 11. Kolejne aktualizacje (cykl stały)

Po pierwszym wdrożeniu każda kolejna aktualizacja to ten sam, krótki cykl (wszystko z bastionu):

```bash
bin/01-preflight.sh                                             # 1. stan + nowa ścieżka (graf z internetu)
vi config/mirror-vars.yaml                                      # 2. nowe currentVersion/targetVersion/channel/versions
bin/03-generate-imageset.py -f config/mirror-vars.yaml          # 3.
bin/04-mirror.sh -f config/mirror-vars.yaml                     # 4. przyrostowo — tylko nowe obrazy
bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage mirrors,catalogs,verify   # 5.
bin/05-configure-cluster.sh -f config/mirror-vars.yaml --stage osus                      # 6. nowy graph-image dla OSUS
# 7. aktualizacja wg rozdz. 10
```

Uwagi:

- IDMS z oc-mirror v2 obejmuje **cały** zestaw obrazów (nie tylko przyrost), więc każda zmiana
  zestawu zmienia IDMS. Nowe wpisy digest-only nie drenują węzłów, ale zmiana istniejących tak —
  etap `mirrors` pokazuje diff przed zastosowaniem.
- Etap `osus` jest idempotentny — przy ponownym uruchomieniu aktualizuje `graphDataImage`
  w UpdateService, dzięki czemu klaster widzi nowe wersje i nowe ostrzeżenia z grafu.
- Nie zmieniaj ręcznie cache ani `working-dir` — rób kopię cache po każdym udanym mirrorze.

---

## 12. Utrzymanie mini Quay

### 12.1. Ważne ograniczenia (dokumentacja, rozdz. 4.2.1)

- Mini Quay **nie jest wysokodostępny** i nie zastępuje produkcyjnego Red Hat Quay.
- Jest wspierany **tylko** dla obrazów potrzebnych do instalacji/aktualizacji (release, operatory Red Hat) —
  **nie umieszczaj** w nim obrazów aplikacji banku.
- Używanie go dla wielu klastrów jest odradzane (pojedynczy punkt awarii).
- **Rejestr musi działać zawsze, gdy działa klaster** — bez niego nie wystartuje pod na węźle, który
  nie ma obrazu w lokalnym cache (restart, nowy węzeł, przeniesienie poda). Monitoruj
  `https://<fqdn>:8443/health/instance` i rób snapshoty VM bastionu.

> Rekomendacja na przyszłość: gdy bank ma produkcyjny rejestr (Red Hat Quay HA, Artifactory, Nexus,
> Harbor), użyj go jako celu oc-mirror — cała procedura pozostaje taka sama, zmienia się tylko
> `registry.host` i CA.

### 12.2. Kopie zapasowe

| Co | Gdzie | Kiedy |
|---|---|---|
| cache oc-mirror | `/data/oc-mirror/cache` | po każdym udanym mirrorze |
| konfiguracja + CA Quay | `<quayRoot>` (`/data/quay/quay-install`) | po instalacji i zmianie certyfikatu |
| dane Quay | `quayStorage` + `sqliteStorage` | wg polityki banku (lub snapshot VM) |
| plik zmiennych, wyniki | Git + `/data/oc-mirror/results/` | przy każdej zmianie |

### 12.3. Certyfikat z PKI banku / rotacja

```bash
cd /data/oc-mirror/tools/mirror-registry
./mirror-registry upgrade --sslCert /ścieżka/ssl.crt --sslKey /ścieżka/ssl.key -v
```

Następnie zaktualizuj `registry.caFile` i ponów etap `trust`
(`bin/05-configure-cluster.sh ... --stage trust`). Termin ważności CA sprawdza `02-setup-bastion.sh`.

### 12.4. Aktualizacja mini Quay

Pobierz nowszy `mirror-registry-amd64.tar.gz`, rozpakuj i uruchom `./mirror-registry upgrade -v`
(od 2.0.11 zachowuje hostname, ścieżki i certyfikaty). Na czas aktualizacji rejestr jest chwilowo
niedostępny — nie wykonuj jej w trakcie aktualizacji klastra.

### 12.5. Zwalnianie miejsca (stare wersje)

oc-mirror v2 **nie kasuje automatycznie**. Stare wersje usuwasz jawnie (dokumentacja, rozdz. 5.6):

```yaml
# delete-imageset-config.yaml
apiVersion: mirror.openshift.io/v2alpha1
kind: DeleteImageSetConfiguration
delete:
  platform:
    channels:
    - name: stable-4.20
      minVersion: 4.20.12
      maxVersion: 4.20.12
```

```bash
oc-mirror delete --v2 --config delete-imageset-config.yaml \
  --workspace file:///data/oc-mirror/archive --cache-dir /data/oc-mirror/cache \
  --authfile /data/oc-mirror/auth/auth.json --generate docker://<fqdn>:8443/ocp
# przejrzyj archive/working-dir/delete/delete-images.yaml, potem:
oc-mirror delete --v2 --delete-yaml-file /data/oc-mirror/archive/working-dir/delete/delete-images.yaml \
  --authfile /data/oc-mirror/auth/auth.json docker://<fqdn>:8443/ocp
```

Nie usuwaj wersji, na której klaster **aktualnie działa**. Quay zwalnia miejsce na dysku
przez garbage collection w tle (z opóźnieniem).

---

## 13. Rozwiązywanie problemów

| Objaw | Przyczyna | Rozwiązanie |
|---|---|---|
| `x509: certificate signed by unknown authority` (bastion) | CA mini Quay nie jest zaufane | `02-setup-bastion.sh` (krok 5) lub ręcznie `update-ca-trust` |
| `x509` na węzłach / pody `ErrImagePull` z mirrora | brak CA w `additionalTrustedCA` lub zły klucz | etap `trust`; klucz musi mieć postać `fqdn..8443` |
| `unauthorized` przy pobieraniu z mirrora | brak/zły token w pull secret, robot bez *Read* | etap `pullsecret`; uprawnienia robota (rozdz. 4.7) |
| `pasta failed ... External interface not usable` | Podman 5 bez domyślnej trasy | rozdz. 4.1 (slirp4netns) |
| oc-mirror: `too many open files` | niski `ulimit -n` | skrypt podnosi limit; ew. `/etc/security/limits.d/` |
| oc-mirror: `multiple channel heads` | `maxVersion` odcina głowę kanału | usuń `maxVersion` / obniż `minVersion` (rozdz. 5.13) |
| oc-mirror: kanał nie istnieje | kanał z v4.20 nie istnieje w v4.21 | sprawdź `opm render` (rozdz. 6.1), popraw `channel` |
| operator niekompletny po mirrorze | błąd obrazu operatora | `working-dir/logs/mirroring_error*`, ponów krok |
| CatalogSource nie `READY` | brak indeksu w mirrorze / pull secret / CA | `oc get pods -n openshift-marketplace`, `oc describe pod ...` |
| Subscription: `constraints not satisfiable` | w mirrorze brak wersji z kanału / zależności | dodaj `minVersion` lub brakujący pakiet, zmirroruj ponownie |
| CVO: `RetrievedUpdates=False` (x509) | CVO nie ufa routerowi z OSUS | rozdz. 8.6 „OSUS i certyfikaty” |
| CVO: release verification failed | brak ConfigMap z podpisami | etap `mirrors` (podpisy), sprawdź `results/latest` |
| Insights `Degraded` po odcięciu | brak dostępu do console.redhat.com | etap `disconnect` |
| Pod z obrazem `nginx:latest` nie startuje po 4.21 | krótkie nazwy nieobsługiwane | pełna nazwa z rejestrem (preflight wskazuje takie pody) |

Logi: `/data/oc-mirror/logs/`, `working-dir/logs/`, `systemctl --user status quay-app quay-redis quay-pod`.

---

## 14. Źródła

Dokumentacja Red Hat OpenShift Container Platform 4.21, *Disconnected environments*:

- Rozdz. 1.2 — preferowane metody (oc-mirror v2, OSUS)
- Rozdz. 2 — konwersja klastra connected → disconnected (Insights, powrót do trybu online)
- Rozdz. 4 — *Creating a mirror registry with mirror registry for Red Hat OpenShift*
- Rozdz. 5 — *Mirroring images for a disconnected installation by using the oc-mirror plugin v2*
  (workflow m2d/d2m/m2m, zasoby, filtrowanie operatorów, podpisy, kasowanie, cache/workspace)
- Rozdz. 10 — *Using Operator Lifecycle Manager in disconnected environments*
- Rozdz. 11 — *Updating a cluster in a disconnected environment* (OSUS, aktualizacja bez OSUS, IDMS a restarty węzłów)

<https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/disconnected_environments/index>

Pozostałe:

- *Configuring your firewall for OpenShift Container Platform* (4.21, *Installation configuration*)
- mirror registry for Red Hat OpenShift: <https://github.com/quay/mirror-registry>
- Graf aktualizacji: `https://api.openshift.com/api/upgrades_info/v1/graph?channel=<kanał>&arch=<arch>`
- Narzędzia: <https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/>
