extends TestCase
## P2-T15 / P2-T16 on top of per-cell persistence (P3-1, docs/09 §15.1,
## docs/10), through WorldPersistence and real files: after units were put
## down, pickups merged into carried stacks and a trade was completed, a
## save -> server "restart" (a brand-new world object from disk) -> restore
## keeps every unit and every id exactly once, with cells in memory and
## cells released, and a cell file that is older than the rest of the save
## brings no merged unit back. Rules without files:
## tests/unit/item_moves_in_cells_test.gd.

const WORLD: String = "item_moves_persist_world"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const FOOD: String = "dev_food_ration"
const FOOD_MAX: int = 5
const BANDAGE: String = "dev_bandage"
const SINGLE: String = "dev_test_item"
## 10 m cells. Players start at SPAWN (SPAWN_CELL); from FAR the spawn cell
## is not kept in memory.
const SPAWN: Vector3 = Vector3(25.0, 0.0, 25.0)
const SPAWN_CELL: String = "cell_2_2"
const BESIDE: Vector3 = Vector3(1.0, 0.0, 0.0)
const FAR: Vector3 = Vector3(-35.0, 0.0, -35.0)
const FAR_CELL: String = "cell_-4_-4"
## Standing in these four cells (one after the other) brings every cell of
## the 10 x 10 test map into memory once.
const TOUR: Array[Vector3] = [Vector3(-25.0, 0.0, -25.0), Vector3(-25.0, 0.0, 25.0), Vector3(25.0, 0.0, -25.0), Vector3(25.0, 0.0, 25.0)]
## Longer than unload_delay_sec.
const RELEASE_SEC: float = 2.0
const LOG_SKIPPED: String = "saved world items skipped"

var _root: String = ""
var _settings: WorldCellSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/item_moves_persist_%d" % Time.get_ticks_usec()
	# Only the player's own cell is simulated, two rings are kept in memory,
	# cells are released one second after they are no longer wanted.
	_settings = WorldCellSettings.new()
	_settings.cell_size_m = 10.0
	_settings.bounds_min_m = Vector2(-50.0, -50.0)
	_settings.bounds_max_m = Vector2(50.0, 50.0)
	_settings.active_radius_cells = 0
	_settings.preload_radius_cells = 2
	_settings.preload_lookahead_sec = 0.0
	_settings.deactivate_delay_sec = 0.0
	_settings.unload_delay_sec = 1.0
	_settings.refresh_period_sec = 0.0
	_settings.max_preload_loads_per_refresh = 1000


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _config() -> CompositionConfig:
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
	config.trade = TradeSettings.new()
	config.world_cells = _settings
	return config


func _save_service() -> SaveService:
	return SaveService.new(_root)


func _persistence() -> WorldPersistence:
	return WorldPersistence.new(_save_service(), _config())


## A server start: a brand-new world object built from what is on disk.
func _boot() -> ServerWorld:
	return _persistence().load_or_create(WORLD)


func _cells(world: ServerWorld) -> WorldCellService:
	return world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


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


func _read_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary


func _world_state_file() -> Dictionary:
	return _read_json(_save_service().world_dir(WORLD).path_join(SaveService.WORLD_STATE_FILE))


func _cell_file_path(cell_id: String) -> String:
	return _save_service().world_dir(WORLD).path_join(SaveService.cell_file(cell_id))


## Ids of the world items in a cell file of the save on disk, sorted.
func _ids_in_cell_file(cell_id: String) -> PackedStringArray:
	var ids: PackedStringArray = []
	var world_items: Dictionary = _read_json(_cell_file_path(cell_id))[WorldCellDocument.KEY_WORLD_ITEMS] as Dictionary
	for entry: Variant in (world_items.get(InventoryService.SNAPSHOT_ITEMS, []) as Array):
		ids.append(str((entry as Dictionary)["item_instance_id"]))
	ids.sort()
	return ids


## Every item of the save on disk: the world document's and every cell file's.
func _items_on_disk() -> Array:
	var items: Array = ((_world_state_file()["inventory"] as Dictionary)[InventoryService.SNAPSHOT_ITEMS] as Array).duplicate()
	for cell_id: String in _save_service().saved_cell_ids(WORLD):
		var world_items: Dictionary = _read_json(_cell_file_path(cell_id))[WorldCellDocument.KEY_WORLD_ITEMS] as Dictionary
		items.append_array(world_items.get(InventoryService.SNAPSHOT_ITEMS, []) as Array)
	return items


## The save on disk holds exactly `totals` units ({definition: units}), every
## item once, and no retired id.
func _assert_disk(totals: Dictionary, label: String) -> void:
	var retired: Array = _world_state_file()["tombstones"] as Array
	var seen: Dictionary = {}
	var on_disk: Dictionary = {}
	for entry: Variant in _items_on_disk():
		var item_id: String = str((entry as Dictionary)["item_instance_id"])
		var definition_id: String = str((entry as Dictionary)["definition_id"])
		assert_false(seen.has(item_id), "%s: %s is saved once" % [label, item_id])
		assert_false(retired.has(item_id), "%s: %s is not a retired id" % [label, item_id])
		seen[item_id] = true
		on_disk[definition_id] = int(on_disk.get(definition_id, 0)) + int((entry as Dictionary)["quantity"])
	assert_eq(on_disk, totals, label + ": the save holds every unit once")


