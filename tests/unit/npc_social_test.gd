extends TestCase
## F-31 (docs/09 §17.16): NPCs notice players, react to them and talk with
## them. The reaction rules (pure), noticing in a world, what the body does
## about it, the conversation machine and what a choice changes, gifts and
## trades as real item moves, a player's hit, and that the relationship
## survives a save and a restart while the conversation does not.
## The network side is tests/integration/npc_dialogue_net_test.gd.

const WORLD: String = "npc_social_world"
const FRIENDLY: String = "f31_friendly"
const TIMID: String = "f31_timid"
const BOLD: String = "f31_bold"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
## Within talking range of Alice.
const NEAR: Vector3 = Vector3(5.5, 0.0, 3.5)
## Seen by her, not within talking range.
const SEEN: Vector3 = Vector3(5.5, 0.0, -3.5)
## Out of an NPC's sight (15 m), in a simulated cell.
const UNSEEN: Vector3 = Vector3(-14.5, 0.0, -14.5)
const FOOD: String = "dev_food_ration"
const WATER: String = "dev_water_bottle"
const BANDAGE: String = "dev_bandage"
const PIPE: String = "dev_melee_pipe"
const WOOD: String = "dev_wood"


class IdleDecider:
	extends NpcDecider


var _settings: NpcSocialSettings = null
var _idle: bool = true
var _bad: Array = []
var _joins: Array = []
var _noticed: Array = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = NpcSocialSettings.new()
	_idle = true
	_bad = []
	_joins = []
	_noticed = []


func after_each() -> void:
	GameLogger.set_capture(false)


func _definition(definition_id: String, nature: float) -> NpcDefinition:
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = definition_id
	definition.display_name = "이서연" if definition_id == FRIENDLY else ("박겁" if definition_id == TIMID else "최강")
	definition.extraversion = nature
	definition.agreeableness = nature
	definition.courage = nature
	definition.risk_tolerance = nature
	definition.neuroticism = 1.0 - nature
	definition.self_interest = 1.0 - nature
	if definition_id == BOLD:
		# Brave, and no friend of anybody.
		definition.extraversion = 0.1
		definition.agreeableness = 0.1
		definition.courage = 1.0
		definition.risk_tolerance = 1.0
		definition.neuroticism = 0.0
	return definition


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = SurvivalSettings.new()
	config.survival.health_recovery_per_world_sec = 0.0
	config.survival.wound_recovery_per_world_sec = 0.0
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = WorldCellSettings.new()
	config.world_cells.cell_size_m = 10.0
	config.world_cells.bounds_min_m = Vector2(-50.0, -50.0)
	config.world_cells.bounds_max_m = Vector2(50.0, 50.0)
	config.world_cells.active_radius_cells = 2
	config.world_cells.preload_radius_cells = 2
	config.world_cells.preload_lookahead_sec = 0.0
	config.world_cells.deactivate_delay_sec = 0.0
	config.world_cells.unload_delay_sec = 0.5
	config.world_cells.refresh_period_sec = 0.0
	config.world_cells.max_preload_loads_per_refresh = 1000
	config.map_content = null
	config.npc_spots = null
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	config.npc_definitions.add(_definition(FRIENDLY, 1.0))
	config.npc_definitions.add(_definition(TIMID, 0.0))
	config.npc_definitions.add(_definition(BOLD, 1.0))
	config.npc_behaviour = NpcBehaviourSettings.new()
	config.npc_health = NpcHealthSettings.new()
	config.npc_scavenge = null
	config.npc_relocation = null
	config.npc_decider = IdleDecider.new() if _idle else null
	config.npc_social = _settings
	return config


