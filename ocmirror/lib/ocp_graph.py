#!/usr/bin/env python3
"""ocp_graph.py — analiza grafu aktualizacji OpenShift (OpenShift Update Service).

Pobiera graf aktualizacji udostępniany przez Red Hat (ten sam, z którego korzysta
Cluster Version Operator) i odpowiada na pytania:
  * czy bieżąca wersja jest w danym kanale,
  * jaka jest najnowsza wersja w kanale,
  * na jakie wersje można zaktualizować się bezpośrednio (rekomendowane i warunkowe),
  * jaka jest najkrótsza rekomendowana ścieżka do wersji docelowej.

Użycie:
    ocp_graph.py --current 4.20.14 --channel stable-4.20 --channel stable-4.21
                 [--target latest|4.21.30] [--arch amd64]
                 [--graph-url URL] [--cacert PLIK] [--allow-conditional]
                 [--summary-file wynik.json]

Ostatni podany --channel jest kanałem docelowym (w nim liczona jest ścieżka).
--graph-url pozwala wskazać lokalny OSUS po odcięciu internetu.
Tylko biblioteka standardowa Pythona; respektuje zmienne https_proxy/no_proxy.
"""
import argparse
import json
import re
import ssl
import sys
import urllib.parse
import urllib.request
from collections import deque

DEFAULT_GRAPH_URL = "https://api.openshift.com/api/upgrades_info/v1/graph"


def version_key(version: str):
    """Klucz sortowania wersji: 4.21.3 < 4.21.10, wersje -rc/-ec przed GA."""
    main, _, pre = version.partition("-")
    nums = tuple(int(x) for x in re.findall(r"\d+", main))
    return nums + ((1,) if not pre else (0, pre))


def minor_of(version: str) -> str:
    return ".".join(version.split(".")[:2])


class UpdateGraph:
    """Graf jednego kanału: węzły = wersje, krawędzie = dozwolone aktualizacje."""

    def __init__(self, channel: str, data: dict):
        self.channel = channel
        nodes = data.get("nodes") or []
        self.versions = [n["version"] for n in nodes]
        self.payload = {n["version"]: n.get("payload", "") for n in nodes}
        self.errata = {n["version"]: n.get("metadata", {}).get("url", "") for n in nodes}

        self.edges = {}
        for src, dst in data.get("edges") or []:
            self.edges.setdefault(self.versions[src], set()).add(self.versions[dst])

        # Krawędzie warunkowe: aktualizacja możliwa, ale obarczona znanym ryzykiem
        self.risks = {}
        for cond in data.get("conditionalEdges") or []:
            for edge in cond.get("edges", []):
                self.risks[(edge["from"], edge["to"])] = cond.get("risks", [])

    def latest(self, minor=None):
        cands = [v for v in self.versions if minor is None or minor_of(v) == minor]
        return max(cands, key=version_key) if cands else None

    def recommended_from(self, version):
        return sorted(self.edges.get(version, set()), key=version_key)

    def conditional_from(self, version):
        return sorted((dst for (src, dst) in self.risks if src == version), key=version_key)

    def neighbours(self, version, allow_conditional):
        result = set(self.edges.get(version, set()))
        if allow_conditional:
            result |= set(self.conditional_from(version))
        return result

    def reachable(self, start, allow_conditional=False):
        """BFS: zwraca słownik poprzedników dla wszystkich osiągalnych wersji."""
        prev = {start: None}
        queue = deque([start])
        while queue:
            cur = queue.popleft()
            # Deterministycznie: najpierw wyższe wersje (mniej kroków pośrednich w praktyce)
            for nxt in sorted(self.neighbours(cur, allow_conditional), key=version_key, reverse=True):
                if nxt not in prev:
                    prev[nxt] = cur
                    queue.append(nxt)
        return prev

    @staticmethod
    def path_to(prev, target):
        if target not in prev:
            return []
        path = [target]
        while prev[path[-1]] is not None:
            path.append(prev[path[-1]])
        return list(reversed(path))


def fetch_graph(url, channel, arch, cacert=None):
    query = urllib.parse.urlencode({"channel": channel, "arch": arch})
    req = urllib.request.Request(f"{url}?{query}", headers={"Accept": "application/json"})
    ctx = ssl.create_default_context(cafile=cacert) if cacert else None
    with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
        return json.load(resp)


