extends TestCase
## P2-T12: using a bandage or a cure on another player over real ENet
## (server + 3 clients). A client names an item it carries and a target
## player; the server decides everything else from its own state. The user
## learns the result, the target its own treatment and who gave it, and a
## bystander only that one player tended to another (docs/00 ADR-009,
## ADR-018). Rules: tests/unit/treat_other_test.gd.

const WORLD: String = "treat_other_net_test_world"
const NEVER: float = 1.0e9
const BANDAGE: String = "t12n_bandage"
const CURE: String = "t12n_cure"
const FOOD: String = "t12n_food"
const WATER: String = "t13n_water"
const FOOD_HUNGER: float = 30.0
const WATER_THIRST: float = 50.0
const NEED_TOLERANCE: float = 0.01
const STACK_MAX: int = 5
const CELL: String = DevWorldSeed.DEV_CELL_ID
## Players spawn at the origin; these positions are within pickup range.
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const OTHER_ITEM_AT: Vector3 = Vector3(-0.5, 0.0, 1.0)
const THIRD_ITEM_AT: Vector3 = Vector3(0.5, 0.0, -1.0)
const FAR_AWAY: Vector3 = Vector3(60.0, 0.0, 0.0)
const WAIT_MSEC: int = 6000
## Server ticks waited before asserting that nothing more arrived.
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 60.0
const GENEROUS_BURST: int = 60
const LETHAL_DAMAGE: float = 100000.0
const LACERATION_DAMAGE: float = 20.0
const FORGED_REQUEST_ID: int = 77
const MISSING_PLAYER_ID: String = "player_999999"
## Needs that must not move on their own during a test.
const FROZEN_NEED_HOURS: float = 100000.0
## Words that must not appear in anything a bystander receives.
const PRIVATE_WORDS: PackedStringArray = ["wound", "bleed", "infect", "health", "stage", "latent", "early", "reason", "definition", "bandage", "cure", "ok"]

var _cluster: NetTestCluster = null
var _net_settings: NetworkSettings = null
var _inventory_net: InventoryNetSettings = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
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
	# Wounds and infections change only through hits and treatments.
	_config.survival = SurvivalSettings.new()
	_config.survival.hunger_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.thirst_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.fatigue_hours_to_max = FROZEN_NEED_HOURS
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.wound_recovery_per_world_sec = 0.0
	_config.survival.bleeding_health_loss_per_severity_per_world_sec = 0.0
	_config.survival.stamina_regen_per_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.survival.infection_chance_bite = 1.0
	# Infection stages do not advance during a test.
	_config.survival.infection_latent_hours = FROZEN_NEED_HOURS
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
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

## The shipped item definitions plus a test bandage, cure and food.
func _new_catalog() -> ItemCatalog:
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var bandage: ItemDefinition = ItemDefinition.new()
	bandage.definition_id = BANDAGE
	bandage.max_stack = STACK_MAX
	bandage.treat_bleeding_wound_count = 1
	catalog.add(bandage)
	var cure: ItemDefinition = ItemDefinition.new()
	cure.definition_id = CURE
	cure.max_stack = STACK_MAX
	cure.cures_infection = true
	catalog.add(cure)
	var food: ItemDefinition = ItemDefinition.new()
	food.definition_id = FOOD
	food.max_stack = STACK_MAX
	food.consume_hunger_reduction = FOOD_HUNGER
	catalog.add(food)
	var water: ItemDefinition = ItemDefinition.new()
	water.definition_id = WATER
	water.max_stack = STACK_MAX
	water.consume_thirst_reduction = WATER_THIRST
	catalog.add(water)
	return catalog


func _first_untreatable_stage() -> InfectionState.Stage:
	return (_config.survival.infection_treatment_max_stage + 1) as InfectionState.Stage


func _start_server() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null:
		return false
	_world.seed_new_world(_config.dev_seed)
	return _cluster.start_server(_world, null) == OK


## Joins "alice", "bob" and "carol" (after the test placed its items).
func _join_three() -> Array[NetworkService]:
	var joined: Array[NetworkService] = []
	for key: String in ["alice", "bob", "carol"]:
		var client: NetworkService = await _cluster.join_client(key)
		if client == null:
			fail("%s did not join" % key)
			return []
		joined.append(client)
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


## Wounds a player on the server with a bleeding laceration; the wound id.
func _wound(player_id: String, amount: float = LACERATION_DAMAGE) -> String:
	var hit: ActionResult = _survival().apply_damage(player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.LACERATION, amount))
	if not hit.ok:
		fail("test setup: damage failed: " + hit.reason)
		return ""
	return str((hit.event["wound"] as Dictionary)["wound_id"])


func _infect(player_id: String, stage: InfectionState.Stage = InfectionState.Stage.LATENT) -> void:
	var result: ActionResult = _survival().apply_infection_exposure(player_id, InfectionState.Exposure.BITE, "zombie_000001")
	if not result.ok or str(result.event.get("event_type", "")) != SurvivalService.EVENT_PLAYER_INFECTED:
		fail("test setup: infection failed")
	_survival().get_vitals(player_id).infection.stage = stage


## Rows [request_id, ok, reason] of every use-on result of `service`.
func _use_on_results_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	_module(service).use_on_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	return rows