func _world(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_not_null(world, "the composition builds the world")
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	var dialogue: NpcDialogue = NpcSocial.of_world(world).dialogue()
	dialogue.conversation_went_badly.connect(func(npc_id: String, player_id: String, reason: String) -> void: _bad.append([npc_id, player_id, reason]))
	dialogue.join_requested.connect(func(npc_id: String, player_id: String, lean: float) -> void: _joins.append([npc_id, player_id, lean]))
	NpcSocial.of_world(world).player_noticed.connect(func(npc_id: String, player_id: String, reaction: String) -> void: _noticed.append([npc_id, player_id, reaction]))
	return world


func _started(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = _world(store)
	world.join("alice")
	_run(world, TICK)
	return world


func _run(world: ServerWorld, seconds: float, tick: float = TICK) -> void:
	for step: int in range(roundi(seconds / tick)):
		world.step_systems(tick)


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _social(world: ServerWorld) -> NpcSocial:
	return NpcSocial.of_world(world)


func _talk(world: ServerWorld) -> NpcDialogue:
	return _social(world).dialogue()


func _alice(world: ServerWorld) -> PlayerState:
	return world.get_player(world.online_player_ids()[0])


func _spawn(world: ServerWorld, definition_id: String, position: Vector3) -> String:
	var result: ActionResult = _npcs(world).spawn_npc(world, definition_id, position)
	assert_true(result.ok, result.reason)
	return str(result.event.get(NpcService.KEY_NPC_ID, ""))


func _npc(world: ServerWorld, npc_id: String) -> NpcState:
	return _npcs(world).get_npc(npc_id)


func _state(world: ServerWorld, npc_id: String) -> NpcSocialState:
	return NpcSocialState.of(_npc(world, npc_id))


func _record(world: ServerWorld, npc_id: String) -> NpcSocialState.Record:
	return _state(world, npc_id).record_of(_alice(world).player_id)


func _relationship(world: ServerWorld, npc_id: String) -> RelationshipState:
	return (_npc(world, npc_id).component(RelationshipStore.COMPONENT_ID) as RelationshipStore).relationship(_alice(world).player_id)


func _give_player(world: ServerWorld, definition_id: String, quantity: int = 1) -> void:
	var player: PlayerState = _alice(world)
	var item_id: String = world.inventory.spawn_world_item(definition_id, quantity, world.cell_id_at(player.position), player.position)
	assert_true(world.try_pickup(player.player_id, item_id).ok, "test setup: pick up " + definition_id)


func _give_npc(world: ServerWorld, npc_id: String, definition_id: String, quantity: int = 1) -> void:
	assert_false(world.inventory.spawn_detached_item(NpcSurvivalSense.inventory_of(_npc(world, npc_id)), definition_id, quantity).is_empty(), "test setup: the NPC gets " + definition_id)


func _units(world: ServerWorld, inventory_id: String, definition_id: String) -> int:
	var total: int = 0
	for item: ItemInstance in world.inventory.items_in_inventory(inventory_id):
		if item.definition_id == definition_id:
			total += item.quantity
	return total


func _begin(world: ServerWorld, npc_id: String) -> Dictionary:
	var result: ActionResult = _talk(world).start(world, _alice(world).player_id, npc_id)
	assert_true(result.ok, "start: " + result.reason)
	return result.event


func _choose(world: ServerWorld, npc_id: String, view: Dictionary, choice_id: String) -> Dictionary:
	var result: ActionResult = _talk(world).choose(world, _alice(world).player_id, npc_id, int(view.get(NpcDialogue.KEY_TURN, -1)), choice_id)
	assert_true(result.ok, "choose %s: %s" % [choice_id, result.reason])
	return result.event


func _choice_ids(view: Dictionary) -> PackedStringArray:
	var ids: PackedStringArray = []
	for entry: Array in view.get(NpcDialogue.KEY_CHOICES, []):
		ids.append(str(entry[0]))
	return ids


func _view(nature: float) -> NpcReactionRules.View:
	var view: NpcReactionRules.View = NpcReactionRules.View.new()
	view.traits = _definition(FRIENDLY, nature).personality()
	return view


func _distance(world: ServerWorld, npc_id: String) -> float:
	return Vector2(_npc(world, npc_id).position.x - _alice(world).position.x, _npc(world, npc_id).position.z - _alice(world).position.z).length()


# ------------------------------------------------------------ data

func test_default_settings_are_valid_and_the_tuning_file_matches_them() -> void:
	assert_eq(_settings.validate().size(), 0)
	var loaded: NpcSocialSettings = NpcSocialSettings.load_or_default()
	assert_eq(loaded.validate().size(), 0)
	for property: Dictionary in _settings.get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			assert_eq(loaded.get(property["name"]), _settings.get(property["name"]), str(property["name"]))
	var broken: NpcSocialSettings = NpcSocialSettings.new()
	broken.talk_leave_range_m = 1.0
	broken.flee_fear = 0.1
	broken.notice_check_period_sec = 0.0
	assert_eq(broken.validate().size(), 3)


func test_the_korean_lines_have_every_key_and_fill_their_placeholders() -> void:
	var lines: NpcDialogueLines = NpcDialogueLines.load_or_default()
	assert_eq(lines.validate().size(), 0, "; ".join(lines.validate()))
	for key: String in NpcDialogueLines.LINE_KEYS:
		assert_true(lines.variant_count(key) >= 1, key)
	assert_contains(lines.line("who_open", 0, {"name": "이서연"}), "이서연")
	assert_ne(lines.line("greet_warm", 0), lines.line("greet_warm", 1), "a line has variants")
	assert_eq(lines.line("greet_warm", 0), lines.line("greet_warm", lines.variant_count("greet_warm")), "the variants wrap")
	assert_contains(lines.choice("give_item", {"item": "붕대"}), "붕대")
	assert_eq(NpcDialogueLines.new().line("greet_warm"), "", "missing text is empty, never an error")
	assert_true(NpcDialogueLines.new().validate().size() > 0)


# ------------------------------------------------------------ the rules

func test_personality_and_what_the_player_did_decide_the_reaction() -> void:
	var average: NpcReactionRules.View = _view(0.5)
	assert_eq(NpcReactionRules.reaction(average, _settings), NpcReactionRules.GREET, "an average NPC greets an unarmed stranger")
	average.armed = true
	assert_eq(NpcReactionRules.reaction(average, _settings), NpcReactionRules.WARY, "an armed one it watches")
	var timid: NpcReactionRules.View = _view(0.0)
	timid.armed = true
	assert_eq(NpcReactionRules.reaction(timid, _settings), NpcReactionRules.HIDE, "a timid loner keeps its distance from an armed stranger")
	assert_true(NpcReactionRules.fear(timid, _settings) > NpcReactionRules.fear(average, _settings), "the same player frightens a timid NPC more")
	var friendly: NpcReactionRules.View = _view(1.0)
	friendly.armed = true
	assert_eq(NpcReactionRules.reaction(friendly, _settings), NpcReactionRules.GREET, "an outgoing, brave NPC greets even an armed one")
	average.armed = false
	average.harmed_count = 1
	# What a hit leaves in the record (NpcSocial.on_npc_damaged).
	average.relationship = RelationshipState.new()
	average.relationship.fear = _settings.harmed_fear
	average.relationship.resentment = _settings.harmed_resentment
	assert_eq(NpcReactionRules.reaction(average, _settings), NpcReactionRules.AFRAID, "whoever hurt it, it runs from")
	var bold: NpcReactionRules.View = NpcReactionRules.View.new()
	bold.traits = _definition(BOLD, 1.0).personality()
	bold.harmed_count = 1
	bold.relationship = average.relationship
	assert_eq(NpcReactionRules.reaction(bold, _settings), NpcReactionRules.HIDE, "a bold NPC does not run: it keeps its distance (F-32 makes it hostile)")
	var witness: NpcReactionRules.View = _view(0.5)
	witness.kills_seen = 2
	assert_true(NpcReactionRules.threat(witness, _settings) > NpcReactionRules.threat(_view(0.5), _settings), "a killer of NPCs is more threatening")
	var hurt: NpcReactionRules.View = _view(0.5)
	hurt.npc_hurt = true
	assert_true(NpcReactionRules.fear(hurt, _settings) > NpcReactionRules.fear(_view(0.5), _settings), "a hurt NPC is more easily frightened")


func test_trust_calms_and_fear_alarms() -> void:
	var view: NpcReactionRules.View = _view(0.0)
	view.armed = true
	view.relationship = RelationshipState.new()
	view.relationship.trust = 0.9
	view.relationship.liking = 0.5
	assert_eq(NpcReactionRules.reaction(view, _settings), NpcReactionRules.GREET, "even a timid NPC greets somebody it trusts")
	view.relationship.trust = 0.0
	view.relationship.fear = 0.9
	view.relationship.resentment = 0.5
	assert_eq(NpcReactionRules.reaction(view, _settings), NpcReactionRules.AFRAID)
	for value: float in [0.0, 0.3, 0.7, 1.0]:
		var any: NpcReactionRules.View = _view(value)
		assert_true(NpcReactionRules.threat(any, _settings) >= 0.0 and NpcReactionRules.threat(any, _settings) <= 1.0)
		assert_true(NpcReactionRules.join_lean(any, _settings) >= 0.0 and NpcReactionRules.join_lean(any, _settings) <= 1.0)
	assert_true(NpcReactionRules.join_lean(_view(1.0), _settings) > NpcReactionRules.join_lean(_view(0.0), _settings) + 0.3, "personality weighs heavily in the join lean (FD-10)")


# ------------------------------------------------------------ noticing

func test_an_npc_notices_a_player_it_sees_and_shows_how_it_takes_it() -> void:
	var world: ServerWorld = _started()
	var friendly_id: String = _spawn(world, FRIENDLY, SEEN)
	var far_id: String = _spawn(world, FRIENDLY, UNSEEN)
	assert_eq(NpcSocialState.reaction_of(_npc(world, friendly_id)), NpcReactionRules.NONE, "nothing before it looked")
	_run(world, 1.0)
	assert_eq(NpcSocialState.reaction_of(_npc(world, friendly_id)), NpcReactionRules.GREET)
	assert_eq(_state(world, friendly_id).reaction_player_id, _alice(world).player_id)
	assert_null(_record(world, friendly_id), "being seen writes no record: nothing of the NPC is saved anew")
	assert_eq(_noticed, [[friendly_id, _alice(world).player_id, NpcReactionRules.GREET]], "noticed once, not at every look")
	assert_eq(NpcSocialState.reaction_of(_npc(world, far_id)), NpcReactionRules.NONE, "out of sight: no reaction")
	assert_null(_record(world, far_id))
	assert_null(_relationship(world, friendly_id), "being seen writes no relationship")
	assert_false((_npcs(world).npc_document(friendly_id)[NpcState.KEY_COMPONENTS][NpcSocialState.COMPONENT_ID] as Dictionary).has("reaction"), "the public reaction is not saved")


func test_an_armed_player_is_taken_differently_and_a_gone_one_forgotten() -> void:
	var world: ServerWorld = _started()
	var timid_id: String = _spawn(world, TIMID, SEEN)
	_run(world, 1.0)
	assert_eq(NpcSocialState.reaction_of(_npc(world, timid_id)), NpcReactionRules.WARY, "a timid NPC watches an unarmed stranger")
	_give_player(world, PIPE)
	_run(world, 1.0)
	assert_eq(NpcSocialState.reaction_of(_npc(world, timid_id)), NpcReactionRules.HIDE, "with a weapon in the player's hands it keeps its distance")
	world.leave(_alice(world).player_id)
	_npcs(world).step(world, TICK, TICK)
	for step: int in 12:
		_npcs(world).step(world, TICK, TICK)
	assert_eq(NpcSocialState.reaction_of(_npc(world, timid_id)), NpcReactionRules.NONE, "nobody there: no reaction")


func test_an_npc_comes_over_backs_off_or_runs_and_then_goes_on() -> void:
	_idle = false
	_settings.attention_sec = 6.0
	var world: ServerWorld = _started()
	var friendly_id: String = _spawn(world, FRIENDLY, SEEN)
	var before: float = _distance(world, friendly_id)
	_run(world, 5.0)
	assert_true(_distance(world, friendly_id) < before - 3.0, "the friendly NPC came over: %f -> %f" % [before, _distance(world, friendly_id)])
	assert_true(_distance(world, friendly_id) <= _settings.talk_range_m + 0.5, "to within talking range")
	var decision: NpcDecisionComponent = _npc(world, friendly_id).component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
	assert_eq(decision.action_id, NpcSocial.ACTION_MEET)
	assert_eq(str(decision.last_record().get(NpcUtilityDecider.KEY_HARD_INTERRUPT, "")), NpcSocial.HARD_PLAYER_MET)
	_run(world, 6.0)
	assert_ne(decision.action_id, NpcSocial.ACTION_MEET, "after its attention is over it goes on with its day")
	assert_eq(NpcSocialState.reaction_of(_npc(world, friendly_id)), NpcReactionRules.GREET, "the label stays while it sees the player")


func test_a_frightened_npc_runs_from_the_player_that_hurt_it() -> void:
	_idle = false
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, TIMID, NEAR)
	_run(world, 0.3)
	var before: float = _distance(world, npc_id)
	assert_true(NpcHealth.of_world(world).apply_damage(npc_id, DamageInput.create(_alice(world).player_id, BodyPart.Part.TORSO, Wound.Type.LACERATION, 5.0)).ok)
	assert_eq(NpcSocialState.reaction_of(_npc(world, npc_id)), NpcReactionRules.AFRAID, "at once, not at its next look")
	_run(world, 3.0)
	var decision: NpcDecisionComponent = _npc(world, npc_id).component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
	assert_true(_distance(world, npc_id) > before + 3.0, "it ran: %f -> %f" % [before, _distance(world, npc_id)])
	assert_eq(NpcDecisionComponent.label_of(_npc(world, npc_id)), "flee")
	assert_eq(str(decision.target.get(NpcActionExecutor.TARGET_THREAT_ID, "")), _alice(world).player_id, "the player is the threat")


# ------------------------------------------------------------ a player's hit

func test_a_players_hit_is_remembered_in_every_way() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, FRIENDLY, NEAR)
	_run(world, 1.0)
	var view: Dictionary = _begin(world, npc_id)
	assert_true(bool(view[NpcDialogue.KEY_OPEN]))
	var player_id: String = _alice(world).player_id
	assert_true(NpcHealth.of_world(world).apply_damage(npc_id, DamageInput.create(player_id, BodyPart.Part.TORSO, Wound.Type.LACERATION, 5.0)).ok)
	var record: NpcSocialState.Record = _record(world, npc_id)
	assert_eq(record.harmed, 1)
	var relationship: RelationshipState = _relationship(world, npc_id)
	assert_true(relationship.fear >= _settings.harmed_fear - 0.0001 and relationship.resentment >= _settings.harmed_resentment - 0.0001)
	assert_true(relationship.trust < 0.1, "the trust is gone")
	var memories: NpcMemoryStore = _npc(world, npc_id).component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	var remembered: bool = false
	for memory_id: String in memories.memory_ids():
		remembered = remembered or memories.memory(memory_id).event_type == NpcSocial.MEMORY_ATTACKED
	assert_true(remembered, "a memory of the attack")
	assert_false(_talk(world).is_talking(player_id), "the conversation is over")
	var events: Array[Dictionary] = _talk(world).drain_events()
	assert_eq(events.size(), 1)
	assert_eq(str((events[0][NpcDialogue.KEY_VIEW] as Dictionary)[NpcDialogue.KEY_END_REASON]), NpcDialogue.END_NPC_HURT)
	assert_true(NpcSocialState.reaction_of(_npc(world, npc_id)) in [NpcReactionRules.HIDE, NpcReactionRules.AFRAID], "even the friendliest NPC is no friend now: " + NpcSocialState.reaction_of(_npc(world, npc_id)))
	var refused: Dictionary = _begin(world, npc_id)
	assert_false(bool(refused[NpcDialogue.KEY_OPEN]), "and will not talk")
	assert_eq(str(refused[NpcDialogue.KEY_END_REASON]), NpcDialogue.END_REFUSED)
	# A zombie's or anybody else's hit is not a player's.
	var other_id: String = _spawn(world, FRIENDLY, SEEN)
	assert_true(NpcHealth.of_world(world).apply_damage(other_id, DamageInput.create("zombie_1", BodyPart.Part.TORSO, Wound.Type.LACERATION, 5.0)).ok)
	assert_null(_state(world, other_id).record_of("zombie_1"))


