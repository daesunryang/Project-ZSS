extends TestCase
## F-29 (docs/09 §17.14): survival first. An NPC that lives alone searches
## the buildings around its home when it lacks supplies, carries what it
## finds home, remembers where it met zombies and stays away from there,
## bandages itself with what it found, and fights the zombie it cannot get
## away from. Whatever it is in the middle of goes on after a restart and
## after its cell left memory.
##
## The shipped composition and generated map (NpcLifeRun with the generated
## map), without generated zombies: the tests put a zombie where they want
## one. What the containers hold is set by the tests (the loot of a world is
## rolled from a random seed): every container around the NPC is searched
## and emptied, then the loot of the test is put where it belongs.

const WORLD: String = "npc_scavenge_world"
const SEED: int = 20261123
const MODULE_M: float = 1.0
const TICK: float = 0.05
const ROSTER_ID: String = "dev_npc_roster"
const FOOD: String = "dev_food_ration"
const WATER: String = "dev_water_bottle"
const BANDAGE: String = "dev_bandage"
const PIPE: String = "dev_melee_pipe"
const KNIFE: String = "melee_kitchen_knife"
const NAILS: String = "dev_nails"
const SCAVENGE: String = NpcBehaviours.ACTION_SCAVENGE
## Ticks for the cells around a player to come into memory.
const ARRIVE_TICKS: int = 40
## Most ticks a test waits for something an NPC does (10 real minutes).
const PATIENCE_TICKS: int = 12000
## Other buildings with containers the NPC of a scene has around its home.
const MIN_NEIGHBOURS: int = 3
const FAR_AWAY: Vector3 = Vector3(0.0, 0.0, 0.0)
const MEASURE_TICK: float = 1.0 / 60.0
const MEASURE_TICKS: int = 3600
const STAGE_BOUND_MS: float = 2.0
const PICK_BOUND_MS: float = 2.0

var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	# F-31: what NPCs do about a player is tests/unit/npc_social_test.gd. Here
	# the player only keeps the cells simulated; an NPC that stopped to look
	# at it would not finish the trips these tests follow.
	NpcLifeRun.with_social = false
	_root = "user://test_saves/npc_scavenge_%d" % Time.get_ticks_usec()


func after_each() -> void:
	NpcLifeRun.with_social = true
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


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _center_of(definition: MapBuildingDefinition) -> Vector3:
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	return (grid.tile_center(definition.origin_tile) + grid.tile_center(definition.origin_tile + definition.size_tiles - Vector2i.ONE)) * 0.5


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## The buildings with a container whose middle is within the search radius
## of `home_id`'s middle, nearest to `from` first (then the smaller id): the
## order in which an NPC that stands at `from` and remembers no danger
## searches them.
func _neighbours(run: NpcLifeRun, home_id: String, from: Vector3) -> PackedStringArray:
	var generator: ProceduralMapGenerator = _map(run.world).generator()
	var radius: float = NpcScavengeSettings.load_or_default().radius_m
	var home_center: Vector3 = _center_of(generator.building_by_id(home_id).definition)
	var rows: Array[Array] = []
	for cell: Vector2i in run.world.cell_grid.cells_within(run.world.cell_grid.cell_of(home_center), 2):
		for building: ProceduralBuilding in generator.plan_cell(cell).buildings:
			var id: String = building.building_id()
			var center: Vector3 = _center_of(building.definition)
			if id == home_id or building.definition.containers.is_empty() or _flat(center, home_center) > radius or run.npcs().is_seeded_home(id):
				continue
			rows.append([_flat(center, from), id])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]) if float(a[0]) != float(b[0]) else str(a[1]) < str(b[1]))
	var ids: PackedStringArray = []
	for row: Array in rows:
		ids.append(str(row[1]))
	return ids


## A run with the observer in the house of an NPC of the roster that has
## neighbours to search, every container around it searched and empty:
## {run, npc_id, home_id, home_position, neighbours}. {} when it failed.
func _scene(run: NpcLifeRun) -> Dictionary:
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
		var neighbours: PackedStringArray = _neighbours(run, home_id, home_position)
		if neighbours.size() < MIN_NEIGHBOURS or layout.food_offsets.is_empty():
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
		return {"run": run, "npc_id": npc_id, "home_id": home_id, "home_position": home_position, "neighbours": neighbours}
	fail("test setup: no NPC of the roster has %d buildings to search around its home" % MIN_NEIGHBOURS)
	return {}


## The containers of a generated building, by their index.
func _containers_of(world: ServerWorld, building_id: String) -> Array[ContainerInstance]:
	var found: Array[ContainerInstance] = []
	var building: ProceduralBuilding = _map(world).generator().building_by_id(building_id)
	for index: int in range(building.definition.containers.size()):
		found.append(_containers(world).get_container(_containers(world).container_id_of_source(MapBuildingPlan.container_source_key(ProceduralMapGenerator.MAP_ID, building_id, index))))
	return found


## Every container of a building is searched (its loot is rolled) and empty.
func _empty(world: ServerWorld, building_id: String) -> void:
	for container: ContainerInstance in _containers_of(world, building_id):
		if container == null:
			fail("test setup: a container of %s is not in memory" % building_id)
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


func _trip(run: NpcLifeRun, npc_id: String) -> NpcScavengeState:
	return NpcScavengeState.of(run.npcs().get_npc(npc_id))


## Steps until `done` says so (at most PATIENCE_TICKS). True when it did.
func _run_until(run: NpcLifeRun, done: Callable) -> bool:
	for tick: int in range(PATIENCE_TICKS):
		if done.call():
			return true
		run.step()
	return done.call()


func _no_errors() -> void:
	assert_false(" | ".join(GameLogger.captured_lines()).contains("[ERROR]"), "no errors on the way")


# ------------------------------------------------------------ pure data