## Walks a player through the whole map and returns the id and the units of
## every world item that came into memory on the way: {item_id: quantity}.
func _tour(world: ServerWorld, player_id: String) -> Dictionary:
	var seen: Dictionary = {}
	for stop: Vector3 in TOUR:
		_move(world, player_id, stop)
		for item_id: String in world.inventory.world_item_ids():
			var quantity: int = world.inventory.get_item(item_id).quantity
			if seen.has(item_id) and int(seen[item_id]) != quantity:
				fail("%s changed during the tour" % item_id)
			seen[item_id] = quantity
	return seen


func _log_has(text: String) -> bool:
	for line: String in GameLogger.captured_lines():
		if line.contains(text):
			return true
	return false


## Both players trade: `a` gives `a_quantity` units of `a_item`, `b` gives
## `b_quantity` units of `b_item`. Returns true when the exchange happened.
func _trade_items(world: ServerWorld, a: String, a_item: String, a_quantity: int, b: String, b_item: String, b_quantity: int) -> bool:
	var trade: TradeService = world.get_system(TradeService.SYSTEM_ID) as TradeService
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


# ------------------------------------------------------------ save, restart, restore

func test_drops_merged_pickups_and_a_trade_survive_a_restart() -> void:
	var persistence: WorldPersistence = _persistence()
	var world: ServerWorld = persistence.load_or_create(WORLD)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	_move(world, bob.player_id, SPAWN + BESIDE)
	var alice_food: String = _give(world, alice, FOOD, 4)
	var bandage: String = _give(world, bob, BANDAGE, 5)
	var bob_food: String = _give(world, bob, FOOD, 4)
	var totals: Dictionary = {FOOD: 8, BANDAGE: 5}
	# Alice puts one unit down, then trades two for bob's bandages.
	var one: String = str(world.try_drop_item(alice.player_id, alice_food, 1).event.get("world_item_instance_id", ""))
	assert_eq(world.cell_index.cell_of(one), SPAWN_CELL)
	assert_true(_trade_items(world, alice.player_id, alice_food, 2, bob.player_id, bandage, 5), "the trade was completed")
	# Bob picks up the unit alice left (it merges away) and leaves one of his own.
	assert_true(world.try_pickup(bob.player_id, one).ok)
	var left: String = str(world.try_drop_item(bob.player_id, bob_food, 1).event.get("world_item_instance_id", ""))
	# Both walk far away; alice leaves a part of the bandages there. The
	# spawn cell is released, which writes a save.
	_move(world, alice.player_id, FAR)
	var far_part: String = str(world.try_drop_item(alice.player_id, bandage, 2).event.get("world_item_instance_id", ""))
	_move(world, bob.player_id, FAR + BESIDE)
	_run(world, RELEASE_SEC)
	assert_eq(_cells(world).state_of(SPAWN_CELL), WorldCellLifecycle.State.UNLOADED, "the spawn cell was released (and saved)")
	assert_eq(_ids_in_cell_file(SPAWN_CELL), PackedStringArray([left]), "its file holds the unit bob left, not the merged one")
	var alice_rows: Array = _rows(world, alice.player_id)
	var bob_rows: Array = _rows(world, bob.player_id)
	assert_eq(alice_rows, [[FOOD, 1], [BANDAGE, 3]])
	assert_eq(bob_rows, [[FOOD, 2], [FOOD, 4]])
	world.leave(alice.player_id)
	world.leave(bob.player_id)
	assert_eq(persistence.save(world), OK)
	assert_eq(_ids_in_cell_file(FAR_CELL), PackedStringArray([far_part]), "a part put down is saved with the cell of its position")
	_assert_disk(totals, "first save")

	# --- restart ---
	persistence = _persistence()
	var second: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(second)
	if second == null:
		return
	assert_eq(second.inventory.world_item_ids().size(), 0, "a restart brings no cell into memory")
	var alice_back: PlayerState = second.join("alice")
	var bob_back: PlayerState = second.join("bob")
	assert_eq(alice_back.player_id, alice.player_id)
	assert_eq(_rows(second, alice_back.player_id), alice_rows, "alice carries what she carried")
	assert_eq(_rows(second, bob_back.player_id), bob_rows, "bob carries what he carried")
	assert_eq(second.inventory.get_item(bandage).location_id, alice_back.inventory_id, "the traded stack kept its id")
	assert_eq(second.inventory.world_item_ids(), PackedStringArray([far_part]), "the cells around the players are loaded")
	assert_eq(second.inventory.get_item(far_part).quantity, 2)
	assert_eq(second.cell_index.cell_of(far_part), FAR_CELL)
	assert_null(second.inventory.get_item(one), "the merged unit is gone")
	assert_true(second.registry.is_tombstoned(one), "... and its id is retired")
	# Alice walks back to the spawn point: bob's unit lies there; she takes it.
	_move(second, alice_back.player_id, SPAWN)
	assert_eq(second.inventory.world_item_ids_in_cell(SPAWN_CELL), PackedStringArray([left]))
	assert_eq(second.inventory.get_item(left).quantity, 1)
	assert_true(second.try_pickup(alice_back.player_id, left).ok)
	assert_eq(_rows(second, alice_back.player_id), [[FOOD, 2], [BANDAGE, 3]], "it merged into her stack")
	_move(second, alice_back.player_id, FAR)
	_run(second, RELEASE_SEC)
	assert_eq(_cells(second).state_of(SPAWN_CELL), WorldCellLifecycle.State.UNLOADED)
	assert_false(_save_service().saved_cell_ids(WORLD).has(SPAWN_CELL), "the emptied cell has no file any more")
	second.leave(alice_back.player_id)
	second.leave(bob_back.player_id)
	assert_eq(persistence.save(second), OK)
	_assert_disk(totals, "second save")

	# --- restart again: the whole map holds one lying item ---
	var third: ServerWorld = _boot()
	assert_not_null(third)
	if third == null:
		return
	var seen: Dictionary = _tour(third, third.join("alice").player_id)
	assert_eq(seen, {far_part: 2}, "nothing came back anywhere on the map")
	assert_true(third.registry.is_tombstoned(one))
	assert_true(third.registry.is_tombstoned(left))
	assert_eq(_rows(third, alice.player_id), [[FOOD, 2], [BANDAGE, 3]])
	assert_eq(_rows(third, bob.player_id), bob_rows)


