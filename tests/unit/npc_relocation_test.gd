extends TestCase
## F-30 (docs/09 §17.15): an NPC that lives alone moves to another shelter
## by itself: when nothing is left around its home and its food runs low,
## when it met zombies at home again and again, when it was badly hurt
## there. It chooses a building nobody lives in, packs what it can carry,
## walks there in legs and moves in; the world's record of who lives where
## follows. Whatever it is in the middle of goes on after a restart and
## after its cell left memory, and an NPC that dies on the way leaves what
## it carried on the road and the building free.
##
## The shipped composition and generated map (NpcLifeRun with the generated
## map), without generated zombies. What the containers hold is set by the
## tests. The observer walks with the NPC, so the cells on its way are in
## memory and built (an NPC whose cell is not simulated is frozen, as
## everywhere).

const WORLD: String = "npc_relocation_world"
const SEED: int = 20261123
const MODULE_M: float = 1.0
const TICK: float = 0.05
const ROSTER_ID: String = "dev_npc_roster"
const FOOD: String = "dev_food_ration"
const WATER: String = "dev_water_bottle"
const BANDAGE: String = "dev_bandage"
const NAILS: String = "dev_nails"
const RELOCATE: String = NpcBehaviours.ACTION_RELOCATE
## Ticks for the cells around a player to come into memory.
const ARRIVE_TICKS: int = 40
## Most ticks a test waits for a move (25 real minutes).
const PATIENCE_TICKS: int = 30000
## Most ticks a test waits for an NPC to use something of its new home.
const LIVING_TICKS: int = 90000
const FAR_AWAY: Vector3 = Vector3(0.0, 0.0, 0.0)
const MEASURE_TICK: float = 1.0 / 60.0
## Two minutes: long enough for NPCs that walk 80 m and more to arrive.
const MEASURE_TICKS: int = 7200
const STAGE_BOUND_MS: float = 2.0
const CHOICE_BOUND_MS: float = 3.0
const SCAN_BOUND_MS: float = 2.0

var _root: String = ""
## Buildings NPCs chose to move to whose containers the test empties as
## soon as they are in memory (so that what is in them afterwards is what
## the NPC brought, not the loot of a world with a random loot seed).
var _to_empty: Array[String] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_to_empty.clear()
	_root = "user://test_saves/npc_relocation_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	SaveService.remove_tree(_root + "_copy")
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _procedural() -> ProceduralMapSettings:
	var settings: ProceduralMapSettings = (ProceduralMapSettings.load_or_null() as ProceduralMapSettings).duplicate(true) as ProceduralMapSettings
	settings.world_seed = SEED
	settings.town_zombies_per_cell_max = 0
	settings.roadside_zombie_percent = 0
	settings.wild_zombie_per_10000 = 0
	return settings


func _map(world: ServerWorld) -> ProceduralMapService:
	return world.get_system(ProceduralMapService.SYSTEM_ID) as ProceduralMapService


func _containers(world: ServerWorld) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _health(world: ServerWorld) -> NpcHealth:
	return NpcHealth.of_world(world)


func _center_of(definition: MapBuildingDefinition) -> Vector3:
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	return (grid.tile_center(definition.origin_tile) + grid.tile_center(definition.origin_tile + definition.size_tiles - Vector2i.ONE)) * 0.5


func _center(run: NpcLifeRun, building_id: String) -> Vector3:
	return _center_of(_map(run.world).generator().building_by_id(building_id).definition)


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## The buildings with a container whose middle is within the scavenging
## radius of `home_id`'s middle and nobody lives in, nearest first.
func _neighbours(run: NpcLifeRun, home_id: String) -> PackedStringArray:
	var generator: ProceduralMapGenerator = _map(run.world).generator()
	var radius: float = NpcScavengeSettings.load_or_default().radius_m
	var home_center: Vector3 = _center(run, home_id)
	var rows: Array[Array] = []
	for cell: Vector2i in run.world.cell_grid.cells_within(run.world.cell_grid.cell_of(home_center), 2):
		for building: ProceduralBuilding in generator.plan_cell(cell).buildings:
			var id: String = building.building_id()
			var center: Vector3 = _center_of(building.definition)
			if id == home_id or building.definition.containers.is_empty() or _flat(center, home_center) > radius or run.npcs().is_seeded_home(id):
				continue
			rows.append([_flat(center, home_center), id])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]) if float(a[0]) != float(b[0]) else str(a[1]) < str(b[1]))
	var ids: PackedStringArray = []
	for row: Array in rows:
		ids.append(str(row[1]))
	return ids


## A run with the observer in the house of an NPC of the roster, every
## container of its house and of the buildings around it searched and
## empty, the NPC carrying nothing: {run, npc_id, home_id, home_position,
## neighbours}. `rural`: an NPC that lives outside every town; otherwise
## one in a town with buildings around it. `empty_destinations`: the
## containers of a building an NPC chooses to move to are emptied before
## it arrives (see _to_empty). {} when it failed.
func _scene(run: NpcLifeRun, rural: bool = false, empty_destinations: bool = true) -> Dictionary:
	assert_not_null(run, "test setup: the world")
	if run == null:
		return {}
	var service: NpcService = run.npcs()
	var generator: ProceduralMapGenerator = _map(run.world).generator()
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	for definition_id: String in NpcRoster.load_or_null().npc_definition_ids:
		var home_id: String = service.seeded_home(ROSTER_ID, definition_id)
		var layout: NpcHomeLayout = NpcHomeLayout.of(generator.building_by_id(home_id).definition)
		var home_position: Vector3 = grid.tile_center(layout.home_tile())
		var in_town: bool = generator.cell_kind(run.world.cell_grid.cell_of(home_position)) == ProceduralMapGenerator.CellKind.TOWN
		var neighbours: PackedStringArray = _neighbours(run, home_id)
		if in_town == rural or layout.food_offsets.is_empty() or (not rural and neighbours.size() < 3):
			continue
		run.observer.position = home_position
		run.run_ticks(ARRIVE_TICKS)
		_map(run.world).finish_pending(run.world)
		run.run_ticks(2)
		var npc_id: String = service.seeded_npc_id(ROSTER_ID, definition_id)
		assert_true(service.is_awake(npc_id), "test setup: the NPC is simulated while a player is in its house")
		if not service.is_awake(npc_id):
			return {}
		_empty(run.world, home_id)
		for building_id: String in neighbours:
			_empty(run.world, building_id)
		_drop_all(run.world, run.behaviour_of(npc_id).inventory_id)
		if empty_destinations and run.behaviours.relocation() != null:
			run.behaviours.relocation().destination_chosen.connect(func(_moved_id: String, building_id: String) -> void: _to_empty.append(building_id))
		return {"run": run, "npc_id": npc_id, "definition_id": definition_id, "home_id": home_id, "home_position": home_position, "neighbours": neighbours}
	fail("test setup: no NPC of the roster lives %s" % ("outside the towns" if rural else "in a town with buildings around it"))
	return {}


## The containers of a generated building, by their index.
func _containers_of(world: ServerWorld, building_id: String) -> Array[ContainerInstance]:
	var found: Array[ContainerInstance] = []
	var building: ProceduralBuilding = _map(world).generator().building_by_id(building_id)
	for index: int in range(building.definition.containers.size()):
		found.append(_containers(world).get_container(_containers(world).container_id_of_source(MapBuildingPlan.container_source_key(ProceduralMapGenerator.MAP_ID, building_id, index))))
	return found


## Every container of a building that is in memory is searched (its loot is
## rolled) and empty.
func _empty(world: ServerWorld, building_id: String) -> void:
	for container: ContainerInstance in _containers_of(world, building_id):
		if container == null:
			continue
		_containers(world).search_now(world, container.container_id)
		_drop_all(world, container.inventory_id)


func _drop_all(world: ServerWorld, inventory_id: String) -> void:
	for item: ItemInstance in world.inventory.items_in_inventory(inventory_id):
		world.inventory.remove_item(inventory_id, item.item_instance_id, item.quantity)


func _put(world: ServerWorld, inventory_id: String, definition_id: String, units: int) -> void:
	assert_false(world.inventory.spawn_detached_item(inventory_id, definition_id, units).is_empty(), "test setup: %d of %s" % [units, definition_id])


func _units(world: ServerWorld, inventory_id: String, definition_id: String) -> int:
	var total: int = 0
	for item: ItemInstance in world.inventory.items_in_inventory(inventory_id):
		total += item.quantity if item.definition_id == definition_id else 0
	return total


func _units_in_building(world: ServerWorld, building_id: String, definition_id: String) -> int:
	var total: int = 0
	for container: ContainerInstance in _containers_of(world, building_id):
		total += _units(world, container.inventory_id, definition_id) if container != null else 0
	return total


func _move_of(run: NpcLifeRun, npc_id: String) -> NpcRelocationState:
	return NpcRelocationState.of(run.npcs().get_npc(npc_id))


func _home_of(run: NpcLifeRun, npc_id: String) -> String:
	return NpcHome.of(run.npcs().get_npc(npc_id)).building_id


## The NPC knows that every building around its home is empty (it has been
## everywhere), without the trips that would teach it.
func _knows_everything_is_empty(run: NpcLifeRun, scene: Dictionary) -> void:
	var trip: NpcScavengeState = NpcScavengeState.of(run.npcs().get_npc(str(scene["npc_id"])))
	trip.note_visit(str(scene["home_id"]), NpcScavengeState.RESULT_EMPTY, 0, 512)
	for building_id: String in (scene["neighbours"] as PackedStringArray):
		trip.note_visit(building_id, NpcScavengeState.RESULT_EMPTY, 0, 512)


## Steps until `done` says so (at most `patience` ticks); the observer
## walks with the NPC `follow_id` and the cells around them are built at
## once. True when it did.
func _run_until(run: NpcLifeRun, done: Callable, follow_id: String = "", patience: int = PATIENCE_TICKS) -> bool:
	for tick: int in range(patience):
		if done.call():
			return true
		_follow(run, follow_id)
		run.step()
	return done.call()


func _follow(run: NpcLifeRun, follow_id: String) -> void:
	var followed: NpcState = run.npcs().get_npc(follow_id) if not follow_id.is_empty() else null
	if followed != null:
		run.observer.position = followed.position
		if _map(run.world).pending_cell_count() > 0:
			_map(run.world).finish_pending(run.world)
	for building_id: String in _to_empty.duplicate():
		var containers: Array[ContainerInstance] = _containers_of(run.world, building_id)
		if not containers.has(null) and NpcHome.of(followed).building_id != building_id:
			_empty(run.world, building_id)
			_to_empty.erase(building_id)


func _no_errors() -> void:
	assert_false(" | ".join(GameLogger.captured_lines()).contains("[ERROR]"), "no errors on the way")


func _tail(run: NpcLifeRun, count: int = 8) -> String:
	return str(run.events.slice(maxi(run.events.size() - count, 0)))


func _near(actual: float, expected: float, tolerance: float, message: String = "") -> void:
	assert_true(absf(actual - expected) <= tolerance, "%s (%s, expected %s)" % [message, str(actual), str(expected)])