func test_the_shipped_settings_and_actions_are_valid() -> void:
	var settings: NpcScavengeSettings = NpcScavengeSettings.load_or_default()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	var defaults: NpcScavengeSettings = NpcScavengeSettings.new()
	for property: Dictionary in defaults.get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			assert_eq(settings.get(str(property["name"])), defaults.get(str(property["name"])), "the tuning file and the script agree on %s" % property["name"])
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	assert_true(settings.radius_m <= config.navigation.max_search_radius_m, "a building it searches is within reach of the path search")
	var bad: NpcScavengeSettings = NpcScavengeSettings.new()
	bad.radius_m = config.navigation.max_search_radius_m + 1.0
	bad.fight_range_m = 0.0
	bad.hurt_fear = 1.5
	assert_eq(bad.validate().size(), 2, "; ".join(bad.validate()))
	assert_eq(bad.validate_against(config.navigation).size(), 1)
	var actions: NpcActionCatalog = config.npc_actions
	var scavenge: NpcActionDefinition = actions.get_action(SCAVENGE)
	assert_true(scavenge.requires_lone_home and scavenge.need_is_supply_shortage and scavenge.runs_until_done and scavenge.selectable)
	assert_true(actions.get_action(NpcBehaviours.ACTION_TREAT).requires_treatment)
	assert_false(actions.get_action(NpcBehaviours.ACTION_FIGHT).selectable)
	# Survival first: a wound it can treat outweighs every need, and a full
	# shortage outweighs wandering but not thirst or hunger in danger.
	var needs: NpcNeedSettings = config.npc_needs
	var danger: float = needs.danger_threshold / needs.need_max
	assert_true(actions.get_action(NpcBehaviours.ACTION_TREAT).base_priority >= 1.0)
	assert_true(scavenge.base_priority + scavenge.need_weight + scavenge.personality_weight + scavenge.environment_weight < danger, "eating and drinking in danger come before a trip")
	assert_true(scavenge.base_priority + scavenge.need_weight > actions.get_action(NpcBehaviours.ACTION_WANDER).base_priority + actions.get_action(NpcBehaviours.ACTION_WANDER).personality_weight + config.npc_decision.score_jitter, "an NPC without supplies searches before it wanders")
	var wrong: NpcActionDefinition = scavenge.duplicate() as NpcActionDefinition
	wrong.need_kind = NpcNeedKind.HUNGER
	assert_eq(wrong.validate().size(), 1, "the shortage term and a need exclude each other")


func test_the_scavenge_component_round_trips_and_refuses_bad_documents() -> void:
	var state: NpcScavengeState = NpcScavengeState.new()
	assert_true(state.to_document().is_empty(), "an NPC that never scavenged saves nothing")
	var empty: NpcScavengeState = NpcScavengeState.new()
	assert_eq(empty.restore_document({NpcComponent.KEY_SCHEMA_VERSION: NpcScavengeState.SCHEMA_VERSION}).size(), 0, "and an empty document is a fresh component")
	assert_false(empty.is_on_trip())
	state.phase = NpcScavengeState.PHASE_SEARCHING
	state.building_id = "gen_p1_n2_0"
	state.container_index = 1
	state.taken_units = 3
	state.left_useful = true
	state.home_food_units = 7
	state.home_medical_units = 1
	for index: int in range(6):
		state.note_visit("gen_p1_n2_%d" % index, NpcScavengeState.RESULTS[index % 3], index, 4)
	assert_eq(state.visited.size(), 4, "the oldest visits are forgotten")
	assert_eq(state.result_of("gen_p1_n2_0"), "", "forgotten")
	state.note_visit("gen_p1_n2_3", NpcScavengeState.RESULT_EMPTY, 9, 4)
	assert_eq(state.visited.size(), 4, "one entry per building")
	assert_eq(state.result_of("gen_p1_n2_3"), NpcScavengeState.RESULT_EMPTY)
	assert_eq(state.day_of("gen_p1_n2_3"), 9)
	assert_eq(str(state.visited[3][NpcScavengeState.KEY_BUILDING_ID]), "gen_p1_n2_3", "the newest last")
	var document: Dictionary = state.to_document()
	document[NpcComponent.KEY_SCHEMA_VERSION] = NpcScavengeState.SCHEMA_VERSION
	var saved: Dictionary = JSON.parse_string(JSON.stringify(document)) as Dictionary
	var restored: NpcScavengeState = NpcScavengeState.new()
	assert_eq(restored.restore_document(saved).size(), 0, "; ".join(restored.restore_document(saved)))
	var again: Dictionary = restored.to_document()
	again[NpcComponent.KEY_SCHEMA_VERSION] = NpcScavengeState.SCHEMA_VERSION
	assert_eq(NpcLifeRun.first_difference(JSON.parse_string(JSON.stringify(again)), saved, "scavenge"), "")
	restored.clear_trip()
	assert_false(restored.is_on_trip())
	assert_eq(restored.visited.size(), 4, "what it knows stays when a trip ends")
	for change: Array in [
		[NpcScavengeState.KEY_PHASE, "strolling"], [NpcScavengeState.KEY_BUILDING_ID, "Not An Id"], [NpcScavengeState.KEY_BUILDING_ID, ""],
		[NpcScavengeState.KEY_CONTAINER_INDEX, -2], [NpcScavengeState.KEY_TAKEN_UNITS, 1.5], [NpcScavengeState.KEY_LEFT_USEFUL, 1],
		[NpcScavengeState.KEY_VISITED, [{"building_id": "a", "result": "tidy", "day": 0}]],
		[NpcScavengeState.KEY_VISITED, [{"building_id": "a", "result": "empty", "day": 0}, {"building_id": "a", "result": "left", "day": 1}]],
		[NpcComponent.KEY_SCHEMA_VERSION, 99],
	]:
		var bad: Dictionary = saved.duplicate(true)
		bad[change[0]] = change[1]
		var target: NpcScavengeState = NpcScavengeState.new()
		assert_true(target.restore_document(bad).size() > 0, "%s = %s is refused" % [change[0], str(change[1])])
		assert_false(target.is_on_trip(), "a refused document changes nothing")


# ------------------------------------------------------------ scavenging