## Every treatment notice `service` receives from now on.
func _notices_of(service: NetworkService) -> Array[Dictionary]:
	var notices: Array[Dictionary] = []
	_module(service).treatment_seen.connect(func(notice: Dictionary) -> void: notices.append(notice))
	return notices


## Every survival event `service` receives from now on.
func _survival_events_of(service: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_mirror(service).event_received.connect(func(event: Dictionary) -> void: events.append(event))
	return events


## Rows [signal name, payload] of the inventory mirror signals of `service`.
func _inventory_signals_of(service: NetworkService) -> Array[Array]:
	var rows: Array[Array] = []
	var module: InventoryNetModule = _module(service)
	module.inventory_items_removed.connect(func(ids: PackedStringArray) -> void: rows.append(["inventory_items_removed", Array(ids)]))
	module.inventory_item_changed.connect(func(item_id: String) -> void: rows.append(["inventory_item_changed", item_id]))
	return rows


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
	for item_id: String in item_ids:
		client.request_pickup(item_id)
	var has_all: Callable = func() -> bool:
		for item_id: String in item_ids:
			if not client.client_state.has_inventory_item(item_id):
				return false
		return true
	var done: bool = await _wait(has_all)
	if not done:
		fail("test setup: pickup of %s failed" % str(item_ids))
	return done


## Sends one use-on request and waits for its answer: [ok, reason].
func _use_on(client: NetworkService, item_id: String, target_id: String) -> Array:
	var rows: Array[Array] = _use_on_results_of(client)
	var request_id: int = _module(client).request_use_on(item_id, target_id)
	if request_id == InventoryNetModule.NO_REQUEST:
		fail("the use-on request was not sent")
		return [false, "not_sent"]
	var answered: bool = await _wait(func() -> bool: return rows.size() >= 1)
	if not answered:
		fail("the use-on request was not answered")
		return [false, "no_answer"]
	if int(rows[0][0]) != request_id:
		fail("the answer carries another request id: %s" % str(rows[0]))
	return [rows[0][1], rows[0][2]]


## Units of `item_id` in the client's inventory mirror (0 = not there).
func _mirror_quantity(client: NetworkService, item_id: String) -> int:
	return int(client.client_state.get_inventory_item(item_id).get("quantity", 0)) if client.client_state.has_inventory_item(item_id) else 0


func _server_quantity(item_id: String) -> int:
	var item: ItemInstance = _world.inventory.get_item(item_id)
	return 0 if item == null else item.quantity


## [wound id, is bleeding] rows of the client's own wound mirror.
func _mirror_wound_rows(client: NetworkService) -> Array:
	var rows: Array = []
	for wound: Dictionary in _mirror(client).wounds():
		rows.append([str(wound.get("wound_id", "")), bool(wound.get("is_bleeding", false))])
	return rows


func _server_wound_rows(player_id: String) -> Array:
	var rows: Array = []
	for wound: Wound in _survival().get_vitals(player_id).injuries:
		rows.append([wound.wound_id, wound.is_bleeding])
	return rows


## Asserts that a bystander's notice says only who tended to whom.
func _assert_public_notice(notice: Dictionary, user_id: String, target_id: String, label: String) -> void:
	var keys: Array = notice.keys()
	keys.sort()
	assert_eq(keys, ["scope", "target_id", "user_id", "world_time"], label + ": a public notice carries nothing else")
	assert_eq(notice.get("scope", ""), InventoryNetModule.NOTICE_SCOPE_PUBLIC, label)
	assert_eq(notice.get("user_id", ""), user_id, label)
	assert_eq(notice.get("target_id", ""), target_id, label)
	var text: String = JSON.stringify(notice).to_lower().replace(user_id, "").replace(target_id, "")
	for word: String in PRIVATE_WORDS:
		assert_not_contains(text, word, label + ": a bystander was told something private")


# ------------------------------------------------------------ 1. bandage

func test_a_client_bandages_another_player() -> void:
	assert_true(_start_server(), "server started")
	var bandages: String = _spawn(BANDAGE, 3)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [bandages]):
		return
	var light: String = _wound(bob_id, 15.0)
	var heavy: String = _wound(bob_id, 40.0)
	assert_true(await _wait(func() -> bool: return _mirror_wound_rows(b) == _server_wound_rows(bob_id)), "bob's mirror has his wounds")
	await _settle()
	var a_notices: Array[Dictionary] = _notices_of(a)
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var b_events: Array[Dictionary] = _survival_events_of(b)
	var c_events: Array[Dictionary] = _survival_events_of(c)
	var b_inventory: Array[Array] = _inventory_signals_of(b)
	var c_inventory: Array[Array] = _inventory_signals_of(c)
	var b_results: Array[Array] = _use_on_results_of(b)
	var c_results: Array[Array] = _use_on_results_of(c)

	# Alice bandages bob: the item id and the target, nothing else.
	assert_eq(await _use_on(a, bandages, bob_id), [true, ""])
	assert_eq(_survival().bleeding_wound_ids(bob_id), PackedStringArray([light]), "server: bob's worst wound stopped bleeding")
	assert_eq(_server_quantity(bandages), 2, "server: one bandage left alice's stack")
	# Bob's mirror follows his wounds; alice's mirror her inventory.
	assert_true(await _wait(func() -> bool: return _mirror_wound_rows(b) == _server_wound_rows(bob_id)), "bob's mirror: %s vs server %s" % [str(_mirror_wound_rows(b)), str(_server_wound_rows(bob_id))])
	assert_eq(_mirror_wound_rows(b), [[light, true], [heavy, false]])
	assert_true(await _wait(func() -> bool: return _mirror_quantity(a, bandages) == 2), "alice's mirror: two bandages left (%d)" % _mirror_quantity(a, bandages))
	await _settle()

	# Alice: the result only. No notice, no survival event about bob.
	assert_eq(a_notices.size(), 0, "the user gets the result, not a notice: %s" % str(a_notices))
	assert_eq(a_events.size(), 0, "alice was told nothing about bob's wounds: %s" % str(a_events))
	assert_eq(_mirror(a).wounds().size(), 0, "alice's wound mirror is about herself")
	# Bob: who used what on him, and his own wound event.
	assert_eq(b_notices.size(), 1, str(b_notices))
	assert_eq(b_notices[0].get("scope", ""), InventoryNetModule.NOTICE_SCOPE_TARGET)
	assert_eq(b_notices[0].get("user_id", ""), alice_id, "bob knows who treated him")
	assert_eq(b_notices[0].get("target_id", ""), bob_id)
	assert_eq(b_notices[0].get("definition_id", ""), BANDAGE, "and with what")
	assert_eq(b_notices[0].get("ok", false), true)
	assert_eq(b_events.size(), 1, str(b_events))
	assert_eq(b_events[0].get("event_type", ""), SurvivalService.EVENT_PLAYER_BLEEDING_STOPPED)
	assert_eq(b_events[0].get("scope", ""), ClientSurvivalState.SCOPE_OWNER)
	assert_eq(b_events[0].get("wound_id", ""), heavy)
	assert_eq(b_inventory.size(), 0, "bob's inventory did not change")
	# Carol: that alice tended to bob. Nothing about wounds or the item.
	assert_eq(c_notices.size(), 1, str(c_notices))
	_assert_public_notice(c_notices[0], alice_id, bob_id, "carol")
	assert_eq(c_events.size(), 0, "carol got no survival event: %s" % str(c_events))
	assert_eq(c_inventory.size(), 0)
	assert_eq(b_results.size() + c_results.size(), 0, "the result goes to the requester only")

	# The second bandage stops the other wound; the third finds nothing to
	# treat: refused, kept, and bob and carol see the attempt all the same.
	assert_eq(await _use_on(a, bandages, bob_id), [true, ""])
	assert_eq(_survival().bleeding_wound_ids(bob_id).size(), 0)
	b_notices.clear()
	c_notices.clear()
	assert_eq(await _use_on(a, bandages, bob_id), [false, SurvivalService.REASON_NOT_BLEEDING], "alice learns that bob does not bleed")
	assert_eq(_server_quantity(bandages), 1, "server: the bandage is kept")
	await _settle()
	assert_eq(_mirror_quantity(a, bandages), 1)
	assert_eq(b_notices.size(), 1)
	assert_eq(b_notices[0].get("ok", true), false)
	assert_eq(b_notices[0].get("reason", ""), SurvivalService.REASON_NOT_BLEEDING, "bob is told the attempt did nothing")
	assert_eq(c_notices.size(), 1, "carol sees the attempt")
	_assert_public_notice(c_notices[0], alice_id, bob_id, "carol, refused attempt")
	assert_eq(c_events.size(), 0)
	assert_eq(_cluster.server.rejected_intent_count(), 1, "only the refused attempt was counted")


