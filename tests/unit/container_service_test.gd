extends TestCase
## P3-3 (docs/00 ADR-021 "창고에 넣어서 옮기는 방식", ADR-026, docs/09 §15.3):
## ContainerService, the server rules of containers. A container stands in
## the world and holds items; a player near it opens it (the first opening
## is a search that rolls its loot, once), takes stacks out and puts stacks
## in. Server rules only, no network (tests/integration/container_net_test.gd);
## cells and save documents: tests/unit/container_cell_test.gd. Time is the
## injected world clock: no test waits.

const WORLD: String = "container_service_test_world"
const NEVER: float = 1.0e9
const TICK: float = 0.05
const LETHAL_DAMAGE: float = 100000.0
const LIGHT_DAMAGE: float = 1.0
const ZOMBIE: String = "zombie_000001"
const MISSING_ITEM_ID: String = "item_999999"
const MISSING_CONTAINER_ID: String = "container_999999"
const FOOD: String = "t33_food"
const FOOD_MAX: int = 5
const BULK: String = "t33_bulk"
const BULK_MAX: int = 10
const PLAIN: String = "t33_plain"
## A storage box nobody filled, and a locker that is filled when searched.
const BOX: String = "t33_box"
const BOX_SLOTS: int = 3
const LOCKER: String = "t33_locker"
const LOCKER_SLOTS: int = 6
const LOOT: String = "t33_loot"
const LOOT_ROLLS: int = 3
const SEARCH_SEC: float = 2.0
const RANGE_M: float = 2.5
## Players spawn at the origin.
const NEAR: Vector3 = Vector3(1.0, 0.0, 0.0)
const ALSO_NEAR: Vector3 = Vector3(0.0, 0.0, 1.5)
const OUT_OF_REACH: Vector3 = Vector3(6.0, 0.0, 0.0)
const FAR_AWAY: Vector3 = Vector3(40.0, 0.0, 0.0)

var _settings: ContainerSettings = null
var _survival_settings: SurvivalSettings = null
var _gameplay: GameplaySettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = ContainerSettings.new()
	_settings.interact_range_m = RANGE_M
	_settings.search_duration_sec = 0.0
	_survival_settings = SurvivalSettings.new()
	_survival_settings.respawn_delay_sec = NEVER
	_survival_settings.health_recovery_per_world_sec = 0.0
	_survival_settings.wound_recovery_per_world_sec = 0.0
	_gameplay = GameplaySettings.new()


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.gameplay = _gameplay
	config.survival = _survival_settings
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 1.0
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.containers = _settings
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	for row: Array in [[FOOD, FOOD_MAX], [BULK, BULK_MAX], [PLAIN, 1]]:
		var definition: ItemDefinition = ItemDefinition.new()
		definition.definition_id = str(row[0])
		definition.max_stack = int(row[1])
		catalog.add(definition)
	config.catalog = catalog
	var table: LootTable = LootTable.new()
	table.table_id = LOOT
	table.rolls_min = LOOT_ROLLS
	table.rolls_max = LOOT_ROLLS
	table.item_definition_ids = PackedStringArray([FOOD, BULK])
	table.weights = PackedFloat32Array([1.0, 1.0])
	table.quantities_min = PackedInt32Array([1, 1])
	table.quantities_max = PackedInt32Array([3, 6])
	config.loot_tables = LootTableCatalog.new()
	config.loot_tables.add(table)
	config.container_definitions = ContainerCatalog.new()
	var box: ContainerDefinition = ContainerDefinition.new()
	box.definition_id = BOX
	box.slot_count = BOX_SLOTS
	config.container_definitions.add(box)
	var locker: ContainerDefinition = ContainerDefinition.new()
	locker.definition_id = LOCKER
	locker.slot_count = LOCKER_SLOTS
	locker.loot_table_id = LOOT
	config.container_definitions.add(locker)
	return config


func _world() -> ServerWorld:
	var config: CompositionConfig = _config()
	var errors: PackedStringArray = config.validate()
	if not errors.is_empty():
		fail("test setup: invalid config: " + "; ".join(errors))
	return ServerComposition.create_world(WORLD, config)


func _service(world: ServerWorld) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


## A new container; returns its id ("" and a failure when it was refused).
func _container(world: ServerWorld, definition_id: String, position: Vector3 = NEAR) -> String:
	var created: ActionResult = _service(world).create_container(world, definition_id, position)
	if not created.ok:
		fail("test setup: container refused: " + created.reason)
		return ""
	return str(created.event.get("container_id", ""))


## Spawns an item where `player` stands and lets it pick the item up.
func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, world.cell_id_at(player.position), player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


func _open(world: ServerWorld, player: PlayerState, container_id: String) -> void:
	var opened: ActionResult = _service(world).try_open(world, player.player_id, container_id)
	if not opened.ok:
		fail("test setup: open refused: " + opened.reason)