func test_an_npc_with_an_empty_house_finds_food_next_door_and_brings_it_home() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var npc_id: String = scene["npc_id"]
	var home_id: String = scene["home_id"]
	var neighbours: PackedStringArray = scene["neighbours"]
	var world: ServerWorld = run.world
	var sense: NpcSurvivalSense = run.decider.survival()
	var scavenging: NpcScavenging = run.behaviours.scavenging()
	assert_not_null(sense, "the shipped composition has the survival layer")
	assert_not_null(scavenging)
	if sense == null or scavenging == null:
		return
	var npc: NpcState = run.npcs().get_npc(npc_id)
	assert_true(sense.is_lone(npc))
	assert_eq(sense.supply_shortage(npc), 1.0, "nothing to eat at home or on it")
	# The loot: food, water, a pipe and nails in the nearest building.
	var target: String = neighbours[0]
	var box: ContainerInstance = _containers_of(world, target)[0]
	_put(world, box.inventory_id, FOOD, 3)
	_put(world, box.inventory_id, WATER, 1)
	_put(world, box.inventory_id, PIPE, 1)
	_put(world, box.inventory_id, NAILS, 2)
	var wants: int = sense.wanted_food(world, npc)
	assert_true(wants >= 4 and wants <= 12, "it wants between half and one and a half times the setting (%d)" % wants)
	# Per finished trip: what it says, and where the NPC stood then.
	var finished: Array[Dictionary] = []
	run.behaviours.behaviour_finished.connect(func(done_id: String, action_id: String, info: Dictionary) -> void:
		if done_id == npc_id and action_id == SCAVENGE:
			var row: Dictionary = info.duplicate()
			row["at"] = run.npcs().get_npc(npc_id).position
			finished.append(row))
	var trip: NpcScavengeState = _trip(run, npc_id)
	var farthest: Array[float] = [0.0]
	var home_position: Vector3 = scene["home_position"]
	var done: bool = _run_until(run, func() -> bool:
		farthest[0] = maxf(farthest[0], _flat(run.npcs().get_npc(npc_id).position, home_position))
		return not trip.result_of(target).is_empty() and not trip.is_on_trip() and _units(world, run.behaviour_of(npc_id).inventory_id, FOOD) == 0)
	assert_true(done, "it searched the nearest building and came back within %d ticks (visited %s, events %s)" % [PATIENCE_TICKS, str(trip.visited), str(run.events.slice(maxi(run.events.size() - 6, 0)))])
	if not done:
		return
	print("[f29] an empty house: %d trips in %d ticks, farthest %.1f m from home, searches %d, taken %d, stowed %d units; last pick %d candidates in %.3f ms" % [finished.size(), run.tick, farthest[0], scavenging.search_count, scavenging.taken_unit_count, scavenging.stowed_unit_count, scavenging.last_candidate_count, float(scavenging.last_pick_usec) / 1000.0])
	# Its own house first, then the buildings around it, the near ones first
	# (the nearest of all is one of the first two: it starts the second trip
	# from the last container of its own house, not from its home tile).
	assert_eq(str(trip.visited[0][NpcScavengeState.KEY_BUILDING_ID]), home_id, "its own house first")
	var order: PackedStringArray = []
	for entry: Dictionary in trip.visited:
		order.append(str(entry[NpcScavengeState.KEY_BUILDING_ID]))
	assert_true(order.find(target) >= 1 and order.find(target) <= 2, "then the nearest buildings (%s)" % str(order))
	assert_eq(trip.result_of(target), NpcScavengeState.RESULT_EMPTY, "nothing useful is left there")
	assert_true(farthest[0] > 3.0, "it left its house (%.1f m)" % farthest[0])
	# It came home with what it found, and put the food and the water away.
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	var home_trip: Dictionary = {}
	for row: Dictionary in finished:
		if str(row[NpcScavenging.INFO_BUILDING]) == target:
			home_trip = row
	assert_false(home_trip.is_empty(), "the trip to that building was finished (%s)" % str(finished))
	if home_trip.is_empty():
		return
	assert_eq(grid.tile_of(home_trip["at"]), grid.tile_of(home_position), "the trip ends on its home tile")
	assert_eq(int(home_trip[NpcScavenging.INFO_TAKEN]), 5, "three rations, the water and the pipe")
	assert_eq(int(home_trip[NpcScavenging.INFO_STOWED]), 4, "the rations and the water go into the home's containers")
	assert_eq(_units_in_building(world, target, FOOD), 0)
	assert_eq(_units_in_building(world, home_id, FOOD) + run.behaviour_of(npc_id).count_of("eat"), 3, "the food is in its home (or eaten)")
	assert_eq(_units_in_building(world, home_id, WATER), 1, "and the water")
	var carried: String = run.behaviour_of(npc_id).inventory_id
	assert_eq(_units(world, carried, PIPE), 1, "it keeps the weapon on it")
	assert_eq(_units_in_building(world, target, NAILS), 2, "what it cannot use stays where it was")
	assert_eq(_units_in_building(world, target, PIPE) + _units_in_building(world, home_id, PIPE), 0)
	assert_true(world.inventory.items_in_inventory(carried).size() <= run.behaviour_of(npc_id).capacity())
	assert_true(sense.supply_shortage(npc) < 1.0, "it is better off (%.2f)" % sense.supply_shortage(npc))
	assert_eq(_trip(run, npc_id).home_food_units, _units_in_building(world, home_id, FOOD), "it knows what its home holds")
	# It goes on to the next building for more, and takes no second pipe: a
	# knife is no better than the pipe it has.
	var second: String = ""
	for building_id: String in neighbours:
		if trip.result_of(building_id).is_empty() and second.is_empty():
			second = building_id
	assert_false(second.is_empty(), "test setup: a building it has not searched yet")
	var second_box: ContainerInstance = _containers_of(world, second)[0]
	_put(world, second_box.inventory_id, FOOD, 3)
	_put(world, second_box.inventory_id, KNIFE, 1)
	done = _run_until(run, func() -> bool: return not trip.result_of(second).is_empty() and not trip.is_on_trip() and _units(world, carried, FOOD) == 0)
	assert_true(done, "it searched the next building too")
	assert_eq(_units_in_building(world, home_id, FOOD) + run.behaviour_of(npc_id).count_of("eat"), 6, "all the food is at home (or eaten)")
	assert_eq(_units_in_building(world, second, KNIFE), 1, "a weapon that is no better stays")
	assert_eq(_units(world, carried, PIPE), 1)
	assert_eq(_units(world, carried, KNIFE), 0)
	# Nothing was made or lost on the way.
	var food_everywhere: int = _units(world, carried, FOOD) + run.behaviour_of(npc_id).count_of("eat")
	for building_id: String in [home_id, target, second]:
		food_everywhere += _units_in_building(world, building_id, FOOD)
	assert_eq(food_everywhere, 6, "food is conserved")
	assert_eq(run.behaviour_of(npc_id).count_of("work"), 0, "it does not work")
	_no_errors()
	run.finish()


func test_an_npc_takes_only_what_it_wants_and_can_carry() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var npc_id: String = scene["npc_id"]
	var world: ServerWorld = run.world
	var sense: NpcSurvivalSense = run.decider.survival()
	var npc: NpcState = run.npcs().get_npc(npc_id)
	var target: String = (scene["neighbours"] as PackedStringArray)[0]
	var box: ContainerInstance = _containers_of(world, target)[0]
	# More food than anybody wants, in more stacks than it has hands.
	var stacks: int = mini(box.slot_count, 6)
	for index: int in range(stacks):
		_put(world, box.inventory_id, FOOD, 5)
	var wants: int = sense.wanted_food(world, npc)
	var trip: NpcScavengeState = _trip(run, npc_id)
	var most_carried: Array[int] = [0]
	var carried: String = run.behaviour_of(npc_id).inventory_id
	var done: bool = _run_until(run, func() -> bool:
		most_carried[0] = maxi(most_carried[0], world.inventory.items_in_inventory(carried).size())
		return not trip.result_of(target).is_empty() and not trip.is_on_trip() and _units(world, carried, FOOD) == 0)
	assert_true(done, "it searched the building and came home")
	if not done:
		return
	var home_food: int = _units_in_building(world, str(scene["home_id"]), FOOD) + run.behaviour_of(npc_id).count_of("eat")
	assert_eq(home_food, wants, "it took what it wanted (%d), not everything (%d)" % [wants, stacks * 5])
	assert_eq(_units_in_building(world, target, FOOD), stacks * 5 - wants)
	assert_eq(trip.result_of(target), NpcScavengeState.RESULT_LEFT, "it remembers that food is left there")
	assert_true(most_carried[0] <= run.behaviour_of(npc_id).capacity(), "never more stacks than it can carry (%d)" % most_carried[0])
	assert_eq(sense.wanted_food(world, npc), run.behaviour_of(npc_id).count_of("eat"), "it wants no more (but what it ate since)")
	# While it wants nothing, the building it left food in is no place to go.
	var scavenging: NpcScavenging = run.behaviours.scavenging()
	if sense.wanted_food(world, npc) == 0 and sense.wanted_drinks(world, npc) == 0:
		assert_ne(scavenging.pick_target(world, run.npcs(), npc), target)
	_no_errors()
	run.finish()


