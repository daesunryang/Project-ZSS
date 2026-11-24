class_name ProceduralMapService
extends ServerSystem
## Places the generated part of the map (ProceduralMapGenerator: towns,
## farms, their containers and first zombies) in a world, cell by cell, the
## first time each cell comes into memory (F-33, docs/09 §15.3.1). System id
## "procedural_map".
##
## Never the whole map: a world of 80 x 80 cells is not generated when it is
## created. When WorldCellService brought a cell into memory (LOADING ->
## PRELOADED) this system asks the generator what the cell holds. A cell
## that holds nothing costs one plan and leaves no trace. Any other cell is
## queued and built in step(): `max_pieces_per_tick` structure pieces per
## server tick, in the order the cells arrived (a cell that becomes ACTIVE
## goes to the front). A cell that becomes ACTIVE with a player in it or next
## to it is finished at once (a wall never appears around somebody); the
## preload ring is one cell wider than the active area, so cells a walking
## player comes to were finished long before.
##
## Once per cell: the cell document records how many buildings of the cell
## were placed, how many pieces of the building that is being placed, and
## whether the cell is complete (`systems.procedural_map` =
## {schema_version, generator_version, buildings_done, pieces_done,
## complete}). The record is saved in the same generation as
## the structures it describes, so neither a restart nor a cell that is
## loaded again places anything twice, and what players changed (a
## demolished wall, an emptied container) stays changed. A cell that was
## released half-built goes on with its next piece when it is loaded
## again. A complete cell keeps what it has when the generator or its
## settings change later.
##
## The seed: a new world takes ProceduralMapSettings.world_seed (0 = a
## random one) and keeps it in its world document. A world that was saved
## before it had a generated map takes the configured seed the first time it
## is started and keeps it from then on.
##
## Everything is placed through the server rules of the systems that own
## the entities: BuildingService.place_completed_structure,
## ContainerService.create_container (with a source key, so one placement is
## never two containers) and ZombieService.spawn_zombie. A piece whose slot
## is taken or whose edge somebody stands in is left out and counted; so is
## a zombie the zombie limit has no room for.

const SYSTEM_ID: String = "procedural_map"
const SCHEMA_VERSION: int = 1
const CELL_SCHEMA_VERSION: int = 1
const KEY_WORLD_SEED: String = "world_seed"
const KEY_GENERATOR_VERSION: String = "generator_version"
const KEY_BUILDINGS_DONE: String = "buildings_done"
## Structure pieces placed of the building that is being placed.
const KEY_PIECES_DONE: String = "pieces_done"
const KEY_COMPLETE: String = "complete"
## A cell that becomes ACTIVE with an online player this many cells away or
## closer is finished at once.
const FINISH_NOW_RADIUS_CELLS: int = 1
## Refusals of a structure piece that are expected and only counted.
const SKIPPABLE_STRUCTURE_REASONS: PackedStringArray = [BuildingService.REASON_SLOT_OCCUPIED, BuildingService.REASON_BLOCKED_BY_ENTITY]
const UNKNOWN_SEED: int = -1
const NO_BUDGET_LIMIT: int = -1

## Diagnostics (tests / profiling), since this system was created.
var cells_completed: int = 0
var cells_finished_at_once: int = 0
var buildings_placed: int = 0
var structures_placed: int = 0
var containers_placed: int = 0
var zombies_placed: int = 0
var skipped_structures: int = 0
var refused_structures: int = 0
var skipped_containers: int = 0
var skipped_zombies: int = 0
## Wall-clock microseconds spent placing, and the longest single step().
var placing_usec: int = 0
var max_step_usec: int = 0

var _settings: ProceduralMapSettings
var _grid_module_m: float = 1.0
var _world_ref: WeakRef = null
var _seed: int = UNKNOWN_SEED
var _generator: ProceduralMapGenerator = null
## cell_id -> {buildings_done: int, pieces_done: int, complete: bool,
## generator_version: int} of the cells in memory that have a record.
var _records: Dictionary[String, Dictionary] = {}
## cell_id -> the plan of a cell that is in memory and not complete.
var _plans: Dictionary[String, ProceduralCellPlan] = {}
## Ids of those cells in the order they are built.
var _queue: Array[String] = []
## cell_id -> the structure pieces of the building that is being placed.
var _pieces: Dictionary[String, Array] = {}


## `settings` null = this world gets no generated map (tests, tools).
func _init(settings: ProceduralMapSettings, grid_module_m: float) -> void:
	_settings = settings
	_grid_module_m = grid_module_m


func get_system_id() -> String:
	return SYSTEM_ID


# ------------------------------------------------------------ public API

func is_enabled() -> bool:
	return _settings != null