## [definition, quantity] of what an inventory holds, in slot order.
func _rows(world: ServerWorld, inventory_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in world.inventory.items_in_inventory(inventory_id):
		rows.append([item.definition_id, item.quantity])
	return rows


func _carried(world: ServerWorld, player: PlayerState) -> Array:
	return _rows(world, player.inventory_id)


## [definition, quantity] of what a container holds, in slot order.
func _stored(world: ServerWorld, container_id: String) -> Array:
	var rows: Array = []
	for entry: Dictionary in _service(world).contents_of(container_id):
		rows.append([entry["definition_id"], entry["quantity"]])
	return rows


func _first_stored_id(world: ServerWorld, container_id: String, definition_id: String = "") -> String:
	for entry: Dictionary in _service(world).contents_of(container_id):
		if definition_id.is_empty() or str(entry["definition_id"]) == definition_id:
			return str(entry["item_instance_id"])
	return ""


## Units of one definition in the given inventories and containers together.
func _units(world: ServerWorld, definition_id: String, players: Array, container_ids: Array) -> int:
	var total: int = 0
	for player: PlayerState in players:
		for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
			if item.definition_id == definition_id:
				total += item.quantity
	for container_id: String in container_ids:
		for entry: Dictionary in _service(world).contents_of(container_id):
			if str(entry["definition_id"]) == definition_id:
				total += int(entry["quantity"])
	return total


## Every item id in the given inventories and containers (to check that no
## two stacks share an id).
func _ids(world: ServerWorld, players: Array, container_ids: Array) -> Array:
	var ids: Array = []
	for player: PlayerState in players:
		for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
			ids.append(item.item_instance_id)
	for container_id: String in container_ids:
		for entry: Dictionary in _service(world).contents_of(container_id):
			ids.append(str(entry["item_instance_id"]))
	return ids


func _are_unique(ids: Array) -> bool:
	var seen: Dictionary = {}
	for id: Variant in ids:
		if seen.has(id):
			return false
		seen[id] = true
	return true


func _events_of_type(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			matching.append(event)
	return matching


# ------------------------------------------------------------ creation

func test_a_created_container_is_a_registered_indexed_world_entity() -> void:
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	assert_not_null(service, "the composition registers the container system")
	# A player in the world: the cells around the origin are in memory.
	world.join("alice")
	var created: ActionResult = service.create_container(world, BOX, NEAR)
	assert_true(created.ok, created.reason)
	var container_id: String = str(created.event.get("container_id", ""))
	assert_true(container_id.begins_with("container_"), "a stable id of its own kind: " + container_id)
	assert_eq(world.registry.kind_of(container_id), ContainerService.ENTITY_KIND_CONTAINER)
	var container: ContainerInstance = service.get_container(container_id)
	assert_not_null(container)
	assert_eq(container.definition_id, BOX)
	assert_eq(container.position, NEAR)
	assert_eq(container.cell_id, world.cell_id_at(NEAR), "it belongs to the cell of its position")
	assert_eq(world.cell_index.cell_of(container_id), world.cell_id_at(NEAR))
	assert_eq(world.cell_index.kind_of(container_id), ContainerService.ENTITY_KIND_CONTAINER)
	assert_eq(container.slot_count, BOX_SLOTS)
	assert_true(container.searched, "a container without a loot table has nothing to search for")
	assert_true(world.inventory.is_detached_inventory(container.inventory_id), "its content is an inventory of the inventory service")
	assert_eq(service.contents_of(container_id).size(), 0)
	var events: Array[Dictionary] = service.drain_events()
	assert_eq(events.size(), 1)
	assert_eq(events[0].get("event_type", ""), ContainerService.EVENT_ADDED)
	assert_eq(events[0].get("container_id", ""), container_id)
	assert_eq(events[0].get("cell_id", ""), world.cell_id_at(NEAR))
	assert_true(SaveService.is_json_safe(events[0]), "events are plain data")
	var row: Dictionary = service.public_row(container)
	assert_eq(row.keys().size(), 4, "the public row: id, definition, position, searched")
	assert_false(row.has("inventory_id"), "what is inside is not public")
	# A container with a loot table starts unsearched and empty.
	var locker_id: String = _container(world, LOCKER, ALSO_NEAR)
	assert_false(service.get_container(locker_id).searched)
	assert_eq(service.contents_of(locker_id).size(), 0, "nothing is rolled before the first search")
	assert_eq(service.container_count(), 2)
	assert_ne(locker_id, container_id)


func test_creation_refusals_change_nothing() -> void:
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	assert_eq(service.create_container(world, BOX, NEAR).reason, ContainerService.REASON_CELL_NOT_LOADED, "nobody is in the world: no cell is in memory")
	world.join("alice")
	var before_sequence: int = world.ids.get_next_sequence()
	assert_eq(service.create_container(world, BOX, Vector3(240.0, 0.0, 240.0)).reason, ContainerService.REASON_CELL_NOT_LOADED, "a cell far from every player is not in memory")
	assert_eq(service.create_container(world, "no_such_container", NEAR).reason, ContainerService.REASON_UNKNOWN_DEFINITION)
	assert_eq(service.create_container(world, BOX, Vector3(NAN, 0.0, 0.0)).reason, ContainerService.REASON_BAD_POSITION)
	assert_eq(service.create_container(world, BOX, Vector3(_gameplay.world_half_extent_m + 1.0, 0.0, 0.0)).reason, ContainerService.REASON_BAD_POSITION, "outside the play area")
	assert_eq(service.create_container(world, BOX, NEAR, "no_such_table").reason, ContainerService.REASON_UNKNOWN_LOOT_TABLE)
	assert_eq(service.container_count(), 0)
	assert_eq(world.ids.get_next_sequence(), before_sequence, "no id was spent on a refused container")
	assert_eq(service.drain_events().size(), 0)
	# The same source key twice: the second is refused (a map is seeded once).
	assert_true(service.create_container(world, BOX, NEAR, "", "map/a/0").ok)
	assert_eq(service.create_container(world, BOX, ALSO_NEAR, "", "map/a/0").reason, ContainerService.REASON_SOURCE_EXISTS)
	assert_true(service.has_source("map/a/0"))
	assert_eq(service.container_count(), 1)
	# The per-cell limit.
	_settings.max_containers_per_cell = 2
	assert_true(service.create_container(world, BOX, ALSO_NEAR).ok)
	assert_eq(service.create_container(world, BOX, Vector3(2.0, 0.0, 2.0)).reason, ContainerService.REASON_LIMIT)


# ------------------------------------------------------------ search and loot

func test_the_first_opening_rolls_the_loot_exactly_once() -> void:
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var locker_id: String = _container(world, LOCKER)
	service.drain_events()
	var opened: ActionResult = service.try_open(world, alice.player_id, locker_id)
	assert_true(opened.ok, opened.reason)
	assert_true(service.get_container(locker_id).searched)
	assert_eq(service.loot_roll_count, 1)
	var first: Array = _stored(world, locker_id)
	assert_true(first.size() >= 1 and first.size() <= LOOT_ROLLS, "the table rolls %d stacks" % LOOT_ROLLS)
	for row: Array in first:
		assert_true(row[0] == FOOD or row[0] == BULK, "only what the table lists")
	var events: Array[Dictionary] = service.drain_events()
	assert_eq(_events_of_type(events, ContainerService.EVENT_CHANGED).size(), 1, "everybody near learns that it was searched")
	var sessions: Array[Dictionary] = _events_of_type(events, ContainerService.EVENT_SESSION)
	assert_eq(sessions.size(), 1)
	assert_eq(sessions[0].get("phase", ""), ContainerService.PHASE_OPEN)
	assert_eq(sessions[0].get("player_id", ""), alice.player_id)
	assert_eq((sessions[0].get("items", []) as Array).size(), first.size(), "the opener is told what is inside")
	# Closing and opening again, by the same player or by another, rolls nothing.
	assert_true(service.try_close(world, alice.player_id, locker_id).ok)
	_open(world, alice, locker_id)
	var bob: PlayerState = world.join("bob")
	_open(world, bob, locker_id)
	assert_eq(service.loot_roll_count, 1, "rolled once, whoever opens it and however often")
	assert_eq(_stored(world, locker_id), first)
	# An emptied container stays empty.
	for entry: Dictionary in service.contents_of(locker_id):
		assert_true(service.try_take(world, alice.player_id, locker_id, str(entry["item_instance_id"]), InventoryService.WHOLE_STACK).ok)
	assert_eq(service.contents_of(locker_id).size(), 0)
	service.try_close(world, alice.player_id, locker_id)
	service.try_close(world, bob.player_id, locker_id)
	_run(world, 5.0)
	_open(world, bob, locker_id)
	assert_eq(service.contents_of(locker_id).size(), 0, "nothing comes back")
	assert_eq(service.loot_roll_count, 1)


func test_loot_is_decided_by_the_world_seed_and_the_container_id() -> void:
	# Two worlds built the same way: container n holds the same in both.
	var contents: Array = []
	for run: int in range(2):
		var world: ServerWorld = _world()
		var service: ContainerService = _service(world)
		var alice: PlayerState = world.join("alice")
		var per_container: Array = []
		for index: int in range(8):
			var locker_id: String = _container(world, LOCKER, Vector3(1.0, 0.0, -1.0 + float(index) * 0.25))
			_open(world, alice, locker_id)
			per_container.append(_stored(world, locker_id))
		contents.append(per_container)
	assert_eq(contents[0], contents[1], "the same seed and the same ids give the same loot")
	var different: Dictionary = {}
	for rows: Array in contents[0]:
		different[str(rows)] = true
	assert_true(different.size() > 1, "containers of one kind do not all hold the same")
	# Another loot seed: another world.
	_settings.loot_seed += 1
	var other: ServerWorld = _world()
	var other_alice: PlayerState = other.join("alice")
	var other_contents: Array = []
	for index: int in range(8):
		var locker_id: String = _container(other, LOCKER, Vector3(1.0, 0.0, -1.0 + float(index) * 0.25))
		_open(other, other_alice, locker_id)
		other_contents.append(_stored(other, locker_id))
	assert_ne(other_contents, contents[0], "the loot depends on the seed")


func test_the_first_search_takes_action_time() -> void:
	_settings.search_duration_sec = SEARCH_SEC
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var locker_id: String = _container(world, LOCKER)
	service.drain_events()
	var opened: ActionResult = service.try_open(world, alice.player_id, locker_id)
	assert_true(opened.ok, opened.reason)
	assert_eq(service.session_phase(alice.player_id), ContainerService.PHASE_SEARCHING)
	assert_false(service.get_container(locker_id).searched, "nothing is decided while the search runs")
	assert_eq(service.loot_roll_count, 0)
	var started: Array[Dictionary] = _events_of_type(service.drain_events(), ContainerService.EVENT_SESSION)
	assert_eq(started.size(), 1)
	assert_eq(started[0].get("phase", ""), ContainerService.PHASE_SEARCHING)
	assert_eq(float(started[0].get("search_sec", 0.0)), SEARCH_SEC)
	assert_eq((started[0].get("items", []) as Array).size(), 0, "a searcher is not told the contents yet")
	# Taking and putting wait for the search.
	assert_eq(service.try_take(world, alice.player_id, locker_id, MISSING_ITEM_ID, 1).reason, ContainerService.REASON_SEARCHING)
	assert_eq(service.try_open(world, alice.player_id, locker_id).reason, ContainerService.REASON_SEARCHING)
	_run(world, SEARCH_SEC - 0.5)
	assert_eq(service.session_phase(alice.player_id), ContainerService.PHASE_SEARCHING, "not yet")
	_run(world, 0.6)
	assert_eq(service.session_phase(alice.player_id), ContainerService.PHASE_OPEN)
	assert_true(service.get_container(locker_id).searched)
	assert_eq(service.loot_roll_count, 1)
	var finished: Array[Dictionary] = _events_of_type(service.drain_events(), ContainerService.EVENT_SESSION)
	assert_eq(finished.size(), 1)
	assert_eq(finished[0].get("phase", ""), ContainerService.PHASE_OPEN)
	assert_true((finished[0].get("items", []) as Array).size() >= 1)
	# A searched container opens at once for everybody afterwards.
	var bob: PlayerState = world.join("bob")
	assert_true(service.try_open(world, bob.player_id, locker_id).ok)
	assert_eq(service.session_phase(bob.player_id), ContainerService.PHASE_OPEN)
	# A container without loot is never searched.
	var box_id: String = _container(world, BOX, ALSO_NEAR)
	assert_true(service.try_open(world, bob.player_id, box_id).ok)
	assert_eq(service.session_phase(bob.player_id), ContainerService.PHASE_OPEN)


func test_two_searchers_finish_together() -> void:
	_settings.search_duration_sec = SEARCH_SEC
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var locker_id: String = _container(world, LOCKER)
	_open(world, alice, locker_id)
	_run(world, SEARCH_SEC * 0.5)
	_open(world, bob, locker_id)
	assert_eq(service.session_phase(bob.player_id), ContainerService.PHASE_SEARCHING)
	_run(world, SEARCH_SEC * 0.5 + 0.1)
	assert_eq(service.session_phase(alice.player_id), ContainerService.PHASE_OPEN)
	assert_eq(service.session_phase(bob.player_id), ContainerService.PHASE_OPEN, "the container is searched: the second searcher sees it too")
	assert_eq(service.loot_roll_count, 1)


func test_a_search_is_interrupted_by_leaving_being_hit_and_lying_down() -> void:
	_settings.search_duration_sec = SEARCH_SEC
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var locker_id: String = _container(world, LOCKER)
	# 1. walking away
	_open(world, alice, locker_id)
	service.drain_events()
	alice.position = OUT_OF_REACH
	_run(world, TICK)
	assert_eq(service.session_phase(alice.player_id), "", "out of reach: the search ended")
	var closed: Array[Dictionary] = _events_of_type(service.drain_events(), ContainerService.EVENT_SESSION)
	assert_eq(closed.size(), 1)
	assert_eq(closed[0].get("phase", ""), ContainerService.PHASE_CLOSED)
	assert_eq(closed[0].get("reason", ""), ContainerService.REASON_TOO_FAR)
	_run(world, SEARCH_SEC * 2.0)
	assert_false(service.get_container(locker_id).searched, "an interrupted search finds nothing")
	# 2. being hit
	alice.position = Vector3.ZERO
	_open(world, alice, locker_id)
	service.drain_events()
	assert_true(_survival(world).apply_damage(alice.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LIGHT_DAMAGE)).ok)
	assert_eq(service.session_phase(alice.player_id), "", "a hit interrupts the search at once")
	closed = _events_of_type(service.drain_events(), ContainerService.EVENT_SESSION)
	assert_eq(closed.size(), 1)
	assert_eq(closed[0].get("reason", ""), ContainerService.REASON_INTERRUPTED)
	# 3. lying down
	_open(world, alice, locker_id)
	service.drain_events()
	assert_true(_survival(world).start_rest(alice.player_id).ok)
	_run(world, TICK)
	assert_eq(service.session_phase(alice.player_id), "")
	closed = _events_of_type(service.drain_events(), ContainerService.EVENT_SESSION)
	assert_eq(closed.size(), 1)
	assert_eq(closed[0].get("reason", ""), "player_resting")
	_survival(world).stop_rest(alice.player_id)
	assert_false(service.get_container(locker_id).searched)
	assert_eq(service.loot_roll_count, 0)
	# A search that is left alone still completes, from the beginning.
	_open(world, alice, locker_id)
	_run(world, SEARCH_SEC + 0.1)
	assert_true(service.get_container(locker_id).searched)
	# A hit does not close a container that is open already.
	assert_true(_survival(world).apply_damage(alice.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LIGHT_DAMAGE)).ok)
	assert_eq(service.session_phase(alice.player_id), ContainerService.PHASE_OPEN)
	# The setting turns the hit rule off.
	_settings.search_interrupted_by_damage = false
	var second_id: String = _container(world, LOCKER, ALSO_NEAR)
	_open(world, alice, second_id)
	assert_true(_survival(world).apply_damage(alice.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LIGHT_DAMAGE)).ok)
	assert_eq(service.session_phase(alice.player_id), ContainerService.PHASE_SEARCHING)