## The NPC sees zombies around `center`, one place after another (the
## middle, then rings 10.5 m apart), until the danger it remembers there
## is at least `limit`. Returns how many sightings that took.
func _see_zombies_until(run: NpcLifeRun, npc: NpcState, center: Vector3, limit: float) -> int:
	var sense: NpcSurvivalSense = run.decider.survival()
	var places: Array[Vector3] = [center]
	for ring: int in range(1, 3):
		for index: int in range(6 * ring):
			var angle: float = float(index) * TAU / float(6 * ring)
			places.append(center + Vector3(cos(angle), 0.0, sin(angle)) * 10.5 * float(ring))
	var seen: int = 0
	for place: Vector3 in places:
		if sense.danger_at(npc, center, run.world.clock.world_time_sec) >= limit:
			break
		if sense.note_zombie_seen(run.world, npc, place):
			seen += 1
	return seen


# ------------------------------------------------------------ pure data

func test_the_shipped_settings_and_action_are_valid() -> void:
	var settings: NpcRelocationSettings = NpcRelocationSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	var defaults: NpcRelocationSettings = NpcRelocationSettings.new()
	for property: Dictionary in defaults.get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			assert_eq(settings.get(str(property["name"])), defaults.get(str(property["name"])), "the tuning file and the script agree on %s" % property["name"])
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	assert_not_null(config.npc_relocation, "the shipped composition lets NPCs move")
	assert_true(settings.leg_length_m <= config.navigation.max_search_radius_m * NpcRelocationSettings.LEG_SHARE_OF_SEARCH_RADIUS, "a leg is within reach of the path search")
	var bad: NpcRelocationSettings = NpcRelocationSettings.new()
	bad.leg_length_m = config.navigation.max_search_radius_m
	bad.hurt_health_fraction = 1.5
	bad.max_leg_failures = 0
	bad.min_distance_m = bad.max_distance_m
	assert_eq(bad.validate().size(), 2, "; ".join(bad.validate()))
	bad.hurt_health_fraction = 0.5
	bad.max_leg_failures = 1
	assert_eq(bad.validate().size(), 1, "the nearest distance must be below the farthest: %s" % "; ".join(bad.validate()))
	assert_eq(bad.validate_against(config.navigation).size(), 1)
	var actions: NpcActionCatalog = config.npc_actions
	var relocate: NpcActionDefinition = actions.get_action(RELOCATE)
	assert_not_null(relocate)
	assert_true(relocate.requires_move_reason and relocate.requires_lone_home and relocate.runs_until_done and relocate.selectable)
	assert_false(relocate.draws_jitter, "an action added after Phase 4 draws no number")
	assert_true(actions.get_action(NpcBehaviours.ACTION_SCAVENGE).blocked_while_moving and actions.get_action(NpcBehaviours.ACTION_WANDER).blocked_while_moving, "nothing sends a moving NPC back")
	assert_false(relocate.blocked_while_moving)
	# Survival first: a wound it can treat and a need in danger come before
	# the move, the move before a scavenging trip and a stroll.
	var needs: NpcNeedSettings = config.npc_needs
	var danger: float = needs.danger_threshold / needs.need_max
	var scavenge: NpcActionDefinition = actions.get_action(NpcBehaviours.ACTION_SCAVENGE)
	assert_true(relocate.base_priority + config.npc_decision.current_action_bonus < actions.get_action(NpcBehaviours.ACTION_TREAT).base_priority, "treating a wound comes first")
	assert_true(relocate.base_priority < danger, "eating and drinking in danger come first")
	assert_true(relocate.base_priority > scavenge.base_priority + scavenge.need_weight + scavenge.personality_weight + scavenge.environment_weight, "an NPC that wants to move does not go scavenging instead")


func test_the_relocation_component_round_trips_and_refuses_bad_documents() -> void:
	var state: NpcRelocationState = NpcRelocationState.new()
	assert_true(state.to_document().is_empty(), "an NPC that never moved saves nothing")
	var empty: NpcRelocationState = NpcRelocationState.new()
	assert_eq(empty.restore_document({NpcComponent.KEY_SCHEMA_VERSION: NpcRelocationState.SCHEMA_VERSION}).size(), 0, "and an empty document is a fresh component")
	assert_false(empty.is_moving())
	assert_eq(empty.last_settled_day, NpcRelocationState.NEVER)
	state.begin(NpcRelocationState.REASON_DANGER, 3)
	assert_true(state.is_moving() and not state.has_target())
	state.scan_index = 17
	var choosing: Dictionary = state.to_document()
	choosing[NpcComponent.KEY_SCHEMA_VERSION] = NpcRelocationState.SCHEMA_VERSION
	var choosing_again: NpcRelocationState = NpcRelocationState.new()
	assert_eq(choosing_again.restore_document(JSON.parse_string(JSON.stringify(choosing)) as Dictionary).size(), 0)
	assert_eq(choosing_again.scan_index, 17)
	assert_eq(choosing_again.phase, NpcRelocationState.PHASE_CHOOSING)
	state.phase = NpcRelocationState.PHASE_TRAVELLING
	state.target_building_id = "gen_p1_n2_0"
	state.target_tile = Vector2i(-73, 1204)
	state.scan_index = 0
	state.packed = true
	state.packed_units = 5
	state.leg_failures = 2
	state.from_here = true
	state.attacked = true
	state.last_settled_day = 4
	state.moves = 2
	state.no_choice_until_world_sec = 123456
	var document: Dictionary = state.to_document()
	document[NpcComponent.KEY_SCHEMA_VERSION] = NpcRelocationState.SCHEMA_VERSION
	var saved: Dictionary = JSON.parse_string(JSON.stringify(document)) as Dictionary
	var restored: NpcRelocationState = NpcRelocationState.new()
	assert_eq(restored.restore_document(saved).size(), 0, "; ".join(restored.restore_document(saved)))
	var again: Dictionary = restored.to_document()
	again[NpcComponent.KEY_SCHEMA_VERSION] = NpcRelocationState.SCHEMA_VERSION
	assert_eq(NpcLifeRun.first_difference(JSON.parse_string(JSON.stringify(again)), saved, "relocation"), "")
	assert_eq(restored.target_tile, Vector2i(-73, 1204))
	restored.clear_move()
	assert_false(restored.is_moving())
	assert_true(restored.attacked and restored.moves == 2 and restored.last_settled_day == 4, "what it knows stays when a move ends")
	restored.choose_again(9)
	assert_true(restored.from_here and restored.phase == NpcRelocationState.PHASE_CHOOSING and not restored.has_target())
	for change: Array in [
		[NpcRelocationState.KEY_PHASE, "strolling"], [NpcRelocationState.KEY_REASON, "boredom"], [NpcRelocationState.KEY_REASON, ""],
		[NpcRelocationState.KEY_TARGET, "Not An Id"], [NpcRelocationState.KEY_TARGET, ""], [NpcRelocationState.KEY_TARGET_TILE, [1.5, 2]],
		[NpcRelocationState.KEY_PHASE, NpcRelocationState.PHASE_CHOOSING], [NpcRelocationState.KEY_PHASE, ""],
		[NpcRelocationState.KEY_CONTAINER_INDEX, -2], [NpcRelocationState.KEY_PACKED_UNITS, 1.5], [NpcRelocationState.KEY_PACKED, 1],
		[NpcRelocationState.KEY_LAST_SETTLED_DAY, -2], [NpcRelocationState.KEY_MOVES, -1], [NpcComponent.KEY_SCHEMA_VERSION, 99],
	]:
		var bad: Dictionary = saved.duplicate(true)
		bad[change[0]] = change[1]
		var target: NpcRelocationState = NpcRelocationState.new()
		assert_true(target.restore_document(bad).size() > 0, "%s = %s is refused" % [change[0], str(change[1])])
		assert_false(target.is_moving(), "a refused document changes nothing")


## Three cells in a row, 50 m each: what the picker chooses from lists made
## by hand.
func test_the_picker_prefers_a_near_safe_house_with_things_to_search_around() -> void:
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(4, 0)]
	var lists: Dictionary = {
		Vector2i(0, 0): [_entry("gen_p0_p0_0", 10.0, "house"), _entry("gen_p0_p0_1", 40.0, "house")],
		Vector2i(1, 0): [_entry("gen_p1_p0_0", 60.0, "house"), _entry("gen_p1_p0_1", 70.0, "shop"), _entry("gen_p1_p0_2", 80.0, "shed")],
		Vector2i(2, 0): [_entry("gen_p2_p0_0", 120.0, "house")],
		Vector2i(4, 0): [_entry("gen_p4_p0_0", 220.0, "house"), _entry("gen_p4_p0_1", 225.0, "house"), _entry("gen_p4_p0_2", 230.0, "house"), _entry("gen_p4_p0_3", 235.0, "house"), _entry("gen_p4_p0_4", 240.0, "house")],
	}
	var asked: Array[int] = [0]
	var buildings_of: Callable = func(cell: Vector2i) -> Array: return lists.get(cell, [])
	var is_livable: Callable = func(entry: Dictionary) -> bool:
		asked[0] += 1
		return str(entry[NpcRelocationPicker.KEY_TYPE]) != "shed"
	var picker: NpcRelocationPicker = NpcRelocationPicker.new()
	var query: NpcRelocationPicker.Query = NpcRelocationPicker.Query.new()
	query.origin = Vector3(10.0, 0.0, 0.0)
	query.anchor = Vector3(10.0, 0.0, 0.0)
	query.min_distance_m = 20.0
	query.max_distance_m = 300.0
	query.home_building_id = "gen_p0_p0_0"
	query.danger_radius_m = 25.0
	query.danger_limit = 0.25
	query.danger_cost_m = 60.0
	query.house_types = PackedStringArray(["house"])
	query.other_type_cost_m = 40.0
	# Without a bonus for things to search: the nearest house that is far enough.
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p0_p0_1")
	assert_eq(picker.last_cell_count, 4)
	assert_eq(picker.last_building_count, 11)
	assert_eq(picker.last_candidate_count, 9, "not its home, not the shed")
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p0_p0_1", "the same again")
	# Taken, remembered as empty: the next.
	query.taken = {"gen_p0_p0_1": true}
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p1_p0_0")
	query.skip = {"gen_p1_p0_0": true}
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p1_p0_1", "a shop 60 m away (plus 40) before a house 110 m away")
	query.other_type_cost_m = 60.0
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p2_p0_0", "a house when the shop counts as farther")
	query.other_type_cost_m = 40.0
	# Too dangerous: not at all. A little dangerous: it counts as farther.
	query.danger_sources = [[Vector3(70.0, 0.0, 0.0), 0.5]]
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p2_p0_0", "the shop is too dangerous now")
	assert_eq(picker.last_avoided_count, 1)
	_near(NpcRelocationPicker.danger_at(Vector3(80.0, 0.0, 0.0), query), 0.3, 0.0001, "as NpcSurvivalSense.danger_at: weight x nearness")
	query.danger_sources = [[Vector3(70.0, 0.0, 0.0), 0.1]]
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p1_p0_1", "0.1 of danger is 6 m: still the shop")
	query.danger_sources = []
	# Out of range.
	query.min_distance_m = 100.0
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p2_p0_0")
	query.max_distance_m = 105.0
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "", "nothing between 100 and 105 m")
	query.allow_return = true
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p0_p0_0", "it goes back home when it may")
	query.allow_return = false
	query.min_distance_m = 20.0
	query.max_distance_m = 300.0
	query.taken = {}
	query.skip = {}
	# Things to search around (the buildings of its cell and of the cells
	# beside it, itself not counted): the house in the middle of five wins.
	query.prospect_bonus_m = 60.0
	query.prospect_cap = 8
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p1_p0_0")
	_near(picker.last_cost_m, 50.0 - 4.0 * 60.0, 0.001, "50 m less four buildings around it")
	query.prospect_cap = 2
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p0_p0_1", "the bonus is capped: the nearest wins again")
	_near(picker.last_cost_m, 30.0 - 2.0 * 60.0, 0.001, "")
	# A house with four neighbours 210 m away beats a house 30 m away with
	# nothing around it that is worth a search.
	query.prospect_cap = 8
	query.taken = {"gen_p1_p0_0": true, "gen_p1_p0_1": true, "gen_p1_p0_2": true, "gen_p2_p0_0": true}
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p4_p0_0")
	_near(picker.last_cost_m, 210.0 - 4.0 * 60.0, 0.001, "")
	query.taken = {}
	# Ties go to the smaller id.
	query.prospect_bonus_m = 0.0
	lists[Vector2i(0, 0)] = [_entry("gen_p0_p0_0", 10.0, "house"), _entry("gen_p0_p0_9", 40.0, "house"), _entry("gen_p0_p0_3", 40.0, "house")]
	assert_eq(picker.choose(cells, buildings_of, is_livable, query), "gen_p0_p0_3")
	assert_true(asked[0] > 0)


