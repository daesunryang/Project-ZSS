extends TestCase
## P2-T9 (docs/00 ADR-015): the character state model on the server, no
## network. A connected player without a character is not in the world: it
## cannot act, its needs do not run, zombies ignore it and nobody sees it.
## Creating a character puts it at the spawn point. After a death the next
## character starts when the player creates it (once the delay has passed),
## not by itself. Also: the compatible default (no creation required),
## duplicate names, saving and the player file migration.

const WORLD: String = "character_creation_test_world"
const SINGLE: String = "t9_single"
const CELL: String = DevWorldSeed.DEV_CELL_ID
const SPAWN_AT: Vector3 = Vector3(1.0, 0.0, 2.0)
const DEATH_AT: Vector3 = Vector3(12.5, 0.0, -7.0)
const FAR_AWAY: Vector3 = Vector3(200.0, 0.0, 200.0)
const DELAY_SEC: float = 5.0
const TICK: float = 0.1
const INPUT_TIMEOUT_MSEC: int = 1000
const LETHAL_DAMAGE: float = 100000.0

var _survival_settings: SurvivalSettings = null
var _gameplay: GameplaySettings = null
var _character: CharacterSettings = null
var _root: String = ""
var _sequence: int = 0


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = ""
	_sequence = 0
	_survival_settings = SurvivalSettings.new()
	_survival_settings.respawn_delay_sec = DELAY_SEC
	_gameplay = GameplaySettings.new()
	_gameplay.player_spawn_position = SPAWN_AT
	_character = CharacterSettings.new()


func after_each() -> void:
	if not _root.is_empty():
		SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _config(require_creation: bool) -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.survival = _survival_settings
	config.gameplay = _gameplay
	config.character = _character
	var catalog: ItemCatalog = ItemCatalog.new()
	var single: ItemDefinition = ItemDefinition.new()
	single.definition_id = SINGLE
	catalog.add(single)
	config.catalog = catalog
	config.dev_seed = DevWorldSeed.new()
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.require_character_creation = require_creation
	return config


## A world that asks every player to create its character (what a dedicated
## server runs).
func _strict_world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config(true))


## A world with the compatible default: join() gives a default character.
func _lenient_world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config(false))


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _noise(world: ServerWorld) -> NoiseService:
	return world.get_system(NoiseService.SYSTEM_ID) as NoiseService


func _combat(world: ServerWorld) -> CombatService:
	return world.get_system(CombatService.SYSTEM_ID) as CombatService


func _look(overrides: Dictionary = {}) -> Dictionary:
	var selection: Dictionary = {"top_color": "red", "hair_style": "ponytail", "height": "tall"}
	selection.merge(overrides, true)
	return selection


func _create(world: ServerWorld, player_id: String, character_name: String = "Rick Grimes", selection: Variant = null) -> ActionResult:
	return world.create_character(player_id, character_name, _look() if selection == null else selection)


func _kill(world: ServerWorld, player_id: String) -> void:
	var result: ActionResult = _survival(world).apply_damage(player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE))
	if not result.ok:
		fail("test setup: kill failed: " + result.reason)


## Advances the world by `seconds` of real (action) time in fixed ticks.
func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


## The player holds "forward" for `seconds`. Returns the reason the last
## move intent was refused ("" = accepted).
func _walk(world: ServerWorld, player_id: String, seconds: float) -> String:
	var reason: String = ""
	for tick: int in range(roundi(seconds / TICK)):
		_sequence += 1
		reason = world.set_move_input(player_id, _sequence, Vector2(1.0, 0.0), 0.0, 0)
		world.step_movement(TICK, 0, INPUT_TIMEOUT_MSEC)
		world.step_systems(TICK)
	return reason


