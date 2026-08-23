extends Control

# SNOMED Game Drop — main game controller.
# Vertical, Tetris-like playfield: a narrow central well with side panels.
# Concept cards sit on the base and grow UPWARD as relationships are completed,
# so each lane's landing point rises and later pieces have less time than the first.

# Explicit preloads so the project runs even before the global class cache exists.
const Palette = preload("res://scripts/palette.gd")
const PrototypeData = preload("res://scripts/prototype_data.gd")
const ConceptCard = preload("res://scripts/concept_card.gd")
const RelationshipPiece = preload("res://scripts/relationship_piece.gd")
const Sfx = preload("res://scripts/sfx.gd")
const BgFall = preload("res://scripts/bg_fall.gd")

# ----- constants -----
const LANE_COUNT := 4
const TOTAL_CONCEPTS := 8
const START_LIVES := 3
const MAX_COMBO := 5

const SCREEN := Vector2(1280, 720)
const CARD_W := 190.0                            # keep in sync with ConceptCard.CARD_W
const LANE_PITCH := 210.0                        # horizontal distance between lane centers
const PLAY_TOP := 60.0
const BASE_Y := 700.0                            # bottom edge where cards rest
const WELL_LEFT := 208.0
const WELL_RIGHT := 1072.0

const PIECE_W := 196.0                           # matches RelationshipPiece.PIECE_W
const PIECE_START_Y := 88.0

const FALL_SPEED_START := 38.0
const FALL_SPEED_SOFT := 300.0
const FALL_SPEED_STEP := 11.0
const FALL_SPEED_MAX := 190.0

enum State { START, HOWTO, PLAYING, PAUSED, GAMEOVER, VICTORY, REVIEW }

# ----- game state -----
var state: int = State.START
var input_locked := false
var _counting := false             # true during the start countdown
var _input_guard := false          # brief lockout after game over (avoid reflex taps)
var _go_buttons: Array = []        # game-over buttons, disabled during the guard

var active_concepts: Array = []       # size LANE_COUNT, each a runtime concept dict
var lane_cards: Array = []            # Array[ConceptCard]
var played_concepts: Array = []       # every concept that appeared this round (deduped by id)
var current_piece: RelationshipPiece = null

var score := 0
var combo := 0
var best_combo := 0
var lives := START_LIVES
var concepts_completed := 0
var current_fall_speed := FALL_SPEED_START

var last_pair_key := ""
var last_pair_count := 0
var _skip_lane_next_spawn := -1     # lane just refilled; its concept is skipped for one spawn

# ----- nodes -----
var piece_layer: Control
var sfx: Sfx
var score_val: Label
var combo_val: Label
var lives_val: Label
var speed_val: Label
var message_label: Label
var countdown_label: Label
var getready_label: Label
var _cd_tween: Tween

var review_panel: Control
var review_rtl: RichTextLabel
var _review_from: int = State.GAMEOVER   # where CONCEPTS PLAYED was opened from

var start_panel: Control
var howto_panel: Control
var pause_panel: Control
var gameover_panel: Control
var victory_panel: Control
var go_stats_label: Label
var vic_stats_label: Label
var _default_focus: Dictionary = {}   # panel -> Button to focus when shown

func _ready() -> void:
	_setup_input()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_background()
	_build_lanes()
	piece_layer = Control.new()
	piece_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	piece_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(piece_layer)
	_build_hud()
	_build_overlays()
	sfx = Sfx.new()
	add_child(sfx)
	_build_logo()
	_show_only(start_panel)
	state = State.START

# SNOMED International badge, pinned bottom-right, above everything.
func _build_logo() -> void:
	var tex = load("res://assets/snomed_international.svg")
	if tex == null:
		return
	var logo := TextureRect.new()
	logo.texture = tex
	# Set expand/stretch BEFORE size, else size is clamped to the texture's 144px.
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var s := 60.0
	logo.custom_minimum_size = Vector2(s, s)
	logo.size = Vector2(s, s)
	logo.position = Vector2(SCREEN.x - s - 18.0, SCREEN.y - s - 16.0)
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.modulate = Color(1, 1, 1, 0.92)
	add_child(logo)

# ----- input actions (keyboard + gamepad, ready for Steam Deck) -----
func _setup_input() -> void:
	# name -> {keys, buttons, axes:[[axis, value], ...]}
	_add_action("af_left",  [KEY_LEFT, KEY_A, KEY_J], [JOY_BUTTON_DPAD_LEFT],  [[JOY_AXIS_LEFT_X, -1.0]])
	_add_action("af_right", [KEY_RIGHT, KEY_D, KEY_L], [JOY_BUTTON_DPAD_RIGHT], [[JOY_AXIS_LEFT_X, 1.0]])
	_add_action("af_soft",  [KEY_DOWN, KEY_S], [JOY_BUTTON_DPAD_DOWN], [[JOY_AXIS_LEFT_Y, 1.0]])
	_add_action("af_hard",  [KEY_SPACE], [JOY_BUTTON_A], [])
	_add_action("af_pause", [KEY_ESCAPE], [JOY_BUTTON_START], [])

