class_name ZombieState
extends RefCounted
## Server-side state of one zombie (docs/02 §6.1). Plain data, saved in
## world_state.json `systems.zombie.zombies[]`. Other systems treat it as
## read-only; all changes go through ZombieService.
## Every timestamp here is action time (WorldClock.action_time_sec, real
## seconds, docs/09 §14.16). Saves written before P2-T1 stored them in the
## single real-time world clock; the world migration starts the action clock
## at that value, so they keep their meaning.

enum State { IDLE, INVESTIGATE, CHASE, ATTACK, SEARCH, DORMANT, DEAD }

## Save/network names, indexed by State.
##   idle        waiting / wandering around the home point
##   investigate walking to a heard noise (or to whoever hit it)
##   chase       following a target it can see
##   attack      in range of a visible target
##   search      looking around the last known position
##   dormant     inactive (field only; nothing enters it yet, docs/15 P2-29)
##   dead        corpse waiting for removal
const STATE_NAMES: PackedStringArray = ["idle", "investigate", "chase", "attack", "search", "dormant", "dead"]
const ZOMBIE_ID_PATTERN: String = "^zombie_[0-9]+$"
const NO_TIME: float = -1.0

var zombie_id: String = ""
var position: Vector3 = Vector3.ZERO
## Facing around Y, radians (ZombiePerception yaw convention).
var yaw: float = 0.0
var state: State = State.IDLE
var health: float = 0.0
## Centre of idle wandering.
var home_position: Vector3 = Vector3.ZERO
## Player being chased/attacked ("" = none).
var target_player_id: String = ""
## Whether the target was seen at the last AI decision.
var target_visible: bool = false
## Last known target position, heard noise position or search centre.
var focus_position: Vector3 = Vector3.ZERO
## Current wander/search waypoint (valid while has_move_target).
var has_move_target: bool = false
var move_target: Vector3 = Vector3.ZERO
## Action time when investigate/search gives up.
var state_until: float = 0.0
## Action time of the earliest next attack.
var attack_ready_at: float = 0.0
## Action time of the earliest next wander step.
var next_wander_at: float = 0.0
## Newest noise event time (action time) already reacted to (NoiseService
## `since_time`).
var last_noise_time: float = NO_TIME
## Action time of death (NO_TIME while alive).
var died_at: float = NO_TIME
## Attacker to notice at the next AI decision ("" = none).
var alerted_by: String = ""
## Deterministic per-zombie RNG (wander, search, attack rolls). State saved.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func is_alive() -> bool:
	return state != State.DEAD


static func state_name(value: State) -> String:
	return STATE_NAMES[value]


func to_dict() -> Dictionary:
	return {
		"zombie_id": zombie_id,
		"position": _vector_to_array(position),
		"yaw": yaw,
		"state": STATE_NAMES[state],
		"health": health,
		"home_position": _vector_to_array(home_position),
		"target_player_id": target_player_id,
		"target_visible": target_visible,
		"focus_position": _vector_to_array(focus_position),
		"has_move_target": has_move_target,
		"move_target": _vector_to_array(move_target),
		"state_until": state_until,
		"attack_ready_at": attack_ready_at,
		"next_wander_at": next_wander_at,
		"last_noise_time": last_noise_time,
		"died_at": died_at,
		"alerted_by": alerted_by,
		# 64-bit values are stored as strings: JSON numbers would lose precision.
		"rng_seed": str(rng.seed),
		"rng_state": str(rng.state),
	}


## Returns null when `data` is malformed. `max_health` bounds the health.
static func from_dict(data: Dictionary, max_health: float) -> ZombieState:
	var id: Variant = data.get("zombie_id", null)
	if typeof(id) != TYPE_STRING or RegEx.create_from_string(ZOMBIE_ID_PATTERN).search(str(id)) == null:
		return null
	var state_index: int = STATE_NAMES.find(str(data.get("state", "")))
	if state_index < 0:
		return null
	var zombie: ZombieState = ZombieState.new()
	zombie.zombie_id = str(id)
	zombie.state = state_index as State
	for key: String in ["position", "home_position", "focus_position", "move_target"]:
		var vector: Variant = _array_to_vector(data.get(key, null))
		if vector == null:
			return null
		zombie.set(key, vector)
	for key: String in ["yaw", "health", "state_until", "attack_ready_at", "next_wander_at", "last_noise_time", "died_at"]:
		var number: Variant = data.get(key, null)
		if not _is_number(number) or not is_finite(float(number)):
			return null
		zombie.set(key, float(number))
	if zombie.health < 0.0 or zombie.health > max_health:
		return null
	if (zombie.state == State.DEAD) != (zombie.health <= 0.0):
		return null
	for key: String in ["target_visible", "has_move_target"]:
		if typeof(data.get(key, null)) != TYPE_BOOL:
			return null
		zombie.set(key, bool(data[key]))
	for key: String in ["target_player_id", "alerted_by"]:
		if typeof(data.get(key, null)) != TYPE_STRING:
			return null
		zombie.set(key, str(data[key]))
	var seed_text: String = str(data.get("rng_seed", ""))
	var state_text: String = str(data.get("rng_state", ""))
	if not seed_text.is_valid_int() or not state_text.is_valid_int():
		return null
	zombie.rng.seed = seed_text.to_int()
	zombie.rng.state = state_text.to_int()
	return zombie


static func _vector_to_array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


## Vector3 for a saved [x, y, z] array, or null.
static func _array_to_vector(value: Variant) -> Variant:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 3:
		return null
	for component: Variant in (value as Array):
		if not _is_number(component) or not is_finite(float(component)):
			return null
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
