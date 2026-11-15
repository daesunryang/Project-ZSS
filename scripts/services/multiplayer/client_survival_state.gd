class_name ClientSurvivalState
extends RefCounted
## Non-authoritative client mirror of survival data disclosed by the server.
## It has no send/RPC API. Every incoming DTO is validated before mutation.

signal changed
signal own_vitals_changed
signal player_alive_changed(player_id: String, alive: bool)
signal event_received(event: Dictionary)
signal player_respawned(player_id: String, position: Vector3)

const SCHEMA_VERSION: int = 1
const SCOPE_OWNER: String = "owner"
const SCOPE_PUBLIC: String = "public"

var local_player_id: String = ""
## player_id -> bool. This is observation state, never authority.
var alive_by_player: Dictionary[String, bool] = {}

var _own_vitals: Dictionary = {}
var _recent_events: Array[Dictionary] = []
var _respawn_positions: Dictionary[String, Vector3] = {}
var _net_settings: SurvivalNetSettings
var _survival_settings: SurvivalSettings


func _init(net_settings: SurvivalNetSettings, survival_settings: SurvivalSettings) -> void:
	_net_settings = net_settings
	_survival_settings = survival_settings


## Applies the module join fragment atomically. Invalid fragments are ignored.
func apply_join(player_id: String, fragment: Dictionary) -> bool:
	if not _valid_player_id(player_id) or not _has_exact_keys(fragment, ["schema_version", "self", "players"]):
		return _reject("join_fragment")
	if typeof(fragment["schema_version"]) != TYPE_INT or int(fragment["schema_version"]) != SCHEMA_VERSION:
		return _reject("join_schema")
	if typeof(fragment["self"]) != TYPE_DICTIONARY or typeof(fragment["players"]) != TYPE_ARRAY:
		return _reject("join_types")
	var own: Dictionary = fragment["self"]
	if not _validate_owner_snapshot(own, player_id):
		return _reject("join_self")
	var statuses: Dictionary[String, bool] = {}
	for value: Variant in fragment["players"] as Array:
		if typeof(value) != TYPE_DICTIONARY:
			return _reject("join_player_type")
		var row: Dictionary = value
		if not _validate_status(row) or statuses.has(str(row["player_id"])):
			return _reject("join_player")
		statuses[str(row["player_id"])] = bool(row["alive"])
	if not statuses.has(player_id) or statuses[player_id] != bool(own["alive"]):
		return _reject("join_local_status")
	local_player_id = player_id
	alive_by_player = statuses
	_own_vitals = own.duplicate(true)
	_recent_events.clear()
	_respawn_positions.clear()
	changed.emit()
	own_vitals_changed.emit()
	for status_id: String in alive_by_player:
		player_alive_changed.emit(status_id, alive_by_player[status_id])
	return true


## Applies a changed-only owner snapshot.
func apply_owner_snapshot(snapshot: Dictionary) -> bool:
	if local_player_id.is_empty() or not _validate_owner_snapshot(snapshot, local_player_id):
		return _reject("owner_snapshot")
	if snapshot == _own_vitals:
		return true
	_own_vitals = snapshot.duplicate(true)
	_set_alive(local_player_id, bool(snapshot["alive"]))
	own_vitals_changed.emit()
	changed.emit()
	return true


## Applies one public alive/dead status row (used when a player joins).
func apply_player_status(status: Dictionary) -> bool:
	if not _validate_status(status):
		return _reject("player_status")
	_set_alive(str(status["player_id"]), bool(status["alive"]))
	return true


func remove_player(player_id: String) -> void:
	if alive_by_player.erase(player_id):
		_respawn_positions.erase(player_id)
		changed.emit()


## Validates each event independently. Invalid entries are ignored and logged.
## Returns the number accepted.
func apply_event_batch(values: Array) -> int:
	if values.size() > _survival_settings.max_pending_events:
		_reject("event_batch_size")
		return 0
	var accepted: int = 0
	for value: Variant in values:
		if typeof(value) != TYPE_DICTIONARY:
			_reject("event_type")
			continue
		var event: Dictionary = value
		if not _validate_event(event):
			_reject("event_payload")
			continue
		_apply_event(event)
		accepted += 1
	return accepted


func has_player(player_id: String) -> bool:
	return alive_by_player.has(player_id)


