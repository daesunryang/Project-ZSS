extends TestCase
## F-25 (docs/09 §17.12): the NPCs' bodies. Damage, bleeding, infection,
## treatment by a player and by the NPC itself, death (the body, what it
## carried, the witnesses), rising as a zombie, and that all of it survives
## a save, a restart and a cell that leaves memory.

const WORLD: String = "npc_health_world"
const DEFINITION_ID: String = "f25_survivor"
const TICK: float = 0.1
const NEVER: float = 1.0e9
const TOLERANCE: float = 0.000001
## Alice stands here; yaw 0 faces -Z.
const SPAWN: Vector3 = Vector3(5.5, 0.0, 5.5)
## In reach of Alice's hands and bandages, straight ahead of her.
const NEAR: Vector3 = Vector3(5.5, 0.0, 4.4)
## In the next cell (still simulated), out of Alice's reach.
const ASIDE: Vector3 = Vector3(15.5, 0.0, 5.5)
## One metre from ASIDE on +Z: a zombie here that faces -Z looks at ASIDE
## and has Alice outside its view cone.
const ZOMBIE_SPOT: Vector3 = Vector3(15.5, 0.0, 6.5)
const FAR: Vector3 = Vector3(45.5, 0.0, 45.5)
const BANDAGE: String = "dev_bandage"
const CURE: String = "dev_cure"
const FOOD: String = "dev_food_ration"

var _survival: SurvivalSettings = null
var _health_settings: NpcHealthSettings = null
var _zombie_settings: ZombieSettings = null
var _cells: WorldCellSettings = null
var _with_behaviours: bool = false
var _with_health: bool = true


func before_each() -> void:
	GameLogger.set_capture(true)
	_survival = SurvivalSettings.new()
	# Nothing changes with time unless a test asks for it.
	_survival.health_recovery_per_world_sec = 0.0
	_survival.wound_recovery_per_world_sec = 0.0
	_survival.respawn_delay_sec = NEVER
	_health_settings = NpcHealthSettings.new()
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	_cells = WorldCellSettings.new()
	_cells.cell_size_m = 10.0
	_cells.bounds_min_m = Vector2(-50.0, -50.0)
	_cells.bounds_max_m = Vector2(50.0, 50.0)
	_cells.active_radius_cells = 1
	_cells.preload_radius_cells = 1
	_cells.preload_lookahead_sec = 0.0
	_cells.deactivate_delay_sec = 0.0
	_cells.unload_delay_sec = 0.5
	_cells.refresh_period_sec = 0.0
	_cells.max_preload_loads_per_refresh = 1000
	_with_behaviours = false
	_with_health = true


func after_each() -> void:
	GameLogger.set_capture(false)


func _definition() -> NpcDefinition:
	var definition: NpcDefinition = NpcDefinition.new()
	definition.definition_id = DEFINITION_ID
	definition.display_name = "체력 테스트"
	return definition


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	if not _with_behaviours:
		config.npc_behaviour = null
	config.npc_health = _health_settings if _with_health else null
	config.gameplay = GameplaySettings.new()
	config.gameplay.world_half_extent_m = 50.0
	config.gameplay.player_spawn_position = SPAWN
	config.clock = WorldClockSettings.new()
	config.survival = _survival
	config.zombie = _zombie_settings
	config.combat = CombatSettings.new()
	config.combat.damage_roll_min = 1.0
	config.combat.damage_roll_max = 1.0
	config.dev_seed = DevWorldSeed.new()
	config.world_cells = _cells
	config.map_content = null
	config.npc_spots = null
	config.npc = NpcSettings.new()
	config.npc_definitions = NpcCatalog.new()
	config.npc_definitions.add(_definition())
	return config


func _world(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_not_null(world, "the composition builds the world")
	(world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(store)
	return world


func _npcs(world: ServerWorld) -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _health(world: ServerWorld) -> NpcHealth:
	return NpcHealth.of_world(world)


func _vitals(world: ServerWorld, npc_id: String) -> NpcVitals:
	return _health(world).vitals_of(npc_id)


func _run(world: ServerWorld, seconds: float, tick: float = TICK) -> void:
	for step: int in range(roundi(seconds / tick)):
		world.step_systems(tick)


func _spawn(world: ServerWorld, position: Vector3) -> String:
	var result: ActionResult = _npcs(world).spawn_npc(world, DEFINITION_ID, position)
	assert_true(result.ok, result.reason)
	return str(result.event.get(NpcService.KEY_NPC_ID, ""))


## A world with Alice in it (the clock runs, her cells are simulated).
func _started(store: WorldCellStore = null) -> ServerWorld:
	var world: ServerWorld = _world(store)
	world.join("alice")
	_run(world, TICK)
	return world


func _alice(world: ServerWorld) -> PlayerState:
	return world.get_player(world.online_player_ids()[0])


func _hit(world: ServerWorld, npc_id: String, amount: float, type: Wound.Type = Wound.Type.LACERATION, source: String = "test_source") -> ActionResult:
	return _health(world).apply_damage(npc_id, DamageInput.create(source, BodyPart.Part.TORSO, type, amount))


func _give(world: ServerWorld, player: PlayerState, definition_id: String) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, 1, world.cell_id_at(player.position), player.position)
	assert_true(world.try_pickup(player.player_id, item_id).ok, "test setup: pick up " + definition_id)
	return item_id


func _carried(world: ServerWorld, npc_id: String) -> NpcBehaviourState:
	return _npcs(world).get_npc(npc_id).component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState


func _json(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value, "", false, true)) as Dictionary


