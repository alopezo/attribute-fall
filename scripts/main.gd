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
const Scores = preload("res://scripts/scores.gd")
const I18n = preload("res://scripts/i18n.gd")

# ----- constants -----
const LANE_COUNT := 4
const TOTAL_CONCEPTS := 8
const START_LIVES := 3
const MAX_LIVES := 6         # cap on bonus lives (HUD fit + anti-hoarding)
const MAX_COMBO := 5
const SCORE_BASE := 12      # per correct drop, before combo/speed
const SCORE_CONCEPT := 45   # bonus per completed concept, before speed
# Bonus lives: first at LIFE_FIRST, then every LIFE_INTERVAL (2500, 7500, 15000, ...).
# Points scale with speed, so these real-world intervals shrink as play speeds up.
const LIFE_FIRST := 2500
const LIFE_INTERVAL := 7500

const SCREEN := Vector2(1280, 720)
const CARD_W := 190.0                            # keep in sync with ConceptCard.CARD_W
const LANE_PITCH := 210.0                        # horizontal distance between lane centers
const PLAY_TOP := 16.0
const BASE_Y := 700.0                            # bottom edge where cards rest
const WELL_LEFT := 208.0
const WELL_RIGHT := 1072.0

const PIECE_W := 196.0                           # matches RelationshipPiece.PIECE_W
const PIECE_START_Y := 88.0

const FALL_SPEED_START := 38.0
const FALL_SPEED_SOFT := 300.0
const FALL_SPEED_STEP := 11.0
const FALL_SPEED_MAX := 190.0
# Gentle onboarding: the first few pieces of a round fall extra slow so a player
# new to the game (SNOMED experts/learners, not gamers) has time to read and
# orient. Piece INTRO_PIECES+1 onward uses the normal speed.
const FALL_SPEED_INTRO := 20.0
const INTRO_PIECES := 3
# Difficulty scales the whole fall-speed curve (start, intro, per-concept step,
# and cap) by one factor; "medium" is today's speed. Scoring follows via
# _speed_factor, so harder = faster = more points.
const DIFFICULTY_MULT := {"easy": 0.6, "medium": 1.0, "hard": 1.6}
const SETTINGS_PATH := "user://settings.cfg"

enum State { START, HOWTO, CREDITS, DIFFICULTY, PLAYING, PAUSED, GAMEOVER, REVIEW, HIGHSCORES }

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
var _next_life_score := LIFE_FIRST     # next score threshold that grants a bonus life
var concepts_completed := 0
var current_fall_speed := FALL_SPEED_START
var _pieces_spawned := 0     # per-round piece counter (for the slow intro pieces)
var _difficulty := "medium"
# Tutorial state (guided first two pieces).
var _tutorial_this_round := false   # tutorial runs during this round
var _tutorial_correct := 0          # correct drops so far (tutorial ends at 2)
var _tutorial_hold := false         # falling frozen, waiting for the first input
var _tutorial_line: Line2D
var _tutorial_pulse: Polygon2D       # travelling dot along the connector
var _tutorial_pulse_t := 0.0
var _tutorial_box: PanelContainer
var _tutorial_target_lane := -1

var last_pair_key := ""
var _bag: Array = []                # shuffle bag of pair keys
var _streak: Dictionary = {}        # concept id -> consecutive spawns owned by it
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

var scores: Scores
var highscores_panel: Control
var hs_list: VBoxContainer
var hs_status: Label
var _hs_from: int = State.START
var _scores_ctx := "view"                # "view" or "gameover"
var _go_scores_done := false
var _go_entries: Array = []
var go_name_group: VBoxContainer
var go_name_edit: LineEdit
var go_submit_btn: Button

var start_panel: Control
var howto_panel: Control
var credits_panel: Control
var difficulty_panel: Control
var pause_panel: Control
var gameover_panel: Control
var go_title: Label
var go_reveal: VBoxContainer
var go_stats_label: Label
var _default_focus: Dictionary = {}   # panel -> Button to focus when shown

func _ready() -> void:
	I18n.register()
	var lang := I18n.load_pref()
	TranslationServer.set_locale(lang)
	PrototypeData.set_language(lang)
	_difficulty = str(_get_setting("difficulty", "medium"))
	_setup_fonts()
	_setup_input()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

# Add DejaVu Sans as a glyph fallback so symbols (→ ✓ ♥ ●) render on web too,
# where Godot has no system-font fallback. Keeps the default font's look.
func _setup_fonts() -> void:
	var dv = load("res://assets/fonts/DejaVuSans.ttf")
	if dv == null:
		return
	var base = ThemeDB.fallback_font
	if base == null:
		return
	var fbs = base.get("fallbacks")
	if typeof(fbs) != TYPE_ARRAY:
		fbs = []
	if not fbs.has(dv):
		fbs.append(dv)
		base.set("fallbacks", fbs)
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
	scores = Scores.new()
	add_child(scores)
	scores.loaded.connect(_on_scores_loaded)
	scores.submitted.connect(_on_score_submitted)
	_build_music()
	_build_logo()
	_build_version_label()
	_build_crt()
	_build_music_toggle()
	_build_lang_toggle()
	_show_only(start_panel)
	state = State.START

# Full-screen CRT/glitch overlay (Route A: reads the backbuffer via screen_texture).
# Subtle, sporadic bursts; menus only (hidden during play).
var _crt: ColorRect
var _crt_mat: ShaderMaterial
var _crt_cooldown := 1.0
var _crt_was_menu := false
var _crt_error := false     # true during a wrong-drop glitch burst (shown even in-game)
func _build_crt() -> void:
	var sh = load("res://assets/crt_glitch.gdshader")
	if sh == null:
		return
	_crt_mat = ShaderMaterial.new()
	_crt_mat.shader = sh
	_crt_mat.set_shader_parameter("intensity", 0.0)
	_crt = ColorRect.new()
	_crt.material = _crt_mat
	_crt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_crt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crt)

func _set_crt(v: float) -> void:
	_crt_mat.set_shader_parameter("intensity", v)

func _crt_tick(delta: float) -> void:
	if _crt == null:
		return
	var in_menu := state != State.PLAYING
	_crt.visible = in_menu or _crt_error   # error bursts show even during play
	if in_menu and not _crt_was_menu:
		_crt_cooldown = randf_range(0.3, 0.8)   # kick in promptly when a menu appears (e.g. game over)
	_crt_was_menu = in_menu
	if not in_menu:
		return
	_crt_cooldown -= delta
	if _crt_cooldown <= 0.0:
		_crt_cooldown = randf_range(1.0, 2.6)
		_crt_burst()

func _crt_burst() -> void:
	var peak := randf_range(0.22, 0.42)   # subtle
	var t := create_tween()
	t.tween_method(_set_crt, 0.0, peak, 0.04)
	t.tween_method(_set_crt, peak, peak * 0.35, 0.08)
	t.tween_method(_set_crt, peak * 0.35, peak * 0.75, 0.05)
	t.tween_method(_set_crt, peak * 0.75, 0.0, 0.14)

# Sharp glitch on a wrong drop; shown even mid-game.
func _crt_error_burst() -> void:
	if _crt == null:
		return
	_crt_error = true
	_crt.visible = true
	var t := create_tween()
	t.tween_method(_set_crt, 0.65, 0.25, 0.06)
	t.tween_method(_set_crt, 0.25, 0.5, 0.05)
	t.tween_method(_set_crt, 0.5, 0.0, 0.2)
	t.tween_callback(func(): _crt_error = false)