func _entry(id: String, x: float, type: String) -> Dictionary:
	return {NpcRelocationPicker.KEY_ID: id, NpcRelocationPicker.KEY_CENTER: Vector3(x, 0.0, 0.0), NpcRelocationPicker.KEY_TYPE: type}


# ------------------------------------------------------------ who lives where

func test_a_building_somebody_moves_to_is_taken_and_the_record_follows_the_move() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var service: NpcService = run.npcs()
	var npc_id: String = scene["npc_id"]
	var home_id: String = scene["home_id"]
	var neighbours: PackedStringArray = scene["neighbours"]
	var other_id: String = ""
	for definition_id: String in NpcRoster.load_or_null().npc_definition_ids:
		if definition_id != str(scene["definition_id"]):
			other_id = service.seeded_npc_id(ROSTER_ID, definition_id)
			break
	assert_true(service.is_seeded_home(home_id))
	assert_false(service.is_seeded_home(neighbours[0]))
	assert_true(service.to_world_document().get(NpcService.KEY_HOME_CLAIMS, {}).is_empty(), "nothing is claimed in a world where nobody moves")
	# A claim: taken for everybody else, kept by its holder.
	assert_true(service.claim_home(npc_id, neighbours[0]))
	assert_true(service.claim_home(npc_id, neighbours[0]), "the holder may ask again")
	assert_false(service.claim_home(other_id, neighbours[0]), "nobody else gets it")
	assert_false(service.claim_home(other_id, home_id), "nor a building somebody lives in")
	assert_false(service.claim_home("", neighbours[1]))
	assert_true(service.is_seeded_home(neighbours[0]))
	assert_eq(service.home_claim_holder(neighbours[0]), npc_id)
	assert_eq(service.claimed_homes_of(npc_id), PackedStringArray([neighbours[0]]))
	assert_true(service.taken_home_ids().has(neighbours[0]) and service.taken_home_ids().has(home_id))
	assert_eq(service.taken_home_ids().size(), NpcRoster.load_or_null().npc_definition_ids.size() + 1)
	# Saved with the world, and read back.
	var document: Dictionary = NpcLifeRun.as_saved(service.to_world_document())
	assert_eq((document[NpcService.KEY_HOME_CLAIMS] as Dictionary), {neighbours[0]: npc_id})
	for bad_claims: Variant in [[], {"Not An Id": npc_id}, {neighbours[0]: "nobody"}]:
		var bad: Dictionary = document.duplicate(true)
		bad[NpcService.KEY_HOME_CLAIMS] = bad_claims
		var errors: PackedStringArray = []
		service._read_home_claims(bad[NpcService.KEY_HOME_CLAIMS], errors)
		assert_true(errors.size() > 0, "claims %s are refused" % str(bad_claims))
	var read: PackedStringArray = []
	var claims: Dictionary[String, String] = service._read_home_claims(document[NpcService.KEY_HOME_CLAIMS], read)
	assert_eq(read.size(), 0)
	assert_eq(claims.size(), 1)
	assert_eq(str(claims.get(neighbours[0], "")), npc_id)
	# Somebody else's release does nothing; its own frees the building.
	service.release_home_claim(other_id, neighbours[0])
	assert_true(service.is_seeded_home(neighbours[0]))
	service.release_home_claim(npc_id, neighbours[0])
	assert_false(service.is_seeded_home(neighbours[0]))
	# Moving in: the roster record names the new building, the old is free.
	assert_true(service.claim_home(npc_id, neighbours[1]))
	service.settle_home(npc_id, neighbours[1])
	assert_eq(service.seeded_home(ROSTER_ID, str(scene["definition_id"])), neighbours[1])
	assert_true(service.is_seeded_home(neighbours[1]))
	assert_false(service.is_seeded_home(home_id), "the old home is free")
	assert_eq(service.claimed_homes_of(npc_id).size(), 0, "the record keeps it taken now, not a claim")
	service.settle_home(npc_id, neighbours[1])
	assert_eq(service.seeded_home(ROSTER_ID, str(scene["definition_id"])), neighbours[1], "again changes nothing")
	assert_eq(service.pending_relocation_count(), 0, "nothing wants to put it back")
	# An NPC that is in no roster: its claim is what keeps its home taken.
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	var layout: NpcHomeLayout = NpcHomeLayout.of(_map(run.world).generator().building_by_id(neighbours[2]).definition)
	var spawned: ActionResult = service.spawn_npc(run.world, str(scene["definition_id"]), grid.tile_center(layout.home_tile()))
	assert_true(spawned.ok, spawned.reason)
	var loner_id: String = str(spawned.event[NpcService.KEY_NPC_ID])
	service.settle_home(loner_id, neighbours[2])
	assert_eq(service.home_claim_holder(neighbours[2]), loner_id)
	assert_true(service.claim_home(loner_id, home_id), "it moves to the house the other left")
	service.settle_home(loner_id, home_id)
	assert_eq(service.claimed_homes_of(loner_id), PackedStringArray([home_id]))
	assert_false(service.is_seeded_home(neighbours[2]))
	# An NPC that is removed from the world holds nothing.
	assert_true(service.remove_npc(run.world, loner_id).ok)
	assert_false(service.is_seeded_home(home_id))
	_no_errors()
	run.finish()


## The record and the claims are saved with the world, the NPC's home and
## move with its cell: after a crash between two saves they can disagree.
func test_when_an_npc_wakes_the_world_is_brought_in_line_with_what_the_npc_knows() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var npc_id: String = scene["npc_id"]
	var home_id: String = scene["home_id"]
	var neighbours: PackedStringArray = scene["neighbours"]
	var npc: NpcState = service.get_npc(npc_id)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var move: NpcRelocationState = _move_of(run, npc_id)
	var definition_id: String = scene["definition_id"]
	run.behaviours.cancel(world, service, npc)
	# Nothing to do for an NPC that is where the world thinks it is.
	relocation.on_npc_woke(world, service, npc)
	assert_eq(service.seeded_home(ROSTER_ID, definition_id), home_id)
	assert_eq(service.claimed_homes_of(npc_id).size(), 0)
	# The world's save is newer than the NPC's: the record names a building
	# the NPC never moved into.
	service.settle_home(npc_id, neighbours[0])
	assert_false(service.is_seeded_home(home_id))
	relocation.on_npc_woke(world, service, npc)
	assert_eq(service.seeded_home(ROSTER_ID, definition_id), home_id, "the record follows the NPC")
	assert_false(service.is_seeded_home(neighbours[0]), "and the other building is free")
	# The NPC's save is newer: it is on its way, the world has no claim.
	var layout: NpcHomeLayout = NpcHomeLayout.of(_map(world).generator().building_by_id(neighbours[1]).definition)
	move.begin(NpcRelocationState.REASON_DANGER, 0)
	move.phase = NpcRelocationState.PHASE_TRAVELLING
	move.target_building_id = neighbours[1]
	move.target_tile = layout.home_tile()
	relocation.on_npc_woke(world, service, npc)
	assert_eq(service.home_claim_holder(neighbours[1]), npc_id, "the building it moves to is claimed again")
	assert_eq(move.target_building_id, neighbours[1])
	# Somebody else took the building meanwhile: it chooses again.
	service.release_home_claim(npc_id, neighbours[1])
	assert_true(service.claim_home("npc_999999", neighbours[1]))
	relocation.on_npc_woke(world, service, npc)
	assert_eq(service.home_claim_holder(neighbours[1]), "npc_999999", "it does not take what is somebody else's")
	assert_true(move.phase == NpcRelocationState.PHASE_CHOOSING and not move.has_target() and move.from_here, "it chooses again from where it stands")
	assert_eq(NpcScavengeState.of(npc).result_of(neighbours[1]), "", "the building is not blocked, only taken")
	# A claim that is left over from a move that is over is given up.
	move.clear_move()
	assert_true(service.claim_home(npc_id, neighbours[2]))
	relocation.on_npc_woke(world, service, npc)
	assert_false(service.is_seeded_home(neighbours[2]))
	assert_eq(service.seeded_home(ROSTER_ID, definition_id), home_id)
	_no_errors()
	run.finish()


# ------------------------------------------------------------ when

