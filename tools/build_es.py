#!/usr/bin/env python3
"""Build the Spanish concept database (data/concepts.es.json) from the existing
English data/concepts.json plus a SNOMED CT edition that carries Spanish
descriptions (e.g. the SNOMED CT Argentina Edition).

The English pool is kept EXACTLY as-is: same concepts, same relationships, same
order. Only the displayed strings (concept label, attribute, value) are swapped
to their Spanish PREFERRED TERM (PT). Where no Spanish PT can be found the
English string is kept as a fallback, so the file is always drop-in compatible
with concepts.json and game matching stays consistent within a language.

Resolution strategy for each attribute/value string (English -> Spanish PT):
  1. Per-concept: read the concept's real inferred relationships from the
     release; match the English string against the type/value concept's English
     terms (PT + synonyms + FSN), then take that concept's Spanish PT.
  2. Global unique reverse map: English preferred term / FSN(no tag) -> concept
     id, only when unambiguous.
  3. Fallback: keep the English string.

Note: the Spanish PT is taken from the description tables regardless of whether
the CONCEPT is currently active, so concepts that are inactive in this edition
still get their Spanish term as long as an active preferred Spanish description
exists.

Usage:
    python3 tools/build_es.py \
        data/concepts.json \
        "/path/to/SnomedCT_Argentina-EditionRelease_.../Snapshot" \
        data/concepts.es.json
"""
import csv
import glob
import json
import os
import sys
from collections import defaultdict

csv.field_size_limit(10 ** 7)

FSN = "900000000000003001"
SYNONYM = "900000000000013009"
PREFERRED = "900000000000548007"
IS_A = "116680003"
INFERRED = "900000000000011006"


def find(snapshot, name):
    hits = glob.glob(os.path.join(snapshot, "**", name), recursive=True)
    if not hits:
        raise FileNotFoundError(f"No file matching {name} under {snapshot}")
    return hits[0]


def notag(t):
    return t[: t.rfind(" (")] if (t.endswith(")") and " (" in t) else t


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    en_path, snapshot, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

    desc_file = find(snapshot, "sct2_Description_*.txt")
    lang_file = find(snapshot, "der2_cRefset_Language*.txt")
    rel_file = find(snapshot, "sct2_Relationship_Snapshot*.txt")

    concepts = json.load(open(en_path, encoding="utf-8"))
    cids = {c["id"] for c in concepts}

    # preferred description ids (any language refset, active, Preferred)
    preferred = set()
    with open(lang_file, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            if r["active"] == "1" and r["acceptabilityId"] == PREFERRED:
                preferred.add(r["referencedComponentId"])

    # Spanish PT per concept + English match keys per concept + global reverse map
    es_pt = {}
    en_terms = defaultdict(set)          # cid -> {lowercased english terms}
    en_key_to_ids = defaultdict(set)     # english key -> {cid} (for global unique map)
    with open(desc_file, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            if r["active"] != "1":
                continue
            cid, typ, lc, term, did = (
                r["conceptId"], r["typeId"], r["languageCode"], r["term"], r["id"])
            if lc == "es" and typ == SYNONYM and did in preferred:
                es_pt.setdefault(cid, term)       # only the Spanish PT
            elif lc == "en":
                if typ == SYNONYM:
                    key = term.lower()
                    en_terms[cid].add(key)
                    if did in preferred:
                        en_key_to_ids[key].add(cid)
                elif typ == FSN:
                    en_terms[cid].add(term.lower())
                    en_terms[cid].add(notag(term).lower())
                    en_key_to_ids[notag(term).lower()].add(cid)

    # inferred, non-Is-a relationships for our concepts
    attrs = defaultdict(list)            # sourceId -> [(typeId, destId), ...]
    with open(rel_file, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            if r["active"] != "1" or r["sourceId"] not in cids:
                continue
            if r["typeId"] == IS_A or r["characteristicTypeId"] != INFERRED:
                continue
            attrs[r["sourceId"]].append((r["typeId"], r["destinationId"]))

    def global_id(term):
        ids = en_key_to_ids.get(term.lower())
        return next(iter(ids)) if ids and len(ids) == 1 else None

    def translate(term, rel_ids, is_attr):
        """English string -> (Spanish PT or None)."""
        # 1) per-concept RF2 match
        for typ, dst in rel_ids:
            cand = typ if is_attr else dst
            if term.lower() in en_terms.get(cand, ()):
                return es_pt.get(cand)
        # 2) global unique reverse map
        cid = global_id(term)
        if cid is not None:
            return es_pt.get(cid)
        return None

    stats = {"labels": 0, "attr": 0, "value": 0, "rels": 0, "collisions": 0}
    out = []
    for c in concepts:
        rel_ids = attrs.get(c["id"], [])
        label_es = es_pt.get(c["id"])
        if label_es:
            stats["labels"] += 1
        entry = {
            "id": c["id"],
            "label": label_es or c["label"],
            "hier": c.get("hier", "other"),
            "relationships": [],
        }
        seen_pairs = set()
        for rel in c["relationships"]:
            stats["rels"] += 1
            a_es = translate(rel["attribute"], rel_ids, True)
            v_es = translate(rel["value"], rel_ids, False)
            if a_es:
                stats["attr"] += 1
            if v_es:
                stats["value"] += 1
            a = a_es or rel["attribute"]
            v = v_es or rel["value"]
            # Keep pairs distinct within a concept (matching relies on it). If a
            # translation collides with an already-used pair, revert to English.
            if (a, v) in seen_pairs:
                a, v = rel["attribute"], rel["value"]
                if (a, v) in seen_pairs:
                    stats["collisions"] += 1
                    continue
            seen_pairs.add((a, v))
            entry["relationships"].append({"attribute": a, "value": v})
        out.append(entry)

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))

    rels = stats["rels"] or 1
    n = len(out) or 1
    print(f"Wrote {len(out)} concepts -> {out_path}")
    print(f"  labels es: {stats['labels']}/{len(out)} ({100*stats['labels']/n:.1f}%)")
    print(f"  attribute es: {stats['attr']}/{stats['rels']} ({100*stats['attr']/rels:.1f}%)")
    print(f"  value es: {stats['value']}/{stats['rels']} ({100*stats['value']/rels:.1f}%)")
    if stats["collisions"]:
        print(f"  dropped {stats['collisions']} relationship(s) to avoid duplicate pairs")


if __name__ == "__main__":
    main()