# ------------------------------------------------------------ 2. cure

func test_a_client_cures_another_player_and_learns_only_the_result() -> void:
	assert_true(_start_server(), "server started")
	var cures: String = _spawn(CURE, 3)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [cures]):
		return
	await _settle()
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var c_events: Array[Dictionary] = _survival_events_of(c)
	var c_mirror_changes: Array[int] = []
	_mirror(c).own_vitals_changed.connect(func() -> void: c_mirror_changes.append(1))

	# Bob is not infected: refused, the cure is kept. Alice now knows that.
	assert_eq(await _use_on(a, cures, bob_id), [false, SurvivalService.REASON_NOT_INFECTED])
	assert_eq(_server_quantity(cures), 3, "server: the cure is kept")
	assert_eq(_survival().infection_stage(bob_id), InfectionState.Stage.NONE)
	# Bob is infected (he knows; nobody else does).
	_infect(bob_id)
	assert_true(await _wait(func() -> bool: return _mirror(b).infection_stage() == "latent"), "bob's mirror: infected")
	await _settle()
	assert_eq(_mirror(a).infection_stage(), "none", "alice's mirror is about herself")
	b_notices.clear()
	c_notices.clear()

	# Alice cures bob.
	assert_eq(await _use_on(a, cures, bob_id), [true, ""])
	assert_eq(_survival().infection_stage(bob_id), InfectionState.Stage.NONE, "server: bob is cured")
	assert_eq(_server_quantity(cures), 2)
	assert_true(await _wait(func() -> bool: return _mirror(b).infection_stage() == "none"), "bob's mirror: cured")
	assert_true(await _wait(func() -> bool: return _mirror_quantity(a, cures) == 2), "alice's mirror: two cures left")
	await _settle()
	assert_eq(b_notices.size(), 1, str(b_notices))
	assert_eq(b_notices[0].get("user_id", ""), alice_id)
	assert_eq(b_notices[0].get("definition_id", ""), CURE)
	assert_eq(b_notices[0].get("ok", false), true)
	assert_eq(c_notices.size(), 1, str(c_notices))
	_assert_public_notice(c_notices[0], alice_id, bob_id, "carol")
	# Too late: refused and kept.
	_infect(bob_id, _first_untreatable_stage())
	assert_eq(await _use_on(a, cures, bob_id), [false, SurvivalService.REASON_TOO_LATE])
	assert_eq(_server_quantity(cures), 2)
	await _settle()

	# Nobody but bob ever received anything about his infection: alice only
	# the three results, carol only that alice tended to bob.
	assert_eq(a_events.size(), 0, "alice got no survival event: %s" % str(a_events))
	assert_eq(c_events.size(), 0, "carol got no survival event: %s" % str(c_events))
	assert_eq(c_mirror_changes.size(), 0, "carol's vitals mirror never changed")
	assert_eq(_mirror(a).infection_stage(), "none")
	assert_eq(_mirror(c).infection_stage(), "none")
	for notice: Dictionary in c_notices:
		_assert_public_notice(notice, alice_id, bob_id, "carol")
	assert_eq(c_notices.size(), 2, "the cure and the attempt that came too late look the same to carol")
	# A use on oneself through the same request is the usual use: no notice.
	_infect(alice_id)
	b_notices.clear()
	c_notices.clear()
	assert_eq(await _use_on(a, cures, ""), [true, ""])
	assert_eq(_survival().infection_stage(alice_id), InfectionState.Stage.NONE, "server: alice cured herself")
	assert_eq(await _use_on(a, cures, alice_id), [false, SurvivalService.REASON_NOT_INFECTED])
	await _settle()
	assert_eq(b_notices.size() + c_notices.size(), 0, "a self-use is told to nobody")
	assert_eq(_server_quantity(cures), 1)