# ------------------------------------------------------------ take and put

func test_put_and_take_whole_stacks_parts_and_merging() -> void:
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var box_id: String = _container(world, BOX)
	var food_id: String = _give(world, alice, FOOD, 4)
	_open(world, alice, box_id)
	service.drain_events()
	# A part of a stack: the carried stack shrinks, a new stack with a new id
	# lies in the container.
	var put: ActionResult = service.try_put(world, alice.player_id, box_id, food_id, 1)
	assert_true(put.ok, put.reason)
	assert_eq(_carried(world, alice), [[FOOD, 3]])
	assert_eq(_stored(world, box_id), [[FOOD, 1]])
	var stored_id: String = _first_stored_id(world, box_id)
	assert_ne(stored_id, food_id, "two stacks never share an id")
	var contents: Array[Dictionary] = _events_of_type(service.drain_events(), ContainerService.EVENT_CONTENTS)
	assert_eq(contents.size(), 1)
	assert_eq(contents[0].get("container_id", ""), box_id)
	assert_eq((contents[0].get("changed", []) as Array).size(), 1)
	assert_eq(str(((contents[0]["changed"] as Array)[0] as Dictionary)["item_instance_id"]), stored_id)
	assert_eq(int(((contents[0]["changed"] as Array)[0] as Dictionary)["quantity"]), 1)
	assert_eq(contents[0].get("viewers", []), [alice.player_id], "the change goes to whoever has it open")
	assert_true(SaveService.is_json_safe(contents[0]))
	# More units of the same kind merge into the stack that lies there.
	assert_true(service.try_put(world, alice.player_id, box_id, food_id, 2).ok)
	assert_eq(_stored(world, box_id), [[FOOD, 3]])
	assert_eq(_first_stored_id(world, box_id), stored_id, "merged: still one stack with its id")
	# The whole rest: the stack leaves the inventory; it merges away.
	assert_true(service.try_put(world, alice.player_id, box_id, food_id, InventoryService.WHOLE_STACK).ok)
	assert_eq(_carried(world, alice), [])
	assert_eq(_stored(world, box_id), [[FOOD, 4]])
	assert_true(world.registry.is_tombstoned(food_id), "the emptied stack's id is retired, never reused")
	# Taking a part: the stored stack shrinks, a new stack arrives.
	service.drain_events()
	var taken: ActionResult = service.try_take(world, alice.player_id, box_id, stored_id, 3)
	assert_true(taken.ok, taken.reason)
	assert_eq(_stored(world, box_id), [[FOOD, 1]])
	assert_eq(_carried(world, alice), [[FOOD, 3]])
	contents = _events_of_type(service.drain_events(), ContainerService.EVENT_CONTENTS)
	assert_eq(contents.size(), 1)
	assert_eq(int(((contents[0]["changed"] as Array)[0] as Dictionary)["quantity"]), 1)
	assert_eq((contents[0].get("removed", []) as Array).size(), 0)
	# Taking the whole rest: it merges into the carried stack and is gone.
	taken = service.try_take(world, alice.player_id, box_id, stored_id, InventoryService.WHOLE_STACK)
	assert_true(taken.ok, taken.reason)
	assert_eq(_stored(world, box_id), [])
	assert_eq(_carried(world, alice), [[FOOD, 4]])
	contents = _events_of_type(service.drain_events(), ContainerService.EVENT_CONTENTS)
	assert_eq(contents[0].get("removed", []), [stored_id])
	assert_eq(_units(world, FOOD, [alice], [box_id]), 4, "every unit exists exactly once")
	# A whole stack that does not merge keeps its id on the way in and out.
	var plain_id: String = _give(world, alice, PLAIN, 1)
	assert_true(service.try_put(world, alice.player_id, box_id, plain_id, 1).ok)
	assert_eq(_first_stored_id(world, box_id, PLAIN), plain_id)
	assert_true(service.try_take(world, alice.player_id, box_id, plain_id, 1).ok)
	assert_eq(world.inventory.get_item(plain_id).location_id, alice.inventory_id)