func _add_action(name: String, keys: Array, buttons: Array, axes: Array) -> void:
	if InputMap.has_action(name):
		InputMap.erase_action(name)
	InputMap.add_action(name, 0.5)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(name, e)
	for b in buttons:
		var e := InputEventJoypadButton.new()
		e.button_index = b
		InputMap.action_add_event(name, e)
	for a in axes:
		var e := InputEventJoypadMotion.new()
		e.axis = a[0]
		e.axis_value = a[1]
		InputMap.action_add_event(name, e)

# ----- layout helpers -----
func _lane_center_x(i: int) -> float:
	var left_center := SCREEN.x / 2.0 - LANE_PITCH * (LANE_COUNT - 1) / 2.0
	return left_center + LANE_PITCH * i

func _lane_drop_y(lane: int) -> float:
	# Piece top position at which its bottom meets the top of the lane's card.
	var card: ConceptCard = lane_cards[lane]
	var ph := 0.0
	if current_piece != null:
		ph = current_piece.size.y
	return card.get_top_y() - ph

func _build_background() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Central "well".
	var well := Panel.new()
	well.position = Vector2(WELL_LEFT, PLAY_TOP - 6.0)
	well.size = Vector2(WELL_RIGHT - WELL_LEFT, BASE_Y + 12.0 - (PLAY_TOP - 6.0))
	well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var wstyle := StyleBoxFlat.new()
	wstyle.bg_color = Color(0.055, 0.078, 0.145, 1.0)
	wstyle.set_border_width_all(2)
	wstyle.border_color = Palette.CARD_BORDER
	wstyle.set_corner_radius_all(18)
	well.add_theme_stylebox_override("panel", wstyle)
	add_child(well)

	# Faint lane separators inside the well.
	for i in range(1, LANE_COUNT):
		var sep := ColorRect.new()
		sep.color = Color(1, 1, 1, 0.03)
		var x := (_lane_center_x(i - 1) + _lane_center_x(i)) / 2.0
		sep.position = Vector2(x - 1.0, PLAY_TOP + 4.0)
		sep.size = Vector2(2, BASE_Y - PLAY_TOP - 4.0)
		sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(sep)

	# Base line where cards rest.
	var base_line := ColorRect.new()
	base_line.color = Color(Palette.MUTED.r, Palette.MUTED.g, Palette.MUTED.b, 0.18)
	base_line.position = Vector2(WELL_LEFT + 8.0, BASE_Y + 2.0)
	base_line.size = Vector2(WELL_RIGHT - WELL_LEFT - 16.0, 2)
	base_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(base_line)

func _build_lanes() -> void:
	lane_cards.clear()
	active_concepts = [null, null, null, null]
	for i in LANE_COUNT:
		var card := ConceptCard.new()
		card.lane_index = i
		add_child(card)
		card.place_bottom(_lane_center_x(i), BASE_Y)
		card.setup_empty()
		card.clicked.connect(_on_card_clicked)
		lane_cards.append(card)

func _make_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _make_stat(caption: String, x: float, y: float, value_color: Color) -> Label:
	var cap := _make_label(caption, 13, Palette.MUTED)
	cap.position = Vector2(x, y)
	add_child(cap)
	var val := _make_label("", 26, value_color)
	val.position = Vector2(x, y + 18.0)
	add_child(val)
	return val

func _build_hud() -> void:
	_build_side_panel()
	_build_links_panel()

	# Right panel: stats stacked.
	var rx := 1092.0
	score_val = _make_stat("SCORE", rx, 96, Palette.TEXT)
	combo_val = _make_stat("COMBO", rx, 176, Palette.MUTED)
	lives_val = _make_stat("LIVES", rx, 256, Palette.INCORRECT)
	speed_val = _make_stat("SPEED", rx, 336, Palette.ACCENT2)

	# Transient message, centered in the well.
	message_label = _make_label("", 24, Palette.TEXT)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.position = Vector2(WELL_LEFT, 300)
	message_label.size = Vector2(WELL_RIGHT - WELL_LEFT, 40)
	message_label.modulate.a = 0.0
	add_child(message_label)

	# "GET READY" above the countdown.
	getready_label = _make_label("GET READY", 26, Palette.MUTED)
	getready_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	getready_label.position = Vector2(WELL_LEFT, 122)
	getready_label.size = Vector2(WELL_RIGHT - WELL_LEFT, 34)
	getready_label.modulate.a = 0.0
	add_child(getready_label)

	# Start countdown, high in the well so it does not cover the cards below.
	countdown_label = _make_label("", 96, Palette.ACCENT)
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_label.position = Vector2(WELL_LEFT, 170)
	countdown_label.size = Vector2(WELL_RIGHT - WELL_LEFT, 130)
	countdown_label.pivot_offset = countdown_label.size / 2.0
	countdown_label.modulate.a = 0.0
	add_child(countdown_label)