## The seed of this world's layout (UNKNOWN_SEED before it was decided:
## no settings, or a world that was not seeded or restored yet).
func world_seed() -> int:
	return _seed


## The generator of this world (null without settings or a world). Other
## server systems ask it where the generated buildings are without loading
## a cell (F-28: where an NPC can live).
func generator() -> ProceduralMapGenerator:
	var world: ServerWorld = _world()
	if _settings == null or world == null:
		return null
	if _generator == null:
		_ensure_seed()
		var signature: Dictionary = world.cell_grid.signature()
		var low: Array = signature[WorldCellGrid.KEY_BOUNDS_MIN]
		var high: Array = signature[WorldCellGrid.KEY_BOUNDS_MAX]
		_generator = ProceduralMapGenerator.new(_settings, _seed, world.cell_grid.cell_size_m, Vector2(float(low[0]), float(low[1])), Vector2(float(high[0]), float(high[1])), world.gameplay.world_half_extent_m, _grid_module_m)
	return _generator


## Number of cells that are in memory and still being built.
func pending_cell_count() -> int:
	return _queue.size()


## True when the cell is in memory and everything the generator gives it was
## placed (also true for a loaded cell that gets nothing).
func is_cell_complete(cell_id: String) -> bool:
	return not _plans.has(cell_id)


## Builds everything that is queued and can be built now (tests, tools).
func finish_pending(world: ServerWorld) -> void:
	var cell_id: String = _next_buildable(world)
	while not cell_id.is_empty():
		_advance(world, cell_id, NO_BUDGET_LIMIT)
		cell_id = _next_buildable(world)


# ------------------------------------------------------------ ServerSystem

func on_registered(world: ServerWorld) -> void:
	_world_ref = weakref(world)
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	if _settings != null and cells != null:
		cells.cell_state_changed.connect(_on_cell_state_changed)


## A new world decides its seed now; nothing is placed.
func seed_new_world(world: ServerWorld) -> Error:
	if _settings == null:
		return OK
	_ensure_seed()
	GameLogger.info("map", "generated map: seed decided", {"world_id": world.world_id, "world_seed": str(_seed), "generator_version": ProceduralMapGenerator.GENERATOR_VERSION})
	return OK


func step(world: ServerWorld, _action_delta: float, _world_delta: float) -> void:
	if _queue.is_empty():
		return
	var started_usec: int = Time.get_ticks_usec()
	var budget: int = _settings.max_pieces_per_tick
	while budget > 0:
		var cell_id: String = _next_buildable(world)
		if cell_id.is_empty():
			break
		budget -= _advance(world, cell_id, budget)
	max_step_usec = maxi(max_step_usec, Time.get_ticks_usec() - started_usec)


func on_cell_activated(world: ServerWorld, cell_id: String) -> void:
	if not _plans.has(cell_id):
		return
	if _is_player_near(world, cell_id):
		cells_finished_at_once += 1
		_advance(world, cell_id, NO_BUDGET_LIMIT)
	else:
		# Somebody will see it soon: it goes to the front.
		_queue.erase(cell_id)
		_queue.push_front(cell_id)


func to_cell_document(cell_id: String) -> Dictionary:
	if not _records.has(cell_id):
		return {}
	var record: Dictionary = _records[cell_id]
	return {"schema_version": CELL_SCHEMA_VERSION, KEY_GENERATOR_VERSION: int(record[KEY_GENERATOR_VERSION]), KEY_BUILDINGS_DONE: int(record[KEY_BUILDINGS_DONE]), KEY_PIECES_DONE: int(record[KEY_PIECES_DONE]), KEY_COMPLETE: bool(record[KEY_COMPLETE])}


