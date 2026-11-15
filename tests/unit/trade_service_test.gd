extends TestCase
## P2-T16 (user decision 2026-11-16, docs/00 ADR-022, docs/09 §14.30):
## TradeService, the rules of a trade between two players. One asks, the
## other accepts, both put offers together and confirm, and only then the
## server exchanges everything at once. Server rules only, no network
## (tests/integration/trade_net_test.gd); the exchange transaction itself is
## tests/unit/item_exchange_test.gd. Time is the injected world clock: no
## test waits.

const WORLD: String = "trade_service_test_world"
const NEVER: float = 1.0e9
const LETHAL_DAMAGE: float = 100000.0
const ZOMBIE: String = "zombie_000001"
const MISSING_ITEM_ID: String = "item_999999"
const MISSING_PLAYER_ID: String = "player_999999"
const MISSING_SESSION_ID: int = 999999
const FOOD: String = "t16s_food"
const FOOD_MAX: int = 5
const PLAIN: String = "t16s_plain"
const BULK: String = "t16s_bulk"
const BULK_MAX: int = 10
## A step short enough that nothing but the tested rule happens.
const TICK: float = 0.05

var _settings: SurvivalSettings = null
var _gameplay: GameplaySettings = null
var _trade: TradeSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SurvivalSettings.new()
	_settings.respawn_delay_sec = NEVER
	_settings.health_recovery_per_world_sec = 0.0
	_settings.wound_recovery_per_world_sec = 0.0
	_gameplay = GameplaySettings.new()
	_trade = TradeSettings.new()


func after_each() -> void:
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _world(require_creation: bool = false) -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.gameplay = _gameplay
	config.survival = _settings
	config.trade = _trade
	config.clock = WorldClockSettings.new()
	config.clock.time_scale = 1.0
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var food: ItemDefinition = ItemDefinition.new()
	food.definition_id = FOOD
	food.max_stack = FOOD_MAX
	food.consume_hunger_reduction = 30.0
	catalog.add(food)
	var plain: ItemDefinition = ItemDefinition.new()
	plain.definition_id = PLAIN
	plain.max_stack = 1
	catalog.add(plain)
	var bulk: ItemDefinition = ItemDefinition.new()
	bulk.definition_id = BULK
	bulk.max_stack = BULK_MAX
	catalog.add(bulk)
	config.catalog = catalog
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.require_character_creation = require_creation
	return ServerComposition.create_world(WORLD, config)


func _service(world: ServerWorld) -> TradeService:
	return world.get_system(TradeService.SYSTEM_ID) as TradeService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


## Spawns an item where `player` stands and lets it pick the item up.
func _give(world: ServerWorld, player: PlayerState, definition_id: String, quantity: int = 1) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, DevWorldSeed.DEV_CELL_ID, player.position)
	var result: ActionResult = world.try_pickup(player.player_id, item_id)
	if not result.ok:
		fail("test setup: pickup failed: " + result.reason)
	return item_id


func _kill(world: ServerWorld, player: PlayerState) -> void:
	if not _survival(world).apply_damage(player.player_id, DamageInput.create(ZOMBIE, BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE)).ok:
		fail("test setup: lethal damage failed")


## [definition, quantity] of what a player carries, in slot order.
func _rows(world: ServerWorld, player: PlayerState) -> Array:
	var rows: Array = []
	for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
		rows.append([item.definition_id, item.quantity])
	return rows


## Opens a session between two players standing next to each other and
## returns its id (0 on failure).
func _open(world: ServerWorld, a: PlayerState, b: PlayerState) -> int:
	var trade: TradeService = _service(world)
	var asked: ActionResult = trade.request_trade(world, a.player_id, b.player_id)
	if not asked.ok:
		fail("test setup: request failed: " + asked.reason)
		return 0
	var session_id: int = int(asked.event.get("session_id", 0))
	var accepted: ActionResult = trade.accept(world, b.player_id, session_id)
	if not accepted.ok:
		fail("test setup: accept failed: " + accepted.reason)
		return 0
	trade.drain_events()
	return session_id


## The changes of the drained events, oldest first.
func _changes(events: Array[Dictionary]) -> Array:
	var changes: Array = []
	for event: Dictionary in events:
		changes.append(event.get("change", ""))
	return changes


## Asserts that the newest drained event closed a session as cancelled, for
## `cause` and by `by_player_id`, and that neither player has a session.
func _assert_cancelled(world: ServerWorld, a: PlayerState, b: PlayerState, cause: String, by_player_id: String, label: String) -> void:
	var trade: TradeService = _service(world)
	var events: Array[Dictionary] = trade.drain_events()
	assert_true(events.size() >= 1, label + ": an event was recorded")
	if events.is_empty():
		return
	var event: Dictionary = events[events.size() - 1]
	assert_eq(event.get("event_type", ""), TradeService.EVENT_SESSION_CHANGED, label)
	assert_eq(event.get("change", ""), TradeService.CHANGE_CLOSED, label)
	var session: Dictionary = event.get("session", {})
	assert_eq(session.get("phase", ""), TradeSession.PHASE_CLOSED, label)
	assert_eq(session.get("outcome", ""), TradeSession.OUTCOME_CANCELLED, label)
	assert_eq(session.get("cause", ""), cause, label + ": both are told why")
	assert_eq(session.get("by_player_id", "?"), by_player_id, label + ": and who caused it")
	assert_true(SaveService.is_json_safe(event), label + ": the event is plain data")
	assert_null(trade.session_of(a.player_id), label + ": the one side is free again")
	assert_null(trade.session_of(b.player_id), label + ": and so is the other")
	assert_eq(trade.session_count(), 0, label)


# ------------------------------------------------------------ settings and composition

