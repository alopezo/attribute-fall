# Attribute Fall

**▶ Play in your browser: https://alopezo.github.io/attribute-fall/**

A small arcade game where **SNOMED CT relationships fall** and you drop each one onto
the concept it defines. A falling block shows an attribute and its value
(e.g. `FINDING SITE → Lung structure`); move it over the concept it belongs to and drop.
Complete every relationship of a concept to clear it — endless mode, three lives.

Built with **Godot 4.5** (GDScript).

## Assetless by design

All visuals are **generated in code** with Godot's native UI primitives — `Control`
nodes and `StyleBoxFlat` (rounded rects, borders, glow). There's **no sprite or bitmap
game art**: just a couple of vector logos (SVG), a bundled font for glyph coverage, a
**screen shader** for the CRT/glitch effect, and **procedural sound effects** (PCM
generated at runtime) alongside a couple of bundled music tracks. The result is crisp at
any resolution and fully themeable from one palette.

## Play

Run the project in Godot 4.5+ (open the folder and press **F5**), or from the CLI:

```bash
godot --path .
```

**Controls**

| Action | Keyboard | Gamepad | Mouse / touch |
|---|---|---|---|
| Move | ← → · A D · J L | D-pad / left stick | — |
| Soft drop | ↓ / S | D-pad down | — |
| Hard drop | Space | A | — |
| Drop on a concept | — | — | click/tap the card |
| Pause | Esc | Start | — |
| Mute music | M | — | click ♪ |

Concept cards are colored by their top-level **hierarchy** (finding, procedure, product,
situation, substance, observable, body structure…); each falling block keeps a consistent
accent frame, with its **attribute name tinted by attribute type**.

## Game data

The concept pool is real SNOMED CT content, extracted from a **SNOMED CT RF2 release**
by [`tools/build_concepts.py`](tools/build_concepts.py):

```bash
python3 tools/build_concepts.py "/path/to/<Release>/Snapshot" data/concepts.json
```

It keeps active concepts with 2–5 defining attributes (active, inferred, excluding *Is a*),
using the **preferred synonym** of the concept, the attribute type, and the target value,
and tags each with its top-level hierarchy (Specimen concepts are excluded). The bundled
`data/concepts.json` was built from the **International Patient Summary (IPS) Terminology**
free set (~6,900 concepts).

> SNOMED CT is distributed by SNOMED International. Use of SNOMED CT content is subject to the
> applicable SNOMED CT licence; the IPS terminology subset is freely available.

## Resources

- Implementation Support Portal — https://www.implementation.snomed.org/
- SNOMED Demonstrators — https://ihtsdo.github.io/sct-implementation-demonstrator/#/home

## Credits

- **Music:** Free Rhythm Game Music Pack 1 — Tricks & Traps. Licensed under CC0 1.0 /
  Public Domain. Source: OpenGameArt.org.
- Built with [Godot](https://godotengine.org/) (MIT).
