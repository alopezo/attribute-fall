class_name BgFall
extends Control

# Subtle decorative background: faint "ghost" relationship blocks drifting down.
# Only animates while visible in tree (i.e. while its menu overlay is shown).

const Palette = preload("res://scripts/palette.gd")

const SCREEN := Vector2(1280, 720)
const COUNT := 11

const SAMPLES := [
	["FINDING SITE", "Lung structure"],
	["ASSOCIATED MORPHOLOGY", "Inflammation"],
	["CAUSATIVE AGENT", "Streptococcus pneumoniae"],
	["FINDING SITE", "Femur structure"],
	["ASSOCIATED MORPHOLOGY", "Fracture"],
	["FINDING SITE", "Stomach structure"],
	["ASSOCIATED MORPHOLOGY", "Abscess"],
	["FINDING SITE", "Liver structure"],
	["FINDING SITE", "Appendix structure"],
	["ASSOCIATED MORPHOLOGY", "Inflammation"],
]

var _blocks: Array = []   # each: {panel, attr, val, speed, w, h}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	for i in COUNT:
		_blocks.append(_make_block())
	# Scatter across the screen so it is already populated when shown.
	for b in _blocks:
		_reroll(b, true)

func _make_block() -> Dictionary:
	var panel := Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.clip_contents = true   # keep decorative text inside the border
	var style := StyleBoxFlat.new()
	style.bg_color = Color(Palette.PIECE_BG.r, Palette.PIECE_BG.g, Palette.PIECE_BG.b, 0.55)
	style.set_border_width_all(1)
	style.border_color = Color(Palette.ACCENT.r, Palette.ACCENT.g, Palette.ACCENT.b, 0.5)
	style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 10.0
	vb.offset_right = -10.0
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vb)

	var attr := Label.new()
	attr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	attr.clip_text = true
	attr.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	attr.add_theme_font_size_override("font_size", 10)
	attr.add_theme_color_override("font_color", Palette.ACCENT)
	vb.add_child(attr)

	var val := Label.new()
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.clip_text = true
	val.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	val.add_theme_font_size_override("font_size", 14)
	val.add_theme_color_override("font_color", Palette.TEXT)
	vb.add_child(val)

	return {"panel": panel, "attr": attr, "val": val, "speed": 30.0, "w": 150.0, "h": 56.0}

func _reroll(b: Dictionary, initial: bool) -> void:
	var sample: Array = SAMPLES[randi() % SAMPLES.size()]
	b.attr.text = sample[0]
	b.val.text = sample[1]
	b.w = randf_range(120.0, 190.0)
	b.h = randf_range(52.0, 62.0)
	b.speed = randf_range(16.0, 42.0)
	var w: float = b.w
	var h: float = b.h
	var panel: Panel = b.panel
	panel.size = Vector2(w, h)
	panel.modulate = Color(1, 1, 1, randf_range(0.10, 0.20))
	var x := randf_range(0.0, SCREEN.x - w)
	var y := randf_range(0.0, SCREEN.y - h) if initial else -h - randf_range(0.0, 260.0)
	panel.position = Vector2(x, y)

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	for b in _blocks:
		var panel: Panel = b.panel
		panel.position.y += b.speed * delta
		if panel.position.y > SCREEN.y:
			_reroll(b, false)