func is_alive(player_id: String) -> bool:
	return alive_by_player.get(player_id, false)


func health() -> float:
	return float(_own_vitals.get("health", 0.0))


func stamina() -> float:
	return float(_own_vitals.get("stamina", 0.0))


func need_category(kind: String) -> String:
	var needs: Dictionary = _own_vitals.get("needs", {})
	return str(needs.get(kind, ""))


func wounds() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for wound: Variant in _own_vitals.get("wounds", []):
		result.append((wound as Dictionary).duplicate(true))
	return result


func infection_stage() -> String:
	return str(_own_vitals.get("infection_stage", ""))


func recent_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in _recent_events:
		result.append(event.duplicate(true))
	return result


func last_respawn_position(player_id: String) -> Vector3:
	return _respawn_positions.get(player_id, Vector3.ZERO)


func _apply_event(event: Dictionary) -> void:
	var player_id: String = str(event["player_id"])
	var event_type: String = str(event["event_type"])
	match event_type:
		SurvivalService.EVENT_PLAYER_WOUNDED:
			if str(event["scope"]) == SCOPE_OWNER:
				_own_vitals["health"] = float(event["health_after"])
				# The ActionResult still describes a wound after the server's stored
				# wound cap is reached. Canonical wound membership therefore comes
				# from the next owner snapshot, not by replaying this event.
				own_vitals_changed.emit()
			if bool(event["died"]):
				_set_alive(player_id, false)
		SurvivalService.EVENT_PLAYER_SURVIVAL_DAMAGE:
			_own_vitals["health"] = float(event["health_after"])
			own_vitals_changed.emit()
		SurvivalService.EVENT_PLAYER_DIED:
			_set_alive(player_id, false)
			if player_id == local_player_id:
				_own_vitals["health"] = 0.0
				_own_vitals["alive"] = false
				own_vitals_changed.emit()
		SurvivalService.EVENT_PLAYER_RESPAWNED:
			var xyz: Array = event["position"]
			var position: Vector3 = Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2]))
			_respawn_positions[player_id] = position
			_set_alive(player_id, true)
			player_respawned.emit(player_id, position)
		SurvivalService.EVENT_PLAYER_INFECTED:
			_own_vitals["infection_stage"] = InfectionState.STAGE_NAMES[InfectionState.Stage.LATENT]
			own_vitals_changed.emit()
		SurvivalService.EVENT_PLAYER_INFECTION_STAGE_CHANGED:
			_own_vitals["infection_stage"] = str(event["to"])
			own_vitals_changed.emit()
		SurvivalService.EVENT_PLAYER_INFECTION_CURED:
			_own_vitals["infection_stage"] = InfectionState.STAGE_NAMES[InfectionState.Stage.NONE]
			own_vitals_changed.emit()
		SurvivalService.EVENT_PLAYER_BLEEDING_STOPPED:
			var stopped_id: String = str(event["wound_id"])
			for wound: Dictionary in _own_vitals.get("wounds", []):
				if str(wound.get("wound_id", "")) == stopped_id:
					wound["is_bleeding"] = false
					break
			own_vitals_changed.emit()
		SurvivalService.EVENT_NEED_CATEGORY_CHANGED:
			var needs: Dictionary = _own_vitals.get("needs", {})
			needs[str(event["need"])] = str(event["category"])
			_own_vitals["needs"] = needs
			own_vitals_changed.emit()
	_recent_events.append(event.duplicate(true))
	while _recent_events.size() > _net_settings.max_recent_events:
		_recent_events.pop_front()
	event_received.emit(event.duplicate(true))
	changed.emit()


func _set_alive(player_id: String, alive: bool) -> void:
	var previous: Variant = alive_by_player.get(player_id, null)
	alive_by_player[player_id] = alive
	if previous == null or bool(previous) != alive:
		player_alive_changed.emit(player_id, alive)
		changed.emit()


