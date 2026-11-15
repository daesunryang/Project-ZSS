extends TestCase
## P2-T6: using a bandage over real ENet (server + 2 clients).
## A client only asks ("use this item", the consume intent of P2-T3); the
## server takes one bandage from the requester's own inventory and stops the
## worst bleeding wound of that player. The owner sees the smaller stack
## (InventoryNet) and the wound that no longer bleeds (owner survival
## events / snapshot); nobody else is told anything about the wounds or the
## bandage. A bandage is refused and kept when nothing bleeds. Manipulated
## requests change nothing.

const WORLD: String = "bandage_net_test_world"
const NEVER: float = 1.0e9
const BANDAGE: String = "t6_bandage"
const PLAIN: String = "t6_plain"
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
const LETHAL_DAMAGE: float = 100000.0
const LACERATION_DAMAGE: float = 20.0
const BITE_DAMAGE: float = 15.0
const FORGED_REQUEST_ID: int = 77
const MISSING_ITEM_ID: String = "item_999999"
## Needs do not move on their own during a test (the longest allowed climb).
const FROZEN_NEED_HOURS: float = 100000.0
## Keys of the only survival event another player may get about a wound.
const PUBLIC_WOUND_KEYS: Array = ["scope", "event_type", "player_id", "body_part", "wound_type", "died", "world_time"]

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
	# Wounds change only through hits and bandages: no healing, no respawn,
	# and so little bleeding damage that nobody dies during a test.
	_config.survival = SurvivalSettings.new()
	_config.survival.hunger_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.thirst_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.fatigue_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.wound_recovery_per_world_sec = 0.0
	_config.survival.stamina_regen_per_sec = 0.0
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

## The shipped item definitions plus a test bandage and a plain item.
func _new_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var bandage: ItemDefinition = ItemDefinition.new()
	bandage.definition_id = BANDAGE
	bandage.max_stack = STACK_MAX
	bandage.treat_bleeding_wound_count = 1
	catalog.add(bandage)
	var plain: ItemDefinition = ItemDefinition.new()
	plain.definition_id = PLAIN
	plain.max_stack = STACK_MAX
	catalog.add(plain)
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


## The client's survival mirror.
func _mirror(service: NetworkService) -> ClientSurvivalState:
	return (service.get_module(SurvivalNetModule.MODULE_NAME) as SurvivalNetModule).client_state


func _survival() -> SurvivalService:
	return _world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _spawn(definition_id: String, quantity: int = 1, position: Vector3 = ITEM_AT) -> String:
	return _world.inventory.spawn_world_item(definition_id, quantity, CELL, position)


## Wounds a player on the server and returns the wound id.
func _wound(player_id: String, type: Wound.Type, amount: float, part: BodyPart.Part = BodyPart.Part.TORSO) -> String:
	var hit: ActionResult = _survival().apply_damage(player_id, DamageInput.create("zombie_000001", part, type, amount))
	if not hit.ok:
		fail("test setup: damage failed: " + hit.reason)
		return ""
	return str((hit.event["wound"] as Dictionary)["wound_id"])


## Rows [request_id, ok, reason] of every consume result of `service`.
func _consume_results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).consume_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Rows [signal name, payload] of the module's mirror signals of `service`.
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


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


## The events of `events` that are about `player_id`.
func _events_about(events: Array[Dictionary], player_id: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("player_id", "")) == player_id:
			matching.append(event)
	return matching


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


## "" when the client's own wound list (ids and bleeding flags, in order)
## equals the server's, else what differs.
func _wounds_mismatch(client: NetworkService) -> String:
	var player_id: String = client.client_state.local_player_id
	var server_rows: Array = []
	for wound: Wound in _survival().get_vitals(player_id).injuries:
		server_rows.append([wound.wound_id, wound.is_bleeding])
	var mirror_rows: Array = []
	for wound: Dictionary in _mirror(client).wounds():
		mirror_rows.append([str(wound.get("wound_id", "")), bool(wound.get("is_bleeding", false))])
	return "" if server_rows == mirror_rows else "wounds: mirror %s, server %s" % [str(mirror_rows), str(server_rows)]