func _build_side_panel() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 74)
	panel.custom_minimum_size = Vector2(184, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	st.bg_color = Color(1, 1, 1, 0.03)
	st.set_border_width_all(1)
	st.border_color = Palette.CARD_BORDER
	st.set_corner_radius_all(14)
	st.content_margin_left = 16
	st.content_margin_right = 16
	st.content_margin_top = 14
	st.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", st)
	add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vb)

	vb.add_child(_make_label("ATTRIBUTE", 24, Palette.ACCENT))
	vb.add_child(_make_label("FALL", 24, Palette.ACCENT2))

	var tag := _make_label("SNOMED CT relationship match", 11, Palette.MUTED)
	tag.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tag.custom_minimum_size = Vector2(152, 0)
	vb.add_child(tag)

	vb.add_child(_spacer(10))
	vb.add_child(_divider())
	vb.add_child(_spacer(8))

	vb.add_child(_make_label("CONTROLS", 10, Palette.MUTED))
	vb.add_child(_make_label("Move     ← →\nDrop      Space\nPause    Esc", 13, Palette.TEXT))

	panel.reset_size()

func _build_links_panel() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 356)
	panel.custom_minimum_size = Vector2(184, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	st.bg_color = Color(1, 1, 1, 0.03)
	st.set_border_width_all(1)
	st.border_color = Palette.CARD_BORDER
	st.set_corner_radius_all(14)
	st.content_margin_left = 16
	st.content_margin_right = 16
	st.content_margin_top = 14
	st.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", st)
	add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vb)

	vb.add_child(_make_label("RESOURCES", 10, Palette.MUTED))

	var links := RichTextLabel.new()
	links.bbcode_enabled = true
	links.fit_content = true
	links.scroll_active = false
	links.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	links.custom_minimum_size = Vector2(152, 0)
	links.add_theme_font_size_override("normal_font_size", 13)
	var hex := Palette.ACCENT2.to_html(false)
	links.text = "[url=https://www.implementation.snomed.org/][u][color=#%s]Implementation Support ↗[/color][/u][/url]\n\n[url=https://ihtsdo.github.io/sct-implementation-demonstrator/#/home][u][color=#%s]SNOMED Demonstrators ↗[/color][/u][/url]" % [hex, hex]
	links.meta_clicked.connect(_on_link_meta)
	links.meta_hover_started.connect(func(_m): links.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND)
	links.meta_hover_ended.connect(func(_m): links.mouse_default_cursor_shape = Control.CURSOR_ARROW)
	vb.add_child(links)

	panel.reset_size()

func _on_link_meta(meta) -> void:
	OS.shell_open(str(meta))

func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _divider() -> ColorRect:
	var d := ColorRect.new()
	d.color = Palette.CARD_BORDER
	d.custom_minimum_size = Vector2(0, 1)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return d

func _update_hud() -> void:
	score_val.text = str(score)
	var mult := maxi(combo, 1)
	combo_val.text = "x%d" % mult
	combo_val.add_theme_color_override("font_color", _combo_color(combo))
	lives_val.text = ("♥ ".repeat(lives)).strip_edges() if lives > 0 else "—"
	speed_val.text = str(concepts_completed + 1)

