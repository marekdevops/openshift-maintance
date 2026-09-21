#!/usr/bin/env python3
"""03-generate-imageset.py — generuje ImageSetConfiguration (oc-mirror v2) z mirror-vars.yaml.

Użycie:
    03-generate-imageset.py -f config/mirror-vars.yaml [-o imageset-config.yaml]

Domyślnie wynik trafia do <mirror.baseDir>/imageset-config.yaml.

Skrypt:
  * waliduje plik zmiennych (wersje, kanały, reguły filtrowania oc-mirror),
  * buduje ImageSetConfiguration w formacie mirror.openshift.io/v2alpha1,
  * NIE łączy się z klastrem ani z internetem.

Kody wyjścia: 0 = OK, 1 = ostrzeżenia, 2 = błędy walidacji.
"""
import argparse
import copy
import datetime
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("BŁĄD: brak modułu Python 'yaml'. Na RHEL: sudo dnf install -y python3-pyyaml")

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
CHANNEL_RE = re.compile(r"^(stable|fast|candidate|eus)-(\d+\.\d+)$")
TAG_RE = re.compile(r"^v\d+\.\d+$")
ARCHS = {"amd64", "arm64", "ppc64le", "s390x", "multi"}


class Validator:
    def __init__(self):
        self.errors, self.warnings = [], []

    def error(self, msg):
        self.errors.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)


def vtuple(version):
    return tuple(int(x) for x in version.split("."))


def build_platform(v, platform, arch):
    channel = str(platform.get("channel", ""))
    current = str(platform.get("currentVersion", ""))
    target = str(platform.get("targetVersion", ""))

    m = CHANNEL_RE.match(channel)
    if not m:
        v.error(f"platform.channel '{channel}' — oczekiwano np. stable-4.21")
    for name, value in (("currentVersion", current), ("targetVersion", target)):
        if not VERSION_RE.match(value):
            v.error(f"platform.{name} '{value}' — oczekiwano formatu X.Y.Z")
    if v.errors:
        return None

    if vtuple(target) < vtuple(current):
        v.error(f"targetVersion {target} jest niższa niż currentVersion {current}")
    target_minor = ".".join(target.split(".")[:2])
    if m.group(2) != target_minor:
        v.error(f"kanał {channel} nie odpowiada linii wersji docelowej {target_minor} "
                f"(użyj np. stable-{target_minor})")
    if vtuple(target)[:2] > vtuple(current)[:2] and vtuple(target)[1] - vtuple(current)[1] > 1:
        v.warn("przeskok o więcej niż jedną wersję minor — sprawdź, czy to aktualizacja EUS-to-EUS "
               "(kanał eus-X.Y) i czy ścieżka z preflight jest poprawna")

    return {
        "architectures": [arch],
        "channels": [{
            "name": channel,
            "minVersion": current,
            "maxVersion": target,
            "shortestPath": bool(platform.get("shortestPath", True)),
        }],
        "graph": bool(platform.get("graph", True)),
    }


def build_package(v, catalog, pkg):
    name = pkg.get("name")
    if not name:
        v.error(f"{catalog}: pakiet bez pola 'name'")
        return None
    out = {"name": name}

    channels = pkg.get("channels") or ([pkg["channel"]] if pkg.get("channel") else [])
    min_version = pkg.get("minVersion")
    max_version = pkg.get("maxVersion")

    if channels:
        # Filtrowanie po kanale + wersji musi być NA POZIOMIE KANAŁU
        # (dokumentacja oc-mirror v2, "How filtering works", scenariusze 11-14).
        entries = []
        for ch in channels:
            entry = {"name": str(ch)}
            if min_version:
                entry["minVersion"] = str(min_version)
            if max_version:
                entry["maxVersion"] = str(max_version)
                v.warn(f"{name}: maxVersion odcina 'głowę' kanału — możliwy błąd 'multiple channel heads'")
            entries.append(entry)
        out["channels"] = entries
        # Gdy wybrany kanał nie jest domyślnym kanałem pakietu, oc-mirror wymaga
        # defaultChannel. Ustawiamy go zawsze — przy kanale domyślnym nic nie zmienia.
        out["defaultChannel"] = str(pkg.get("defaultChannel", channels[0]))
    else:
        if min_version:
            out["minVersion"] = str(min_version)
        if max_version:
            out["maxVersion"] = str(max_version)
        v.warn(f"{name}: brak kanału — zostanie zmirrorowana głowa KAŻDEGO kanału pakietu")
    return out