func restore_cell_document(_world_arg: ServerWorld, cell_id: String, document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != CELL_SCHEMA_VERSION:
		errors.append("procedural_map: cell %s: unsupported schema_version" % cell_id)
		return errors
	if not ItemInstance.is_integer_value(document.get(KEY_GENERATOR_VERSION, null)) or not ItemInstance.is_integer_value(document.get(KEY_BUILDINGS_DONE, null)) or int(document[KEY_BUILDINGS_DONE]) < 0 or not ItemInstance.is_integer_value(document.get(KEY_PIECES_DONE, null)) or int(document[KEY_PIECES_DONE]) < 0 or typeof(document.get(KEY_COMPLETE, null)) != TYPE_BOOL:
		errors.append("procedural_map: cell %s: invalid record" % cell_id)
		return errors
	_records[cell_id] = {KEY_GENERATOR_VERSION: int(document[KEY_GENERATOR_VERSION]), KEY_BUILDINGS_DONE: int(document[KEY_BUILDINGS_DONE]), KEY_PIECES_DONE: int(document[KEY_PIECES_DONE]), KEY_COMPLETE: bool(document[KEY_COMPLETE])}
	return errors


func release_cell(_world_arg: ServerWorld, cell_id: String) -> void:
	_records.erase(cell_id)
	_pieces.erase(cell_id)
	if _plans.erase(cell_id):
		_queue.erase(cell_id)


## The seed of this world ({} while there is none to remember).
func to_world_document() -> Dictionary:
	if _seed == UNKNOWN_SEED:
		if _settings == null:
			return {}
		_ensure_seed()
	return {"schema_version": SCHEMA_VERSION, KEY_WORLD_SEED: str(_seed), KEY_GENERATOR_VERSION: ProceduralMapGenerator.GENERATOR_VERSION}


func restore_world_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get("schema_version", null)) or int(document["schema_version"]) != SCHEMA_VERSION:
		errors.append("procedural_map: unsupported schema_version")
		return errors
	var seed_text: Variant = document.get(KEY_WORLD_SEED, null)
	if typeof(seed_text) != TYPE_STRING or not (seed_text as String).is_valid_int() or (seed_text as String).to_int() < 1 or (seed_text as String).to_int() > ProceduralMapSettings.MAX_WORLD_SEED:
		errors.append("procedural_map: world_seed must be a whole number as text")
		return errors
	_seed = (seed_text as String).to_int()
	_generator = null
	return errors


# ------------------------------------------------------------ internals

func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


## Decides the seed of a world that has none yet: the configured one, or a
## random one when the settings say 0.
func _ensure_seed() -> void:
	if _seed != UNKNOWN_SEED:
		return
	if _settings != null and _settings.world_seed > 0:
		_seed = _settings.world_seed
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	# One draw, exact in JSON, never 0 (the settings' "random" sentinel).
	_seed = int(rng.randi()) + 1


func _on_cell_state_changed(cell_id: String, from: int, to: int) -> void:
	if from != WorldCellLifecycle.State.LOADING or to != WorldCellLifecycle.State.PRELOADED:
		return
	var world: ServerWorld = _world()
	if world == null or _plans.has(cell_id):
		return
	var record: Dictionary = _records.get(cell_id, {})
	if bool(record.get(KEY_COMPLETE, false)):
		return
	var cell: Variant = WorldCellGrid.parse_id(cell_id)
	var maker: ProceduralMapGenerator = generator()
	if cell == null or maker == null:
		return
	if not record.is_empty() and int(record[KEY_GENERATOR_VERSION]) != ProceduralMapGenerator.GENERATOR_VERSION:
		# Half-built by another generator: its plan is gone. It keeps what it has.
		GameLogger.warning("map", "a cell half-built by another generator version keeps what it has", {"world_id": world.world_id, "cell_id": cell_id, "generator_version": int(record[KEY_GENERATOR_VERSION]), "operation": "generate_cell"})
		record[KEY_COMPLETE] = true
		mark_cell_save_dirty(cell_id)
		return
	var plan: ProceduralCellPlan = maker.plan_cell(cell as Vector2i)
	if plan.is_empty():
		return
	_plans[cell_id] = plan
	_queue.append(cell_id)


## The first queued cell that may be built now ("" = none). A cell that is
## being saved (SAVING) is left alone until the save is done: what was placed
## after its document was cut would leave memory unsaved. It then either
## stays in memory and is built on, or comes back with its record and goes on
## where the saved record says.
func _next_buildable(world: ServerWorld) -> String:
	var cells: WorldCellService = world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService
	for cell_id: String in _queue:
		if cells == null or cells.state_of(cell_id) != WorldCellLifecycle.State.SAVING:
			return cell_id
	return ""