# ------------------------------------------------------------ 3. who can be treated

func test_targets_that_cannot_be_treated_are_refused_and_the_item_is_kept() -> void:
	# This server does not let players feed each other (the default does:
	# P2-T13, see the feeding test below).
	_config.gameplay.allow_feeding_others = false
	assert_true(_start_server(), "server started")
	var bandages: String = _spawn(BANDAGE, 3)
	var food: String = _spawn(FOOD, 2, OTHER_ITEM_AT)
	var bobs: String = _spawn(BANDAGE, 1, THIRD_ITEM_AT)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var bob_id: String = b.client_state.local_player_id
	var carol_id: String = c.client_state.local_player_id
	if not await _pick_up(a, [bandages, food]):
		return
	if not await _pick_up(b, [bobs]):
		return
	_wound(bob_id)
	_wound(carol_id)
	await _settle()
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var before: Dictionary = _world.inventory.to_snapshot()
	var server: NetworkService = _cluster.server

	# Not hers to use, nothing for others, nobody there.
	assert_eq(await _use_on(a, bobs, bob_id), [false, InventoryService.REASON_NOT_IN_INVENTORY], "bob's own bandage")
	assert_eq(await _use_on(a, "item_999999", bob_id), [false, InventoryService.REASON_NOT_IN_INVENTORY], "an id that does not exist looks the same")
	assert_eq(await _use_on(a, food, bob_id), [false, ItemConsumption.REASON_NOT_USABLE_ON_OTHERS], "food is not given to others when the setting is off")
	assert_eq(await _use_on(a, bandages, MISSING_PLAYER_ID), [false, ItemConsumption.REASON_TARGET_UNAVAILABLE], "no such player")
	# Too far: the server's positions decide, whatever the client believes.
	_world.get_player(bob_id).position = FAR_AWAY
	assert_eq(await _use_on(a, bandages, bob_id), [false, ItemConsumption.REASON_TARGET_TOO_FAR])
	_world.get_player(bob_id).position = Vector3.ZERO
	# Dead.
	assert_true(_survival().apply_damage(carol_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(await _use_on(a, bandages, carol_id), [false, ItemConsumption.REASON_TARGET_DEAD])
	# Gone: carol leaves. Her id answers like an unknown one.
	_cluster.remove_client(c)
	assert_true(await _wait(func() -> bool: return not _world.is_online(carol_id)), "carol left")
	assert_eq(await _use_on(a, bandages, carol_id), [false, ItemConsumption.REASON_TARGET_UNAVAILABLE], "an offline player")
	await _settle()
	assert_eq(_world.inventory.to_snapshot(), before, "no refused request changed an item")
	assert_eq(_survival().bleeding_wound_ids(bob_id).size(), 1, "bob still bleeds")
	assert_eq(b_notices.size() + c_notices.size(), 0, "none of these was an attempt anybody saw")
	assert_eq(server.rejected_intent_count(), 7, "every refusal was counted")
	# The dead cannot treat either.
	_wound(a.client_state.local_player_id)
	assert_true(_survival().apply_damage(bob_id, DamageInput.create("test", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok)
	assert_eq(await _use_on(b, bobs, a.client_state.local_player_id), [false, SurvivalService.REASON_PLAYER_DEAD], "a dead player treats nobody")


# ------------------------------------------------------------ 3b. food and drink (P2-T13)

## P2-T13 (user decision 2026-11-15, docs/00 ADR-019): with the default
## settings a client gives food and water to another player. The unit leaves
## the giver's inventory, the receiver's hunger / thirst drops, the receiver
## is told who gave what and a bystander only that one tended to the other.
func test_a_client_gives_food_and_water_to_another_player() -> void:
	assert_true(_config.gameplay.allow_feeding_others, "the default lets players feed each other")
	assert_true(_start_server(), "server started")
	var food: String = _spawn(FOOD, 3)
	var water: String = _spawn(WATER, 1, OTHER_ITEM_AT)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [food, water]):
		return
	# Bob is hungry (caution) and very thirsty (danger); alice is hungry too.
	_survival().get_vitals(bob_id).hunger = 60.0
	_survival().get_vitals(bob_id).thirst = 80.0
	_survival().get_vitals(alice_id).hunger = 60.0
	assert_true(await _wait(func() -> bool: return _mirror(b).need_category("hunger") == "caution" and _mirror(b).need_category("thirst") == "danger"), "bob's mirror shows his needs")
	assert_true(await _wait(func() -> bool: return _mirror(a).need_category("hunger") == "caution"), "alice's mirror shows hers")
	await _settle()
	var a_notices: Array[Dictionary] = _notices_of(a)
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var a_events: Array[Dictionary] = _survival_events_of(a)
	var c_events: Array[Dictionary] = _survival_events_of(c)
	var b_inventory: Array[Array] = _inventory_signals_of(b)
	var c_inventory: Array[Array] = _inventory_signals_of(c)
	var b_results: Array[Array] = _use_on_results_of(b)
	var c_results: Array[Array] = _use_on_results_of(c)

	# Alice gives bob food: the item id and the receiver, nothing else.
	assert_eq(await _use_on(a, food, bob_id), [true, ""])
	assert_true(absf(_survival().get_vitals(bob_id).hunger - (60.0 - FOOD_HUNGER)) <= NEED_TOLERANCE, "server: bob was fed (%f)" % _survival().get_vitals(bob_id).hunger)
	assert_true(absf(_survival().get_vitals(alice_id).hunger - 60.0) <= NEED_TOLERANCE, "server: alice is as hungry as before")
	assert_eq(_server_quantity(food), 2, "server: one unit left alice's stack")
	assert_eq(_world.inventory.items_in_inventory(_world.get_player(bob_id).inventory_id).size(), 0, "server: nothing entered bob's inventory")
	assert_true(await _wait(func() -> bool: return _mirror(b).need_category("hunger") == "good"), "bob's mirror: no longer hungry")
	assert_true(await _wait(func() -> bool: return _mirror_quantity(a, food) == 2), "alice's mirror: two units left")
	assert_eq(_mirror(a).need_category("hunger"), "caution", "alice's mirror is about herself")

	# And her only bottle of water: the item is gone.
	assert_eq(await _use_on(a, water, bob_id), [true, ""])
	assert_true(absf(_survival().get_vitals(bob_id).thirst - (80.0 - WATER_THIRST)) <= NEED_TOLERANCE, "server: bob drank (%f)" % _survival().get_vitals(bob_id).thirst)
	assert_eq(_server_quantity(water), 0, "server: the bottle is used up")
	assert_true(await _wait(func() -> bool: return _mirror(b).need_category("thirst") == "good"), "bob's mirror: no longer thirsty")
	assert_true(await _wait(func() -> bool: return _mirror_quantity(a, water) == 0), "alice's mirror: the bottle is gone")
	await _settle()

	# Alice: the two results. No notice and nothing about bob's needs.
	assert_eq(a_notices.size(), 0, "the giver gets the result, not a notice: %s" % str(a_notices))
	assert_eq(a_events.size(), 0, "alice was told nothing about bob: %s" % str(a_events))
	# Bob: who gave him what.
	assert_eq(b_notices.size(), 2, str(b_notices))
	for notice: Dictionary in b_notices:
		assert_eq(notice.get("scope", ""), InventoryNetModule.NOTICE_SCOPE_TARGET)
		assert_eq(notice.get("user_id", ""), alice_id, "bob knows who fed him")
		assert_eq(notice.get("target_id", ""), bob_id)
		assert_eq(notice.get("ok", false), true)
	assert_eq(b_notices[0].get("definition_id", ""), FOOD)
	assert_eq(b_notices[1].get("definition_id", ""), WATER)
	assert_eq(b_inventory.size(), 0, "bob's inventory did not change")
	# Carol: that alice tended to bob, twice. Not what was given, nothing
	# about bob's needs.
	assert_eq(c_notices.size(), 2, str(c_notices))
	for notice: Dictionary in c_notices:
		_assert_public_notice(notice, alice_id, bob_id, "carol")
		assert_not_contains(JSON.stringify(notice).to_lower(), "food", "carol is not told what was given")
		assert_not_contains(JSON.stringify(notice).to_lower(), "water", "carol is not told what was given")
	assert_eq(c_events.size(), 0, "carol got no survival event: %s" % str(c_events))
	assert_eq(c_inventory.size(), 0)
	assert_eq(_mirror(c).need_category("hunger"), "good", "carol's mirror is about herself")
	assert_eq(b_results.size() + c_results.size(), 0, "the result goes to the requester only")
	assert_eq(_cluster.server.rejected_intent_count(), 0, "nothing was refused so far")

	# Out of reach: the server's positions decide; the food is kept and
	# nobody sees an attempt.
	b_notices.clear()
	c_notices.clear()
	_world.get_player(bob_id).position = FAR_AWAY
	assert_eq(await _use_on(a, food, bob_id), [false, ItemConsumption.REASON_TARGET_TOO_FAR])
	_world.get_player(bob_id).position = Vector3.ZERO
	assert_eq(_server_quantity(food), 2, "server: the food is kept")
	await _settle()
	assert_eq(b_notices.size() + c_notices.size(), 0, "a refused request is told to nobody")
	assert_eq(_module(a).rejected_payload_count + _module(b).rejected_payload_count + _module(c).rejected_payload_count, 0, "the server's own messages pass the client validation")


# ------------------------------------------------------------ 4. manipulated requests

func test_manipulated_use_on_requests_are_rejected_and_change_nothing() -> void:
	assert_true(_start_server(), "server started")
	var bandages: String = _spawn(BANDAGE, 3)
	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var b: NetworkService = clients[1]
	var c: NetworkService = clients[2]
	var bob_id: String = b.client_state.local_player_id
	if not await _pick_up(a, [bandages]):
		return
	_wound(bob_id)
	await _settle()
	var a_results: Array[Array] = _use_on_results_of(a)
	var b_notices: Array[Dictionary] = _notices_of(b)
	var c_notices: Array[Dictionary] = _notices_of(c)
	var before: Dictionary = _world.inventory.to_snapshot()
	var server: NetworkService = _cluster.server
	var module: InventoryNetModule = _module(a)

	# Malformed arguments.
	module.send_raw_use_on_request("x", bandages, bob_id)
	module.send_raw_use_on_request(1, 5, bob_id)
	module.send_raw_use_on_request(2, bandages, 7)
	module.send_raw_use_on_request(3, bandages, null)
	module.send_raw_use_on_request(4, bandages, [bob_id])
	module.send_raw_use_on_request(-1, bandages, bob_id)
	module.send_raw_use_on_request(5, "", bob_id)
	module.send_raw_use_on_request(6, "i".repeat(200), bob_id)
	module.send_raw_use_on_request(7, bandages, "p".repeat(200))
	module.send_raw_use_on_request(8.0, bandages, bob_id)
	module.send_raw_use_on_request(9, bandages, Vector3.ZERO)
	const MALFORMED: int = 11
	assert_true(await _wait(func() -> bool: return server.rejected_intent_count() == MALFORMED), "every malformed request was rejected (%d)" % server.rejected_intent_count())
	# A request cannot carry a position, a distance or an effect: the handler
	# takes three arguments and the engine refuses a call with more
	# (reported as an engine error, the expected outcome, so printing is off).
	Engine.print_error_messages = false
	module._rpc_request_use_on.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, bandages, bob_id, Vector3.ZERO)
	module._rpc_request_use_on.rpc_id(NetworkService.SERVER_PEER_ID, FORGED_REQUEST_ID, bandages, bob_id, 0.0, true)
	await _settle()
	Engine.print_error_messages = true
	assert_eq(a_results, [
		[1, false, IntentValidator.REASON_BAD_TYPE],
		[2, false, IntentValidator.REASON_BAD_TYPE],
		[3, false, IntentValidator.REASON_BAD_TYPE],
		[4, false, IntentValidator.REASON_BAD_TYPE],
		[5, false, IntentValidator.REASON_BAD_ITEM_ID],
		[6, false, IntentValidator.REASON_BAD_ITEM_ID],
		[7, false, InventoryNetModule.REASON_BAD_TARGET_ID],
		[9, false, IntentValidator.REASON_BAD_TYPE],
	], "answers go to usable request ids only, in order")
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_TYPE), 7)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_SEQUENCE), 1)
	assert_eq(server.rejected_intent_count(IntentValidator.REASON_BAD_ITEM_ID), 2)
	assert_eq(server.rejected_intent_count(InventoryNetModule.REASON_BAD_TARGET_ID), 1)
	assert_eq(server.rejected_intent_count(), MALFORMED, "the calls the engine refused never reached the handler")
	assert_eq(_world.inventory.to_snapshot(), before, "no item changed")
	assert_eq(_survival().bleeding_wound_ids(bob_id).size(), 1, "bob still bleeds")
	assert_eq(b_notices.size() + c_notices.size(), 0)

	# Forged server messages: a client cannot tell another client that it was
	# treated, or answer a request. Real ENet path: the engine refuses these
	# (the sender is not the authority) and reports each as an engine error,
	# the expected outcome, so printing is off for this block.
	var forged_target: Dictionary = {"scope": "target", "user_id": a.client_state.local_player_id, "target_id": bob_id, "definition_id": BANDAGE, "ok": true, "reason": "", "world_time": 1.0}
	var b_results: Array[Array] = _use_on_results_of(b)
	var server_notices: Array[Dictionary] = _notices_of(server)
	Engine.print_error_messages = false
	for target: int in [NetworkService.SERVER_PEER_ID, b.multiplayer.get_unique_id()]:
		module._rpc_use_on_result.rpc_id(target, FORGED_REQUEST_ID, true, "")
		module._rpc_treatment_notice.rpc_id(target, forged_target)
	await _settle()
	Engine.print_error_messages = true
	# Script-level guard, independent of the engine (sender id 0 here), and a
	# client never acts on a request addressed to it.
	_module(b)._rpc_use_on_result(FORGED_REQUEST_ID, true, "")
	_module(b)._rpc_treatment_notice(forged_target)
	_module(b)._rpc_request_use_on(FORGED_REQUEST_ID, bandages, bob_id)
	await _settle()
	assert_eq(b_results.size() + b_notices.size() + server_notices.size(), 0, "nothing forged was delivered")
	assert_eq(_world.inventory.to_snapshot(), before)
	assert_eq(server.rejected_intent_count(), MALFORMED)