func _vitals_document(world: ServerWorld, npc_id: String) -> Dictionary:
	return _json((_npcs(world).npc_document(npc_id)[NpcState.KEY_COMPONENTS] as Dictionary)[NpcVitals.COMPONENT_ID] as Dictionary)


func _fast_infection() -> void:
	_survival.infection_chance_bite = 1.0
	_survival.infection_chance_scratch = 1.0
	for property: String in ["infection_latent_hours", "infection_early_hours", "infection_progressing_hours", "infection_severe_hours", "infection_terminal_hours"]:
		_survival.set(property, 0.01)


# ------------------------------------------------------------ settings

func test_default_settings_are_valid_and_the_tuning_file_matches_them() -> void:
	assert_eq(_health_settings.validate().size(), 0)
	var loaded: NpcHealthSettings = NpcHealthSettings.load_or_default()
	assert_eq(loaded.validate().size(), 0)
	for property: Dictionary in _health_settings.get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			assert_eq(loaded.get(property["name"]), _health_settings.get(property["name"]), str(property["name"]))
	var broken: NpcHealthSettings = NpcHealthSettings.new()
	broken.melee_body_part = "tail"
	broken.rise_chance = 2.0
	broken.rise_delay_world_sec = -1.0
	broken.rise_retry_world_sec = 0.0
	assert_eq(broken.validate().size(), 4)


func test_a_new_npc_is_whole_and_costs_the_stage_nothing() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	var vitals: NpcVitals = _vitals(world, npc_id)
	assert_not_null(vitals, "every NPC has vitals")
	assert_eq(vitals.health, _survival.max_health)
	assert_true(vitals.is_alive() and vitals.is_untouched())
	assert_eq(vitals.condition(), NpcVitals.CONDITION_OK)
	assert_eq(NpcVitals.condition_of(_npcs(world).get_npc(npc_id)), NpcVitals.CONDITION_OK)
	var before: Dictionary = _vitals_document(world, npc_id)
	_run(world, 2.0)
	assert_eq(_health(world).last_hurt_count, 0, "a whole NPC is not looked at")
	assert_eq(_vitals_document(world, npc_id), before, "and nothing of it changes")


func test_without_health_settings_npcs_have_no_body_rules() -> void:
	_with_health = false
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	assert_null(_health(world))
	assert_null(NpcVitals.of(_npcs(world).get_npc(npc_id)))
	assert_eq(NpcVitals.condition_of(_npcs(world).get_npc(npc_id)), NpcVitals.CONDITION_OK)


# ------------------------------------------------------------ damage

func test_damage_makes_a_wound_and_lowers_health() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	var hit: ActionResult = _hit(world, npc_id, 20.0)
	assert_true(hit.ok, hit.reason)
	assert_eq(str(hit.event["event_type"]), NpcHealth.EVENT_WOUNDED)
	assert_eq(float(hit.event["health_after"]), _survival.max_health - 20.0)
	assert_false(bool(hit.event["died"]))
	var vitals: NpcVitals = _vitals(world, npc_id)
	assert_eq(vitals.injuries.size(), 1)
	assert_eq(vitals.injuries[0].wound_type, Wound.Type.LACERATION)
	assert_true(absf(vitals.injuries[0].severity - 20.0 / _survival.wound_severity_reference_damage) < TOLERANCE)
	assert_true(vitals.injuries[0].is_bleeding, "a cut this deep bleeds (the players' rule)")
	assert_true(vitals.injuries[0].wound_id.begins_with("wound_"))
	assert_eq(vitals.condition(), NpcVitals.CONDITION_HURT, "a bleeding NPC looks hurt")


func test_bad_damage_is_refused_and_changes_nothing() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	assert_eq(_hit(world, npc_id, 0.0).reason, DamageInput.REASON_BAD_AMOUNT)
	assert_eq(_hit(world, npc_id, NAN).reason, DamageInput.REASON_BAD_AMOUNT)
	assert_eq(_hit(world, npc_id, 5.0, Wound.Type.BRUISE, "").reason, DamageInput.REASON_BAD_SOURCE)
	assert_eq(_hit(world, "npc_999", 5.0).reason, NpcHealth.REASON_UNKNOWN_NPC)
	assert_eq(_health(world).apply_damage(npc_id, null).reason, DamageInput.REASON_BAD_AMOUNT)
	assert_true(_vitals(world, npc_id).is_untouched())


func test_a_bruise_does_not_bleed_and_low_health_looks_hurt() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	assert_true(_hit(world, npc_id, 30.0, Wound.Type.BRUISE).ok)
	var vitals: NpcVitals = _vitals(world, npc_id)
	assert_false(vitals.is_bleeding())
	assert_eq(vitals.condition(), NpcVitals.CONDITION_OK)
	assert_true(_hit(world, npc_id, 30.0, Wound.Type.BRUISE).ok)
	assert_eq(vitals.condition(), NpcVitals.CONDITION_HURT, "at or below half its health")


