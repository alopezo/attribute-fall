class_name RelationshipPiece
extends PanelContainer

# A single falling attribute -> value relationship (design doc sections 11 & 14).
# Sizes to its content (grows in height for long values); width is fixed.
# Border/glow + attribute text are colored by attribute type.

const Palette = preload("res://scripts/palette.gd")

const PIECE_W := 196.0
const MIN_H := 62.0

var attribute: String = ""
var value: String = ""
var lane_index: int = 0

var _built := false
var _style: StyleBoxFlat
var _attr_label: Label
var _val_label: Label

func setup(attr: String, val: String) -> void:
	attribute = attr
	value = val
	_build()

func _build() -> void:
	if _built:
		_attr_label.text = attribute.to_upper()
		_val_label.text = value
		reset_size()
		return
	_built = true

	var col := Palette.attr_color(attribute)   # colored by attribute type
	custom_minimum_size = Vector2(PIECE_W, MIN_H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_style = StyleBoxFlat.new()
	_style.bg_color = Palette.PIECE_BG
	_style.set_border_width_all(2)
	_style.border_color = col
	_style.set_corner_radius_all(14)
	_style.content_margin_left = 14
	_style.content_margin_right = 14
	_style.content_margin_top = 8
	_style.content_margin_bottom = 8
	_style.shadow_color = Color(col.r, col.g, col.b, 0.35)
	_style.shadow_size = 8
	add_theme_stylebox_override("panel", _style)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vb)

	var inner := PIECE_W - 28.0   # width available inside the content margins

	_attr_label = Label.new()
	_attr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_attr_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_attr_label.custom_minimum_size = Vector2(inner, 0)   # fixed width -> correct wrap height
	_attr_label.add_theme_color_override("font_color", col)
	_attr_label.add_theme_font_size_override("font_size", 12)
	_attr_label.text = attribute.to_upper()
	vb.add_child(_attr_label)

	_val_label = Label.new()
	_val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_val_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_val_label.custom_minimum_size = Vector2(inner, 0)
	_val_label.add_theme_color_override("font_color", Palette.TEXT)
	_val_label.add_theme_font_size_override("font_size", 16)
	_val_label.text = value
	vb.add_child(_val_label)

	reset_size()

# Correct drop: shrink and fade into the card, then remove.
func animate_success() -> void:
	pivot_offset = size / 2.0
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(self, "scale", Vector2(0.25, 0.25), 0.18)
	t.tween_property(self, "modulate:a", 0.0, 0.18)
	await t.finished
	queue_free()

# Wrong drop: break/fade away, then remove.
func animate_fail() -> void:
	pivot_offset = size / 2.0
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(self, "modulate:a", 0.0, 0.22)
	t.tween_property(self, "rotation", 0.22, 0.22)
	t.tween_property(self, "position:y", position.y + 24.0, 0.22)
	await t.finished
	queue_free()
