extends TestCase
## P3-3: containers and world cells (docs/09 §15.1, §15.3). A container and
## everything inside it belong to the cell of the container's position: they
## are in the cell index, are saved in that cell's document, leave memory
## with the cell and come back identical. Loot is rolled once, whatever is
## saved, released and loaded in between; no order of put / take / unload /
## reload / restore doubles or loses a unit or an id. Server rules only, a
## memory cell store, no nodes. Real files and a server restart:
## tests/integration/container_persistence_test.gd.

const WORLD: String = "container_cell_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const TOLERANCE: float = 0.000001
const FOOD: String = "t33c_food"
const FOOD_MAX: int = 5
const BULK: String = "t33c_bulk"
const BULK_MAX: int = 10
const PLAIN: String = "t33c_plain"
const BOX: String = "t33c_box"
const BOX_SLOTS: int = 4
const LOCKER: String = "t33c_locker"
const LOOT: String = "t33c_loot"
const KIND: String = ContainerService.ENTITY_KIND_CONTAINER
## 10 m cells: SPAWN and BESIDE are in cell (0, 0); from FAR that cell is
## released.
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
const BESIDE: Vector3 = Vector3(6.5, 0.0, 5.5)
const ALSO_BESIDE: Vector3 = Vector3(5.5, 0.0, 6.5)
const HOME_CELL: String = "cell_0_0"
const FAR: Vector3 = Vector3(45.5, 0.0, 45.5)
const BESIDE_FAR: Vector3 = Vector3(46.5, 0.0, 45.5)
const FAR_CELL: String = "cell_4_4"
## Longer than the unload delay.
const RELEASE_SEC: float = 2.0
const LOG_SKIPPED_CONTAINERS: String = "saved containers skipped"
const LOG_SKIPPED_ITEMS: String = "saved container items skipped"

var _cell_settings: WorldCellSettings = null
var _settings: ContainerSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	# 10 m cells on a 100 m map. Only the player's own cell is active, one
	# ring is kept in memory, a cell is released half a second after nobody
	# wants it.
	_cell_settings = WorldCellSettings.new()
	_cell_settings.cell_size_m = 10.0
	_cell_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_cell_settings.bounds_max_m = Vector2(50.0, 50.0)
	_cell_settings.active_radius_cells = 0
	_cell_settings.preload_radius_cells = 1
	_cell_settings.preload_lookahead_sec = 0.0
	_cell_settings.deactivate_delay_sec = 0.0
	_cell_settings.unload_delay_sec = 0.5
	_cell_settings.refresh_period_sec = 0.0
	_cell_settings.max_preload_loads_per_refresh = 1000
	_settings = ContainerSettings.new()
	_settings.search_duration_sec = 0.0


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _config(cell_settings: WorldCellSettings = null) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = cell_settings if cell_settings != null else _cell_settings
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
	table.rolls_min = 3
	table.rolls_max = 3
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
	locker.slot_count = 6
	locker.loot_table_id = LOOT
	config.container_definitions.add(locker)
	return config


func _world(store: WorldCellStore = null, config: CompositionConfig = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, config if config != null else _config())
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	return world


func _service(world: ServerWorld) -> ContainerService:
	return world.get_system(ContainerService.SYSTEM_ID) as ContainerService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _move(world: ServerWorld, player: PlayerState, position: Vector3, seconds: float = TICK) -> void:
	player.position = position
	_run(world, seconds)


func _container(world: ServerWorld, definition_id: String, position: Vector3) -> String:
	var created: ActionResult = _service(world).create_container(world, definition_id, position)
	if not created.ok:
		fail("test setup: container refused: " + created.reason)
		return ""
	return str(created.event.get("container_id", ""))


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


func _put(world: ServerWorld, player: PlayerState, container_id: String, item_id: String, quantity: int = InventoryService.WHOLE_STACK) -> void:
	var put: ActionResult = _service(world).try_put(world, player.player_id, container_id, item_id, quantity)
	if not put.ok:
		fail("test setup: put refused: " + put.reason)


func _take(world: ServerWorld, player: PlayerState, container_id: String, item_id: String, quantity: int = InventoryService.WHOLE_STACK) -> void:
	var taken: ActionResult = _service(world).try_take(world, player.player_id, container_id, item_id, quantity)
	if not taken.ok:
		fail("test setup: take refused: " + taken.reason)