func test_bleeding_costs_health_by_the_players_rate_whatever_the_tick() -> void:
	var healths: Array[float] = []
	for tick: float in [0.1, 0.5]:
		var world: ServerWorld = _started()
		var npc_id: String = _spawn(world, NEAR)
		assert_true(_hit(world, npc_id, 25.0).ok)
		var start_health: float = _vitals(world, npc_id).health
		var start_time: float = world.clock.world_time_sec
		_run(world, 10.0, tick)
		var elapsed: float = world.clock.world_time_sec - start_time
		var rate: float = _survival.bleeding_health_loss_per_severity_per_world_sec * _survival.bleeding_laceration_multiplier * (25.0 / _survival.wound_severity_reference_damage)
		assert_true(absf(_vitals(world, npc_id).health - (start_health - rate * elapsed)) < 0.0001, "health after %s s of bleeding" % str(elapsed))
		healths.append(_vitals(world, npc_id).health)
	assert_true(absf(healths[0] - healths[1]) < 0.0001, "the tick length does not matter")


func test_an_npc_that_bleeds_out_dies_of_bleeding() -> void:
	_survival.bleeding_health_loss_per_severity_per_world_sec = 10.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	var deaths: Array = []
	_health(world).npc_died.connect(func(id: String, cause: String, killer: String) -> void: deaths.append([id, cause, killer]))
	assert_true(_hit(world, npc_id, 25.0).ok)
	_run(world, 2.0)
	var vitals: NpcVitals = _vitals(world, npc_id)
	assert_false(vitals.is_alive())
	assert_eq(vitals.health, 0.0)
	assert_eq(vitals.death_cause, SurvivalService.CAUSE_BLEEDING)
	assert_eq(vitals.killer_id, "")
	assert_true(vitals.died_at_world_time > 0.0 and vitals.died_at_world_time <= world.clock.world_time_sec)
	assert_eq(vitals.rise_at_world_time, NpcVitals.NO_RISE_TIME, "it was neither infected nor bitten")
	assert_eq(deaths, [[npc_id, SurvivalService.CAUSE_BLEEDING, ""]])
	assert_eq(_health(world).death_count, 1)


func test_health_and_wounds_recover_when_nothing_bleeds() -> void:
	_survival.health_recovery_per_world_sec = 1.0
	_survival.wound_recovery_per_world_sec = 0.05
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	assert_true(_hit(world, npc_id, 10.0, Wound.Type.BRUISE).ok)
	_run(world, 1.0)
	var vitals: NpcVitals = _vitals(world, npc_id)
	assert_eq(vitals.health, _survival.max_health)
	assert_true(vitals.injuries.is_empty(), "the bruise healed")
	_run(world, TICK)
	assert_eq(_health(world).last_hurt_count, 0, "a healed NPC is not looked at any more")


# ------------------------------------------------------------ zombies

func test_a_zombie_sees_attacks_and_infects_an_npc() -> void:
	_fast_infection()
	_zombie_settings.bite_chance = 1.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, ASIDE)
	var zombie_id: String = str(_zombies(world).spawn_zombie(world, ZOMBIE_SPOT, 0.0).event["zombie_id"])
	_zombies(world).drain_events()
	_run(world, 1.5)
	var zombie: ZombieState = _zombies(world).get_zombie(zombie_id)
	assert_eq(zombie.target_player_id, npc_id, "the zombie's target is the NPC")
	var attacks: Array[Dictionary] = []
	for event: Dictionary in _zombies(world).drain_events():
		if str(event["event_type"]) == ZombieService.EVENT_ATTACKED:
			attacks.append(event)
	assert_true(attacks.size() >= 1, "it attacked")
	assert_eq(str(attacks[0]["target_id"]), npc_id)
	assert_eq(str(attacks[0]["wound_type"]), "bite")
	assert_eq(str(attacks[0]["infection"]), NpcHealth.EVENT_INFECTED)
	var vitals: NpcVitals = _vitals(world, npc_id)
	assert_true(vitals.has_bite())
	assert_true(vitals.infection.is_infected())
	assert_eq(vitals.infection.source_id, zombie_id)
	assert_eq(vitals.infection.exposure, InfectionState.Exposure.BITE)
	assert_eq(_alice(world).position, SPAWN)
	assert_eq((world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService).get_vitals(_alice(world).player_id).health, _survival.max_health, "Alice, behind the zombie, was left alone")


func test_an_exposure_can_be_resisted_and_an_infected_npc_is_not_infected_twice() -> void:
	_survival.infection_chance_scratch = 0.0
	_survival.infection_chance_bite = 1.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	var resisted: ActionResult = _health(world).apply_infection_exposure(npc_id, InfectionState.Exposure.SCRATCH, "zombie_1")
	assert_true(resisted.ok)
	assert_eq(str(resisted.event["event_type"]), NpcHealth.EVENT_INFECTION_RESISTED)
	assert_false(_vitals(world, npc_id).infection.is_infected())
	var infected: ActionResult = _health(world).apply_infection_exposure(npc_id, InfectionState.Exposure.BITE, "zombie_1")
	assert_eq(str(infected.event["event_type"]), NpcHealth.EVENT_INFECTED)
	assert_eq(_vitals(world, npc_id).infection.stage, InfectionState.Stage.LATENT)
	assert_eq(_health(world).apply_infection_exposure(npc_id, InfectionState.Exposure.BITE, "zombie_1").reason, NpcHealth.REASON_ALREADY_INFECTED)
	assert_eq(_health(world).apply_infection_exposure("npc_999", InfectionState.Exposure.BITE, "zombie_1").reason, NpcHealth.REASON_UNKNOWN_NPC)