func _events_of(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			matching.append(event)
	return matching


func _last_fatal_line() -> String:
	var lines: PackedStringArray = GameLogger.captured_lines()
	for index: int in range(lines.size() - 1, -1, -1):
		if lines[index].contains("[FATAL]") or lines[index].contains("[ERROR]"):
			return lines[index]
	return ""


# ------------------------------------------------------------ joining

func test_without_required_creation_join_gives_a_default_character() -> void:
	var world: ServerWorld = _lenient_world()
	assert_false(world.require_character_creation)
	var alice: PlayerState = world.join("alice")
	assert_not_null(alice)
	assert_true(alice.has_character(), "a default character exists at once")
	assert_true(world.has_character(alice.player_id))
	assert_true(world.is_online(alice.player_id), "and it is in the world")
	assert_true(world.is_player_connected(alice.player_id))
	assert_eq(alice.character.name, _character.default_name)
	assert_eq(alice.character.appearance, world.character_rules.catalog.default_selection())
	assert_eq(alice.character_generation, PlayerState.FIRST_CHARACTER_GENERATION)
	assert_true(_survival(world).is_alive(alice.player_id))
	assert_eq(world.character_creation_block_reason(alice.player_id), SurvivalService.REASON_CHARACTER_ALIVE)


func test_with_required_creation_a_new_player_is_connected_but_not_in_the_world() -> void:
	var world: ServerWorld = _strict_world()
	assert_true(world.require_character_creation)
	var alice: PlayerState = world.join("alice")
	assert_not_null(alice, "the connection is accepted")
	assert_false(alice.has_character())
	assert_null(alice.character)
	assert_false(world.has_character(alice.player_id))
	assert_true(world.is_player_connected(alice.player_id))
	assert_false(world.is_online(alice.player_id), "not in the world")
	assert_eq(Array(world.online_player_ids()), [], "nobody who looks at the world sees it")
	assert_eq(Array(world.connected_player_ids()), [alice.player_id])
	assert_eq(alice.character_generation, PlayerState.FIRST_CHARACTER_GENERATION, "its first character is still to come")
	assert_false(_survival(world).has_player(alice.player_id), "no vitals without a character")
	assert_eq(world.character_creation_block_reason(alice.player_id), "", "it may create a character")
	# The same key cannot connect twice.
	assert_null(world.join("alice"))
	assert_eq(world.known_player_count(), 1)


# ------------------------------------------------------------ a player without a character

func test_a_player_without_a_character_cannot_act() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	var item_id: String = world.inventory.spawn_world_item(SINGLE, 1, CELL, SPAWN_AT)
	var before: Vector3 = alice.position
	assert_eq(_walk(world, alice.player_id, 1.0), ServerWorld.REASON_NOT_ONLINE, "a move intent is refused")
	assert_eq(alice.position, before, "and nothing moved")
	assert_eq(world.try_pickup(alice.player_id, item_id).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_eq(world.try_drop_item(alice.player_id, item_id).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_eq(_combat(world).request_melee_attack(world, alice.player_id, 0.0).reason, CombatService.REASON_NOT_ONLINE)
	assert_eq(ItemConsumption.try_consume(world, alice.player_id, item_id).reason, ServerWorld.REASON_NOT_ONLINE)
	assert_false(_survival(world).start_rest(alice.player_id).ok, "it cannot lie down")
	assert_false(_survival(world).is_resting(alice.player_id))
	assert_eq(world.inventory.items_in_inventory(alice.inventory_id).size(), 0)
	assert_eq(world.inventory.get_item(item_id).location_type, ItemInstance.LOCATION_WORLD)
	# After the character exists the same requests work.
	assert_true(_create(world, alice.player_id).ok)
	assert_eq(_walk(world, alice.player_id, 1.0), "")
	assert_true(alice.position.distance_to(before) > 1.0, "the character walks")
	alice.position = SPAWN_AT
	assert_true(world.try_pickup(alice.player_id, item_id).ok)
	assert_true(world.try_drop_item(alice.player_id, item_id).ok)
	assert_true(_combat(world).request_melee_attack(world, alice.player_id, 0.0).ok)
	assert_true(_survival(world).start_rest(alice.player_id).ok)


func test_needs_do_not_run_before_the_character_exists() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	# Somebody else is in the world, so the clock runs.
	var bob: PlayerState = world.join("bob")
	assert_true(_create(world, bob.player_id, "Bob").ok)
	_run(world, 60.0)
	var survival: SurvivalService = _survival(world)
	assert_true(survival.get_vitals(bob.player_id).hunger > 0.0, "bob got hungry meanwhile")
	assert_null(survival.get_vitals(alice.player_id), "alice has no needs yet")
	assert_true(_create(world, alice.player_id).ok)
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_not_null(vitals)
	assert_eq(vitals.hunger, 0.0, "the character starts fresh, however long the player waited")
	assert_eq(vitals.thirst, 0.0)
	assert_eq(vitals.fatigue, 0.0)
	_run(world, 60.0)
	assert_true(vitals.hunger > 0.0, "now its needs run")


func test_the_world_clock_does_not_run_for_players_without_a_character() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	_run(world, 5.0)
	assert_eq(world.clock.world_time_sec, 0.0, "only somebody in the world keeps the clock running")
	assert_eq(world.clock.action_time_sec, 0.0)
	assert_true(_create(world, alice.player_id).ok)
	_run(world, 5.0)
	assert_true(world.clock.action_time_sec > 4.9)


func test_zombies_ignore_a_player_without_a_character() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	assert_true(_create(world, bob.player_id, "Bob").ok)
	bob.position = FAR_AWAY
	var zombies: ZombieService = _zombies(world)
	# Three metres from the spawn point, looking at it (yaw 0 faces -Z).
	var spawned: ActionResult = zombies.spawn_zombie(world, SPAWN_AT + Vector3(0.0, 0.0, 3.0), 0.0)
	assert_true(spawned.ok, spawned.reason)
	var zombie: ZombieState = zombies.get_zombie(zombies.zombie_ids()[0])
	_run(world, 6.0)
	assert_eq(zombie.target_player_id, "", "nobody is there for the zombie")
	assert_eq(_events_of(zombies.drain_events(), ZombieService.EVENT_ATTACKED).size(), 0)
	assert_eq(alice.position, SPAWN_AT)
	# The character appears where the zombie is looking.
	assert_true(_create(world, alice.player_id).ok)
	var survival: SurvivalService = _survival(world)
	var hurt: bool = false
	for tick: int in range(roundi(20.0 / TICK)):
		world.step_systems(TICK)
		if zombie.target_player_id == alice.player_id or survival.get_vitals(alice.player_id).health < _survival_settings.max_health:
			hurt = true
			break
	assert_true(hurt, "the zombie goes for the new character")


func test_a_player_without_a_character_makes_no_footsteps() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	assert_true(_create(world, bob.player_id, "Bob").ok)
	bob.position = FAR_AWAY
	_walk(world, alice.player_id, 3.0)
	assert_eq(_noise(world).active_count(), 0, "no character, no steps")
	assert_true(_create(world, alice.player_id).ok)
	_walk(world, alice.player_id, 3.0)
	assert_true(_noise(world).active_count() > 0, "a walking character is heard")


# ------------------------------------------------------------ creating the first character

func test_creating_a_character_puts_the_player_in_the_world() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	alice.position = DEATH_AT  # wherever the state was, a character starts at the spawn point
	var result: ActionResult = world.create_character(alice.player_id, "  Rick   Grimes ", {"top_color": "red"})
	assert_true(result.ok, result.reason)
	assert_true(alice.has_character())
	assert_eq(alice.character.name, "Rick Grimes", "the cleaned name")
	var expected: Dictionary = world.character_rules.catalog.default_selection()
	expected["top_color"] = "red"
	assert_eq(alice.character.appearance, expected, "what was not chosen is the default")
	assert_eq(alice.character_generation, 1)
	assert_eq(alice.position, SPAWN_AT)
	assert_true(world.is_online(alice.player_id))
	assert_eq(Array(world.online_player_ids()), [alice.player_id])
	assert_true(_survival(world).is_alive(alice.player_id))
	var event: Dictionary = result.event
	assert_eq(event.get("event_type", ""), ServerWorld.EVENT_CHARACTER_CREATED)
	assert_eq(event.get("player_id", ""), alice.player_id)
	assert_eq(event.get("character_generation", 0), 1)
	assert_eq(event.get("name", ""), "Rick Grimes")
	assert_eq(event.get("appearance", {}), expected)
	assert_eq(event.get("first_character", false), true)
	assert_eq(event.get("position", []), [SPAWN_AT.x, SPAWN_AT.y, SPAWN_AT.z])
	assert_true(SaveService.is_json_safe(event), "the event is JSON-safe")
	# No "respawn": this is the first character.
	assert_eq(_events_of(_survival(world).drain_events(), SurvivalService.EVENT_PLAYER_RESPAWNED).size(), 0)
	assert_eq(world.character_creation_block_reason(alice.player_id), SurvivalService.REASON_CHARACTER_ALIVE)


func test_a_living_character_cannot_be_replaced() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	assert_true(_create(world, alice.player_id, "First").ok)
	alice.position = DEATH_AT
	var before: Dictionary = alice.to_dict()
	var again: ActionResult = _create(world, alice.player_id, "Second", {"top_color": "green"})
	assert_false(again.ok)
	assert_eq(again.reason, SurvivalService.REASON_CHARACTER_ALIVE)
	assert_eq(alice.to_dict(), before, "nothing changed")
	assert_eq(alice.character.name, "First")
	# Changing the look of a living character is not a feature (docs/15 P2-166).
	assert_eq(world.create_character(alice.player_id, "First", {"top_color": "green"}).reason, SurvivalService.REASON_CHARACTER_ALIVE)


func test_refused_requests_change_nothing() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	var before: Dictionary = alice.to_dict()
	var huge_appearance: Dictionary = {}
	for index: int in range(3000):
		huge_appearance["slot_%d" % index] = "x"
	var cases: Array[Array] = [
		["a", {}, CharacterNameRules.REASON_TOO_SHORT],
		["", {}, CharacterNameRules.REASON_EMPTY],
		["x".repeat(_character.name_max_length + 1), {}, CharacterNameRules.REASON_TOO_LONG],
		["x".repeat(100000), {}, CharacterNameRules.REASON_TOO_LONG],
		["al!ce", {}, CharacterNameRules.REASON_BAD_CHARACTERS],
		["al\nice", {}, CharacterNameRules.REASON_BAD_CHARACTERS],
		["alice", {"tail": "long"}, AppearanceCatalog.REASON_UNKNOWN_SLOT],
		["alice", {"top_color": "ultraviolet"}, AppearanceCatalog.REASON_UNKNOWN_OPTION],
		["alice", {"top_color": Color.RED}, AppearanceCatalog.REASON_BAD_TYPE],
		["alice", huge_appearance, AppearanceCatalog.REASON_TOO_LARGE],
		[42, {}, CharacterRules.REASON_BAD_TYPE],
		[null, {}, CharacterRules.REASON_BAD_TYPE],
		["alice", null, CharacterRules.REASON_BAD_TYPE],
		["alice", ["top_color", "red"], CharacterRules.REASON_BAD_TYPE],
	]
	for row: Array in cases:
		var result: ActionResult = world.create_character(alice.player_id, row[0], row[1])
		assert_false(result.ok, "refused: %s" % str(row[0]).left(20))
		assert_eq(result.reason, row[2], "name %s" % str(row[0]).left(20))
	assert_eq(alice.to_dict(), before, "the player is untouched")
	assert_false(world.is_online(alice.player_id))
	assert_false(_survival(world).has_player(alice.player_id))
	# Who is not connected cannot create anything.
	assert_eq(world.create_character("player_999999", "alice", {}).reason, ServerWorld.REASON_UNKNOWN_PLAYER)
	world.leave(alice.player_id)
	assert_eq(world.create_character(alice.player_id, "alice", {}).reason, ServerWorld.REASON_NOT_CONNECTED)
	assert_eq(world.character_creation_block_reason(alice.player_id), ServerWorld.REASON_NOT_CONNECTED)
	assert_eq(world.character_creation_block_reason("player_999999"), ServerWorld.REASON_UNKNOWN_PLAYER)
	assert_false(alice.has_character())


# ------------------------------------------------------------ after a death

func test_after_a_death_the_next_character_waits_for_the_player() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	assert_true(_create(world, alice.player_id, "First One", {"top_color": "red"}).ok)
	var item_id: String = world.inventory.spawn_world_item(SINGLE, 1, CELL, SPAWN_AT)
	assert_true(world.try_pickup(alice.player_id, item_id).ok)
	alice.position = DEATH_AT
	var survival: SurvivalService = _survival(world)
	_kill(world, alice.player_id)
	survival.drain_events()
	assert_eq(world.inventory.get_item(item_id).location_type, ItemInstance.LOCATION_WORLD, "the belongings were left at once")

	# Too early.
	_run(world, DELAY_SEC - 1.0)
	assert_eq(world.character_creation_block_reason(alice.player_id), SurvivalService.REASON_RESPAWN_WAIT)
	var early: ActionResult = _create(world, alice.player_id, "Second One")
	assert_eq(early.reason, SurvivalService.REASON_RESPAWN_WAIT)
	assert_false(survival.is_alive(alice.player_id))
	assert_eq(alice.character.name, "First One")

	# The delay passes, and much more: nothing starts by itself.
	_run(world, 1.0 + 30.0)
	assert_false(survival.is_alive(alice.player_id), "still dead: the player has not created the next character")
	assert_eq(alice.character_generation, 1)
	assert_eq(alice.position, DEATH_AT, "the dead character stays where it died")
	assert_eq(alice.character.name, "First One")
	assert_true(world.is_online(alice.player_id), "a dead character is still in the world")
	assert_eq(_events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_RESPAWNED).size(), 0)
	assert_eq(world.character_creation_block_reason(alice.player_id), "", "now it may")
	# A dead character still cannot act.
	assert_eq(world.try_pickup(alice.player_id, item_id).reason, SurvivalService.REASON_PLAYER_DEAD)

	var result: ActionResult = world.create_character(alice.player_id, "Second One", {"top_color": "green", "hair_style": "bald"})
	assert_true(result.ok, result.reason)
	assert_true(survival.is_alive(alice.player_id))
	assert_eq(alice.character_generation, 2, "the generation goes up")
	assert_eq(alice.character.name, "Second One")
	assert_eq(alice.character.appearance["top_color"], "green")
	assert_eq(alice.character.appearance["hair_style"], "bald")
	assert_eq(alice.position, SPAWN_AT)
	assert_eq(world.inventory.items_in_inventory(alice.inventory_id).size(), 0, "the new character starts empty")
	assert_eq(world.inventory.get_item(item_id).location_type, ItemInstance.LOCATION_WORLD)
	var vitals: PlayerVitals = survival.get_vitals(alice.player_id)
	assert_eq(vitals.health, _survival_settings.max_health)
	assert_eq(vitals.injuries.size(), 0)
	assert_eq(result.event.get("event_type", ""), ServerWorld.EVENT_CHARACTER_CREATED)
	assert_eq(result.event.get("first_character", true), false)
	assert_eq(result.event.get("character_generation", 0), 2)
	assert_eq(result.event.get("name", ""), "Second One")
	var respawned: Array[Dictionary] = _events_of(survival.drain_events(), SurvivalService.EVENT_PLAYER_RESPAWNED)
	assert_eq(respawned.size(), 1, "the existing event of a new character")
	assert_eq(respawned[0].get("character_generation", 0), 2)
	assert_eq(respawned[0].get("position", []), [SPAWN_AT.x, SPAWN_AT.y, SPAWN_AT.z])
	assert_eq(world.character_creation_block_reason(alice.player_id), SurvivalService.REASON_CHARACTER_ALIVE)
	# One death, one new character.
	_run(world, DELAY_SEC * 3.0)
	assert_eq(alice.character_generation, 2)


func test_a_dead_player_who_left_can_create_the_next_character_after_rejoining() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	assert_true(_create(world, alice.player_id, "First One").ok)
	assert_true(_create(world, bob.player_id, "Bob").ok)
	_kill(world, alice.player_id)
	world.leave(alice.player_id)
	_run(world, DELAY_SEC * 2.0)
	assert_eq(world.character_creation_block_reason(alice.player_id), ServerWorld.REASON_NOT_CONNECTED)
	assert_not_null(world.join("alice"))
	assert_true(world.is_online(alice.player_id), "the dead character is back in the world")
	assert_false(_survival(world).is_alive(alice.player_id))
	assert_eq(world.character_creation_block_reason(alice.player_id), "", "the delay passed while it was away")
	assert_true(_create(world, alice.player_id, "Second One").ok)
	assert_eq(alice.character_generation, 2)
	assert_true(_survival(world).is_alive(alice.player_id))


func test_without_required_creation_the_next_character_starts_by_itself_and_keeps_the_profile() -> void:
	var world: ServerWorld = _lenient_world()
	var alice: PlayerState = world.join("alice")
	alice.character = CharacterProfile.create("Given Name", world.character_rules.catalog.check_selection({"top_color": "purple"}).event["appearance"])
	_kill(world, alice.player_id)
	_run(world, DELAY_SEC - 1.0)
	assert_false(_survival(world).is_alive(alice.player_id))
	assert_eq(_create(world, alice.player_id, "Other").reason, SurvivalService.REASON_RESPAWN_WAIT)
	_run(world, 1.0 + 2.0 * TICK)
	assert_true(_survival(world).is_alive(alice.player_id), "started by itself")
	assert_eq(alice.character_generation, 2)
	assert_eq(alice.character.name, "Given Name", "nobody chose again: the profile carries over")
	assert_eq(alice.character.appearance["top_color"], "purple")
	assert_eq(alice.position, SPAWN_AT)


# ------------------------------------------------------------ names of other characters

func test_duplicate_names_are_allowed_by_default() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	assert_true(_character.allow_duplicate_names)
	assert_true(_create(world, alice.player_id, "Survivor").ok)
	assert_true(_create(world, bob.player_id, "Survivor").ok)
	assert_eq(bob.character.name, "Survivor")


func test_duplicate_names_can_be_refused_by_configuration() -> void:
	_character.allow_duplicate_names = false
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	assert_true(_create(world, alice.player_id, "Rick Grimes").ok)
	assert_eq(_create(world, bob.player_id, "Rick Grimes").reason, ServerWorld.REASON_NAME_TAKEN)
	assert_eq(_create(world, bob.player_id, "rick grimes").reason, ServerWorld.REASON_NAME_TAKEN, "case does not make a different name")
	assert_false(bob.has_character())
	assert_true(_create(world, bob.player_id, "Daryl").ok)
	# The name of a character whose player is away is still taken.
	world.leave(alice.player_id)
	assert_eq(_create(world, carol.player_id, "Rick Grimes").reason, ServerWorld.REASON_NAME_TAKEN)
	# A player may give its next character the name of its last one.
	_kill(world, bob.player_id)
	_run(world, DELAY_SEC + 1.0)
	assert_eq(_create(world, bob.player_id, "Rick Grimes").reason, ServerWorld.REASON_NAME_TAKEN)
	assert_true(_create(world, bob.player_id, "Daryl").ok)
	assert_eq(bob.character_generation, 2)


# ------------------------------------------------------------ leaving and coming back

func test_a_player_that_left_without_a_character_comes_back_without_one() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	world.leave(alice.player_id)
	assert_false(world.is_player_connected(alice.player_id))
	var again: PlayerState = world.join("alice")
	assert_eq(again.player_id, alice.player_id, "the same player")
	assert_false(again.has_character())
	assert_false(world.is_online(alice.player_id))
	assert_true(_create(world, alice.player_id).ok)
	assert_eq(alice.character_generation, 1)


func test_a_player_with_a_character_is_in_the_world_as_soon_as_it_comes_back() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	assert_true(_create(world, alice.player_id, "Rick Grimes").ok)
	alice.position = DEATH_AT
	world.leave(alice.player_id)
	assert_false(world.is_online(alice.player_id))
	assert_false(world.is_player_connected(alice.player_id))
	world.join("alice")
	assert_true(world.is_online(alice.player_id), "no creation needed: the character exists")
	assert_eq(alice.character.name, "Rick Grimes")
	assert_eq(alice.position, DEATH_AT, "where it was")
	assert_eq(alice.character_generation, 1)


# ------------------------------------------------------------ saving

func test_name_appearance_and_generation_survive_save_and_restart() -> void:
	_root = "user://test_saves/character_creation_%d" % Time.get_ticks_usec()
	var config: CompositionConfig = _config(true)
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), config)
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var carol: PlayerState = world.join("carol")
	assert_true(_create(world, alice.player_id, "First One").ok)
	assert_true(_create(world, bob.player_id, "김철수", {"top_color": "navy", "body_type": "heavy"}).ok)
	# Alice is on her second character; carol never created one.
	_kill(world, alice.player_id)
	_run(world, DELAY_SEC + 1.0)
	assert_true(world.create_character(alice.player_id, "Second One", {"hair_color": "red", "height": "very_tall"}).ok)
	var alice_look: Dictionary = alice.character.appearance.duplicate()
	var bob_look: Dictionary = bob.character.appearance.duplicate()
	for player_id: String in [alice.player_id, bob.player_id, carol.player_id]:
		world.leave(player_id)
	assert_eq(persistence.save(world), OK)

	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	assert_not_null(restored, "the save loads: %s" % _last_fatal_line())
	if restored == null:
		return
	var restored_alice: PlayerState = restored.get_player(alice.player_id)
	var restored_bob: PlayerState = restored.get_player(bob.player_id)
	var restored_carol: PlayerState = restored.get_player(carol.player_id)
	assert_eq(restored_alice.character.name, "Second One")
	assert_eq(restored_alice.character.appearance, alice_look)
	assert_eq(restored_alice.character_generation, 2)
	assert_eq(restored_bob.character.name, "김철수")
	assert_eq(restored_bob.character.appearance, bob_look)
	assert_eq(restored_bob.character.appearance["top_color"], "navy")
	assert_eq(restored_bob.character_generation, 1)
	assert_false(restored_carol.has_character(), "no character was saved for carol")
	# Back online: alice and bob are in the world at once, carol still has to create.
	restored.join("alice")
	restored.join("bob")
	restored.join("carol")
	assert_true(restored.is_online(alice.player_id))
	assert_true(restored.is_online(bob.player_id))
	assert_false(restored.is_online(carol.player_id))
	assert_eq(restored.character_creation_block_reason(carol.player_id), "")
	assert_true(_create(restored, carol.player_id, "Carol").ok)
	assert_eq(restored_carol.character_generation, 1)


