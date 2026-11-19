class_name NpcThreatSense
extends RefCounted
## What an NPC sees of the zombies (P4-4, docs/09 §17.6 "하드 인터럽트"): a
## living zombie within range whose line is not blocked by a structure, the
## same blocking hook the zombies' own sight uses
## (ServerWorld.is_line_blocked). Reads the zombie system, changes nothing
## (docs/13 §16.3 D3: zombies do not know NPCs). No view cone: an NPC
## notices a zombie in every direction (docs/15 P4-160).

## Keys of a threat.
const KEY_THREAT_ID: String = NpcActionExecutor.TARGET_THREAT_ID
const KEY_THREAT_POSITION: String = NpcActionExecutor.TARGET_THREAT_POSITION
const KEY_DISTANCE: String = "distance_m"


## The living zombies in memory: [[zombie_id, position], ...] in id order of
## the zombie system. Made once for several nearest_visible() calls.
static func living_zombies(world: ServerWorld) -> Array[Array]:
	var result: Array[Array] = []
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService if world != null else null
	if zombies == null or zombies.zombie_count() == 0:
		return result
	for zombie_id: String in zombies.zombie_ids():
		var zombie: ZombieState = zombies.get_zombie(zombie_id)
		if zombie != null and zombie.is_alive():
			result.append([zombie_id, zombie.position])
	return result


## The nearest zombie of `zombies` (living_zombies()) that `eye` sees
## within `range_m` (ties: the smaller id): {threat_id, threat_position:
## [x, y, z], distance_m}, or {} when it sees none.
static func nearest_visible(world: ServerWorld, eye: Vector3, range_m: float, zombies: Array[Array]) -> Dictionary:
	if zombies.is_empty() or range_m <= 0.0 or not eye.is_finite():
		return {}
	var range_sq: float = range_m * range_m
	# [distance squared, zombie id, position]
	var in_range: Array[Array] = []
	for entry: Array in zombies:
		var position: Vector3 = entry[1]
		var distance_sq: float = Vector2(position.x - eye.x, position.z - eye.z).length_squared()
		if distance_sq <= range_sq:
			in_range.append([distance_sq, entry[0], position])
	if in_range.size() > 1:
		in_range.sort_custom(_is_nearer)
	for entry: Array in in_range:
		var position: Vector3 = entry[2]
		if not world.is_line_blocked(eye, position):
			return {KEY_THREAT_ID: str(entry[1]), KEY_THREAT_POSITION: [position.x, position.y, position.z], KEY_DISTANCE: sqrt(float(entry[0]))}
	return {}


static func _is_nearer(a: Array, b: Array) -> bool:
	if float(a[0]) != float(b[0]):
		return float(a[0]) < float(b[0])
	return str(a[1]) < str(b[1])
