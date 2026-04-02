#!/usr/bin/env python3
"""
OpenShift Drain Watchdog
========================
Monitoruje węzły podczas upgradu klastra OCP. Jeśli węzeł jest w stanie
SchedulingDisabled (kordony MCO) przez dłużej niż DRAIN_TIMEOUT sekund
i nadal ma pody do ewakuacji, wykonuje wymuszony drain z --disable-eviction.

Użycie:
    python3 drain_watchdog.py [--timeout 180] [--interval 30] [--max-retries 3] [--dry-run]

Przykład (upgrade w tle):
    nohup python3 drain_watchdog.py --timeout 180 --log-file /tmp/drain-watchdog.log &

Wymagania:
    - zalogowany oc/kubectl z uprawnieniami cluster-admin
    - Python >= 3.9
"""

import argparse
import json
import logging
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional


# ---------------------------------------------------------------------------
# Konfiguracja
# ---------------------------------------------------------------------------

DEFAULT_DRAIN_TIMEOUT = 180   # sekundy — kiedy uznajemy drain za "zawieszony"
DEFAULT_CHECK_INTERVAL = 30   # co ile sekund odpytujemy klaster
DEFAULT_MAX_RETRIES = 3       # max prób force-drain na jeden węzeł


# ---------------------------------------------------------------------------
# Struktury danych
# ---------------------------------------------------------------------------

@dataclass
class NodeDrainState:
    name: str
    cordoned_at: datetime
    force_drain_attempts: int = 0
    last_force_drain_at: Optional[datetime] = None
    already_warned: bool = False


# ---------------------------------------------------------------------------
# Pomocnicze funkcje oc
# ---------------------------------------------------------------------------