def print_risks(graph, src, dst, indent="      "):
    for risk in graph.risks.get((src, dst), []):
        print(f"{indent}- ryzyko: {risk.get('name', '?')}: {risk.get('message', '').strip()}")
        if risk.get("url"):
            print(f"{indent}  {risk['url']}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Analiza grafu aktualizacji OpenShift")
    ap.add_argument("--current", required=True, help="bieżąca wersja klastra, np. 4.20.14")
    ap.add_argument("--channel", action="append", required=True,
                    help="kanał do sprawdzenia (można podać wiele; ostatni = docelowy)")
    ap.add_argument("--target", default="latest", help="wersja docelowa lub 'latest'")
    ap.add_argument("--arch", default="amd64", help="architektura: amd64, arm64, multi, ...")
    ap.add_argument("--graph-url", default=DEFAULT_GRAPH_URL, help="adres API grafu (np. lokalny OSUS)")
    ap.add_argument("--cacert", help="plik CA do weryfikacji TLS (np. lokalny OSUS)")
    ap.add_argument("--allow-conditional", action="store_true",
                    help="dopuść krawędzie warunkowe przy liczeniu ścieżki")
    ap.add_argument("--summary-file", help="zapisz podsumowanie w formacie JSON")
    args = ap.parse_args()

    current = args.current
    graphs = {}
    for channel in args.channel:
        try:
            graphs[channel] = UpdateGraph(channel, fetch_graph(args.graph_url, channel, args.arch, args.cacert))
        except Exception as exc:  # sieć, TLS, JSON — raportujemy i idziemy dalej
            print(f"  [ERR]  Nie udało się pobrać grafu dla kanału {channel}: {exc}")

    if not graphs:
        return 2

    target_channel = args.channel[-1]
    for channel, g in graphs.items():
        print(f"\n  Kanał {channel}: {len(g.versions)} wersji, najnowsza: {g.latest() or '-'}")
        if current not in g.versions:
            print(f"    Bieżąca wersja {current} NIE występuje w tym kanale.")
            continue
        print(f"    Najnowsza w linii {minor_of(current)}: {g.latest(minor_of(current))}")
        if channel != target_channel:
            continue
        rec = g.recommended_from(current)
        cond = g.conditional_from(current)
        print(f"    Rekomendowane bezpośrednie aktualizacje z {current} ({len(rec)}):")
        print("      " + (", ".join(rec) if rec else "brak"))
        if cond:
            print(f"    Aktualizacje warunkowe (znane ryzyka, Red Hat ich NIE rekomenduje domyślnie):")
            for dst in cond:
                print(f"    * {current} -> {dst}")
                print_risks(g, current, dst)

    g = graphs.get(target_channel)
    summary = {"current": current, "channel": target_channel, "arch": args.arch,
               "target": None, "path": [], "targetPayload": None, "conditionalHops": []}

    if g is None or current not in g.versions:
        print(f"\n  Nie można policzyć ścieżki: wersji {current} brak w kanale docelowym {target_channel}.")
        print("  Zwykle oznacza to, że najpierw trzeba zaktualizować się w obrębie bieżącego kanału.")
    else:
        prev = g.reachable(current, args.allow_conditional)
        if args.target == "latest":
            reachable = [v for v in prev if v != current]
            target = max(reachable, key=version_key) if reachable else None
        else:
            target = args.target
        path = g.path_to(prev, target) if target else []

        if not target:
            print(f"\n  Brak dostępnych aktualizacji z {current} w kanale {target_channel}.")
        elif not path:
            print(f"\n  Wersja {target} NIE jest osiągalna z {current} rekomendowaną ścieżką w {target_channel}.")
            if not args.allow_conditional:
                alt = g.path_to(g.reachable(current, True), target)
                if alt:
                    print(f"  Jest osiągalna przez krawędzie warunkowe: {' -> '.join(alt)}")
                    print("  Przeanalizuj ryzyka i uruchom z --allow-conditional, jeśli je akceptujesz.")
        else:
            hops = list(zip(path, path[1:]))
            conditional = [f"{a}->{b}" for a, b in hops if (a, b) in g.risks]
            print(f"\n  Ścieżka {current} -> {target} w kanale {target_channel} ({len(hops)} krok(i)):")
            print("    " + " -> ".join(path))
            for a, b in hops:
                if (a, b) in g.risks:
                    print(f"    UWAGA: krok {a} -> {b} jest warunkowy:")
                    print_risks(g, a, b)
            print(f"    Obraz release docelowy: {g.payload.get(target, '?')}")
            if g.errata.get(target):
                print(f"    Errata: {g.errata[target]}")
            summary.update({"target": target, "path": path,
                            "targetPayload": g.payload.get(target), "conditionalHops": conditional})

    if args.summary_file:
        with open(args.summary_file, "w", encoding="utf-8") as fh:
            json.dump(summary, fh, indent=2)
    return 0 if summary["target"] else 1


if __name__ == "__main__":
    sys.exit(main())
