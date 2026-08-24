class_name ConceptCard
extends PanelContainer

# One concept lane card (design doc sections 5 & 11).
# Relationships are hidden and only revealed as they are completed;
# the card grows taller each time a relationship is resolved.

const Palette = preload("res://scripts/palette.gd")

signal clicked(lane_index: int)

const CARD_W := 190.0

var concept: Dictionary = {}       # runtime concept (may be empty when lane is empty)
var lane_index: int = 0

var _built := false
var _name_label: Label
var _count_label: Label
var _progress: ProgressBar
var _rows_box: VBoxContainer
var _rows: Array = []               # Array[Label], one per COMPLETED relationship
var _shown_rows := 0
var _style: StyleBoxFlat
var _pfill: StyleBoxFlat
var _hier_color: Color = Palette.CARD_BORDER
var _base_pos: Vector2
var _center_x: float = 0.0          # lane center; card is bottom-anchored and grows upward
var _bottom_y: float = 0.0
var _anchor := true                 # when false, animations control position directly

func _ensure_built() -> void:
	if _built:
		return
	_built = true
	# Card text is concept data (already in the chosen language) — never auto-translate.
	auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
	custom_minimum_size = Vector2(CARD_W, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP   # receive clicks/taps (children stay IGNORE)

	_style = StyleBoxFlat.new()
	_style.bg_color = Palette.CARD_BG
	_style.set_border_width_all(2)
	_style.border_color = Palette.CARD_BORDER
	_style.set_corner_radius_all(14)
	_style.content_margin_left = 13
	_style.content_margin_right = 13
	_style.content_margin_top = 9
	_style.content_margin_bottom = 9
	add_theme_stylebox_override("panel", _style)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(header)

	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 13)
	_name_label.add_theme_color_override("font_color", Palette.TEXT)
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Fixed min width so autowrap computes the CORRECT height (avoids inflation).
	_name_label.custom_minimum_size = Vector2(116, 0)
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_name_label)

	_count_label = Label.new()
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_label.add_theme_font_size_override("font_size", 10)
	_count_label.add_theme_color_override("font_color", Palette.MUTED)
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_count_label)

	_progress = ProgressBar.new()
	_progress.max_value = 100
	_progress.value = 0
	_progress.show_percentage = false
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress.custom_minimum_size = Vector2(0, 5)
	var pbg := StyleBoxFlat.new()
	pbg.bg_color = Palette.SLOT.darkened(0.35)
	pbg.set_corner_radius_all(3)
	_pfill = StyleBoxFlat.new()
	_pfill.bg_color = Palette.ACCENT
	_pfill.set_corner_radius_all(3)
	_progress.add_theme_stylebox_override("background", pbg)
	_progress.add_theme_stylebox_override("fill", _pfill)
	vb.add_child(_progress)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 3)
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_rows_box)

# Keep size and bottom-anchor synced every frame. Content size settles
# asynchronously across frames as autowrap labels re-flow, so a one-shot
# reset_size()/reposition is not enough.
func _process(_delta: float) -> void:
	if _built and _anchor:
		reset_size()
		_reposition()

# Anchor the card by its bottom edge at a lane center; it grows upward.
func place_bottom(center_x: float, bottom_y: float) -> void:
	_ensure_built()
	_center_x = center_x
	_bottom_y = bottom_y
	_reposition()

func _reposition() -> void:
	position = Vector2(_center_x - size.x / 2.0, _bottom_y - size.y)
	_base_pos = position

func get_top_y() -> float:
	return position.y

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(lane_index)

# Assign a concept to this lane and animate it in.
func setup(c: Dictionary) -> void:
	_ensure_built()
	concept = c
	scale = Vector2.ONE
	_shown_rows = 0
	_hier_color = Palette.hier_color(c.get("hier", "other"))
	_set_border(_hier_color)
	_pfill.bg_color = _hier_color
	_name_label.text = c.label
	_name_label.add_theme_color_override("font_color", Palette.TEXT)
	refresh()
	_animate_in()