## Waits until the client's inventory and wound mirrors equal the server.
func _assert_owner_mirror_matches(client: NetworkService, label: String) -> void:
	var matched: bool = await _wait(func() -> bool: return _inventory_mismatch(client).is_empty() and _wounds_mismatch(client).is_empty())
	assert_true(matched, "%s: %s %s" % [label, _inventory_mismatch(client), _wounds_mismatch(client)])


func _mirror_wound(client: NetworkService, wound_id: String) -> Dictionary:
	for wound: Dictionary in _mirror(client).wounds():
		if str(wound.get("wound_id", "")) == wound_id:
			return wound
	return {}


# ------------------------------------------------------------ 1. bleed, bandage

func test_a_client_bandages_its_bleeding_and_only_the_owner_learns_it() -> void:
	assert_true(_start_server(), "server started")
	var bandage_id: String = _spawn(BANDAGE, 3)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var b_events: Array[Dictionary] = _survival_events_of(b)
	if not await _pick_up(a, [bandage_id]):
		return
	# Alice is hit twice: a deep cut (worst) and a bite. Both bleed.
	var cut_id: String = _wound(alice_id, Wound.Type.LACERATION, LACERATION_DAMAGE, BodyPart.Part.LEFT_ARM)
	var bite_id: String = _wound(alice_id, Wound.Type.BITE, BITE_DAMAGE, BodyPart.Part.RIGHT_LEG)
	await _assert_owner_mirror_matches(a, "after the hits")
	assert_true(bool(_mirror_wound(a, cut_id).get("is_bleeding", false)), "alice's mirror: the cut bleeds")
	assert_true(bool(_mirror_wound(a, bite_id).get("is_bleeding", false)), "alice's mirror: the bite bleeds")
	assert_true(await _wait(func() -> bool: return b_events.size() == 2), "bob saw the two hits")
	await _settle()
	# What bob knows about alice's wounds: the two observable hits, nothing else.
	assert_eq(b_events.size(), 2)
	for event: Dictionary in b_events:
		assert_eq(str(event.get("event_type", "")), SurvivalService.EVENT_PLAYER_WOUNDED)
		assert_eq(str(event.get("scope", "")), ClientSurvivalState.SCOPE_PUBLIC)
		var keys: Array = event.keys()
		keys.sort()
		var allowed: Array = PUBLIC_WOUND_KEYS.duplicate()
		allowed.sort()
		assert_eq(keys, allowed, "no bleeding flag, wound id, severity or health in a public hit")
	b_events.clear()
	var a_consumes: Array[Array] = _consume_results_of(a)
	var b_consumes: Array[Array] = _consume_results_of(b)
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var b_signals: Array[Array] = _mirror_signals_of(b)
	var b_owner_messages: int = _module(b).owner_message_count
	var b_wounds_before: Array[Dictionary] = _mirror(b).wounds()

	# Alice uses a bandage: an intent with a request id and the item id only.
	var first_request: int = _module(a).request_consume(bandage_id)
	assert_true(first_request > 0, "a joined client gets a request id")
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 1), "alice got her answer")
	assert_eq(a_consumes, [[first_request, true, ""]])
	assert_eq(_world.inventory.get_item(bandage_id).quantity, 2, "server: one bandage left the stack")
	assert_eq(Array(_survival().bleeding_wound_ids(alice_id)), [bite_id], "server: the worst wound (the cut) was treated")
	await _assert_owner_mirror_matches(a, "after the first bandage")
	assert_false(bool(_mirror_wound(a, cut_id).get("is_bleeding", true)), "alice's mirror: the cut no longer bleeds")
	assert_true(bool(_mirror_wound(a, bite_id).get("is_bleeding", false)), "alice's mirror: the bite still bleeds")
	assert_eq(a.client_state.get_inventory_item(bandage_id).get("quantity", 0), 2, "alice's mirror: the smaller stack")

	# The second bandage treats the bite; a third is refused and kept.
	var second_request: int = _module(a).request_consume(bandage_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 2), "alice got her second answer")
	assert_eq(a_consumes[1], [second_request, true, ""])
	assert_eq(_survival().bleeding_wound_ids(alice_id).size(), 0, "server: nothing bleeds any more")
	await _assert_owner_mirror_matches(a, "after the second bandage")
	var third_request: int = _module(a).request_consume(bandage_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 3), "alice got her third answer")
	assert_eq(a_consumes[2], [third_request, false, SurvivalService.REASON_NOT_BLEEDING], "nothing bleeds: refused")
	assert_eq(_world.inventory.get_item(bandage_id).quantity, 1, "server: the last bandage was not used up")
	await _settle()
	await _assert_owner_mirror_matches(a, "after the refused bandage")
	assert_eq(a.client_state.get_inventory_item(bandage_id).get("quantity", 0), 1)
	assert_eq(_mirror(a).wounds().size(), 2, "alice still has both wounds, treated")
	assert_eq(_cluster.server.rejected_intent_count(SurvivalService.REASON_NOT_BLEEDING), 1)
	assert_eq(_cluster.server.rejected_intent_count(), 1)

	assert_eq(a_signals, [["inventory_item_changed", bandage_id], ["inventory_item_changed", bandage_id]], "the owner: a smaller stack, twice")
	# Nobody else is told: no result, no inventory message, no survival event,
	# no wound of alice's in bob's mirror.
	assert_eq(b_consumes.size(), 0, "the result goes to the requester only")
	assert_eq(b_signals.size(), 0, "bob's mirrors did not change")
	assert_eq(_module(b).owner_message_count, b_owner_messages, "bob never received an owner-only message")
	assert_eq(b_events.size(), 0, "bob received no survival event about the bandage: %s" % str(b_events))
	assert_eq(_mirror(b).wounds(), b_wounds_before, "bob's mirror holds his own wounds only")
	assert_eq(_mirror(b).wounds().size(), 0)
	assert_eq(_survival().get_vitals(bob_id).injuries.size(), 0, "server: bob was not touched")
	assert_eq(b.client_state.inventory.size(), 0)
	assert_eq(_module(a).rejected_payload_count + _module(b).rejected_payload_count, 0, "the server's own messages pass the client validation")