# ----- overlays -----
func _make_overlay(with_bg := false) -> Dictionary:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	# Menu/how-to fully hide the game scene (opaque); pause/game-over let it show through.
	dim.color = Palette.BG if with_bg else Color(0.02, 0.03, 0.06, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	if with_bg:
		var fall := BgFall.new()
		root.add_child(fall)     # renders above the dim, below the content
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	center.add_child(vb)
	root.visible = false
	add_child(root)
	return {"root": root, "vb": vb}

func _add_centered_label(vb: VBoxContainer, text: String, size: int, color: Color) -> Label:
	var l := _make_label(text, size, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(l)
	return l

func _make_button(text: String, callback: Callable, _primary := true) -> Button:
	# Uniform menu button: all options look the same; only the focused/hovered
	# one is highlighted (standard menu behavior).
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 20)
	b.custom_minimum_size = Vector2(300, 54)

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(1, 1, 1, 0.04)
	normal.set_border_width_all(1)
	normal.border_color = Palette.CARD_BORDER
	normal.set_corner_radius_all(10)

	var hi := StyleBoxFlat.new()          # highlight ONLY for the focused/selected option
	hi.bg_color = Color(Palette.ACCENT.r, Palette.ACCENT.g, Palette.ACCENT.b, 0.18)
	hi.set_border_width_all(2)
	hi.border_color = Palette.ACCENT
	hi.set_corner_radius_all(10)

	var disabled := StyleBoxFlat.new()
	disabled.bg_color = Color(1, 1, 1, 0.02)
	disabled.set_border_width_all(1)
	disabled.border_color = Color(Palette.CARD_BORDER.r, Palette.CARD_BORDER.g, Palette.CARD_BORDER.b, 0.5)
	disabled.set_corner_radius_all(10)

	# hover looks like normal — the highlight comes from FOCUS only, and hovering
	# with the mouse moves focus (see mouse_entered below). One selection, always.
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_stylebox_override("pressed", hi)
	b.add_theme_stylebox_override("focus", hi)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_color_override("font_color", Palette.TEXT)
	b.add_theme_color_override("font_hover_color", Palette.TEXT)
	b.add_theme_color_override("font_focus_color", Palette.TEXT)
	b.add_theme_color_override("font_pressed_color", Palette.TEXT)
	b.add_theme_color_override("font_disabled_color", Palette.MUTED)
	b.pressed.connect(callback)
	b.mouse_entered.connect(func():
		if not b.disabled:
			b.grab_focus())
	return b

func _build_overlays() -> void:
	# Main menu (with subtle falling background)
	var s := _make_overlay(true)
	start_panel = s.root
	_add_centered_label(s.vb, "ATTRIBUTE FALL", 56, Palette.ACCENT)
	_add_centered_label(s.vb, "Drop each SNOMED relationship onto the concept it defines.", 19, Palette.MUTED)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 18)
	s.vb.add_child(spacer)
	var start_btn := _make_button("START", start_round, true)
	var howto_btn := _make_button("HOW TO PLAY", _show_howto, false)
	var exit_btn := _make_button("EXIT", _exit_game, false)
	for btn in [start_btn, howto_btn, exit_btn]:
		var row := CenterContainer.new()
		row.add_child(btn)
		s.vb.add_child(row)
	_default_focus[start_panel] = start_btn

	# Discreet footer links.
	var footer := RichTextLabel.new()
	footer.bbcode_enabled = true
	footer.fit_content = true
	footer.scroll_active = false
	footer.mouse_filter = Control.MOUSE_FILTER_PASS
	footer.add_theme_font_size_override("normal_font_size", 14)
	footer.position = Vector2(0, SCREEN.y - 46)
	footer.size = Vector2(SCREEN.x, 30)
	var lhex := Palette.ACCENT2.to_html(false)
	var mhex := Palette.MUTED.to_html(false)
	footer.text = "[center][url=https://www.implementation.snomed.org/][u][color=#%s]Implementation Support ↗[/color][/u][/url]      [color=#%s]·[/color]      [url=https://ihtsdo.github.io/sct-implementation-demonstrator/#/home][u][color=#%s]SNOMED Demonstrators ↗[/color][/u][/url][/center]" % [lhex, mhex, lhex]
	footer.meta_clicked.connect(_on_link_meta)
	footer.meta_hover_started.connect(func(_m): footer.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND)
	footer.meta_hover_ended.connect(func(_m): footer.mouse_default_cursor_shape = Control.CURSOR_ARROW)
	start_panel.add_child(footer)

	# How to play (with subtle falling background)
	var h := _make_overlay(true)
	howto_panel = h.root
	_add_centered_label(h.vb, "HOW TO PLAY", 44, Palette.ACCENT)
	var body := _make_label(_howto_text(), 18, Palette.TEXT)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	body.custom_minimum_size = Vector2(760, 0)
	h.vb.add_child(body)

	var legend := RichTextLabel.new()
	legend.bbcode_enabled = true
	legend.fit_content = true
	legend.scroll_active = false
	legend.focus_mode = Control.FOCUS_NONE
	legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	legend.custom_minimum_size = Vector2(760, 0)
	legend.add_theme_font_size_override("normal_font_size", 16)
	legend.text = _hier_legend_text()
	h.vb.add_child(legend)

	var hspacer := Control.new()
	hspacer.custom_minimum_size = Vector2(0, 10)
	h.vb.add_child(hspacer)
	var back_btn := _make_button("BACK", _show_menu, true)
	var hrow := CenterContainer.new()
	hrow.add_child(back_btn)
	h.vb.add_child(hrow)
	_default_focus[howto_panel] = back_btn

	# Pause menu
	var p := _make_overlay()
	pause_panel = p.root
	_add_centered_label(p.vb, "PAUSED", 44, Palette.TEXT)
	var pause_resume := _make_button("RESUME", _toggle_pause)
	var pause_review := _make_button("CONCEPTS PLAYED", _show_review, false)
	var pause_menu := _make_button("MAIN MENU", _show_menu, false)
	var pause_exit := _make_button("EXIT", _exit_game, false)
	for btn in [pause_resume, pause_review, pause_menu, pause_exit]:
		var row := CenterContainer.new()
		row.add_child(btn)
		p.vb.add_child(row)
	_default_focus[pause_panel] = pause_resume

	# Game over
	var g := _make_overlay()
	gameover_panel = g.root
	_add_centered_label(g.vb, "GAME OVER", 48, Palette.INCORRECT)
	go_stats_label = _add_centered_label(g.vb, "", 22, Palette.TEXT)
	var go_btn := _make_button("TRY AGAIN", restart_round, true)
	var grow := CenterContainer.new()
	grow.add_child(go_btn)
	g.vb.add_child(grow)
	var go_review := _make_button("CONCEPTS PLAYED", _show_review, false)
	var grow_r := CenterContainer.new()
	grow_r.add_child(go_review)
	g.vb.add_child(grow_r)
	var go_menu := _make_button("MAIN MENU", _show_menu, false)
	var grow2 := CenterContainer.new()
	grow2.add_child(go_menu)
	g.vb.add_child(grow2)
	_default_focus[gameover_panel] = go_btn
	_go_buttons = [go_btn, go_review, go_menu]

	# Concepts-played review (scrollable, ids linked to the SNOMED URI)
	var r := _make_overlay()
	review_panel = r.root
	(r.root.get_child(0) as ColorRect).color = Palette.BG   # opaque
	_add_centered_label(r.vb, "CONCEPTS PLAYED", 40, Palette.ACCENT)
	review_rtl = RichTextLabel.new()
	review_rtl.bbcode_enabled = true
	review_rtl.scroll_active = true
	review_rtl.focus_mode = Control.FOCUS_NONE
	review_rtl.custom_minimum_size = Vector2(860, 470)
	review_rtl.add_theme_font_size_override("normal_font_size", 16)
	review_rtl.add_theme_font_size_override("bold_font_size", 16)
	review_rtl.meta_clicked.connect(_on_review_meta)
	r.vb.add_child(review_rtl)
	var review_back := _make_button("BACK", _close_review, true)
	var brow := CenterContainer.new()
	brow.add_child(review_back)
	r.vb.add_child(brow)
	_default_focus[review_panel] = review_back

	# Victory
	var v := _make_overlay()
	victory_panel = v.root
	_add_centered_label(v.vb, "ROUND COMPLETE", 48, Palette.CORRECT)
	vic_stats_label = _add_centered_label(v.vb, "", 22, Palette.TEXT)
	var vic_btn := _make_button("PLAY AGAIN", restart_round, true)
	var vrow := CenterContainer.new()
	vrow.add_child(vic_btn)
	v.vb.add_child(vrow)
	var vic_menu := _make_button("MAIN MENU", _show_menu, false)
	var vrow2 := CenterContainer.new()
	vrow2.add_child(vic_menu)
	v.vb.add_child(vrow2)
	_default_focus[victory_panel] = vic_btn