## Save data of every container in memory with its content, by id.
func _saved(world: ServerWorld) -> Dictionary:
	var service: ContainerService = _service(world)
	var result: Dictionary = {}
	for container_id: String in service.container_ids():
		var data: Dictionary = service.get_container(container_id).to_dict()
		data["contents"] = service.contents_of(container_id)
		result[container_id] = data
	return result


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value)) as Dictionary


## Equal, except that numbers may differ by what a JSON round trip of a
## float loses (a save is text).
func _same(a: Variant, b: Variant) -> bool:
	if (typeof(a) == TYPE_FLOAT or typeof(a) == TYPE_INT) and (typeof(b) == TYPE_FLOAT or typeof(b) == TYPE_INT):
		return absf(float(a) - float(b)) <= TOLERANCE
	if typeof(a) != typeof(b):
		return false
	if typeof(a) == TYPE_ARRAY:
		if (a as Array).size() != (b as Array).size():
			return false
		for index: int in range((a as Array).size()):
			if not _same(a[index], b[index]):
				return false
		return true
	if typeof(a) == TYPE_DICTIONARY:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for key: Variant in (a as Dictionary):
			if not (b as Dictionary).has(key) or not _same(a[key], b[key]):
				return false
		return true
	return a == b


## Units of one definition everywhere in memory: carried by the given
## players, inside every container in memory and lying in the world.
func _units(world: ServerWorld, definition_id: String, players: Array) -> int:
	var total: int = 0
	for player: PlayerState in players:
		for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
			if item.definition_id == definition_id:
				total += item.quantity
	for container_id: String in _service(world).container_ids():
		for entry: Dictionary in _service(world).contents_of(container_id):
			if str(entry["definition_id"]) == definition_id:
				total += int(entry["quantity"])
	for item_id: String in world.inventory.world_item_ids():
		if world.inventory.get_item(item_id).definition_id == definition_id:
			total += world.inventory.get_item(item_id).quantity
	return total


## Every item id in memory (carried, inside containers, lying in the world).
func _item_ids(world: ServerWorld, players: Array) -> Array:
	var ids: Array = []
	for player: PlayerState in players:
		for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
			ids.append(item.item_instance_id)
	for container_id: String in _service(world).container_ids():
		for entry: Dictionary in _service(world).contents_of(container_id):
			ids.append(str(entry["item_instance_id"]))
	for item_id: String in world.inventory.world_item_ids():
		ids.append(item_id)
	return ids


func _are_unique(ids: Array) -> bool:
	var seen: Dictionary = {}
	for id: Variant in ids:
		if seen.has(id):
			return false
		seen[id] = true
	return true


func _logged(text: String) -> bool:
	for line: String in GameLogger.captured_lines():
		if line.contains(text):
			return true
	return false


func _container_document(containers: Array) -> Dictionary:
	return {"schema_version": ContainerService.CELL_SCHEMA_VERSION, ContainerService.KEY_CONTAINERS: containers}


## A valid saved container with one stack, for tests that then break a field.
func _entry(container_id: String, inventory_id: String, item_id: String, position: Vector3 = BESIDE) -> Dictionary:
	var container: ContainerInstance = ContainerInstance.new()
	container.container_id = container_id
	container.definition_id = BOX
	container.position = position
	container.inventory_id = inventory_id
	container.slot_count = BOX_SLOTS
	container.searched = true
	var item: ItemInstance = ItemInstance.new()
	item.item_instance_id = item_id
	item.definition_id = FOOD
	item.quantity = 2
	item.location_type = ItemInstance.LOCATION_INVENTORY
	item.location_id = inventory_id
	item.slot_id = "slot_0"
	var data: Dictionary = container.to_dict()
	data[ContainerService.KEY_ITEMS] = [item.to_dict()]
	return data


# ------------------------------------------------------------ cells