# ------------------------------------------------------------ danger

func test_an_npc_remembers_where_it_saw_a_zombie_and_searches_elsewhere() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var npc_id: String = scene["npc_id"]
	var world: ServerWorld = run.world
	var sense: NpcSurvivalSense = run.decider.survival()
	var scavenging: NpcScavenging = run.behaviours.scavenging()
	var npc: NpcState = run.npcs().get_npc(npc_id)
	var neighbours: PackedStringArray = scene["neighbours"]
	var trip: NpcScavengeState = _trip(run, npc_id)
	var settings: NpcScavengeSettings = sense.settings
	# Its own house is done; it stands on its home tile.
	run.behaviours.cancel(world, run.npcs(), npc)
	run.npcs().set_npc_transform(world, npc_id, scene["home_position"], 0.0)
	trip.note_visit(str(scene["home_id"]), NpcScavengeState.RESULT_EMPTY, 0, settings.max_visited)
	var nearest: String = _neighbours(run, str(scene["home_id"]), npc.position)[0]
	assert_eq(scavenging.pick_target(world, run.npcs(), npc), nearest, "without danger: the nearest building")
	assert_eq(scavenging.last_avoided_count, 0)
	assert_true(scavenging.last_candidate_count >= MIN_NEIGHBOURS)
	# It sees a zombie in front of that building.
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	var generator: ProceduralMapGenerator = _map(world).generator()
	var place: Vector3 = _center_of(generator.building_by_id(nearest).definition)
	var now: float = world.clock.world_time_sec
	assert_eq(sense.danger_at(npc, place, now), 0.0)
	assert_true(sense.note_zombie_seen(world, npc, place), "the sighting is remembered")
	assert_eq(memories.count(), 1)
	var memory: NpcMemory = memories.memory(memories.memory_ids()[0])
	assert_eq(memory.event_type, NpcSurvivalSense.MEMORY_ZOMBIE_SEEN)
	assert_eq(memory.location, place)
	assert_true(memory.interpretation_tags.has(NpcSurvivalSense.TAG_DANGER))
	assert_eq(memory.decay_half_life_world_sec, settings.danger_half_life_world_sec)
	assert_false(sense.note_zombie_seen(world, npc, place + Vector3(2.0, 0.0, 0.0)), "the same zombie a moment later is no second memory")
	assert_eq(memories.count(), 1)
	var danger: float = sense.danger_at(npc, place, now)
	assert_true(danger >= sense.danger_limit(npc), "the place is too dangerous for it (%.2f, limit %.2f)" % [danger, sense.danger_limit(npc)])
	assert_true(sense.danger_at(npc, place + Vector3(settings.danger_radius_m * 0.5, 0.0, 0.0), now) < danger, "less so farther away")
	assert_eq(sense.danger_at(npc, place + Vector3(settings.danger_radius_m + 1.0, 0.0, 0.0), now), 0.0)
	var picked: String = scavenging.pick_target(world, run.npcs(), npc)
	assert_ne(picked, nearest, "it does not go where it saw the zombie")
	assert_false(picked.is_empty(), "it goes somewhere else")
	assert_true(scavenging.last_avoided_count >= 1)
	assert_true(_flat(_center_of(generator.building_by_id(picked).definition), place) > 0.0)
	# For a while: the memory fades.
	var later: float = now + settings.danger_half_life_world_sec * 6.0
	assert_true(sense.danger_at(npc, place, later) < sense.danger_limit(npc), "days later the place is no longer avoided")
	# And it really walks to the other building: the avoided one stays
	# unsearched while the memory is fresh.
	_put(world, _containers_of(world, picked)[0].inventory_id, FOOD, 2)
	_put(world, _containers_of(world, nearest)[0].inventory_id, FOOD, 2)
	var done: bool = _run_until(run, func() -> bool: return not trip.result_of(picked).is_empty())
	assert_true(done, "it searched the building it chose")
	assert_eq(trip.result_of(nearest), "", "and not the one where it saw the zombie")
	assert_eq(_units_in_building(world, nearest, FOOD), 2)
	# A zombie's hit is remembered where it happened, with fear.
	var health: NpcHealth = NpcHealth.of_world(world)
	var before: int = memories.count()
	assert_true(health.apply_damage(npc_id, DamageInput.create("zombie_999999", BodyPart.Part.LEFT_ARM, Wound.Type.BRUISE, 3.0)).ok)
	assert_eq(memories.count(), before + 1)
	var hurt: NpcMemory = memories.memory(memories.memory_ids()[memories.count() - 1])
	assert_eq(hurt.event_type, NpcSurvivalSense.MEMORY_HURT)
	assert_true(hurt.importance > memory.importance, "a hit weighs more than a sighting")
	assert_true((npc.component(NpcEmotions.COMPONENT_ID) as NpcEmotions).value_at(NpcSurvivalSense.EMOTION_FEAR, world.clock.world_time_sec) > 0.0, "it is afraid")
	assert_true(health.apply_damage(npc_id, DamageInput.create("player_1", BodyPart.Part.LEFT_ARM, Wound.Type.BRUISE, 3.0)).ok)
	assert_eq(memories.count(), before + 1, "a hit by somebody else is not this rule's (F-32)")
	_no_errors()
	run.finish()


# ------------------------------------------------------------ treating itself