func test_an_npc_wants_to_move_only_for_a_reason_and_its_personality_sets_the_limits() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var npc_id: String = scene["npc_id"]
	var npc: NpcState = service.get_npc(npc_id)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var sense: NpcSurvivalSense = run.decider.survival()
	assert_not_null(relocation, "the shipped composition has the moves")
	if relocation == null:
		return
	var settings: NpcRelocationSettings = relocation.settings
	var move: NpcRelocationState = _move_of(run, npc_id)
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	var home_center: Vector3 = _center(run, str(scene["home_id"]))
	run.behaviours.cancel(world, service, npc)
	# An empty house alone is no reason: there may be things around it.
	assert_eq(relocation.move_reason(world, npc), "")
	assert_false(relocation.wants_to_move(npc))
	# Nothing left: it searched its home, found nothing to search twice, and
	# has little food.
	trip.note_visit(str(scene["home_id"]), NpcScavengeState.RESULT_EMPTY, 0, 48)
	trip.no_target_streak = settings.exhausted_tries - 1
	assert_eq(relocation.move_reason(world, npc), "", "one trip without a building is not enough")
	trip.no_target_streak = settings.exhausted_tries
	assert_eq(relocation.move_reason(world, npc), NpcRelocationState.REASON_NO_SUPPLIES)
	assert_true(relocation.wants_to_move(npc))
	var floor_units: int = relocation.food_floor(npc)
	assert_true(floor_units >= 1 and floor_units < sense.food_target(npc), "it leaves before its food is gone, with less than it wants to have (%d of %d)" % [floor_units, sense.food_target(npc)])
	_put(world, _containers_of(world, str(scene["home_id"]))[0].inventory_id, FOOD, floor_units + 1)
	assert_eq(relocation.move_reason(world, npc), "", "with food enough it stays")
	_drop_all(world, _containers_of(world, str(scene["home_id"]))[0].inventory_id)
	_put(world, run.behaviour_of(npc_id).inventory_id, FOOD, floor_units)
	assert_eq(relocation.move_reason(world, npc), NpcRelocationState.REASON_NO_SUPPLIES, "what it carries counts like what is at home")
	trip.no_target_streak = 0
	assert_eq(relocation.move_reason(world, npc), "")
	# Repeated danger at home. One zombie seen is not enough for anybody.
	var limit: float = relocation.home_danger_limit(npc)
	assert_true(limit >= settings.home_danger_threshold * 0.5 - 0.0001 and limit <= settings.home_danger_threshold * 2.0 + 0.0001, "between half and twice the setting (%.3f)" % limit)
	assert_true(sense.note_zombie_seen(world, npc, home_center))
	assert_true(sense.danger_at(npc, home_center, world.clock.world_time_sec) < settings.home_danger_threshold * 0.5, "one sighting is below the lowest limit anybody has (%.2f)" % sense.danger_at(npc, home_center, world.clock.world_time_sec))
	assert_eq(relocation.move_reason(world, npc), "", "one zombie seen at home moves nobody")
	var seen: int = 1 + _see_zombies_until(run, npc, home_center, limit)
	assert_true(sense.danger_at(npc, home_center, world.clock.world_time_sec) >= limit, "test setup: %d sightings are over its limit" % seen)
	assert_true(seen >= 2)
	assert_eq(relocation.move_reason(world, npc), NpcRelocationState.REASON_DANGER, "zombies seen at home again and again (%d)" % seen)
	# It just moved in: danger does not make it move again at once, nor
	# little food (but no food at all does).
	move.last_settled_day = 0
	assert_eq(relocation.move_reason(world, npc), "", "not within a day of moving in")
	trip.no_target_streak = settings.exhausted_tries
	assert_eq(relocation.move_reason(world, npc), "", "with a little food it gives the new place a day")
	_drop_all(world, run.behaviour_of(npc_id).inventory_id)
	assert_eq(relocation.move_reason(world, npc), NpcRelocationState.REASON_NO_SUPPLIES, "without any food it does not wait")
	trip.no_target_streak = 0
	# ... but being attacked does (F-32's hook), and that comes first.
	assert_true(relocation.note_attacked(service, npc))
	assert_eq(relocation.move_reason(world, npc), NpcRelocationState.REASON_ATTACKED)
	move.attacked = false
	# Badly hurt at home by a zombie: also right after it moved in.
	var vitals: NpcVitals = NpcVitals.of(npc)
	var hurt_limit: float = relocation.hurt_health_limit(npc)
	assert_true(hurt_limit > 0.0 and hurt_limit < 1.0)
	vitals.health = vitals.max_health() * hurt_limit * 0.9
	assert_eq(relocation.move_reason(world, npc), "", "hurt, but it remembers no zombie's hit at home")
	sense.on_npc_damaged(npc_id, "zombie_1")
	assert_eq(relocation.move_reason(world, npc), NpcRelocationState.REASON_HURT)
	vitals.health = vitals.max_health()
	assert_eq(relocation.move_reason(world, npc), "", "with a scratch it stays")
	move.last_settled_day = NpcRelocationState.NEVER
	assert_eq(relocation.move_reason(world, npc), NpcRelocationState.REASON_DANGER)
	# Danger fades: two days later the same memories are too weak.
	var later: float = world.clock.world_time_sec + sense.settings.danger_half_life_world_sec * 4.0
	assert_true(sense.danger_at(npc, home_center, later) < settings.home_danger_threshold * 0.5, "four half-lives later the danger is forgotten (%.2f)" % sense.danger_at(npc, home_center, later))
	# It found nowhere to go: it does not ask again for a while.
	assert_true(relocation.wants_to_move(npc))
	move.no_choice_until_world_sec = floori(world.clock.world_time_sec) + 100
	assert_false(relocation.wants_to_move(npc))
	move.no_choice_until_world_sec = 0
	# A dead NPC wants nothing.
	vitals.health = 0.0
	vitals.died_at_world_time = world.clock.world_time_sec
	assert_eq(relocation.move_reason(world, npc), "")
	_no_errors()
	run.finish()


func test_the_limits_follow_the_personality() -> void:
	var run: NpcLifeRun = NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural())
	assert_not_null(run)
	if run == null:
		return
	var relocation: NpcRelocation = run.behaviours.relocation()
	var service: NpcService = run.npcs()
	var settings: NpcRelocationSettings = relocation.settings
	var definitions: NpcCatalog = CompositionConfig.from_defaults().npc_definitions
	var seen: int = 0
	var lowest: float = INF
	var highest: float = 0.0
	for definition_id: String in NpcRoster.load_or_null().npc_definition_ids:
		var layout: NpcHomeLayout = NpcHomeLayout.of(_map(run.world).generator().building_by_id(service.seeded_home(ROSTER_ID, definition_id)).definition)
		run.observer.position = StructureGrid.new(MODULE_M).tile_center(layout.home_tile())
		run.run_ticks(ARRIVE_TICKS)
		var npc: NpcState = service.get_npc(service.seeded_npc_id(ROSTER_ID, definition_id))
		assert_not_null(npc, "test setup: %s is in memory" % definition_id)
		if npc == null:
			continue
		var definition: NpcDefinition = definitions.get_definition(definition_id)
		var lean: float = clampf(definition.risk_tolerance + definition.courage - definition.neuroticism - 0.5, -1.0, 1.0)
		_near(relocation.home_danger_limit(npc), settings.home_danger_threshold * pow(2.0, lean), 0.0001, "%s: daring, brave and calm stays longer" % definition_id)
		_near(relocation.hurt_health_limit(npc), settings.hurt_health_fraction * (1.5 - definition.courage), 0.0001, "%s: the brave stay until they are worse off" % definition_id)
		assert_eq(relocation.food_floor(npc), clampi(roundi(float(settings.move_when_food_at_most) * (1.5 - definition.risk_tolerance)), 0, run.decider.survival().food_target(npc) - 1), "%s: the cautious leave with more food left" % definition_id)
		lowest = minf(lowest, relocation.home_danger_limit(npc))
		highest = maxf(highest, relocation.home_danger_limit(npc))
		seen += 1
	assert_eq(seen, NpcRoster.load_or_null().npc_definition_ids.size())
	assert_true(highest > lowest, "the NPCs of the roster do not all have the same limit (%.2f .. %.2f)" % [lowest, highest])
	print("[f30] danger at home at which the ten NPCs of the roster leave: %.2f .. %.2f (setting %.2f)" % [lowest, highest, settings.home_danger_threshold])
	run.finish()


# ------------------------------------------------------------ the move