# Looping background music: menu track vs in-game track, crossfaded on switch.
# Two players fade between each other; a dedicated bus handles mute (independent
# of the fade). On web the browser resumes audio on first input.
const MUSIC_VOL := -12.0
const MUSIC_FADE := 1.2
var _music_menu: AudioStream
var _music_game: AudioStream
var _music_muted := false
var _music_bus := -1
var _mplayers: Array = []          # two AudioStreamPlayers for crossfading
var _mactive := 0
var _mcur: AudioStream
var _mfade: Tween
var _music_btn: Button
var _music_slash: ColorRect
var _duck_target := 0.0
var _duck_tween: Tween
var _music_locked := false          # pause automatic music switching (start countdown)
var _audio_kicked := false          # web audio unlocks on the first user gesture

func _load_music(path: String) -> AudioStream:
	var s = load(path)
	if s != null and "loop" in s:
		s.loop = true
	return s

func _build_music() -> void:
	_music_menu = _load_music("res://assets/music/2_starting_over.ogg")
	_music_game = _load_music("res://assets/music/1_ascend.ogg")
	_music_bus = AudioServer.bus_count
	AudioServer.add_bus(_music_bus)
	AudioServer.set_bus_name(_music_bus, "Music")
	AudioServer.set_bus_send(_music_bus, "Master")
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = "Music"
		p.volume_db = -80.0
		add_child(p)
		_mplayers.append(p)
	_mcur = _music_menu
	_mplayers[_mactive].stream = _music_menu
	_mplayers[_mactive].volume_db = MUSIC_VOL
	_mplayers[_mactive].play()

# Crossfade to `stream` over `fade` seconds.
func _play_music(stream: AudioStream, fade: float) -> void:
	if _mplayers.is_empty() or stream == null or stream == _mcur:
		return
	_mcur = stream
	var old_i := _mactive
	var new_i := 1 - _mactive
	var np: AudioStreamPlayer = _mplayers[new_i]
	np.stream = stream
	np.volume_db = -80.0
	np.play()
	_mactive = new_i
	if _mfade and _mfade.is_valid():
		_mfade.kill()
	if fade <= 0.0:
		np.volume_db = MUSIC_VOL          # start immediately, no ramp
		_mplayers[old_i].volume_db = -80.0
		return
	_mfade = create_tween()
	_mfade.set_parallel(true)
	_mfade.tween_property(np, "volume_db", MUSIC_VOL, fade)
	_mfade.tween_property(_mplayers[old_i], "volume_db", -80.0, fade)

# Fade the currently playing track down to silence (without changing _mcur).
func _fade_music_out(dur: float) -> void:
	if _mplayers.is_empty():
		return
	if _mfade and _mfade.is_valid():
		_mfade.kill()
	_mfade = create_tween()
	_mfade.tween_property(_mplayers[_mactive], "volume_db", -80.0, dur)

# Game track while playing/paused, menu track elsewhere — crossfaded.
# Duck the music bus while paused so it stays audible but quieter.
# Skipped while _music_locked (e.g. during the start countdown).
func _update_music() -> void:
	if _mplayers.is_empty() or _music_locked:
		return
	var duck := -14.0 if state == State.PAUSED else 0.0
	if not is_equal_approx(duck, _duck_target):
		_duck_target = duck
		if _duck_tween and _duck_tween.is_valid():
			_duck_tween.kill()
		_duck_tween = create_tween()
		_duck_tween.tween_method(_set_music_bus_db, AudioServer.get_bus_volume_db(_music_bus), duck, 0.25)
	var want: AudioStream = _music_game if state == State.PLAYING or state == State.PAUSED else _music_menu
	_play_music(want, MUSIC_FADE)

func _set_music_bus_db(v: float) -> void:
	if _music_bus >= 0:
		AudioServer.set_bus_volume_db(_music_bus, v)

func _toggle_music() -> void:
	_music_muted = not _music_muted
	if _music_bus >= 0:
		AudioServer.set_bus_mute(_music_bus, _music_muted)
	_update_music_icon()

# Clickable ♪ toggle, top-right, always visible.
func _build_music_toggle() -> void:
	_music_btn = Button.new()
	_music_btn.text = "♪"
	_music_btn.tooltip_text = "Music on/off (M)"
	_music_btn.focus_mode = Control.FOCUS_NONE
	_music_btn.add_theme_font_size_override("font_size", 24)
	_music_btn.custom_minimum_size = Vector2(40, 40)
	_music_btn.size = Vector2(40, 40)
	_music_btn.position = Vector2(SCREEN.x - 54.0, 12.0)
	_music_btn.text = "♪"
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "focus"]:
		_music_btn.add_theme_stylebox_override(s, empty)
	_music_btn.pressed.connect(_toggle_music)
	add_child(_music_btn)

	# Diagonal strike shown when muted (drawn over the note).
	_music_slash = ColorRect.new()
	_music_slash.color = Palette.MUTED
	_music_slash.size = Vector2(30, 3)
	_music_slash.position = Vector2(5, 18.5)
	_music_slash.pivot_offset = Vector2(15, 1.5)
	_music_slash.rotation = deg_to_rad(-45)
	_music_slash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_music_slash.visible = false
	_music_btn.add_child(_music_slash)
	_update_music_icon()

func _update_music_icon() -> void:
	if _music_btn == null:
		return
	_music_btn.add_theme_color_override("font_color", Palette.MUTED if _music_muted else Palette.ACCENT)
	_music_btn.add_theme_color_override("font_hover_color", Palette.TEXT)
	if _music_slash:
		_music_slash.visible = _music_muted

# EN/ES language toggle, left of the music note. Shown in menus only (switching
# mid-game would desync the text-keyed piece bag). The chosen language applies to
# the concept data on the next round; UI text updates immediately.
var _lang_btn: Button
func _build_lang_toggle() -> void:
	_lang_btn = Button.new()
	_lang_btn.focus_mode = Control.FOCUS_NONE
	_lang_btn.add_theme_font_size_override("font_size", 15)
	_lang_btn.custom_minimum_size = Vector2(40, 40)
	_lang_btn.size = Vector2(40, 40)
	_lang_btn.position = Vector2(SCREEN.x - 100.0, 12.0)
	_lang_btn.tooltip_text = "Language / Idioma"
	_lang_btn.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "focus"]:
		_lang_btn.add_theme_stylebox_override(s, empty)
	_lang_btn.add_theme_color_override("font_color", Palette.MUTED)
	_lang_btn.add_theme_color_override("font_hover_color", Palette.TEXT)
	_lang_btn.pressed.connect(_toggle_language)
	add_child(_lang_btn)
	_update_lang_icon()

func _update_lang_icon() -> void:
	if _lang_btn:
		_lang_btn.text = I18n.lang.to_upper()

func _toggle_language() -> void:
	_set_language("es" if I18n.lang == "en" else "en")

# ----- persistent settings (shares user://settings.cfg with the language pref) -----
func _get_setting(key: String, default):
	var c := ConfigFile.new()
	c.load(SETTINGS_PATH)
	return c.get_value("game", key, default)

func _set_setting(key: String, value) -> void:
	var c := ConfigFile.new()
	c.load(SETTINGS_PATH)
	c.set_value("game", key, value)
	c.save(SETTINGS_PATH)

func _fall_mult() -> float:
	return float(DIFFICULTY_MULT.get(_difficulty, 1.0))

func _set_language(l: String) -> void:
	if l == I18n.lang:
		return
	I18n.save_pref(l)
	TranslationServer.set_locale(l)
	PrototypeData.set_language(l)
	_retranslate()
	_update_lang_icon()