func test_a_bleeding_npc_finds_a_bandage_and_bandages_itself() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var npc_id: String = scene["npc_id"]
	var world: ServerWorld = run.world
	var sense: NpcSurvivalSense = run.decider.survival()
	var npc: NpcState = run.npcs().get_npc(npc_id)
	var health: NpcHealth = NpcHealth.of_world(world)
	assert_true(health.self_treat_by_action, "the decision layer treats, not the health stage")
	var target: String = (scene["neighbours"] as PackedStringArray)[0]
	_put(world, _containers_of(world, str(scene["home_id"]))[0].inventory_id, FOOD, 5)
	_put(world, _containers_of(world, str(scene["home_id"]))[0].inventory_id, FOOD, 5)
	_put(world, _containers_of(world, str(scene["home_id"]))[0].inventory_id, FOOD, 5)
	_put(world, _containers_of(world, target)[0].inventory_id, BANDAGE, 2)
	assert_true(sense.supply_shortage(npc) < 1.0, "it has food")
	assert_false(sense.can_treat(npc), "it is whole")
	assert_true(health.apply_damage(npc_id, DamageInput.create("test_source", BodyPart.Part.TORSO, Wound.Type.LACERATION, 25.0)).ok)
	var vitals: NpcVitals = NpcVitals.of(npc)
	assert_true(vitals.is_bleeding(), "test setup: it bleeds")
	assert_false(sense.can_treat(npc), "and has nothing to stop it")
	assert_eq(sense.supply_shortage(npc), 1.0, "a bleeding NPC without a bandage needs one more than anything")
	var treated_at: Array[int] = [-1]
	var treat_started_at: Array[int] = [-1]
	run.behaviours.behaviour_started.connect(func(started_id: String, action_id: String, _info: Dictionary) -> void:
		if started_id == npc_id and action_id == NpcBehaviours.ACTION_TREAT and treat_started_at[0] < 0:
			treat_started_at[0] = run.tick)
	run.behaviours.behaviour_finished.connect(func(done_id: String, action_id: String, _info: Dictionary) -> void:
		if done_id == npc_id and action_id == NpcBehaviours.ACTION_TREAT and treated_at[0] < 0:
			treated_at[0] = run.tick)
	var health_before: float = vitals.health
	var done: bool = _run_until(run, func() -> bool: return not vitals.is_bleeding())
	assert_true(done, "it found the bandage and used it (events %s)" % str(run.events.slice(maxi(run.events.size() - 6, 0))))
	if not done:
		return
	print("[f29] a bleeding NPC: bandaged itself after %d ticks (%.1f game minutes), health %.1f -> %.1f" % [run.tick, float(run.tick) * TICK * world.clock.time_scale / 60.0, health_before, vitals.health])
	assert_true(vitals.is_alive())
	assert_eq(run.behaviour_of(npc_id).count_of(NpcBehaviours.ACTION_TREAT), 1, "by the action treat")
	assert_eq(health.self_treat_count, 0, "not by the health stage's own rule")
	var treat_ticks: int = treated_at[0] - treat_started_at[0]
	assert_true(absi(treat_ticks - roundi(sense.settings.treat_duration_sec / TICK)) <= 1, "treating takes its time (%d ticks)" % treat_ticks)
	var carried: String = run.behaviour_of(npc_id).inventory_id
	assert_eq(_units(world, carried, BANDAGE) + _units_in_building(world, target, BANDAGE) + _units_in_building(world, str(scene["home_id"]), BANDAGE), 1, "one bandage was used up")
	assert_eq(_units(world, carried, BANDAGE), 1, "the other it keeps on it")
	assert_false(sense.can_treat(npc), "nothing is left to treat")
	_no_errors()
	run.finish()


# ------------------------------------------------------------ fighting

func test_a_cornered_npc_fights_the_zombie_with_its_best_weapon() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var npc_id: String = scene["npc_id"]
	var world: ServerWorld = run.world
	var npc: NpcState = run.npcs().get_npc(npc_id)
	var fighting: NpcFighting = run.behaviours.fighting()
	var carried: String = run.behaviour_of(npc_id).inventory_id
	var decision: NpcDecisionComponent = npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
	assert_eq(fighting.weapon_of(world, carried).weapon_id, "unarmed", "bare hands without a weapon")
	_put(world, carried, KNIFE, 1)
	_put(world, carried, PIPE, 1)
	var pipe: MeleeWeaponDefinition = fighting.weapon_of(world, carried)
	assert_eq(pipe.weapon_id, PIPE, "the best weapon it carries")
	# It stands at home with nothing to do; fleeing is blocked (the flee
	# action just failed: it is on its retry cooldown).
	run.behaviours.cancel(world, run.npcs(), npc)
	run.npcs().set_npc_transform(world, npc_id, scene["home_position"], 0.0)
	var clock: int = run.decider.scheduler().clock_usec()
	decision.set_cooldown(NpcBehaviours.ACTION_FLEE, clock + 600 * 1000000)
	var records: Array[Dictionary] = []
	run.decider.decided.connect(func(decided_id: String, record: Dictionary) -> void:
		if decided_id == npc_id:
			records.append(record))
	# A zombie right beside it, already hurt (the fight is about the rule,
	# not about who wins).
	var zombies: ZombieService = _zombies(world)
	zombies.drain_events()
	var spawned: ActionResult = zombies.spawn_zombie(world, npc.position + Vector3(0.3, 0.0, 0.3), 0.0)
	assert_true(spawned.ok, "test setup: a zombie")
	var zombie_id: String = str(spawned.event["zombie_id"])
	var zombie: ZombieState = zombies.get_zombie(zombie_id)
	assert_true(zombies.apply_damage_to_zombie(zombie_id, zombie.health - 40.0, "test_setup").ok)
	var rng_before: int = npc.rng.state
	var done: bool = _run_until(run, func() -> bool: return not zombie.is_alive())
	assert_true(done, "it killed the zombie (hits %d, zombie health %.1f, events %s)" % [fighting.hit_count, zombie.health, str(run.events.slice(maxi(run.events.size() - 6, 0)))])
	if not done:
		return
	var cornered: int = 0
	var fled: int = 0
	for record: Dictionary in records:
		cornered += 1 if str(record[NpcUtilityDecider.KEY_HARD_INTERRUPT]) == NpcUtilityDecider.HARD_CORNERED else 0
		fled += 1 if str(record[NpcUtilityDecider.KEY_CHOSEN]) == NpcBehaviours.ACTION_FLEE else 0
	assert_true(cornered >= 1, "the decision layer found it cornered")
	assert_eq(fled, 0, "it could not flee")
	var state: NpcBehaviourState = run.behaviour_of(npc_id)
	var hits: int = state.count_of(NpcBehaviours.COUNT_FIGHT_HIT)
	assert_true(hits >= 2, "it took more than one swing (%d)" % hits)
	assert_eq(hits, fighting.hit_count)
	assert_eq(state.count_of(NpcBehaviours.COUNT_FIGHT_KILL), 1)
	assert_ne(npc.rng.state, rng_before, "the damage rolls come from its own generator")
	# The players' melee rules: the weapon's damage, its wear, the attacker.
	var killed_by: String = ""
	var damages: PackedFloat32Array = []
	for event: Dictionary in zombies.drain_events():
		if str(event.get("zombie_id", "")) != zombie_id:
			continue
		if str(event["event_type"]) == ZombieService.EVENT_DIED:
			killed_by = str(event["source_id"])
		elif str(event["event_type"]) == ZombieService.EVENT_DAMAGED and str(event["source_id"]) == npc_id:
			damages.append(float(event["damage"]))
	assert_eq(killed_by, npc_id, "the zombie died by the NPC's hand")
	assert_eq(damages.size(), hits)
	var combat: CombatSettings = CombatSettings.load_or_default()
	for amount: float in damages:
		assert_true(amount >= pipe.base_damage * combat.damage_roll_min - 0.001 and amount <= pipe.base_damage * combat.damage_roll_max + 0.001, "a hit does the weapon's damage (%.2f)" % amount)
	var pipe_item: ItemInstance = null
	for item: ItemInstance in world.inventory.items_in_inventory(carried):
		if item.definition_id == PIPE:
			pipe_item = item
	assert_not_null(pipe_item)
	if pipe_item != null:
		assert_eq(pipe.uses_left(pipe_item.condition), pipe.max_durability - hits, "every hit wore the weapon")
	assert_true(NpcVitals.of(npc).is_alive(), "it lived")
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	var seen: int = 0
	for memory_id: String in memories.memory_ids():
		seen += 1 if memories.memory(memory_id).event_type == NpcSurvivalSense.MEMORY_ZOMBIE_SEEN else 0
	assert_eq(seen, 1, "and remembers where the zombie was")
	print("[f29] cornered: %d swings, %d hits (%s), NPC health %.1f, wounds %d" % [fighting.swing_count, hits, str(damages), NpcVitals.of(npc).health, NpcVitals.of(npc).injuries.size()])
	_no_errors()
	run.finish()