func test_a_released_cell_takes_its_containers_out_of_memory_and_brings_them_back_identical() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var locker_id: String = _container(world, LOCKER, BESIDE)
	var box_id: String = _container(world, BOX, ALSO_BESIDE)
	assert_eq(world.cell_index.cell_of(locker_id), HOME_CELL, "a container is indexed in the cell of its position")
	assert_eq(Array(service.container_ids_in_cell(world, HOME_CELL)), [locker_id, box_id])
	# A searched, partly looted locker and a box somebody put things into.
	_open(world, alice, locker_id)
	var looted: Array[Dictionary] = service.contents_of(locker_id)
	assert_true(looted.size() >= 1)
	_take(world, alice, locker_id, str(looted[0]["item_instance_id"]), 1)
	var plain_id: String = _give(world, alice, PLAIN, 1)
	var bulk_id: String = _give(world, alice, BULK, 7)
	_open(world, alice, box_id)
	_put(world, alice, box_id, plain_id)
	_put(world, alice, box_id, bulk_id, 4)
	var before: Dictionary = _saved(world)
	var inventory_ids: Array = [service.get_container(locker_id).inventory_id, service.get_container(box_id).inventory_id]
	var inside_ids: Array = []
	for container_id: String in [locker_id, box_id]:
		for entry: Dictionary in service.contents_of(container_id):
			inside_ids.append(str(entry["item_instance_id"]))
	var players: Array = [alice]
	var food_total: int = _units(world, FOOD, players)
	var bulk_total: int = _units(world, BULK, players)
	var items_in_memory: int = world.inventory.item_count()

	_move(world, alice, FAR, RELEASE_SEC)
	assert_false(service.has_container(locker_id), "the cell was released: its containers left memory")
	assert_false(service.has_container(box_id))
	assert_eq(service.session_count(), 0, "nobody has a container open that is not in memory")
	assert_false(world.cell_index.has(locker_id))
	assert_false(world.registry.has(locker_id), "the id left the registry")
	assert_false(world.registry.is_tombstoned(locker_id), "but it is not retired: the container still exists")
	for inventory_id: String in inventory_ids:
		assert_false(world.inventory.has_inventory(inventory_id), "the content left memory with it")
	for item_id: String in inside_ids:
		assert_null(world.inventory.get_item(item_id))
		assert_false(world.registry.is_tombstoned(item_id))
	assert_eq(world.inventory.item_count(), items_in_memory - inside_ids.size(), "carried items never leave memory")
	var document: Dictionary = store.document_of(HOME_CELL)
	var saved: Array = ((document["systems"] as Dictionary)[ContainerService.SYSTEM_ID] as Dictionary)[ContainerService.KEY_CONTAINERS]
	assert_eq(saved.size(), 2, "both are in the cell's document")
	assert_true(SaveService.is_json_safe(document))

	_move(world, alice, SPAWN, 0.5)
	assert_true(_same(_saved(world), before), "the same containers with the same content, ids and slots")
	assert_eq(world.registry.kind_of(locker_id), KIND)
	assert_true(world.inventory.is_detached_inventory(str(inventory_ids[0])))
	assert_eq(service.loot_roll_count, 1, "loading a cell rolls nothing")
	assert_eq(_units(world, FOOD, players), food_total)
	assert_eq(_units(world, BULK, players), bulk_total)
	assert_true(_are_unique(_item_ids(world, players)))
	# And it works as before: bob takes what alice put in.
	var bob: PlayerState = world.join("bob")
	_open(world, bob, box_id)
	_take(world, bob, box_id, plain_id)
	assert_eq(world.inventory.get_item(plain_id).location_id, bob.inventory_id)


func test_reloading_a_cell_never_rolls_loot_again() -> void:
	# The reference: the same world, the locker searched at once.
	var reference: ServerWorld = _world(WorldCellStore.new())
	var reference_alice: PlayerState = reference.join("alice")
	var reference_id: String = _container(reference, LOCKER, BESIDE)
	_open(reference, reference_alice, reference_id)
	var expected: Array[Dictionary] = _service(reference).contents_of(reference_id)

	var world: ServerWorld = _world(WorldCellStore.new())
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var locker_id: String = _container(world, LOCKER, BESIDE)
	assert_eq(locker_id, reference_id, "the same container in both worlds")
	# Unsearched, released, loaded, released, loaded: still unsearched.
	for round_index: int in range(2):
		_move(world, alice, FAR, RELEASE_SEC)
		assert_false(service.has_container(locker_id))
		_move(world, alice, SPAWN, 0.5)
		assert_false(service.get_container(locker_id).searched, "a cell that comes back does not search its containers")
		assert_eq(service.contents_of(locker_id).size(), 0)
	assert_eq(service.loot_roll_count, 0)
	_open(world, alice, locker_id)
	assert_true(_same(service.contents_of(locker_id), expected), "what it holds does not depend on when it is searched")
	# Emptied, released, loaded: it stays empty and searched.
	for entry: Dictionary in service.contents_of(locker_id):
		_take(world, alice, locker_id, str(entry["item_instance_id"]))
	for round_index: int in range(2):
		_move(world, alice, FAR, RELEASE_SEC)
		_move(world, alice, SPAWN, 0.5)
		assert_true(service.get_container(locker_id).searched)
		assert_eq(service.contents_of(locker_id).size(), 0, "an emptied container is not filled again")
		_open(world, alice, locker_id)
		assert_eq(service.contents_of(locker_id).size(), 0)
	assert_eq(service.loot_roll_count, 1)