func test_the_infection_runs_its_stages_kills_and_the_body_rises() -> void:
	_fast_infection()
	_health_settings.rise_delay_world_sec = 48.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, ASIDE)
	var risen: Array = []
	_health(world).npc_rose.connect(func(id: String, zombie_id: String) -> void: risen.append([id, zombie_id]))
	assert_true(_health(world).apply_infection_exposure(npc_id, InfectionState.Exposure.BITE, "zombie_1").ok)
	var seen_stages: Dictionary[int, bool] = {}
	var vitals: NpcVitals = _vitals(world, npc_id)
	# Five stages of 36 calendar seconds each: 7.5 s at 24x.
	for step: int in range(80):
		world.step_systems(TICK)
		seen_stages[vitals.infection.stage] = true
		if not vitals.is_alive():
			break
	for stage: int in [InfectionState.Stage.LATENT, InfectionState.Stage.EARLY, InfectionState.Stage.PROGRESSING, InfectionState.Stage.SEVERE, InfectionState.Stage.TERMINAL]:
		assert_true(seen_stages.has(stage), "stage %s was passed" % InfectionState.STAGE_NAMES[stage])
	assert_false(vitals.is_alive())
	assert_eq(vitals.death_cause, SurvivalService.CAUSE_INFECTION)
	assert_true(absf(vitals.rise_at_world_time - (vitals.died_at_world_time + 48.0)) < TOLERANCE)
	assert_true(_npcs(world).has_npc(npc_id), "the body lies there")
	assert_false(_npcs(world).is_awake(npc_id), "and is never simulated")
	assert_eq(_zombies(world).zombie_count(), 0)
	var place: Vector3 = _npcs(world).get_npc(npc_id).position
	_run(world, 2.5)
	assert_eq(_zombies(world).zombie_count(), 1, "the body rose as one zombie")
	assert_eq(risen.size(), 1)
	assert_eq(str(risen[0][0]), npc_id)
	assert_eq(_zombies(world).get_zombie(str(risen[0][1])).position, place)
	assert_false(_npcs(world).has_npc(npc_id), "the NPC is gone")
	assert_false(_npcs(world).population_ids().has(npc_id))
	assert_eq(_health(world).rise_count, 1)
	assert_eq(_health(world).body_ids().size(), 0)


func test_a_bitten_npc_rises_and_an_unbitten_body_is_taken_out_later() -> void:
	_survival.infection_chance_bite = 0.0
	_health_settings.rise_delay_world_sec = 24.0
	_health_settings.body_remove_delay_world_sec = 24.0
	var world: ServerWorld = _started()
	var bitten_id: String = _spawn(world, ASIDE)
	var beaten_id: String = _spawn(world, NEAR)
	assert_true(_hit(world, bitten_id, 200.0, Wound.Type.BITE, "zombie_7").ok)
	assert_true(_hit(world, beaten_id, 200.0, Wound.Type.BRUISE, _alice(world).player_id).ok)
	assert_true(_vitals(world, bitten_id).rise_at_world_time > 0.0, "bitten, not infected: it rises (provisional)")
	assert_eq(_vitals(world, beaten_id).rise_at_world_time, NpcVitals.NO_RISE_TIME)
	assert_eq(_vitals(world, beaten_id).killer_id, _alice(world).player_id)
	assert_eq(_vitals(world, beaten_id).death_cause, SurvivalService.CAUSE_COMBAT)
	_run(world, 1.5)
	assert_eq(_zombies(world).zombie_count(), 1)
	assert_false(_npcs(world).has_npc(bitten_id))
	assert_false(_npcs(world).has_npc(beaten_id), "the other body was taken out")
	assert_eq(_health(world).body_removed_count, 1)


func test_the_rising_rules_can_be_turned_off() -> void:
	_health_settings.bitten_rise = false
	_health_settings.infected_rise = false
	_survival.infection_chance_bite = 1.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	assert_true(_health(world).apply_infection_exposure(npc_id, InfectionState.Exposure.BITE, "zombie_1").ok)
	assert_true(_hit(world, npc_id, 200.0, Wound.Type.BITE, "zombie_1").ok)
	assert_eq(_vitals(world, npc_id).rise_at_world_time, NpcVitals.NO_RISE_TIME)


func test_a_refused_rising_keeps_the_body_and_is_tried_again() -> void:
	_health_settings.rise_delay_world_sec = 0.0
	_health_settings.rise_retry_world_sec = 24.0
	_zombie_settings.max_active_zombies = 1
	_zombie_settings.sight_range_m = 0.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, ASIDE)
	var blocker_id: String = str(_zombies(world).spawn_zombie(world, FAR, 0.0).event["zombie_id"])
	assert_false(blocker_id.is_empty())
	assert_true(_hit(world, npc_id, 200.0, Wound.Type.BITE, "zombie_7").ok)
	_run(world, 0.3)
	assert_true(_health(world).refused_rise_count >= 1)
	assert_true(_npcs(world).has_npc(npc_id), "the body stays")
	assert_true(_vitals(world, npc_id).rise_at_world_time > world.clock.world_time_sec - 24.0)
	assert_eq(_zombies(world).zombie_count(), 1)


# ------------------------------------------------------------ melee