# ------------------------------------------------------------ conversations

func test_who_may_begin_a_conversation() -> void:
	var world: ServerWorld = _started()
	var player_id: String = _alice(world).player_id
	var near_id: String = _spawn(world, FRIENDLY, NEAR)
	var seen_id: String = _spawn(world, FRIENDLY, SEEN)
	_run(world, 1.0)
	var talk: NpcDialogue = _talk(world)
	assert_eq(talk.start(world, player_id, "npc_999").reason, NpcDialogue.REASON_UNKNOWN_NPC)
	assert_eq(talk.start(world, "player_999", near_id).reason, NpcDialogue.REASON_UNKNOWN_PLAYER)
	assert_eq(talk.start(world, player_id, seen_id).reason, NpcDialogue.REASON_TOO_FAR)
	assert_eq(talk.choose(world, player_id, near_id, 1, NpcDialogue.CHOICE_GREET).reason, NpcDialogue.REASON_NOT_TALKING)
	assert_eq(talk.end(world, player_id).reason, NpcDialogue.REASON_NOT_TALKING)
	var view: Dictionary = _begin(world, near_id)
	assert_true(bool(view[NpcDialogue.KEY_OPEN]))
	assert_eq(str(view[NpcDialogue.KEY_NPC_NAME]), "이서연")
	assert_eq(int(view[NpcDialogue.KEY_TURN]), 1)
	assert_false(str(view[NpcDialogue.KEY_LINE]).is_empty(), "the NPC says something")
	assert_eq(_choice_ids(view), PackedStringArray(["greet", "who", "give", "news", "trade", "join", "threaten", "leave"]))
	assert_eq(talk.partner_of(near_id), player_id)
	assert_eq(NpcSocialState.reaction_of(_npc(world, near_id)), NpcReactionRules.TALK, "everybody sees that it talks")
	assert_eq(_record(world, near_id).talks, 1)
	assert_eq(int(_begin(world, near_id)[NpcDialogue.KEY_TURN]), 1, "asking again shows the same conversation")
	assert_eq(_record(world, near_id).talks, 1)
	# A dead NPC, and a dead player.
	var dead_id: String = _spawn(world, FRIENDLY, NEAR + Vector3(1.0, 0.0, 0.0))
	assert_true(NpcHealth.of_world(world).apply_damage(dead_id, DamageInput.create("test_source", BodyPart.Part.TORSO, Wound.Type.LACERATION, 500.0)).ok)
	assert_eq(talk.start(world, player_id, dead_id).reason, NpcDialogue.REASON_NPC_DEAD)
	# Another player cannot cut in.
	var bob: PlayerState = world.join("bob")
	_run(world, TICK)
	assert_eq(talk.start(world, bob.player_id, near_id).reason, NpcDialogue.REASON_NPC_TALKING)