def build_operators(v, operators, platform_cfg):
    result, names_seen = [], set()
    for idx, cat in enumerate(operators or []):
        index = str(cat.get("catalog", "")).strip()
        if not index:
            v.error(f"operators[{idx}]: brak pola 'catalog'")
            continue
        if re.search(r"[:@][^/]*$", index.split("/", 1)[-1]):
            v.error(f"{index}: podaj katalog BEZ tagu — tagi wpisz w 'versions'")
            continue
        versions = cat.get("versions") or []
        if not versions:
            v.error(f"{index}: brak listy 'versions' (np. [v4.20, v4.21])")
            continue
        packages = cat.get("packages") or []
        if not packages:
            v.error(f"{index}: brak 'packages' — mirror całego katalogu to setki GB; "
                    "jeśli naprawdę tego chcesz, dopisz ręcznie 'full: true' w wygenerowanym pliku")
            continue

        built = [p for p in (build_package(v, index, pkg) for pkg in packages) if p]
        for p in built:
            names_seen.add(p["name"])
        for tag in versions:
            tag = str(tag)
            if not TAG_RE.match(tag):
                v.error(f"{index}: wersja katalogu '{tag}' — oczekiwano np. v4.21")
                continue
            result.append({"catalog": f"{index}:{tag}", "packages": copy.deepcopy(built)})

    if platform_cfg and platform_cfg.get("graph") and "cincinnati-operator" not in names_seen:
        v.warn("platform.graph=true, ale brak pakietu 'cincinnati-operator' (OpenShift Update Service) "
               "— bez niego nie zainstalujesz lokalnego OSUS")
    return result


def build_additional_images(v, images):
    result = []
    for img in images or []:
        name = img["name"] if isinstance(img, dict) else str(img)
        first = name.split("/", 1)[0]
        if "/" not in name or not ("." in first or ":" in first or first == "localhost"):
            v.error(f"additionalImages: '{name}' — wymagana pełna nazwa z rejestrem "
                    "(np. registry.redhat.io/ubi9/ubi@sha256:...)")
            continue
        if "@sha256:" not in name:
            v.warn(f"additionalImages: '{name}' po tagu — wygeneruje ImageTagMirrorSet "
                   "(utworzenie ITMS restartuje węzły)")
        result.append({"name": name})
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description="Generator ImageSetConfiguration dla oc-mirror v2")
    ap.add_argument("-f", "--vars", required=True, help="plik mirror-vars.yaml")
    ap.add_argument("-o", "--output", help="plik wynikowy (domyślnie <mirror.baseDir>/imageset-config.yaml)")
    args = ap.parse_args()

    with open(args.vars, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}

    v = Validator()
    arch = str(cfg.get("cluster", {}).get("architecture", "amd64"))
    if arch not in ARCHS:
        v.error(f"cluster.architecture '{arch}' — dozwolone: {', '.join(sorted(ARCHS))}")

    platform_cfg = build_platform(v, cfg.get("platform") or {}, arch)
    mirror = {}
    if platform_cfg:
        mirror["platform"] = platform_cfg
    operators = build_operators(v, cfg.get("operators"), platform_cfg)
    if operators:
        mirror["operators"] = operators
    additional = build_additional_images(v, cfg.get("additionalImages"))
    if additional:
        mirror["additionalImages"] = additional

    isc = {"kind": "ImageSetConfiguration", "apiVersion": "mirror.openshift.io/v2alpha1"}
    archive_size = cfg.get("mirror", {}).get("archiveSizeGiB")
    if archive_size:
        isc["archiveSize"] = int(archive_size)
    isc["mirror"] = mirror

    for w in v.warnings:
        print(f"  [WARN] {w}")
    for e in v.errors:
        print(f"  [ERR]  {e}")
    if v.errors:
        print(f"\nWalidacja nieudana ({len(v.errors)} błędów) — plik NIE został zapisany.")
        return 2

    output = args.output
    if not output:
        base = os.path.expanduser(str(cfg.get("mirror", {}).get("baseDir", ".")))
        output = os.path.join(base, "imageset-config.yaml")
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)

    header = (
        "# Wygenerowano przez 03-generate-imageset.py — NIE edytuj ręcznie.\n"
        f"# Źródło: {os.path.abspath(args.vars)}\n"
        f"# Data:   {datetime.datetime.now().isoformat(timespec='seconds')}\n"
        "# Zmiany wprowadzaj w pliku zmiennych i wygeneruj ponownie.\n"
    )
    with open(output, "w", encoding="utf-8") as fh:
        fh.write(header)
        yaml.safe_dump(isc, fh, sort_keys=False, default_flow_style=False)

    print(f"  [OK]   Zapisano: {output}")
    print(f"         Sprawdź zawartość, a następnie: bin/04-mirror.sh -f {args.vars} --dry-run")
    return 1 if v.warnings else 0


if __name__ == "__main__":
    sys.exit(main())