func test_a_cell_file_from_before_merged_pickups_brings_no_unit_back_after_a_restart() -> void:
	var persistence: WorldPersistence = _persistence()
	var world: ServerWorld = persistence.load_or_create(WORLD)
	var alice: PlayerState = world.join("alice")
	var carried: String = _give(world, alice, FOOD, 3)
	var four: String = _lay(world, FOOD, 4, SPAWN + BESIDE)
	var two: String = _lay(world, FOOD, 2, SPAWN - BESIDE)
	var single: String = _lay(world, SINGLE, 1, SPAWN + BESIDE)
	# Saved with all three lying in the spawn cell.
	assert_eq(persistence.save(world), OK)
	var before: PackedStringArray = PackedStringArray([four, two, single])
	before.sort()
	assert_eq(_ids_in_cell_file(SPAWN_CELL), before)
	# One merges partly (it is carried with fewer units), one completely.
	assert_true(world.try_pickup(alice.player_id, four).ok)
	assert_true(world.try_pickup(alice.player_id, two).ok)
	assert_eq(_rows(world, alice.player_id), [[FOOD, FOOD_MAX], [FOOD, 4]])
	assert_false(world.cell_index.has(four))
	assert_false(world.cell_index.has(two))
	world.leave(alice.player_id)
	assert_eq(persistence.save(world), OK)
	assert_eq(_ids_in_cell_file(SPAWN_CELL), PackedStringArray([single]))
	_assert_disk({FOOD: 9, SINGLE: 1}, "after the pickups")
	# The current cell file breaks; its newest readable copy is the one from
	# before the pickups (three items).
	var file: FileAccess = FileAccess.open(_cell_file_path(SPAWN_CELL), FileAccess.WRITE)
	file.store_string("{ broken")
	file.close()

	var restarted: ServerWorld = _boot()
	assert_not_null(restarted)
	if restarted == null:
		return
	var back: PlayerState = restarted.join("alice")
	assert_eq(_cells(restarted).state_of(SPAWN_CELL), WorldCellLifecycle.State.ACTIVE, "the cell loads from its backup")
	assert_eq(restarted.inventory.world_item_ids(), PackedStringArray([single]), "neither merged item is put back into the world")
	assert_null(restarted.inventory.get_item(two), "the item that merged away was not revived")
	assert_true(restarted.registry.is_tombstoned(two))
	assert_eq(restarted.inventory.get_item(four).quantity, 4, "the carried item kept what it holds now, not what the old file says")
	assert_eq(restarted.inventory.get_item(four).location_id, back.inventory_id)
	assert_eq(restarted.inventory.get_item(carried).quantity, FOOD_MAX)
	assert_eq(_rows(restarted, back.player_id), [[FOOD, FOOD_MAX], [FOOD, 4]])
	assert_eq(restarted.inventory.item_count(), 3, "two carried stacks and the single item")
	assert_true(_log_has(LOG_SKIPPED))
	# The next save writes the truth again.
	restarted.leave(back.player_id)
	assert_eq(_persistence().save(restarted), OK)
	assert_eq(_ids_in_cell_file(SPAWN_CELL), PackedStringArray([single]))
	_assert_disk({FOOD: 9, SINGLE: 1}, "after the restart")