func _validate_owner_snapshot(data: Dictionary, expected_player_id: String) -> bool:
	if not _has_exact_keys(data, ["schema_version", "player_id", "alive", "health", "stamina", "needs", "wounds", "infection_stage"]):
		return false
	if typeof(data["schema_version"]) != TYPE_INT or int(data["schema_version"]) != SCHEMA_VERSION:
		return false
	if typeof(data["player_id"]) != TYPE_STRING or str(data["player_id"]) != expected_player_id:
		return false
	if typeof(data["alive"]) != TYPE_BOOL or not _number_in_range(data["health"], 0.0, _survival_settings.max_health):
		return false
	if not _number_in_range(data["stamina"], 0.0, _survival_settings.max_stamina):
		return false
	if bool(data["alive"]) != (float(data["health"]) > 0.0):
		return false
	if typeof(data["needs"]) != TYPE_DICTIONARY or not _validate_needs(data["needs"] as Dictionary):
		return false
	if typeof(data["wounds"]) != TYPE_ARRAY or (data["wounds"] as Array).size() > _survival_settings.max_wounds_per_player:
		return false
	for wound: Variant in data["wounds"] as Array:
		if typeof(wound) != TYPE_DICTIONARY or not _validate_wound(wound as Dictionary):
			return false
	return typeof(data["infection_stage"]) == TYPE_STRING and InfectionState.STAGE_NAMES.has(str(data["infection_stage"]))


func _validate_needs(needs: Dictionary) -> bool:
	if not _has_exact_keys(needs, NeedKind.KIND_NAMES):
		return false
	for kind: String in NeedKind.KIND_NAMES:
		if typeof(needs[kind]) != TYPE_STRING or not NeedKind.CATEGORY_NAMES.has(str(needs[kind])):
			return false
	return true


func _validate_wound(wound: Dictionary) -> bool:
	if not _has_exact_keys(wound, ["wound_id", "body_part", "wound_type", "severity", "is_bleeding", "source_id", "created_at_world_time"]):
		return false
	if typeof(wound["wound_id"]) != TYPE_STRING or str(wound["wound_id"]).is_empty():
		return false
	if typeof(wound["body_part"]) != TYPE_STRING or BodyPart.from_name(str(wound["body_part"])) < 0:
		return false
	if typeof(wound["wound_type"]) != TYPE_STRING or not Wound.TYPE_NAMES.has(str(wound["wound_type"])):
		return false
	if not _number_in_range(wound["severity"], 0.0, Wound.MAX_SEVERITY) or typeof(wound["is_bleeding"]) != TYPE_BOOL:
		return false
	if typeof(wound["source_id"]) != TYPE_STRING or not _finite_number(wound["created_at_world_time"]):
		return false
	return float(wound["created_at_world_time"]) >= 0.0


func _validate_status(status: Dictionary) -> bool:
	return (
		_has_exact_keys(status, ["player_id", "alive"])
		and typeof(status["player_id"]) == TYPE_STRING
		and _valid_player_id(str(status["player_id"]))
		and typeof(status["alive"]) == TYPE_BOOL
	)


func _validate_event(event: Dictionary) -> bool:
	if typeof(event.get("scope", null)) != TYPE_STRING or typeof(event.get("event_type", null)) != TYPE_STRING:
		return false
	if typeof(event.get("player_id", null)) != TYPE_STRING or not _valid_player_id(str(event["player_id"])):
		return false
	var scope: String = str(event["scope"])
	if scope == SCOPE_OWNER:
		if str(event["player_id"]) != local_player_id:
			return false
		return _validate_owner_event(event)
	if scope == SCOPE_PUBLIC:
		return _validate_public_event(event)
	return false