func test_use_on_request_before_join_is_rejected_and_floods_are_limited() -> void:
	const BURST: int = 2
	const FLOOD: int = 6
	# One new token every 100 seconds: only the burst passes within the test.
	_inventory_net.consume_intent_rate_per_sec = 0.01
	_inventory_net.consume_intent_burst = BURST
	assert_true(_start_server(), "server started")
	var bandages: String = _spawn(BANDAGE, STACK_MAX)
	var stranger: NetworkService = _cluster.add_client("mallory", false)
	var stranger_results: Array[Array] = _use_on_results_of(stranger)
	var connected: bool = await _wait(func() -> bool: return stranger.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	assert_true(connected, "transport connected (no join request sent)")
	if not connected:
		return
	assert_eq(_module(stranger).request_use_on(bandages, "player_000001"), InventoryNetModule.NO_REQUEST, "the client API sends nothing before the join")
	_module(stranger).send_raw_use_on_request(1, bandages, "player_000001")
	assert_true(await _wait(func() -> bool: return _cluster.server.rejected_intent_count(NetworkService.NOT_JOINED) == 1), "the server refused the request of a peer that has not joined")
	await _settle()
	assert_eq(stranger_results.size(), 0, "an unjoined peer is told nothing")

	var clients: Array[NetworkService] = await _join_three()
	if clients.is_empty():
		return
	var a: NetworkService = clients[0]
	var bob_id: String = clients[1].client_state.local_player_id
	if not await _pick_up(a, [bandages]):
		return
	for index: int in range(FLOOD):
		_wound(bob_id, 15.0)
	var a_results: Array[Array] = _use_on_results_of(a)
	var requests: Array = []
	for index: int in range(FLOOD):
		requests.append(_module(a).request_use_on(bandages, bob_id))
	assert_true(await _wait(func() -> bool: return a_results.size() == FLOOD), "every request was answered (%d)" % a_results.size())
	await _settle()
	var expected: Array = []
	for index: int in range(FLOOD):
		expected.append([requests[index], true, ""] if index < BURST else [requests[index], false, NetworkService.RATE_LIMITED])
	assert_eq(a_results, expected, "only the burst is accepted")
	assert_eq(_cluster.server.rejected_intent_count(NetworkService.RATE_LIMITED), FLOOD - BURST, "rejection counter")
	assert_eq(_server_quantity(bandages), STACK_MAX - BURST, "server: only the accepted uses took a bandage")
	assert_eq(_survival().bleeding_wound_ids(bob_id).size(), FLOOD - BURST, "server: only the accepted uses treated bob")
	# The use on oneself shares the same allowance (it is a use).
	var consumes: Array[Array] = []
	_module(a).consume_result.connect(func(request_id: int, ok: bool, reason: String) -> void: consumes.append([request_id, ok, reason]))
	var consume_id: int = _module(a).request_consume(bandages)
	assert_true(await _wait(func() -> bool: return consumes.size() == 1), "the consume request was answered")
	assert_eq(consumes, [[consume_id, false, NetworkService.RATE_LIMITED]])


# ------------------------------------------------------------ rules (no network)

func test_rpc_table_request_validation_and_notice_validation() -> void:
	assert_eq(BuildInfo.PROTOCOL_VERSION, 21, "the use-on RPCs are part of protocol 8 (P2-T10..T12); 9 since the hand-over RPCs (P2-T14), 10 since they were withdrawn and the drop intent got a quantity (P2-T15), 11 since the trade RPCs (P2-T16), 12 since the structure RPCs (P3-4a), 13 since the replication scope by cell (P3-2), 14 since the construction RPCs (P3-5), 15 since the container RPCs (P3-3)")
	assert_eq(InventoryNetModule.validate_use_on_request(1, "item_000001", "player_000002"), "")
	assert_eq(InventoryNetModule.validate_use_on_request(0, "item_000001", ""), "", "no target = myself")
	assert_eq(InventoryNetModule.validate_use_on_request("1", "item_000001", ""), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_use_on_request(1, 5, ""), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_use_on_request(1, "item_000001", null), IntentValidator.REASON_BAD_TYPE)
	assert_eq(InventoryNetModule.validate_use_on_request(1, "item_000001", 3), IntentValidator.REASON_BAD_TYPE, "a target is an id, not a number")
	assert_eq(InventoryNetModule.validate_use_on_request(-1, "item_000001", ""), IntentValidator.REASON_BAD_SEQUENCE)
	assert_eq(InventoryNetModule.validate_use_on_request(1, "", ""), IntentValidator.REASON_BAD_ITEM_ID)
	assert_eq(InventoryNetModule.validate_use_on_request(1, "item_000001", "p".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH + 1)), InventoryNetModule.REASON_BAD_TARGET_ID)
	assert_eq(InventoryNetModule.validate_use_on_request(1, "item_000001", "p".repeat(IntentValidator.ENTITY_ID_MAX_LENGTH)), "")
	var service: NetworkService = NetworkService.new()
	assert_eq(ServerComposition.install_net_modules(service, CompositionConfig.from_defaults()), OK)
	var module: InventoryNetModule = service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule
	assert_eq(module.request_use_on("item_000001", "player_000002"), InventoryNetModule.NO_REQUEST, "nothing is sent while offline")
	# Channel 0, reliable; requests from any peer, everything else only from the server.
	var rpc_config: Dictionary = (module.get_script() as Script).get_rpc_config()
	var expected_modes: Dictionary[String, int] = {
		"_rpc_request_use_on": MultiplayerAPI.RPC_MODE_ANY_PEER,
		"_rpc_use_on_result": MultiplayerAPI.RPC_MODE_AUTHORITY,
		"_rpc_treatment_notice": MultiplayerAPI.RPC_MODE_AUTHORITY,
	}
	for method: String in expected_modes:
		var method_config: Dictionary = rpc_config.get(StringName(method), rpc_config.get(method, {}))
		assert_eq(method_config.get("rpc_mode", -1), expected_modes[method], method + " mode")
		assert_eq(method_config.get("transfer_mode", -1), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method + " is reliable")
		assert_eq(method_config.get("channel", -1), NetworkSettings.CHANNEL_RELIABLE, method + " channel")
		assert_eq(method_config.get("call_local", true), false, method + " is remote only")
	service.free()

	# Notices: exact keys per scope and the right addressee.
	const USER: String = "player_000001"
	const TARGET: String = "player_000002"
	const BYSTANDER: String = "player_000003"
	var target_notice: Dictionary = {"scope": "target", "user_id": USER, "target_id": TARGET, "definition_id": "dev_bandage", "ok": true, "reason": "", "world_time": 5.0}
	var public_notice: Dictionary = {"scope": "public", "user_id": USER, "target_id": TARGET, "world_time": 5.0}
	assert_true(InventoryNetModule.is_valid_treatment_notice(target_notice, TARGET))
	assert_true(InventoryNetModule.is_valid_treatment_notice(public_notice, BYSTANDER))
	var refused: Dictionary = target_notice.duplicate()
	refused["ok"] = false
	refused["reason"] = SurvivalService.REASON_NOT_BLEEDING
	assert_true(InventoryNetModule.is_valid_treatment_notice(refused, TARGET))
	assert_false(InventoryNetModule.is_valid_treatment_notice(target_notice, BYSTANDER), "a target notice is for the target only")
	assert_false(InventoryNetModule.is_valid_treatment_notice(target_notice, USER))
	assert_false(InventoryNetModule.is_valid_treatment_notice(public_notice, TARGET), "the target gets the target notice")
	assert_false(InventoryNetModule.is_valid_treatment_notice(public_notice, USER), "the user gets the result")
	var bad_notices: Array = [
		"notice",
		{},
		{"scope": "owner", "user_id": USER, "target_id": TARGET, "world_time": 5.0},
		{"scope": "public", "user_id": USER, "target_id": TARGET},
		{"scope": "public", "user_id": USER, "target_id": USER, "world_time": 5.0},
		{"scope": "public", "user_id": USER, "target_id": TARGET, "world_time": -1.0},
		{"scope": "public", "user_id": USER, "target_id": TARGET, "world_time": NAN},
		{"scope": "public", "user_id": "", "target_id": TARGET, "world_time": 5.0},
		{"scope": "public", "user_id": 1, "target_id": TARGET, "world_time": 5.0},
		{"scope": "public", "user_id": USER, "target_id": TARGET, "world_time": 5.0, "definition_id": "dev_cure"},
		{"scope": "public", "user_id": USER, "target_id": TARGET, "world_time": 5.0, "ok": true},
		{"scope": "public", "user_id": USER, "target_id": TARGET, "world_time": 5.0, "infection_stage": "latent"},
	]
	for bad: Variant in bad_notices:
		assert_false(InventoryNetModule.is_valid_treatment_notice(bad, BYSTANDER), "rejected: %s" % str(bad))
	for key: String in ["definition_id", "ok", "reason"]:
		var missing: Dictionary = target_notice.duplicate()
		missing.erase(key)
		assert_false(InventoryNetModule.is_valid_treatment_notice(missing, TARGET), "a target notice without " + key)
	var wrong: Array[Dictionary] = [
		{"definition_id": "Not A Definition"}, {"definition_id": 3}, {"ok": 1}, {"reason": 5},
		{"reason": "not_bleeding"}, {"ok": false}, {"reason": "r".repeat(200), "ok": false},
		{"health": 12.0}, {"wound_ids": ["wound_000001"]}, {"infection_cured_from": "latent"},
	]
	for change: Dictionary in wrong:
		var changed: Dictionary = target_notice.duplicate()
		changed.merge(change, true)
		assert_false(InventoryNetModule.is_valid_treatment_notice(changed, TARGET), "rejected: %s" % str(change))