func test_choices_are_checked_and_the_turn_guards_against_stale_ones() -> void:
	var world: ServerWorld = _started()
	var player_id: String = _alice(world).player_id
	var npc_id: String = _spawn(world, FRIENDLY, NEAR)
	_run(world, 1.0)
	var talk: NpcDialogue = _talk(world)
	var view: Dictionary = _begin(world, npc_id)
	assert_eq(talk.choose(world, player_id, npc_id, 99, NpcDialogue.CHOICE_GREET).reason, NpcDialogue.REASON_STALE_TURN)
	assert_eq(talk.choose(world, player_id, npc_id, 1, "give:0").reason, NpcDialogue.REASON_BAD_CHOICE, "not a choice of this view")
	assert_eq(talk.choose(world, player_id, npc_id, 1, "open_sesame").reason, NpcDialogue.REASON_BAD_CHOICE)
	assert_eq(talk.choose(world, player_id, "npc_999", 1, NpcDialogue.CHOICE_GREET).reason, NpcDialogue.REASON_NOT_TALKING)
	var greeted: Dictionary = _choose(world, npc_id, view, NpcDialogue.CHOICE_GREET)
	assert_eq(int(greeted[NpcDialogue.KEY_TURN]), 2)
	assert_false(_choice_ids(greeted).has("greet"), "one greeting per conversation")
	assert_eq(talk.choose(world, player_id, npc_id, 1, NpcDialogue.CHOICE_WHO).reason, NpcDialogue.REASON_STALE_TURN, "the old view's turn is refused")
	var relationship: RelationshipState = _relationship(world, npc_id)
	assert_not_null(relationship, "the greeting made the relationship record")
	var trust: float = relationship.trust
	assert_true(trust > NpcReactionRules.trust(_view(1.0), _settings), "and raised the trust a stranger gets")
	var who: Dictionary = _choose(world, npc_id, greeted, NpcDialogue.CHOICE_WHO)
	assert_contains(str(who[NpcDialogue.KEY_LINE]), "이서연", "it says its name")
	var left: Dictionary = _choose(world, npc_id, who, NpcDialogue.CHOICE_LEAVE)
	assert_false(bool(left[NpcDialogue.KEY_OPEN]))
	assert_eq(str(left[NpcDialogue.KEY_END_REASON]), NpcDialogue.END_PLAYER_LEFT)
	assert_false(str(left[NpcDialogue.KEY_LINE]).is_empty(), "it says goodbye")
	assert_eq((left[NpcDialogue.KEY_CHOICES] as Array).size(), 0)
	assert_eq(talk.partner_of(npc_id), "")
	assert_eq(talk.drain_events().size(), 0, "what the player ended itself is not announced again")
	# The greeting counts once per day.
	var again: Dictionary = _choose(world, npc_id, _begin(world, npc_id), NpcDialogue.CHOICE_GREET)
	assert_true(bool(again[NpcDialogue.KEY_OPEN]))
	assert_eq(_relationship(world, npc_id).trust, trust, "a second greeting the same day changes nothing")