# Plain Label/Button text auto-translates on locale change; here we refresh the
# bbcode / custom nodes that don't.
func _retranslate() -> void:
	if _links_rtl:
		_set_links_text()
	if _footer_rtl:
		_set_footer_text()
	if _rules_rtl:
		_set_rules_text()
	if _legend_rtl:
		_legend_rtl.text = _hier_legend_text()
	if _contact_rtl:
		_set_contact_text()
	if _demo_box:
		_fill_demo()
	if _music_btn:
		_music_btn.tooltip_text = tr("Music on/off (M)")

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

# Version badge, pinned top-left. Reads application/config/version so it
# stays in sync with project.godot. (Top-left is clear of the HUD, the music
# toggle, the SNOMED logo, and the web loading footer.) Menus only — hidden
# while actively playing.
var _version_label: Label
func _build_version_label() -> void:
	var v: String = str(ProjectSettings.get_setting("application/config/version", ""))
	if v == "":
		return
	_version_label = Label.new()
	_version_label.text = "v" + v
	_version_label.add_theme_font_size_override("font_size", 13)
	_version_label.add_theme_color_override("font_color", Palette.MUTED)
	_version_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_version_label.position = Vector2(16.0, 10.0)
	add_child(_version_label)

# ----- input actions (keyboard + gamepad, ready for Steam Deck) -----
func _setup_input() -> void:
	# name -> {keys, buttons, axes:[[axis, value], ...]}
	_add_action("af_left",  [KEY_LEFT, KEY_A, KEY_J], [JOY_BUTTON_DPAD_LEFT],  [[JOY_AXIS_LEFT_X, -1.0]])
	_add_action("af_right", [KEY_RIGHT, KEY_D, KEY_L], [JOY_BUTTON_DPAD_RIGHT], [[JOY_AXIS_LEFT_X, 1.0]])
	_add_action("af_soft",  [KEY_DOWN, KEY_S], [JOY_BUTTON_DPAD_DOWN], [[JOY_AXIS_LEFT_Y, 1.0]])
	_add_action("af_hard",  [KEY_SPACE], [JOY_BUTTON_A], [])
	_add_action("af_pause", [KEY_ESCAPE], [JOY_BUTTON_START], [])
	_add_action("af_mute",  [KEY_M], [], [])

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
	vb.add_child(_make_label("Move     ← →\nDrop      Space\nPause    Esc\nMute      M", 13, Palette.TEXT))

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
	links.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
	links.add_theme_font_size_override("normal_font_size", 13)
	links.meta_clicked.connect(_on_link_meta)
	links.meta_hover_started.connect(func(_m): links.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND)
	links.meta_hover_ended.connect(func(_m): links.mouse_default_cursor_shape = Control.CURSOR_ARROW)
	vb.add_child(links)
	_links_rtl = links
	_set_links_text()

	panel.reset_size()

var _links_rtl: RichTextLabel
func _set_links_text() -> void:
	var hex := Palette.ACCENT2.to_html(false)
	_links_rtl.text = "[url=https://www.implementation.snomed.org/][u][color=#%s]%s[/color][/u][/url]\n\n[url=https://ihtsdo.github.io/sct-implementation-demonstrator/#/home][u][color=#%s]%s[/color][/u][/url]" % [hex, tr("Implementation Support Portal →"), hex, tr("SNOMED Demonstrators →")]

var _footer_rtl: RichTextLabel
func _set_footer_text() -> void:
	var lhex := Palette.ACCENT2.to_html(false)
	var mhex := Palette.MUTED.to_html(false)
	_footer_rtl.text = "[center][url=https://www.implementation.snomed.org/][u][color=#%s]%s[/color][/u][/url]      [color=#%s]·[/color]      [url=https://ihtsdo.github.io/sct-implementation-demonstrator/#/home][u][color=#%s]%s[/color][/u][/url][/center]" % [lhex, tr("Implementation Support Portal →"), mhex, lhex, tr("SNOMED Demonstrators →")]

var _rules_rtl: RichTextLabel
func _set_rules_text() -> void:
	var acc := Palette.ACCENT.to_html(false)
	var bad := Palette.INCORRECT.to_html(false)
	var good := Palette.CORRECT.to_html(false)
	_rules_rtl.text = "\n".join([
		"[color=#%s]●[/color]  %s" % [acc, tr("Fill a concept to clear it — a new one takes its place. Endless mode.")],
		"[color=#%s]●[/color]  %s" % [acc, tr("A relationship can fit more than one concept — any valid card counts.")],
		"[color=#%s]●[/color]  %s" % [bad, tr("Wrong drop costs a life (you start with 3). Chain correct drops for combo ×5.")],
		"[color=#%s]●[/color]  %s" % [good, tr("Earn a bonus life at 2,500 points, then every 7,500 (up to 6).")],
	])

var _legend_rtl: RichTextLabel

var _contact_rtl: RichTextLabel
func _set_contact_text() -> void:
	var chex := Palette.ACCENT2.to_html(false)
	var cmhex := Palette.MUTED.to_html(false)
	_contact_rtl.text = "[center][color=#%s]%s[/color][url=mailto:info@snomed.org][u][color=#%s]info@snomed.org[/color][/u][/url][/center]" % [cmhex, tr("Questions? Write to "), chex]

