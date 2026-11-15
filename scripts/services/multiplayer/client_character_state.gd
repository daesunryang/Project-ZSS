class_name ClientCharacterState
extends RefCounted
## Non-authoritative client mirror of what the server disclosed about
## characters (docs/00 ADR-015, docs/09 §14.24): the name and appearance of
## every player in the world, and whether the local player may create a
## character now. It has no send/RPC API. Every incoming DTO is validated
## before anything changes.
##
## Presentation reads: has_character(), character_name(), appearance(),
## character_generation(), player_ids(), can_create_character(),
## creation_block_reason(); and listens to the signals below.

signal changed
## A character of `player_id` is known now or its name / appearance changed.
signal character_changed(player_id: String)
## `player_id` left; its character is no longer known.
signal character_removed(player_id: String)
## Whether the local player may create a character changed. `reason` is ""
## exactly when it may.
signal creation_state_changed(can_create: bool, reason: String)

## Join fragment format (same value as CharacterNetModule).
const SCHEMA_VERSION: int = 1
const KEY_PLAYER_ID: String = "player_id"
const KEY_NAME: String = "name"
const KEY_APPEARANCE: String = "appearance"
const KEY_GENERATION: String = "character_generation"
const KEY_CAN_CREATE: String = "can_create"
const KEY_REASON: String = "reason"
const ROW_KEYS: PackedStringArray = [KEY_PLAYER_ID, KEY_NAME, KEY_APPEARANCE, KEY_GENERATION]
## creation_block_reason() before the server said anything.
const REASON_NOT_JOINED: String = "not_joined"
## Value of character_generation() when the server did not tell.
const GENERATION_NOT_SHARED: int = 0
## Protocol limits (the same numbers as CharacterNetModule).
const MAX_ROWS_PER_MESSAGE: int = 256
const REASON_MAX_LENGTH: int = 64
const LAST_C0_CONTROL: int = 0x1F
const FIRST_DEL_OR_C1_CONTROL: int = 0x7F
const LAST_C1_CONTROL: int = 0x9F

var local_player_id: String = ""
## Payloads (whole messages and single rows) that failed validation.
var rejected_payload_count: int = 0

var _settings: CharacterSettings
var _catalog: AppearanceCatalog
## player_id -> {"name": String, "appearance": Dictionary, "character_generation": int}
var _characters: Dictionary[String, Dictionary] = {}
var _can_create: bool = false
var _creation_reason: String = REASON_NOT_JOINED


func _init(settings: CharacterSettings, catalog: AppearanceCatalog) -> void:
	_settings = settings
	_catalog = catalog


# ------------------------------------------------------------ read surface

func has_character(player_id: String) -> bool:
	return _characters.has(player_id)


## Name of the character of `player_id` ("" when unknown).
func character_name(player_id: String) -> String:
	return str(_characters.get(player_id, {}).get(KEY_NAME, ""))


## A copy of the appearance selection {slot_id: option_id} ({} when unknown).
func appearance(player_id: String) -> Dictionary:
	var selection: Dictionary = _characters.get(player_id, {}).get(KEY_APPEARANCE, {})
	return selection.duplicate()


## Which character of that player this is (1 = the first one), or
## GENERATION_NOT_SHARED (0) when unknown or not disclosed. The server always
## tells a player its own; others only by configuration (docs/00 ADR-009).
func character_generation(player_id: String) -> int:
	return int(_characters.get(player_id, {}).get(KEY_GENERATION, GENERATION_NOT_SHARED))


## Players whose character is known, sorted.
func player_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_characters.keys())
	ids.sort()
	return ids


## True when the server said the local player may create a character now
## (it has none yet, or its character is dead and the delay has passed).
func can_create_character() -> bool:
	return _can_create


## Why not ("" when it may): "character_alive", "respawn_wait", or
## "not_joined" before the join.
func creation_block_reason() -> String:
	return _creation_reason


# ------------------------------------------------------------ applying server data

## Applies the module join fragment atomically. Invalid fragments are
## ignored (the earlier state is kept).
func apply_join(player_id: String, fragment: Dictionary) -> bool:
	if not _valid_player_id(player_id) or not _has_exact_keys(fragment, ["schema_version", "characters", "self"]):
		return _reject("join_fragment")
	if typeof(fragment["schema_version"]) != TYPE_INT or int(fragment["schema_version"]) != SCHEMA_VERSION:
		return _reject("join_schema")
	if typeof(fragment["characters"]) != TYPE_ARRAY or typeof(fragment["self"]) != TYPE_DICTIONARY:
		return _reject("join_types")
	var own: Dictionary = fragment["self"]
	if not _has_exact_keys(own, [KEY_CAN_CREATE, KEY_REASON]) or not _valid_creation_state(own[KEY_CAN_CREATE], own[KEY_REASON]):
		return _reject("join_self")
	var rows: Array = fragment["characters"]
	if rows.size() > MAX_ROWS_PER_MESSAGE:
		return _reject("join_rows")
	var characters: Dictionary[String, Dictionary] = {}
	for value: Variant in rows:
		if not _valid_row(value) or characters.has(str((value as Dictionary)[KEY_PLAYER_ID])):
			return _reject("join_row")
		characters[str((value as Dictionary)[KEY_PLAYER_ID])] = _stored(value as Dictionary)
	local_player_id = player_id
	_characters = characters
	for known_id: String in _characters:
		character_changed.emit(known_id)
	_set_creation_state(bool(own[KEY_CAN_CREATE]), str(own[KEY_REASON]), true)
	changed.emit()
	return true