func test_a_players_swing_hits_and_kills_an_npc() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	var alice: PlayerState = _alice(world)
	var combat: CombatService = world.get_system(CombatService.SYSTEM_ID) as CombatService
	var weapon: MeleeWeaponDefinition = combat.weapon_for(world, alice.player_id)
	var swing: ActionResult = combat.request_melee_attack(world, alice.player_id, 0.0)
	assert_true(swing.ok, swing.reason)
	assert_true(bool(swing.event["hit"]))
	assert_eq(str(swing.event["target_id"]), npc_id)
	assert_true(absf(float(swing.event["damage"]) - weapon.base_damage) < TOLERANCE)
	assert_true(absf(float(swing.event["target_health_after"]) - (_survival.max_health - weapon.base_damage)) < TOLERANCE)
	var vitals: NpcVitals = _vitals(world, npc_id)
	assert_eq(vitals.injuries[0].wound_type, Wound.Type.BRUISE, "bare hands bruise")
	assert_eq(vitals.injuries[0].source_id, alice.player_id)
	assert_eq(vitals.injuries[0].body_part, BodyPart.Part.TORSO)
	# The other way: nothing behind her.
	_run(world, weapon.cooldown_sec + TICK)
	var miss: ActionResult = combat.request_melee_attack(world, alice.player_id, PI)
	assert_true(miss.ok and not bool(miss.event["hit"]))
	var died: bool = false
	for swing_index: int in range(200):
		_run(world, weapon.cooldown_sec + 2.0)
		var next: ActionResult = combat.request_melee_attack(world, alice.player_id, 0.0)
		if not next.ok:
			continue
		if bool(next.event["target_died"]):
			died = true
			break
	assert_true(died, "enough swings kill it")
	assert_false(vitals.is_alive())
	assert_eq(vitals.killer_id, alice.player_id)
	assert_eq(vitals.condition(), NpcVitals.CONDITION_DEAD)
	_run(world, weapon.cooldown_sec + 2.0)
	var after: ActionResult = combat.request_melee_attack(world, alice.player_id, 0.0)
	assert_true(after.ok and not bool(after.event["hit"]), "a body is not hit again")


func test_a_zombie_in_the_arc_is_hit_before_an_npc() -> void:
	_zombie_settings.sight_range_m = 0.0
	_zombie_settings.wander_speed_mps = 0.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	# Farther than the NPC, in the same direction.
	var zombie_id: String = str(_zombies(world).spawn_zombie(world, Vector3(5.5, 0.0, 4.0), 0.0).event["zombie_id"])
	var alice: PlayerState = _alice(world)
	var combat: CombatService = world.get_system(CombatService.SYSTEM_ID) as CombatService
	var swing: ActionResult = combat.request_melee_attack(world, alice.player_id, 0.0)
	assert_true(swing.ok, swing.reason)
	assert_eq(str(swing.event["target_id"]), zombie_id)
	assert_true(_vitals(world, npc_id).is_untouched())


func test_weapon_kinds_leave_their_wounds() -> void:
	var blade: MeleeWeaponDefinition = MeleeWeaponDefinition.new()
	blade.category = MeleeWeaponDefinition.Category.BLADE
	var axe: MeleeWeaponDefinition = MeleeWeaponDefinition.new()
	axe.category = MeleeWeaponDefinition.Category.AXE
	var blunt: MeleeWeaponDefinition = MeleeWeaponDefinition.new()
	blunt.category = MeleeWeaponDefinition.Category.BLUNT
	assert_eq(NpcMeleeTargets.wound_type_of(blade), Wound.Type.LACERATION)
	assert_eq(NpcMeleeTargets.wound_type_of(axe), Wound.Type.LACERATION)
	assert_eq(NpcMeleeTargets.wound_type_of(blunt), Wound.Type.BRUISE)
	assert_eq(NpcMeleeTargets.wound_type_of(null), Wound.Type.BRUISE)


# ------------------------------------------------------------ treatment

func test_a_player_bandages_and_cures_an_npc() -> void:
	_survival.infection_chance_bite = 1.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	var alice: PlayerState = _alice(world)
	var bandage_id: String = _give(world, alice, BANDAGE)
	var cure_id: String = _give(world, alice, CURE)
	var food_id: String = _give(world, alice, FOOD)
	assert_eq(ItemConsumption.try_use_on(world, alice.player_id, bandage_id, npc_id).reason, SurvivalService.REASON_NOT_BLEEDING)
	assert_eq(ItemConsumption.try_use_on(world, alice.player_id, cure_id, npc_id).reason, SurvivalService.REASON_NOT_INFECTED)
	assert_eq(ItemConsumption.try_use_on(world, alice.player_id, food_id, npc_id).reason, ItemConsumption.REASON_NOT_USABLE_ON_OTHERS, "food is not given to NPCs yet")
	assert_not_null(world.inventory.get_item(bandage_id), "a refused use takes nothing")
	assert_true(_hit(world, npc_id, 25.0).ok)
	assert_true(_health(world).apply_infection_exposure(npc_id, InfectionState.Exposure.BITE, "zombie_1").ok)
	var bandaged: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, bandage_id, npc_id)
	assert_true(bandaged.ok, bandaged.reason)
	assert_eq(str(bandaged.event["event_type"]), ItemConsumption.EVENT_ITEM_USED_ON_NPC)
	assert_eq(str(bandaged.event["target_id"]), npc_id)
	assert_eq((bandaged.event["bleeding_stopped_wound_ids"] as Array).size(), 1)
	assert_null(world.inventory.get_item(bandage_id), "the bandage was used up")
	assert_false(_vitals(world, npc_id).is_bleeding())
	var cured: ActionResult = ItemConsumption.try_use_on(world, alice.player_id, cure_id, npc_id)
	assert_true(cured.ok, cured.reason)
	assert_eq(str(cured.event["infection_cured_from"]), "latent")
	assert_false(_vitals(world, npc_id).infection.is_infected())