# How-to demo row (falling piece -> concept card). Rebuilt on language change.
var _demo_box: HBoxContainer
func _fill_demo() -> void:
	for ch in _demo_box.get_children():
		ch.queue_free()
	_demo_box.add_child(_demo_piece(tr("Finding site"), tr("Lung structure")))
	var arrow := _make_label("→", 40, Palette.MUTED)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_demo_box.add_child(arrow)
	_demo_box.add_child(_demo_card(tr("Pneumonia")))

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
	var start_btn := _make_button("START", _show_difficulty, true)
	var howto_btn := _make_button("HOW TO PLAY", _show_howto, false)
	var hs_btn := _make_button("HIGH SCORES", _show_highscores, false)
	var credits_btn := _make_button("CREDITS", _show_credits, false)
	var menu_btns := [start_btn, howto_btn, hs_btn, credits_btn]
	if not OS.has_feature("web"):   # EXIT is meaningless in a browser
		menu_btns.append(_make_button("EXIT", _exit_game, false))
	for btn in menu_btns:
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
	footer.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
	footer.meta_clicked.connect(_on_link_meta)
	footer.meta_hover_started.connect(func(_m): footer.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND)
	footer.meta_hover_ended.connect(func(_m): footer.mouse_default_cursor_shape = Control.CURSOR_ARROW)
	start_panel.add_child(footer)
	_footer_rtl = footer
	_set_footer_text()

	# "Made with Godot" credit, bottom-left (balances the SNOMED badge bottom-right).
	var gtex = load("res://assets/godot_icon.svg")
	if gtex != null:
		var gicon := TextureRect.new()
		gicon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gicon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		gicon.texture = gtex
		gicon.custom_minimum_size = Vector2(22, 22)
		gicon.size = Vector2(22, 22)
		gicon.position = Vector2(24, SCREEN.y - 42)
		gicon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		start_panel.add_child(gicon)
		var glabel := _make_label("Made with Godot", 13, Palette.MUTED)
		glabel.position = Vector2(52, SCREEN.y - 40)
		start_panel.add_child(glabel)

	# How to play (with subtle falling background)
	var h := _make_overlay(true)
	howto_panel = h.root
	_add_centered_label(h.vb, "HOW TO PLAY", 40, Palette.ACCENT)

	# Visual demo: a falling relationship -> the concept it defines.
	var demo := HBoxContainer.new()
	demo.add_theme_constant_override("separation", 18)
	demo.alignment = BoxContainer.ALIGNMENT_CENTER
	demo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_demo_box = demo
	_fill_demo()
	var demo_row := CenterContainer.new()
	demo_row.add_child(demo)
	h.vb.add_child(demo_row)

	_add_centered_label(h.vb, "Move the falling relationship onto the concept it defines, and drop it.", 15, Palette.MUTED)

	# Short rules with colored dots.
	var rules := RichTextLabel.new()
	rules.bbcode_enabled = true
	rules.fit_content = true
	rules.scroll_active = false
	rules.focus_mode = Control.FOCUS_NONE
	rules.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rules.custom_minimum_size = Vector2(700, 0)
	rules.add_theme_font_size_override("normal_font_size", 16)
	rules.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
	h.vb.add_child(rules)
	_rules_rtl = rules
	_set_rules_text()

	# Controls as keycaps.
	var cbox := VBoxContainer.new()
	cbox.add_theme_constant_override("separation", 6)
	cbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cbox.add_child(_control_row("Move", ["←", "→", "/", "A", "D", "/", "J", "L"]))
	cbox.add_child(_control_row("Soft / hard drop", ["↓", "S", "·", "Space"]))
	cbox.add_child(_control_row("Pause", ["Esc"]))
	var extra := _make_label("Gamepad: D-pad / stick move · A drop · Start pause        Mouse / touch: click a card        M: mute music", 13, Palette.MUTED)
	extra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cbox.add_child(extra)
	var crow := CenterContainer.new()
	crow.add_child(cbox)
	h.vb.add_child(crow)

	# Hierarchy color legend (swatches).
	var legend := RichTextLabel.new()
	legend.bbcode_enabled = true
	legend.fit_content = true
	legend.scroll_active = false
	legend.focus_mode = Control.FOCUS_NONE
	legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	legend.custom_minimum_size = Vector2(700, 0)
	legend.add_theme_font_size_override("normal_font_size", 15)
	legend.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
	legend.text = _hier_legend_text()
	h.vb.add_child(legend)
	_legend_rtl = legend

	var back_btn := _make_button("BACK", _show_menu, true)
	var hrow := CenterContainer.new()
	hrow.add_child(back_btn)
	h.vb.add_child(hrow)
	_default_focus[howto_panel] = back_btn

	# Credits
	var c := _make_overlay(true)
	credits_panel = c.root
	_add_centered_label(c.vb, "CREDITS", 40, Palette.ACCENT)
	_add_centered_label(c.vb, "Attribute Fall", 24, Palette.TEXT)
	_add_centered_label(c.vb, "SNOMED Implementation Support Team", 19, Palette.TEXT)

	# Contact (clickable mailto).
	var contact := RichTextLabel.new()
	contact.bbcode_enabled = true
	contact.fit_content = true
	contact.scroll_active = false
	contact.focus_mode = Control.FOCUS_NONE
	contact.custom_minimum_size = Vector2(700, 0)
	contact.add_theme_font_size_override("normal_font_size", 16)
	contact.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
	contact.meta_clicked.connect(_on_link_meta)
	contact.meta_hover_started.connect(func(_m): contact.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND)
	contact.meta_hover_ended.connect(func(_m): contact.mouse_default_cursor_shape = Control.CURSOR_ARROW)
	c.vb.add_child(contact)
	_contact_rtl = contact
	_set_contact_text()

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 10)
	c.vb.add_child(spacer2)

	_add_centered_label(c.vb, "Music: Free Rhythm Game Music Pack 1 — Tricks & Traps (CC0, OpenGameArt.org)", 13, Palette.MUTED)
	_add_centered_label(c.vb, "Built with Godot Engine (MIT)", 13, Palette.MUTED)
	_add_centered_label(c.vb, "SNOMED CT content © SNOMED International", 13, Palette.MUTED)

	var cback := _make_button("BACK", _show_menu, true)
	var cbrow := CenterContainer.new()
	cbrow.add_child(cback)
	c.vb.add_child(cbrow)
	_default_focus[credits_panel] = cback

	# Difficulty (second "start" menu, with a subtle falling background)
	var dpanel := _make_overlay(true)
	difficulty_panel = dpanel.root
	_add_centered_label(dpanel.vb, "CHOOSE DIFFICULTY", 40, Palette.ACCENT)
	_add_centered_label(dpanel.vb, "Speed only — Easy always shows the tutorial", 18, Palette.MUTED)
	var dtop := Control.new()
	dtop.custom_minimum_size = Vector2(0, 14)
	dpanel.vb.add_child(dtop)
	var diffs := [["easy", "EASY"], ["medium", "NORMAL"], ["hard", "HARD"]]
	var first_diff_btn: Button = null
	for d in diffs:
		var key: String = d[0]
		var btn := _make_button(d[1], func(): _start_with_difficulty(key), false)
		if first_diff_btn == null:
			first_diff_btn = btn
		var brow := CenterContainer.new()
		brow.add_child(btn)
		dpanel.vb.add_child(brow)
	var dspacer := Control.new()
	dspacer.custom_minimum_size = Vector2(0, 16)
	dpanel.vb.add_child(dspacer)
	var dback := _make_button("BACK", _show_menu, false)
	var dbrow := CenterContainer.new()
	dbrow.add_child(dback)
	dpanel.vb.add_child(dbrow)
	_default_focus[difficulty_panel] = first_diff_btn

	# Pause menu
	var p := _make_overlay()
	pause_panel = p.root
	_add_centered_label(p.vb, "PAUSED", 44, Palette.TEXT)
	var pause_resume := _make_button("RESUME", _toggle_pause)
	var pause_restart := _make_button("RESTART", restart_round, false)
	var pause_review := _make_button("CONCEPTS PLAYED", _show_review, false)
	var pause_menu := _make_button("MAIN MENU", _show_menu, false)
	var pause_btns := [pause_resume, pause_restart, pause_review, pause_menu]
	if not OS.has_feature("web"):
		pause_btns.append(_make_button("EXIT", _exit_game, false))
	for btn in pause_btns:
		var row := CenterContainer.new()
		row.add_child(btn)
		p.vb.add_child(row)
	_default_focus[pause_panel] = pause_resume

	# Game over — title first, then a reveal group (stats + buttons) that appears
	# after a beat and pushes the title up (also covers the anti-reflex lockout).
	var g := _make_overlay()
	gameover_panel = g.root
	go_title = _add_centered_label(g.vb, "GAME OVER", 48, Palette.INCORRECT)
	go_reveal = VBoxContainer.new()
	go_reveal.alignment = BoxContainer.ALIGNMENT_CENTER
	go_reveal.add_theme_constant_override("separation", 14)
	g.vb.add_child(go_reveal)
	go_stats_label = _add_centered_label(go_reveal, "", 22, Palette.TEXT)

	# Name entry (only shown when the score makes the top 20).
	go_name_group = VBoxContainer.new()
	go_name_group.alignment = BoxContainer.ALIGNMENT_CENTER
	go_name_group.add_theme_constant_override("separation", 8)
	go_name_group.visible = false
	go_reveal.add_child(go_name_group)
	_add_centered_label(go_name_group, "New high score!  Enter your name:", 18, Palette.ACCENT)
	var name_row := HBoxContainer.new()
	name_row.alignment = BoxContainer.ALIGNMENT_CENTER
	name_row.add_theme_constant_override("separation", 8)
	go_name_edit = LineEdit.new()
	go_name_edit.placeholder_text = tr("Your name")
	go_name_edit.max_length = 16
	go_name_edit.custom_minimum_size = Vector2(220, 44)
	go_name_edit.add_theme_font_size_override("font_size", 18)
	go_name_edit.text_submitted.connect(func(_t): _on_submit_pressed())
	name_row.add_child(go_name_edit)
	go_submit_btn = _make_button("SUBMIT", _on_submit_pressed, true)
	go_submit_btn.custom_minimum_size = Vector2(150, 44)
	name_row.add_child(go_submit_btn)
	var name_center := CenterContainer.new()
	name_center.add_child(name_row)
	go_name_group.add_child(name_center)

	var go_btn := _make_button("TRY AGAIN", restart_round, true)
	var grow := CenterContainer.new()
	grow.add_child(go_btn)
	go_reveal.add_child(grow)
	var go_hs := _make_button("HIGH SCORES", _show_highscores, false)
	var grow_h := CenterContainer.new()
	grow_h.add_child(go_hs)
	go_reveal.add_child(grow_h)
	var go_review := _make_button("CONCEPTS PLAYED", _show_review, false)
	var grow_r := CenterContainer.new()
	grow_r.add_child(go_review)
	go_reveal.add_child(grow_r)
	var go_menu := _make_button("MAIN MENU", _show_menu, false)
	var grow2 := CenterContainer.new()
	grow2.add_child(go_menu)
	go_reveal.add_child(grow2)
	_default_focus[gameover_panel] = go_btn
	_go_buttons = [go_btn, go_hs, go_review, go_menu]

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
	review_rtl.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED   # concept data
	review_rtl.meta_clicked.connect(_on_review_meta)
	r.vb.add_child(review_rtl)
	var review_back := _make_button("BACK", _close_review, true)
	var brow := CenterContainer.new()
	brow.add_child(review_back)
	r.vb.add_child(brow)
	_default_focus[review_panel] = review_back

	# High scores (leaderboard from Firestore)
	var hp := _make_overlay()
	highscores_panel = hp.root
	(hp.root.get_child(0) as ColorRect).color = Palette.BG   # opaque
	_add_centered_label(hp.vb, "HIGH SCORES", 40, Palette.ACCENT)
	hs_status = _add_centered_label(hp.vb, "", 16, Palette.MUTED)
	var hs_scroll := ScrollContainer.new()
	hs_scroll.custom_minimum_size = Vector2(620, 430)
	hs_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hs_list = VBoxContainer.new()
	hs_list.custom_minimum_size = Vector2(620, 0)
	hs_list.add_theme_constant_override("separation", 4)
	hs_scroll.add_child(hs_list)
	hp.vb.add_child(hs_scroll)
	var hs_back := _make_button("BACK", _close_highscores, true)
	var hsrow := CenterContainer.new()
	hsrow.add_child(hs_back)
	hp.vb.add_child(hsrow)
	_default_focus[highscores_panel] = hs_back