func test_a_container_keeps_the_loot_seed_it_was_created_with() -> void:
	# The reference: the locker searched at once with the seed of its world.
	var seed_at_creation: int = _settings.loot_seed
	var reference: ServerWorld = _world(WorldCellStore.new())
	var reference_alice: PlayerState = reference.join("alice")
	var reference_id: String = _container(reference, LOCKER, BESIDE)
	_open(reference, reference_alice, reference_id)
	var expected: Array[Dictionary] = _service(reference).contents_of(reference_id)
	assert_true(expected.size() >= 1, "the reference found something")
	# The same locker, unsearched, saved; the setting changes before the restart.
	var world: ServerWorld = _world(WorldCellStore.new())
	world.join("alice")
	var locker_id: String = _container(world, LOCKER, BESIDE)
	assert_eq(locker_id, reference_id, "the same container in both worlds")
	assert_eq(_service(world).get_container(locker_id).loot_seed, seed_at_creation, "the container records the seed")
	_settings.loot_seed = seed_at_creation + 1
	var restored: ServerWorld = _restored_copy(world)
	var alice: PlayerState = restored.join("alice")
	_move(restored, alice, SPAWN, 0.5)
	var service: ContainerService = _service(restored)
	if not service.has_container(locker_id):
		fail("the locker did not come back")
		return
	assert_eq(service.get_container(locker_id).loot_seed, seed_at_creation, "the saved seed came back")
	_open(restored, alice, locker_id)
	assert_true(_same(service.contents_of(locker_id), expected), "a later change of the setting does not change what an existing container holds")
	# The resolved world seed is stable: changing the settings object after
	# world creation cannot split one world across two loot layouts.
	var later_id: String = _container(restored, LOCKER, ALSO_BESIDE)
	assert_eq(service.get_container(later_id).loot_seed, seed_at_creation)
	# Tests/tools can still inject a fixed seed for another new world.
	var another: ServerWorld = _world(WorldCellStore.new())
	another.join("alice")
	var another_id: String = _container(another, LOCKER, BESIDE)
	assert_eq(_service(another).get_container(another_id).loot_seed, seed_at_creation + 1)
	# A saved container without a seed the save can carry exactly is refused.
	var entry: Dictionary = _entry("container_000900", "inventory_000900", "item_000900")
	assert_not_null(ContainerInstance.from_dict(entry), "the valid entry")
	for bad: Variant in [null, -1, ContainerInstance.MAX_LOOT_SEED + 1, 1.5, "7"]:
		var broken: Dictionary = entry.duplicate(true)
		if typeof(bad) == TYPE_NIL:
			broken.erase(ContainerInstance.KEY_LOOT_SEED)
		else:
			broken[ContainerInstance.KEY_LOOT_SEED] = bad
		assert_null(ContainerInstance.from_dict(broken), "loot_seed %s is refused" % str(bad))
	var settings: ContainerSettings = ContainerSettings.new()
	settings.loot_seed = -1
	assert_eq(settings.validate().size(), 1, "; ".join(settings.validate()))
	settings.loot_seed = ContainerInstance.MAX_LOOT_SEED
	assert_eq(settings.validate().size(), 0)