# Show an empty lane (queue exhausted).
func setup_empty() -> void:
	_ensure_built()
	concept = {}
	scale = Vector2.ONE
	_shown_rows = 0
	_anchor = true
	_hier_color = Palette.CARD_BORDER
	modulate = Color(1, 1, 1, 0.28)
	_set_border(_hier_color)
	_name_label.text = "—"
	_name_label.add_theme_color_override("font_color", Palette.SLOT)
	_count_label.text = ""
	_progress.value = 0
	_clear_rows()
	reset_size()

func _clear_rows() -> void:
	# Free immediately (not queue_free) so reset_size() sees the correct child
	# count in the same frame; otherwise the card keeps the previous height.
	for lbl in _rows:
		_rows_box.remove_child(lbl)
		lbl.free()
	_rows.clear()

# Rebuild the visible rows: only COMPLETED relationships are shown.
func refresh() -> void:
	if concept.is_empty():
		return
	_clear_rows()
	var done := 0
	var total: int = concept.relationships.size()
	for r in concept.relationships:
		if r.completed:
			done += 1
			var lbl := Label.new()
			lbl.add_theme_font_size_override("font_size", 11)
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			lbl.custom_minimum_size = Vector2(CARD_W - 26.0, 0)  # fixed width -> correct wrap height
			lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			lbl.add_theme_color_override("font_color", Palette.attr_color(r.attribute))
			lbl.text = "✓ %s → %s" % [r.attribute, r.value]
			_rows_box.add_child(lbl)
			_rows.append(lbl)
	_count_label.text = "%d / %d" % [done, total]
	_progress.value = 0 if total == 0 else float(done) / float(total) * 100.0
	reset_size()
	# Fade in the newly revealed row.
	if done > _shown_rows and not _rows.is_empty():
		var newrow: Label = _rows.back()
		newrow.modulate.a = 0.0
		var t := create_tween()
		t.tween_property(newrow, "modulate:a", 1.0, 0.25)
	_shown_rows = done

# ----- feedback animations -----

func _set_border(c: Color) -> void:
	_style.border_color = c

func flash_correct() -> void:
	_set_border(Palette.CORRECT)
	var t := create_tween()
	t.tween_method(_set_border, Palette.CORRECT, _hier_color, 0.4)

func flash_wrong() -> void:
	_set_border(Palette.INCORRECT)
	var t := create_tween()
	t.tween_method(_set_border, Palette.INCORRECT, _hier_color, 0.5)
	_shake()

func highlight_valid() -> void:
	_set_border(Palette.ACCENT)
	var t := create_tween()
	t.tween_interval(0.6)
	t.tween_method(_set_border, Palette.ACCENT, _hier_color, 0.3)

func _shake() -> void:
	_anchor = false
	var x := _base_pos.x
	var t := create_tween()
	t.tween_property(self, "position:x", x - 8.0, 0.05)
	t.tween_property(self, "position:x", x + 8.0, 0.05)
	t.tween_property(self, "position:x", x - 5.0, 0.05)
	t.tween_property(self, "position:x", x, 0.05)
	t.tween_callback(func(): _anchor = true)

# Concept completion: scale up + glow, then fade/slide down. Awaited by main.
func play_complete_animation() -> void:
	_anchor = false
	pivot_offset = size / 2.0
	_set_border(Palette.CORRECT)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(self, "scale", Vector2(1.06, 1.06), 0.18)
	t.tween_property(self, "modulate:a", 1.0, 0.18)
	await t.finished
	var t2 := create_tween()
	t2.set_parallel(true)
	t2.tween_property(self, "scale", Vector2(0.9, 0.9), 0.3)
	t2.tween_property(self, "modulate:a", 0.0, 0.3)
	t2.tween_property(self, "position:y", _base_pos.y + 30.0, 0.3)
	await t2.finished
	# Reset transform so the lane can be reused.
	scale = Vector2.ONE
	position = _base_pos
	modulate = Color(1, 1, 1, 1)

func _animate_in() -> void:
	_anchor = false
	modulate = Color(1, 1, 1, 0)
	position = _base_pos + Vector2(0, 18)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(self, "modulate:a", 1.0, 0.25)
	t.tween_property(self, "position:y", _base_pos.y, 0.25)
	t.chain().tween_callback(func(): _anchor = true)