def oc(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    cmd = ["oc"] + list(args)
    logging.debug("Executing: %s", " ".join(cmd))
    result = subprocess.run(cmd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed: {' '.join(cmd)}\n{result.stderr.strip()}")
    return result


def get_cordoned_nodes() -> dict[str, dict]:
    """Zwraca słownik {node_name: node_object} dla węzłów z unschedulable=true."""
    result = oc("get", "nodes", "-o", "json")
    if result.returncode != 0:
        logging.error("Nie udało się pobrać listy węzłów: %s", result.stderr.strip())
        return {}

    nodes = json.loads(result.stdout).get("items", [])
    return {
        n["metadata"]["name"]: n
        for n in nodes
        if n["spec"].get("unschedulable", False)
    }


def get_non_daemonset_pods(node_name: str) -> list[dict]:
    """
    Zwraca pody na węźle, które NIE należą do DaemonSet
    i nie są w fazie Succeeded/Failed.
    """
    result = oc(
        "get", "pods",
        "--all-namespaces",
        f"--field-selector=spec.nodeName={node_name}",
        "-o", "json",
    )
    if result.returncode != 0:
        logging.warning("Nie udało się pobrać podów dla %s: %s", node_name, result.stderr.strip())
        return []

    pods = json.loads(result.stdout).get("items", [])
    evictable = []
    for pod in pods:
        phase = pod.get("status", {}).get("phase", "")
        if phase in ("Succeeded", "Failed"):
            continue
        owners = pod["metadata"].get("ownerReferences", [])
        if any(o["kind"] == "DaemonSet" for o in owners):
            continue
        evictable.append(pod)
    return evictable


def node_mco_state(node_name: str) -> Optional[str]:
    """
    Odczytuje stan MCO z adnotacji węzła
    (machineconfiguration.openshift.io/state).
    Zwraca np. 'Draining', 'Done', 'Degraded' lub None.
    """
    result = oc(
        "get", "node", node_name,
        "-o", "jsonpath={.metadata.annotations.machineconfiguration\\.openshift\\.io/state}",
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def force_drain(node_name: str, dry_run: bool = False) -> bool:
    """
    Wykonuje wymuszony drain węzła z --disable-eviction (omija PDB).
    Zwraca True przy sukcesie.
    """
    cmd_args = [
        "adm", "drain", node_name,
        "--force",
        "--disable-eviction",        # omija PodDisruptionBudgets — konieczne przy zawieszonym drain
        "--ignore-daemonsets",
        "--delete-emptydir-data",
        "--grace-period=10",         # krótki grace period — upgrade i tak restart robi
        "--timeout=120s",
    ]
    if dry_run:
        logging.info("[DRY-RUN] Pomijam: oc %s", " ".join(cmd_args))
        return True

    logging.warning(
        "FORCE DRAIN: oc %s  (UWAGA: omija PodDisruptionBudgets!)",
        " ".join(cmd_args),
    )
    result = oc(*cmd_args)
    if result.returncode == 0:
        logging.info("Force drain węzła %s zakończony sukcesem.", node_name)
        return True
    else:
        logging.error(
            "Force drain węzła %s NIE POWIÓDŁ SIĘ (rc=%d):\n%s",
            node_name, result.returncode, result.stderr.strip(),
        )
        return False


# ---------------------------------------------------------------------------
# Główna pętla watchdoga
# ---------------------------------------------------------------------------

def run_watchdog(
    drain_timeout: int,
    check_interval: int,
    max_retries: int,
    dry_run: bool,
) -> None:
    logging.info(
        "Drain Watchdog uruchomiony | timeout=%ds interval=%ds max_retries=%d dry_run=%s",
        drain_timeout, check_interval, max_retries, dry_run,
    )

    # node_name -> NodeDrainState
    watched: dict[str, NodeDrainState] = {}

    while True:
        now = datetime.now(timezone.utc)
        cordoned = get_cordoned_nodes()

        # Usuń węzły, które przestały być skordowane
        for name in list(watched.keys()):
            if name not in cordoned:
                logging.info("Węzeł %s już nie jest skordowany — usuwam z watchlisty.", name)
                del watched[name]

        # Sprawdź nowe i istniejące skordowane węzły
        for name in cordoned:
            if name not in watched:
                mco = node_mco_state(name)
                logging.info(
                    "Nowy skordowany węzeł: %s  (MCO state: %s)",
                    name, mco or "n/a",
                )
                watched[name] = NodeDrainState(name=name, cordoned_at=now)
                continue

            state = watched[name]
            elapsed = (now - state.cordoned_at).total_seconds()

            if elapsed < drain_timeout:
                logging.debug(
                    "Węzeł %s: drainuje %ds / %ds (czekam).",
                    name, elapsed, drain_timeout,
                )
                continue

            # Przekroczono timeout — sprawdź czy są jeszcze pody
            pods = get_non_daemonset_pods(name)
            if not pods:
                if not state.already_warned:
                    logging.info(
                        "Węzeł %s: timeout przekroczony (%ds), ale brak podów do ewakuacji — MCO przetwarza.",
                        name, elapsed,
                    )
                    state.already_warned = True
                continue

            # Są pody — sprawdź limit prób
            if state.force_drain_attempts >= max_retries:
                logging.error(
                    "Węzeł %s: wyczerpano limit prób force-drain (%d/%d). "
                    "Wymaga manualnej interwencji!",
                    name, state.force_drain_attempts, max_retries,
                )
                continue

            # Odczekaj ≥60s między kolejnymi próbami force-drain
            if state.last_force_drain_at:
                since_last = (now - state.last_force_drain_at).total_seconds()
                if since_last < 60:
                    logging.debug(
                        "Węzeł %s: zbyt wcześnie na kolejną próbę (%.0fs temu).",
                        name, since_last,
                    )
                    continue

            pod_names = [
                f"{p['metadata']['namespace']}/{p['metadata']['name']}"
                for p in pods[:5]
            ]
            logging.warning(
                "Węzeł %s drainuje %ds (limit %ds). "
                "Pozostałe pody (%d): %s%s. Próba force-drain #%d.",
                name, elapsed, drain_timeout,
                len(pods), ", ".join(pod_names),
                " ..." if len(pods) > 5 else "",
                state.force_drain_attempts + 1,
            )

            success = force_drain(name, dry_run=dry_run)
            state.force_drain_attempts += 1
            state.last_force_drain_at = now
            if success:
                state.already_warned = False

        time.sleep(check_interval)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="OpenShift Drain Watchdog — wymusza drain zawieszonych węzłów podczas upgradu.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument(
        "--timeout", type=int, default=DEFAULT_DRAIN_TIMEOUT, metavar="SECONDS",
        help="Czas (s) po którym drain uznajemy za zawieszony.",
    )
    p.add_argument(
        "--interval", type=int, default=DEFAULT_CHECK_INTERVAL, metavar="SECONDS",
        help="Interwał odpytywania klastra (s).",
    )
    p.add_argument(
        "--max-retries", type=int, default=DEFAULT_MAX_RETRIES,
        help="Maksymalna liczba prób force-drain per węzeł.",
    )
    p.add_argument(
        "--dry-run", action="store_true",
        help="Loguj akcje bez faktycznego wykonywania drain.",
    )
    p.add_argument(
        "--log-file", metavar="PATH",
        help="Opcjonalny plik logów (równolegle do stdout).",
    )
    p.add_argument(
        "--log-level", default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Poziom logowania.",
    )
    return p.parse_args()


def setup_logging(level: str, log_file: Optional[str]) -> None:
    fmt = "%(asctime)s  %(levelname)-8s  %(message)s"
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if log_file:
        handlers.append(logging.FileHandler(log_file))
    logging.basicConfig(level=getattr(logging, level), format=fmt, handlers=handlers)


def main() -> None:
    args = parse_args()
    setup_logging(args.log_level, args.log_file)

    # Szybki sanity-check: czy oc jest dostępny i zalogowany
    result = oc("whoami")
    if result.returncode != 0:
        logging.critical("Nie można połączyć się z klastrem (oc whoami failed). Zaloguj się przed uruchomieniem.")
        sys.exit(1)
    logging.info("Połączono z klastrem jako: %s", result.stdout.strip())

    try:
        run_watchdog(
            drain_timeout=args.timeout,
            check_interval=args.interval,
            max_retries=args.max_retries,
            dry_run=args.dry_run,
        )
    except KeyboardInterrupt:
        logging.info("Watchdog zatrzymany przez użytkownika.")


if __name__ == "__main__":
    main()