func test_world_documents_round_trip_containers_in_memory_and_in_released_cells() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var home_box: String = _container(world, BOX, BESIDE)
	var home_locker: String = _container(world, LOCKER, ALSO_BESIDE)
	var food_id: String = _give(world, alice, FOOD, 5)
	_open(world, alice, home_box)
	_put(world, alice, home_box, food_id, 2)
	var home_before: Dictionary = _saved(world)
	_move(world, alice, FAR, RELEASE_SEC)
	var far_box: String = _container(world, BOX, BESIDE_FAR)
	_open(world, alice, far_box)
	_put(world, alice, far_box, food_id, 1)
	var players: Array = [alice]
	var documents: Dictionary = world.to_documents()
	# With a memory store the world document holds what is in memory and the
	# cell documents hold the released cells.
	var in_world: Array = ((documents["world_state"]["systems"] as Dictionary)[ContainerService.SYSTEM_ID] as Dictionary)[ContainerService.KEY_CONTAINERS]
	assert_eq(in_world.size(), 1)
	assert_eq(in_world[0]["container_id"], far_box)
	assert_true((documents["cells"] as Dictionary).has(HOME_CELL))
	assert_true(SaveService.is_json_safe(documents["world_state"]))
	# The inventory part of the world document knows nothing of containers.
	var inventory_part: Dictionary = documents["world_state"]["inventory"]
	assert_eq((inventory_part["inventories"] as Dictionary).keys(), [alice.inventory_id], "only the player's inventory")
	for item: Dictionary in inventory_part["items"]:
		assert_eq(item["location_id"], alice.inventory_id, "items inside a container are saved with the container")

	var restored: ServerWorld = _world(WorldCellStore.new())
	var errors: PackedStringArray = restored.restore_documents(_json(documents["world_state"]), _json(documents["players"]), _json(documents["cells"]))
	assert_eq(errors.size(), 0, "; ".join(errors))
	var restored_service: ContainerService = _service(restored)
	assert_eq(restored_service.container_ids(), PackedStringArray([far_box]), "the container that was in memory")
	assert_true(_same(_saved(restored)[far_box], _saved(world)[far_box]))
	assert_eq(restored.cell_index.cell_of(far_box), FAR_CELL)
	# The released cell comes back when somebody goes there.
	var player: PlayerState = restored.join("alice")
	_move(restored, player, SPAWN, RELEASE_SEC)
	assert_true(restored_service.has_container(home_box) and restored_service.has_container(home_locker))
	for container_id: String in [home_box, home_locker]:
		assert_true(_same(_saved(restored)[container_id], home_before[container_id]), container_id)
	assert_false(restored_service.get_container(home_locker).searched, "an unsearched container is still unsearched after a restore")
	assert_eq(restored.ids.get_next_sequence(), world.ids.get_next_sequence(), "no id of a saved container or item can be handed out again")
	# Every unit once: 2 in the home box, 1 in the far box, 2 carried. Only
	# one of the two cells is in memory at a time.
	assert_false(restored_service.has_container(far_box), "the far cell was released meanwhile")
	assert_eq(_units(restored, FOOD, [player]), 4, "2 carried + 2 in the home box")
	_move(restored, player, FAR, RELEASE_SEC)
	assert_eq(_units(restored, FOOD, [player]), 3, "2 carried + 1 in the far box")
	assert_eq(_units(world, FOOD, players), 3)


func test_a_world_without_a_cell_store_saves_containers_in_the_world_document() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var locker_id: String = _container(world, LOCKER, BESIDE)
	_open(world, alice, locker_id)
	var documents: Dictionary = world.to_documents()
	assert_eq((documents["cells"] as Dictionary).size(), 0)
	var restored: ServerWorld = _world()
	assert_eq(restored.restore_documents(_json(documents["world_state"]), _json(documents["players"])).size(), 0)
	assert_true(_same(_saved(restored), _saved(world)), "the same containers")
	assert_eq(restored.registry.kind_of(locker_id), KIND)
	assert_true(_service(restored).get_container(locker_id).searched)
	var restored_alice: PlayerState = restored.join("alice")
	_open(restored, restored_alice, locker_id)
	assert_eq(_service(restored).loot_roll_count, 0, "a restored world rolls nothing for a searched container")
	# A save from before the world seed existed has no container document at all.
	var old_world: ServerWorld = _world()
	old_world.join("alice")
	var old_documents: Dictionary = old_world.to_documents()
	(old_documents["world_state"]["systems"] as Dictionary).erase(ContainerService.SYSTEM_ID)
	var from_old: ServerWorld = _world()
	assert_eq(from_old.restore_documents(_json(old_documents["world_state"]), _json(old_documents["players"])).size(), 0, "an older save loads")
	assert_eq(_service(from_old).container_count(), 0)
	# A world document whose container is known already is refused as a whole.
	var twice: PackedStringArray = _service(restored).restore_world_document(_json(documents["world_state"]["systems"][ContainerService.SYSTEM_ID]))
	assert_true(twice.size() > 0, "a world document is strict about ids it already has")
	assert_eq(_service(restored).container_count(), 1)