func test_a_rural_npc_with_nothing_left_packs_moves_to_another_building_and_lives_there() -> void:
	# (The containers of the building it chooses are left as they are: the
	# NPC searches them when it moves in.)
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()), true, false)
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var npc_id: String = scene["npc_id"]
	var home_id: String = scene["home_id"]
	var npc: NpcState = service.get_npc(npc_id)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var sense: NpcSurvivalSense = run.decider.survival()
	var carried: String = run.behaviour_of(npc_id).inventory_id
	# [food, water] it carried when it stood on its new home tile.
	var brought: Array[int] = [-1, -1]
	# What is left in its house: a little food, water, a bandage, nails.
	var box: ContainerInstance = _containers_of(world, home_id)[0]
	_put(world, box.inventory_id, FOOD, 2)
	_put(world, box.inventory_id, WATER, 2)
	_put(world, box.inventory_id, BANDAGE, 1)
	_put(world, box.inventory_id, NAILS, 3)
	_knows_everything_is_empty(run, scene)
	assert_true(2 <= relocation.food_floor(npc), "test setup: two rations are little for it (%d)" % relocation.food_floor(npc))
	assert_eq(relocation.move_reason(world, npc), "", "it does not know yet that there is nothing to search")
	var started: Array[String] = []
	var chosen: Array[String] = []
	var relocated: Array[Array] = []
	var finished: Array[Dictionary] = []
	var started_tick: Array[int] = [-1]
	relocation.move_started.connect(func(moved_id: String, reason: String) -> void:
		if moved_id == npc_id:
			started.append(reason)
			started_tick[0] = run.tick)
	relocation.destination_chosen.connect(func(moved_id: String, building_id: String) -> void:
		if moved_id == npc_id:
			chosen.append(building_id))
	relocation.npc_relocated.connect(func(moved_id: String, from_id: String, to_id: String, reason: String) -> void:
		if moved_id == npc_id:
			relocated.append([from_id, to_id, reason, run.tick]))
	run.behaviours.behaviour_finished.connect(func(done_id: String, action_id: String, info: Dictionary) -> void:
		if done_id == npc_id and action_id == RELOCATE:
			finished.append(info.duplicate()))
	var phases: Array[String] = []
	var eaten_before: int = run.behaviour_of(npc_id).count_of("eat")
	var move: NpcRelocationState = _move_of(run, npc_id)
	var done: bool = _run_until(run, func() -> bool:
		if move.is_moving() and (phases.is_empty() or phases[phases.size() - 1] != move.phase):
			phases.append(move.phase)
		if move.phase == NpcRelocationState.PHASE_SETTLING:
			brought[0] = _units(world, carried, FOOD)
			brought[1] = _units(world, carried, WATER)
		return not relocated.is_empty(), npc_id)
	assert_true(done, "it moved within %d ticks (reason now '%s', phase '%s', streak %d, events %s)" % [PATIENCE_TICKS, relocation.move_reason(world, npc), move.phase, NpcScavengeState.of(npc).no_target_streak, _tail(run)])
	if not done:
		return
	var to_id: String = str(relocated[0][1])
	var eaten: int = run.behaviour_of(npc_id).count_of("eat") - eaten_before
	print("[f30] a rural NPC with nothing left: decided at tick %d, moved in at tick %d, %s -> %s, %.1f m, %d legs, phases %s, packed %d units, %d cells listed (slowest tick of that %.3f ms), choice %.3f ms among %d buildings (%d candidates)" % [
		started_tick[0], int(relocated[0][3]), home_id, to_id, _flat(_center(run, home_id), _center(run, to_id)), relocation.leg_count, str(phases), int(finished[0][NpcRelocation.INFO_PACKED]) if not finished.is_empty() else -1,
		relocation.scanned_cell_count, float(relocation.max_scan_usec) / 1000.0, float(relocation.max_choose_usec) / 1000.0, relocation.picker().last_building_count, relocation.picker().last_candidate_count])
	assert_eq(started, ["no_supplies"] as Array[String], "its own decision, for one reason, once")
	assert_eq(str(relocated[0][0]), home_id)
	assert_eq(str(relocated[0][2]), NpcRelocationState.REASON_NO_SUPPLIES)
	assert_eq(chosen, [to_id] as Array[String], "the building it chose is the one it lives in")
	assert_eq(phases, ["choosing", "packing", "travelling", "settling"] as Array[String])
	assert_ne(to_id, home_id)
	# Where: a building an NPC can live in, that it did not know as empty,
	# within the travel distance.
	var generator: ProceduralMapGenerator = _map(world).generator()
	assert_true(NpcHomePicker.is_home(generator.building_by_id(to_id)))
	assert_false((scene["neighbours"] as PackedStringArray).has(to_id), "not one of the buildings it has emptied")
	var distance: float = _flat(_center(run, home_id), _center(run, to_id))
	assert_true(distance >= relocation.settings.min_distance_m and distance <= relocation.settings.max_distance_m, "%.1f m" % distance)
	# It lives there: its component, the roster record, the spots it uses.
	var home: NpcHome = NpcHome.of(npc)
	var layout: NpcHomeLayout = NpcHomeLayout.of(generator.building_by_id(to_id).definition)
	assert_eq(home.building_id, to_id)
	assert_eq(home.tile, layout.home_tile())
	assert_eq(StructureGrid.new(MODULE_M).tile_of(npc.position), layout.home_tile(), "it stands on its new home tile")
	assert_eq(service.seeded_home(ROSTER_ID, str(scene["definition_id"])), to_id, "the roster record follows")
	assert_true(service.is_seeded_home(to_id))
	assert_false(service.is_seeded_home(home_id), "the old house is free")
	assert_eq(service.claimed_homes_of(npc_id).size(), 0)
	assert_eq(service.pending_relocation_count(), 0, "nothing wants to put it back")
	assert_false(move.is_moving())
	assert_eq(move.moves, 1)
	assert_true(sense.homes().home_building_id(npc, service.definition_of(npc_id)) == to_id)
	# What it took along: food, water and the bandage, not the nails.
	assert_eq(_units_in_building(world, home_id, NAILS), 3, "what is of no use to it stays behind")
	assert_eq(_units_in_building(world, home_id, FOOD) + _units_in_building(world, home_id, WATER) + _units_in_building(world, home_id, BANDAGE), 0, "the old house is packed up")
	assert_eq(brought[0] + eaten, 2, "the food came along (or was eaten on the way)")
	assert_eq(brought[1], 2, "and the water")
	assert_true(_units_in_building(world, to_id, FOOD) >= brought[0] and _units_in_building(world, to_id, WATER) >= brought[1], "what it brought is in the new house (with whatever was there)")
	assert_eq(_units(world, carried, BANDAGE), 1, "the bandage stays on it")
	assert_eq(_units(world, carried, FOOD) + _units(world, carried, WATER), 0, "food and water are put away in the new house")
	assert_eq(finished.size(), 1)
	if not finished.is_empty():
		assert_eq(str(finished[0][NpcRelocation.INFO_TO]), to_id)
		assert_eq(str(finished[0][NpcRelocation.INFO_FROM]), home_id)
		var packed: int = int(finished[0][NpcRelocation.INFO_PACKED])
		assert_true(packed >= 3 and packed <= 5, "two rations (less one it had taken out to eat), two bottles, one bandage (%d)" % packed)
		assert_eq(int(finished[0][NpcRelocation.INFO_STOWED]), brought[0] + brought[1], "it put away what it brought")
	for container: ContainerInstance in _containers_of(world, to_id):
		assert_true(container != null and container.searched, "the containers of the new house were searched")
	assert_eq(relocation.move_reason(world, npc), "", "it has no reason to move on")
	# And it goes on living there: it uses what the new house has, and looks
	# around it.
	var used: Array[String] = []
	run.behaviours.behaviour_started.connect(func(started_id: String, _action_id: String, info: Dictionary) -> void:
		if started_id == npc_id and info.has(NpcBehaviours.INFO_SPOT):
			used.append(str(info[NpcBehaviours.INFO_SPOT])))
	var trip: NpcScavengeState = NpcScavengeState.of(npc)
	var lived: bool = _run_until(run, func() -> bool: return not used.is_empty() and not trip.result_of(to_id).is_empty(), npc_id, LIVING_TICKS)
	assert_true(lived, "it used a spot of its new house and searched it (used %s, visited %s, events %s)" % [str(used), str(trip.visited.slice(maxi(trip.visited.size() - 3, 0))), _tail(run)])
	for spot_id: String in used:
		assert_eq(NpcHomeLayout.building_id_of_spot(spot_id), to_id, "every spot it uses is one of its new house (%s)" % spot_id)
	assert_eq(home.building_id, to_id, "it did not move again")
	assert_eq(relocated.size(), 1)
	_no_errors()
	run.finish()


func test_an_npc_leaves_a_house_where_it_saw_zombies_again_and_again() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var npc_id: String = scene["npc_id"]
	var home_id: String = scene["home_id"]
	var npc: NpcState = service.get_npc(npc_id)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var sense: NpcSurvivalSense = run.decider.survival()
	var home_center: Vector3 = _center(run, home_id)
	# A house with everything it wants: it has no other reason to leave.
	var box: ContainerInstance = _containers_of(world, home_id)[0]
	_put(world, box.inventory_id, FOOD, 5)
	_put(world, box.inventory_id, FOOD, 5)
	_put(world, run.behaviour_of(npc_id).inventory_id, BANDAGE, 1)
	run.run_ticks(200)
	assert_false(_move_of(run, npc_id).is_moving(), "a quiet house: it stays")
	assert_eq(relocation.started_count, 0)
	# Zombies seen around the house, again and again.
	var limit: float = relocation.home_danger_limit(npc)
	var seen: int = _see_zombies_until(run, npc, home_center, limit)
	assert_true(seen >= 2, "one sighting is not enough (%d)" % seen)
	assert_eq(relocation.move_reason(world, npc), NpcRelocationState.REASON_DANGER, "test setup: %d sightings" % seen)
	var relocated: Array[Array] = []
	relocation.npc_relocated.connect(func(moved_id: String, from_id: String, to_id: String, reason: String) -> void:
		if moved_id == npc_id:
			relocated.append([from_id, to_id, reason]))
	var eaten_before: int = run.behaviour_of(npc_id).count_of("eat")
	var done: bool = _run_until(run, func() -> bool: return not relocated.is_empty(), npc_id)
	assert_true(done, "it moved (phase '%s', events %s)" % [_move_of(run, npc_id).phase, _tail(run)])
	if not done:
		return
	var to_id: String = str(relocated[0][1])
	var distance: float = _flat(home_center, _center(run, to_id))
	print("[f30] zombies at home: %d sightings (danger %.2f, its limit %.2f), moved %.1f m to %s in %d legs" % [seen, sense.danger_at(npc, home_center, world.clock.world_time_sec), limit, distance, to_id, relocation.leg_count])
	assert_eq(str(relocated[0][2]), NpcRelocationState.REASON_DANGER)
	assert_true(distance >= relocation.settings.danger_min_distance_m, "it went well away from the danger (%.1f m)" % distance)
	assert_true(sense.danger_at(npc, _center(run, to_id), world.clock.world_time_sec) < sense.danger_limit(npc), "to a place it does not remember as dangerous")
	assert_eq(NpcHome.of(npc).building_id, to_id)
	assert_eq(service.seeded_home(ROSTER_ID, str(scene["definition_id"])), to_id)
	assert_false(service.is_seeded_home(home_id))
	var eaten: int = run.behaviour_of(npc_id).count_of("eat") - eaten_before
	var capacity: int = run.behaviour_of(npc_id).capacity()
	assert_true(_units_in_building(world, to_id, FOOD) >= 1, "it brought food along")
	assert_eq(_units_in_building(world, to_id, FOOD) + _units_in_building(world, home_id, FOOD) + _units(world, run.behaviour_of(npc_id).inventory_id, FOOD) + eaten, 10, "no food appeared or vanished (it carries %d slots)" % capacity)
	assert_eq(relocation.move_reason(world, npc), "", "the new house is quiet")
	_no_errors()
	run.finish()


func test_two_npcs_never_take_the_same_building() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var first_id: String = scene["npc_id"]
	var relocation: NpcRelocation = run.behaviours.relocation()
	var generator: ProceduralMapGenerator = _map(world).generator()
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	# A second NPC, living next door.
	var next_door: String = ""
	for building_id: String in (scene["neighbours"] as PackedStringArray):
		if NpcHomePicker.is_home(generator.building_by_id(building_id)):
			next_door = building_id
			break
	assert_false(next_door.is_empty(), "test setup: a building next door somebody can live in")
	if next_door.is_empty():
		return
	var layout: NpcHomeLayout = NpcHomeLayout.of(generator.building_by_id(next_door).definition)
	var spawned: ActionResult = service.spawn_npc(world, str(scene["definition_id"]), grid.tile_center(layout.home_tile()))
	assert_true(spawned.ok, spawned.reason)
	var second_id: String = str(spawned.event[NpcService.KEY_NPC_ID])
	var second: NpcState = service.get_npc(second_id)
	NpcHome.of(second).set_generated(next_door, layout.home_tile())
	service.settle_home(second_id, next_door)
	assert_true(service.is_seeded_home(next_door))
	var first: NpcState = service.get_npc(first_id)
	# Both are driven out at the same moment.
	assert_true(relocation.note_attacked(service, first) and relocation.note_attacked(service, second))
	_move_of(run, first_id).reason = NpcRelocationState.REASON_ATTACKED
	_move_of(run, second_id).reason = NpcRelocationState.REASON_ATTACKED
	var first_choice: String = relocation.choose_destination(world, service, first)
	var second_choice: String = relocation.choose_destination(world, service, second)
	assert_false(first_choice.is_empty() or second_choice.is_empty(), "test setup: both find a building")
	# Whatever the second would choose: once it is claimed for the first, the
	# second chooses another.
	assert_true(service.claim_home(first_id, second_choice))
	var second_again: String = relocation.choose_destination(world, service, second)
	assert_ne(second_again, second_choice, "a building claimed for another NPC is not chosen")
	assert_false(second_again.is_empty())
	service.release_home_claim(first_id, second_choice)
	_move_of(run, first_id).reason = ""
	_move_of(run, second_id).reason = ""
	print("[f30] two neighbours driven out: alone the first would go to %s, the second to %s (%s)" % [first_choice, second_choice, "the same building" if first_choice == second_choice else "not the same"])
	var relocated: Dictionary = {}
	relocation.npc_relocated.connect(func(moved_id: String, _from_id: String, to_id: String, _reason: String) -> void: relocated[moved_id] = to_id)
	var same_target_ticks: Array[int] = [0]
	var done: bool = _run_until(run, func() -> bool:
		var a: NpcRelocationState = _move_of(run, first_id)
		var b: NpcRelocationState = _move_of(run, second_id)
		if a.has_target() and b.has_target() and a.target_building_id == b.target_building_id:
			same_target_ticks[0] += 1
		for moving: NpcRelocationState in [a, b]:
			if moving.has_target():
				assert_true(service.is_seeded_home(moving.target_building_id), "a building somebody moves to is taken")
		return relocated.size() == 2, first_id)
	assert_true(done, "both moved (%s; phases '%s' / '%s'; events %s)" % [str(relocated), _move_of(run, first_id).phase, _move_of(run, second_id).phase, _tail(run)])
	if not done:
		return
	assert_eq(same_target_ticks[0], 0, "they never moved to the same building")
	assert_ne(str(relocated[first_id]), str(relocated[second_id]), "and do not live in the same building")
	assert_eq(_home_of(run, first_id), str(relocated[first_id]))
	assert_eq(_home_of(run, second_id), str(relocated[second_id]))
	assert_eq(service.seeded_home(ROSTER_ID, str(scene["definition_id"])), str(relocated[first_id]), "the roster record names the home of its own NPC")
	assert_eq(service.claimed_homes_of(second_id), PackedStringArray([str(relocated[second_id])]), "the other keeps its home by its claim")
	assert_false(service.is_seeded_home(str(scene["home_id"])) or service.is_seeded_home(next_door), "both old houses are free")
	_no_errors()
	run.finish()