func test_a_frightened_npc_will_not_talk_and_pestering_goes_badly() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, TIMID, NEAR)
	_give_player(world, PIPE)
	_run(world, 1.0)
	assert_eq(NpcSocialState.reaction_of(_npc(world, npc_id)), NpcReactionRules.HIDE)
	_settings.refuse_fear = 0.4
	var refused: Dictionary = _begin(world, npc_id)
	assert_false(bool(refused[NpcDialogue.KEY_OPEN]))
	assert_eq(str(refused[NpcDialogue.KEY_END_REASON]), NpcDialogue.END_REFUSED)
	assert_false(str(refused[NpcDialogue.KEY_LINE]).is_empty(), "it says so")
	assert_false(_talk(world).is_talking(_alice(world).player_id))
	assert_eq(_record(world, npc_id).refusals, 1)
	assert_eq(_bad.size(), 0)
	for attempt: int in _settings.pester_limit:
		assert_false(bool(_begin(world, npc_id)[NpcDialogue.KEY_OPEN]))
	assert_eq(_bad, [[npc_id, _alice(world).player_id, NpcSocialState.BAD_PESTERED]], "asking again and again went badly, once")
	assert_eq(_record(world, npc_id).bad_talks, 1)
	assert_eq(_record(world, npc_id).last_bad_reason, NpcSocialState.BAD_PESTERED)
	assert_true(_relationship(world, npc_id).resentment > 0.0)
	# After the cooldown it is asked anew (and refuses for its own reason).
	_run(world, _settings.refuse_cooldown_sec + 1.0)
	_begin(world, npc_id)
	assert_eq(_bad.size(), 1)


func test_a_threat_frightens_ends_the_talk_and_is_written_down() -> void:
	var world: ServerWorld = _started()
	var player_id: String = _alice(world).player_id
	var timid_id: String = _spawn(world, TIMID, NEAR)
	var bold_id: String = _spawn(world, BOLD, NEAR + Vector3(1.0, 0.0, 0.0))
	_run(world, 1.0)
	var cowed: Dictionary = _choose(world, timid_id, _begin(world, timid_id), NpcDialogue.CHOICE_THREATEN)
	assert_false(bool(cowed[NpcDialogue.KEY_OPEN]))
	assert_eq(str(cowed[NpcDialogue.KEY_END_REASON]), NpcDialogue.END_NPC_ENDED)
	var lines: NpcDialogueLines = _talk(world).lines()
	assert_true((lines.lines["threat_cowed"] as PackedStringArray).has(str(cowed[NpcDialogue.KEY_LINE])), "a timid NPC gives in: " + str(cowed[NpcDialogue.KEY_LINE]))
	var defiant: Dictionary = _choose(world, bold_id, _begin(world, bold_id), NpcDialogue.CHOICE_THREATEN)
	assert_true((lines.lines["threat_defiant"] as PackedStringArray).has(str(defiant[NpcDialogue.KEY_LINE])), "a bold one talks back: " + str(defiant[NpcDialogue.KEY_LINE]))
	assert_eq(_bad, [[timid_id, player_id, NpcSocialState.BAD_THREATENED], [bold_id, player_id, NpcSocialState.BAD_THREATENED]], "the hook F-32 uses")
	assert_true(_relationship(world, timid_id).fear > _relationship(world, bold_id).fear, "the timid one is frightened more")
	assert_true(_relationship(world, bold_id).resentment > _relationship(world, timid_id).resentment, "the bold one resents it more")
	assert_eq(_record(world, timid_id).bad_talks, 1)
	assert_eq(_record(world, timid_id).last_bad_reason, NpcSocialState.BAD_THREATENED)
	assert_true(_record(world, timid_id).last_bad_at >= 0.0)
	assert_eq(NpcSocialState.reaction_of(_npc(world, timid_id)), NpcReactionRules.AFRAID, "it is afraid of the player now")
	assert_true(NpcVitals.of(_npc(world, timid_id)).is_untouched() and world.get_system(SurvivalService.SYSTEM_ID) != null, "nobody was attacked")
	assert_false(bool(_begin(world, timid_id)[NpcDialogue.KEY_OPEN]), "and it will not talk again for a while")


func test_join_me_only_writes_the_request_down() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, FRIENDLY, NEAR)
	_run(world, 1.0)
	var view: Dictionary = _begin(world, npc_id)
	var position: Vector3 = _npc(world, npc_id).position
	var asked: Dictionary = _choose(world, npc_id, view, NpcDialogue.CHOICE_JOIN)
	assert_true(bool(asked[NpcDialogue.KEY_OPEN]), "the conversation goes on")
	assert_eq(_joins.size(), 1)
	assert_eq(_joins[0][0], npc_id)
	var lean: float = float(_joins[0][2])
	assert_true(lean > 0.5, "a friendly NPC leans towards it: %f" % lean)
	var record: NpcSocialState.Record = _record(world, npc_id)
	assert_eq(record.join_requests, 1)
	assert_eq(record.join_last_lean, lean)
	assert_null(_relationship(world, npc_id), "asking changes no score")
	assert_eq(_npc(world, npc_id).position, position)
	_choose(world, npc_id, asked, NpcDialogue.CHOICE_JOIN)
	assert_eq(_record(world, npc_id).join_requests, 2)


func test_a_gift_really_moves_and_is_worth_more_to_one_in_need() -> void:
	var world: ServerWorld = _started()
	var player: PlayerState = _alice(world)
	var npc_id: String = _spawn(world, FRIENDLY, NEAR)
	_give_player(world, FOOD, 3)
	_give_player(world, WOOD, 1)
	_run(world, 1.0)
	var npc_inventory: String = NpcSurvivalSense.inventory_of(_npc(world, npc_id))
	var total: int = world.inventory.item_count()
	var list: Dictionary = _choose(world, npc_id, _begin(world, npc_id), NpcDialogue.CHOICE_GIVE)
	assert_eq(_choice_ids(list), PackedStringArray(["give:0", "back"]), "food is a gift, wood is not")
	assert_contains(str((list[NpcDialogue.KEY_CHOICES] as Array)[0][1]), "전투식량")
	var given: Dictionary = _choose(world, npc_id, list, "give:0")
	assert_true(bool(given[NpcDialogue.KEY_OPEN]))
	assert_eq(_units(world, player.inventory_id, FOOD), 2, "one unit left the player")
	assert_eq(_units(world, npc_inventory, FOOD), 1, "and the NPC carries it")
	var first_trust: float = _relationship(world, npc_id).trust
	assert_true(first_trust > NpcReactionRules.trust(_view(1.0), _settings) + _settings.gift_trust - 0.0001)
	assert_eq(_record(world, npc_id).gifts_today, 1)
	# The second gift of the day counts half.
	var second: Dictionary = _choose(world, npc_id, _choose(world, npc_id, given, NpcDialogue.CHOICE_GIVE), "give:0")
	assert_true(absf((_relationship(world, npc_id).trust - first_trust) - _settings.gift_trust * 0.5) < 0.0001, "half as much the second time")
	assert_eq(_units(world, player.inventory_id, FOOD) + _units(world, npc_inventory, FOOD), 3, "no unit is made or lost")
	assert_true(world.inventory.item_count() <= total + 1)
	# A choice whose item is gone is refused in words, nothing moves.
	var stale: Dictionary = _choose(world, npc_id, second, NpcDialogue.CHOICE_GIVE)
	assert_true(world.remove_player_item(player.player_id, world.inventory.items_in_inventory(player.inventory_id)[0].item_instance_id, 1).ok)
	for item: ItemInstance in world.inventory.items_in_inventory(player.inventory_id):
		if item.definition_id == FOOD:
			world.remove_player_item(player.player_id, item.item_instance_id, item.quantity)
	var gone: Dictionary = _choose(world, npc_id, stale, "give:0")
	assert_true(bool(gone[NpcDialogue.KEY_OPEN]))
	assert_eq(_units(world, npc_inventory, FOOD), 2)
	assert_eq(_record(world, npc_id).gifts_total, 2)


