class_name Scores
extends Node

# High-score client for Firebase Firestore via its REST API (works on web).
# Requires a Firestore rule allowing read + create on the COLLECTION.

const PROJECT_ID := "snoguess-e4d1c"
const API_KEY := "AIzaSyAFjiIuMBA1IpTrw__WdkQiK5PKht4_go8"   # public Firebase web key
const COLLECTION := "attribute-fall"
const LIMIT := 20

signal loaded(entries: Array)   # Array of {name: String, score: int}
signal submitted(ok: bool)

var _get: HTTPRequest
var _post: HTTPRequest

func _ready() -> void:
	_get = HTTPRequest.new()
	# On web the browser already decompresses responses; letting Godot also try
	# to gunzip corrupts the body. Disable it so JSON parses correctly.
	_get.accept_gzip = false
	add_child(_get)
	_get.request_completed.connect(_on_get_done)
	_post = HTTPRequest.new()
	_post.accept_gzip = false
	add_child(_post)
	_post.request_completed.connect(_on_post_done)

func fetch_top() -> void:
	var url := "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents:runQuery?key=%s" % [PROJECT_ID, API_KEY]
	var q := {
		"structuredQuery": {
			"from": [{"collectionId": COLLECTION}],
			"orderBy": [{"field": {"fieldPath": "score"}, "direction": "DESCENDING"}],
			"limit": LIMIT,
		}
	}
	var err := _get.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(q))
	if err != OK:
		loaded.emit([])

func _on_get_done(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var entries: Array = []
	if code == 200:
		var data = JSON.parse_string(body.get_string_from_utf8())
		if typeof(data) == TYPE_ARRAY:
			for row in data:
				if typeof(row) == TYPE_DICTIONARY and row.has("document"):
					var f = row["document"].get("fields", {})
					var nm: String = f.get("message", {}).get("stringValue", "?")
					var sc := int(str(f.get("score", {}).get("integerValue", "0")))
					var df = f.get("date", {})
					var dt: String = df.get("timestampValue", df.get("stringValue", ""))
					entries.append({"name": nm, "score": sc, "date": dt})
	loaded.emit(entries)

func submit(player_name: String, score: int) -> void:
	var url := "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s?key=%s" % [PROJECT_ID, COLLECTION, API_KEY]
	var iso := Time.get_datetime_string_from_system(true) + "Z"
	var doc := {
		"fields": {
			"message": {"stringValue": player_name},
			"mode": {"stringValue": "endless"},
			"score": {"integerValue": str(score)},
			"date": {"timestampValue": iso},
		}
	}
	var err := _post.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(doc))
	if err != OK:
		submitted.emit(false)

func _on_post_done(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	submitted.emit(code == 200 or code == 201)

# Does `score` make the top LIMIT given current (desc-sorted) entries?
static func qualifies(score: int, entries: Array) -> bool:
	if score <= 0:
		return false
	if entries.size() < LIMIT:
		return true
	return score > int(entries[entries.size() - 1].score)