# ------------------------------------------------------------ interrupted

## A scene in which the NPC was driven out of a house that holds three
## rations, and is on its way: {scene..., target, run}. {} when it failed.
func _on_the_way(run: NpcLifeRun, min_from_home_m: float = 12.0) -> Dictionary:
	var scene: Dictionary = _scene(run)
	if scene.is_empty():
		return {}
	var world: ServerWorld = run.world
	var npc_id: String = scene["npc_id"]
	var npc: NpcState = run.npcs().get_npc(npc_id)
	_put(world, _containers_of(world, str(scene["home_id"]))[0].inventory_id, FOOD, 3)
	_put(world, run.behaviour_of(npc_id).inventory_id, BANDAGE, 1)
	assert_true(run.behaviours.relocation().note_attacked(run.npcs(), npc))
	var move: NpcRelocationState = _move_of(run, npc_id)
	var executor: NpcExecutor = run.behaviours.movement_executor()
	var walking: bool = _run_until(run, func() -> bool:
		return move.phase == NpcRelocationState.PHASE_TRAVELLING and executor.phase_of(npc_id) == NpcExecutorState.PHASE_MOVING and _flat(npc.position, scene["home_position"]) > min_from_home_m, npc_id)
	assert_true(walking, "test setup: it is on its way (phase '%s', events %s)" % [move.phase, _tail(run)])
	if not walking:
		return {}
	scene["target"] = move.target_building_id
	return scene


func test_a_move_goes_on_after_a_save_and_a_restart() -> void:
	var first: NpcLifeRun = NpcLifeRun.begin_on_disk(WORLD, _root, TICK, _procedural())
	var scene: Dictionary = _on_the_way(first)
	if scene.is_empty():
		return
	var npc_id: String = scene["npc_id"]
	var home_id: String = scene["home_id"]
	var target: String = scene["target"]
	var world: ServerWorld = first.world
	var npc: NpcState = first.npcs().get_npc(npc_id)
	assert_true(first.npcs().is_seeded_home(target), "the building is claimed for it")
	assert_eq(first.persistence.save(world), OK)
	var saved: Dictionary = NpcLifeRun.as_saved(first.npcs().npc_document(npc_id))
	var saved_position: Vector3 = npc.position
	assert_eq(NpcLifeRun.copy_tree(ProjectSettings.globalize_path(_root), ProjectSettings.globalize_path(_root + "_copy")), OK, "test setup: a copy of the save")
	# The server that was not stopped finishes the move.
	var move: NpcRelocationState = _move_of(first, npc_id)
	var done: bool = _run_until(first, func() -> bool: return not move.is_moving(), npc_id)
	assert_true(done, "the move ends on the server that went on (events %s)" % _tail(first))
	var expected: Dictionary = _outcome(first, npc_id, home_id, target)
	first.finish()

	# The restarted server: the same NPC, in the middle of the same move.
	var second: NpcLifeRun = NpcLifeRun.begin_on_disk(WORLD, _root + "_copy", TICK, _procedural())
	assert_not_null(second, "the save loads")
	if second == null:
		return
	assert_true(second.npcs().is_seeded_home(target), "the claim is in the world's save: the building is taken")
	assert_eq(second.npcs().home_claim_holder(target), npc_id)
	_to_empty.append(target)
	second.observer.position = saved_position
	var arrived: bool = _run_until(second, func() -> bool: return second.npcs().get_npc(npc_id) != null)
	assert_true(arrived, "the NPC comes into memory")
	if not arrived:
		return
	var restored_npc: NpcState = second.npcs().get_npc(npc_id)
	var restored: Dictionary = NpcLifeRun.as_saved(second.npcs().npc_document(npc_id))
	var compared: bool = not second.npcs().is_awake(npc_id) or second.tick <= 1
	print("[f30] restart in the middle of a move: the NPC is in memory at tick %d; its saved components are compared bit for bit: %s" % [second.tick, "yes" if compared else "no (it took a step already)"])
	if compared:
		# Looked at before it took a step: the document is the saved one.
		for component_id: String in [NpcRelocationState.COMPONENT_ID, NpcScavengeState.COMPONENT_ID, NpcHome.COMPONENT_ID, NpcBehaviourState.COMPONENT_ID, NpcExecutorState.COMPONENT_ID]:
			assert_eq(NpcLifeRun.first_difference((restored[NpcState.KEY_COMPONENTS] as Dictionary)[component_id], (saved[NpcState.KEY_COMPONENTS] as Dictionary)[component_id], component_id), "", "%s is as it was saved" % component_id)
	var restored_move: NpcRelocationState = NpcRelocationState.of(restored_npc)
	assert_eq(restored_move.phase, NpcRelocationState.PHASE_TRAVELLING)
	assert_eq(restored_move.target_building_id, target, "it is still on its way to the same building")
	assert_true(restored_move.packed, "with what it packed")
	assert_true(_flat(restored_npc.position, saved_position) < 3.0, "about where it was (%.2f m)" % _flat(restored_npc.position, saved_position))
	assert_true(second.behaviour_of(npc_id).is_running() and second.behaviour_of(npc_id).action_id == RELOCATE)
	assert_eq(NpcHome.of(restored_npc).building_id, home_id, "it still lives in the old house")
	var failures_before: int = second.behaviours.failed_count
	var starts_before: int = second.behaviours.relocation().started_count
	done = _run_until(second, func() -> bool: return not restored_move.is_moving(), npc_id)
	assert_true(done, "the move ends on the restarted server too (events %s)" % _tail(second))
	assert_eq(second.behaviours.failed_count, failures_before, "without a failure")
	assert_eq(second.behaviours.relocation().started_count, starts_before, "the same move, not a new one")
	assert_eq(second.behaviours.relocation().chosen_count, 0, "it did not choose again")
	assert_eq(_outcome(second, npc_id, home_id, target), expected, "the restarted server ends the move as the other did")
	assert_eq(str(expected["home"]), target)
	assert_eq(int(expected["food"]), 3)
	assert_true(bool(expected["old_home_free"]) and bool(expected["new_home_taken"]))
	_no_errors()
	second.finish()


## What a finished move left: where the NPC lives, what the world knows,
## and where the food is.
func _outcome(run: NpcLifeRun, npc_id: String, old_home_id: String, target: String) -> Dictionary:
	var world: ServerWorld = run.world
	var move: NpcRelocationState = _move_of(run, npc_id)
	var definition_id: String = run.npcs().get_npc(npc_id).definition_id
	return {
		"home": _home_of(run, npc_id),
		"home_tile": NpcHome.of(run.npcs().get_npc(npc_id)).tile,
		"record": run.npcs().seeded_home(ROSTER_ID, definition_id),
		"old_home_free": not run.npcs().is_seeded_home(old_home_id),
		"new_home_taken": run.npcs().is_seeded_home(target),
		"claims": run.npcs().claimed_homes_of(npc_id).size(),
		"food": _units_in_building(world, target, FOOD) + _units(world, run.behaviour_of(npc_id).inventory_id, FOOD) + run.behaviour_of(npc_id).count_of("eat"),
		"food_left_behind": _units_in_building(world, old_home_id, FOOD),
		"bandages": _units(world, run.behaviour_of(npc_id).inventory_id, BANDAGE),
		"relocation": NpcLifeRun.as_saved(move.to_document()),
		"moves": move.moves,
	}