func test_shipped_settings_and_composition() -> void:
	var shipped: TradeSettings = TradeSettings.load_or_default()
	assert_eq(shipped.validate().size(), 0, "; ".join(shipped.validate()))
	var defaults: TradeSettings = TradeSettings.new()
	for property: String in ["request_range_m", "session_range_m", "request_timeout_sec", "session_idle_timeout_sec", "max_offer_entries", "max_pending_events"]:
		assert_eq(defaults.get(property), shipped.get(property), "the script default of %s agrees with the shipped resource" % property)
	assert_true(shipped.session_range_m >= shipped.request_range_m, "a session is not broken by the distance it was asked from")
	var broken: TradeSettings = TradeSettings.new()
	broken.request_range_m = 0.0
	broken.session_range_m = -1.0
	broken.request_timeout_sec = 0.0
	broken.session_idle_timeout_sec = NAN
	broken.max_offer_entries = 0
	broken.max_pending_events = 0
	assert_eq(broken.validate().size(), 6, "; ".join(broken.validate()))
	var shorter: TradeSettings = TradeSettings.new()
	shorter.session_range_m = shorter.request_range_m - 0.5
	assert_eq(shorter.validate().size(), 1, "the session range may not be shorter than the request range")
	# The composition: the system is registered, last, and validated.
	var world: ServerWorld = _world()
	assert_not_null(_service(world), "the composition registers the trade system")
	var ids: PackedStringArray = world.system_ids()
	assert_eq(ids[ids.size() - 1], TradeService.SYSTEM_ID, "after the systems whose state it asks for: %s" % ", ".join(ids))
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	config.trade = broken
	assert_true(config.validate().size() > 0, "composition validation covers the trade settings")
	config.trade = null
	assert_true(config.validate().size() > 0, "a missing settings object is reported")
	# Nothing of a trade is saved.
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	assert_true(_open(world, alice, bob) > 0)
	var documents: Dictionary = world.to_documents()
	assert_false((documents["world_state"][ServerWorld.KEY_SYSTEMS] as Dictionary).has(TradeService.SYSTEM_ID), "no world document")
	assert_false((documents["players"][alice.player_id][ServerWorld.KEY_SYSTEMS] as Dictionary).has(TradeService.SYSTEM_ID), "no player fragment")


# ------------------------------------------------------------ the flow

func test_a_request_is_accepted_both_confirm_and_everything_is_exchanged_at_once() -> void:
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var food: String = _give(world, alice, FOOD, 3)
	var plain: String = _give(world, alice, PLAIN)
	var bulk: String = _give(world, bob, BULK, 6)
	var alice_before: Dictionary = survival.to_player_fragment(alice.player_id)
	var bob_before: Dictionary = survival.to_player_fragment(bob.player_id)
	survival.drain_events()
	var transactions: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: transactions.append(event))

	# --- alice asks bob.
	var asked: ActionResult = trade.request_trade(world, alice.player_id, bob.player_id)
	assert_true(asked.ok, asked.reason)
	var session_id: int = int(asked.event.get("session_id", 0))
	assert_true(session_id >= 1, "a session id: %d" % session_id)
	assert_eq(asked.event.get("phase", ""), TradeSession.PHASE_REQUESTED)
	assert_eq(asked.event.get("requester_id", ""), alice.player_id)
	assert_eq(asked.event.get("target_id", ""), bob.player_id)
	assert_eq(trade.session_of(alice.player_id), trade.session_of(bob.player_id), "one session for both")
	assert_null(trade.session_of(carol.player_id))
	assert_eq(_changes(trade.drain_events()), [TradeService.CHANGE_REQUESTED])
	# Nothing can be offered before the answer.
	assert_eq(trade.set_offer(world, alice.player_id, session_id, food, 1).reason, TradeService.REASON_SESSION_NOT_OPEN)
	assert_eq(trade.set_confirmed(world, alice.player_id, session_id, 0, true).reason, TradeService.REASON_SESSION_NOT_OPEN)

	# --- bob accepts: the session is open.
	var accepted: ActionResult = trade.accept(world, bob.player_id, session_id)
	assert_true(accepted.ok, accepted.reason)
	assert_eq(accepted.event.get("phase", ""), TradeSession.PHASE_OPEN)
	assert_eq(_changes(trade.drain_events()), [TradeService.CHANGE_OPENED])

	# --- both put their offers together.
	var offered: ActionResult = trade.set_offer(world, alice.player_id, session_id, food, 2)
	assert_true(offered.ok, offered.reason)
	assert_eq(offered.event.get("revision", -1), 1, "every offer change is a new revision")
	assert_true(trade.set_offer(world, alice.player_id, session_id, plain, 1).ok)
	assert_true(trade.set_offer(world, bob.player_id, session_id, bulk, 4).ok)
	var session: TradeSession = trade.session_of(alice.player_id)
	assert_eq(session.revision, 3)
	assert_eq(session.offers[alice.player_id], [
		{"item_instance_id": food, "definition_id": FOOD, "quantity": 2},
		{"item_instance_id": plain, "definition_id": PLAIN, "quantity": 1},
	], "the offer names stacks, their kind and how many units")
	assert_eq(session.offers[bob.player_id], [{"item_instance_id": bulk, "definition_id": BULK, "quantity": 4}])
	assert_eq(_rows(world, alice), [[FOOD, 3], [PLAIN, 1]], "an offer moves nothing")
	assert_eq(_rows(world, bob), [[BULK, 6]])
	assert_eq(transactions.size(), 0, "no inventory transaction yet")
	assert_eq(_changes(trade.drain_events()), [TradeService.CHANGE_OFFER, TradeService.CHANGE_OFFER, TradeService.CHANGE_OFFER])

	# --- alice confirms: nothing moves on one confirmation.
	var first: ActionResult = trade.set_confirmed(world, alice.player_id, session_id, 3, true)
	assert_true(first.ok, first.reason)
	assert_eq(first.event.get("phase", ""), TradeSession.PHASE_OPEN)
	assert_eq((first.event.get("confirmed", {}) as Dictionary).get(alice.player_id, false), true)
	assert_eq((first.event.get("confirmed", {}) as Dictionary).get(bob.player_id, true), false)
	assert_eq(_rows(world, alice), [[FOOD, 3], [PLAIN, 1]])
	assert_eq(transactions.size(), 0)
	assert_eq(_changes(trade.drain_events()), [TradeService.CHANGE_CONFIRMED])

	# --- bob confirms: both have, so the exchange happens, all at once.
	var second: ActionResult = trade.set_confirmed(world, bob.player_id, session_id, 3, true)
	assert_true(second.ok, second.reason)
	assert_eq(second.event.get("phase", ""), TradeSession.PHASE_CLOSED)
	assert_eq(second.event.get("outcome", ""), TradeSession.OUTCOME_COMPLETED)
	assert_eq(_rows(world, alice), [[FOOD, 1], [BULK, 4]], "alice gave 2 food and her single item and got 4 of bob's stack")
	assert_eq(_rows(world, bob), [[BULK, 2], [FOOD, 2], [PLAIN, 1]])
	assert_eq(_rows(world, carol), [], "nobody else got anything")
	assert_eq(transactions.size(), 1, "ONE inventory transaction")
	assert_eq(transactions[0].get("event_type", ""), InventoryService.EVENT_ITEMS_EXCHANGED)
	var events: Array[Dictionary] = trade.drain_events()
	assert_eq(_changes(events), [TradeService.CHANGE_CLOSED], "one event: the confirmation that completed the trade closed it")
	var closed: Dictionary = events[0].get("session", {})
	assert_eq(closed.get("outcome", ""), TradeSession.OUTCOME_COMPLETED)
	assert_eq(closed.get("cause", "?"), "")
	assert_eq((closed.get("offers", {}) as Dictionary).get(bob.player_id, []), [{"item_instance_id": bulk, "definition_id": BULK, "quantity": 4}], "the closed session still says what was exchanged")
	assert_true(SaveService.is_json_safe(events[0]))
	# Both are free again, and the finished session takes no more intents.
	assert_null(trade.session_of(alice.player_id))
	assert_null(trade.session_of(bob.player_id))
	assert_eq(trade.session_count(), 0)
	assert_eq(trade.set_confirmed(world, alice.player_id, session_id, 3, true).reason, TradeService.REASON_NOT_IN_SESSION)
	assert_eq(trade.set_offer(world, bob.player_id, session_id, bulk, 1).reason, TradeService.REASON_NOT_IN_SESSION)
	assert_eq(trade.cancel(world, alice.player_id, session_id).reason, TradeService.REASON_NOT_IN_SESSION)
	# A trade moves items and nothing else.
	assert_eq(survival.to_player_fragment(alice.player_id), alice_before)
	assert_eq(survival.to_player_fragment(bob.player_id), bob_before)
	assert_eq(survival.drain_events().size(), 0, "no survival event")
	# The next trade gets another session id.
	var again: ActionResult = trade.request_trade(world, bob.player_id, alice.player_id)
	assert_true(again.ok, again.reason)
	assert_true(int(again.event.get("session_id", 0)) > session_id, "session ids are not reused")


