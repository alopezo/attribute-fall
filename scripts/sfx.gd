class_name Sfx
extends Node

# Lightweight procedural sound effects generated at runtime (no external assets).
# The game must remain fully readable with sound disabled (design doc section 12).

var _players: Array[AudioStreamPlayer] = []
var _next: int = 0
const VOICES := 4

func _ready() -> void:
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)

func _tone(freq: float, dur: float, vol: float = 0.4) -> AudioStreamWAV:
	var rate := 22050
	var count := int(rate * dur)
	var data := PackedByteArray()
	data.resize(count * 2)
	for i in count:
		var t := float(i) / rate
		var env := 1.0 - float(i) / count       # simple linear decay
		var s := sin(TAU * freq * t) * vol * env
		var v := int(clamp(s, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav

func _play(freq: float, dur: float, vol: float = 0.4) -> void:
	var p := _players[_next]
	_next = (_next + 1) % VOICES
	p.stream = _tone(freq, dur, vol)
	p.play()

func sfx_move() -> void:
	_play(430.0, 0.05, 0.18)

func sfx_correct() -> void:
	_play(660.0, 0.10, 0.30)

func sfx_wrong() -> void:
	_play(150.0, 0.20, 0.40)

func sfx_concept_complete() -> void:
	_play(880.0, 0.18, 0.35)

func sfx_game_over() -> void:
	_play(110.0, 0.55, 0.40)