func test_a_dead_character_is_saved_and_the_next_one_is_created_after_the_restart() -> void:
	var world: ServerWorld = _strict_world()
	var alice: PlayerState = world.join("alice")
	assert_true(_create(world, alice.player_id, "First One").ok)
	_kill(world, alice.player_id)
	_run(world, 1.0)
	world.leave(alice.player_id)
	var documents: Dictionary = world.to_documents()

	var restored: ServerWorld = _strict_world()
	var errors: PackedStringArray = restored.restore_documents(documents["world_state"], documents["players"])
	assert_eq(errors.size(), 0, "; ".join(errors))
	restored.join("alice")
	assert_false(_survival(restored).is_alive(alice.player_id))
	assert_eq(restored.get_player(alice.player_id).character.name, "First One")
	assert_eq(restored.character_creation_block_reason(alice.player_id), SurvivalService.REASON_RESPAWN_WAIT, "the rest of the delay still runs")
	_run(restored, DELAY_SEC)
	assert_eq(restored.character_creation_block_reason(alice.player_id), "")
	assert_true(_create(restored, alice.player_id, "Second One").ok)
	assert_eq(restored.get_player(alice.player_id).character_generation, 2)


func test_a_world_without_required_creation_gives_a_saved_characterless_player_a_default() -> void:
	var strict: ServerWorld = _strict_world()
	var alice: PlayerState = strict.join("alice")
	strict.leave(alice.player_id)
	var documents: Dictionary = strict.to_documents()
	var lenient: ServerWorld = _lenient_world()
	assert_eq(lenient.restore_documents(documents["world_state"], documents["players"]).size(), 0)
	assert_false(lenient.get_player(alice.player_id).has_character())
	lenient.join("alice")
	assert_true(lenient.get_player(alice.player_id).has_character())
	assert_true(lenient.is_online(alice.player_id))
	assert_eq(lenient.get_player(alice.player_id).character.name, _character.default_name)