func test_a_gift_needs_the_receivers_confirmation_and_empty_offers_exchange_nothing() -> void:
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 3)
	var session_id: int = _open(world, alice, bob)
	# Nothing offered by anybody: there is nothing to confirm.
	assert_eq(trade.set_confirmed(world, alice.player_id, session_id, 0, true).reason, TradeService.REASON_NOTHING_OFFERED)
	assert_true(trade.set_offer(world, alice.player_id, session_id, food, 2).ok)
	# The giver alone cannot finish it: bob has to confirm what he receives.
	assert_true(trade.set_confirmed(world, alice.player_id, session_id, 1, true).ok)
	assert_eq(_rows(world, bob), [], "nothing arrives without the receiver's confirmation")
	assert_not_null(trade.session_of(bob.player_id))
	var done: ActionResult = trade.set_confirmed(world, bob.player_id, session_id, 1, true)
	assert_true(done.ok, done.reason)
	assert_eq(done.event.get("outcome", ""), TradeSession.OUTCOME_COMPLETED)
	assert_eq(_rows(world, alice), [[FOOD, 1]])
	assert_eq(_rows(world, bob), [[FOOD, 2]], "a one-sided gift, accepted")


func test_any_change_of_an_offer_clears_both_confirmations() -> void:
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 3)
	var bulk: String = _give(world, bob, BULK, 6)
	var session_id: int = _open(world, alice, bob)
	var session: TradeSession = trade.session_of(alice.player_id)
	assert_true(trade.set_offer(world, alice.player_id, session_id, food, 1).ok)
	assert_true(trade.set_offer(world, bob.player_id, session_id, bulk, 6).ok)
	assert_true(trade.set_confirmed(world, alice.player_id, session_id, 2, true).ok, "alice agrees to 1 food for 6 bulk")
	assert_true(session.confirmed[alice.player_id])
	assert_eq(trade.set_confirmed(world, alice.player_id, session_id, 2, true).reason, TradeService.REASON_ALREADY_CONFIRMED)

	# Bob lowers his offer after alice confirmed: her confirmation is gone.
	var lowered: ActionResult = trade.set_offer(world, bob.player_id, session_id, bulk, 1)
	assert_true(lowered.ok, lowered.reason)
	assert_false(session.confirmed[alice.player_id], "a changed offer clears the other side's confirmation")
	assert_false(session.confirmed[bob.player_id])
	assert_eq(session.revision, 3)
	# Bob confirms at once; alice's confirmation of what she saw before does
	# not count for what is offered now.
	assert_true(trade.set_confirmed(world, bob.player_id, session_id, 3, true).ok)
	var stale: ActionResult = trade.set_confirmed(world, alice.player_id, session_id, 2, true)
	assert_eq(stale.reason, TradeService.REASON_STALE_OFFER, "a confirmation of an older revision is refused")
	assert_eq(_rows(world, alice), [[FOOD, 3]], "nothing was exchanged")
	assert_eq(_rows(world, bob), [[BULK, 6]])
	assert_true(session.confirmed[bob.player_id], "bob's confirmation of the current offers stands")
	# The own offer changing clears the own confirmation too.
	assert_true(trade.set_offer(world, bob.player_id, session_id, bulk, 2).ok)
	assert_false(session.confirmed[bob.player_id])
	# Taking a stack out of the offer is a change as well.
	assert_true(trade.set_confirmed(world, alice.player_id, session_id, 4, true).ok)
	assert_true(trade.set_offer(world, alice.player_id, session_id, food, 0).ok)
	assert_false(session.confirmed[alice.player_id])
	assert_eq(session.offers[alice.player_id], [])
	assert_eq(session.revision, 5)
	# Setting what is already offered changes nothing and clears nothing.
	assert_true(trade.set_confirmed(world, alice.player_id, session_id, 5, true).ok)
	trade.drain_events()
	assert_eq(trade.set_offer(world, bob.player_id, session_id, bulk, 2).reason, TradeService.REASON_OFFER_UNCHANGED)
	assert_true(session.confirmed[alice.player_id], "nothing changed, so the confirmation stands")
	assert_eq(session.revision, 5)
	assert_eq(trade.drain_events().size(), 0, "a refused intent records no event")
	# A confirmation can be taken back without changing an offer.
	var taken_back: ActionResult = trade.set_confirmed(world, alice.player_id, session_id, 5, false)
	assert_true(taken_back.ok, taken_back.reason)
	assert_false(session.confirmed[alice.player_id])
	assert_eq(session.revision, 5, "taking a confirmation back changes no offer")
	assert_eq(_changes(trade.drain_events()), [TradeService.CHANGE_UNCONFIRMED])
	assert_eq(trade.set_confirmed(world, alice.player_id, session_id, 5, false).reason, TradeService.REASON_NOT_CONFIRMED)
	# Nobody confirms for the other side: a confirmation is always the caller's.
	assert_true(trade.set_confirmed(world, bob.player_id, session_id, 5, true).ok)
	assert_false(session.confirmed[alice.player_id], "bob's confirmation is bob's")
	assert_not_null(trade.session_of(alice.player_id), "one confirmation completes nothing")
	assert_eq(_rows(world, alice), [[FOOD, 3]])


