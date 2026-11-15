class_name ClientPostureState
extends RefCounted
## Non-authoritative client mirror of player postures (P2-T11, docs/09
## §14.26): who stands, who lies prone, who lies asleep. A posture is a fact
## anybody can see, so it is kept for every known player. It has no send /
## RPC API. Every incoming DTO is validated before mutation. A player the
## mirror has no row for stands.

signal changed
## Emitted on changes only.
signal posture_changed(player_id: String, posture: PlayerPosture.Kind)

## Join fragment format (same value as PostureNetModule).
const SCHEMA_VERSION: int = 1
const KEY_PLAYER_ID: String = "player_id"
const KEY_POSTURE: String = "posture"
## Protocol limit: rows in one message or join fragment.
const MAX_ROWS: int = 256

var local_player_id: String = ""
## player_id -> PlayerPosture.Kind. Observation state, never authority.
var posture_by_player: Dictionary[String, int] = {}

var _settings: PostureNetSettings


func _init(settings: PostureNetSettings) -> void:
	_settings = settings


## Applies the module join fragment atomically: {schema_version, players:
## [{player_id, posture}]}. An invalid fragment is ignored (everybody stands).
func apply_join(player_id: String, fragment: Dictionary) -> bool:
	local_player_id = player_id
	posture_by_player = {}
	if not _has_exact_keys(fragment, ["schema_version", "players"]):
		return _reject("join_fragment")
	if typeof(fragment["schema_version"]) != TYPE_INT or int(fragment["schema_version"]) != SCHEMA_VERSION:
		return _reject("join_schema")
	if typeof(fragment["players"]) != TYPE_ARRAY or (fragment["players"] as Array).size() > MAX_ROWS:
		return _reject("join_players")
	var postures: Dictionary[String, int] = {}
	for value: Variant in fragment["players"] as Array:
		if not is_valid_row(value) or postures.has(str((value as Dictionary)[KEY_PLAYER_ID])):
			return _reject("join_player")
		var row: Dictionary = value
		postures[str(row[KEY_PLAYER_ID])] = PlayerPosture.from_name(str(row[KEY_POSTURE]))
	posture_by_player = postures
	changed.emit()
	for row_id: String in posture_by_player:
		posture_changed.emit(row_id, posture_by_player[row_id] as PlayerPosture.Kind)
	return true


## Applies a batch of rows; each row is validated on its own. Returns the
## number accepted.
func apply_rows(values: Array) -> int:
	if values.size() > MAX_ROWS:
		_reject("rows_size")
		return 0
	var accepted: int = 0
	for value: Variant in values:
		if not is_valid_row(value):
			_reject("row")
			continue
		var row: Dictionary = value
		_set_posture(str(row[KEY_PLAYER_ID]), PlayerPosture.from_name(str(row[KEY_POSTURE])) as PlayerPosture.Kind)
		accepted += 1
	return accepted


func remove_player(player_id: String) -> void:
	if posture_by_player.erase(player_id):
		changed.emit()


## Posture of `player_id` (the local player or anybody else). Unknown
## players stand.
func posture_of(player_id: String) -> PlayerPosture.Kind:
	return posture_by_player.get(player_id, PlayerPosture.Kind.STANDING) as PlayerPosture.Kind


func is_prone(player_id: String) -> bool:
	return posture_of(player_id) == PlayerPosture.Kind.PRONE


## True when `value` is a posture row as the server sends it:
## {player_id: String, posture: one of PlayerPosture.NAMES}, nothing else.
func is_valid_row(value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		return false
	var row: Dictionary = value
	if not _has_exact_keys(row, [KEY_PLAYER_ID, KEY_POSTURE]):
		return false
	if typeof(row[KEY_PLAYER_ID]) != TYPE_STRING or typeof(row[KEY_POSTURE]) != TYPE_STRING:
		return false
	var player_id: String = row[KEY_PLAYER_ID]
	if player_id.is_empty() or player_id.length() > _settings.max_player_id_length:
		return false
	return PlayerPosture.from_name(str(row[KEY_POSTURE])) != PlayerPosture.INVALID


func _set_posture(player_id: String, posture: PlayerPosture.Kind) -> void:
	var previous: int = posture_by_player.get(player_id, PlayerPosture.Kind.STANDING)
	posture_by_player[player_id] = posture
	if previous != posture:
		posture_changed.emit(player_id, posture)
		changed.emit()


func _has_exact_keys(data: Dictionary, expected: Array) -> bool:
	if data.size() != expected.size():
		return false
	for key: Variant in data.keys():
		if typeof(key) != TYPE_STRING or not expected.has(str(key)):
			return false
	return true


func _reject(kind: String) -> bool:
	GameLogger.warning("posture_net", "invalid client posture payload ignored", {"kind": kind, "operation": "apply_payload"})
	return false
