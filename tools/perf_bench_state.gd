class_name PerfBenchState
extends RefCounted
## Canonical deterministic state used by the fixed-seed performance bench.
## Timing and transient network queues are deliberately excluded.

const QUANTUM: float = 0.001


static func digest(world: ServerWorld) -> String:
	return canonical_json(payload(world)).sha256_text()


static func payload(world: ServerWorld) -> Dictionary:
	return {
		"players": _players(world),
		"zombies": _zombies(world),
		"items": _items(world),
		"containers": _containers(world),
		"structures": _structures(world),
	}


static func canonical_json(value: Variant) -> String:
	match typeof(value):
		TYPE_DICTIONARY:
			var dictionary: Dictionary = value as Dictionary
			var keys: Array[String] = []
			for key: Variant in dictionary:
				keys.append(str(key))
			keys.sort()
			var fields: PackedStringArray = []
			for key: String in keys:
				fields.append("%s:%s" % [JSON.stringify(key), canonical_json(dictionary[key])])
			return "{%s}" % ",".join(fields)
		TYPE_ARRAY:
			var entries: PackedStringArray = []
			for entry: Variant in (value as Array):
				entries.append(canonical_json(entry))
			return "[%s]" % ",".join(entries)
		TYPE_FLOAT:
			return JSON.stringify(_rounded(float(value)))
		_:
			return JSON.stringify(value)


static func _players(world: ServerWorld) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var survival: SurvivalService = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	for player_id: String in world.online_player_ids():
		var player: PlayerState = world.get_player(player_id)
		var health: float = 0.0
		if survival != null:
			var vitals: PlayerVitals = survival.get_vitals(player_id)
			health = vitals.health if vitals != null else 0.0
		var carried: Array[Dictionary] = []
		for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
			carried.append(_item_row(item))
		result.append({
			"id": player_id,
			"position": _vector(player.position),
			"yaw": _rounded(player.yaw),
			"health": _rounded(health),
			"inventory": carried,
		})
	return result


static func _zombies(world: ServerWorld) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var service: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	if service == null:
		return result
	var ids: PackedStringArray = service.zombie_ids()
	ids.sort()
	for zombie_id: String in ids:
		var zombie: ZombieState = service.get_zombie(zombie_id)
		result.append({
			"id": zombie_id,
			"position": _vector(zombie.position),
			"yaw": _rounded(zombie.yaw),
			"state": ZombieState.state_name(zombie.state),
			"health": _rounded(zombie.health),
			"target": zombie.target_player_id,
			"target_visible": zombie.target_visible,
			"focus": _vector(zombie.focus_position),
		})
	return result


static func _items(world: ServerWorld) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var snapshot: Dictionary = world.inventory.to_snapshot()
	var positions: Dictionary = snapshot.get(InventoryService.SNAPSHOT_POSITIONS, {}) as Dictionary
	for entry: Variant in (snapshot.get(InventoryService.SNAPSHOT_ITEMS, []) as Array):
		var item: Dictionary = entry as Dictionary
		var row: Dictionary = {
			"id": str(item.get("item_instance_id", "")),
			"definition": str(item.get("definition_id", "")),
			"quantity": int(item.get("quantity", 0)),
			"location_type": str(item.get("location_type", "")),
			"location_id": str(item.get("location_id", "")),
		}
		var item_id: String = str(row["id"])
		if positions.has(item_id):
			var raw_position: Array = positions[item_id] as Array
			row["position"] = [_rounded(float(raw_position[0])), _rounded(float(raw_position[1])), _rounded(float(raw_position[2]))]
		result.append(row)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
	return result


static func _containers(world: ServerWorld) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var service: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	if service == null:
		return result
	var ids: PackedStringArray = service.container_ids()
	ids.sort()
	for container_id: String in ids:
		var container: ContainerInstance = service.get_container(container_id)
		var contents: Array[Dictionary] = []
		for entry: Dictionary in service.contents_of(container_id):
			contents.append({
				"id": str(entry.get(ContainerService.ENTRY_ITEM_ID, "")),
				"definition": str(entry.get(ContainerService.ENTRY_DEFINITION_ID, "")),
				"quantity": int(entry.get(ContainerService.ENTRY_QUANTITY, 0)),
			})
		contents.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
		result.append({
			"id": container_id,
			"definition": container.definition_id,
			"position": _vector(container.position),
			"searched": container.searched,
			"contents": contents,
		})
	return result


static func _structures(world: ServerWorld) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var service: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	if service == null:
		return result
	var ids: PackedStringArray = service.structure_ids()
	ids.sort()
	for structure_id: String in ids:
		var structure: StructureInstance = service.get_structure(structure_id)
		var row: Dictionary = service.public_row(structure)
		result.append({
			"id": structure_id,
			"definition": structure.definition_id,
			"tile": [structure.tile.x, structure.tile.y],
			"rotation": structure.rotation,
			"state": str(row.get(BuildingService.KEY_STATE, "")),
			"door_open": structure.door_open,
			"health": _rounded(structure.health),
			"progress": _rounded(structure.construction_progress),
			"delivered": row.get(BuildingService.KEY_DELIVERED, {}),
		})
	return result


static func _item_row(item: ItemInstance) -> Dictionary:
	return {
		"id": item.item_instance_id,
		"definition": item.definition_id,
		"quantity": item.quantity,
	}


static func _vector(value: Vector3) -> Array[float]:
	return [_rounded(value.x), _rounded(value.y), _rounded(value.z)]


static func _rounded(value: float) -> float:
	var rounded: float = snappedf(value, QUANTUM)
	return 0.0 if is_zero_approx(rounded) else rounded