# ------------------------------------------------------------ who can ask whom

func test_who_can_ask_whom() -> void:
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var survival: SurvivalService = _survival(world)
	var posture: PostureService = world.get_system(PostureService.SYSTEM_ID) as PostureService
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var dave: PlayerState = world.join("dave")
	var before: Dictionary = world.to_documents()
	# Not oneself, nobody that is no player in the world.
	assert_eq(trade.request_trade(world, alice.player_id, alice.player_id).reason, TradeService.REASON_TARGET_IS_SELF)
	for target: String in [MISSING_PLAYER_ID, "", ZOMBIE, bob.inventory_id]:
		assert_eq(trade.request_trade(world, alice.player_id, target).reason, TradeService.REASON_TARGET_UNAVAILABLE, "target '%s'" % target)
	assert_eq(trade.request_trade(world, MISSING_PLAYER_ID, bob.player_id).reason, TradeService.REASON_NOT_ONLINE, "an unknown requester")
	# Within the request range, measured between the server's positions.
	var range_m: float = _trade.request_range_m
	bob.position = alice.position + Vector3(range_m + 0.01, 0.0, 0.0)
	assert_eq(trade.request_trade(world, alice.player_id, bob.player_id).reason, TradeService.REASON_TARGET_TOO_FAR, "just out of range")
	bob.position = alice.position + Vector3(range_m, 0.0, 0.0)
	var at_range: ActionResult = trade.request_trade(world, alice.player_id, bob.player_id)
	assert_true(at_range.ok, "at the range: " + at_range.reason)
	assert_true(trade.cancel(world, alice.player_id, int(at_range.event["session_id"])).ok)
	bob.position = alice.position
	# A sleeper is not asked (it could not answer) and cannot ask.
	assert_true(survival.start_rest(bob.player_id).ok)
	assert_eq(trade.request_trade(world, alice.player_id, bob.player_id).reason, TradeService.REASON_TARGET_RESTING)
	assert_eq(trade.request_trade(world, bob.player_id, alice.player_id).reason, SurvivalService.REASON_PLAYER_RESTING)
	assert_true(survival.is_resting(bob.player_id), "a refused request does not wake")
	assert_true(survival.stop_rest(bob.player_id).ok)
	# A prone player can trade, as requester and as target.
	assert_true(posture.request_posture(world, bob.player_id, PlayerPosture.Kind.PRONE).ok)
	var prone_target: ActionResult = trade.request_trade(world, alice.player_id, bob.player_id)
	assert_true(prone_target.ok, "a prone player can be asked: " + prone_target.reason)
	assert_true(trade.accept(world, bob.player_id, int(prone_target.event["session_id"])).ok, "and can accept")
	assert_true(posture.is_prone(bob.player_id), "and stays prone")
	# Somebody in a request or a session is busy; somebody in one cannot ask.
	assert_eq(trade.request_trade(world, carol.player_id, alice.player_id).reason, TradeService.REASON_TARGET_BUSY)
	assert_eq(trade.request_trade(world, carol.player_id, bob.player_id).reason, TradeService.REASON_TARGET_BUSY)
	assert_eq(trade.request_trade(world, alice.player_id, carol.player_id).reason, TradeService.REASON_ALREADY_TRADING)
	assert_eq(trade.request_trade(world, alice.player_id, alice.player_id).reason, TradeService.REASON_ALREADY_TRADING, "the requester's own state comes first")
	# From afar nothing is learnt about whether somebody is busy or asleep.
	carol.position = alice.position + Vector3(50.0, 0.0, 0.0)
	assert_eq(trade.request_trade(world, carol.player_id, alice.player_id).reason, TradeService.REASON_TARGET_TOO_FAR, "busy, but far: the distance is told")
	carol.position = alice.position
	assert_true(trade.cancel(world, bob.player_id, int(prone_target.event["session_id"])).ok)
	# A pending request makes both busy too.
	var pending: ActionResult = trade.request_trade(world, carol.player_id, dave.player_id)
	assert_true(pending.ok, pending.reason)
	assert_eq(trade.request_trade(world, alice.player_id, dave.player_id).reason, TradeService.REASON_TARGET_BUSY)
	assert_eq(trade.request_trade(world, alice.player_id, carol.player_id).reason, TradeService.REASON_TARGET_BUSY)
	assert_eq(trade.request_trade(world, carol.player_id, alice.player_id).reason, TradeService.REASON_ALREADY_TRADING)
	# Asking the player that asked me is saying yes.
	var mutual: ActionResult = trade.request_trade(world, dave.player_id, carol.player_id)
	assert_true(mutual.ok, mutual.reason)
	assert_eq(mutual.event.get("phase", ""), TradeSession.PHASE_OPEN, "a request answered with a request opens the session")
	assert_eq(mutual.event.get("session_id", 0), pending.event.get("session_id", -1))
	assert_true(trade.cancel(world, dave.player_id, int(mutual.event["session_id"])).ok)
	# The dead are not asked and do not ask.
	_kill(world, bob)
	assert_eq(trade.request_trade(world, alice.player_id, bob.player_id).reason, TradeService.REASON_TARGET_DEAD)
	assert_eq(trade.request_trade(world, bob.player_id, alice.player_id).reason, SurvivalService.REASON_PLAYER_DEAD)
	# Dead comes before the distance (both are public facts), away before dead.
	bob.position = alice.position + Vector3(50.0, 0.0, 0.0)
	assert_eq(trade.request_trade(world, alice.player_id, bob.player_id).reason, TradeService.REASON_TARGET_DEAD)
	world.leave(bob.player_id)
	assert_eq(trade.request_trade(world, alice.player_id, bob.player_id).reason, TradeService.REASON_TARGET_UNAVAILABLE, "an offline player")
	world.leave(carol.player_id)
	assert_eq(trade.request_trade(world, carol.player_id, alice.player_id).reason, TradeService.REASON_NOT_ONLINE, "an offline requester")
	assert_eq(trade.session_count(), 0)
	assert_eq(JSON.stringify(world.to_documents()["world_state"]["inventory"]), JSON.stringify(before["world_state"]["inventory"]), "asking moves no item")