func test_a_full_npc_takes_nothing_and_nothing_is_lost() -> void:
	var world: ServerWorld = _started()
	var player: PlayerState = _alice(world)
	var npc_id: String = _spawn(world, FRIENDLY, NEAR)
	_run(world, 1.0)
	var capacity: int = (_npc(world, npc_id).component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState).capacity()
	for slot: int in capacity:
		_give_npc(world, npc_id, WOOD)
	_give_player(world, BANDAGE)
	var list: Dictionary = _choose(world, npc_id, _begin(world, npc_id), NpcDialogue.CHOICE_GIVE)
	var refused: Dictionary = _choose(world, npc_id, list, "give:0")
	assert_true((_talk(world).lines().lines["give_full"] as PackedStringArray).has(str(refused[NpcDialogue.KEY_LINE])), str(refused[NpcDialogue.KEY_LINE]))
	assert_eq(_units(world, player.inventory_id, BANDAGE), 1, "the player keeps it")
	assert_eq(_record(world, npc_id).gifts_total, 0)
	assert_null(_relationship(world, npc_id))


func test_a_trade_swaps_one_for_one_in_one_transaction() -> void:
	var world: ServerWorld = _started()
	var player: PlayerState = _alice(world)
	var npc_id: String = _spawn(world, FRIENDLY, NEAR)
	_run(world, 1.0)
	var npc_inventory: String = NpcSurvivalSense.inventory_of(_npc(world, npc_id))
	var nothing: Dictionary = _choose(world, npc_id, _begin(world, npc_id), NpcDialogue.CHOICE_TRADE)
	assert_true((_talk(world).lines().lines["trade_nothing"] as PackedStringArray).has(str(nothing[NpcDialogue.KEY_LINE])), "nothing to swap: " + str(nothing[NpcDialogue.KEY_LINE]))
	_give_npc(world, npc_id, FOOD, 3)
	_give_player(world, BANDAGE)
	_give_player(world, WOOD)
	var offers: Dictionary = _choose(world, npc_id, nothing, NpcDialogue.CHOICE_TRADE)
	assert_eq(_choice_ids(offers), PackedStringArray(["trade:0", "back"]), "a bandage is worth food to it, wood is not")
	var text: String = str((offers[NpcDialogue.KEY_CHOICES] as Array)[0][1])
	assert_true(text.contains("붕대") and text.contains("전투식량"), text)
	var done: Dictionary = _choose(world, npc_id, offers, "trade:0")
	assert_true(bool(done[NpcDialogue.KEY_OPEN]))
	assert_eq(_units(world, player.inventory_id, BANDAGE), 0)
	assert_eq(_units(world, player.inventory_id, FOOD), 1)
	assert_eq(_units(world, npc_inventory, BANDAGE), 1)
	assert_eq(_units(world, npc_inventory, FOOD), 2)
	assert_true(_relationship(world, npc_id).trust > NpcReactionRules.trust(_view(1.0), _settings))
	# It keeps its last food.
	_give_player(world, BANDAGE, 2)
	var more: Dictionary = _choose(world, npc_id, done, NpcDialogue.CHOICE_TRADE)
	_choose(world, npc_id, more, "trade:0")
	var last: Dictionary = _choose(world, npc_id, _talk(world).view_of(player.player_id), NpcDialogue.CHOICE_TRADE)
	assert_eq(_units(world, npc_inventory, FOOD), 1, "the last unit of food is not for trade")
	assert_true(_choice_ids(last).has("greet"), "back at the root: there was nothing to offer")


func test_news_is_what_the_npc_remembers() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, FRIENDLY, NEAR)
	_run(world, 1.0)
	var lines: NpcDialogueLines = _talk(world).lines()
	var view: Dictionary = _begin(world, npc_id)
	var none: Dictionary = _choose(world, npc_id, view, NpcDialogue.CHOICE_NEWS)
	assert_true((lines.lines["news_none"] as PackedStringArray).has(str(none[NpcDialogue.KEY_LINE])), str(none[NpcDialogue.KEY_LINE]))
	_choose(world, npc_id, none, NpcDialogue.CHOICE_LEAVE)
	# It saw a zombie 60 m to the east.
	var memories: NpcMemoryStore = _npc(world, npc_id).component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	var place: Vector3 = _npc(world, npc_id).position + Vector3(40.0, 0.0, 0.0)
	var participants: Array[Dictionary] = [{"entity_id": npc_id, "role": "witness"}]
	assert_true(memories.record_memory("", NpcSurvivalSense.MEMORY_ZOMBIE_SEEN, participants, place, world.clock.world_time_sec, NpcMemory.OBSERVATION_WITNESSED, 0.8, 0.8, PackedStringArray([NpcSurvivalSense.TAG_DANGER])).ok)
	var told: Dictionary = _choose(world, npc_id, _begin(world, npc_id), NpcDialogue.CHOICE_NEWS)
	assert_true(str(told[NpcDialogue.KEY_LINE]).contains("동쪽") and str(told[NpcDialogue.KEY_LINE]).contains("40미터"), str(told[NpcDialogue.KEY_LINE]))
	var again: Dictionary = _choose(world, npc_id, told, NpcDialogue.CHOICE_NEWS)
	assert_true((lines.lines["news_none"] as PackedStringArray).has(str(again[NpcDialogue.KEY_LINE])), "it tells a thing once per conversation")
	# A distrustful NPC keeps what it knows to itself.
	var timid_id: String = _spawn(world, TIMID, NEAR + Vector3(1.0, 0.0, 0.0))
	_choose(world, npc_id, again, NpcDialogue.CHOICE_LEAVE)
	_run(world, 1.0)
	var kept: Dictionary = _choose(world, timid_id, _begin(world, timid_id), NpcDialogue.CHOICE_NEWS)
	assert_true((lines.lines["news_refuse"] as PackedStringArray).has(str(kept[NpcDialogue.KEY_LINE])), str(kept[NpcDialogue.KEY_LINE]))


