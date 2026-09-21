#!/usr/bin/env python3
"""yamlq.py — odczyt pojedynczej wartości z pliku YAML.

Użycie:
    yamlq.py <plik.yaml> <klucz.z.kropkami> [wartość_domyślna]

Przykład:
    yamlq.py mirror-vars.yaml registry.host
    yamlq.py mirror-vars.yaml mirror.parallelImages 4

Wartości skalarne są wypisywane jako tekst, listy/słowniki jako JSON.
Kod wyjścia 3, gdy klucza brak i nie podano wartości domyślnej.
"""
import json
import sys

import yaml


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 1

    path, key = sys.argv[1], sys.argv[2]
    with open(path, encoding="utf-8") as fh:
        node = yaml.safe_load(fh) or {}

    for part in key.split("."):
        if isinstance(node, dict) and part in node and node[part] is not None:
            node = node[part]
        else:
            if len(sys.argv) == 4:
                print(sys.argv[3])
                return 0
            return 3

    if isinstance(node, (dict, list)):
        print(json.dumps(node))
    elif isinstance(node, bool):
        print("true" if node else "false")
    else:
        print(node)
    return 0


if __name__ == "__main__":
    sys.exit(main())