# ------------------------------------------------------------ 2. manipulated requests

func test_manipulated_bandage_requests_are_rejected_and_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var mine: String = _spawn(BANDAGE, 2)
	var plain: String = _spawn(PLAIN)
	var bobs: String = _spawn(BANDAGE, 1, OTHER_ITEM_AT)
	var lying: String = _spawn(BANDAGE, 3, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [mine, plain]):
		return
	if not await _pick_up(b, [bobs]):
		return
	# Both bleed. Alice may only treat herself, with her own bandage.
	var alice_wound: String = _wound(alice_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var bob_wound: String = _wound(bob_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	await _assert_owner_mirror_matches(a, "start")
	await _assert_owner_mirror_matches(b, "start (bob)")
	var a_consumes: Array[Array] = _consume_results_of(a)
	var b_consumes: Array[Array] = _consume_results_of(b)
	var b_signals: Array[Array] = _mirror_signals_of(b)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var before: Dictionary = _world.inventory.to_snapshot()
	var server: NetworkService = _cluster.server
	var module: InventoryNetModule = _module(a)
	var long_id: String = "x".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1)

	# Wrong ownership / unknown ids: answered, and nothing tells the requester
	# whether the id exists somewhere else.
	module.send_raw_consume_request(1, bobs)
	module.send_raw_consume_request(2, MISSING_ITEM_ID)
	module.send_raw_consume_request(3, lying)
	# Her own item, but not something to use.
	module.send_raw_consume_request(4, plain)
	# A wound id (hers or bob's) is not an item: a request cannot name a wound.
	module.send_raw_consume_request(5, alice_wound)
	module.send_raw_consume_request(6, bob_wound)
	# Malformed arguments.
	module.send_raw_consume_request("x", mine)
	module.send_raw_consume_request(7, 12345)
	module.send_raw_consume_request(8, "")
	module.send_raw_consume_request(9, long_id)
	module.send_raw_consume_request(-1, mine)
	module.send_raw_consume_request(10.0, mine)
	module.send_raw_consume_request(11, null)
	const EXPECTED_REJECTIONS: int = 13
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == EXPECTED_REJECTIONS), "every manipulated request was rejected (%d)" % server.rejected_intent_count())
	# A request cannot name another player or a wound to treat: the handler
	# takes two arguments and the engine refuses a call with more (reported
	# as an engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_consume.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, mine, bob_id)
	module._rpc_request_consume.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, mine, bob_wound)
	await _settle()
	Engine.print_error_messages = true

	assert_eq(a_consumes, [
		[1, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[2, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[3, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[4, false, ItemConsumption.REASON_NOT_CONSUMABLE],
		[5, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[6, false, InventoryService.REASON_NOT_IN_INVENTORY],
		[7, false, IntentValidator.REASON_BAD_TYPE],
		[8, false, IntentValidator.REASON_BAD_ITEM_ID],
		[9, false, IntentValidator.REASON_BAD_ITEM_ID],
		[11, false, IntentValidator.REASON_BAD_TYPE],
	], "answers go to usable request ids only, in order")
	assert_eq(server.rejected_intent_count(), EXPECTED_REJECTIONS, "the calls the engine refused never reached the handler")
	assert_eq(_world.inventory.to_snapshot(), before, "server items are unchanged")
	assert_eq(Array(_survival().bleeding_wound_ids(alice_id)), [alice_wound], "alice still bleeds")
	assert_eq(Array(_survival().bleeding_wound_ids(bob_id)), [bob_wound], "nobody treated bob")
	assert_eq(b_consumes.size() + b_signals.size(), 0, "bob was told nothing")
	assert_eq(_events_about(b_events, alice_id).size(), 0, "bob received no survival event about alice")
	assert_eq(b.client_state.get_inventory_item(bobs).get("quantity", 0), 1, "bob still carries his bandage")

	# The path itself works: a clean request from the same peer is accepted
	# and treats the requester, never somebody else.
	var request_id: int = module.request_consume(mine)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 11), "a valid request still goes through")
	assert_eq(a_consumes[10], [request_id, true, ""])
	assert_eq(_survival().bleeding_wound_ids(alice_id).size(), 0)
	assert_eq(Array(_survival().bleeding_wound_ids(bob_id)), [bob_wound], "bob still bleeds")
	await _assert_owner_mirror_matches(a, "after the valid request")
	await _settle()
	assert_eq(_events_about(b_events, alice_id).size(), 0, "bob learned nothing about alice's treatment")
	for event: Dictionary in b_events:
		assert_eq(str(event.get("scope", "")), ClientSurvivalState.SCOPE_OWNER, "bob only gets events about his own body")


func test_a_dead_player_cannot_use_a_bandage() -> void:
	assert_true(_start_server(), "server started")
	var bandage_id: String = _spawn(BANDAGE, 2)
	var clients: Array[NetworkService] = await _join_two()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var alice_id: String = a.client_state.local_player_id
	if not await _pick_up(a, [bandage_id]):
		return
	_wound(alice_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var a_consumes: Array[Array] = _consume_results_of(a)
	assert_true(_survival().apply_damage(alice_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok, "test setup: kill alice")
	assert_false(_survival().is_alive(alice_id))
	# The death put her bandages down where she died (P2-T4).
	assert_true(await _wait(func() -> bool: return a.client_state.world_items.has(bandage_id) and a.client_state.inventory.is_empty()), "the death's drop reached alice")
	var a_signals: Array[Array] = _mirror_signals_of(a)
	var before: Dictionary = _world.inventory.to_snapshot()
	var request_id: int = _module(a).request_consume(bandage_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 1), "dead alice got an answer")
	await _settle()
	assert_eq(a_consumes, [[request_id, false, SurvivalService.REASON_PLAYER_DEAD]])
	assert_eq(_cluster.server.rejected_intent_count(SurvivalService.REASON_PLAYER_DEAD), 1, "rejection counter")
	assert_eq(_world.inventory.to_snapshot(), before, "the bandage is not used up")
	assert_eq(_survival().bleeding_wound_ids(alice_id).size(), 0, "a dead character has no treatable wound")
	assert_true(_survival().get_vitals(alice_id).injuries[0].is_bleeding, "the dead character's wound was not treated")
	assert_eq(a_signals.size(), 0)


# ------------------------------------------------------------ 3. saving

func test_a_bandage_use_survives_a_server_restart() -> void:
	_save_root = "user://test_saves/bandage_net_%d" % Time.get_ticks_usec()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence.load_or_create(WORLD)
	assert_not_null(_world)
	if _world == null:
		return
	var bandage_id: String = _spawn(BANDAGE, 3)
	assert_eq(_cluster.start_server(_world, persistence), OK)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	if not await _pick_up(a, [bandage_id]):
		return
	var cut_id: String = _wound(alice_id, Wound.Type.LACERATION, LACERATION_DAMAGE)
	var bite_id: String = _wound(alice_id, Wound.Type.BITE, BITE_DAMAGE)
	var save: SaveService = SaveService.new(_save_root)
	var a_consumes: Array[Array] = _consume_results_of(a)

	# Like eating, a bandage use is not saved on its own (docs/15 P2-123).
	var generation: int = save.current_generation(WORLD)
	_module(a).request_consume(bandage_id)
	assert_true(await _wait(func() -> bool: return a_consumes.size() == 1), "alice used a bandage")
	assert_eq(a_consumes[0].slice(1), [true, ""])
	await _settle()
	assert_eq(save.current_generation(WORLD), generation, "a bandage use alone does not write the world")
	# What a crash right now would bring back: the last save, in which the
	# bandage is still in the stack (never one half without the other).
	var on_disk: ServerWorld = WorldPersistence.new(SaveService.new(_save_root), _config).load_or_create(WORLD)
	assert_not_null(on_disk)
	if on_disk == null:
		return
	assert_eq(on_disk.inventory.get_item(bandage_id).quantity, 3, "on disk: the stack before the use")

	# --- full restart (the shutdown saves): state comes only from disk ---
	await _cluster.shutdown()
	_cluster = null
	_world = null
	var persistence2: WorldPersistence = WorldPersistence.new(SaveService.new(_save_root), _config)
	_world = persistence2.load_or_create(WORLD)
	assert_not_null(_world, "world restored from save")
	if _world == null:
		return
	assert_eq(_world.inventory.get_item(bandage_id).quantity, 2, "one bandage was used")
	assert_eq(Array(_survival().bleeding_wound_ids(alice_id)), [bite_id], "the cut stays treated, the bite still bleeds")
	_cluster = NetTestCluster.new(tree, _net_settings, _config)
	assert_eq(_cluster.start_server(_world, persistence2), OK)
	var a2: NetworkService = await _cluster.join_client("alice")
	if a2 == null:
		fail("alice did not rejoin")
		return
	assert_eq(a2.client_state.local_player_id, alice_id, "alice is the same player")
	await _assert_owner_mirror_matches(a2, "session 2")
	assert_false(bool(_mirror_wound(a2, cut_id).get("is_bleeding", true)), "session 2 mirror: the cut is treated")
	assert_true(bool(_mirror_wound(a2, bite_id).get("is_bleeding", false)), "session 2 mirror: the bite bleeds")
	var a2_consumes: Array[Array] = _consume_results_of(a2)
	_module(a2).request_consume(bandage_id)
	assert_true(await _wait(func() -> bool: return a2_consumes.size() == 1), "alice used another bandage")
	assert_eq(a2_consumes[0].slice(1), [true, ""])
	assert_eq(_survival().bleeding_wound_ids(alice_id).size(), 0)
	await _assert_owner_mirror_matches(a2, "session 2 after the bandage")
	assert_eq(a2.client_state.get_inventory_item(bandage_id).get("quantity", 0), 1)