func test_a_treatment_needs_reach_and_a_living_npc() -> void:
	var world: ServerWorld = _started()
	var far_id: String = _spawn(world, ASIDE)
	var near_id: String = _spawn(world, NEAR)
	var alice: PlayerState = _alice(world)
	var bandage_id: String = _give(world, alice, BANDAGE)
	assert_true(_hit(world, far_id, 25.0).ok)
	assert_eq(ItemConsumption.try_use_on(world, alice.player_id, bandage_id, far_id).reason, ItemConsumption.REASON_TARGET_TOO_FAR)
	assert_true(_hit(world, near_id, 500.0).ok)
	assert_eq(ItemConsumption.try_use_on(world, alice.player_id, bandage_id, near_id).reason, ItemConsumption.REASON_TARGET_DEAD)
	assert_eq(ItemConsumption.try_use_on(world, alice.player_id, bandage_id, "npc_999").reason, ItemConsumption.REASON_TARGET_UNAVAILABLE)
	assert_not_null(world.inventory.get_item(bandage_id))


func test_a_cure_comes_too_late_after_the_treatable_stage() -> void:
	_fast_infection()
	_survival.infection_severe_hours = 1000.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	var alice: PlayerState = _alice(world)
	var cure_id: String = _give(world, alice, CURE)
	assert_true(_health(world).apply_infection_exposure(npc_id, InfectionState.Exposure.BITE, "zombie_1").ok)
	_run(world, 5.0)
	assert_eq(_vitals(world, npc_id).infection.stage, InfectionState.Stage.SEVERE)
	assert_eq(ItemConsumption.try_use_on(world, alice.player_id, cure_id, npc_id).reason, SurvivalService.REASON_TOO_LATE)


func test_an_npc_uses_the_bandage_and_the_cure_it_carries() -> void:
	_with_behaviours = true
	_survival.infection_chance_bite = 1.0
	_health_settings.self_treat_cooldown_world_sec = 24.0
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, ASIDE)
	var inventory_id: String = _carried(world, npc_id).inventory_id
	assert_false(world.inventory.spawn_detached_item(inventory_id, FOOD, 1).is_empty())
	assert_false(world.inventory.spawn_detached_item(inventory_id, BANDAGE, 1).is_empty())
	assert_false(world.inventory.spawn_detached_item(inventory_id, CURE, 1).is_empty())
	assert_true(_hit(world, npc_id, 25.0).ok)
	assert_true(_health(world).apply_infection_exposure(npc_id, InfectionState.Exposure.BITE, "zombie_1").ok)
	_run(world, 2 * TICK)
	var vitals: NpcVitals = _vitals(world, npc_id)
	assert_false(vitals.is_bleeding(), "it bandaged itself")
	assert_true(vitals.infection.is_infected(), "one treatment per look")
	assert_eq(_health(world).self_treat_count, 1)
	_run(world, 1.5)
	assert_false(vitals.infection.is_infected(), "after the cooldown it took the cure")
	assert_eq(_health(world).self_treat_count, 2)
	var left: PackedStringArray = []
	for item: ItemInstance in _carried(world, npc_id).carried_items():
		left.append(item.definition_id)
	assert_eq(left, PackedStringArray([FOOD]), "only the treatments were used up")


# ------------------------------------------------------------ death

func test_a_dead_npc_drops_what_it_carries_and_stops_for_good() -> void:
	_with_behaviours = true
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, ASIDE)
	var inventory_id: String = _carried(world, npc_id).inventory_id
	var food_id: String = world.inventory.spawn_detached_item(inventory_id, FOOD, 2)
	var bandage_id: String = world.inventory.spawn_detached_item(inventory_id, BANDAGE, 1)
	_run(world, 1.0)
	assert_true(_hit(world, npc_id, 500.0, Wound.Type.BRUISE, _alice(world).player_id).ok)
	var place: Vector3 = _npcs(world).get_npc(npc_id).position
	assert_eq(_carried(world, npc_id).carried_items().size(), 0, "it carries nothing any more")
	for item_id: String in [food_id, bandage_id]:
		var item: ItemInstance = world.inventory.get_item(item_id)
		assert_not_null(item, "the item still exists")
		assert_eq(item.location_type, ItemInstance.LOCATION_WORLD)
		assert_true(world.inventory.world_item_ids_in_cell(world.cell_id_at(place)).has(item_id), "it lies in the cell the NPC died in")
	assert_false(_npcs(world).is_awake(npc_id))
	assert_eq(_npcs(world).get_npc(npc_id).simulation_tier, NpcState.TIER_FROZEN)
	_run(world, 3.0)
	assert_eq(_npcs(world).get_npc(npc_id).position, place, "a body does not move")
	assert_false(_npcs(world).is_awake(npc_id), "and never wakes")
	assert_eq(_hit(world, npc_id, 5.0).reason, NpcHealth.REASON_NPC_DEAD)
	assert_true(_npcs(world).population_ids().has(npc_id), "the world still counts the body")


