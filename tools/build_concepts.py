#!/usr/bin/env python3
"""Build the Attribute Fall game database from a SNOMED CT RF2 Snapshot release.

Extracts every ACTIVE concept that has >= 2 defining attribute relationships
(active, inferred, excluding 'Is a'), using the PREFERRED SYNONYM of the
concept, the relationship type, and the target/value.

Output: data/concepts.json — a list of
    {"id": "<sctid>", "label": "<PT>", "relationships": [{"attribute","value"}, ...]}

Usage:
    python3 tools/build_concepts.py \
        "/path/to/SnomedCT_IPSTerminologyRelease_.../Snapshot" \
        data/concepts.json
"""
import csv
import json
import os
import sys
from collections import defaultdict

# --- SNOMED CT metadata concept ids ---
FSN = "900000000000003001"
SYNONYM = "900000000000013009"
PREFERRED = "900000000000548007"
IS_A = "116680003"
INFERRED = "900000000000011006"
ROOT = "138875005"

# Top-level SNOMED CT hierarchy (direct children of the root) -> game category key.
TOP_CATEGORY = {
    "404684003": "finding",        # Clinical finding
    "71388002": "procedure",       # Procedure
    "123038009": "specimen",       # Specimen
    "373873005": "product",        # Pharmaceutical / biologic product
    "243796009": "situation",      # Situation with explicit context
    "105590001": "substance",      # Substance
    "363787002": "observable",     # Observable entity
    "123037004": "bodystructure",  # Body structure
    "410607006": "organism",       # Organism
    "260787004": "object",         # Physical object
    "272379006": "event",          # Event
    "78621006": "physforce",       # Physical force
    "48176007": "social",          # Social context
    "254291000": "staging",        # Staging and scales
    "370115009": "special",        # Special concept
    "900000000000441003": "metadata",
}
# When a concept reaches several top levels, prefer by this order.
CATEGORY_PRIORITY = [
    "finding", "procedure", "situation", "specimen", "product",
    "substance", "observable", "bodystructure", "organism", "object", "event",
]
# Categories excluded from the game pool.
EXCLUDE_CATEGORIES = {"specimen"}

# Attribute -> value pairs that make a concept play poorly: the repetitive
# tumour-staging histopathology modelling ("Tumour invasion into X, in situ" and
# friends). Drop any concept whose modelling contains one of these pairs.
EXCLUDE_PAIRS = {
    ("Interprets", "Lesion observable"),
    ("Interprets", "Histopathology test"),
    # Vaccine products ("... antigen only vaccine product") — repetitive
    # "Plays role → Active immunity stimulant role" + "Has active ingredient".
    ("Plays role", "Active immunity stimulant role"),
}

# Skip/relabel a few very generic attribute types that read poorly in a game.
# (Kept minimal on purpose; extend if desired.)
MIN_RELS = 2
MAX_RELS = 5          # exclude concepts with more than this, so every card shows
                     # the concept's COMPLETE real modeling (no truncation)


def find_file(folder, must_contain):
    for name in os.listdir(folder):
        if all(tok in name for tok in must_contain) and name.endswith(".txt"):
            return os.path.join(folder, name)
    raise FileNotFoundError(f"No file in {folder} matching {must_contain}")