func test_an_npc_that_cannot_shake_a_zombie_off_stops_fleeing_and_fights() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var npc_id: String = scene["npc_id"]
	var world: ServerWorld = run.world
	var npc: NpcState = run.npcs().get_npc(npc_id)
	var settings: NpcScavengeSettings = run.decider.survival().settings
	run.behaviours.cancel(world, run.npcs(), npc)
	run.npcs().set_npc_transform(world, npc_id, scene["home_position"], 0.0)
	var zombies: ZombieService = _zombies(world)
	var zombie_id: String = str(zombies.spawn_zombie(world, npc.position, 0.0).event["zombie_id"])
	var zombie: ZombieState = zombies.get_zombie(zombie_id)
	var flee_tick: Array[int] = [-1]
	var fight_tick: Array[int] = [-1]
	run.behaviours.behaviour_started.connect(func(started_id: String, action_id: String, _info: Dictionary) -> void:
		if started_id != npc_id:
			return
		if action_id == NpcBehaviours.ACTION_FLEE and flee_tick[0] < 0:
			flee_tick[0] = run.tick
		if action_id == NpcBehaviours.ACTION_FIGHT and fight_tick[0] < 0:
			fight_tick[0] = run.tick)
	# The zombie keeps up with it, whatever it does.
	var done: bool = _run_until(run, func() -> bool:
		if zombie.is_alive():
			zombie.position = npc.position
		return fight_tick[0] >= 0 or not NpcVitals.of(npc).is_alive())
	assert_true(done and fight_tick[0] >= 0, "it began to fight (flee at tick %d)" % flee_tick[0])
	if fight_tick[0] < 0:
		return
	assert_true(flee_tick[0] >= 0 and flee_tick[0] < fight_tick[0], "it tried to flee first")
	var fled_ticks: int = fight_tick[0] - flee_tick[0]
	assert_true(float(fled_ticks) * TICK >= settings.fight_after_fleeing_sec - TICK, "it fled for a while before it gave that up (%d ticks)" % fled_ticks)
	assert_true(float(fled_ticks) * TICK <= settings.fight_after_fleeing_sec + 2.0, "and not for long (%d ticks)" % fled_ticks)
	# A zombie that is not adjacent is fled from, not fought.
	assert_true(zombies.apply_damage_to_zombie(zombie_id, 100000.0, "test_setup").ok)
	run.run_ticks(60)
	_no_errors()
	run.finish()


# ------------------------------------------------------------ saving