func test_npcs_that_see_a_death_remember_it_and_feel_it() -> void:
	var world: ServerWorld = _started()
	var dead_id: String = _spawn(world, ASIDE)
	var witness_id: String = _spawn(world, NEAR)
	var second_id: String = _spawn(world, Vector3(12.5, 0.0, 5.5))
	var away_id: String = _spawn(world, Vector3(5.5, 0.0, -4.5))
	_health_settings.witness_range_m = 12.0
	var killer_id: String = _alice(world).player_id
	assert_true(_hit(world, dead_id, 500.0, Wound.Type.LACERATION, killer_id).ok)
	var event_ids: Dictionary[String, bool] = {}
	for npc_id: String in [witness_id, second_id]:
		var npc: NpcState = _npcs(world).get_npc(npc_id)
		var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
		assert_eq(memories.count(), 1)
		var memory: NpcMemory = memories.memory(memories.memory_ids()[0])
		assert_eq(memory.event_type, NpcHealth.MEMORY_EVENT_DIED)
		assert_eq(memory.observation, NpcMemory.OBSERVATION_WITNESSED)
		assert_true(memory.interpretation_tags.has(NpcHealth.TAG_DEATH) and memory.interpretation_tags.has(NpcHealth.TAG_KILLED_BY_PLAYER))
		assert_eq(memory.participants, [{"entity_id": dead_id, "role": "target"}, {"entity_id": killer_id, "role": "actor"}] as Array[Dictionary])
		event_ids[memory.event_id] = true
		var emotions: NpcEmotions = npc.component(NpcEmotions.COMPONENT_ID) as NpcEmotions
		assert_true(absf(emotions.value_at("fear", world.clock.world_time_sec) - _health_settings.witness_fear) < TOLERANCE)
		assert_true(absf(emotions.value_at("grief", world.clock.world_time_sec) - _health_settings.witness_grief) < TOLERANCE)
	assert_eq(event_ids.size(), 1, "both remember the same event")
	var away: NpcMemoryStore = _npcs(world).get_npc(away_id).component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	assert_eq(away.count(), 0, "too far away to see it")
	var own: NpcMemoryStore = _npcs(world).get_npc(dead_id).component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	assert_eq(own.count(), 0)


# ------------------------------------------------------------ save

func test_vitals_round_trip_through_json_with_every_bit() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	assert_true(_hit(world, npc_id, 17.3).ok)
	assert_true(_hit(world, npc_id, 9.1, Wound.Type.BITE, "zombie_3").ok)
	_survival.infection_chance_bite = 1.0
	assert_true(_health(world).apply_infection_exposure(npc_id, InfectionState.Exposure.BITE, "zombie_3").ok)
	_run(world, 1.3)
	var source: NpcVitals = _vitals(world, npc_id)
	var document: Dictionary = _vitals_document(world, npc_id)
	var copy: NpcVitals = NpcVitals.new(_survival, _health_settings)
	assert_eq(copy.restore_document(document).size(), 0)
	assert_true(var_to_bytes(copy.health) == var_to_bytes(source.health), "health comes back with every bit")
	assert_eq(copy.injuries.size(), 2)
	for index: int in 2:
		assert_true(var_to_bytes(copy.injuries[index].severity) == var_to_bytes(source.injuries[index].severity))
		assert_eq(copy.injuries[index].wound_id, source.injuries[index].wound_id)
	assert_true(var_to_bytes(copy.infection.stage_elapsed_world_sec) == var_to_bytes(source.infection.stage_elapsed_world_sec))
	var again: Dictionary = copy.to_document()
	again[NpcComponent.KEY_SCHEMA_VERSION] = NpcVitals.SCHEMA_VERSION
	assert_eq(_json(again), document)


func test_malformed_vitals_are_refused() -> void:
	var world: ServerWorld = _started()
	var npc_id: String = _spawn(world, NEAR)
	assert_true(_hit(world, npc_id, 10.0).ok)
	var good: Dictionary = _vitals_document(world, npc_id)
	var cases: Array[Dictionary] = []
	for change: Array in [
		[NpcComponent.KEY_SCHEMA_VERSION, 99], [NpcVitals.KEY_HEALTH, "many"], [NpcVitals.KEY_HEALTH, 1000.0],
		[NpcVitals.KEY_INJURIES, "none"], [NpcVitals.KEY_INJURIES, [{"wound_id": ""}]], [NpcVitals.KEY_INFECTION, {}],
		[NpcVitals.KEY_DIED_AT, 5.0], [NpcVitals.KEY_DEATH_CAUSE, 3],
	]:
		var broken: Dictionary = good.duplicate(true)
		broken[change[0]] = change[1]
		broken.erase(NpcVitals.KEY_EXACT)
		cases.append(broken)
	for broken: Dictionary in cases:
		var vitals: NpcVitals = NpcVitals.new(_survival, _health_settings)
		assert_true(vitals.restore_document(broken).size() > 0, "refused: %s" % JSON.stringify(broken))
		assert_true(vitals.is_untouched(), "a refused document changes nothing")


