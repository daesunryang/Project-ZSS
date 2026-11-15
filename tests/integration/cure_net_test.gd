extends TestCase
## P2-T7: using a cure over real ENet (server + 2 clients).
## A client only asks ("use this item", the consume intent of P2-T3); the
## server takes one cure from the requester's own inventory and clears that
## player's infection if it is still treatable. The owner sees the smaller
## stack (InventoryNet) and its infection stage go back to "none" (owner
## survival events / snapshot). Nobody else receives anything about the
## infection or the treatment (docs/00 ADR-009). A cure is refused and kept
## when the player is not infected or it is too late.

const WORLD: String = "cure_net_test_world"
const NEVER: float = 1.0e9
const CURE: String = "t7_cure"
const STACK_MAX: int = 5
const CELL: String = DevWorldSeed.DEV_CELL_ID
## Players spawn at the origin; both positions are within pickup range.
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const OTHER_ITEM_AT: Vector3 = Vector3(-0.5, 0.0, 1.0)
const WAIT_MSEC: int = 5000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const FORGED_REQUEST_ID: int = 77
const ZOMBIE: String = "zombie_000001"
## Needs do not move on their own during a test (the longest allowed climb).
const FROZEN_NEED_HOURS: float = 100000.0
## Infection stages do not advance on their own during a test.
const FROZEN_STAGE_HOURS: float = 100000.0
## Words that must not appear in anything another player receives.
const PRIVATE_WORDS: PackedStringArray = ["infect", "cure", "latent", "early", "progressing", "stage", "treat"]

var _cluster: NetTestCluster = null
var _net_settings: NetworkSettings = null
var _inventory_net: InventoryNetSettings = null
var _config: CompositionConfig = null
var _world: ServerWorld = null
var _save_root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_save_root = ""
	_net_settings = NetworkSettings.new()
	_net_settings.autosave_interval_sec = 0.0
	# Pickups are test setup here: keep their limiter out of the way.
	_net_settings.pickup_intent_rate_per_sec = GENEROUS_RATE
	_net_settings.pickup_intent_burst = GENEROUS_BURST
	_inventory_net = InventoryNetSettings.new()
	_inventory_net.consume_intent_rate_per_sec = GENEROUS_RATE
	_inventory_net.consume_intent_burst = GENEROUS_BURST
	_config = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.dev_seed = DevWorldSeed.new()
	_config.catalog = _new_catalog()
	# The infection changes only through the test and the cure.
	_config.survival = SurvivalSettings.new()
	_config.survival.infection_chance_bite = 1.0
	_config.survival.infection_latent_hours = FROZEN_STAGE_HOURS
	_config.survival.infection_early_hours = FROZEN_STAGE_HOURS
	_config.survival.infection_progressing_hours = FROZEN_STAGE_HOURS
	_config.survival.hunger_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.thirst_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.fatigue_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.respawn_delay_sec = NEVER
	_config.survival_net = SurvivalNetSettings.new()
	_config.survival_net.owner_snapshot_rate_hz = 20.0
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	# No zombies.
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.inventory_net = _inventory_net
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	_world = null


func after_each() -> void:
	Engine.print_error_messages = true
	if _cluster != null:
		await _cluster.shutdown()
	if not _save_root.is_empty():
		SaveService.remove_tree(_save_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## The shipped item definitions plus a test cure.
func _new_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var cure: ItemDefinition = ItemDefinition.new()
	cure.definition_id = CURE
	cure.max_stack = STACK_MAX
	cure.cures_infection = true
	catalog.add(cure)
	return catalog


func _start_server() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


## Joins "alice" and "bob" (after the test placed its items). Empty on failure.
func _join_two() -> Array[NetworkService]:
	var joined: Array[NetworkService] = []
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return joined
	joined.append(a)
	joined.append(b)
	return joined


func _module(service: NetworkService) -> InventoryNetModule:
	return service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule


func _survival_module(service: NetworkService) -> SurvivalNetModule:
	return service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule


## The client's survival mirror.
func _mirror(service: NetworkService) -> ClientSurvivalState:
	return _survival_module(service).client_state


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _spawn(definition_id: String, quantity: int = 1, position: Vector3 = ITEM_AT) -> String:
	return _world.inventory.spawn_world_item(definition_id, quantity, CELL, position)


## Infects a player on the server with a bite (the configured chance is 1).
func _infect(player_id: String) -> void:
	var exposed: ActionResult = _survival().apply_infection_exposure(player_id, InfectionState.Exposure.BITE, ZOMBIE)
	if not exposed.ok or _survival().infection_stage(player_id) != InfectionState.Stage.LATENT:
		fail("test setup: infection failed: " + exposed.reason)


func _stage_name(player_id: String) -> String:
	return InfectionState.stage_name(_survival().infection_stage(player_id))


## Rows [request_id, ok, reason] of every consume result of `service`.
func _consume_results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).consume_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Rows [signal name, payload] of the inventory mirror signals of `service`.
func _mirror_signals_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	var module: InventoryNetModule = _module(service)
	module.world_items_added.connect(func(ids: PackedStringArray) -> void: rows.append(["world_items_added", Array(ids)]))
	module.inventory_items_removed.connect(func(ids: PackedStringArray) -> void: rows.append(["inventory_items_removed", Array(ids)]))
	module.inventory_item_changed.connect(func(item_id: String) -> void: rows.append(["inventory_item_changed", item_id]))
	return rows