func test_a_player_without_a_character_neither_asks_nor_is_asked() -> void:
	var world: ServerWorld = _world(true)
	var trade: TradeService = _service(world)
	var alice: PlayerState = world.join("alice")
	assert_true(world.create_character(alice.player_id, "Alice", {}).ok)
	var ghost: PlayerState = world.join("ghost")
	assert_true(world.is_player_connected(ghost.player_id) and not world.is_online(ghost.player_id), "connected, without a character")
	assert_eq(trade.request_trade(world, alice.player_id, ghost.player_id).reason, TradeService.REASON_TARGET_UNAVAILABLE)
	assert_eq(trade.request_trade(world, ghost.player_id, alice.player_id).reason, TradeService.REASON_NOT_ONLINE)


# ------------------------------------------------------------ cancelling

func test_a_request_is_declined_withdrawn_or_times_out() -> void:
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	# Declined by the player that was asked.
	var asked: ActionResult = trade.request_trade(world, alice.player_id, bob.player_id)
	var session_id: int = int(asked.event["session_id"])
	assert_eq(trade.accept(world, alice.player_id, session_id).reason, TradeService.REASON_NO_SUCH_REQUEST, "the requester cannot accept its own request")
	assert_eq(trade.accept(world, carol.player_id, session_id).reason, TradeService.REASON_NO_SUCH_REQUEST, "a third player cannot accept it")
	assert_eq(trade.cancel(world, carol.player_id, session_id).reason, TradeService.REASON_NOT_IN_SESSION, "or decline it")
	assert_eq(trade.accept(world, bob.player_id, MISSING_SESSION_ID).reason, TradeService.REASON_NO_SUCH_REQUEST, "another session id")
	trade.drain_events()
	assert_true(trade.cancel(world, bob.player_id, session_id).ok)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_DECLINED, bob.player_id, "declined")
	assert_eq(trade.accept(world, bob.player_id, session_id).reason, TradeService.REASON_NO_SUCH_REQUEST, "a declined request cannot be accepted any more")
	# Withdrawn by the player that asked.
	asked = trade.request_trade(world, alice.player_id, bob.player_id)
	session_id = int(asked.event["session_id"])
	assert_true(trade.cancel(world, alice.player_id, session_id).ok)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_WITHDRAWN, alice.player_id, "withdrawn")
	# Unanswered: it times out on the world clock (no real waiting).
	asked = trade.request_trade(world, alice.player_id, bob.player_id)
	session_id = int(asked.event["session_id"])
	trade.drain_events()
	world.step_systems(_trade.request_timeout_sec - 1.0)
	assert_not_null(trade.session_of(bob.player_id), "one second before the timeout the request still waits")
	assert_eq(trade.drain_events().size(), 0)
	world.step_systems(1.0)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_REQUEST_TIMEOUT, "", "request timeout")
	assert_eq(trade.accept(world, bob.player_id, session_id).reason, TradeService.REASON_NO_SUCH_REQUEST, "too late")
	# The timeout is a setting.
	_trade.request_timeout_sec = 3.0
	assert_true(trade.request_trade(world, alice.player_id, bob.player_id).ok)
	world.step_systems(3.0)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_REQUEST_TIMEOUT, "", "a shorter configured timeout")


