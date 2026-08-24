# Possible improvements — Attribute Fall

> Reference document (backlog). Nothing here is urgent: the game works and is
> maintainable as-is. This list exists for when you *want* to invest time, not because
> you need to. Snapshot as of 2026-08-24, Godot 4.5, `main.gd` ≈ 1907 lines.

## Principles before touching anything

- **Do not refactor "to prepare for Godot upgrades."** Upgrade pain comes from engine
  API changes, not from how the `.gd` files are split. The current code-first
  architecture (a single, nearly-empty `main.tscn`) is already the most portable across
  versions: zero scene-format migrations.
- **The trigger for a serious refactor is feature growth**, not the engine version. If no
  new game modes / level editor / multiplayer are coming, the code is fine.
- **The game loop + scoring logic (`main.gd` ~1332–1906) stays together.** It is coupled
  to shared state; splitting it is high risk for little benefit.
- Always validate after a change: `godot --headless --check` (or the project's command).

---

## 1. Low-risk extractions (only if they bother you)

Self-contained blocks that can be pulled out of `main.gd` without touching game state.

- [ ] **Music → `MusicPlayer` node/class** (`main.gd` ~237–319, ~80 lines).
      The most independent block. `_build_music`, `_play_music`, `_fade_music_out`,
      `_update_music`, `_set_music_bus_db`, `_toggle_music`. ~80 lines for almost free.
- [ ] **CRT shader → its own node/class** (`main.gd` ~166–236, ~70 lines).
      `_build_crt`, `_set_crt`, `_crt_tick`, `_crt_burst`, `_crt_error_burst`.
      Also self-contained.

Combined impact: `main.gd` drops from ~1907 to ~1750 without touching game/scoring.

## 2. Do NOT do (for now)

Recorded so it is clear this is a conscious decision, not an oversight.

- [ ] ~~Break up HUD / panels / overlays~~ (`main.gd` ~448–1230). Heavily coupled to
      `score`, `combo`, `active_concepts`, `lane_cards`… Separating it forces passing
      references everywhere or introducing a state singleton. High cost, high risk.
- [ ] ~~Split the game loop / spawn / scoring~~. It is the heart of the game. Keep it together.

## 3. Robustness and quality (independent of file size)

Improvements that pay off even with no refactor.

- [ ] **Duplicated "keep in sync" constants.** There are comments like
      `CARD_W ... # keep in sync with ConceptCard.CARD_W` and
      `PIECE_W ... # matches RelationshipPiece.PIECE_W`. Change one side, forget the
      other = silent layout bug. Option: have `main.gd` read the value from the class
      (`ConceptCard.CARD_W`) instead of redefining it.
- [ ] **Headless smoke test.** A minimal script that boots the scene in `--headless`,
      runs `start_round()` for a few frames, and asserts there are no errors. Cheap, and
      catches regressions after Godot upgrades.
- [ ] **Validation CI.** `.github/` already exists; confirm it runs
      `godot --headless --check` on every push to catch API breakage early.

## 4. Content and data

- [ ] **Concept data source.** `prototype_data.gd` suggests hardcoded prototype data. If
      the SNOMED concept set is to grow, consider loading from an external resource/JSON
      instead of code, so content can be edited without touching logic. (Only if content
      will grow.)
- [ ] **Pending pharma-filter decision** (see project memory). Resolve whether it affects
      the set of playable concepts.

## 5. Internationalization

- [ ] **Migrate to Godot's `.po`/`.csv` translations.** Today i18n lives in `i18n.gd` +
      `_retranslate()`. If more languages beyond EN/ES are added, Godot's native
      translation system (`TranslationServer` + `.po` files) scales better. With only
      2 languages, the current approach is perfectly fine.

---

## Suggested priority

| Priority | Item | Cost | Risk |
|---|---|---|---|
| Medium | "Keep in sync" constants → read from the class | Low | Low |
| Medium | Headless smoke test + `--check` CI | Low | None |
| Low | Extract music / CRT | Low | Low |
| Low (conditional) | External data / more languages / pharma filter | Medium | Low |
| Do not do | HUD / game loop refactor | High | High |

**Rule of thumb:** only do what fixes a real pain. If none of this hurts today, the best
improvement is not touching a game that works.