## Every survival event `service` receives from now on.
func _survival_events_of(service: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_mirror(service).event_received.connect(func(event: Dictionary) -> void: events.append(event))
	return events


## Counts every change notification of the client's survival mirror.
func _mirror_changes_of(service: NetworkService) -> Array[int]:
	var changes: Array[int] = [0]
	_mirror(service).changed.connect(func() -> void: changes[0] += 1)
	return changes


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


## Lets the server run some ticks so anything still in flight arrives.
func _settle() -> void:
	for tick: int in range(SETTLE_TICKS):
		await tree.physics_frame


## Picks up `item_ids` through the real pickup RPC and waits for the mirror.
func _pick_up(client: NetworkService, item_ids: Array) -> bool:
	var results: Dictionary = {}
	client.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: results[request_id] = [ok, reason])
	for item_id: String in item_ids:
		client.request_pickup(item_id)
	var done: bool = await _wait(func() -> bool:
		for item_id: String in item_ids:
			if not client.client_state.has_inventory_item(item_id):
				return false
		return true)
	if not done:
		fail("test setup: pickup of %s failed: %s" % [str(item_ids), str(results)])
	return done


## "" when the client's inventory mirror equals what its player carries on
## the server, else what differs.
func _inventory_mismatch(client: NetworkService) -> String:
	var state: ClientWorldState = client.client_state
	var carried: Array[ItemInstance] = _world.inventory.items_in_inventory(_world.get_player(state.local_player_id).inventory_id)
	if state.inventory.size() != carried.size():
		return "inventory: mirror %d, server %d" % [state.inventory.size(), carried.size()]
	for item: ItemInstance in carried:
		if state.get_inventory_item(item.item_instance_id) != item.to_dict():
			return "carried item %s differs: %s" % [item.item_instance_id, str(state.get_inventory_item(item.item_instance_id))]
	return ""


## "" when the client's own infection stage equals the server's.
func _stage_mismatch(client: NetworkService) -> String:
	var server_stage: String = _stage_name(client.client_state.local_player_id)
	var mirror_stage: String = _mirror(client).infection_stage()
	return "" if server_stage == mirror_stage else "infection stage: mirror %s, server %s" % [mirror_stage, server_stage]


## Waits until the client's inventory and infection mirrors equal the server.
func _assert_owner_mirror_matches(client: NetworkService, label: String) -> void:
	var matched: bool = await _wait(func() -> bool: return _inventory_mismatch(client).is_empty() and _stage_mismatch(client).is_empty())
	assert_true(matched, "%s: %s %s" % [label, _inventory_mismatch(client), _stage_mismatch(client)])


# ------------------------------------------------------------ 1. infected, cured

