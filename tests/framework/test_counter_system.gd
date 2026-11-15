class_name TestCounterSystem
extends ServerSystem
## Test double for the ServerSystem seam: counts hooks, persists a world
## counter and a per-player counter.

const SYSTEM_ID: String = "test_counter"

var seeded: int = 0
var steps: int = 0
var world_time_seen: float = 0.0
var total: int = 0
var per_player: Dictionary[String, int] = {}
var online_events: PackedStringArray = []


func get_system_id() -> String:
	return SYSTEM_ID


func seed_new_world(_world: ServerWorld) -> Error:
	seeded += 1
	return OK


func step(_world: ServerWorld, _real_delta: float, world_delta: float) -> void:
	steps += 1
	world_time_seen += world_delta


func on_player_online(_world: ServerWorld, player_id: String) -> void:
	online_events.append("online:" + player_id)
	per_player[player_id] = per_player.get(player_id, 0) + 1


func on_player_offline(_world: ServerWorld, player_id: String) -> void:
	online_events.append("offline:" + player_id)


func to_world_document() -> Dictionary:
	return {"schema_version": 1, "total": total}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	if int(document.get("schema_version", 0)) != 1:
		return PackedStringArray(["test_counter: bad schema_version"])
	total = int(document.get("total", 0))
	return PackedStringArray()


func to_player_fragment(player_id: String) -> Dictionary:
	if not per_player.has(player_id):
		return {}
	return {"schema_version": 1, "joins": per_player[player_id]}


func restore_player_fragment(player_id: String, fragment: Dictionary) -> PackedStringArray:
	per_player[player_id] = int(fragment.get("joins", 0))
	return PackedStringArray()