# ----- How-to-play visual helpers -----
func _keycap(txt: String) -> Control:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	st.bg_color = Color(1, 1, 1, 0.06)
	st.set_border_width_all(1)
	st.border_color = Palette.CARD_BORDER
	st.set_corner_radius_all(6)
	st.content_margin_left = 9
	st.content_margin_right = 9
	st.content_margin_top = 3
	st.content_margin_bottom = 3
	p.add_theme_stylebox_override("panel", st)
	var l := _make_label(txt, 14, Palette.TEXT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	return p

func _control_row(caption: String, items: Array) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var c := _make_label(caption, 14, Palette.MUTED)
	c.custom_minimum_size = Vector2(150, 0)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(c)
	for it in items:
		if it == "/" or it == "·":
			var sep := _make_label(it, 14, Palette.MUTED)
			sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
			h.add_child(sep)
		else:
			h.add_child(_keycap(it))
	return h

func _demo_piece(attr: String, val: String) -> Control:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.custom_minimum_size = Vector2(150, 0)
	var st := StyleBoxFlat.new()
	st.bg_color = Palette.PIECE_BG
	st.set_border_width_all(2)
	st.border_color = Palette.ACCENT
	st.set_corner_radius_all(12)
	st.content_margin_left = 12
	st.content_margin_right = 12
	st.content_margin_top = 8
	st.content_margin_bottom = 8
	p.add_theme_stylebox_override("panel", st)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(vb)
	var a := _make_label(attr.to_upper(), 11, Palette.attr_color(attr))
	a.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	a.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(a)
	var v := _make_label(val, 15, Palette.TEXT)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(v)
	return p

func _demo_card(cname: String) -> Control:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.custom_minimum_size = Vector2(180, 0)
	var st := StyleBoxFlat.new()
	st.bg_color = Palette.CARD_BG
	st.set_border_width_all(2)
	st.border_color = Palette.hier_color("finding")
	st.set_corner_radius_all(12)
	st.content_margin_left = 12
	st.content_margin_right = 12
	st.content_margin_top = 10
	st.content_margin_bottom = 10
	p.add_theme_stylebox_override("panel", st)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(vb)
	var n := _make_label(cname, 15, Palette.TEXT)
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(n)
	var row := _make_label(tr("✓ Finding site → Lung structure"), 12, Palette.attr_color("Finding site"))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(row)
	return p

func _hier_legend_text() -> String:
	var cats := [
		["finding", "Clinical finding"],
		["procedure", "Procedure"],
		["product", "Product"],
		["situation", "Situation"],
		["substance", "Substance"],
	]
	var parts: Array = []
	for c in cats:
		var hex := Palette.hier_color(c[0]).to_html(false)
		parts.append("[color=#%s]● %s[/color]" % [hex, tr(c[1])])
	return "[color=#9AA7BD]%s[/color]\n" % tr("Card border color = concept hierarchy:") + "     ".join(parts)

func _show_only(panel: Control) -> void:
	for pnl in [start_panel, howto_panel, credits_panel, difficulty_panel, pause_panel, gameover_panel, review_panel, highscores_panel]:
		if pnl:
			pnl.visible = (pnl == panel)
	if panel != null and not _input_guard and _default_focus.has(panel):
		var btn: Button = _default_focus[panel]
		btn.call_deferred("grab_focus")

func _hide_overlays() -> void:
	_show_only(null)

func _show_menu() -> void:
	_clear_tutorial()
	state = State.START
	_show_only(start_panel)

func _show_howto() -> void:
	state = State.HOWTO
	_show_only(howto_panel)

func _show_credits() -> void:
	state = State.CREDITS
	_show_only(credits_panel)

func _show_difficulty() -> void:
	state = State.DIFFICULTY
	_show_only(difficulty_panel)

func _start_with_difficulty(d: String) -> void:
	_difficulty = d
	_set_setting("difficulty", d)
	start_round()

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
	lines.append("[color=#9AA7BD]%s[/color]\n" % (tr("%d concepts played — click an id to open it in the SNOMED browser") % items.size()))
	for c in items:
		var url := "http://snomed.info/id/%s" % str(c.id)
		lines.append("[b]%s[/b]   [url=%s][color=#6EA8FE]%s[/color][/url]" % [_bb(c.label), url, str(c.id)])
		for rel in c.relationships:
			lines.append("      [color=#9AA7BD]%s → %s[/color]" % [_bb(rel.attribute), _bb(rel.value)])
		lines.append("")
	review_rtl.text = "\n".join(lines)

func _on_review_meta(meta) -> void:
	OS.shell_open(str(meta))

# ----- high scores (Firestore) -----
func _show_highscores() -> void:
	_hs_from = state
	_scores_ctx = "view"
	state = State.HIGHSCORES
	hs_status.text = tr("Loading…")
	_clear_children(hs_list)
	_show_only(highscores_panel)
	scores.fetch_top()

func _close_highscores() -> void:
	if _hs_from == State.GAMEOVER:
		_show_gameover()
	else:
		_show_menu()

func _clear_children(n: Node) -> void:
	for c in n.get_children():
		c.queue_free()

func _populate_highscores(entries: Array) -> void:
	_clear_children(hs_list)
	if entries.is_empty():
		hs_status.text = tr("No scores yet — be the first!")
		return
	hs_status.text = ""
	for i in entries.size():
		var e = entries[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var rank := _make_label(str(i + 1), 16, Palette.MUTED)
		rank.custom_minimum_size = Vector2(38, 0)
		rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(rank)
		var nm := _make_label(str(e.name), 16, Palette.TEXT)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.clip_text = true
		row.add_child(nm)
		var sc := _make_label(str(e.score), 16, Palette.ACCENT)
		sc.custom_minimum_size = Vector2(80, 0)
		sc.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(sc)
		var d := str(e.get("date", ""))
		if d.length() >= 10:
			d = d.substr(0, 10)   # YYYY-MM-DD
		var dl := _make_label(d, 14, Palette.MUTED)
		dl.custom_minimum_size = Vector2(100, 0)
		dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(dl)
		hs_list.add_child(row)

func _on_scores_loaded(entries: Array) -> void:
	if _scores_ctx == "gameover":
		_go_entries = entries
		_go_scores_done = true
	elif _scores_ctx == "view" and state == State.HIGHSCORES:
		_populate_highscores(entries)

func _on_submit_pressed() -> void:
	if go_submit_btn.disabled:
		return
	var nm := go_name_edit.text.strip_edges()
	if nm == "":
		nm = "Anon"
	go_submit_btn.disabled = true
	go_name_edit.editable = false
	scores.submit(nm, score)

func _on_score_submitted(ok: bool) -> void:
	if ok:
		go_name_group.visible = false   # done — hide the form so it doesn't linger
		_hs_from = State.GAMEOVER
		_scores_ctx = "view"
		state = State.HIGHSCORES
		hs_status.text = tr("Loading…")
		_clear_children(hs_list)
		_show_only(highscores_panel)
		scores.fetch_top()
	else:
		go_submit_btn.disabled = false
		go_name_edit.editable = true
		go_submit_btn.text = tr("RETRY")

# ----- round lifecycle -----
func start_round() -> void:
	score = 0
	combo = 0
	best_combo = 0
	lives = START_LIVES
	_next_life_score = LIFE_FIRST
	concepts_completed = 0
	current_fall_speed = FALL_SPEED_START
	_pieces_spawned = 0
	# Tutorial: first time ever, or always on Easy.
	_tutorial_this_round = _difficulty == "easy" or not bool(_get_setting("tutorial_seen", false))
	_tutorial_correct = 0
	_clear_tutorial()
	last_pair_key = ""
	_bag.clear()
	_streak.clear()
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
	# Fade the menu music out; the countdown pulses play over silence, then the
	# game track comes in as the countdown ends.
	_music_locked = true
	_fade_music_out(0.6)
	await _run_countdown()
	if state == State.PLAYING:
		_music_locked = false
		_mcur = null   # force the game track to (re)start
		_play_music(_music_game, 0.0)   # start immediately, no fade-in
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
	_show_countdown(tr("GO"), Palette.CORRECT)
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
	_clear_tutorial()
	state = State.GAMEOVER
	current_piece = null
	sfx.sfx_game_over()
	go_stats_label.text = tr("Concepts completed: %d\nScore: %d\nBest combo: x%d") % [concepts_completed, score, maxi(best_combo, 1)]

	# Lock input while the sequence plays (also stops reflex taps from restarting).
	_input_guard = true
	for b in _go_buttons:
		b.disabled = true

	# Reset the (hidden) name-entry group for this run.
	go_name_group.visible = false
	go_name_edit.text = ""
	go_name_edit.editable = true
	go_submit_btn.disabled = false
	go_submit_btn.text = tr("SUBMIT")

	# Start fetching the leaderboard right away so we can decide (form or not)
	# BEFORE revealing the menu — no layout jump.
	_go_scores_done = false
	_go_entries = []
	if score > 0:
		_scores_ctx = "gameover"
		scores.fetch_top()
	else:
		_go_scores_done = true

	# Phase A: only "GAME OVER", centered, with a pop.
	go_reveal.visible = false
	go_title.modulate.a = 0.0
	_show_only(gameover_panel)
	await get_tree().process_frame   # let layout compute the title size
	go_title.pivot_offset = go_title.size / 2.0
	go_title.scale = Vector2(0.6, 0.6)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(go_title, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(go_title, "modulate:a", 1.0, 0.25)

	# Wait at least 2s (anti-reflex) AND until the scores are in (cap the wait).
	await _delay(2.0)
	var waited := 0.0
	while not _go_scores_done and waited < 4.0:
		await _delay(0.1)
		waited += 0.1
	if state != State.GAMEOVER:
		return   # player left somehow

	# Decide the form BEFORE revealing, so nothing shifts afterwards.
	var qualifies := score > 0 and Scores.qualifies(score, _go_entries)
	go_name_group.visible = qualifies

	# Phase B: reveal the menu (title moves up), fade it in.
	go_reveal.modulate.a = 0.0
	go_reveal.visible = true
	var t2 := create_tween()
	t2.tween_property(go_reveal, "modulate:a", 1.0, 0.3)
	await _delay(0.35)

	# Phase C: enable interaction.
	_input_guard = false
	for b in _go_buttons:
		b.disabled = false
	if state == State.GAMEOVER:
		if qualifies:
			go_name_edit.call_deferred("grab_focus")
		elif _default_focus.has(gameover_panel):
			(_default_focus[gameover_panel] as Button).grab_focus()

# ----- piece spawning (shuffle-bag over distinct unresolved pairs) -----
# Every distinct unresolved pair is drawn once before any repeats, so pieces
# spread across concepts instead of clustering on one.
func _pool_map() -> Dictionary:
	# key "attr|value" -> {attribute, value, lanes: Array[int]}
	var m := {}
	for i in active_concepts.size():
		var c = active_concepts[i]
		if c == null:
			continue
		for r in c.relationships:
			if r.completed:
				continue
			var k := "%s|%s" % [r.attribute, r.value]
			if not m.has(k):
				m[k] = {"attribute": r.attribute, "value": r.value, "lanes": []}
			m[k]["lanes"].append(i)
	return m

func _refill_bag(keys: Array) -> void:
	_bag = keys.duplicate()
	_bag.shuffle()
	# avoid repeating the just-played pair across the bag boundary
	if _bag.size() > 1 and _bag[_bag.size() - 1] == last_pair_key:
		var tmp = _bag[0]
		_bag[0] = _bag[_bag.size() - 1]
		_bag[_bag.size() - 1] = tmp

# True if choosing this pair would be the 3rd spawn in a row owned by a concept.
func _would_exceed_streak(k: String, pool: Dictionary) -> bool:
	for l in pool[k]["lanes"]:
		var c = active_concepts[l]
		if c != null and int(_streak.get(c.id, 0)) >= 2:
			return true
	return false

# Record the concepts a spawned pair belongs to; concepts not owned reset to 0.
func _register_owners(k: String, pool: Dictionary) -> void:
	var new_streak := {}
	for l in pool[k]["lanes"]:
		var c = active_concepts[l]
		if c != null:
			new_streak[c.id] = int(_streak.get(c.id, 0)) + 1
	_streak = new_streak

func spawn_next_piece() -> void:
	var pool := _pool_map()
	if pool.is_empty():
		return   # infinite mode keeps lanes full; this should not happen
	var skip := _skip_lane_next_spawn   # don't force the just-shown concept
	_skip_lane_next_spawn = -1

	var chosen := ""
	var deferred: Array = []
	var guard := 0
	while guard < 128:
		guard += 1
		if _bag.is_empty():
			_refill_bag(pool.keys())
			if _bag.is_empty():
				break
		var k = _bag.pop_back()
		if not pool.has(k):
			continue   # stale: completed, or its concept was replaced
		var lanes: Array = pool[k]["lanes"]
		if skip >= 0 and lanes.size() == 1 and lanes[0] == skip:
			deferred.append(k)
			continue
		if _would_exceed_streak(k, pool):   # avoid a 3rd piece in a row for one concept
			deferred.append(k)
			continue
		chosen = k
		break
	# keep deferred pairs in the cycle for later spawns
	for d in deferred:
		if not _bag.has(d):
			_bag.append(d)
	if chosen == "":
		chosen = deferred[0] if not deferred.is_empty() else pool.keys()[randi() % pool.size()]

	_register_owners(chosen, pool)
	last_pair_key = chosen
	var pair = pool[chosen]
	var piece := RelationshipPiece.new()
	piece.setup(pair["attribute"], pair["value"])
	piece.lane_index = 1
	piece_layer.add_child(piece)
	piece.position = Vector2(_lane_center_x(1) - PIECE_W / 2.0, PIECE_START_Y)
	current_piece = piece
	_pieces_spawned += 1
	input_locked = false
	if _tutorial_this_round:
		_begin_tutorial_step(piece)   # guide every piece until 2 correct drops

# ----- input & falling -----
func _process(delta: float) -> void:
	_crt_tick(delta)
	_update_music()
	if _version_label:
		_version_label.visible = state != State.PLAYING   # menus only, not while playing
	if _lang_btn:
		# switching is safe only in the static menus (no live piece bag to desync)
		_lang_btn.visible = state == State.START or state == State.HOWTO or state == State.CREDITS or state == State.DIFFICULTY
	if state != State.PLAYING or current_piece == null or input_locked:
		return
	if _tutorial_line != null:
		_tutorial_pulse_t = fmod(_tutorial_pulse_t + delta / 0.9, 1.0)   # ~0.9s piece→card
		_update_tutorial_line()   # keep the guide anchored to the moving piece
	if _tutorial_hold:
		return                    # frozen until the first input
	var base := current_fall_speed
	if _pieces_spawned <= INTRO_PIECES or _tutorial_this_round:
		base = minf(base, FALL_SPEED_INTRO)   # slow for onboarding / while the tutorial guides
	var speed := base * _fall_mult()          # difficulty scales the whole curve
	if Input.is_action_pressed("af_soft"):
		speed = maxf(speed, FALL_SPEED_SOFT)
	current_piece.position.y += speed * delta
	var target := _lane_drop_y(current_piece.lane_index)
	if current_piece.position.y >= target:
		current_piece.position.y = target
		resolve_drop(current_piece.lane_index)

# Runs before the GUI, so it sees button clicks too. On the first user gesture,
# start the active music ONLY if it isn't already playing, so browsers unlock
# audio without restarting a track that's already going (the web AudioContext is
# resumed separately by web/shell.html).
func _input(event: InputEvent) -> void:
	if _audio_kicked:
		return
	if event.is_pressed():
		_audio_kicked = true
		if not _mplayers.is_empty() and not _music_locked and not _mplayers[_mactive].playing:
			_mplayers[_mactive].play()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("af_mute"):
		_toggle_music()
		return
	if _counting or _input_guard:
		return
	# Menu-like states rely on focusable buttons (keyboard + gamepad via ui_* actions);
	# here we only handle in-game actions and cancel/back.
	match state:
		State.HOWTO:
			if event.is_action_pressed("ui_cancel") or event.is_action_pressed("af_pause"):
				_show_menu()
		State.CREDITS:
			if event.is_action_pressed("ui_cancel") or event.is_action_pressed("af_pause"):
				_show_menu()
		State.DIFFICULTY:
			if event.is_action_pressed("ui_cancel") or event.is_action_pressed("af_pause"):
				_show_menu()
		State.PLAYING:
			if _tutorial_hold and (event.is_action_pressed("af_left") or event.is_action_pressed("af_right") \
					or event.is_action_pressed("af_soft") or event.is_action_pressed("af_hard")):
				_end_tutorial_hold()   # a real move/drop resumes the fall; the action still applies
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
		State.HIGHSCORES:
			if event.is_action_pressed("ui_cancel") or event.is_action_pressed("af_pause"):
				_close_highscores()

func _toggle_pause() -> void:
	if state == State.PLAYING:
		state = State.PAUSED
		if _tutorial_box:
			_tutorial_box.visible = false   # don't let the tutorial prompt sit over the pause menu
		_show_only(pause_panel)
	elif state == State.PAUSED:
		state = State.PLAYING
		if _tutorial_hold and _tutorial_box:
			_tutorial_box.visible = true    # still mid-tutorial → restore the prompt
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
	if _tutorial_hold:
		_end_tutorial_hold()   # first click also resumes the tutorial hold
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

	var was_tutorial := _tutorial_this_round
	if was_tutorial:
		_clear_tutorial()   # the guide line disappears when the piece lands

	var concept = active_concepts[lane]
	var correct := false
	if concept != null:
		var idx := _find_unresolved_match(concept, piece.attribute, piece.value)
		if idx >= 0:
			concept.relationships[idx].completed = true
			correct = true
	if was_tutorial and correct:
		_tutorial_correct += 1

	if correct:
		combo = mini(combo + 1, MAX_COMBO)
		best_combo = maxi(best_combo, combo)
		var gained := roundi(SCORE_BASE * combo * _speed_factor())
		score += gained
		_update_hud()
		_check_extra_life()
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
		if not was_tutorial:   # mistakes are free during the guided tutorial
			lives -= 1
		combo = 0
		_update_hud()
		lane_cards[lane].flash_wrong()
		if not was_tutorial:
			_show_message(tr("Not part of this concept"), Palette.INCORRECT)
		_highlight_valid_targets(piece)
		_crt_error_burst()
		sfx.sfx_wrong()
		piece.animate_fail()
		if lives <= 0:
			await _delay(0.5)
			end_game()
			return
		await _delay(0.5)

	# Encouraging feedback during the guided tutorial.
	if was_tutorial:
		if not correct:
			_show_message(tr("Not quite — the right card is highlighted"), Palette.INCORRECT, 2.2)
		elif _tutorial_correct < 2:
			_show_message(tr("Nice — that's how it works!"), Palette.CORRECT)   # first correct

	# End the tutorial after two correct drops (mistakes keep guiding, cost nothing).
	if was_tutorial and _tutorial_correct >= 2:
		_tutorial_this_round = false
		_set_setting("tutorial_seen", true)
		_show_message(tr("Good! Now it's your turn…"), Palette.ACCENT, 2.0)   # immediate, alongside the score popups
		await _delay(0.6)

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
	var bonus := roundi(SCORE_CONCEPT * _speed_factor())
	score += bonus
	concepts_completed += 1
	_increase_speed()
	_update_hud()
	sfx.sfx_concept_complete()
	_show_message(tr("CONCEPT COMPLETE  +%d") % bonus, Palette.ACCENT)
	_check_extra_life()   # its own center popup, independent of the concept message
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

# Grows from 1.0 as the fall speed rises; makes scores vary and not stay round.
func _speed_factor() -> float:
	return current_fall_speed * _fall_mult() / FALL_SPEED_START

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

func _pulse_life() -> void:
	lives_val.pivot_offset = lives_val.size / 2.0
	lives_val.scale = Vector2(1.5, 1.5)
	var t := create_tween()
	t.tween_property(lives_val, "scale", Vector2.ONE, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

# Award bonus lives when the score crosses the milestones (2500, 7500, 15000, ...).
# The loop handles a single gain that crosses several thresholds at once. Past the
# cap it keeps advancing the threshold silently (no award, no message spam).
func _check_extra_life() -> void:
	while score >= _next_life_score:
		var reached := _next_life_score
		_next_life_score = LIFE_INTERVAL if reached == LIFE_FIRST else reached + LIFE_INTERVAL
		if lives < MAX_LIVES:
			lives += 1
			_update_hud()
			_pulse_life()
			_extra_life_popup()
			sfx.sfx_extra_life()

# Big center-of-well toast for a bonus life: a heart that pops in with a pulse,
# holds, then drifts up and fades. More visible than the small status message.
func _extra_life_popup() -> void:
	var l := _make_label(tr("♥  EXTRA LIFE"), 40, Palette.INCORRECT)   # red, matching the LIVES hearts
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size = Vector2(WELL_RIGHT - WELL_LEFT, 60)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	piece_layer.add_child(l)
	l.position = Vector2(WELL_LEFT, 262.0)
	l.pivot_offset = l.size / 2.0
	l.scale = Vector2(0.6, 0.6)
	l.modulate.a = 0.0
	# Scale: pop in with overshoot, then settle — the pulse.
	var ts := create_tween()
	ts.tween_property(l, "scale", Vector2(1.18, 1.18), 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	ts.tween_property(l, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_SINE)
	# Alpha + drift: fade in, hold, then rise and fade out, then free.
	var t := create_tween()
	t.tween_property(l, "modulate:a", 1.0, 0.15)
	t.tween_interval(0.7)
	t.set_parallel(true)
	t.tween_property(l, "modulate:a", 0.0, 0.5).set_ease(Tween.EASE_IN)
	t.tween_property(l, "position:y", l.position.y - 30.0, 0.5)
	t.chain().tween_callback(l.queue_free)

# ----- guided tutorial (first two pieces) -----
# Which lane the guide points to for a piece (a concept it validly belongs to).
func _first_valid_lane(piece: RelationshipPiece) -> int:
	for i in active_concepts.size():
		var c = active_concepts[i]
		if c != null and _find_unresolved_match(c, piece.attribute, piece.value) >= 0:
			return i
	return -1

# Let the piece fall a moment (so the motion is visible), then freeze it and draw
# the guide to a valid target concept.
func _begin_tutorial_step(piece: RelationshipPiece) -> void:
	await _delay(0.7)
	if state != State.PLAYING or current_piece != piece:
		return
	var lane := _first_valid_lane(piece)
	if lane < 0:
		return
	_tutorial_target_lane = lane
	_tutorial_hold = true
	lane_cards[lane].set_tutorial_glow(true)
	_draw_tutorial_line()
	var cname := str(active_concepts[lane].label) if active_concepts[lane] != null else ""
	_show_tutorial_box(cname)

func _end_tutorial_hold() -> void:
	_tutorial_hold = false
	if _tutorial_box:
		_tutorial_box.visible = false   # hide the prompt; the line stays until landing

func _clear_tutorial() -> void:
	_tutorial_hold = false
	if _tutorial_target_lane >= 0 and _tutorial_target_lane < lane_cards.size():
		lane_cards[_tutorial_target_lane].set_tutorial_glow(false)
	_tutorial_target_lane = -1
	if _tutorial_line:
		_tutorial_line.queue_free()
		_tutorial_line = null
	if _tutorial_pulse:
		_tutorial_pulse.queue_free()
		_tutorial_pulse = null
	if _tutorial_box:
		_tutorial_box.queue_free()
		_tutorial_box = null

func _draw_tutorial_line() -> void:
	if _tutorial_line == null:
		_tutorial_line = Line2D.new()
		_tutorial_line.width = 3.0
		_tutorial_line.default_color = Color(Palette.ACCENT.r, Palette.ACCENT.g, Palette.ACCENT.b, 0.9)
		# No z_index bump: stay within piece_layer so menu overlays (pause) draw
		# over and dim the line like everything else.
		piece_layer.add_child(_tutorial_line)
	if _tutorial_pulse == null:
		_tutorial_pulse = Polygon2D.new()
		_tutorial_pulse.polygon = _circle_points(6.0, 16)
		_tutorial_pulse.color = Color(Palette.ACCENT.r, Palette.ACCENT.g, Palette.ACCENT.b, 1.0)
		piece_layer.add_child(_tutorial_pulse)
		_tutorial_pulse_t = 0.0
	_update_tutorial_line()

func _circle_points(r: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts

# Position along the elbow polyline at normalized t (0 = piece, 1 = card).
func _point_along(pts: PackedVector2Array, t: float) -> Vector2:
	if pts.size() < 2:
		return pts[0] if pts.size() == 1 else Vector2.ZERO
	var seglens: PackedFloat32Array = []
	var total := 0.0
	for i in pts.size() - 1:
		var l := pts[i].distance_to(pts[i + 1])
		seglens.append(l)
		total += l
	if total <= 0.0:
		return pts[0]
	var d := clampf(t, 0.0, 1.0) * total
	for i in pts.size() - 1:
		var sl := seglens[i]
		if d <= sl or i == pts.size() - 2:
			var f: float = 0.0 if sl == 0.0 else d / sl
			return pts[i].lerp(pts[i + 1], clampf(f, 0.0, 1.0))
		d -= sl
	return pts[pts.size() - 1]

# Right-angle "elbow" connector from the piece's bottom to the target card's top.
func _update_tutorial_line() -> void:
	if _tutorial_line == null or current_piece == null or _tutorial_target_lane < 0:
		return
	var start := Vector2(current_piece.position.x + PIECE_W / 2.0, current_piece.position.y + current_piece.size.y)
	var endp := Vector2(_lane_center_x(_tutorial_target_lane), lane_cards[_tutorial_target_lane].get_top_y())
	var mid_y := (start.y + endp.y) / 2.0
	var pts := PackedVector2Array([start, Vector2(start.x, mid_y), Vector2(endp.x, mid_y), endp])
	_tutorial_line.points = pts
	if _tutorial_pulse:
		var t := _tutorial_pulse_t
		_tutorial_pulse.position = _point_along(pts, t)
		# fade in as it leaves the piece, out as it reaches the card
		var a := 1.0
		if t < 0.15:
			a = t / 0.15
		elif t > 0.85:
			a = (1.0 - t) / 0.15
		_tutorial_pulse.modulate.a = clampf(a, 0.0, 1.0)

func _show_tutorial_box(concept_name: String) -> void:
	if _tutorial_box:
		_tutorial_box.queue_free()
	_tutorial_box = PanelContainer.new()
	_tutorial_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tutorial_box.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.043, 0.063, 0.125, 0.94)
	st.set_border_width_all(1)
	st.border_color = Palette.ACCENT
	st.set_corner_radius_all(10)
	st.content_margin_left = 18
	st.content_margin_right = 18
	st.content_margin_top = 10
	st.content_margin_bottom = 10
	_tutorial_box.add_theme_stylebox_override("panel", st)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tutorial_box.add_child(vb)
	var l1 := _make_label(tr("This attribute is part of the '%s' definition") % concept_name, 18, Palette.TEXT)
	l1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(l1)
	var l2 := _make_label(tr("Move it over the card and drop — or click the card"), 14, Palette.MUTED)
	l2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(l2)
	add_child(_tutorial_box)
	_tutorial_box.reset_size()
	_tutorial_box.position = Vector2(SCREEN.x / 2.0 - _tutorial_box.size.x / 2.0, 20.0)

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

func _show_message(text: String, color: Color = Palette.TEXT, hold: float = 0.55) -> void:
	message_label.text = text
	message_label.add_theme_color_override("font_color", color)
	message_label.modulate.a = 1.0
	var t := create_tween()
	t.tween_interval(hold)
	t.tween_property(message_label, "modulate:a", 0.0, 0.4)

func _delay(t: float) -> void:
	await get_tree().create_timer(t).timeout