func _howto_text() -> String:
	return "\n".join([
		"Each falling block is a SNOMED relationship: an attribute and its",
		"value, e.g.  FINDING SITE → Lung structure.",
		"",
		"The 4 cards at the base are concepts. Their relationships are hidden;",
		"each correct drop is revealed and the card grows upward.",
		"",
		"•  Move the block over the concept the relationship belongs to and drop it.",
		"•  A relationship can fit more than one concept — any valid card counts.",
		"•  As you fill a concept its card grows, so each new relationship on it",
		"   lands sooner than the last — less time as the concept nears completion.",
		"•  Complete every relationship of a concept to clear it; it is then replaced",
		"   by a fresh concept in that lane. Endless mode — keep clearing concepts.",
		"•  A wrong drop costs a life (you have 3). Consecutive hits build a combo (up to x5).",
		"•  Overall falling speed rises the more concepts you clear.",
		"",
		"Keyboard:   ← →  /  A D  /  J L  move      ↓ or S  soft drop",
		"            SPACE  hard drop        ESC  pause",
		"Gamepad:    D-pad / left stick  move      A  hard drop      Start  pause",
		"Mouse / touch:   click a concept card to drop the piece there",
	])

func _hier_legend_text() -> String:
	var cats := [
		["finding", "Clinical finding"],
		["procedure", "Procedure"],
		["specimen", "Specimen"],
		["product", "Product"],
		["situation", "Situation"],
		["substance", "Substance"],
	]
	var parts: Array = []
	for c in cats:
		var hex := Palette.hier_color(c[0]).to_html(false)
		parts.append("[color=#%s]● %s[/color]" % [hex, c[1]])
	return "[color=#9AA7BD]Card border color = concept hierarchy:[/color]\n" + "     ".join(parts)

func _show_only(panel: Control) -> void:
	for pnl in [start_panel, howto_panel, pause_panel, gameover_panel, victory_panel, review_panel]:
		if pnl:
			pnl.visible = (pnl == panel)
	if panel != null and not _input_guard and _default_focus.has(panel):
		var btn: Button = _default_focus[panel]
		btn.call_deferred("grab_focus")

func _hide_overlays() -> void:
	_show_only(null)

func _show_menu() -> void:
	state = State.START
	_show_only(start_panel)

func _show_howto() -> void:
	state = State.HOWTO
	_show_only(howto_panel)

func _exit_game() -> void:
	get_tree().quit()

func _show_gameover() -> void:
	state = State.GAMEOVER
	_show_only(gameover_panel)

func _show_review() -> void:
	_review_from = state         # remember whether we came from pause or game over
	_populate_review()
	state = State.REVIEW
	_show_only(review_panel)

func _close_review() -> void:
	if _review_from == State.PAUSED:
		state = State.PAUSED
		_show_only(pause_panel)
	else:
		_show_gameover()

func _bb(s: String) -> String:
	return s.replace("[", "[lb]")   # escape BBCode opening bracket (e.g. "[D]...")

