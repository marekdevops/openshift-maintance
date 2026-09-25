#!/usr/bin/env python3
"""estimate_size.py — oszacowanie rozmiaru mirrora z mapping.txt oc-mirror v2.

Czyta listę obrazów z dry-run, pobiera SAME MANIFESTY (bez warstw) i sumuje
rozmiary warstw, licząc każdą warstwę raz — obrazy Red Hata dzielą warstwy
bazowe, więc suma "po obrazach" potrafi zawyżyć wynik kilkukrotnie.

Wynik to rozmiar SKOMPRESOWANY: tyle zostanie pobrane z internetu i tyle mniej
więcej zajmą archiwa .tar. Rozpakowane dane w Quay zajmują zwykle 1,3-2x tyle.

Użycie:
  estimate_size.py --mapping <plik> [--authfile <plik>] [--arch amd64] [--jobs 12]
"""
import argparse
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor


def parse_mapping(path):
    """mapping.txt: 'docker://<źródło>=docker://<cel>' — bierzemy źródła, bez duplikatów."""
    images, seen = [], set()
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            src = line.split("=docker://", 1)[0] if "=docker://" in line else line.split("=", 1)[0]
            src = src.strip()
            if src.startswith("docker://"):
                src = src[len("docker://"):]
            if src and src not in seen:
                seen.add(src)
                images.append(src)
    return images


def repo_of(ref):
    """Nazwa repozytorium bez tagu i bez digestu (do adresowania po digeście)."""
    if "@" in ref:
        return ref.split("@", 1)[0]
    head, sep, tail = ref.rpartition(":")
    # ':' w części z portem (host:5000/repo) nie jest tagiem
    return head if sep and "/" not in tail else ref


def skopeo_raw(ref, authfile, timeout):
    cmd = ["skopeo", "inspect", "--raw"]
    if authfile:
        cmd += ["--authfile", authfile]
    cmd.append("docker://" + ref)
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip().split("\n")[-1][:200] or "skopeo inspect nie powiódł się")
    return json.loads(out.stdout)


def pick_from_index(manifest, arch):
    """Z listy manifestów wybiera wpis dla linux/<arch> (albo pierwszy sensowny)."""
    entries = manifest.get("manifests") or []
    for want_arch in (arch, None):
        for m in entries:
            p = m.get("platform") or {}
            if p.get("os") in (None, "linux") and (want_arch is None or p.get("architecture") == want_arch):
                if p.get("os") == "unknown" or p.get("architecture") == "unknown":
                    continue        # wpisy attestation/SBOM, nie obraz
                return m.get("digest")
    return None


def blobs_of(ref, authfile, arch, timeout):
    """Zwraca listę (digest, rozmiar) warstw i configu obrazu."""
    man = skopeo_raw(ref, authfile, timeout)
    media = man.get("mediaType", "")
    if "manifest.list" in media or "image.index" in media or "manifests" in man:
        digest = pick_from_index(man, arch)
        if not digest:
            return []
        man = skopeo_raw(repo_of(ref) + "@" + digest, authfile, timeout)
    out = []
    cfg = man.get("config") or {}
    if cfg.get("digest") and cfg.get("size"):
        out.append((cfg["digest"], int(cfg["size"])))
    for layer in man.get("layers") or []:
        if layer.get("digest") and layer.get("size"):
            out.append((layer["digest"], int(layer["size"])))
    # schema v1 (stare obrazy) nie podaje rozmiarów — zgłaszamy jako nieznane
    if not out and man.get("fsLayers"):
        raise RuntimeError("manifest schema v1 bez rozmiarów warstw")
    return out


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def main():
    ap = argparse.ArgumentParser(description="Oszacowanie rozmiaru mirrora z mapping.txt")
    ap.add_argument("--mapping", required=True, help="working-dir/dry-run/mapping.txt")
    ap.add_argument("--authfile", default=None, help="auth.json z poświadczeniami do rejestrów")
    ap.add_argument("--arch", default="amd64", help="architektura z listy manifestów (domyślnie amd64)")
    ap.add_argument("--jobs", type=int, default=12, help="równoległe zapytania (domyślnie 12)")
    ap.add_argument("--timeout", type=int, default=60, help="limit czasu na zapytanie [s]")
    args = ap.parse_args()

    images = parse_mapping(args.mapping)
    if not images:
        print("Pusta lista obrazów — nie ma czego liczyć.", file=sys.stderr)
        return 2
    print(f"  Obrazów na liście: {len(images)} — pytam rejestry o manifesty ({args.jobs} równolegle)...",
          file=sys.stderr)

    layers, failures, done = {}, [], 0

    def work(ref):
        try:
            return ref, blobs_of(ref, args.authfile, args.arch, args.timeout), None
        except Exception as exc:                      # noqa: BLE001 — chcemy zebrać każdy powód
            return ref, [], str(exc)

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for ref, blobs, err in pool.map(work, images):
            done += 1
            if err:
                failures.append((ref, err))
            for digest, size in blobs:
                layers[digest] = size
            if done % 200 == 0:
                print(f"    ... {done}/{len(images)}", file=sys.stderr)

    total = sum(layers.values())
    ok = len(images) - len(failures)
    print()
    print(f"  Obrazy odpytane   : {ok}/{len(images)}")
    print(f"  Unikalne warstwy  : {len(layers)}")
    print(f"  DO POBRANIA       : {human(total)}  (skompresowane — tyle pójdzie przez sieć i do archiwów)")
    print(f"  W rejestrze Quay  : ok. {human(total * 1.0)} - {human(total * 1.6)} (zależnie od kompresji)")
    if total:
        def eta(mbit):
            sec = total * 8 / (mbit * 10 ** 6)
            if sec < 60:
                return "<1 min"
            return f"{sec / 60:.0f} min" if sec < 3600 else f"{sec / 3600:.1f} h"
        print("  Czas pobierania   : " + ",  ".join(
            f"{mbit} Mb/s ≈ {eta(mbit)}" for mbit in (100, 250, 500, 1000)))
    if failures:
        print(f"\n  Nie udało się odpytać {len(failures)} obrazów (nie wliczone w sumę):")
        for ref, err in failures[:10]:
            print(f"    {ref}\n      {err}")
        if len(failures) > 10:
            print(f"    ... i {len(failures) - 10} więcej")
    return 0


if __name__ == "__main__":
    sys.exit(main())
