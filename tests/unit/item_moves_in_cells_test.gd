extends TestCase
## P2-T15 / P2-T16 on top of world cells (P3-1, docs/09 §15.1): units put
## down, pickups that merge into carried stacks and a completed trade keep
## every unit and every id exactly once while cells are saved, released and
## loaded again.
##   - A part of a stack that is put down lies in the cell of its position
##     and is in the cell index, like a whole stack.
##   - A picked-up item leaves the cell index whether it merges or not; one
##     that merged completely is retired, so no saved copy of its cell can
##     bring it back.
##   - save -> unload -> reload and world documents -> a new world keep
##     the quantities and the ids.
## Server rules only, a memory cell store, no nodes; time passes through
## ServerWorld.step_systems(). Real files and a server restart:
## tests/integration/item_moves_cell_persistence_test.gd.

const WORLD: String = "item_moves_in_cells_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const FOOD: String = "t17_food"
const FOOD_MAX: int = 5
const BULK: String = "t17_bulk"
const BULK_MAX: int = 10
const SINGLE: String = "dev_test_item"
## 10 m cells: HOME is in HOME_CELL, DEPOT in DEPOT_CELL; from AWAY (and from
## DEPOT) the home cell is neither active nor kept in memory.
const HOME: Vector3 = Vector3(-15.0, 0.0, 5.0)
const HOME_CELL: String = "cell_-2_0"
const BESIDE: Vector3 = Vector3(1.0, 0.0, 0.0)
const AWAY: Vector3 = Vector3(35.0, 0.0, 5.0)
const DEPOT: Vector3 = Vector3(35.0, 0.0, -35.0)
const DEPOT_CELL: String = "cell_3_-4"
## Longer than deactivate_delay_sec + unload_delay_sec.
const RELEASE_SEC: float = 7.0
const LOG_SKIPPED: String = "saved world items skipped"

var _settings: WorldCellSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	# A 10 x 10 map of 10 m cells; the player's cell and its neighbours are
	# active, one more ring is in memory, a look every tick.
	_settings = WorldCellSettings.new()
	_settings.cell_size_m = 10.0
	_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_settings.bounds_max_m = Vector2(50.0, 50.0)
	_settings.active_radius_cells = 1
	_settings.preload_radius_cells = 2
	_settings.preload_lookahead_sec = 0.0
	_settings.deactivate_delay_sec = 2.0
	_settings.unload_delay_sec = 4.0
	_settings.refresh_period_sec = 0.0
	_settings.max_preload_loads_per_refresh = 1000
	_settings.retry_delay_sec = 3.0


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.respawn_delay_sec = NEVER
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.trade = TradeSettings.new()
	config.world_cells = _settings
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var food: ItemDefinition = ItemDefinition.new()
	food.definition_id = FOOD
	food.max_stack = FOOD_MAX
	catalog.add(food)
	var bulk: ItemDefinition = ItemDefinition.new()
	bulk.definition_id = BULK
	bulk.max_stack = BULK_MAX
	catalog.add(bulk)
	config.catalog = catalog
	return config


func _world(store: WorldCellStore) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	_cells(world).set_store(store)
	return world


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _trade(world: ServerWorld) -> TradeService:
	return world.get_system(TradeService.SYSTEM_ID) as TradeService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


## Puts a player somewhere (as the server movement would) and steps once.
func _move(world: ServerWorld, player_id: String, position: Vector3) -> void:
	world.get_player(player_id).position = position
	world.step_systems(TICK)


## A new world item where it says, in the cell of that position.
func _lay(world: ServerWorld, definition_id: String, quantity: int, position: Vector3) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, world.cell_id_at(position), position)
	if item_id.is_empty():
		fail("test setup: spawn failed")
	return item_id