func test_a_conversation_ends_when_it_cannot_go_on() -> void:
	var world: ServerWorld = _started()
	var player: PlayerState = _alice(world)
	var npc_id: String = _spawn(world, FRIENDLY, NEAR)
	_run(world, 1.0)
	var talk: NpcDialogue = _talk(world)
	# Walking away.
	_begin(world, npc_id)
	player.position = SPAWN + Vector3(0.0, 0.0, 6.0)
	_run(world, TICK)
	var events: Array[Dictionary] = talk.drain_events()
	assert_eq(events.size(), 1)
	assert_eq(str(events[0][NpcDialogue.KEY_PLAYER_ID]), player.player_id)
	assert_eq(str((events[0][NpcDialogue.KEY_VIEW] as Dictionary)[NpcDialogue.KEY_END_REASON]), NpcDialogue.END_TOO_FAR)
	assert_false(talk.is_talking(player.player_id))
	assert_eq(talk.drain_events().size(), 0, "told once")
	# Saying nothing.
	player.position = SPAWN
	_run(world, 1.0)
	_begin(world, npc_id)
	_run(world, _settings.talk_idle_timeout_sec - 2.0)
	assert_true(talk.is_talking(player.player_id))
	_run(world, 3.0)
	events = talk.drain_events()
	assert_eq(str((events[0][NpcDialogue.KEY_VIEW] as Dictionary)[NpcDialogue.KEY_END_REASON]), NpcDialogue.END_TIMEOUT)
	# Too many questions.
	_settings.talk_max_turns = 2
	_settings.talk_turns_extraversion_bonus = 0
	var view: Dictionary = _begin(world, npc_id)
	view = _choose(world, npc_id, view, NpcDialogue.CHOICE_WHO)
	view = _choose(world, npc_id, view, NpcDialogue.CHOICE_WHO)
	view = _choose(world, npc_id, view, NpcDialogue.CHOICE_WHO)
	assert_false(bool(view[NpcDialogue.KEY_OPEN]), "the NPC has had enough")
	assert_eq(str(view[NpcDialogue.KEY_END_REASON]), NpcDialogue.END_NPC_ENDED)
	# The NPC dies.
	_settings.talk_max_turns = 12
	_run(world, _settings.refuse_cooldown_sec + 1.0)
	assert_true(bool(_begin(world, npc_id)[NpcDialogue.KEY_OPEN]))
	assert_true(NpcHealth.of_world(world).apply_damage(npc_id, DamageInput.create("test_source", BodyPart.Part.TORSO, Wound.Type.LACERATION, 500.0)).ok)
	_run(world, TICK)
	events = talk.drain_events()
	assert_eq(events.size(), 1)
	assert_eq(str((events[0][NpcDialogue.KEY_VIEW] as Dictionary)[NpcDialogue.KEY_END_REASON]), NpcDialogue.END_NPC_GONE)
	assert_eq(talk.session_count(), 0)


func test_waking_a_sleeper_is_a_choice_with_consequences() -> void:
	_idle = false
	var world: ServerWorld = _started()
	var player_id: String = _alice(world).player_id
	var calm_id: String = _spawn(world, FRIENDLY, NEAR)
	var timid_id: String = _spawn(world, TIMID, NEAR + Vector3(1.0, 0.0, 0.0))
	var rest: NpcActionDefinition = NpcActionCatalog.load_directory().get_action(NpcBehaviours.ACTION_REST)
	var behaviours: NpcBehaviours = _npcs(world).get_stage(NpcBehaviours.STAGE_ID) as NpcBehaviours
	for npc_id: String in [calm_id, timid_id]:
		var npc: NpcState = _npc(world, npc_id)
		var decision: NpcDecisionComponent = npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
		if decision.is_running():
			behaviours.cancel(world, _npcs(world), npc)
			decision.clear_action()
			decision.state = NpcDecisionState.IDLE
		assert_eq(behaviours.begin(world, _npcs(world), npc, rest, {}), "")
		decision.state = NpcDecisionState.PERFORM
		decision.set_action(rest.action_id, {}, _social(world).now_usec())
		assert_eq(NpcDecisionComponent.label_of(npc), "sleep", "test setup: it sleeps")
		assert_true(_social(world).is_asleep(npc, _social(world).now_usec()))
	var talk: NpcDialogue = _talk(world)
	var asleep: Dictionary = _begin(world, calm_id)
	assert_eq(_choice_ids(asleep), PackedStringArray(["wake", "leave"]))
	assert_eq(talk.talker_of(calm_id), "", "standing over a sleeper does not wake it")
	assert_eq(talk.partner_of(calm_id), player_id)
	var quiet: Dictionary = _choose(world, calm_id, asleep, NpcDialogue.CHOICE_LEAVE)
	assert_eq(str(quiet[NpcDialogue.KEY_LINE]), "", "leaving quietly: no word")
	assert_eq(_record(world, calm_id).wakes, 0)
	var woken: Dictionary = _choose(world, calm_id, _begin(world, calm_id), NpcDialogue.CHOICE_WAKE)
	assert_true(bool(woken[NpcDialogue.KEY_OPEN]), "a calm NPC grumbles and talks")
	assert_true(_choice_ids(woken).has("who"))
	assert_eq(_record(world, calm_id).wakes, 1)
	assert_true(_relationship(world, calm_id).trust < NpcReactionRules.trust(_view(1.0), _settings), "it cost some trust")
	_run(world, 0.5)
	assert_ne(NpcDecisionComponent.label_of(_npc(world, calm_id)), "sleep", "and it is awake")
	_choose(world, calm_id, talk.view_of(player_id), NpcDialogue.CHOICE_LEAVE)
	var startled: Dictionary = _choose(world, timid_id, _begin(world, timid_id), NpcDialogue.CHOICE_WAKE)
	assert_false(bool(startled[NpcDialogue.KEY_OPEN]), "a timid NPC is startled: no conversation")
	assert_eq(_bad, [[timid_id, player_id, NpcSocialState.BAD_WOKEN]])
	_run(world, 0.5)
	assert_ne(NpcDecisionComponent.label_of(_npc(world, timid_id)), "sleep", "it is awake too")


# ------------------------------------------------------------ save