func test_a_full_container_and_a_full_inventory_refuse_everything_or_nothing() -> void:
	_gameplay.inventory_slot_capacity = 2
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var box_id: String = _container(world, BOX)
	_open(world, alice, box_id)
	_open(world, bob, box_id)
	# Fill the box: three slots.
	for index: int in range(BOX_SLOTS):
		var plain_id: String = _give(world, alice, PLAIN, 1)
		assert_true(service.try_put(world, alice.player_id, box_id, plain_id, 1).ok)
	var bulk_id: String = _give(world, alice, BULK, 4)
	var refused: ActionResult = service.try_put(world, alice.player_id, box_id, bulk_id, 4)
	assert_eq(refused.reason, ContainerService.REASON_CONTAINER_FULL)
	assert_eq(_carried(world, alice), [[BULK, 4]], "nothing was put in")
	assert_eq(_stored(world, box_id).size(), BOX_SLOTS)
	# Bob carries two stacks: his inventory is full.
	_give(world, bob, FOOD, 1)
	_give(world, bob, BULK, 10)
	refused = service.try_take(world, bob.player_id, box_id, _first_stored_id(world, box_id), 1)
	assert_eq(refused.reason, InventoryService.REASON_INVENTORY_FULL)
	assert_eq(_stored(world, box_id).size(), BOX_SLOTS, "nothing was taken")
	assert_eq(_carried(world, bob), [[FOOD, 1], [BULK, 10]])
	# Units that merge into a stack lying there need no slot; units that are
	# left over do, and without one nothing moves at all.
	assert_true(service.try_take(world, alice.player_id, box_id, _first_stored_id(world, box_id), 1).ok)
	assert_true(service.try_put(world, alice.player_id, box_id, bulk_id, 4).ok, "a free slot again")
	assert_eq(_stored(world, box_id).size(), BOX_SLOTS)
	assert_true(service.try_put(world, bob.player_id, box_id, world.inventory.items_in_inventory(bob.inventory_id)[1].item_instance_id, 6).ok, "6 more bulk fill the stack of 4 exactly: no slot is needed")
	assert_eq(_units(world, BULK, [alice, bob], [box_id]), 14)
	refused = service.try_put(world, bob.player_id, box_id, world.inventory.items_in_inventory(bob.inventory_id)[1].item_instance_id, 4)
	assert_eq(refused.reason, ContainerService.REASON_CONTAINER_FULL, "the stack is full and there is no free slot: nothing moves")
	assert_eq(_units(world, BULK, [alice, bob], [box_id]), 14)
	assert_true(_are_unique(_ids(world, [alice, bob], [box_id])))