## Places the next structure pieces of a cell, building by building, until
## `budget` pieces were handled (NO_BUDGET_LIMIT = all of them); a building
## whose last piece was placed gets its containers. After the last building
## the cell gets its zombies and is marked complete. Returns the number of
## pieces it handled (at least 1, so a caller with a budget always ends).
func _advance(world: ServerWorld, cell_id: String, budget: int) -> int:
	var plan: ProceduralCellPlan = _plans.get(cell_id, null)
	if plan == null or not world.is_cell_loaded(cell_id):
		_plans.erase(cell_id)
		_pieces.erase(cell_id)
		_queue.erase(cell_id)
		return 1
	var started_usec: int = Time.get_ticks_usec()
	if not _records.has(cell_id):
		_records[cell_id] = {KEY_GENERATOR_VERSION: ProceduralMapGenerator.GENERATOR_VERSION, KEY_BUILDINGS_DONE: 0, KEY_PIECES_DONE: 0, KEY_COMPLETE: false}
	var record: Dictionary = _records[cell_id]
	var building: BuildingService = world.get_system(BuildingService.SYSTEM_ID) as BuildingService
	var containers: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	var used: int = 0
	while int(record[KEY_BUILDINGS_DONE]) < plan.buildings.size() and (budget == NO_BUDGET_LIMIT or used < budget):
		var current: ProceduralBuilding = plan.buildings[int(record[KEY_BUILDINGS_DONE])]
		if not _pieces.has(cell_id):
			_pieces[cell_id] = current.pieces(_settings.place_floors)
		var pieces: Array = _pieces[cell_id]
		var from: int = mini(int(record[KEY_PIECES_DONE]), pieces.size())
		var to: int = pieces.size() if budget == NO_BUDGET_LIMIT else mini(pieces.size(), from + budget - used)
		if building != null:
			_place_pieces(world, building, current, pieces, from, to)
		used += to - from
		record[KEY_PIECES_DONE] = to
		if to >= pieces.size():
			if building != null and containers != null:
				_place_containers(world, building, containers, current)
			buildings_placed += 1
			record[KEY_BUILDINGS_DONE] = int(record[KEY_BUILDINGS_DONE]) + 1
			record[KEY_PIECES_DONE] = 0
			_pieces.erase(cell_id)
	if int(record[KEY_BUILDINGS_DONE]) >= plan.buildings.size():
		_place_zombies(world, plan)
		record[KEY_COMPLETE] = true
		_plans.erase(cell_id)
		_pieces.erase(cell_id)
		_queue.erase(cell_id)
		cells_completed += 1
		GameLogger.debug("map", "generated cell complete", {"world_id": world.world_id, "cell_id": cell_id, "buildings": plan.buildings.size(), "zombies": plan.zombie_positions.size()})
	mark_cell_save_dirty(cell_id)
	placing_usec += Time.get_ticks_usec() - started_usec
	return maxi(used, 1)


## Places the structure pieces `from` .. `to` - 1 of one building.
func _place_pieces(world: ServerWorld, building: BuildingService, plan: ProceduralBuilding, pieces: Array, from: int, to: int) -> void:
	var refused_reason: String = ""
	for index: int in range(from, to):
		var piece: Dictionary = pieces[index]
		var placed: ActionResult = building.place_completed_structure(world, str(piece[MapBuildingPlan.KEY_DEFINITION_ID]), piece[MapBuildingPlan.KEY_TILE] as Vector2i, int(piece[MapBuildingPlan.KEY_ROTATION]))
		if placed.ok:
			structures_placed += 1
		elif SKIPPABLE_STRUCTURE_REASONS.has(placed.reason):
			skipped_structures += 1
		else:
			refused_structures += 1
			refused_reason = placed.reason
	if not refused_reason.is_empty():
		GameLogger.error("map", "pieces of a generated building were refused", {"world_id": world.world_id, "building_id": plan.building_id(), "reason": refused_reason, "operation": "generate_cell"})


## Places the containers of one building whose structure pieces stand.
func _place_containers(world: ServerWorld, building: BuildingService, containers: ContainerService, plan: ProceduralBuilding) -> void:
	var definition: MapBuildingDefinition = plan.definition
	for index: int in range(definition.containers.size()):
		var placement: MapContainerPlacement = definition.containers[index]
		var created: ActionResult = containers.create_container(world, placement.definition_id, MapBuildingPlan.container_position(definition, placement, building.grid), definition.loot_table_of(placement), MapBuildingPlan.container_source_key(ProceduralMapGenerator.MAP_ID, definition.building_id, index))
		if created.ok:
			containers_placed += 1
		else:
			skipped_containers += 1
			if created.reason != ContainerService.REASON_SOURCE_EXISTS:
				GameLogger.error("map", "a container of a generated building was refused", {"world_id": world.world_id, "building_id": definition.building_id, "definition_id": placement.definition_id, "reason": created.reason, "operation": "generate_cell"})


func _place_zombies(world: ServerWorld, plan: ProceduralCellPlan) -> void:
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	for position: Vector3 in plan.zombie_positions:
		if zombies != null and zombies.has_spawn_room() and zombies.spawn_zombie(world, position).ok:
			zombies_placed += 1
		else:
			skipped_zombies += 1


## True when an online player's cell is at most FINISH_NOW_RADIUS_CELLS
## cells from this cell.
func _is_player_near(world: ServerWorld, cell_id: String) -> bool:
	var cell: Variant = WorldCellGrid.parse_id(cell_id)
	if cell == null:
		return false
	for player_id: String in world.online_player_ids():
		if WorldCellGrid.distance(world.cell_grid.cell_of(world.get_player(player_id).position), cell as Vector2i) <= FINISH_NOW_RADIUS_CELLS:
			return true
	return false