func test_a_trip_goes_on_after_a_save_and_a_restart() -> void:
	var first: NpcLifeRun = NpcLifeRun.begin_on_disk(WORLD, _root, TICK, _procedural())
	var scene: Dictionary = _scene(first)
	if scene.is_empty():
		return
	var npc_id: String = scene["npc_id"]
	var home_id: String = scene["home_id"]
	var target: String = (scene["neighbours"] as PackedStringArray)[0]
	var world: ServerWorld = first.world
	var box: ContainerInstance = _containers_of(world, target)[0]
	_put(world, box.inventory_id, FOOD, 3)
	_put(world, box.inventory_id, BANDAGE, 1)
	var npc: NpcState = first.npcs().get_npc(npc_id)
	# Something to remember, and something in its pocket.
	assert_true(first.decider.survival().note_zombie_seen(world, npc, scene["home_position"] + Vector3(200.0, 0.0, 0.0)))
	_put(world, first.behaviour_of(npc_id).inventory_id, KNIFE, 1)
	var trip: NpcScavengeState = _trip(first, npc_id)
	var executor: NpcExecutor = first.behaviours.movement_executor()
	# Half way to the building next door.
	var on_the_way: bool = _run_until(first, func() -> bool:
		return trip.phase == NpcScavengeState.PHASE_TO_CONTAINER and trip.building_id == target and executor.phase_of(npc_id) == NpcExecutorState.PHASE_MOVING and _flat(npc.position, scene["home_position"]) > 3.0)
	assert_true(on_the_way, "test setup: it is on its way to the building (%s %s)" % [trip.phase, trip.building_id])
	if not on_the_way:
		return
	assert_eq(first.persistence.save(world), OK)
	var saved: Dictionary = NpcLifeRun.as_saved(first.npcs().npc_document(npc_id))
	var saved_position: Vector3 = npc.position
	assert_eq(NpcLifeRun.copy_tree(ProjectSettings.globalize_path(_root), ProjectSettings.globalize_path(_root + "_copy")), OK, "test setup: a copy of the save")
	# The server that was not stopped finishes the trip.
	var done: bool = _run_until(first, func() -> bool: return not trip.result_of(target).is_empty() and not trip.is_on_trip())
	assert_true(done, "the trip ends on the server that went on")
	var expected: Dictionary = {
		"result": trip.result_of(target),
		"home_food": _units_in_building(world, home_id, FOOD) + first.behaviour_of(npc_id).count_of("eat"),
		"bandages": _units(world, first.behaviour_of(npc_id).inventory_id, BANDAGE),
		"knives": _units(world, first.behaviour_of(npc_id).inventory_id, KNIFE),
		"left_food": _units_in_building(world, target, FOOD),
	}
	first.finish()

	# The restarted server: the same NPC, in the middle of the same trip.
	var second: NpcLifeRun = NpcLifeRun.begin_on_disk(WORLD, _root + "_copy", TICK, _procedural())
	assert_not_null(second, "the save loads")
	if second == null:
		return
	second.observer.position = scene["home_position"]
	var arrived: bool = _run_until(second, func() -> bool: return second.npcs().get_npc(npc_id) != null)
	assert_true(arrived, "the NPC comes into memory")
	if not arrived:
		return
	var restored_npc: NpcState = second.npcs().get_npc(npc_id)
	var restored: Dictionary = NpcLifeRun.as_saved(second.npcs().npc_document(npc_id))
	if not second.npcs().is_awake(npc_id) or second.tick <= 1:
		# Looked at before it took a step: the document is the saved one.
		for component_id: String in [NpcScavengeState.COMPONENT_ID, NpcMemoryStore.COMPONENT_ID, NpcHome.COMPONENT_ID]:
			assert_eq(NpcLifeRun.first_difference((restored[NpcState.KEY_COMPONENTS] as Dictionary)[component_id], (saved[NpcState.KEY_COMPONENTS] as Dictionary)[component_id], component_id), "", "%s is as it was saved" % component_id)
	var restored_trip: NpcScavengeState = NpcScavengeState.of(restored_npc)
	assert_eq(restored_trip.building_id, target, "it is still on its way to the same building")
	assert_true(restored_trip.is_on_trip())
	assert_true(_flat(restored_npc.position, saved_position) < 3.0, "about where it was (%.2f m)" % _flat(restored_npc.position, saved_position))
	assert_eq(_units(second.world, second.behaviour_of(npc_id).inventory_id, KNIFE), 1, "with what it carried")
	assert_eq((restored_npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore).count(), 1, "and what it remembered")
	assert_true(second.behaviour_of(npc_id).is_running() and second.behaviour_of(npc_id).action_id == SCAVENGE)
	var failures_before: int = second.behaviours.failed_count
	done = _run_until(second, func() -> bool: return not restored_trip.result_of(target).is_empty() and not restored_trip.is_on_trip())
	assert_true(done, "the trip ends on the restarted server too (events %s)" % str(second.events.slice(maxi(second.events.size() - 6, 0))))
	assert_eq(second.behaviours.failed_count, failures_before, "without a failure: the same trip, not a new one")
	var actual: Dictionary = {
		"result": restored_trip.result_of(target),
		"home_food": _units_in_building(second.world, home_id, FOOD) + second.behaviour_of(npc_id).count_of("eat"),
		"bandages": _units(second.world, second.behaviour_of(npc_id).inventory_id, BANDAGE),
		"knives": _units(second.world, second.behaviour_of(npc_id).inventory_id, KNIFE),
		"left_food": _units_in_building(second.world, target, FOOD),
	}
	assert_eq(actual, expected, "the restarted server ends the trip as the other did")
	assert_eq(int(expected["home_food"]), 3)
	assert_eq(int(expected["bandages"]), 1)
	_no_errors()
	second.finish()


func test_a_trip_goes_on_after_the_npcs_cell_left_memory() -> void:
	var scene: Dictionary = _scene(NpcLifeRun.begin_in_memory(WORLD, TICK, 0, _procedural()))
	if scene.is_empty():
		return
	var run: NpcLifeRun = scene["run"]
	var npc_id: String = scene["npc_id"]
	var world: ServerWorld = run.world
	var target: String = (scene["neighbours"] as PackedStringArray)[0]
	_put(world, _containers_of(world, target)[0].inventory_id, FOOD, 2)
	var executor: NpcExecutor = run.behaviours.movement_executor()
	var on_the_way: bool = _run_until(run, func() -> bool:
		var trip: NpcScavengeState = _trip(run, npc_id)
		return trip.phase == NpcScavengeState.PHASE_TO_CONTAINER and trip.building_id == target and executor.phase_of(npc_id) == NpcExecutorState.PHASE_MOVING and _flat(run.npcs().get_npc(npc_id).position, scene["home_position"]) > 3.0)
	assert_true(on_the_way, "test setup: it is on its way")
	if not on_the_way:
		return
	# The player goes far away: the NPC's cell is saved and released. Nothing
	# happens to it while it is away (docs/15 F29-011: no far simulation).
	run.observer.position = FAR_AWAY
	# [where it stood, the building of its trip] when it was last in memory.
	var last: Array = [run.npcs().get_npc(npc_id).position, ""]
	var gone: bool = _run_until(run, func() -> bool:
		var seen: NpcState = run.npcs().get_npc(npc_id)
		if seen != null:
			last[0] = seen.position
			last[1] = NpcScavengeState.of(seen).building_id
		return seen == null)
	assert_true(gone, "the NPC left memory")
	var left_at: Vector3 = last[0]
	assert_eq(str(last[1]), target, "test setup: it left memory in the middle of the trip")
	run.run_ticks(600)
	assert_null(run.npcs().get_npc(npc_id))
	# The player comes back: it goes on where it stopped.
	run.observer.position = scene["home_position"]
	var back: bool = _run_until(run, func() -> bool: return run.npcs().is_awake(npc_id))
	assert_true(back, "the NPC is back")
	if not back:
		return
	var trip: NpcScavengeState = _trip(run, npc_id)
	assert_true(_flat(run.npcs().get_npc(npc_id).position, left_at) < 3.0, "where it was")
	assert_true(trip.is_on_trip() and trip.building_id == target, "on the same trip")
	var failures_before: int = run.behaviours.failed_count
	var done: bool = _run_until(run, func() -> bool: return not _trip(run, npc_id).result_of(target).is_empty() and not _trip(run, npc_id).is_on_trip())
	assert_true(done, "it finishes the trip (events %s)" % str(run.events.slice(maxi(run.events.size() - 6, 0))))
	assert_eq(run.behaviours.failed_count, failures_before, "the same trip, not a new one")
	assert_eq(_units_in_building(world, str(scene["home_id"]), FOOD) + run.behaviour_of(npc_id).count_of("eat"), 2, "the food came home")
	_no_errors()
	run.finish()


# ------------------------------------------------------------ cost

static func _percentile(sorted: PackedFloat32Array, fraction: float) -> float:
	return sorted[mini(int(float(sorted.size()) * fraction), sorted.size() - 1)]


