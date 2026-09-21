#!/usr/bin/env python3
"""yaml2json.py — konwersja plików YAML/JSON do JSON (jeden dokument na linię).

Użycie:
    yaml2json.py plik1.yaml [plik2.json ...]

Wynik nadaje się do bezpośredniego przetwarzania w jq.
"""
import json
import sys

import yaml


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8") as fh:
            for doc in yaml.safe_load_all(fh):
                if doc is not None:
                    print(json.dumps(doc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