func test_shipped_new_world_draws_and_persists_one_loot_seed() -> void:
	_settings = ContainerSettings.load_or_default().duplicate() as ContainerSettings
	assert_eq(_settings.loot_seed, 0, "0 selects world-creation randomization")
	var world: ServerWorld = _world()
	var documents: Dictionary = world.to_documents()
	var saved: Dictionary = documents["world_state"]["systems"][ContainerService.SYSTEM_ID]
	var seed: int = int(saved[ContainerService.KEY_WORLD_LOOT_SEED])
	assert_true(seed > 0 and seed <= ContainerInstance.MAX_LOOT_SEED)
	assert_eq((saved[ContainerService.KEY_CONTAINERS] as Array).size(), 0)
	var restored: ServerWorld = _world()
	assert_eq(restored.restore_documents(_json(documents["world_state"]), _json(documents["players"])).size(), 0)
	assert_eq(_service(restored).world_loot_seed(), seed, "restart keeps the world's seed")


# ------------------------------------------------------------ memory first

func test_an_older_cell_document_never_doubles_or_resurrects_an_item() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var service: ContainerService = _service(world)
	var alice: PlayerState = world.join("alice")
	var box_id: String = _container(world, BOX, BESIDE)
	var food_id: String = _give(world, alice, FOOD, 5)
	var plain_id: String = _give(world, alice, PLAIN, 1)
	var bulk_id: String = _give(world, alice, BULK, 4)
	_open(world, alice, box_id)
	_put(world, alice, box_id, food_id)
	_put(world, alice, box_id, plain_id)
	_put(world, alice, box_id, bulk_id)
	var carried_bulk_id: String = _give(world, alice, BULK, 3)
	var players: Array = [alice]
	var totals: Dictionary = {FOOD: _units(world, FOOD, players), BULK: _units(world, BULK, players), PLAIN: _units(world, PLAIN, players)}
	# The cell as it was BEFORE anything was taken out (an old backup).
	var stale: Dictionary = _json(world.cell_document(HOME_CELL))
	# The whole plain item goes out (it keeps its id), the bulk stack goes
	# out and merges away (its id is retired), a part of the food goes out.
	_take(world, alice, box_id, plain_id)
	_take(world, alice, box_id, bulk_id)
	_take(world, alice, box_id, food_id, 2)
	assert_true(world.registry.is_tombstoned(bulk_id))
	assert_eq(world.inventory.get_item(carried_bulk_id).quantity, 7)
	# 1. The stale document arrives while the container is in memory: the
	#    container in memory wins, nothing changes.
	var before: Dictionary = _saved(world)
	assert_eq(world.restore_cell_document(HOME_CELL, stale.duplicate(true)).size(), 0)
	assert_true(_same(_saved(world), before), "a container in memory is never replaced by its saved copy")
	assert_true(_logged(LOG_SKIPPED_CONTAINERS))
	# 2. The cell is released and the stale document takes the place of the
	#    one that was saved (a cell file restored from a backup).
	_move(world, alice, FAR, RELEASE_SEC)
	assert_false(service.has_container(box_id))
	var documents: Dictionary = {HOME_CELL: stale}
	store.replace_documents(documents)
	_move(world, alice, SPAWN, 0.5)
	assert_true(service.has_container(box_id))
	assert_true(_logged(LOG_SKIPPED_ITEMS))
	var inside: Dictionary = {}
	for entry: Dictionary in service.contents_of(box_id):
		inside[str(entry["item_instance_id"])] = int(entry["quantity"])
	assert_false(inside.has(plain_id), "the item alice carries did not come back into the box")
	assert_false(inside.has(bulk_id), "a retired id is never restored")
	assert_eq(world.inventory.get_item(plain_id).location_id, alice.inventory_id)
	assert_eq(_units(world, PLAIN, players), int(totals[PLAIN]))
	assert_eq(_units(world, BULK, players), int(totals[BULK]))
	assert_true(_are_unique(_item_ids(world, players)))
	# Known limit (docs/15 §15.3): the units of a stack that was only PARTLY
	# taken out come back with an older cell file (the stack's id is neither
	# in memory nor retired). An older cell file can only appear when a save
	# is restored from a backup by hand.
	assert_eq(inside.get(food_id, 0), 5, "the part that was taken out is in the old file again")