func test_the_player_file_carries_the_character_and_older_files_are_migrated() -> void:
	var state: PlayerState = PlayerState.new()
	state.player_id = "player_000001"
	state.player_key = "alice"
	state.inventory_id = "inventory_000002"
	assert_null(state.character, "a new player state has no character")
	assert_eq(PlayerState.SCHEMA_VERSION, 4)
	assert_eq(SaveMigrations.PLAYER_SCHEMA_VERSION, PlayerState.SCHEMA_VERSION)
	var without: Dictionary = state.to_dict()
	assert_true(without.has(PlayerState.KEY_CHARACTER))
	assert_null(without[PlayerState.KEY_CHARACTER])
	assert_true(SaveService.is_json_safe(without))
	assert_eq(PlayerState.validate_dict(without).size(), 0, "; ".join(PlayerState.validate_dict(without)))
	assert_false(PlayerState.from_dict(without).has_character())

	state.character = CharacterProfile.create("김철수", {"top_color": "red"})
	state.character_generation = 3
	var document: Dictionary = state.to_dict()
	var from_json: Dictionary = JSON.parse_string(JSON.stringify(document))
	var parsed: PlayerState = PlayerState.from_dict(from_json)
	assert_not_null(parsed)
	assert_eq(parsed.character.name, "김철수")
	assert_eq(parsed.character.appearance, {"top_color": "red"})
	assert_eq(parsed.character_generation, 3)

	# A file written before P2-T9 (schema 3): that player had a character.
	var older: Dictionary = document.duplicate(true)
	older.erase(PlayerState.KEY_CHARACTER)
	older["schema_version"] = 3
	var migrated: Dictionary = SaveMigrations.defaults()[SaveService.CATEGORY_PLAYER].migrate(older)
	assert_eq(int(migrated["schema_version"]), PlayerState.SCHEMA_VERSION)
	var migrated_state: PlayerState = PlayerState.from_dict(migrated)
	assert_not_null(migrated_state)
	assert_true(migrated_state.has_character())
	assert_eq(migrated_state.character.name, SaveMigrations.DEFAULT_CHARACTER_NAME)
	assert_eq(SaveMigrations.DEFAULT_CHARACTER_NAME, CharacterSettings.new().default_name, "the migration and the settings agree on the default name")
	assert_eq(migrated_state.character.appearance, {}, "filled with the default options when the world loads")
	assert_eq(migrated_state.character_generation, 3)
	# The whole chain from a Phase 1 file.
	var phase1: Dictionary = older.duplicate(true)
	phase1.erase("character_generation")
	phase1["schema_version"] = 1
	var from_phase1: PlayerState = PlayerState.from_dict(SaveMigrations.defaults()[SaveService.CATEGORY_PLAYER].migrate(phase1))
	assert_true(from_phase1.has_character())
	assert_eq(from_phase1.character_generation, 1)

	# Malformed documents.
	var missing: Dictionary = document.duplicate(true)
	missing.erase(PlayerState.KEY_CHARACTER)
	assert_true(PlayerState.validate_dict(missing).size() > 0, "a current file must carry the key")
	for bad: Variant in [3, "Rick", [], {"name": "Rick"}, {"name": "", "appearance": {}}, {"name": "Rick", "appearance": {"top_color": 3}}]:
		var broken: Dictionary = document.duplicate(true)
		broken[PlayerState.KEY_CHARACTER] = bad
		assert_true(PlayerState.validate_dict(broken).size() > 0, "refused: %s" % str(bad))
	# Only a player's first character can be missing.
	var impossible: Dictionary = without.duplicate(true)
	impossible["character_generation"] = 2
	assert_true(PlayerState.validate_dict(impossible).size() > 0, "generation 2 without a character")