func _populate_review() -> void:
	var items := played_concepts.duplicate()
	items.sort_custom(func(a, b): return a.label.naturalnocasecmp_to(b.label) < 0)
	var lines: Array = []
	lines.append("[color=#9AA7BD]%d concepts played — click an id to open it in the SNOMED browser[/color]\n" % items.size())
	for c in items:
		var url := "http://snomed.info/id/%s" % str(c.id)
		lines.append("[b]%s[/b]   [url=%s][color=#6EA8FE]%s[/color][/url]" % [_bb(c.label), url, str(c.id)])
		for rel in c.relationships:
			lines.append("      [color=#9AA7BD]%s → %s[/color]" % [_bb(rel.attribute), _bb(rel.value)])
		lines.append("")
	review_rtl.text = "\n".join(lines)

func _on_review_meta(meta) -> void:
	OS.shell_open(str(meta))

# ----- round lifecycle -----
func start_round() -> void:
	score = 0
	combo = 0
	best_combo = 0
	lives = START_LIVES
	concepts_completed = 0
	current_fall_speed = FALL_SPEED_START
	last_pair_key = ""
	last_pair_count = 0
	_skip_lane_next_spawn = -1
	input_locked = false

	if current_piece:
		current_piece.queue_free()
		current_piece = null

	# Infinite mode: fill the 4 lanes from an endless, reshuffling pool.
	played_concepts.clear()
	PrototypeData.reset_pool()
	for i in LANE_COUNT:
		active_concepts[i] = PrototypeData.next_runtime_concept()
		lane_cards[i].setup(active_concepts[i])
		_record_played(active_concepts[i])

	_update_hud()
	_hide_overlays()
	get_viewport().gui_release_focus()   # so game keys aren't captured by a menu button
	state = State.PLAYING
	await _run_countdown()
	if state == State.PLAYING:
		spawn_next_piece()

# 3-2-1-GO so the player can read the concepts before the first piece falls.
func _run_countdown() -> void:
	_counting = true
	getready_label.modulate.a = 0.0
	var gt := create_tween()
	gt.tween_property(getready_label, "modulate:a", 1.0, 0.3)
	for n in ["3", "2", "1"]:
		_show_countdown(n, Palette.ACCENT)
		sfx.sfx_move()
		await _delay(0.85)
	_show_countdown("GO", Palette.CORRECT)
	var gt2 := create_tween()
	gt2.tween_property(getready_label, "modulate:a", 0.0, 0.3)
	sfx.sfx_correct()
	await _delay(0.65)
	countdown_label.modulate.a = 0.0
	_counting = false

func _show_countdown(txt: String, col: Color) -> void:
	# Kill any running tween so its tail can't blank the next number's alpha.
	if _cd_tween and _cd_tween.is_valid():
		_cd_tween.kill()
	countdown_label.text = txt
	countdown_label.scale = Vector2(1.4, 1.4)
	countdown_label.modulate = Color(col.r, col.g, col.b, 1.0)
	_cd_tween = create_tween()
	_cd_tween.set_parallel(true)
	_cd_tween.tween_property(countdown_label, "scale", Vector2.ONE, 0.35)
	_cd_tween.tween_property(countdown_label, "modulate:a", 0.0, 0.6)

func restart_round() -> void:
	start_round()

func end_game() -> void:
	state = State.GAMEOVER
	current_piece = null
	sfx.sfx_game_over()
	go_stats_label.text = "Concepts completed: %d\nScore: %d\nBest combo: x%d" % [concepts_completed, score, maxi(best_combo, 1)]
	# Brief lockout so reflex taps on game controls don't immediately restart/close.
	_input_guard = true
	for b in _go_buttons:
		b.disabled = true
	_show_only(gameover_panel)
	get_tree().create_timer(2.0).timeout.connect(_end_game_over_guard)

func _end_game_over_guard() -> void:
	_input_guard = false
	for b in _go_buttons:
		b.disabled = false
	if state == State.GAMEOVER and _default_focus.has(gameover_panel):
		(_default_focus[gameover_panel] as Button).grab_focus()

# ----- piece spawning -----
func _unresolved_pool(exclude_lane: int = -1) -> Array:
	var pool: Array = []
	for i in active_concepts.size():
		if i == exclude_lane:
			continue
		var c = active_concepts[i]
		if c == null:
			continue
		for r in c.relationships:
			if not r.completed:
				pool.append({"attribute": r.attribute, "value": r.value})
	return pool

func _pair_key(p: Dictionary) -> String:
	return "%s|%s" % [p.attribute, p.value]

# Pick a pair, avoiding the same exact pair >2 times in a row when alternatives exist.
func _pick_pair(pool: Array) -> Dictionary:
	var distinct := {}
	for p in pool:
		distinct[_pair_key(p)] = true
	var choice: Dictionary = pool[randi() % pool.size()]
	if distinct.size() > 1 and _pair_key(choice) == last_pair_key and last_pair_count >= 2:
		var attempts := 0
		while _pair_key(choice) == last_pair_key and attempts < 16:
			choice = pool[randi() % pool.size()]
			attempts += 1
	if _pair_key(choice) == last_pair_key:
		last_pair_count += 1
	else:
		last_pair_key = _pair_key(choice)
		last_pair_count = 1
	return choice

