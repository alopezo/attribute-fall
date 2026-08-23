class_name PrototypeData
extends RefCounted

# Real game database, extracted from a SNOMED CT RF2 release by
# tools/build_concepts.py. Each entry:
#   {"id","label","relationships":[{"attribute","value"}, ...]}
# Loaded once; served as an endless, reshuffling pool (infinite mode).

const DATA_PATH := "res://data/concepts.json"

# Minimal fallback so the game still runs if the JSON is missing.
const FALLBACK := [
	{"id": "f1", "label": "Pneumonia", "relationships": [
		{"attribute": "Finding site", "value": "Lung structure"},
		{"attribute": "Associated morphology", "value": "Inflammation"}]},
	{"id": "f2", "label": "Appendicitis", "relationships": [
		{"attribute": "Finding site", "value": "Appendix structure"},
		{"attribute": "Associated morphology", "value": "Inflammation"}]},
	{"id": "f3", "label": "Fracture of femur", "relationships": [
		{"attribute": "Finding site", "value": "Femur structure"},
		{"attribute": "Associated morphology", "value": "Fracture"}]},
	{"id": "f4", "label": "Gastritis", "relationships": [
		{"attribute": "Finding site", "value": "Stomach structure"},
		{"attribute": "Associated morphology", "value": "Inflammation"}]},
	{"id": "f5", "label": "Abscess of lung", "relationships": [
		{"attribute": "Finding site", "value": "Lung structure"},
		{"attribute": "Associated morphology", "value": "Abscess"}]},
	{"id": "f6", "label": "Abscess of liver", "relationships": [
		{"attribute": "Finding site", "value": "Liver structure"},
		{"attribute": "Associated morphology", "value": "Abscess"}]},
]

static var _all: Array = []
static var _loaded := false
static var _order: Array = []
static var _cursor := 0

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if FileAccess.file_exists(DATA_PATH):
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(parsed) == TYPE_ARRAY and not parsed.is_empty():
				_all = parsed
	if _all.is_empty():
		push_warning("concepts.json not found or empty; using fallback data.")
		_all = FALLBACK

static func concept_count() -> int:
	_load()
	return _all.size()

# Start a fresh shuffled walk over the whole pool.
static func reset_pool() -> void:
	_load()
	_order = range(_all.size())
	_order.shuffle()
	_cursor = 0

# Next concept from the pool as fresh runtime state; reshuffles endlessly.
static func next_runtime_concept() -> Dictionary:
	_load()
	if _all.is_empty():
		return {}
	if _order.is_empty() or _cursor >= _order.size():
		reset_pool()
	var src = _all[_order[_cursor]]
	_cursor += 1
	return _runtime_copy(src)

static func _runtime_copy(c: Dictionary) -> Dictionary:
	var rels: Array = []
	for r in c.relationships:
		rels.append({"attribute": r.attribute, "value": r.value, "completed": false})
	return {"id": c.id, "label": c.label, "hier": c.get("hier", "other"), "relationships": rels}