func test_a_session_is_cancelled_for_every_cause_and_nothing_moves() -> void:
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var survival: SurvivalService = _survival(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 3)
	var bulk: String = _give(world, bob, BULK, 6)
	var before: String = JSON.stringify(world.inventory.to_snapshot())
	var session_id: int = 0

	# Each round: an open session with offers on both sides and one
	# confirmation, then the cause.
	var prepare: Callable = func() -> int:
		var opened: int = _open(world, alice, bob)
		if not trade.set_offer(world, alice.player_id, opened, food, 2).ok or not trade.set_offer(world, bob.player_id, opened, bulk, 3).ok:
			fail("test setup: offers failed")
		if not trade.set_confirmed(world, alice.player_id, opened, 2, true).ok:
			fail("test setup: confirmation failed")
		trade.drain_events()
		return opened

	# Either side cancels.
	session_id = prepare.call()
	assert_true(trade.cancel(world, bob.player_id, session_id).ok)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_CANCELLED, bob.player_id, "cancelled by the target")
	session_id = prepare.call()
	assert_true(trade.cancel(world, alice.player_id, session_id).ok)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_CANCELLED, alice.player_id, "cancelled by the requester")
	assert_eq(trade.cancel(world, alice.player_id, session_id).reason, TradeService.REASON_NOT_IN_SESSION, "a session is cancelled once")

	# They move apart: beyond the request range is fine, beyond the session
	# range is not.
	session_id = prepare.call()
	bob.position = alice.position + Vector3(_trade.session_range_m, 0.0, 0.0)
	world.step_systems(TICK)
	assert_not_null(trade.session_of(alice.player_id), "at the session range the session goes on")
	assert_true(_trade.session_range_m > _trade.request_range_m, "(further than a request reaches)")
	bob.position = alice.position + Vector3(_trade.session_range_m + 0.01, 0.0, 0.0)
	world.step_systems(TICK)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_TOO_FAR, "", "moved apart")
	bob.position = alice.position

	# One lies down to sleep.
	session_id = prepare.call()
	assert_true(survival.start_rest(bob.player_id).ok)
	world.step_systems(TICK)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_PLAYER_RESTING, bob.player_id, "fell asleep")
	assert_true(survival.stop_rest(bob.player_id).ok)

	# The session idles past its timeout; an accepted action starts it over.
	session_id = prepare.call()
	world.step_systems(_trade.session_idle_timeout_sec - 1.0)
	assert_not_null(trade.session_of(alice.player_id), "one second before the timeout")
	assert_true(trade.set_confirmed(world, alice.player_id, session_id, 2, false).ok, "an accepted action")
	trade.drain_events()
	world.step_systems(_trade.session_idle_timeout_sec - 1.0)
	assert_not_null(trade.session_of(alice.player_id), "the idle time started over")
	assert_eq(trade.set_offer(world, alice.player_id, session_id, food, 2).reason, TradeService.REASON_OFFER_UNCHANGED, "a refused action")
	world.step_systems(1.0)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_IDLE_TIMEOUT, "", "idle: a refused action does not keep a session alive")

	# One leaves the server: told at once, without waiting for a tick.
	session_id = prepare.call()
	world.leave(bob.player_id)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_DISCONNECTED, bob.player_id, "disconnected")
	assert_eq(JSON.stringify(world.inventory.to_snapshot()), before, "no cancelled trade moved an item")
	assert_not_null(world.join("bob"))
	bob.position = alice.position

	# One starts a new character (its belongings go to the ground first).
	session_id = prepare.call()
	assert_true(world.start_new_character(alice.player_id).ok)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_NEW_CHARACTER, alice.player_id, "new character")
	assert_eq(_rows(world, bob), [[BULK, 6]], "bob kept what he had offered")
	assert_eq(world.inventory.get_item(food).location_type, ItemInstance.LOCATION_WORLD, "alice's offered stack lies where her old character was, not in bob's inventory")
	alice.position = bob.position
	assert_true(world.try_pickup(alice.player_id, food).ok)

	# One dies.
	session_id = prepare.call()
	_kill(world, bob)
	world.step_systems(TICK)
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_PLAYER_DEAD, bob.player_id, "died")
	assert_eq(_rows(world, alice), [[FOOD, 3]], "alice kept what she had offered")
	assert_eq(_rows(world, bob), [], "the dead character's belongings lie on the ground")
	assert_eq(world.inventory.get_item(bulk).location_type, ItemInstance.LOCATION_WORLD)
	assert_eq(world.inventory.get_item(bulk).quantity, 6, "all of it")


func test_the_state_of_both_sides_is_checked_before_every_intent() -> void:
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 3)
	var bulk: String = _give(world, bob, BULK, 6)
	# Bob dies between two ticks, both had offers and bob had confirmed: the
	# confirmation that would complete the trade cancels it instead.
	var session_id: int = _open(world, alice, bob)
	assert_true(trade.set_offer(world, alice.player_id, session_id, food, 3).ok)
	assert_true(trade.set_offer(world, bob.player_id, session_id, bulk, 6).ok)
	assert_true(trade.set_confirmed(world, bob.player_id, session_id, 2, true).ok)
	trade.drain_events()
	_kill(world, bob)
	var late: ActionResult = trade.set_confirmed(world, alice.player_id, session_id, 2, true)
	assert_eq(late.reason, TradeService.REASON_SESSION_CANCELLED, "no exchange with the dead")
	_assert_cancelled(world, alice, bob, TradeService.CAUSE_PLAYER_DEAD, bob.player_id, "died before the last confirmation")
	assert_eq(_rows(world, alice), [[FOOD, 3]], "alice gave nothing")
	# The same for an offer and for accepting a request: too far by now.
	var carol: PlayerState = world.join("carol")
	var asked: ActionResult = trade.request_trade(world, alice.player_id, carol.player_id)
	assert_true(asked.ok, asked.reason)
	carol.position = alice.position + Vector3(_trade.session_range_m + 1.0, 0.0, 0.0)
	trade.drain_events()
	assert_eq(trade.accept(world, carol.player_id, int(asked.event["session_id"])).reason, TradeService.REASON_SESSION_CANCELLED)
	_assert_cancelled(world, alice, carol, TradeService.CAUSE_TOO_FAR, "", "walked away before accepting")
	carol.position = alice.position
	session_id = _open(world, alice, carol)
	carol.position = alice.position + Vector3(_trade.session_range_m + 1.0, 0.0, 0.0)
	assert_eq(trade.set_offer(world, alice.player_id, session_id, food, 1).reason, TradeService.REASON_SESSION_CANCELLED)
	_assert_cancelled(world, alice, carol, TradeService.CAUSE_TOO_FAR, "", "walked away before the offer")


# ------------------------------------------------------------ forged and invalid intents