def read_rf2(path):
    with open(path, encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            yield row


def main():
    snapshot = sys.argv[1] if len(sys.argv) > 1 else None
    out_path = sys.argv[2] if len(sys.argv) > 2 else "data/concepts.json"
    if not snapshot or not os.path.isdir(snapshot):
        sys.exit("Pass the path to the release's Snapshot folder as arg 1.")

    term = os.path.join(snapshot, "Terminology")
    lang_dir = os.path.join(snapshot, "Refset", "Language")

    concept_file = find_file(term, ["sct2_Concept_"])
    desc_file = find_file(term, ["sct2_Description_"])
    rel_file = find_file(term, ["sct2_Relationship_", "Snapshot"])
    lang_file = find_file(lang_dir, ["cRefset_", "Language"])

    # 1) active concepts
    active_concepts = set()
    for row in read_rf2(concept_file):
        if row["active"] == "1":
            active_concepts.add(row["id"])

    # 2) active descriptions: descId -> (conceptId, typeId, term)
    desc = {}
    fsn_of = {}
    for row in read_rf2(desc_file):
        if row["active"] != "1":
            continue
        did = row["id"]
        cid = row["conceptId"]
        typ = row["typeId"]
        term_txt = row["term"]
        desc[did] = (cid, typ, term_txt)
        if typ == FSN:
            fsn_of[cid] = term_txt

    # 3) preferred description ids (any language refset row marked Preferred)
    preferred_desc = set()
    for row in read_rf2(lang_file):
        if row["active"] == "1" and row["acceptabilityId"] == PREFERRED:
            preferred_desc.add(row["referencedComponentId"])

    # 4) preferred synonym (PT) per concept
    pt = {}
    for did, (cid, typ, term_txt) in desc.items():
        if typ == SYNONYM and did in preferred_desc:
            pt[cid] = term_txt

    def label_for(cid):
        if cid in pt:
            return pt[cid]
        # fallback: FSN without the trailing semantic tag
        if cid in fsn_of:
            t = fsn_of[cid]
            if t.endswith(")") and " (" in t:
                return t[: t.rfind(" (")]
            return t
        return None

    # 5) relationships: collect attributes AND Is-a parents (for hierarchy)
    attrs = defaultdict(list)     # sourceId -> [(typeId, destId), ...]
    parents = defaultdict(list)   # sourceId -> [parentId, ...]
    for row in read_rf2(rel_file):
        if row["active"] != "1":
            continue
        if row["typeId"] == IS_A:
            parents[row["sourceId"]].append(row["destinationId"])
            continue
        if row["characteristicTypeId"] != INFERRED:
            continue
        attrs[row["sourceId"]].append((row["typeId"], row["destinationId"]))

    # Determine each concept's game category from its top-level ancestor.
    cat_cache = {}

    def category_of(cid):
        if cid in cat_cache:
            return cat_cache[cid]
        seen = set()
        stack = [cid]
        found = set()
        while stack:
            n = stack.pop()
            if n in seen:
                continue
            seen.add(n)
            for p in parents.get(n, []):
                if p == ROOT:
                    found.add(TOP_CATEGORY.get(n, "other"))
                else:
                    stack.append(p)
        cat = "other"
        for c in CATEGORY_PRIORITY:
            if c in found:
                cat = c
                break
        cat_cache[cid] = cat
        return cat

    # 6) build entries
    out = []
    skipped_no_label = 0
    for cid, rels in attrs.items():
        if cid not in active_concepts:
            continue
        clabel = label_for(cid)
        if not clabel:
            skipped_no_label += 1
            continue
        seen = set()
        built = []
        for typ, dst in rels:
            a = label_for(typ)
            v = label_for(dst)
            if not a or not v:
                continue
            key = (a, v)               # game matches on the text pair
            if key in seen:
                continue
            seen.add(key)
            built.append({"attribute": a, "value": v})
        if len(built) < MIN_RELS or len(built) > MAX_RELS:
            continue
        if any((r["attribute"], r["value"]) in EXCLUDE_PAIRS for r in built):
            continue
        cat = category_of(cid)
        if cat in EXCLUDE_CATEGORIES:
            continue
        out.append({"id": cid, "label": clabel, "hier": cat, "relationships": built})

    out.sort(key=lambda c: c["label"].lower())

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))

    total_rels = sum(len(c["relationships"]) for c in out)
    print(f"Wrote {len(out)} concepts ({total_rels} relationships) -> {out_path}")
    print(f"Skipped {skipped_no_label} sources with no usable label")


if __name__ == "__main__":
    main()