func _validate_owner_event(event: Dictionary) -> bool:
	var event_type: String = str(event["event_type"])
	match event_type:
		SurvivalService.EVENT_PLAYER_WOUNDED:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "source_id", "damage", "health_after", "died", "world_time", "wound"]) and typeof(event["source_id"]) == TYPE_STRING and _positive_number(event["damage"]) and _number_in_range(event["health_after"], 0.0, _survival_settings.max_health) and typeof(event["died"]) == TYPE_BOOL and _world_time(event["world_time"]) and typeof(event["wound"]) == TYPE_DICTIONARY and _validate_wound(event["wound"] as Dictionary)
		SurvivalService.EVENT_PLAYER_BLEEDING_STOPPED:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "wound_id", "world_time"]) and typeof(event["wound_id"]) == TYPE_STRING and not str(event["wound_id"]).is_empty() and _world_time(event["world_time"])
		SurvivalService.EVENT_PLAYER_SURVIVAL_DAMAGE:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "cause", "damage", "health_after", "world_time"]) and typeof(event["cause"]) == TYPE_STRING and _positive_number(event["damage"]) and _number_in_range(event["health_after"], 0.0, _survival_settings.max_health) and _world_time(event["world_time"])
		SurvivalService.EVENT_PLAYER_DIED:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "cause", "world_time"]) and typeof(event["cause"]) == TYPE_STRING and not str(event["cause"]).is_empty() and _world_time(event["world_time"])
		SurvivalService.EVENT_PLAYER_RESPAWNED:
			return _validate_respawn_event(event)
		SurvivalService.EVENT_PLAYER_INFECTED, SurvivalService.EVENT_INFECTION_RESISTED:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "exposure", "source_id", "chance", "world_time"]) and typeof(event["exposure"]) == TYPE_STRING and InfectionState.EXPOSURE_NAMES.has(str(event["exposure"])) and typeof(event["source_id"]) == TYPE_STRING and _number_in_range(event["chance"], 0.0, 1.0) and _world_time(event["world_time"])
		SurvivalService.EVENT_PLAYER_INFECTION_STAGE_CHANGED:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "from", "to", "world_time"]) and typeof(event["from"]) == TYPE_STRING and typeof(event["to"]) == TYPE_STRING and InfectionState.STAGE_NAMES.has(str(event["from"])) and InfectionState.STAGE_NAMES.has(str(event["to"])) and _world_time(event["world_time"])
		SurvivalService.EVENT_PLAYER_INFECTION_CURED:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "source_id", "from", "world_time"]) and typeof(event["source_id"]) == TYPE_STRING and typeof(event["from"]) == TYPE_STRING and InfectionState.STAGE_NAMES.has(str(event["from"])) and _world_time(event["world_time"])
		SurvivalService.EVENT_NEED_CATEGORY_CHANGED:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "need", "category", "world_time"]) and typeof(event["need"]) == TYPE_STRING and NeedKind.KIND_NAMES.has(str(event["need"])) and typeof(event["category"]) == TYPE_STRING and NeedKind.CATEGORY_NAMES.has(str(event["category"])) and _world_time(event["world_time"])
	return false


func _validate_public_event(event: Dictionary) -> bool:
	match str(event["event_type"]):
		SurvivalService.EVENT_PLAYER_WOUNDED:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "body_part", "wound_type", "died", "world_time"]) and typeof(event["body_part"]) == TYPE_STRING and BodyPart.from_name(str(event["body_part"])) >= 0 and typeof(event["wound_type"]) == TYPE_STRING and Wound.TYPE_NAMES.has(str(event["wound_type"])) and typeof(event["died"]) == TYPE_BOOL and _world_time(event["world_time"])
		SurvivalService.EVENT_PLAYER_DIED:
			return _has_exact_keys(event, ["scope", "event_type", "player_id", "world_time"]) and _world_time(event["world_time"])
		SurvivalService.EVENT_PLAYER_RESPAWNED:
			return _validate_respawn_event(event)
	return false


func _validate_respawn_event(event: Dictionary) -> bool:
	if not _has_exact_keys(event, ["scope", "event_type", "player_id", "position", "world_time"]):
		return false
	if typeof(event["position"]) != TYPE_ARRAY or (event["position"] as Array).size() != 3:
		return false
	for coordinate: Variant in event["position"] as Array:
		if not _finite_number(coordinate):
			return false
	return _world_time(event["world_time"])


func _has_exact_keys(data: Dictionary, expected: Variant) -> bool:
	var expected_keys: Array = Array(expected)
	if data.size() != expected_keys.size():
		return false
	for key: Variant in data.keys():
		if typeof(key) != TYPE_STRING or not expected_keys.has(str(key)):
			return false
	return true


func _valid_player_id(player_id: String) -> bool:
	return not player_id.is_empty() and player_id.length() <= _net_settings.max_player_id_length


func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value))


func _number_in_range(value: Variant, minimum: float, maximum: float) -> bool:
	return _finite_number(value) and float(value) >= minimum and float(value) <= maximum


func _positive_number(value: Variant) -> bool:
	return _finite_number(value) and float(value) > 0.0


func _world_time(value: Variant) -> bool:
	return _finite_number(value) and float(value) >= 0.0


func _reject(kind: String) -> bool:
	GameLogger.warning("survival_net", "invalid client survival payload ignored", {"kind": kind, "operation": "apply_payload"})
	return false