func test_a_saved_world_goes_on_exactly_after_a_restart() -> void:
	_fast_infection()
	_survival.infection_latent_hours = 1000.0
	_health_settings.rise_delay_world_sec = 96.0
	var world: ServerWorld = _started(WorldCellStore.new())
	var hurt_id: String = _spawn(world, NEAR)
	var body_id: String = _spawn(world, ASIDE)
	assert_true(_hit(world, hurt_id, 25.0).ok)
	assert_true(_health(world).apply_infection_exposure(hurt_id, InfectionState.Exposure.BITE, "zombie_1").ok)
	assert_true(_hit(world, body_id, 500.0, Wound.Type.BITE, "zombie_1").ok)
	_run(world, 1.0)
	var saved: Dictionary = JSON.parse_string(JSON.stringify(world.to_documents(), "", true, true)) as Dictionary
	var restored: ServerWorld = _world(WorldCellStore.new())
	assert_eq(restored.restore_documents(saved["world_state"], saved["players"], saved["cells"]).size(), 0)
	restored.join("alice")
	assert_eq(_vitals_document(restored, hurt_id), _vitals_document(world, hurt_id), "the hurt NPC came back as it was")
	assert_eq(_vitals_document(restored, body_id), _vitals_document(world, body_id), "and so did the body")
	assert_false(_npcs(restored).is_awake(body_id), "a restored body is not simulated")
	assert_eq(_health(restored).body_ids(), PackedStringArray([body_id]))
	for both: ServerWorld in [world, restored]:
		_run(both, 2.0)
	assert_true(var_to_bytes(_vitals(restored, hurt_id).health) == var_to_bytes(_vitals(world, hurt_id).health), "bleeding went on with the same numbers: %s / %s" % [var_to_str(_vitals(restored, hurt_id).health), var_to_str(_vitals(world, hurt_id).health)])
	assert_true(_vitals(restored, hurt_id).health < _survival.max_health - 25.0)
	_run(restored, 2.0)
	assert_false(_npcs(restored).has_npc(body_id), "the restored body rose at its time")
	assert_eq(_zombies(restored).zombie_count(), 1)
	# The id is retired for good: the old cell file cannot bring it back.
	assert_false(_npcs(restored).population_ids().has(body_id))


func test_an_npc_saved_before_it_had_a_body_gets_a_whole_one() -> void:
	_with_health = false
	var old_world: ServerWorld = _started(WorldCellStore.new())
	var npc_id: String = _spawn(old_world, NEAR)
	_run(old_world, 0.5)
	var saved: Dictionary = JSON.parse_string(JSON.stringify(old_world.to_documents(), "", true, true)) as Dictionary
	assert_false(JSON.stringify(saved).contains("\"vitals\""), "the old save knows no vitals")
	_with_health = true
	var world: ServerWorld = _world(WorldCellStore.new())
	assert_eq(world.restore_documents(saved["world_state"], saved["players"], saved["cells"]).size(), 0)
	world.join("alice")
	_run(world, TICK)
	var vitals: NpcVitals = _vitals(world, npc_id)
	assert_not_null(vitals, "the old NPC has vitals now")
	assert_true(vitals.is_untouched())
	assert_true(_npcs(world).is_awake(npc_id))
	assert_true(_hit(world, npc_id, 10.0).ok, "and can be hurt like any other")


func test_hurt_and_dying_npcs_survive_their_cell_leaving_memory() -> void:
	_health_settings.rise_delay_world_sec = 24.0
	var world: ServerWorld = _started(WorldCellStore.new())
	var alice: PlayerState = _alice(world)
	var hurt_id: String = _spawn(world, NEAR)
	var body_id: String = _spawn(world, ASIDE)
	assert_true(_hit(world, hurt_id, 25.0).ok)
	assert_true(_hit(world, body_id, 500.0, Wound.Type.BITE, "zombie_1").ok)
	_run(world, TICK)
	var hurt_before: Dictionary = _vitals_document(world, hurt_id)
	var health_before: float = _vitals(world, hurt_id).health
	alice.position = FAR
	_run(world, 3.0)
	assert_false(_npcs(world).has_npc(hurt_id), "the hurt NPC left memory")
	assert_false(_npcs(world).has_npc(body_id), "the body left memory")
	assert_eq(_health(world).body_ids().size(), 0)
	assert_eq(_zombies(world).zombie_count(), 0, "a body does not rise while nobody is near")
	alice.position = SPAWN
	_run(world, TICK)
	assert_true(_npcs(world).has_npc(hurt_id), "the hurt NPC is back")
	var after: Dictionary = _vitals_document(world, hurt_id)
	assert_eq(after[NpcVitals.KEY_INJURIES], hurt_before[NpcVitals.KEY_INJURIES], "with the wound it had")
	# Three seconds away are 72 calendar seconds: 0.36 health of bleeding. It
	# lost one tick's worth instead: it was frozen while it was away.
	var lost: float = health_before - _vitals(world, hurt_id).health
	assert_true(lost > 0.0 and lost < 0.05, "it bleeds again, from where it was: lost %s" % str(lost))
	assert_false(_npcs(world).has_npc(body_id), "the body's time had come: it rose at once")
	assert_eq(_zombies(world).zombie_count(), 1)


# ------------------------------------------------------------ cost

func test_fifty_hurt_npcs_cost_little_per_tick() -> void:
	var world: ServerWorld = _started()
	for index: int in 50:
		var npc_id: String = _spawn(world, Vector3(-4.0 + float(index % 10), 0.0, -4.0 + float(index / 10)))
		assert_true(_hit(world, npc_id, 15.0).ok)
	var health: NpcHealth = _health(world)
	var npcs: NpcService = _npcs(world)
	_run(world, TICK)
	assert_eq(health.last_hurt_count, 50)
	var started_usec: int = Time.get_ticks_usec()
	var ticks: int = 200
	for tick: int in ticks:
		health.step(world, npcs, TICK, TICK * 24.0)
	var per_tick_ms: float = float(Time.get_ticks_usec() - started_usec) / 1000.0 / float(ticks)
	print("[measure] npc health: 50 hurt NPCs, %.4f ms per tick" % per_tick_ms)
	assert_time_bound(per_tick_ms, 1.0, "the health stage for 50 hurt NPCs")
