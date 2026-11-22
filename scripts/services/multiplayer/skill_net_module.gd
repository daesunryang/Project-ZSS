class_name SkillNetModule
extends NetModule
## Skill level replication (F-9). Network only: every rule is in
## SkillService.
##
## RPC table (channel 0 = reliable ordered):
##   server -> owner   _rpc_skill_snapshot(snapshot:Dictionary)   reliable, ch0
##
## Replication: a player's skills are owner-only (nobody else sees them).
## The owner gets them in the join snapshot ("SkillNet" fragment) and again
## whenever they changed (experience gained, reset for a new character) or
## its player entered the world. Snapshot = {"schema_version": 1,
## "skills": SkillService.rows_of(player)}. No client -> server RPC: a
## client never sends experience, levels or costs.
##
## Client surface (presentation): the mirror `client_state`. No authority.

const MODULE_NAME: String = "SkillNet"
const SCHEMA_VERSION: int = ClientSkillState.SCHEMA_VERSION

var client_state: ClientSkillState

# --- server state ---
var _skills: SkillService = null


func _init(settings: SkillSettings) -> void:
	name = MODULE_NAME
	client_state = ClientSkillState.new(settings)


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_skills = world.get_system(SkillService.SYSTEM_ID) as SkillService


func on_player_joined(peer_id: int, player_id: String) -> void:
	_send_snapshot(peer_id, player_id)


func build_join_fragment(player_id: String) -> Dictionary:
	if _skills == null:
		return {}
	return make_snapshot(player_id)


func apply_join_fragment(fragment: Dictionary) -> void:
	if fragment.is_empty():
		client_state.clear()
		return
	client_state.apply_snapshot(fragment)


func server_physics(_delta: float) -> void:
	if _skills == null:
		return
	for player_id: String in _skills.drain_changed_players():
		var peer_id: int = network.peer_of_player(player_id)
		if peer_id != 0:
			_send_snapshot(peer_id, player_id)


## The owner snapshot of one player (server).
func make_snapshot(player_id: String) -> Dictionary:
	var rows: Array[Dictionary] = []
	if _skills != null:
		rows = _skills.rows_of(player_id)
	return {"schema_version": SCHEMA_VERSION, "skills": rows}


# ------------------------------------------------------------ server side

func _send_snapshot(peer_id: int, player_id: String) -> void:
	if _skills == null or not network.can_send_to(peer_id):
		return
	_rpc_skill_snapshot.rpc_id(peer_id, make_snapshot(player_id))


# ------------------------------------------------------------ client side

@rpc("authority", "call_remote", "reliable", 0)
func _rpc_skill_snapshot(snapshot: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(snapshot) != TYPE_DICTIONARY:
		client_state.rejected_count += 1
		return
	client_state.apply_snapshot(snapshot as Dictionary)
