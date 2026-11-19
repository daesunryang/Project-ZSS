class_name NpcDebugClientState
extends RefCounted
## Client mirror of the single subscribed private NPC debug snapshot.

signal changed

const SCHEMA_VERSION: int = 1
const KEY_SCHEMA_VERSION: String = "schema_version"
const KEY_SERVER_ENABLED: String = "server_enabled"
const KEY_ALLOWED: String = "allowed"
const KEY_REASON: String = "reason"
const KEY_SUBSCRIBED_NPC_ID: String = "subscribed_npc_id"
const KEY_UPDATE_RATE_HZ: String = "update_rate_hz"

var server_enabled: bool = false
var allowed: bool = false
var reason: String = ""
var subscribed_npc_id: String = ""
var update_rate_hz: float = 0.0
var snapshot: Dictionary = {}
var received_snapshot_count: int = 0
var rejected_payload_count: int = 0


func apply_join(fragment: Dictionary) -> void:
	if fragment.is_empty():
		server_enabled = false
		allowed = false
		reason = NpcDebugNetModule.REASON_SERVER_DISABLED
		subscribed_npc_id = ""
		snapshot = {}
		changed.emit()
		return
	if not _valid_status(fragment):
		rejected_payload_count += 1
		return
	_apply_status(fragment)
	snapshot = {}
	changed.emit()


func apply_status(payload: Dictionary) -> void:
	if not _valid_status(payload):
		rejected_payload_count += 1
		return
	_apply_status(payload)
	if subscribed_npc_id.is_empty():
		snapshot = {}
	changed.emit()


func apply_snapshot(npc_id_value: Variant, found_value: Variant, payload_value: Variant) -> void:
	if typeof(npc_id_value) != TYPE_STRING or not NpcState.is_valid_npc_id(str(npc_id_value)) or typeof(found_value) != TYPE_BOOL or typeof(payload_value) != TYPE_DICTIONARY:
		rejected_payload_count += 1
		return
	var payload: Dictionary = payload_value
	if int(payload.get(KEY_SCHEMA_VERSION, -1)) != NpcDebugQuery.SCHEMA_VERSION or payload.get("found", null) != found_value or str(payload.get("npc_id", "")) != str(npc_id_value):
		rejected_payload_count += 1
		return
	if bool(found_value) and not _valid_found_snapshot(payload):
		rejected_payload_count += 1
		return
	subscribed_npc_id = str(npc_id_value)
	snapshot = payload.duplicate(true)
	received_snapshot_count += 1
	changed.emit()


func _apply_status(payload: Dictionary) -> void:
	server_enabled = bool(payload[KEY_SERVER_ENABLED])
	allowed = bool(payload[KEY_ALLOWED])
	reason = str(payload[KEY_REASON])
	subscribed_npc_id = str(payload[KEY_SUBSCRIBED_NPC_ID])
	update_rate_hz = float(payload[KEY_UPDATE_RATE_HZ])


static func _valid_status(payload: Dictionary) -> bool:
	if int(payload.get(KEY_SCHEMA_VERSION, -1)) != SCHEMA_VERSION:
		return false
	if typeof(payload.get(KEY_SERVER_ENABLED, null)) != TYPE_BOOL or typeof(payload.get(KEY_ALLOWED, null)) != TYPE_BOOL:
		return false
	if typeof(payload.get(KEY_REASON, null)) != TYPE_STRING or typeof(payload.get(KEY_SUBSCRIBED_NPC_ID, null)) != TYPE_STRING:
		return false
	var subscribed: String = str(payload[KEY_SUBSCRIBED_NPC_ID])
	if not subscribed.is_empty() and not NpcState.is_valid_npc_id(subscribed):
		return false
	var rate: Variant = payload.get(KEY_UPDATE_RATE_HZ, null)
	return (typeof(rate) == TYPE_FLOAT or typeof(rate) == TYPE_INT) and is_finite(float(rate)) and float(rate) >= 0.0


static func _valid_found_snapshot(payload: Dictionary) -> bool:
	for key: String in ["name", "definition_id", "state", "goal", "current_action", "lod"]:
		if typeof(payload.get(key, null)) != TYPE_STRING:
			return false
	for key: String in ["action", "needs", "emotions", "failure", "schedule", "seed"]:
		if typeof(payload.get(key, null)) != TYPE_DICTIONARY:
			return false
	for key: String in ["candidates", "relationships", "memories", "path"]:
		if typeof(payload.get(key, null)) != TYPE_ARRAY:
			return false
	return true