func test_what_an_npc_thinks_of_a_player_survives_a_restart_the_talk_does_not() -> void:
	var world: ServerWorld = _started(WorldCellStore.new())
	var player_id: String = _alice(world).player_id
	var npc_id: String = _spawn(world, FRIENDLY, NEAR)
	_give_player(world, FOOD, 2)
	_run(world, 1.0)
	var view: Dictionary = _choose(world, npc_id, _begin(world, npc_id), NpcDialogue.CHOICE_GREET)
	view = _choose(world, npc_id, _choose(world, npc_id, view, NpcDialogue.CHOICE_GIVE), "give:0")
	view = _choose(world, npc_id, view, NpcDialogue.CHOICE_JOIN)
	assert_true(_talk(world).is_talking(player_id))
	_run(world, 0.5)
	var saved: Dictionary = JSON.parse_string(JSON.stringify(world.to_documents(), "", true, true)) as Dictionary
	_bad = []
	_joins = []
	var restored: ServerWorld = _world(WorldCellStore.new())
	assert_eq(restored.restore_documents(saved["world_state"], saved["players"], saved["cells"]).size(), 0)
	restored.join("alice")
	_run(restored, TICK)
	assert_false(_talk(restored).is_talking(player_id), "no conversation after a restart")
	assert_eq(_talk(restored).partner_of(npc_id), "")
	var before: RelationshipState = _relationship(world, npc_id)
	var after: RelationshipState = _relationship(restored, npc_id)
	assert_not_null(after)
	for axis: String in RelationshipState.AXES:
		assert_true(absf(float(after.get(axis)) - float(before.get(axis))) < 0.0000001, axis)
	assert_eq(JSON.stringify(_state(restored, npc_id).to_document()), JSON.stringify(_state(world, npc_id).to_document()), "the record came back as it was")
	assert_eq(_record(restored, npc_id).gifts_total, 1)
	assert_eq(_record(restored, npc_id).join_requests, 1)
	assert_eq(_units(restored, NpcSurvivalSense.inventory_of(_npc(restored, npc_id)), FOOD), 1, "it still carries the gift")
	assert_eq(_units(restored, _alice(restored).inventory_id, FOOD), 1)
	_run(restored, 1.0)
	assert_eq(_noticed.size(), 1, "the restored NPC does not notice the player anew: %s" % str(_noticed))
	assert_true(bool(_begin(restored, npc_id)[NpcDialogue.KEY_OPEN]), "and can be talked to again")
	assert_eq(_record(restored, npc_id).talks, 2)


func test_a_broken_social_document_is_refused() -> void:
	var state: NpcSocialState = NpcSocialState.new()
	assert_eq(state.restore_document({"schema_version": 1, "players": {}, "line_counter": 0}).size(), 0)
	assert_true(state.restore_document({"schema_version": 2, "players": {}, "line_counter": 0}).size() > 0)
	assert_true(state.restore_document({"schema_version": 1, "players": {"zombie_1": {}}, "line_counter": 0}).size() > 0)
	assert_true(state.restore_document({"schema_version": 1, "players": {"player_1": {"talks": -1}}, "line_counter": 0}).size() > 0)
	assert_true(state.restore_document({"schema_version": 1, "players": [], "line_counter": 0}).size() > 0)
	var good: NpcSocialState.Record = NpcSocialState.Record.new()
	good.talks = 3
	good.last_bad_reason = NpcSocialState.BAD_THREATENED
	var row: Dictionary = good.to_document()
	assert_eq(state.restore_document({"schema_version": 1, "players": {"player_7": row}, "line_counter": 5}).size(), 0)
	assert_eq(state.record_of("player_7").talks, 3)
	assert_eq(state.line_counter, 5)
	row["last_bad_reason"] = "Not An Id"
	assert_true(state.restore_document({"schema_version": 1, "players": {"player_7": row}, "line_counter": 5}).size() > 0)
	# The bound: the player it has not talked to for longest is forgotten.
	var bounded: NpcSocialState = NpcSocialState.new()
	bounded.ensure_record("player_1", 1.0, 2).last_talk_at = 5.0
	bounded.ensure_record("player_2", 2.0, 2)
	bounded.ensure_record("player_3", 3.0, 2)
	assert_eq(bounded.known_player_ids(), PackedStringArray(["player_1", "player_3"]))
	var social: NpcSocial = NpcSocial.new(_settings, null, null, 15.0, 86400.0, null, null)
	assert_true(social.restore_world_document({"schema_version": 9}).size() > 0)
	assert_true(social.restore_world_document({"schema_version": 1, "sight": {"npc_1": {"player_1": [true, 1, 2, "nonsense", 0.0, 0.0]}}, "signatures": {}, "roused_until": {}}).size() > 0)
	assert_eq(social.restore_world_document({"schema_version": 1, "sight": {"npc_1": {"player_1": [true, 1, 2, "wary", 0.5, 3.0]}}, "signatures": {"npc_1": "meet:watch:player_1"}, "roused_until": {}}).size(), 0)
	assert_eq(JSON.stringify(social.to_world_document()), JSON.stringify({"schema_version": 1, "sight": {"npc_1": {"player_1": [true, 1, 2, "wary", 0.5, 3.0]}}, "signatures": {"npc_1": "meet:watch:player_1"}, "roused_until": {}}))


# ------------------------------------------------------------ measurement

func test_measure_noticing_with_25_npcs_and_4_players() -> void:
	_idle = false
	var world: ServerWorld = _started()
	for key: String in ["bob", "carol", "dave"]:
		world.join(key)
	var ids: PackedStringArray = []
	for index: int in 25:
		ids.append(_spawn(world, [FRIENDLY, TIMID, BOLD][index % 3], SPAWN + Vector3(float(index % 5) * 2.0 - 4.0, 0.0, float(index / 5) * 2.0 - 12.0)))
	_run(world, 2.0)
	var social: NpcSocial = _social(world)
	var samples: Array[float] = []
	var whole: Array[float] = []
	for tick: int in 600:
		world.step_systems(1.0 / 60.0)
		samples.append(float(social.last_step_usec) / 1000.0)
		whole.append(_npcs(world).last_step_msec)
	samples.sort()
	whole.sort()
	var median: float = samples[samples.size() / 2]
	var p99: float = samples[int(samples.size() * 0.99)]
	var worst: float = samples[samples.size() - 1]
	print("[measure] F-31 noticing, 25 NPCs x 4 players, 600 ticks: social stage median %.3f ms, p99 %.3f ms, worst %.3f ms; all NPC stages median %.3f ms, p99 %.3f ms, worst %.3f ms; looks %d, decisions asked %d" % [median, p99, worst, whole[whole.size() / 2], whole[int(whole.size() * 0.99)], whole[whole.size() - 1], social.look_count, social.poke_count])
	assert_true(social.look_count >= 25, "every NPC looked")
	assert_time_bound(p99, 1.0, "F-31 social stage, 25 NPCs x 4 players, p99")
	assert_time_bound(worst, 2.0, "F-31 social stage, 25 NPCs x 4 players, worst")