func test_a_client_cures_its_infection_and_nobody_else_learns_anything() -> void:
	assert_true(_start_server(), "server started")
	var cure_id: String = _spawn(CURE, 2)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [cure_id]):
		return
	await _settle()
	# From here on everything bob receives is recorded.
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var b_changes: Array[int] = _mirror_changes_of(b)
	var b_consumes: Array[Array] = _consume_results_of(b)
	var b_signals: Array[Array] = _mirror_signals_of(b)
	var b_owner_messages: int = _module(b).owner_message_count
	var a_consumes: Array[Array] = _consume_results_of(a)
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var a_events: Array[Dictionary] = _survival_events_of(a)

	# Alice gets infected: only she learns it.
	_infect(alice_id)
	await _assert_owner_mirror_matches(a, "after the infection")
	assert_eq(_mirror(a).infection_stage(), "latent", "alice's mirror: latent")

	# Alice uses a cure: an intent with a request id and the item id only.
	var request_id: int = _module(a).request_consume(cure_id)
	assert_true(request_id > 0, "a joined client gets a request id")
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 1), "alice got her answer")
	assert_eq(a_consumes, [[request_id, true, ""]])
	assert_eq(_survival().infection_stage(alice_id), InfectionState.Stage.NONE, "server: alice is cured")
	assert_eq(_world.inventory.get_item(cure_id).quantity, 1, "server: one cure left the stack")
	await _assert_owner_mirror_matches(a, "after the cure")
	assert_eq(_mirror(a).infection_stage(), "none", "alice's mirror: no infection")
	assert_eq(a.client_state.get_inventory_item(cure_id).get("quantity", 0), 1, "alice's mirror: the smaller stack")
	var a_event_types: Array = []
	for event: Dictionary in a_events:
		a_event_types.append(str(event.get("event_type", "")))
	assert_eq(a_event_types, [SurvivalService.EVENT_PLAYER_INFECTED, SurvivalService.EVENT_PLAYER_INFECTION_CURED], "alice was told about her own infection and cure")

	# Healthy again: the second cure is refused and kept.
	var second_request: int = _module(a).request_consume(cure_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 2), "alice got her second answer")
	assert_eq(a_consumes[1], [second_request, false, SurvivalService.REASON_NOT_INFECTED], "nothing to cure: refused")
	assert_eq(_world.inventory.get_item(cure_id).quantity, 1, "server: the cure was not used up")
	await _settle()
	await _assert_owner_mirror_matches(a, "after the refused cure")
	assert_eq(a_signals, [["inventory_item_changed", cure_id]], "the owner: a smaller stack, once")
	assert_eq(_cluster.server.rejected_intent_count(SurvivalService.REASON_NOT_INFECTED), 1)
	assert_eq(_cluster.server.rejected_intent_count(), 1)

	# Bob received nothing at all: no survival event, no mirror change, no
	# result, no inventory message. Infection and treatment are private.
	assert_eq(b_events.size(), 0, "bob received a survival event: %s" % str(b_events))
	assert_eq(b_changes[0], 0, "bob's survival mirror never changed")
	assert_eq(b_consumes.size(), 0, "the result goes to the requester only")
	assert_eq(b_signals.size(), 0, "bob's inventory mirrors did not change")
	assert_eq(_module(b).owner_message_count, b_owner_messages, "bob never received an owner-only message")
	assert_eq(_mirror(b).infection_stage(), "none", "bob's mirror shows his own (healthy) state")
	assert_eq(_survival().infection_stage(bob_id), InfectionState.Stage.NONE)
	for event: Dictionary in _mirror(b).recent_events():
		var text: String = JSON.stringify(event).to_lower()
		for word: String in PRIVATE_WORDS:
			assert_not_contains(text, word, "bob's event history mentions the infection")
	assert_eq(_module(a).rejected_payload_count + _module(b).rejected_payload_count, 0, "the server's own messages pass the client validation")


# ------------------------------------------------------------ 2. refusals and manipulated requests