func test_a_cell_document_is_validated_before_anything_changes() -> void:
	var world: ServerWorld = _world()
	var service: ContainerService = _service(world)
	world.join("alice")
	var good: Dictionary = _entry("container_000101", "inventory_000102", "item_000103")
	var cases: Dictionary[String, Dictionary] = {}
	cases["wrong version"] = {"schema_version": 99, ContainerService.KEY_CONTAINERS: [good]}
	cases["no list"] = {"schema_version": ContainerService.CELL_SCHEMA_VERSION, ContainerService.KEY_CONTAINERS: "x"}
	cases["entry is no object"] = _container_document([good, 7])
	var unknown_definition: Dictionary = _entry("container_000111", "inventory_000112", "item_000113")
	unknown_definition["definition_id"] = "removed_definition"
	cases["unknown definition"] = _container_document([good, unknown_definition])
	var unknown_table: Dictionary = _entry("container_000121", "inventory_000122", "item_000123")
	unknown_table["searched"] = false
	unknown_table["loot_table_id"] = "removed_table"
	cases["unsearched with an unknown loot table"] = _container_document([good, unknown_table])
	cases["the same container twice"] = _container_document([good, good.duplicate(true)])
	var shared_inventory: Dictionary = _entry("container_000131", "inventory_000102", "item_000133")
	cases["two containers with one inventory"] = _container_document([good, shared_inventory])
	var no_items: Dictionary = _entry("container_000141", "inventory_000142", "item_000143")
	no_items.erase(ContainerService.KEY_ITEMS)
	cases["no item list"] = _container_document([good, no_items])
	var foreign_item: Dictionary = _entry("container_000151", "inventory_000152", "item_000153")
	((foreign_item[ContainerService.KEY_ITEMS] as Array)[0] as Dictionary)["location_id"] = "inventory_999999"
	cases["an item of another inventory"] = _container_document([good, foreign_item])
	var bad_slot: Dictionary = _entry("container_000161", "inventory_000162", "item_000163")
	((bad_slot[ContainerService.KEY_ITEMS] as Array)[0] as Dictionary)["slot_id"] = "slot_%d" % BOX_SLOTS
	cases["a slot the container does not have"] = _container_document([good, bad_slot])
	var unknown_item: Dictionary = _entry("container_000171", "inventory_000172", "item_000173")
	((unknown_item[ContainerService.KEY_ITEMS] as Array)[0] as Dictionary)["definition_id"] = "removed_item"
	cases["an item without a definition"] = _container_document([good, unknown_item])
	var no_position: Dictionary = _entry("container_000181", "inventory_000182", "item_000183")
	no_position["position"] = [1.0, 2.0]
	cases["a broken position"] = _container_document([good, no_position])
	var items_before: int = world.inventory.item_count()
	for label: String in cases:
		var errors: PackedStringArray = service.restore_cell_document(world, HOME_CELL, _json(cases[label]))
		assert_true(errors.size() > 0, label + ": refused")
		assert_eq(service.container_count(), 0, label + ": nothing was restored, not even the valid container next to it")
		assert_eq(world.inventory.item_count(), items_before, label + ": no item either")
		assert_false(world.inventory.has_inventory("inventory_000102"), label)
		assert_false(world.registry.has("container_000101"), label)
	# The valid document restores.
	assert_eq(service.restore_cell_document(world, HOME_CELL, _json(_container_document([good]))).size(), 0)
	assert_true(service.has_container("container_000101"))
	assert_eq(service.contents_of("container_000101").size(), 1)
	assert_true(world.ids.get_next_sequence() > 103, "restored ids are never handed out again")


func test_documents_cut_with_another_cell_grid_restore_into_the_cells_of_this_grid() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var alice: PlayerState = world.join("alice")
	var box_id: String = _container(world, BOX, BESIDE)
	var food_id: String = _give(world, alice, FOOD, 3)
	_open(world, alice, box_id)
	_put(world, alice, box_id, food_id)
	_move(world, alice, FAR, RELEASE_SEC)
	var far_box: String = _container(world, BOX, BESIDE_FAR)
	var documents: Dictionary = world.to_documents()
	# The same save read by a server whose cells are 25 m.
	var wide: WorldCellSettings = _cell_settings.duplicate() as WorldCellSettings
	wide.cell_size_m = 25.0
	var restored: ServerWorld = _world(WorldCellStore.new(), _config(wide))
	var errors: PackedStringArray = restored.restore_documents(_json(documents["world_state"]), _json(documents["players"]), _json(documents["cells"]))
	assert_eq(errors.size(), 0, "; ".join(errors))
	var service: ContainerService = _service(restored)
	assert_true(service.has_container(box_id) and service.has_container(far_box), "every container was brought into memory for the new grid")
	assert_eq(service.get_container(box_id).cell_id, restored.cell_id_at(BESIDE), "its cell is the cell of its position in this grid")
	assert_eq(restored.cell_index.cell_of(far_box), restored.cell_id_at(BESIDE_FAR))
	assert_eq(service.contents_of(box_id).size(), 1)
	assert_eq(str(service.contents_of(box_id)[0]["item_instance_id"]), food_id)