## `count` NPCs living alone in the houses of one town, all with empty
## houses and loot around them, for MEASURE_TICKS ticks of 1/60 s.
func _measure(count: int) -> void:
	var run: NpcLifeRun = NpcLifeRun.begin_in_memory("%s_%d" % [WORLD, count], MEASURE_TICK, 64, _procedural())
	var scene: Dictionary = _scene(run)
	if scene.is_empty():
		return
	var world: ServerWorld = run.world
	var service: NpcService = run.npcs()
	var generator: ProceduralMapGenerator = _map(world).generator()
	var grid: StructureGrid = StructureGrid.new(MODULE_M)
	var definitions: PackedStringArray = NpcRoster.load_or_null().npc_definition_ids
	# More NPCs: each alone in one of the buildings around the first.
	var homes: PackedStringArray = [str(scene["home_id"])]
	var around: PackedStringArray = []
	for cell: Vector2i in world.cell_grid.cells_within(world.cell_grid.cell_of(scene["home_position"]), 2):
		if not _map(world).is_cell_complete(WorldCellGrid.id_of(cell)) or not world.is_cell_simulated(WorldCellGrid.id_of(cell)):
			continue
		for building: ProceduralBuilding in generator.plan_cell(cell).buildings:
			if building.building_id() != str(scene["home_id"]) and not building.definition.containers.is_empty() and NpcHomeLayout.of(building.definition).is_valid():
				around.append(building.building_id())
	assert_true(around.size() >= count * 2, "test setup: enough buildings around (%d)" % around.size())
	for index: int in range(count - 1):
		var layout: NpcHomeLayout = NpcHomeLayout.of(generator.building_by_id(around[index * 2]).definition)
		var spawned: ActionResult = service.spawn_npc(world, definitions[index % definitions.size()], grid.tile_center(layout.home_tile()))
		assert_true(spawned.ok, "test setup: NPC %d (%s)" % [index, spawned.reason])
		if not spawned.ok:
			return
		var spawned_npc: NpcState = service.get_npc(str(spawned.event[NpcService.KEY_NPC_ID]))
		NpcHome.of(spawned_npc).set_generated(layout.building_id, layout.home_tile())
		# (An NPC of the roster has its home when it wakes; these got theirs
		# a moment later.)
		run.behaviours.scavenging().queue_cells_of(world, spawned_npc)
		homes.append(layout.building_id)
	# Every house empty, two rations and a bandage in every other building.
	for building_id: String in around:
		_empty(world, building_id)
		if not homes.has(building_id):
			var box: ContainerInstance = _containers_of(world, building_id)[0]
			_put(world, box.inventory_id, FOOD, 2)
			_put(world, box.inventory_id, BANDAGE, 1)
	var scavenging: NpcScavenging = run.behaviours.scavenging()
	var stage_ms: PackedFloat32Array = []
	var tick_ms: PackedFloat32Array = []
	var worst_pick_usec: int = 0
	var picks: int = 0
	# The slowest tick of the NPC stages: [ms, tick, executor ms, behaviours ms].
	var slowest: Array = [0.0, 0, 0.0, 0.0]
	var executor: NpcExecutor = run.behaviours.movement_executor()
	var last_trip_count: int = scavenging.trip_count
	var decisions_before: int = run.decider.decision_count
	var evaluations_before: int = run.decider.evaluation_count
	for tick: int in range(MEASURE_TICKS):
		var started: int = Time.get_ticks_usec()
		run.step()
		tick_ms.append(float(Time.get_ticks_usec() - started) / 1000.0)
		stage_ms.append(service.last_step_msec)
		if service.last_step_msec > float(slowest[0]):
			slowest = [service.last_step_msec, tick, float(executor.last_step_usec) / 1000.0, float(run.behaviours.last_step_usec) / 1000.0]
		if scavenging.trip_count != last_trip_count:
			last_trip_count = scavenging.trip_count
			picks += 1
			worst_pick_usec = maxi(worst_pick_usec, scavenging.last_pick_usec)
	var sorted_stage: PackedFloat32Array = stage_ms.duplicate()
	sorted_stage.sort()
	var sorted_tick: PackedFloat32Array = tick_ms.duplicate()
	sorted_tick.sort()
	var on_trip: int = 0
	for npc_id: String in service.awake_npc_ids():
		on_trip += 1 if _trip(run, npc_id).is_on_trip() else 0
	print("[f29 measure] %d lone NPCs in one town, %d ticks at 60 Hz: NPC stages per tick median %.4f ms, 99%% %.4f ms, 99.9%% %.4f ms, worst %.4f ms; whole server tick median %.4f ms, worst %.4f ms; %d decisions (%d evaluations), %d trips begun (worst choice of a building %.3f ms), %d searches, %d units taken, %d on a trip at the end" % [
		service.awake_count(), MEASURE_TICKS, _percentile(sorted_stage, 0.5), _percentile(sorted_stage, 0.99), _percentile(sorted_stage, 0.999), sorted_stage[sorted_stage.size() - 1],
		_percentile(sorted_tick, 0.5), sorted_tick[sorted_tick.size() - 1],
		run.decider.decision_count - decisions_before, run.decider.evaluation_count - evaluations_before,
		picks, float(worst_pick_usec) / 1000.0, scavenging.search_count, scavenging.taken_unit_count, on_trip])
	var slowest_tick: int = 0
	for tick: int in range(tick_ms.size()):
		slowest_tick = tick if tick_ms[tick] > tick_ms[slowest_tick] else slowest_tick
	print("[f29 measure] %d NPCs: slowest tick of the NPC stages %.4f ms (tick %d: executor %.4f ms, behaviours %.4f ms, the rest is the scheduler and the decisions); slowest server tick %.4f ms (tick %d, NPC stages %.4f ms of it)" % [count, float(slowest[0]), int(slowest[1]), float(slowest[2]), float(slowest[3]), tick_ms[slowest_tick], slowest_tick, stage_ms[slowest_tick]])
	assert_eq(service.awake_count(), count, "every NPC is simulated")
	assert_true(picks >= count, "every NPC went on a trip (%d trips)" % picks)
	assert_true(scavenging.taken_unit_count > 0, "and they found things")
	assert_time_bound(_percentile(sorted_stage, 0.99), STAGE_BOUND_MS, "NPC stages, %d scavenging NPCs, 99%%" % count)
	assert_time_bound(float(worst_pick_usec) / 1000.0, PICK_BOUND_MS, "choosing a building, %d NPCs, worst" % count)
	_no_errors()
	run.finish()


func test_ten_scavenging_npcs_cost_little_per_tick() -> void:
	_measure(10)


func test_twenty_five_scavenging_npcs_cost_little_per_tick() -> void:
	_measure(25)