func spawn_next_piece() -> void:
	# Skip the just-refilled lane's concept for one spawn, so the player has
	# time to read the new concept before a piece for it appears.
	var pool := _unresolved_pool(_skip_lane_next_spawn)
	_skip_lane_next_spawn = -1
	if pool.is_empty():
		pool = _unresolved_pool()
	if pool.is_empty():
		return   # infinite mode keeps lanes full; this should not happen
	var pair := _pick_pair(pool)
	var piece := RelationshipPiece.new()
	piece.setup(pair.attribute, pair.value)
	piece.lane_index = 1
	piece_layer.add_child(piece)
	piece.position = Vector2(_lane_center_x(1) - PIECE_W / 2.0, PIECE_START_Y)
	current_piece = piece
	input_locked = false

# ----- input & falling -----
func _process(delta: float) -> void:
	if state != State.PLAYING or current_piece == null or input_locked:
		return
	var speed := current_fall_speed
	if Input.is_action_pressed("af_soft"):
		speed = maxf(speed, FALL_SPEED_SOFT)
	current_piece.position.y += speed * delta
	var target := _lane_drop_y(current_piece.lane_index)
	if current_piece.position.y >= target:
		current_piece.position.y = target
		resolve_drop(current_piece.lane_index)

func _unhandled_input(event: InputEvent) -> void:
	if _counting or _input_guard:
		return
	# Menu-like states rely on focusable buttons (keyboard + gamepad via ui_* actions);
	# here we only handle in-game actions and cancel/back.
	match state:
		State.HOWTO:
			if event.is_action_pressed("ui_cancel") or event.is_action_pressed("af_pause"):
				_show_menu()
		State.PLAYING:
			if event.is_action_pressed("af_left"):
				move_piece_left()
			elif event.is_action_pressed("af_right"):
				move_piece_right()
			elif event.is_action_pressed("af_hard"):
				hard_drop()
			elif event.is_action_pressed("af_pause"):
				_toggle_pause()
		State.PAUSED:
			if event.is_action_pressed("af_pause") or event.is_action_pressed("ui_cancel"):
				_toggle_pause()
		State.REVIEW:
			if event.is_action_pressed("ui_cancel") or event.is_action_pressed("af_pause"):
				_close_review()

func _toggle_pause() -> void:
	if state == State.PLAYING:
		state = State.PAUSED
		_show_only(pause_panel)
	elif state == State.PAUSED:
		state = State.PLAYING
		_hide_overlays()
		get_viewport().gui_release_focus()

func move_piece_left() -> void:
	if current_piece == null or input_locked:
		return
	var new_i: int = clampi(current_piece.lane_index - 1, 0, LANE_COUNT - 1)
	if new_i == current_piece.lane_index:
		return
	current_piece.lane_index = new_i
	_tween_piece_x()
	sfx.sfx_move()

func move_piece_right() -> void:
	if current_piece == null or input_locked:
		return
	var new_i: int = clampi(current_piece.lane_index + 1, 0, LANE_COUNT - 1)
	if new_i == current_piece.lane_index:
		return
	current_piece.lane_index = new_i
	_tween_piece_x()
	sfx.sfx_move()

func _tween_piece_x() -> void:
	var target_x := _lane_center_x(current_piece.lane_index) - PIECE_W / 2.0
	var t := create_tween()
	t.tween_property(current_piece, "position:x", target_x, 0.08).set_trans(Tween.TRANS_QUAD)

func hard_drop() -> void:
	if current_piece == null or input_locked:
		return
	current_piece.position.y = _lane_drop_y(current_piece.lane_index)
	resolve_drop(current_piece.lane_index)

# Mouse/touch: click a concept card to slide the piece to that lane, then drop it.
func _on_card_clicked(lane: int) -> void:
	if state != State.PLAYING or _counting or input_locked or current_piece == null:
		return
	if current_piece.lane_index == lane:
		hard_drop()
		return
	var piece := current_piece
	piece.lane_index = lane
	sfx.sfx_move()
	var target_x := _lane_center_x(lane) - PIECE_W / 2.0
	var t := create_tween()
	t.tween_property(piece, "position:x", target_x, 0.12).set_trans(Tween.TRANS_QUAD)
	await t.finished
	# Only drop if this is still the same, un-resolved piece.
	if state == State.PLAYING and current_piece == piece and not input_locked:
		hard_drop()