func test_a_migrated_player_gets_the_default_look_when_the_world_loads() -> void:
	var world: ServerWorld = _lenient_world()
	var alice: PlayerState = world.join("alice")
	world.leave(alice.player_id)
	var documents: Dictionary = world.to_documents()
	# What SaveMigrations writes for a pre-P2-T9 player, plus a slot and an
	# option that do not exist in today's data.
	var player_doc: Dictionary = (documents["players"] as Dictionary)[alice.player_id]
	player_doc[PlayerState.KEY_CHARACTER] = {"name": SaveMigrations.DEFAULT_CHARACTER_NAME, "appearance": {"top_color": "no_such_colour", "tail": "long", "hair_style": "bald"}}
	var restored: ServerWorld = _strict_world()
	var errors: PackedStringArray = restored.restore_documents(documents["world_state"], documents["players"])
	assert_eq(errors.size(), 0, "a data change does not make a save unloadable: " + "; ".join(errors))
	var restored_alice: PlayerState = restored.get_player(alice.player_id)
	var expected: Dictionary = restored.character_rules.catalog.default_selection()
	expected["hair_style"] = "bald"
	assert_eq(restored_alice.character.appearance, expected)
	assert_true(restored.character_rules.catalog.is_complete_selection(restored_alice.character.appearance))
	restored.join("alice")
	assert_true(restored.is_online(alice.player_id), "a player saved before P2-T9 has a character and needs no creation")


# ------------------------------------------------------------ seams

func test_systems_get_default_hooks_and_bare_worlds_still_work() -> void:
	var system: ServerSystem = ServerSystem.new()
	assert_eq(system.new_character_block_reason("player_000001"), "", "a system has no objection by default")
	# A world built without the composition (no survival system, no data).
	var world: ServerWorld = ServerWorld.new(WORLD, GameplaySettings.new(), ItemCatalog.new())
	assert_false(world.require_character_creation)
	assert_not_null(world.character_rules)
	var alice: PlayerState = world.join("alice")
	assert_true(alice.has_character())
	assert_eq(alice.character.appearance, {}, "no appearance data, no selection")
	assert_true(world.is_online(alice.player_id))
	world.require_character_creation = true
	var bob: PlayerState = world.join("bob")
	assert_false(world.is_online(bob.player_id))
	assert_true(world.create_character(bob.player_id, "Bob", {}).ok)
	assert_true(world.is_online(bob.player_id))
