#!/usr/bin/env python3
"""Sanity-check Tome speaker voiceprints.

Given two or more *.voiceprints.json sidecars (written by Tome when
"Export speaker voiceprints" is on), print the pairwise cosine similarity
between every speaker across all files.

Gate for phases 2-3: the same person recorded in two different sessions
should score high (≈ >0.7); two different people should score noticeably
lower. If that separation isn't there, tune toward the PLDA embedding or
raise the activeSeconds floor before building enrollment/matching on top.

Usage:
    python3 scripts/voiceprint_cosine.py a.voiceprints.json b.voiceprints.json [...]
"""
import json
import math
import sys


def load(path):
    with open(path) as f:
        data = json.load(f)
    stem = path.rsplit("/", 1)[-1].replace(".voiceprints.json", "")
    rows = []
    for label, sp in sorted(data.get("speakers", {}).items()):
        rows.append((f"{stem}::{label}", sp["embedding"], sp.get("activeSeconds", 0.0)))
    return rows, data.get("model", "?"), data.get("dimension", "?")


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na > 0 and nb > 0 else 0.0


def main(paths):
    speakers, models, dims = [], set(), set()
    for p in paths:
        rows, model, dim = load(p)
        speakers.extend(rows)
        models.add(model)
        dims.add(dim)

    if len(models) > 1:
        print(f"WARNING: mixed models {models} — vectors are NOT comparable across models.\n")
    if len(dims) > 1:
        print(f"WARNING: mixed dimensions {dims}.\n")
    if not speakers:
        print("No speakers found in the given sidecars.")
        return

    n = len(speakers)
    print("Cosine similarity matrix (1.00 = identical voice):\n")
    print(" " * 6 + "".join(f"{j:>7}" for j in range(n)))
    for i in range(n):
        cells = "".join(f"{cosine(speakers[i][1], speakers[j][1]):7.2f}" for j in range(n))
        print(f"[{i:>2}] " + cells)
    print()
    for i, (name, _, active) in enumerate(speakers):
        print(f"  [{i:>2}] {name}  (activeSeconds={active:.1f})")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1:])