## Spawns an item where `player` stands and lets it pick the item up.
func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int) -> String:
	var item_id: String = _lay(world, definition_id, quantity, player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


## [definition, quantity] of what a player carries, in slot order.
func _rows(world: ServerWorld, player_id: String) -> Array:
	var rows: Array = []
	for item: ItemInstance in world.inventory.items_in_inventory(world.get_player(player_id).inventory_id):
		rows.append([item.definition_id, item.quantity])
	return rows


## Units per definition of every item that is in memory.
func _totals(world: ServerWorld) -> Dictionary:
	return _totals_of(world.inventory.to_snapshot()[InventoryService.SNAPSHOT_ITEMS] as Array)


func _totals_of(items: Array) -> Dictionary:
	var totals: Dictionary = {}
	for entry: Variant in items:
		var definition_id: String = str((entry as Dictionary)["definition_id"])
		totals[definition_id] = int(totals.get(definition_id, 0)) + int((entry as Dictionary)["quantity"])
	return totals


## Every saved item of world documents (ServerWorld.to_documents after a
## JSON round trip): the world document's and every cell document's.
func _saved_items(documents: Dictionary) -> Array:
	var items: Array = ((documents["world_state"] as Dictionary)["inventory"] as Dictionary)[InventoryService.SNAPSHOT_ITEMS] as Array
	items = items.duplicate()
	var cells: Dictionary = documents["cells"] as Dictionary
	for cell_id: Variant in cells:
		var world_items: Dictionary = (cells[cell_id] as Dictionary)[WorldCellDocument.KEY_WORLD_ITEMS] as Dictionary
		items.append_array(world_items.get(InventoryService.SNAPSHOT_ITEMS, []) as Array)
	return items


## Every item is saved exactly once and no retired id is saved.
func _assert_saved_once(documents: Dictionary, label: String) -> void:
	var retired: Array = (documents["world_state"] as Dictionary)["tombstones"] as Array
	var seen: Dictionary = {}
	for entry: Variant in _saved_items(documents):
		var item_id: String = str((entry as Dictionary)["item_instance_id"])
		assert_false(seen.has(item_id), "%s: %s is saved once" % [label, item_id])
		assert_false(retired.has(item_id), "%s: %s is not a retired id" % [label, item_id])
		seen[item_id] = true


## What must hold for the items in memory at any time: a lying item is
## indexed under the cell of its position, a carried item is in no cell, a
## retired id names nothing.
func _assert_consistent(world: ServerWorld, label: String) -> void:
	var lying: PackedStringArray = world.inventory.world_item_ids()
	for item_id: String in lying:
		var item: ItemInstance = world.inventory.get_item(item_id)
		var cell_id: String = world.cell_id_at(world.inventory.world_position_of(item_id))
		assert_eq(item.location_id, cell_id, "%s: %s names the cell of its position" % [label, item_id])
		assert_eq(world.cell_index.cell_of(item_id), cell_id, "%s: %s is indexed there" % [label, item_id])
		assert_eq(world.cell_index.kind_of(item_id), InventoryService.ENTITY_KIND_ITEM, label)
		assert_true(world.registry.has(item_id), "%s: %s is registered" % [label, item_id])
	var indexed: int = 0
	for cell_id: String in world.cell_index.occupied_cell_ids():
		indexed += world.cell_index.count_in_cell(cell_id, InventoryService.ENTITY_KIND_ITEM)
	assert_eq(indexed, lying.size(), label + ": the index holds the lying items and nothing else")
	for entry: Variant in (world.inventory.to_snapshot()[InventoryService.SNAPSHOT_ITEMS] as Array):
		var item_id: String = str((entry as Dictionary)["item_instance_id"])
		if not lying.has(item_id):
			assert_false(world.cell_index.has(item_id), "%s: the carried %s is in no cell" % [label, item_id])
		assert_false(world.registry.is_tombstoned(item_id), "%s: %s is not retired" % [label, item_id])
	for retired: String in world.registry.tombstones():
		assert_null(world.inventory.get_item(retired), "%s: the retired %s names no item" % [label, retired])
		assert_false(world.cell_index.has(retired), "%s: the retired %s is in no cell" % [label, retired])


## Ids of the world items saved in a cell document, sorted.
func _ids_in_document(document: Dictionary) -> PackedStringArray:
	var ids: PackedStringArray = []
	var world_items: Dictionary = document.get(WorldCellDocument.KEY_WORLD_ITEMS, {}) as Dictionary
	for entry: Variant in (world_items.get(InventoryService.SNAPSHOT_ITEMS, []) as Array):
		ids.append(str((entry as Dictionary)["item_instance_id"]))
	ids.sort()
	return ids


func _sorted(ids: Array) -> PackedStringArray:
	var sorted: PackedStringArray = PackedStringArray(ids)
	sorted.sort()
	return sorted


func _log_has(text: String) -> bool:
	for line: String in GameLogger.captured_lines():
		if line.contains(text):
			return true
	return false


## Both players trade: `a` gives `a_quantity` units of `a_item`, `b` gives
## `b_quantity` units of `b_item`. Returns true when the exchange happened.
func _trade_items(world: ServerWorld, a: String, a_item: String, a_quantity: int, b: String, b_item: String, b_quantity: int) -> bool:
	var trade: TradeService = _trade(world)
	var asked: ActionResult = trade.request_trade(world, a, b)
	if not asked.ok:
		fail("test setup: request failed: " + asked.reason)
		return false
	var session_id: int = int(asked.event.get("session_id", 0))
	for step: ActionResult in [trade.accept(world, b, session_id), trade.set_offer(world, a, session_id, a_item, a_quantity), trade.set_offer(world, b, session_id, b_item, b_quantity)]:
		if not step.ok:
			fail("test setup: trade step failed: " + step.reason)
			return false
	var revision: int = trade.session_of(a).revision
	var first: ActionResult = trade.set_confirmed(world, a, session_id, revision, true)
	var second: ActionResult = trade.set_confirmed(world, b, session_id, revision, true)
	if not first.ok or not second.ok:
		fail("test setup: confirmation failed: %s / %s" % [first.reason, second.reason])
		return false
	return trade.session_of(a) == null


# ------------------------------------------------------------ the cell of a dropped part

func test_a_part_of_a_stack_put_down_lies_in_the_cell_of_its_position() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var alice: PlayerState = world.join("alice")
	_move(world, alice.player_id, HOME)
	var food: String = _give(world, alice, FOOD, 5)

	var part: ActionResult = world.try_drop_item(alice.player_id, food, 2)
	assert_true(part.ok, part.reason)
	assert_eq(part.event.get("event_type", ""), InventoryService.EVENT_ITEM_UNITS_DROPPED)
	assert_eq(part.event.get("cell_id", ""), HOME_CELL, "the cell of the position, not a constant")
	var lying: String = str(part.event.get("world_item_instance_id", ""))
	assert_eq(world.inventory.get_item(lying).location_id, HOME_CELL)
	assert_eq(world.cell_index.cell_of(lying), HOME_CELL, "the new item is in the cell index")
	assert_eq(world.cell_index.kind_of(lying), InventoryService.ENTITY_KIND_ITEM)
	assert_eq(world.inventory.world_item_ids_in_cell(HOME_CELL), PackedStringArray([lying]))
	assert_eq(_ids_in_document(world.cell_document(HOME_CELL)), PackedStringArray([lying]), "and in that cell's save data")
	assert_false(world.cell_index.has(food), "the stack it came from is carried: in no cell")

	# Somewhere else: another part and then the rest (the stack itself).
	_move(world, alice.player_id, DEPOT)
	var second: ActionResult = world.try_drop_item(alice.player_id, food, 1)
	assert_true(second.ok, second.reason)
	var second_lying: String = str(second.event.get("world_item_instance_id", ""))
	var rest: ActionResult = world.try_drop_item(alice.player_id, food)
	assert_true(rest.ok, rest.reason)
	assert_eq(second.event.get("cell_id", ""), DEPOT_CELL)
	assert_eq(rest.event.get("cell_id", ""), DEPOT_CELL, "a part and a whole stack get the same cell")
	assert_eq(world.cell_index.cell_of(second_lying), world.cell_index.cell_of(food))
	assert_eq(world.inventory.world_item_ids_in_cell(DEPOT_CELL), _sorted([second_lying, food]))
	assert_eq(world.inventory.world_item_ids_in_cell(HOME_CELL), PackedStringArray([lying]), "the first part stayed where it was put")
	assert_eq(_totals(world), {FOOD: 5})
	_assert_consistent(world, "after three drops")


# ------------------------------------------------------------ a merged pickup leaves the cell

func test_a_picked_up_item_leaves_its_cell_and_a_merged_one_is_retired() -> void:
	var world: ServerWorld = _world(WorldCellStore.new())
	var alice: PlayerState = world.join("alice")
	_move(world, alice.player_id, HOME)
	var carried: String = _give(world, alice, FOOD, 3)
	var four: String = _lay(world, FOOD, 4, HOME + BESIDE)
	var two: String = _lay(world, FOOD, 2, HOME - BESIDE)
	assert_eq(world.inventory.world_item_ids_in_cell(HOME_CELL), _sorted([four, two]))

	# Two units fill the carried stack, the other two keep the item's id in a slot.
	var partly: ActionResult = world.try_pickup(alice.player_id, four)
	assert_true(partly.ok, partly.reason)
	assert_eq(_rows(world, alice.player_id), [[FOOD, FOOD_MAX], [FOOD, 2]])
	assert_false(world.cell_index.has(four), "a partly merged item is carried: in no cell")
	assert_eq(world.inventory.get_item(four).location_id, alice.inventory_id)
	assert_true(world.registry.has(four))
	assert_false(world.registry.is_tombstoned(four), "its id lives on")
	assert_eq(world.inventory.world_item_ids_in_cell(HOME_CELL), PackedStringArray([two]))

	# Both units fit into the stacks alice carries: the item is gone for good.
	var merged: ActionResult = world.try_pickup(alice.player_id, two)
	assert_true(merged.ok, merged.reason)
	assert_eq(merged.event.get("slot_id", "?"), "", "it took no slot")
	assert_eq(_rows(world, alice.player_id), [[FOOD, FOOD_MAX], [FOOD, 4]])
	assert_null(world.inventory.get_item(two))
	assert_false(world.cell_index.has(two), "a merged item is in no cell")
	assert_false(world.registry.has(two))
	assert_true(world.registry.is_tombstoned(two), "its id is retired: nothing can bring it back")
	assert_eq(world.inventory.world_item_ids_in_cell(HOME_CELL).size(), 0)
	assert_eq(world.cell_index.count_in_cell(HOME_CELL), 0)
	assert_true(WorldCellDocument.is_empty(world.cell_document(HOME_CELL)), "the cell has nothing to save")
	assert_eq(_totals(world), {FOOD: 9})
	assert_eq(world.inventory.get_item(carried).quantity, FOOD_MAX)
	_assert_consistent(world, "after two pickups")


# ------------------------------------------------------------ unload and reload

func test_units_put_down_and_merged_pickups_survive_an_unload_and_reload_of_their_cell() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	_move(world, alice.player_id, HOME)
	_move(world, bob.player_id, HOME + BESIDE)
	var alice_food: String = _give(world, alice, FOOD, 5)
	var bob_food: String = _give(world, bob, FOOD, 3)
	var single: String = _lay(world, SINGLE, 1, HOME - BESIDE)
	var two: String = str(world.try_drop_item(alice.player_id, alice_food, 2).event.get("world_item_instance_id", ""))
	var one: String = str(world.try_drop_item(alice.player_id, alice_food, 1).event.get("world_item_instance_id", ""))
	assert_true(world.try_pickup(bob.player_id, two).ok, "both units fill bob's stack")
	assert_null(world.inventory.get_item(two))
	var totals: Dictionary = {FOOD: 8, SINGLE: 1}
	assert_eq(_totals(world), totals)
	var next_sequence: int = world.ids.get_next_sequence()

	# Everybody leaves until the cell is saved and released.
	_move(world, alice.player_id, AWAY)
	_move(world, bob.player_id, AWAY + BESIDE)
	_run(world, RELEASE_SEC)
	assert_eq(_cells(world).state_of(HOME_CELL), WorldCellLifecycle.State.UNLOADED)
	assert_eq(_ids_in_document(store.document_of(HOME_CELL)), _sorted([single, one]), "what lay there was saved: the unit alice left and the single item")
	assert_null(world.inventory.get_item(one), "the lying unit left memory with its cell")
	assert_false(world.registry.has(one))
	assert_false(world.registry.is_tombstoned(one), "... without being retired")
	assert_true(world.registry.is_tombstoned(two), "the merged item stays retired")
	assert_eq(_totals(world), {FOOD: 7}, "what is carried never leaves memory")
	_assert_consistent(world, "cell released")

	# Back: the same unit lies there, nothing else.
	_move(world, alice.player_id, HOME)
	_move(world, bob.player_id, HOME + BESIDE)
	assert_eq(world.inventory.world_item_ids(), _sorted([single, one]))
	assert_eq(world.inventory.get_item(one).quantity, 1)
	assert_eq(world.inventory.world_position_of(one), HOME, "where alice put it")
	assert_null(world.inventory.get_item(two), "the merged item did not come back")
	assert_eq(_totals(world), totals, "every unit is there once")
	assert_eq(world.ids.get_next_sequence(), next_sequence, "no new ids were handed out")
	_assert_consistent(world, "cell loaded again")

	# Alice takes her unit back (it merges away); more trips change nothing.
	assert_true(world.try_pickup(alice.player_id, one).ok)
	assert_eq(_rows(world, alice.player_id), [[FOOD, 3]])
	for trip: int in range(2):
		_move(world, alice.player_id, AWAY)
		_move(world, bob.player_id, AWAY + BESIDE)
		_run(world, RELEASE_SEC)
		assert_eq(_cells(world).state_of(HOME_CELL), WorldCellLifecycle.State.UNLOADED, "trip %d" % trip)
		assert_eq(_ids_in_document(store.document_of(HOME_CELL)), PackedStringArray([single]), "trip %d: the saved cell no longer has the merged unit" % trip)
		_move(world, alice.player_id, HOME)
		_move(world, bob.player_id, HOME + BESIDE)
		assert_eq(world.inventory.world_item_ids(), PackedStringArray([single]), "trip %d: only the single item lies there" % trip)
		assert_null(world.inventory.get_item(one), "trip %d: the merged unit stays gone" % trip)
		assert_eq(_totals(world), totals, "trip %d" % trip)
		assert_eq(_rows(world, alice.player_id), [[FOOD, 3]])
		assert_eq(_rows(world, bob.player_id), [[FOOD, FOOD_MAX]])
		_assert_consistent(world, "trip %d" % trip)


func test_a_cell_document_from_before_merged_pickups_brings_no_unit_back() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var alice: PlayerState = world.join("alice")
	_move(world, alice.player_id, HOME)
	var carried: String = _give(world, alice, FOOD, 3)
	var four: String = _lay(world, FOOD, 4, HOME + BESIDE)
	var two: String = _lay(world, FOOD, 2, HOME - BESIDE)
	# The cell is saved with both items lying in it.
	_move(world, alice.player_id, AWAY)
	_run(world, RELEASE_SEC)
	var stale: Dictionary = store.document_of(HOME_CELL)
	assert_eq(_ids_in_document(stale), _sorted([four, two]))
	_move(world, alice.player_id, HOME)
	# One merges partly (it is carried with fewer units), one completely.
	assert_true(world.try_pickup(alice.player_id, four).ok)
	assert_true(world.try_pickup(alice.player_id, two).ok)
	assert_eq(_rows(world, alice.player_id), [[FOOD, FOOD_MAX], [FOOD, 4]])
	_move(world, alice.player_id, AWAY)
	_run(world, RELEASE_SEC)
	assert_eq(_cells(world).state_of(HOME_CELL), WorldCellLifecycle.State.UNLOADED)
	assert_false(store.saved_cell_ids().has(HOME_CELL), "the emptied cell has no document")

	# The old document comes back (a restored backup) and the cell is loaded.
	store.replace_documents({HOME_CELL: stale})
	_move(world, alice.player_id, HOME)
	assert_true(_cells(world).is_loaded(HOME_CELL))
	assert_eq(world.inventory.world_item_ids().size(), 0, "neither saved copy came into the world")
	assert_null(world.inventory.get_item(two), "the merged item was not revived")
	assert_eq(world.inventory.get_item(four).quantity, 4, "the carried item kept what it holds now, not what was saved")
	assert_eq(world.inventory.get_item(four).location_id, alice.inventory_id)
	assert_eq(world.inventory.get_item(carried).quantity, FOOD_MAX)
	assert_eq(world.inventory.item_count(), 2)
	assert_eq(_totals(world), {FOOD: 9}, "no unit was doubled")
	assert_true(_log_has(LOG_SKIPPED))
	_assert_consistent(world, "stale document loaded")
	# The next release of the cell writes the truth again.
	_move(world, alice.player_id, AWAY)
	_run(world, RELEASE_SEC)
	assert_false(store.saved_cell_ids().has(HOME_CELL), "the stale copy is gone with the next save")


# ------------------------------------------------------------ a trade and world documents

func test_drops_merged_pickups_and_a_trade_survive_world_documents_with_released_cells() -> void:
	var store: WorldCellStore = WorldCellStore.new()
	var world: ServerWorld = _world(store)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	_move(world, alice.player_id, HOME)
	_move(world, bob.player_id, HOME + BESIDE)
	var alice_food: String = _give(world, alice, FOOD, 4)
	var bulk: String = _give(world, bob, BULK, 6)
	var bob_food: String = _give(world, bob, FOOD, 4)
	var totals: Dictionary = {FOOD: 8, BULK: 6}
	# Alice puts one unit down, then trades two for bob's bulk.
	var one: String = str(world.try_drop_item(alice.player_id, alice_food, 1).event.get("world_item_instance_id", ""))
	assert_true(_trade_items(world, alice.player_id, alice_food, 2, bob.player_id, bulk, 6), "the trade was completed")
	assert_eq(_rows(world, alice.player_id), [[FOOD, 1], [BULK, 6]])
	assert_eq(_rows(world, bob.player_id), [[FOOD, 1], [FOOD, FOOD_MAX]], "one unit filled bob's stack, one took the slot his bulk left")
	# Bob picks up the unit alice left (it merges away) and leaves one of his own.
	assert_true(world.try_pickup(bob.player_id, one).ok)
	assert_null(world.inventory.get_item(one))
	var left: String = str(world.try_drop_item(bob.player_id, bob_food, 1).event.get("world_item_instance_id", ""))
	assert_eq(world.cell_index.cell_of(left), HOME_CELL)
	# Alice carries the bulk to the depot and leaves a part of it; bob leaves too.
	_move(world, alice.player_id, DEPOT)
	var depot_part: String = str(world.try_drop_item(alice.player_id, bulk, 2).event.get("world_item_instance_id", ""))
	_move(world, bob.player_id, DEPOT + BESIDE)
	_run(world, RELEASE_SEC)
	assert_eq(_cells(world).state_of(HOME_CELL), WorldCellLifecycle.State.UNLOADED)
	assert_eq(_ids_in_document(store.document_of(HOME_CELL)), PackedStringArray([left]))
	var alice_rows: Array = _rows(world, alice.player_id)
	var bob_rows: Array = _rows(world, bob.player_id)
	assert_eq(alice_rows, [[FOOD, 1], [BULK, 4]])
	assert_eq(bob_rows, [[FOOD, 2], [FOOD, 4]])
	_assert_consistent(world, "before the save")

	# Save documents -> JSON -> a brand-new world with its own store.
	var documents: Dictionary = JSON.parse_string(JSON.stringify(world.to_documents())) as Dictionary
	assert_true((documents["cells"] as Dictionary).has(HOME_CELL), "the released cell is saved as a cell document")
	assert_eq(_totals_of(_saved_items(documents)), totals, "the save holds every unit")
	_assert_saved_once(documents, "first save")
	var restored: ServerWorld = _world(WorldCellStore.new())
	var errors: PackedStringArray = restored.restore_documents(documents["world_state"], documents["players"], documents["cells"])
	assert_eq(errors.size(), 0, "; ".join(errors))
	assert_eq(_rows(restored, alice.player_id), alice_rows)
	assert_eq(_rows(restored, bob.player_id), bob_rows)
	assert_true(restored.registry.is_tombstoned(one), "the merged unit is still retired")
	assert_eq(restored.inventory.world_item_ids(), PackedStringArray([depot_part]), "what lay in a cell in memory is in memory again")
	assert_eq(restored.inventory.get_item(depot_part).location_id, DEPOT_CELL)
	_assert_consistent(restored, "restored")

	# The game goes on: alice walks home, finds bob's unit and takes it.
	var alice_again: PlayerState = restored.join("alice")
	restored.join("bob")
	_move(restored, alice_again.player_id, HOME + BESIDE)
	assert_eq(restored.inventory.world_item_ids_in_cell(HOME_CELL), PackedStringArray([left]), "the released cell came back with its unit")
	assert_eq(restored.inventory.get_item(left).quantity, 1)
	assert_true(restored.try_pickup(alice_again.player_id, left).ok)
	assert_eq(_rows(restored, alice_again.player_id), [[FOOD, 2], [BULK, 4]])
	assert_true(restored.registry.is_tombstoned(left))
	_run(restored, RELEASE_SEC)
	var again: Dictionary = JSON.parse_string(JSON.stringify(restored.to_documents())) as Dictionary
	assert_eq(_totals_of(_saved_items(again)), totals, "still every unit, once")
	_assert_saved_once(again, "second save")
	_assert_consistent(restored, "after the second save")