func test_a_move_goes_on_after_the_npcs_cell_left_memory() -> void:
	var scene: Dictionary = _on_the_way(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var npc_id: String = scene["npc_id"]
	var target: String = scene["target"]
	var relocation: NpcRelocation = run.behaviours.relocation()
	# The player goes far away: the NPC's cell is saved and released. Nothing
	# happens to it while it is away (no far simulation, docs/15 F29-011).
	run.observer.position = FAR_AWAY
	var last: Array = [run.npcs().get_npc(npc_id).position, "", ""]
	var gone: bool = _run_until(run, func() -> bool:
		var seen: NpcState = run.npcs().get_npc(npc_id)
		if seen != null:
			last[0] = seen.position
			last[1] = NpcRelocationState.of(seen).target_building_id
			last[2] = NpcRelocationState.of(seen).phase
		return seen == null)
	assert_true(gone, "the NPC left memory")
	var left_at: Vector3 = last[0]
	assert_eq(str(last[1]), target, "test setup: it left memory in the middle of the move")
	assert_eq(str(last[2]), NpcRelocationState.PHASE_TRAVELLING)
	run.run_ticks(600)
	assert_null(run.npcs().get_npc(npc_id))
	assert_true(run.npcs().is_seeded_home(target), "the building stays taken while the NPC is not in memory")
	assert_eq(run.npcs().home_claim_holder(target), npc_id)
	# The player comes back: it goes on where it stopped.
	run.observer.position = left_at
	var back: bool = _run_until(run, func() -> bool: return run.npcs().is_awake(npc_id))
	assert_true(back, "the NPC is back")
	if not back:
		return
	var move: NpcRelocationState = _move_of(run, npc_id)
	assert_true(_flat(run.npcs().get_npc(npc_id).position, left_at) < 3.0, "where it was")
	assert_true(move.phase == NpcRelocationState.PHASE_TRAVELLING and move.target_building_id == target, "on the same move")
	var starts_before: int = relocation.started_count
	var chosen_before: int = relocation.chosen_count
	var failures_before: int = run.behaviours.failed_count
	var done: bool = _run_until(run, func() -> bool: return not move.is_moving(), npc_id)
	assert_true(done, "it finishes the move (events %s)" % _tail(run))
	assert_eq(relocation.started_count, starts_before, "the same move, not a new one")
	assert_eq(relocation.chosen_count, chosen_before)
	assert_eq(run.behaviours.failed_count, failures_before)
	var outcome: Dictionary = _outcome(run, npc_id, str(scene["home_id"]), target)
	assert_eq(str(outcome["home"]), target)
	assert_eq(str(outcome["record"]), target)
	assert_eq(int(outcome["food"]), 3, "the food came along")
	assert_true(bool(outcome["old_home_free"]))
	_no_errors()
	run.finish()


func test_a_zombie_on_the_way_makes_it_flee_and_then_it_goes_on() -> void:
	var scene: Dictionary = _on_the_way(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var npc_id: String = scene["npc_id"]
	var target: String = scene["target"]
	var npc: NpcState = run.npcs().get_npc(npc_id)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var move: NpcRelocationState = _move_of(run, npc_id)
	var zombies: ZombieService = world.get_system(ZombieService.SYSTEM_ID) as ZombieService
	var zombie_id: String = str(zombies.spawn_zombie(world, npc.position + Vector3(4.0, 0.0, 0.0), 0.0).event["zombie_id"])
	var fled: bool = _run_until(run, func() -> bool: return run.behaviour_of(npc_id).action_id == NpcBehaviours.ACTION_FLEE, npc_id, 400)
	assert_true(fled, "it flees from a zombie on the way (events %s)" % _tail(run))
	assert_true(move.phase == NpcRelocationState.PHASE_TRAVELLING and move.target_building_id == target, "the move is not forgotten")
	assert_true(run.npcs().is_seeded_home(target), "nor the claim")
	var scavenged: Array[int] = [0]
	run.behaviours.behaviour_started.connect(func(started_id: String, action_id: String, _info: Dictionary) -> void:
		if started_id == npc_id and (action_id == NpcBehaviours.ACTION_SCAVENGE or action_id == NpcBehaviours.ACTION_WANDER):
			scavenged[0] += 1)
	run.run_ticks(40)
	assert_true(zombies.apply_damage_to_zombie(zombie_id, 100000.0, "test_setup").ok)
	var starts_before: int = relocation.started_count
	var done: bool = _run_until(run, func() -> bool: return not move.is_moving(), npc_id)
	assert_true(done, "it goes on and arrives (phase '%s', events %s)" % [move.phase, _tail(run)])
	assert_eq(relocation.started_count, starts_before, "the same move")
	assert_eq(_home_of(run, npc_id), target, "in the building it chose before the zombie came")
	assert_eq(scavenged[0], 0, "on the way it neither scavenges nor strolls back")
	assert_eq(int(_outcome(run, npc_id, str(scene["home_id"]), target)["food"]), 3)
	_no_errors()
	run.finish()


func test_an_npc_that_dies_on_the_way_leaves_what_it_carried_on_the_road_and_the_building_free() -> void:
	var scene: Dictionary = _on_the_way(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var npc_id: String = scene["npc_id"]
	var home_id: String = scene["home_id"]
	var target: String = scene["target"]
	var npc: NpcState = service.get_npc(npc_id)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var carried: String = run.behaviour_of(npc_id).inventory_id
	var food_carried: int = _units(world, carried, FOOD)
	assert_true(food_carried >= 1, "test setup: it carries the food of its house (%d)" % food_carried)
	assert_true(service.is_seeded_home(target))
	var abandoned: Array[Array] = []
	relocation.move_abandoned.connect(func(moved_id: String, building_id: String, why: String) -> void: abandoned.append([moved_id, building_id, why]))
	var place: Vector3 = npc.position
	var items_before: PackedStringArray = world.inventory.world_item_ids_in_cell(world.cell_id_at(place))
	for hit: int in range(20):
		if not NpcVitals.of(npc).is_alive():
			break
		_health(world).apply_damage(npc_id, DamageInput.create("test_source", BodyPart.Part.TORSO, Wound.Type.LACERATION, 60.0))
	assert_false(NpcVitals.of(npc).is_alive(), "test setup: it died")
	run.run_ticks(5)
	# What it carried lies where it died: on the road, not in a house.
	var dropped_food: int = 0
	var dropped_bandages: int = 0
	for item_id: String in world.inventory.world_item_ids_in_cell(world.cell_id_at(place)):
		if items_before.has(item_id):
			continue
		var item: ItemInstance = world.inventory.get_item(item_id)
		dropped_food += item.quantity if item.definition_id == FOOD else 0
		dropped_bandages += item.quantity if item.definition_id == BANDAGE else 0
	assert_eq(dropped_food, food_carried, "its food lies on the road")
	assert_eq(dropped_bandages, 1)
	assert_true(_flat(place, scene["home_position"]) > 10.0 and _flat(place, _center(run, target)) > 5.0, "between the two houses")
	assert_eq(_units(world, carried, FOOD), 0)
	# The building it was moving to is free again; its move is over.
	assert_false(service.is_seeded_home(target), "the claim is given back")
	assert_eq(service.claimed_homes_of(npc_id).size(), 0)
	assert_false(_move_of(run, npc_id).is_moving())
	assert_eq(abandoned, [[npc_id, target, NpcRelocation.WHY_DIED]] as Array[Array])
	assert_eq(NpcHome.of(npc).building_id, home_id, "it never lived in the new building")
	assert_false(service.is_awake(npc_id))
	run.run_ticks(200)
	assert_false(_move_of(run, npc_id).is_moving(), "a dead NPC does not move on")
	assert_eq(relocation.relocated_count, 0)
	_no_errors()
	run.finish()


func test_a_destination_it_finds_no_way_to_is_given_up_and_it_chooses_again() -> void:
	var scene: Dictionary = _on_the_way(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var npc_id: String = scene["npc_id"]
	var target: String = scene["target"]
	var npc: NpcState = service.get_npc(npc_id)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var move: NpcRelocationState = _move_of(run, npc_id)
	var state: NpcBehaviourState = run.behaviour_of(npc_id)
	var settings: NpcRelocationSettings = relocation.settings
	# The legs: straight, then to the side, shorter.
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	var destination: Vector3 = grid.tile_center(move.target_tile)
	var from: Vector3 = npc.position
	var far: Vector3 = from + Vector3(1000.0, 0.0, 0.0)
	var straight: Vector3 = relocation.leg_goal(world, from, far, 0)
	_near(_flat(from, straight), settings.leg_length_m, 1.0, "a leg is as long as the setting")
	assert_true(absf(straight.z - from.z) <= 1.0, "straight towards the destination")
	assert_eq(grid.tile_center(grid.tile_of(straight)).x, straight.x, "on the middle of a tile")
	var near: Vector3 = from + Vector3(10.0, 0.0, 3.0)
	assert_eq(relocation.leg_goal(world, from, near, 0), near, "the last leg ends on the destination")
	var seen: Dictionary = {}
	for failures: int in range(1, settings.max_leg_failures):
		var side: Vector3 = relocation.leg_goal(world, from, far, failures)
		assert_true(_flat(from, side) <= settings.leg_length_m * NpcRelocation.DETOUR_LENGTH_SHARE + 1.0 and _flat(from, side) >= 1.0, "a leg to the side is shorter (%.1f m)" % _flat(from, side))
		assert_true(absf(side.z - from.z) > 3.0, "and leaves the straight line (failures %d)" % failures)
		seen[side] = true
	assert_eq(seen.size(), settings.max_leg_failures - 1, "every try goes another way")
	assert_ne(relocation.leg_goal(world, from, near, 1), near, "also when the destination is near")
	# Legs that find no way: it tries again, and after the last it gives the
	# building up.
	var abandoned: Array[Array] = []
	relocation.move_abandoned.connect(func(moved_id: String, building_id: String, why: String) -> void: abandoned.append([moved_id, building_id, why]))
	run.behaviours.movement_executor().cancel(npc_id)
	for failure: int in range(settings.max_leg_failures - 1):
		assert_eq(relocation.on_walk_failed(world, service, npc, state, NpcActionExecutor.FAIL_NO_PATH), NpcRelocation.STEP_CONTINUES)
		assert_eq(move.leg_failures, failure + 1)
		assert_true(move.phase == NpcRelocationState.PHASE_TRAVELLING and move.target_building_id == target, "it keeps trying")
	assert_true(state.step == NpcBehaviourState.STEP_PERFORMING and state.timer_usec > 0, "it waits before the next try")
	assert_eq(relocation.on_walk_failed(world, service, npc, state, NpcActionExecutor.FAIL_NO_PATH), NpcRelocation.STEP_CONTINUES, "the action goes on: it chooses again")
	assert_eq(abandoned, [[npc_id, target, NpcRelocation.WHY_NO_PATH]] as Array[Array])
	assert_eq(move.phase, NpcRelocationState.PHASE_CHOOSING)
	assert_true(move.from_here and not move.has_target() and move.packed, "from where it stands, with what it packed")
	assert_false(service.is_seeded_home(target), "the claim is given back")
	assert_eq(NpcScavengeState.of(npc).result_of(target), NpcScavengeState.RESULT_BLOCKED, "it remembers that it found no way there")
	assert_eq(relocation.on_walk_failed(world, service, npc, state, NpcActionExecutor.FAIL_TARGET_GONE), NpcActionExecutor.FAIL_TARGET_GONE, "any other failure is the action's")
	# It chooses another building (or goes back home) and arrives.
	var done: bool = _run_until(run, func() -> bool: return not move.is_moving(), npc_id)
	assert_true(done, "it arrives somewhere (phase '%s', events %s)" % [move.phase, _tail(run)])
	assert_ne(_home_of(run, npc_id), target, "not in the building it gave up")
	assert_true(service.is_seeded_home(_home_of(run, npc_id)))
	assert_eq(service.claimed_homes_of(npc_id).size(), 0)
	assert_eq(int(_outcome(run, npc_id, str(scene["home_id"]), _home_of(run, npc_id))["food"]) + (_units_in_building(world, str(scene["home_id"]), FOOD) if _home_of(run, npc_id) != str(scene["home_id"]) else 0), 3, "its food is where it lives now")
	print("[f30] a destination given up %.1f m from home: it chose %s (%s) and arrived" % [_flat(from, scene["home_position"]), _home_of(run, npc_id), "its old home" if _home_of(run, npc_id) == str(scene["home_id"]) else "another building"])
	assert_true(_flat(destination, from) > 0.0)
	_no_errors()
	run.finish()


func test_an_npc_whose_way_is_not_built_yet_waits_and_an_npc_with_nowhere_to_go_stays() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var npc_id: String = scene["npc_id"]
	var npc: NpcState = service.get_npc(npc_id)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var move: NpcRelocationState = _move_of(run, npc_id)
	# A leg into a cell that is not in memory does not begin.
	var edge: Vector3 = npc.position + Vector3(world.cell_grid.cell_size_m * 6.0, 0.0, 0.0)
	assert_false(world.is_cell_loaded(world.cell_id_at(edge)), "test setup: six cells away nothing is in memory")
	assert_false(relocation._is_way_ready(world, edge - Vector3(30.0, 0.0, 0.0), edge))
	assert_true(relocation._is_way_ready(world, npc.position, npc.position + Vector3(20.0, 0.0, 0.0)))
	# Nowhere to go: every building in reach is somebody's.
	var generator: ProceduralMapGenerator = _map(world).generator()
	var claimed: int = 0
	for cell: Vector2i in run.behaviours.scavenging().cells_around(world, _center(run, str(scene["home_id"])), relocation.settings.max_distance_m):
		for building: ProceduralBuilding in generator.plan_cell(cell).buildings:
			if not building.definition.containers.is_empty() and service.claim_home("npc_999999", building.building_id()):
				claimed += 1
	assert_true(claimed > 0)
	assert_true(relocation.note_attacked(service, npc))
	var failed: Array[String] = []
	run.behaviours.behaviour_failed.connect(func(failed_id: String, action_id: String, code: String) -> void:
		if failed_id == npc_id and action_id == RELOCATE:
			failed.append(code))
	var gave_up: bool = _run_until(run, func() -> bool: return not failed.is_empty(), npc_id, 2000)
	assert_true(gave_up, "the move ends when there is no building (phase '%s', events %s)" % [move.phase, _tail(run)])
	assert_eq(failed, [NpcRelocation.FAIL_NO_DESTINATION] as Array[String])
	assert_false(move.is_moving(), "it is not in the middle of anything")
	assert_true(move.attacked, "it still wants to leave")
	assert_true(move.no_choice_until_world_sec > floori(world.clock.world_time_sec), "but does not look again at once")
	assert_false(relocation.wants_to_move(npc))
	assert_eq(_home_of(run, npc_id), str(scene["home_id"]), "it stays where it lives")
	assert_eq(service.claimed_homes_of(npc_id).size(), 0)
	var decisions_before: int = relocation.started_count
	run.run_ticks(600)
	assert_eq(relocation.started_count, decisions_before, "and does not begin again and again")
	print("[f30] nowhere to go: %d buildings within %.0f m, all taken" % [claimed, relocation.settings.max_distance_m])
	_no_errors()
	run.finish()


# ------------------------------------------------------------ cost

static func _percentile(sorted: PackedFloat32Array, fraction: float) -> float:
	return sorted[mini(int(float(sorted.size()) * fraction), sorted.size() - 1)]


func test_choosing_where_to_move_costs_little() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, MEASURE_TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var npc_id: String = scene["npc_id"]
	var npc: NpcState = service.get_npc(npc_id)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var move: NpcRelocationState = _move_of(run, npc_id)
	_put(world, _containers_of(world, str(scene["home_id"]))[0].inventory_id, FOOD, 3)
	# The whole choice at once, nothing listed before (what a server pays
	# when it was restarted in the middle of a choice).
	move.reason = NpcRelocationState.REASON_ATTACKED
	var cold_started: int = Time.get_ticks_usec()
	var cold_choice: String = relocation.choose_destination(world, service, npc)
	var cold_ms: float = float(Time.get_ticks_usec() - cold_started) / 1000.0
	var warm_ms: PackedFloat32Array = []
	for index: int in range(20):
		assert_eq(relocation.choose_destination(world, service, npc), cold_choice, "the same building whatever was listed before")
		warm_ms.append(float(relocation.last_choose_usec) / 1000.0)
	warm_ms.sort()
	move.reason = ""
	var picker: NpcRelocationPicker = relocation.picker()
	print("[f30 measure] choosing a destination in a town: %d cells, %d buildings, %d candidates; everything at once with nothing listed %.2f ms; with the cells listed median %.3f ms, worst %.3f ms" % [picker.last_cell_count, picker.last_building_count, picker.last_candidate_count, cold_ms, _percentile(warm_ms, 0.5), warm_ms[warm_ms.size() - 1]])
	# As the game does it: a new world (nothing listed), one cell a tick.
	run.finish()
	scene = _scene(NpcLifeRun.begin_in_memory(WORLD + "_b", MEASURE_TICK, 0, _procedural()))
	if scene.is_empty():
		return
	run = scene["run"]
	world = run.world
	service = run.npcs()
	npc = service.get_npc(npc_id)
	relocation = run.behaviours.relocation()
	move = _move_of(run, npc_id)
	_put(world, _containers_of(world, str(scene["home_id"]))[0].inventory_id, FOOD, 3)
	assert_true(relocation.note_attacked(service, npc))
	var stage_ms: Array[float] = []
	var chose: bool = _run_until(run, func() -> bool:
		if move.phase == NpcRelocationState.PHASE_CHOOSING or (move.has_target() and stage_ms.size() > 0):
			stage_ms.append(service.last_step_msec)
		return move.has_target(), "", 2000)
	assert_true(chose, "it chose (phase '%s')" % move.phase)
	var choosing_ticks: int = stage_ms.size()
	stage_ms.sort()
	assert_eq(move.target_building_id, cold_choice, "one cell a tick chooses what choosing at once chose")
	print("[f30 measure] the same choice in the game: %d ticks of choosing (%d cells listed), slowest listing of a tick %.3f ms, the choice at the end %.3f ms; NPC stages in those ticks median %.4f ms, worst %.4f ms" % [choosing_ticks, relocation.scanned_cell_count, float(relocation.max_scan_usec) / 1000.0, float(relocation.max_choose_usec) / 1000.0, stage_ms[stage_ms.size() / 2] if not stage_ms.is_empty() else 0.0, stage_ms[stage_ms.size() - 1] if not stage_ms.is_empty() else 0.0])
	assert_time_bound(float(relocation.max_scan_usec) / 1000.0, SCAN_BOUND_MS, "listing the cells of a tick while choosing where to move")
	assert_time_bound(float(relocation.max_choose_usec) / 1000.0, CHOICE_BOUND_MS, "choosing where to move, the cells listed")
	_no_errors()
	run.finish()


## `count` NPCs living alone in the houses of one town, all driven out at
## the same moment, for MEASURE_TICKS ticks of 1/60 s.
func _measure(count: int) -> void:
	var run: NpcLifeRun = NpcLifeRun.begin_in_memory("%s_%d" % [WORLD, count], MEASURE_TICK, 64, _procedural())
	var scene: Dictionary = _scene(run)
	if scene.is_empty():
		return
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var generator: ProceduralMapGenerator = _map(world).generator()
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	var relocation: NpcRelocation = run.behaviours.relocation()
	var definitions: PackedStringArray = NpcRoster.load_or_null().npc_definition_ids
	var around: PackedStringArray = []
	for cell: Vector2i in world.cell_grid.cells_within(world.cell_grid.cell_of(scene["home_position"]), 2):
		if not _map(world).is_cell_complete(WorldCellGrid.id_of(cell)) or not world.is_cell_simulated(WorldCellGrid.id_of(cell)):
			continue
		for building: ProceduralBuilding in generator.plan_cell(cell).buildings:
			if building.building_id() != str(scene["home_id"]) and NpcHomePicker.is_home(building):
				around.append(building.building_id())
	assert_true(around.size() >= count * 2, "test setup: enough buildings around (%d)" % around.size())
	var movers: PackedStringArray = [str(scene["npc_id"])]
	_put(world, _containers_of(world, str(scene["home_id"]))[0].inventory_id, FOOD, 3)
	for index: int in range(count - 1):
		var layout: NpcHomeLayout = NpcHomeLayout.of(generator.building_by_id(around[index * 2]).definition)
		var spawned: ActionResult = service.spawn_npc(world, definitions[index % definitions.size()], grid.tile_center(layout.home_tile()))
		assert_true(spawned.ok, "test setup: NPC %d (%s)" % [index, spawned.reason])
		if not spawned.ok:
			return
		var spawned_id: String = str(spawned.event[NpcService.KEY_NPC_ID])
		NpcHome.of(service.get_npc(spawned_id)).set_generated(layout.building_id, layout.home_tile())
		service.settle_home(spawned_id, layout.building_id)
		_empty(world, layout.building_id)
		_put(world, _containers_of(world, layout.building_id)[0].inventory_id, FOOD, 3)
		movers.append(spawned_id)
	for mover_id: String in movers:
		assert_true(relocation.note_attacked(service, service.get_npc(mover_id)))
	var stage_ms: PackedFloat32Array = []
	var tick_ms: PackedFloat32Array = []
	var slowest: Array = [0.0, 0, 0.0, 0.0]
	var executor: NpcExecutor = run.behaviours.movement_executor()
	var same_target: int = 0
	var slowest_tick: int = 0
	for tick: int in range(MEASURE_TICKS):
		if _map(world).pending_cell_count() > 0:
			_map(world).finish_pending(world)
		var started: int = Time.get_ticks_usec()
		run.step()
		tick_ms.append(float(Time.get_ticks_usec() - started) / 1000.0)
		stage_ms.append(service.last_step_msec)
		slowest_tick = tick if tick_ms[tick] > tick_ms[slowest_tick] else slowest_tick
		if service.last_step_msec > float(slowest[0]):
			slowest = [service.last_step_msec, tick, float(executor.last_step_usec) / 1000.0, float(run.behaviours.last_step_usec) / 1000.0]
		if tick % 60 == 0:
			var targets: Dictionary = {}
			for mover_id: String in movers:
				var moving: NpcRelocationState = _move_of(run, mover_id)
				if moving != null and moving.has_target():
					same_target += 1 if targets.has(moving.target_building_id) else 0
					targets[moving.target_building_id] = true
	var sorted_stage: PackedFloat32Array = stage_ms.duplicate()
	sorted_stage.sort()
	var sorted_tick: PackedFloat32Array = tick_ms.duplicate()
	sorted_tick.sort()
	var moving_now: int = 0
	var homes: Dictionary = {}
	for mover_id: String in movers:
		moving_now += 1 if _move_of(run, mover_id).is_moving() else 0
		homes[_home_of(run, mover_id)] = true
	print("[f30 measure] %d lone NPCs of one town driven out at once, %d ticks at 60 Hz: NPC stages per tick median %.4f ms, 99%% %.4f ms, 99.9%% %.4f ms, worst %.4f ms (tick %d: executor %.4f ms, behaviours %.4f ms); whole server tick median %.4f ms, worst %.4f ms (NPC stages %.4f ms of it); %d moves begun, %d destinations chosen (worst choice %.3f ms, slowest listing of a tick %.3f ms, %d cells listed), %d legs, %d moved in, %d still on the way, %d given up; slowest packing of a container %.3f ms, beginning of a leg %.3f ms, moving in %.3f ms" % [
		count, MEASURE_TICKS, _percentile(sorted_stage, 0.5), _percentile(sorted_stage, 0.99), _percentile(sorted_stage, 0.999), sorted_stage[sorted_stage.size() - 1], int(slowest[1]), float(slowest[2]), float(slowest[3]),
		_percentile(sorted_tick, 0.5), sorted_tick[sorted_tick.size() - 1], stage_ms[slowest_tick],
		relocation.started_count, relocation.chosen_count, float(relocation.max_choose_usec) / 1000.0, float(relocation.max_scan_usec) / 1000.0, relocation.scanned_cell_count, relocation.leg_count, relocation.relocated_count, moving_now, relocation.abandoned_count, float(relocation.max_pack_usec) / 1000.0, float(relocation.max_leg_usec) / 1000.0, float(relocation.max_settle_usec) / 1000.0])
	assert_eq(relocation.started_count, count, "every NPC decided to move, once")
	assert_true(relocation.chosen_count >= count, "and chose a building")
	assert_eq(same_target, 0, "no two of them moved to the same building")
	assert_eq(homes.size(), count, "no two of them live in the same building")
	assert_true(relocation.relocated_count + moving_now >= count, "each has moved in or is on its way")
	assert_time_bound(_percentile(sorted_stage, 0.99), STAGE_BOUND_MS, "NPC stages, %d moving NPCs, 99%%" % count)
	_no_errors()
	run.finish()


func test_ten_moving_npcs_cost_little_per_tick() -> void:
	_measure(10)


func test_twenty_five_moving_npcs_cost_little_per_tick() -> void:
	_measure(25)