func test_every_refusal_has_a_reason_and_changes_nothing() -> void:
	_settings.search_duration_sec = SEARCH_SEC
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var box_id: String = _container(world, BOX)
	var far_box_id: String = _container(world, BOX, FAR_AWAY)
	var food_id: String = _give(world, alice, FOOD, 3)
	var bob_food_id: String = _give(world, bob, FOOD, 2)
	# Nobody who is not in the world.
	assert_eq(service.try_open(world, "player_999999", box_id).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_eq(service.try_take(world, "player_999999", box_id, food_id, 1).reason, ServerWorld.REASON_NOT_ONLINE)
	# Unknown and distant containers.
	assert_eq(service.try_open(world, alice.player_id, MISSING_CONTAINER_ID).reason, ContainerService.REASON_UNKNOWN_CONTAINER)
	assert_eq(service.try_open(world, alice.player_id, far_box_id).reason, ContainerService.REASON_TOO_FAR, "range is measured from the server position")
	# Nothing works on a container the player has not opened.
	assert_eq(service.try_put(world, alice.player_id, box_id, food_id, 1).reason, ContainerService.REASON_NOT_OPEN)
	assert_eq(service.try_take(world, alice.player_id, box_id, food_id, 1).reason, ContainerService.REASON_NOT_OPEN)
	assert_eq(service.try_close(world, alice.player_id, box_id).reason, ContainerService.REASON_NOT_OPEN)
	_open(world, alice, box_id)
	assert_eq(service.try_open(world, alice.player_id, box_id).reason, ContainerService.REASON_ALREADY_OPEN)
	assert_eq(service.try_put(world, alice.player_id, far_box_id, food_id, 1).reason, ContainerService.REASON_NOT_OPEN, "another container than the open one")
	# Items that are not where the request says.
	assert_eq(service.try_put(world, alice.player_id, box_id, MISSING_ITEM_ID, 1).reason, ContainerService.REASON_ITEM_NOT_CARRIED)
	assert_eq(service.try_put(world, alice.player_id, box_id, bob_food_id, 1).reason, ContainerService.REASON_ITEM_NOT_CARRIED, "somebody else's stack")
	assert_eq(service.try_take(world, alice.player_id, box_id, MISSING_ITEM_ID, 1).reason, ContainerService.REASON_ITEM_NOT_INSIDE)
	assert_eq(service.try_take(world, alice.player_id, box_id, food_id, 1).reason, ContainerService.REASON_ITEM_NOT_INSIDE, "a carried stack is not inside")
	assert_eq(service.try_take(world, alice.player_id, box_id, bob_food_id, 1).reason, ContainerService.REASON_ITEM_NOT_INSIDE, "a container is no way into another inventory")
	# Quantities.
	for quantity: int in [-1, 4, 1000000]:
		assert_eq(service.try_put(world, alice.player_id, box_id, food_id, quantity).reason, InventoryService.REASON_BAD_QUANTITY, "put %d of 3" % quantity)
	assert_true(service.try_put(world, alice.player_id, box_id, food_id, 2).ok)
	var stored_id: String = _first_stored_id(world, box_id)
	for quantity: int in [-1, 3, 1000000]:
		assert_eq(service.try_take(world, alice.player_id, box_id, stored_id, quantity).reason, InventoryService.REASON_BAD_QUANTITY, "take %d of 2" % quantity)
	# Out of reach with the container open (before the next tick closes it).
	alice.position = OUT_OF_REACH
	assert_eq(service.try_take(world, alice.player_id, box_id, stored_id, 1).reason, ContainerService.REASON_TOO_FAR)
	assert_eq(service.try_put(world, alice.player_id, box_id, food_id, 1).reason, ContainerService.REASON_TOO_FAR)
	alice.position = Vector3.ZERO
	# A sleeper and a dead character.
	assert_true(_survival(world).start_rest(alice.player_id).ok)
	assert_eq(service.try_take(world, alice.player_id, box_id, stored_id, 1).reason, "player_resting")
	assert_eq(service.try_open(world, alice.player_id, box_id).reason, "player_resting")
	_survival(world).stop_rest(alice.player_id)
	assert_true(_survival(world).apply_damage(bob.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(service.try_open(world, bob.player_id, box_id).reason, "player_dead")
	assert_eq(service.try_put(world, bob.player_id, box_id, bob_food_id, 1).reason, "player_dead")
	# Nothing of all that moved a unit.
	assert_eq(_carried(world, alice), [[FOOD, 1]])
	assert_eq(_stored(world, box_id), [[FOOD, 2]])
	assert_eq(service.contents_of(far_box_id).size(), 0)


func test_of_two_takers_of_the_same_units_exactly_one_wins() -> void:
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var box_id: String = _container(world, BOX)
	_open(world, alice, box_id)
	_open(world, bob, box_id)
	# A single item: both ask for it in the same tick.
	var plain_id: String = _give(world, alice, PLAIN, 1)
	assert_true(service.try_put(world, alice.player_id, box_id, plain_id, 1).ok)
	var first: ActionResult = service.try_take(world, alice.player_id, box_id, plain_id, 1)
	var second: ActionResult = service.try_take(world, bob.player_id, box_id, plain_id, 1)
	assert_true(first.ok, first.reason)
	assert_false(second.ok)
	assert_eq(second.reason, ContainerService.REASON_ITEM_NOT_INSIDE, "the loser is told that it is gone")
	assert_eq(_units(world, PLAIN, [alice, bob], [box_id]), 1)
	# A stack of five: both ask for three units.
	var food_id: String = _give(world, alice, FOOD, 5)
	assert_true(service.try_put(world, alice.player_id, box_id, food_id, InventoryService.WHOLE_STACK).ok)
	first = service.try_take(world, bob.player_id, box_id, food_id, 3)
	second = service.try_take(world, alice.player_id, box_id, food_id, 3)
	assert_true(first.ok, first.reason)
	assert_eq(second.reason, InventoryService.REASON_BAD_QUANTITY, "only two are left")
	assert_eq(_carried(world, bob), [[FOOD, 3]])
	assert_eq(_stored(world, box_id), [[FOOD, 2]])
	assert_eq(_units(world, FOOD, [alice, bob], [box_id]), 5)
	assert_true(_are_unique(_ids(world, [alice, bob], [box_id])))


func test_alice_puts_items_in_and_bob_takes_them_later() -> void:
	# The user's flow (docs/00 ADR-021): items move between players through a
	# container, without the two ever meeting.
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var box_id: String = _container(world, BOX)
	var food_id: String = _give(world, alice, FOOD, 3)
	var bulk_id: String = _give(world, alice, BULK, 7)
	_open(world, alice, box_id)
	assert_true(service.try_put(world, alice.player_id, box_id, food_id, InventoryService.WHOLE_STACK).ok)
	assert_true(service.try_put(world, alice.player_id, box_id, bulk_id, 5).ok)
	assert_true(service.try_close(world, alice.player_id, box_id).ok)
	world.leave(alice.player_id)
	_run(world, 1.0)
	var bob: PlayerState = world.join("bob")
	_give(world, bob, FOOD, 1)
	_open(world, bob, box_id)
	assert_eq(_stored(world, box_id), [[FOOD, 3], [BULK, 5]])
	for entry: Dictionary in service.contents_of(box_id):
		var taken: ActionResult = service.try_take(world, bob.player_id, box_id, str(entry["item_instance_id"]), InventoryService.WHOLE_STACK)
		assert_true(taken.ok, taken.reason)
	assert_eq(_carried(world, bob), [[FOOD, 4], [BULK, 5]], "what arrives joins the stacks bob carries")
	assert_eq(_stored(world, box_id), [])
	assert_eq(_carried(world, alice), [[BULK, 2]], "alice keeps what she did not put in")
	assert_eq(_units(world, FOOD, [alice, bob], [box_id]), 4)
	assert_eq(_units(world, BULK, [alice, bob], [box_id]), 7)
	assert_true(_are_unique(_ids(world, [alice, bob], [box_id])))


func test_random_puts_and_takes_conserve_every_unit() -> void:
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var box_id: String = _container(world, BOX)
	var locker_id: String = _container(world, LOCKER, ALSO_NEAR)
	_open(world, alice, locker_id)
	service.try_close(world, alice.player_id, locker_id)
	_give(world, alice, FOOD, 5)
	_give(world, alice, BULK, 9)
	_give(world, bob, FOOD, 2)
	_give(world, bob, PLAIN, 1)
	var players: Array = [alice, bob]
	var boxes: Array = [box_id, locker_id]
	var food_total: int = _units(world, FOOD, players, boxes)
	var bulk_total: int = _units(world, BULK, players, boxes)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 20261116
	var accepted: int = 0
	for step_index: int in range(400):
		var player: PlayerState = players[rng.randi_range(0, 1)]
		var container_id: String = boxes[rng.randi_range(0, 1)]
		if service.session_container_id(player.player_id) != container_id:
			service.try_open(world, player.player_id, container_id)
		var result: ActionResult = null
		if rng.randf() < 0.5:
			var carried: Array[ItemInstance] = world.inventory.items_in_inventory(player.inventory_id)
			if carried.is_empty():
				continue
			var item: ItemInstance = carried[rng.randi_range(0, carried.size() - 1)]
			result = service.try_put(world, player.player_id, container_id, item.item_instance_id, rng.randi_range(0, item.quantity + 1))
		else:
			var inside: Array[Dictionary] = service.contents_of(container_id)
			if inside.is_empty():
				continue
			var entry: Dictionary = inside[rng.randi_range(0, inside.size() - 1)]
			result = service.try_take(world, player.player_id, container_id, str(entry["item_instance_id"]), rng.randi_range(0, int(entry["quantity"]) + 1))
		if result.ok:
			accepted += 1
		if _units(world, FOOD, players, boxes) != food_total or _units(world, BULK, players, boxes) != bulk_total or not _are_unique(_ids(world, players, boxes)):
			fail("step %d broke conservation" % step_index)
			return
	assert_true(accepted > 100, "many moves were accepted (%d)" % accepted)
	assert_eq(_units(world, FOOD, players, boxes), food_total)
	assert_eq(_units(world, BULK, players, boxes), bulk_total)
	for container_id: String in boxes:
		var slots: Dictionary = {}
		for entry: Dictionary in service.contents_of(container_id):
			assert_false(slots.has(entry["slot"]), "one stack per slot")
			slots[entry["slot"]] = true
			assert_true(int(entry["slot"]) >= 0 and int(entry["slot"]) < service.get_container(container_id).slot_count)


# ------------------------------------------------------------ sessions

func test_sessions_end_when_the_player_cannot_reach_or_use_the_container() -> void:
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var box_id: String = _container(world, BOX)
	var other_id: String = _container(world, BOX, ALSO_NEAR)
	_open(world, alice, box_id)
	_open(world, bob, box_id)
	assert_eq(service.session_count(), 2)
	assert_eq(Array(service.viewers_of(box_id)), [alice.player_id, bob.player_id], "two players may use one container at the same time")
	service.drain_events()
	# Opening another container closes the first one.
	_open(world, alice, other_id)
	assert_eq(service.session_container_id(alice.player_id), other_id)
	var sessions: Array[Dictionary] = _events_of_type(service.drain_events(), ContainerService.EVENT_SESSION)
	assert_eq(sessions.size(), 2)
	assert_eq(sessions[0].get("phase", ""), ContainerService.PHASE_CLOSED)
	assert_eq(sessions[0].get("reason", ""), ContainerService.REASON_SWITCHED)
	assert_eq(sessions[0].get("container_id", ""), box_id)
	assert_eq(sessions[1].get("phase", ""), ContainerService.PHASE_OPEN)
	# Walking away.
	alice.position = OUT_OF_REACH
	_run(world, TICK)
	assert_eq(service.session_phase(alice.player_id), "")
	assert_eq(str(_events_of_type(service.drain_events(), ContainerService.EVENT_SESSION)[0].get("reason", "")), ContainerService.REASON_TOO_FAR)
	# Closing by request.
	assert_true(service.try_close(world, bob.player_id, box_id).ok)
	assert_eq(str(_events_of_type(service.drain_events(), ContainerService.EVENT_SESSION)[0].get("reason", "")), ContainerService.REASON_CLOSED)
	# Lying down, then dying.
	_open(world, bob, box_id)
	assert_true(_survival(world).start_rest(bob.player_id).ok)
	_run(world, TICK)
	assert_eq(service.session_phase(bob.player_id), "")
	_survival(world).stop_rest(bob.player_id)
	_open(world, bob, box_id)
	service.drain_events()
	assert_true(_survival(world).apply_damage(bob.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	_run(world, TICK)
	assert_eq(service.session_phase(bob.player_id), "")
	assert_eq(str(_events_of_type(service.drain_events(), ContainerService.EVENT_SESSION)[0].get("reason", "")), "player_dead")
	# Leaving the server.
	alice.position = Vector3.ZERO
	_open(world, alice, box_id)
	world.leave(alice.player_id)
	assert_eq(service.session_count(), 0, "a player who left has nothing open")
	assert_eq(service.viewers_of(box_id).size(), 0)