func test_offers_name_only_the_offering_players_own_stacks() -> void:
	_trade.max_offer_entries = 2
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var food: String = _give(world, alice, FOOD, 3)
	var plain: String = _give(world, alice, PLAIN)
	var bulk_a: String = _give(world, alice, BULK, 2)
	var bulk: String = _give(world, bob, BULK, 6)
	var carols: String = _give(world, carol, PLAIN)
	var lying: String = world.inventory.spawn_world_item(PLAIN, 1, DevWorldSeed.DEV_CELL_ID, alice.position)
	var session_id: int = _open(world, alice, bob)
	var session: TradeSession = trade.session_of(alice.player_id)
	assert_true(trade.set_offer(world, bob.player_id, session_id, bulk, 6).ok)
	var before: String = JSON.stringify(session.to_dict())
	trade.drain_events()

	# Only stacks the offering player carries, and only as many units as the
	# stack holds.
	assert_eq(trade.set_offer(world, alice.player_id, session_id, bulk, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "the other side's stack offered as my own")
	assert_eq(trade.set_offer(world, alice.player_id, session_id, carols, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "a third player's item")
	assert_eq(trade.set_offer(world, alice.player_id, session_id, lying, 1).reason, InventoryService.REASON_NOT_IN_INVENTORY, "an item lying in the world")
	assert_eq(trade.set_offer(world, alice.player_id, session_id, MISSING_ITEM_ID, 1).reason, InventoryService.REASON_UNKNOWN_ITEM)
	assert_eq(trade.set_offer(world, alice.player_id, session_id, bob.player_id, 1).reason, InventoryService.REASON_UNKNOWN_ITEM, "a player id is no item")
	# Ownership before the quantity: nothing is learnt about a foreign stack.
	assert_eq(trade.set_offer(world, alice.player_id, session_id, bulk, 99).reason, InventoryService.REASON_NOT_IN_INVENTORY)
	for bad: int in [4, 1000000, 9223372036854775807, -1, -9223372036854775807]:
		assert_eq(trade.set_offer(world, alice.player_id, session_id, food, bad).reason, InventoryService.REASON_BAD_QUANTITY, "quantity %d" % bad)
	# Nobody changes the other side's offer: "take it out" only ever means
	# the caller's own offer.
	assert_eq(trade.set_offer(world, alice.player_id, session_id, bulk, 0).reason, TradeService.REASON_NOT_IN_OFFER, "alice cannot take bob's stack out of bob's offer")
	assert_eq(trade.set_offer(world, alice.player_id, session_id, food, 0).reason, TradeService.REASON_NOT_IN_OFFER, "nothing of hers is offered yet")
	assert_eq(JSON.stringify(session.to_dict()), before, "no refused intent changed the session")
	assert_eq(trade.drain_events().size(), 0, "or recorded an event")
	# A player that is no party of the session can do nothing in it.
	assert_eq(trade.set_offer(world, carol.player_id, session_id, carols, 1).reason, TradeService.REASON_NOT_IN_SESSION)
	assert_eq(trade.set_confirmed(world, carol.player_id, session_id, session.revision, true).reason, TradeService.REASON_NOT_IN_SESSION)
	assert_eq(trade.set_confirmed(world, carol.player_id, session_id, session.revision, false).reason, TradeService.REASON_NOT_IN_SESSION)
	assert_eq(trade.cancel(world, carol.player_id, session_id).reason, TradeService.REASON_NOT_IN_SESSION)
	assert_eq(trade.accept(world, carol.player_id, session_id).reason, TradeService.REASON_NO_SUCH_REQUEST)
	assert_eq(trade.set_offer(world, MISSING_PLAYER_ID, session_id, food, 1).reason, TradeService.REASON_NOT_IN_SESSION)
	# A party naming another session than its own does nothing either.
	assert_eq(trade.set_offer(world, alice.player_id, session_id + 1, food, 1).reason, TradeService.REASON_NOT_IN_SESSION)
	assert_eq(trade.set_confirmed(world, alice.player_id, MISSING_SESSION_ID, session.revision, true).reason, TradeService.REASON_NOT_IN_SESSION)
	assert_eq(trade.cancel(world, bob.player_id, 0).reason, TradeService.REASON_NOT_IN_SESSION)
	assert_eq(JSON.stringify(session.to_dict()), before)
	assert_false(session.confirmed[alice.player_id] or session.confirmed[bob.player_id])
	# An open session is not a request any more.
	assert_eq(trade.accept(world, bob.player_id, session_id).reason, TradeService.REASON_NO_SUCH_REQUEST)
	# The number of stacks in an offer is bounded.
	assert_true(trade.set_offer(world, alice.player_id, session_id, food, 1).ok)
	assert_true(trade.set_offer(world, alice.player_id, session_id, plain, 1).ok)
	assert_eq(trade.set_offer(world, alice.player_id, session_id, bulk_a, 1).reason, TradeService.REASON_OFFER_FULL)
	assert_true(trade.set_offer(world, alice.player_id, session_id, food, 3).ok, "changing a stack that is already offered is not one more")
	assert_true(trade.set_offer(world, alice.player_id, session_id, plain, 0).ok)
	assert_true(trade.set_offer(world, alice.player_id, session_id, bulk_a, 1).ok, "room again")
	assert_eq(_rows(world, alice), [[FOOD, 3], [PLAIN, 1], [BULK, 2]], "no offer moved anything")
	assert_eq(_rows(world, bob), [[BULK, 6]])


func test_offers_follow_what_the_inventory_holds() -> void:
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 3)
	var plain: String = _give(world, alice, PLAIN)
	var bulk: String = _give(world, bob, BULK, 6)
	var session_id: int = _open(world, alice, bob)
	var session: TradeSession = trade.session_of(alice.player_id)
	assert_true(trade.set_offer(world, alice.player_id, session_id, food, 3).ok)
	assert_true(trade.set_offer(world, alice.player_id, session_id, plain, 1).ok)
	assert_true(trade.set_offer(world, bob.player_id, session_id, bulk, 2).ok)
	assert_true(trade.set_confirmed(world, bob.player_id, session_id, 3, true).ok, "bob agrees to 3 food and the single item")
	trade.drain_events()

	# Alice eats one of the offered food: her offer follows her inventory and
	# bob's confirmation of the old offer is gone.
	assert_true(ItemConsumption.try_consume(world, alice.player_id, food).ok)
	assert_eq(session.offers[alice.player_id][0], {"item_instance_id": food, "definition_id": FOOD, "quantity": 2}, "the offer cannot name more than is carried")
	assert_false(session.confirmed[bob.player_id], "what bob confirmed is not what is offered any more")
	assert_eq(session.revision, 4)
	assert_eq(_changes(trade.drain_events()), [TradeService.CHANGE_OFFER_ADJUSTED])
	assert_eq(trade.set_confirmed(world, bob.player_id, session_id, 3, true).reason, TradeService.REASON_STALE_OFFER)
	# She puts the single item down: it leaves the offer.
	assert_true(world.try_drop_item(alice.player_id, plain).ok)
	assert_eq(session.offers[alice.player_id], [{"item_instance_id": food, "definition_id": FOOD, "quantity": 2}])
	assert_eq(session.revision, 5)
	# A stack that only grows, and a change of something that is not offered,
	# adjust nothing.
	trade.drain_events()
	var more: String = world.inventory.spawn_world_item(BULK, 2, DevWorldSeed.DEV_CELL_ID, bob.position)
	assert_true(world.try_pickup(bob.player_id, more).ok, "it joins bob's offered stack")
	assert_eq(world.inventory.get_item(bulk).quantity, 8)
	assert_eq(session.revision, 5)
	assert_eq(trade.drain_events().size(), 0)
	# The trade then exchanges what is offered now.
	assert_true(trade.set_confirmed(world, alice.player_id, session_id, 5, true).ok)
	var done: ActionResult = trade.set_confirmed(world, bob.player_id, session_id, 5, true)
	assert_true(done.ok, done.reason)
	assert_eq(_rows(world, alice), [[BULK, 2]])
	assert_eq(_rows(world, bob), [[BULK, 6], [FOOD, 2]])


func test_an_exchange_that_does_not_fit_moves_nothing_and_keeps_the_session_open() -> void:
	_gameplay.inventory_slot_capacity = 2
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var food: String = _give(world, alice, FOOD, 4)
	var bobs_plain: String = _give(world, bob, PLAIN)
	var bulk: String = _give(world, bob, BULK, 6)
	var session_id: int = _open(world, alice, bob)
	var session: TradeSession = trade.session_of(alice.player_id)
	# Bob gives a part of his stack (his slots stay in use) and would get a
	# part of alice's food: no slot for it.
	assert_true(trade.set_offer(world, alice.player_id, session_id, food, 2).ok)
	assert_true(trade.set_offer(world, bob.player_id, session_id, bulk, 3).ok)
	assert_true(trade.set_confirmed(world, bob.player_id, session_id, 2, true).ok)
	var before: String = JSON.stringify(world.inventory.to_snapshot())
	trade.drain_events()
	var refused: ActionResult = trade.set_confirmed(world, alice.player_id, session_id, 2, true)
	assert_eq(refused.reason, TradeService.REASON_OTHER_INVENTORY_FULL, "alice is told that bob has no room")
	assert_eq(JSON.stringify(world.inventory.to_snapshot()), before, "nothing moved, on either side")
	assert_eq(session.phase, TradeSession.PHASE_OPEN, "the session stays open")
	assert_false(session.confirmed[alice.player_id] or session.confirmed[bob.player_id], "both have to confirm again")
	assert_eq(session.revision, 2, "the offers are what they were")
	var events: Array[Dictionary] = trade.drain_events()
	assert_eq(_changes(events), [TradeService.CHANGE_EXCHANGE_FAILED])
	assert_eq((events[0]["session"] as Dictionary).get("cause", ""), TradeService.CAUSE_INVENTORY_FULL)
	assert_eq((events[0]["session"] as Dictionary).get("by_player_id", ""), bob.player_id, "whose inventory has no room")
	# The same seen from bob's side: his own inventory is full.
	assert_true(trade.set_confirmed(world, alice.player_id, session_id, 2, true).ok)
	assert_eq(trade.set_confirmed(world, bob.player_id, session_id, 2, true).reason, TradeService.REASON_INVENTORY_FULL)
	assert_eq(JSON.stringify(world.inventory.to_snapshot()), before)
	# Bob makes room; both confirm again and the trade completes.
	assert_true(world.try_drop_item(bob.player_id, bobs_plain).ok)
	assert_true(trade.set_confirmed(world, bob.player_id, session_id, 2, true).ok)
	var done: ActionResult = trade.set_confirmed(world, alice.player_id, session_id, 2, true)
	assert_true(done.ok, done.reason)
	assert_eq(_rows(world, alice), [[FOOD, 2], [BULK, 3]])
	assert_eq(_rows(world, bob), [[FOOD, 2], [BULK, 3]])


# ------------------------------------------------------------ save round trip

func test_a_completed_trade_survives_a_save_round_trip_and_sessions_do_not() -> void:
	var world: ServerWorld = _world()
	var trade: TradeService = _service(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	var food: String = _give(world, alice, FOOD, 4)
	var bulk: String = _give(world, bob, BULK, 6)
	var bobs_food: String = _give(world, bob, FOOD, 4)
	var session_id: int = _open(world, alice, bob)
	assert_true(trade.set_offer(world, alice.player_id, session_id, food, 3).ok)
	assert_true(trade.set_offer(world, bob.player_id, session_id, bulk, 6).ok)
	assert_true(trade.set_confirmed(world, alice.player_id, session_id, 2, true).ok)
	assert_true(trade.set_confirmed(world, bob.player_id, session_id, 2, true).ok)
	var alice_rows: Array = _rows(world, alice)
	var bob_rows: Array = _rows(world, bob)
	assert_eq(alice_rows, [[FOOD, 1], [BULK, 6]])
	assert_eq(bob_rows, [[FOOD, 2], [FOOD, FOOD_MAX]], "one of alice's three filled bob's stack, two took the slot his bulk left")
	# A session that is open while the world is saved.
	assert_true(_open(world, alice, carol) > 0)

	# Save documents -> JSON -> a brand-new world.
	var documents: Dictionary = JSON.parse_string(JSON.stringify(world.to_documents())) as Dictionary
	var restored: ServerWorld = _world()
	var errors: PackedStringArray = restored.restore_documents(documents["world_state"], documents["players"])
	assert_eq(errors.size(), 0, "; ".join(errors))
	assert_eq(JSON.stringify(restored.inventory.to_snapshot()), JSON.stringify(world.inventory.to_snapshot()), "the same items, ids, slots and quantities")
	assert_eq(_rows(restored, alice), alice_rows)
	assert_eq(_rows(restored, bob), bob_rows)
	assert_eq(restored.inventory.get_item(bulk).location_id, alice.inventory_id, "the moved instance kept its id")
	assert_eq(restored.inventory.get_item(bobs_food).quantity, FOOD_MAX)
	var restored_trade: TradeService = _service(restored)
	assert_eq(restored_trade.session_count(), 0, "no session survives a restart")
	# The game goes on in the restored world: the same two trade again.
	var alice_again: PlayerState = restored.join("alice")
	var bob_again: PlayerState = restored.join("bob")
	var again: int = _open(restored, alice_again, bob_again)
	assert_true(restored_trade.set_offer(restored, alice_again.player_id, again, bulk, 6).ok)
	assert_true(restored_trade.set_confirmed(restored, alice_again.player_id, again, 1, true).ok)
	assert_true(restored_trade.set_confirmed(restored, bob_again.player_id, again, 1, true).ok)
	assert_eq(_rows(restored, alice), [[FOOD, 1]])
	assert_eq(_rows(restored, bob), [[FOOD, 2], [FOOD, FOOD_MAX], [BULK, 6]])