## P2-T12 note: this is about the consume intent (two arguments, always the
## requester itself), which is unchanged. Treating another player is a
## separate intent with a target argument (treat_other_net_test.gd).
func test_a_cure_cannot_be_used_on_somebody_else_or_too_late() -> void:
	assert_true(_start_server(), "server started")
	var alices: String = _spawn(CURE, 2)
	var bobs: String = _spawn(CURE, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [alices]):
		return
	if not await _pick_up(b, [bobs]):
		return
	# Bob is infected. Alice is healthy and holds two cures.
	_infect(bob_id)
	await _assert_owner_mirror_matches(b, "bob infected")
	await _settle()
	var a_consumes: Array[Array] = _consume_results_of(a)
	var b_consumes: Array[Array] = _consume_results_of(b)
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var before: Dictionary = _world.inventory.to_snapshot()
	var server: NetworkService = _cluster.server
	var module: InventoryNetModule = _module(a)

	# Alice cannot cure bob: her own cure works on herself only (refused,
	# she is healthy), and bob's cure is not hers to use.
	module.send_raw_consume_request(1, alices)
	module.send_raw_consume_request(2, bobs)
	module.send_raw_consume_request(3, bob_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 3), "alice got her answers")
	# A request cannot name the player to treat: the handler takes two
	# arguments and the engine refuses a call with more (reported as an
	# engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_consume.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, alices, bob_id)
	await _settle()
	Engine.print_error_messages = true
	assert_eq(a_consumes, [
		[1, false, SurvivalService.REASON_NOT_INFECTED],
		[2, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[3, false, InventoryService.REASON_NOT_IN_INVENTORY],
	])
	assert_eq(server.rejected_intent_count(), 3, "the call the engine refused never reached the handler")
	assert_eq(_world.inventory.to_snapshot(), before, "no cure was used up")
	assert_eq(_survival().infection_stage(bob_id), InfectionState.Stage.LATENT, "bob is still infected")
	assert_eq(b_consumes.size() + b_events.size(), 0, "bob was told nothing")
	# The refusal tells alice about herself only: she learned nothing about bob.
	assert_eq(a_events.size(), 0, "alice received no survival event")
	assert_eq(_mirror(a).infection_stage(), "none")

	# Too late: bob's infection has progressed past the treatable stage.
	_survival().get_vitals(bob_id).infection.stage = InfectionState.Stage.PROGRESSING
	await _assert_owner_mirror_matches(b, "bob progressing")
	var late_request: int = _module(b).request_consume(bobs)
	assert_true(await _wait(func() -> bool: return b_consumes.size() == 1), "bob got his answer")
	assert_eq(b_consumes, [[late_request, false, SurvivalService.REASON_TOO_LATE]])
	assert_eq(_world.inventory.to_snapshot(), before, "the cure was not used up")
	assert_eq(b.client_state.get_inventory_item(bobs).get("quantity", 0), 1, "bob still carries his cure")
	assert_eq(_survival().infection_stage(bob_id), InfectionState.Stage.PROGRESSING)

	# Still treatable: the same request is accepted and cures bob, nobody else.
	_survival().get_vitals(bob_id).infection.stage = InfectionState.Stage.EARLY
	await _assert_owner_mirror_matches(b, "bob early")
	var a_changes: Array[int] = _mirror_changes_of(a)
	var cure_request: int = _module(b).request_consume(bobs)
	assert_true(await _wait(func() -> bool: return b_consumes.size() == 2), "bob got his second answer")
	assert_eq(b_consumes[1], [cure_request, true, ""])
	assert_eq(_survival().infection_stage(bob_id), InfectionState.Stage.NONE)
	assert_null(_world.inventory.get_item(bobs), "bob's only cure is gone")
	await _assert_owner_mirror_matches(b, "bob cured")
	await _settle()
	assert_eq(a_events.size(), 0, "alice received nothing about bob's cure")
	assert_eq(a_changes[0], 0, "alice's survival mirror never changed")
	assert_eq(a_consumes.size(), 3, "alice received no result of bob's request")
	assert_eq(_world.inventory.get_item(alices).quantity, 2, "alice's cures are untouched")


# ------------------------------------------------------------ 3. saving

func test_a_cure_survives_a_server_restart() -> void:
	_save_root = "user://test_saves/cure_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	var cure_id: String = _spawn(CURE, 2)
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [cure_id]):
		return
	_infect(alice_id)
	_infect(bob_id)
	var save: SaveService = SaveService.new(_save_root)
	var a_consumes: Array[Array] = _consume_results_of(a)

	# Like eating, a cure is not saved on its own (docs/15 P2-123).
	var generation: int = save.current_generation(WORLD)
	_module(a).request_consume(cure_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 1), "alice used a cure")
	assert_eq(a_consumes[0].slice(1), [true, ""])
	await _settle()
	assert_eq(save.current_generation(WORLD), generation, "a cure alone does not write the world")
	# What a crash right now would bring back: the last save (the pickup), in
	# which the cure is still in the stack and nobody is infected yet. Never
	# one half without the other.
	var on_disk: ServerWorld = WorldPersistence.new(SaveService.new(_save_root), _config).load_or_create(WORLD)
	assert_not_null(on_disk)
	if on_disk == null:
		return
	assert_eq(on_disk.inventory.get_item(cure_id).quantity, 2, "on disk: the stack before the use")

	# --- full restart (the shutdown saves): state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	assert_eq(_world.inventory.get_item(cure_id).quantity, 1, "one cure was used")
	assert_eq(_survival().infection_stage(alice_id), InfectionState.Stage.NONE, "alice stays cured")
	assert_eq(_survival().infection_stage(bob_id), InfectionState.Stage.LATENT, "bob, who had no cure, is still infected")
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	var b2: NetworkService = await _cluster.join_client("bob")
	if a2 == null or b2 == null:
		fail("clients did not rejoin")
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	await _assert_owner_mirror_matches(a2, "session 2 (alice)")
	await _assert_owner_mirror_matches(b2, "session 2 (bob)")
	assert_eq(_mirror(a2).infection_stage(), "none")
	assert_eq(_mirror(b2).infection_stage(), "latent", "bob's own mirror: still infected")
	var a2_consumes: Array[Array] = _consume_results_of(a2)
	_module(a2).request_consume(cure_id)
	assert_true(await _wait(func() -> bool: return a2_consumes.size() == 1), "alice was answered")
	assert_eq(a2_consumes[0].slice(1), [false, SurvivalService.REASON_NOT_INFECTED], "nothing left to cure")
	assert_eq(a2.client_state.get_inventory_item(cure_id).get("quantity", 0), 1)