# ----- drop resolution (design doc section 16) -----
func resolve_drop(lane: int) -> void:
	if current_piece == null or input_locked:
		return
	input_locked = true
	var piece := current_piece
	current_piece = null

	var concept = active_concepts[lane]
	var correct := false
	if concept != null:
		var idx := _find_unresolved_match(concept, piece.attribute, piece.value)
		if idx >= 0:
			concept.relationships[idx].completed = true
			correct = true

	if correct:
		combo = mini(combo + 1, MAX_COMBO)
		best_combo = maxi(best_combo, combo)
		var gained := 100 * combo
		score += gained
		_update_hud()
		_pulse_combo()
		lane_cards[lane].refresh()
		lane_cards[lane].flash_correct()
		var txt := "+%d" % gained
		if combo >= 2:
			txt += "  ×%d" % combo
			_combo_popup(lane, combo)
		_float_text(lane, txt, Palette.CORRECT)
		sfx.sfx_correct()
		piece.animate_success()
		if _is_concept_complete(concept):
			await _complete_concept(lane)
		else:
			await _delay(0.12)
	else:
		lives -= 1
		combo = 0
		_update_hud()
		lane_cards[lane].flash_wrong()
		_show_message("Not part of this concept", Palette.INCORRECT)
		_highlight_valid_targets(piece)
		sfx.sfx_wrong()
		piece.animate_fail()
		if lives <= 0:
			await _delay(0.5)
			end_game()
			return
		await _delay(0.5)

	if state == State.PLAYING:
		spawn_next_piece()

func _find_unresolved_match(concept: Dictionary, attr: String, val: String) -> int:
	for i in concept.relationships.size():
		var r: Dictionary = concept.relationships[i]
		if not r.completed and r.attribute == attr and r.value == val:
			return i
	return -1

func _is_concept_complete(concept: Dictionary) -> bool:
	for r in concept.relationships:
		if not r.completed:
			return false
	return true

func _complete_concept(lane: int) -> void:
	score += 500
	concepts_completed += 1
	_increase_speed()
	_update_hud()
	sfx.sfx_concept_complete()
	_show_message("CONCEPT COMPLETE", Palette.ACCENT)
	await lane_cards[lane].play_complete_animation()
	_replace_completed_concept(lane)

func _replace_completed_concept(lane: int) -> void:
	# Infinite mode: always pull the next concept from the pool.
	var nxt := PrototypeData.next_runtime_concept()
	active_concepts[lane] = nxt
	lane_cards[lane].setup(nxt)
	_record_played(nxt)
	_skip_lane_next_spawn = lane   # give the player a moment to read it

func _record_played(c: Dictionary) -> void:
	if c == null or c.is_empty():
		return
	for p in played_concepts:
		if p.id == c.id:
			return
	played_concepts.append(c)

func _increase_speed() -> void:
	current_fall_speed = minf(FALL_SPEED_START + FALL_SPEED_STEP * concepts_completed, FALL_SPEED_MAX)

func _highlight_valid_targets(piece: RelationshipPiece) -> void:
	for i in LANE_COUNT:
		var c = active_concepts[i]
		if c == null:
			continue
		if _find_unresolved_match(c, piece.attribute, piece.value) >= 0:
			lane_cards[i].highlight_valid()

# ----- small effects -----
func _float_text(lane: int, text: String, color: Color) -> void:
	var l := _make_label(text, 24, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size = Vector2(120, 30)
	piece_layer.add_child(l)
	var top: float = lane_cards[lane].get_top_y()
	l.position = Vector2(_lane_center_x(lane) - 60.0, top - 34.0)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(l, "position:y", l.position.y - 62.0, 1.0)
	t.tween_property(l, "modulate:a", 0.0, 1.0).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(l.queue_free)

func _combo_color(n: int) -> Color:
	if n >= 5:
		return Color("E6C84F")   # gold
	if n == 4:
		return Color("F0A868")   # orange
	if n == 3:
		return Palette.ACCENT2   # blue
	if n == 2:
		return Palette.ACCENT    # teal
	return Palette.MUTED

func _pulse_combo() -> void:
	combo_val.pivot_offset = combo_val.size / 2.0
	combo_val.scale = Vector2(1.5, 1.5)
	var t := create_tween()
	t.tween_property(combo_val, "scale", Vector2.ONE, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _combo_popup(lane: int, n: int) -> void:
	var l := _make_label("COMBO ×%d" % n, 22, _combo_color(n))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size = Vector2(170, 28)
	piece_layer.add_child(l)
	var top: float = lane_cards[lane].get_top_y()
	l.position = Vector2(_lane_center_x(lane) - 85.0, top - 66.0)
	l.pivot_offset = l.size / 2.0
	l.scale = Vector2(0.6, 0.6)
	# pop-in scale
	var ts := create_tween()
	ts.tween_property(l, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# float up while holding, then fade near the end
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(l, "position:y", l.position.y - 64.0, 1.4)
	t.tween_property(l, "modulate:a", 0.0, 1.4).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(l.queue_free)

func _show_message(text: String, color: Color = Palette.TEXT) -> void:
	message_label.text = text
	message_label.add_theme_color_override("font_color", color)
	message_label.modulate.a = 1.0
	var t := create_tween()
	t.tween_interval(0.55)
	t.tween_property(message_label, "modulate:a", 0.0, 0.4)

func _delay(t: float) -> void:
	await get_tree().create_timer(t).timeout