func test_random_moves_through_releases_and_restores_conserve_everything() -> void:
	# put / take / walk away (release) / come back (reload) / save and restore
	# into a new world, in a random order: every unit and every id exists
	# exactly once at every step.
	var world: ServerWorld = _world(WorldCellStore.new())
	var alice: PlayerState = world.join("alice")
	var home_ids: Array = [_container(world, BOX, BESIDE), _container(world, LOCKER, ALSO_BESIDE)]
	_open(world, alice, str(home_ids[1]))
	_give(world, alice, FOOD, 5)
	_give(world, alice, BULK, 9)
	_give(world, alice, PLAIN, 1)
	var food_total: int = _units(world, FOOD, [alice])
	var bulk_total: int = _units(world, BULK, [alice])
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 331116
	var restores: int = 0
	var releases: int = 0
	for step_index: int in range(120):
		var service: ContainerService = _service(world)
		var action: int = rng.randi_range(0, 9)
		if action == 0:
			# Walk away until the cell is released, and come back.
			_move(world, alice, FAR, RELEASE_SEC)
			if service.container_count() != 0:
				fail("step %d: the home cell was not released" % step_index)
				return
			releases += 1
			if rng.randf() < 0.5:
				world = _restored_copy(world)
				alice = world.join("alice")
				restores += 1
			_move(world, alice, SPAWN, 0.5)
		elif action == 1:
			# Save and restore with everything in memory.
			world = _restored_copy(world)
			alice = world.join("alice")
			_move(world, alice, SPAWN, 0.5)
			restores += 1
		else:
			var container_id: String = str(home_ids[rng.randi_range(0, 1)])
			if service.session_container_id(alice.player_id) != container_id:
				service.try_open(world, alice.player_id, container_id)
			if action < 6:
				var carried: Array[ItemInstance] = world.inventory.items_in_inventory(alice.inventory_id)
				if not carried.is_empty():
					var item: ItemInstance = carried[rng.randi_range(0, carried.size() - 1)]
					service.try_put(world, alice.player_id, container_id, item.item_instance_id, rng.randi_range(0, item.quantity))
			else:
				var inside: Array[Dictionary] = service.contents_of(container_id)
				if not inside.is_empty():
					var entry: Dictionary = inside[rng.randi_range(0, inside.size() - 1)]
					service.try_take(world, alice.player_id, container_id, str(entry["item_instance_id"]), rng.randi_range(0, int(entry["quantity"])))
		if _service(world).container_count() != 2 or _units(world, FOOD, [alice]) != food_total or _units(world, BULK, [alice]) != bulk_total or _units(world, PLAIN, [alice]) != 1 or not _are_unique(_item_ids(world, [alice])):
			fail("step %d (action %d) broke conservation: food %d/%d bulk %d/%d" % [step_index, action, _units(world, FOOD, [alice]), food_total, _units(world, BULK, [alice]), bulk_total])
			return
	assert_true(restores >= 5 and releases >= 5, "the run restored %d times and released %d times" % [restores, releases])
	assert_eq(_service(world).loot_roll_count, 0, "the last world never rolled: the locker came searched out of every save")
	assert_eq(_units(world, FOOD, [alice]), food_total)
	assert_eq(_units(world, BULK, [alice]), bulk_total)


## A new world restored from the save documents of `world` (a server
## restart with a memory store).
func _restored_copy(world: ServerWorld) -> ServerWorld:
	var documents: Dictionary = world.to_documents()
	var copy: ServerWorld = _world(WorldCellStore.new())
	var errors: PackedStringArray = copy.restore_documents(_json(documents["world_state"]), _json(documents["players"]), _json(documents["cells"]))
	if not errors.is_empty():
		fail("restore failed: " + "; ".join(errors))
	return copy