## Applies character rows (a new character, or a changed one). Each row is
## validated on its own; invalid rows are dropped. Returns the number
## accepted. A message with too many rows is dropped whole.
func apply_rows(rows: Array) -> int:
	if rows.size() > MAX_ROWS_PER_MESSAGE:
		_reject("rows_size")
		return 0
	var accepted: int = 0
	for value: Variant in rows:
		if not _valid_row(value):
			_reject("row")
			continue
		var row: Dictionary = value
		var player_id: String = str(row[KEY_PLAYER_ID])
		var stored: Dictionary = _stored(row)
		accepted += 1
		if _characters.get(player_id, {}) == stored:
			continue
		_characters[player_id] = stored
		character_changed.emit(player_id)
		changed.emit()
	return accepted


## Applies the local player's creation state. Arguments are Variant: they
## come straight from the RPC.
func apply_creation_state(can_create: Variant, reason: Variant) -> bool:
	if not _valid_creation_state(can_create, reason):
		return _reject("creation_state")
	_set_creation_state(bool(can_create), str(reason), false)
	return true


## Forgets the character of a player that left.
func remove_player(player_id: String) -> void:
	if _characters.erase(player_id):
		character_removed.emit(player_id)
		changed.emit()


# ------------------------------------------------------------ internals

func _set_creation_state(can_create: bool, reason: String, force: bool) -> void:
	if not force and can_create == _can_create and reason == _creation_reason:
		return
	_can_create = can_create
	_creation_reason = reason
	creation_state_changed.emit(can_create, reason)
	changed.emit()


func _stored(row: Dictionary) -> Dictionary:
	return {
		KEY_NAME: str(row[KEY_NAME]),
		KEY_APPEARANCE: (row[KEY_APPEARANCE] as Dictionary).duplicate(),
		KEY_GENERATION: int(row[KEY_GENERATION]),
	}


## "" exactly when the player may create.
func _valid_creation_state(can_create: Variant, reason: Variant) -> bool:
	if typeof(can_create) != TYPE_BOOL or typeof(reason) != TYPE_STRING:
		return false
	return (reason as String).length() <= REASON_MAX_LENGTH and bool(can_create) == (reason as String).is_empty()


## A row as the server sends it: exactly the four keys, a usable player id,
## a displayable name, a complete selection of this client's appearance
## data and a generation >= 0. The name rules themselves (allowed scripts,
## length range) are the server's: a client only refuses what it could not
## show safely.
func _valid_row(value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY or not _has_exact_keys(value as Dictionary, ROW_KEYS):
		return false
	var row: Dictionary = value
	if typeof(row[KEY_PLAYER_ID]) != TYPE_STRING or not _valid_player_id(str(row[KEY_PLAYER_ID])):
		return false
	if typeof(row[KEY_NAME]) != TYPE_STRING or not _displayable_name(row[KEY_NAME] as String):
		return false
	if not _catalog.is_complete_selection(row[KEY_APPEARANCE]):
		return false
	return typeof(row[KEY_GENERATION]) == TYPE_INT and int(row[KEY_GENERATION]) >= GENERATION_NOT_SHARED


func _displayable_name(character_name: String) -> bool:
	if character_name.is_empty() or character_name.length() > CharacterNameRules.HARD_MAX_LENGTH:
		return false
	if CharacterNameRules.sanitize(character_name) != character_name:
		return false
	for index: int in character_name.length():
		var codepoint: int = character_name.unicode_at(index)
		if codepoint <= LAST_C0_CONTROL or (codepoint >= FIRST_DEL_OR_C1_CONTROL and codepoint <= LAST_C1_CONTROL):
			return false
	return true


func _valid_player_id(player_id: String) -> bool:
	return not player_id.is_empty() and player_id.length() <= _settings.max_player_id_length


func _has_exact_keys(data: Dictionary, expected: Variant) -> bool:
	var expected_keys: Array = Array(expected)
	if data.size() != expected_keys.size():
		return false
	for key: Variant in data.keys():
		if typeof(key) != TYPE_STRING or not expected_keys.has(str(key)):
			return false
	return true


func _reject(kind: String) -> bool:
	rejected_payload_count += 1
	GameLogger.warning("character_net", "invalid client character payload ignored", {"kind": kind, "operation": "apply_payload"})
	return false
