#!/usr/bin/env python3
"""Build the Attribute Fall game database (data/concepts.json).

Concept SET comes from the IPS terminology (the free International Patient
Summary refset). RELATIONSHIPS and English labels come from a full SNOMED CT
International RF2 release, so the modelling is the current one (the IPS free set
lags behind and carries older modelling). Spanish is produced separately by
tools/build_es.py from the SNOMED CT Argentina Edition.

For each IPS member that is still active in the International release, we keep its
ACTIVE + INFERRED (excluding 'Is a') attribute relationships, using preferred
terms for the concept / attribute type / value, dedup by the text pair, keep
concepts with 2-5 attributes, tag the top-level hierarchy, and drop a few
categories / repetitive attribute-value pairs.

Output: data/concepts.json — a list of
    {"id","label","hier","relationships":[{"attribute","value"}, ...]}

Usage:
    python3 tools/build_concepts.py \
        "/path/to/SnomedCT_InternationalRF2_.../Snapshot" \
        "/path/to/SnomedCT_IPSTerminologyRelease_.../Snapshot" \
        data/concepts.json
"""
import csv
import glob
import json
import os
import sys
from collections import defaultdict

csv.field_size_limit(10 ** 7)

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
# tumour-staging histopathology modelling, and vaccine products.
EXCLUDE_PAIRS = {
    ("Interprets", "Lesion observable"),
    ("Interprets", "Histopathology test"),
    ("Plays role", "Active immunity stimulant role"),
}

MIN_RELS = 2
MAX_RELS = 5


def find(snapshot, pattern):
    hits = glob.glob(os.path.join(snapshot, "**", pattern), recursive=True)
    if not hits:
        raise FileNotFoundError(f"No file matching {pattern} under {snapshot}")
    return hits[0]


def read_rf2(path):
    with open(path, encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            yield row


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    intl, ips, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

    # 0) IPS concept set = active members of the IPS simple refset (816080008).
    #    A precise, self-contained membership — independent of whatever dependency
    #    concepts the IPS package happens to also ship.
    ips_refset = find(ips, "der2_Refset_*Simple*Snapshot*.txt")
    ips_set = set()
    for row in read_rf2(ips_refset):
        if row["active"] == "1":
            ips_set.add(row["referencedComponentId"])

    # International terminology files.
    concept_file = find(intl, "sct2_Concept_Snapshot*.txt")
    desc_file = find(intl, "sct2_Description_Snapshot*.txt")
    rel_file = find(intl, "sct2_Relationship_Snapshot*.txt")
    lang_file = find(intl, "der2_cRefset_LanguageSnapshot*.txt")

    # 1) active concepts (International)
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
        desc[row["id"]] = (row["conceptId"], row["typeId"], row["term"])
        if row["typeId"] == FSN:
            fsn_of[row["conceptId"]] = row["term"]

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
        if cid in fsn_of:
            t = fsn_of[cid]
            if t.endswith(")") and " (" in t:
                return t[: t.rfind(" (")]
            return t
        return None

    # 5) relationships: attributes AND Is-a parents (for hierarchy)
    attrs = defaultdict(list)
    parents = defaultdict(list)
    for row in read_rf2(rel_file):
        if row["active"] != "1":
            continue
        if row["typeId"] == IS_A:
            parents[row["sourceId"]].append(row["destinationId"])
            continue
        if row["characteristicTypeId"] != INFERRED:
            continue
        attrs[row["sourceId"]].append((row["typeId"], row["destinationId"]))

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

    # 6) build entries — only IPS members that are still active in International
    out = []
    skipped_no_label = 0
    dropped_inactive = 0
    for cid in ips_set:
        if cid not in active_concepts:
            dropped_inactive += 1
            continue
        rels = attrs.get(cid, [])
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
            key = (a, v)
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
    print(f"IPS refset members: {len(ips_set)}  (dropped {dropped_inactive} inactive in International)")
    print(f"Wrote {len(out)} concepts ({total_rels} relationships) -> {out_path}")
    print(f"Skipped {skipped_no_label} with no usable label")


if __name__ == "__main__":
    main()
