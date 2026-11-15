extends TestCase
## P2-T5 (docs/00 ADR-008): a player who dies of infection leaves one zombie
## where the player died. No network here. Survival only announces deaths
## (signal `player_died`); ZombieService decides (ServerComposition connects
## the two). Other causes of death leave no zombie, the zombie limit is
## respected, and the zombie is saved and restored like any other.

const WORLD: String = "player_zombie_test_world"
const DEATH_AT: Vector3 = Vector3(14.0, 0.0, -9.5)
const DEATH_YAW: float = 1.25
const TICK: float = 0.1
const LETHAL_DAMAGE: float = 100000.0
const NEVER: float = 1.0e9
## Every infection stage lasts this long (calendar hours): 3.6 world seconds.
const STAGE_HOURS: float = 0.001
## Real seconds that cover all five stages at the default 24x clock, with margin.
const INFECTION_RUN_SEC: float = 2.0
const SINGLE: String = "t5_single"

var _survival_settings: SurvivalSettings = null
var _zombie_settings: ZombieSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = ""
	_survival_settings = SurvivalSettings.new()
	_survival_settings.respawn_delay_sec = NEVER
	_survival_settings.infection_chance_bite = 1.0
	_survival_settings.infection_latent_hours = STAGE_HOURS
	_survival_settings.infection_early_hours = STAGE_HOURS
	_survival_settings.infection_progressing_hours = STAGE_HOURS
	_survival_settings.infection_severe_hours = STAGE_HOURS
	_survival_settings.infection_terminal_hours = STAGE_HOURS
	# Zombies exist but never see, hear, move or attack on their own.
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.sight_range_m = 0.0
	_zombie_settings.hearing_multiplier = 0.0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	_zombie_settings.wander_speed_mps = 0.0


func after_each() -> void:
	if not _root.is_empty():
		SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


# ------------------------------------------------------------ helpers

func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: never mutate them.
	config.survival = _survival_settings
	config.zombie = _zombie_settings
	config.dev_seed = DevWorldSeed.new()
	var catalog: ItemCatalog = ItemCatalog.load_directory()
	var single: ItemDefinition = ItemDefinition.new()
	single.definition_id = SINGLE
	catalog.add(single)
	config.catalog = catalog
	return config


func _world() -> ServerWorld:
	return ServerComposition.create_world(WORLD, _config())


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _infect(world: ServerWorld, player_id: String) -> void:
	var result: ActionResult = _survival(world).apply_infection_exposure(player_id, InfectionState.Exposure.BITE, "zombie_000001")
	if not result.ok or str(result.event.get("event_type", "")) != SurvivalService.EVENT_PLAYER_INFECTED:
		fail("test setup: infection failed: %s" % result.reason)


func _kill(world: ServerWorld, player_id: String) -> void:
	var result: ActionResult = _survival(world).apply_damage(player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.BRUISE, LETHAL_DAMAGE))
	if not result.ok:
		fail("test setup: kill failed: " + result.reason)


func _death_causes(events: Array[Dictionary], player_id: String) -> Array:
	var causes: Array = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == SurvivalService.EVENT_PLAYER_DIED and str(event.get("player_id", "")) == player_id:
			causes.append(str(event.get("cause", "")))
	return causes


func _events_of(events: Array[Dictionary], event_type: String) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for event: Dictionary in events:
		if str(event.get("event_type", "")) == event_type:
			matching.append(event)
	return matching


func _captured_text() -> String:
	return "\n".join(GameLogger.captured_lines())


# ------------------------------------------------------------ infection death

func test_a_player_who_dies_of_infection_leaves_one_zombie_where_it_died() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var zombies: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var item_id: String = world.inventory.spawn_world_item(SINGLE, 1, DevWorldSeed.DEV_CELL_ID, alice.position)
	assert_true(world.try_pickup(alice.player_id, item_id).ok)
	alice.position = DEATH_AT
	alice.yaw = DEATH_YAW
	_infect(world, alice.player_id)
	survival.drain_events()
	zombies.drain_events()
	assert_eq(zombies.zombie_count(), 0)

	_run(world, INFECTION_RUN_SEC)
	assert_false(survival.is_alive(alice.player_id), "alice turned")
	assert_eq(_death_causes(survival.drain_events(), alice.player_id), [SurvivalService.CAUSE_INFECTION])
	assert_eq(zombies.zombie_count(), 1, "exactly one zombie")
	assert_eq(zombies.player_zombie_count, 1)
	var zombie_id: String = zombies.zombie_ids()[0]
	var zombie: ZombieState = zombies.get_zombie(zombie_id)
	assert_eq(zombie.position, DEATH_AT, "where the player died")
	assert_true(absf(zombie.yaw - DEATH_YAW) < 0.000001, "facing the way the player faced")
	assert_true(zombie.is_alive())
	assert_eq(zombie.health, _zombie_settings.max_health, "a full-strength zombie")
	assert_eq(zombie.state, ZombieState.State.IDLE)
	assert_eq(world.registry.kind_of(zombie_id), ZombieService.ENTITY_KIND_ZOMBIE, "a registered entity with a normal zombie id")
	# The same event every other zombie produces: nothing in it names the player.
	var spawned: Array[Dictionary] = _events_of(zombies.drain_events(), ZombieService.EVENT_SPAWNED)
	assert_eq(spawned.size(), 1)
	assert_eq(spawned[0].get("zombie_id", ""), zombie_id)
	assert_eq(spawned[0].get("position", []), [DEATH_AT.x, DEATH_AT.y, DEATH_AT.z])
	assert_eq(spawned[0].keys().size(), 5, "event_type, zombie_id, world_time, position, yaw: %s" % str(spawned[0].keys()))
	for value: Variant in spawned[0].values():
		assert_ne(value, alice.player_id, "the zombie event does not say who it was")
	# The belongings lie at the same spot (P2-T4); the dead player stays dead.
	assert_eq(world.inventory.world_position_of(item_id), DEATH_AT)
	assert_eq(alice.position, DEATH_AT)
	# Nothing more appears while the world runs on, and bob was never touched.
	_run(world, 3.0)
	assert_eq(zombies.zombie_count(), 1, "one death, one zombie")
	assert_true(survival.is_alive(bob.player_id))
	assert_contains(_captured_text(), "player zombie spawned")


func test_the_new_character_does_not_bring_another_zombie() -> void:
	_survival_settings.respawn_delay_sec = 1.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var zombies: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	alice.position = DEATH_AT
	_infect(world, alice.player_id)
	_run(world, INFECTION_RUN_SEC + 2.0)
	assert_true(survival.is_alive(alice.player_id), "the new character started")
	assert_eq(alice.character_generation, 2)
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.NONE, "the new character is not infected")
	assert_eq(zombies.zombie_count(), 1)
	assert_eq(zombies.get_zombie(zombies.zombie_ids()[0]).position, DEATH_AT, "the zombie stays where the old character died")
	_run(world, INFECTION_RUN_SEC)
	assert_eq(zombies.zombie_count(), 1)
	assert_true(survival.is_alive(alice.player_id))


# ------------------------------------------------------------ other causes

func test_other_causes_of_death_leave_no_zombie() -> void:
	_survival_settings.dehydration_health_loss_per_world_sec = 1000.0
	# The infection of the bitten players below must not run out in this test.
	_survival_settings.infection_latent_hours = 1000.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var zombies: ZombieService = _zombies(world)
	var healthy: PlayerState = world.join("healthy")
	var infected: PlayerState = world.join("infected")
	var thirsty: PlayerState = world.join("thirsty")
	var bleeding: PlayerState = world.join("bleeding")
	# Combat: a healthy player, and a player who is infected but dies of the hit.
	_kill(world, healthy.player_id)
	_infect(world, infected.player_id)
	assert_eq(survival.infection_stage(infected.player_id), InfectionState.Stage.LATENT)
	_kill(world, infected.player_id)
	# Thirst and bleeding (survival rules inside the step).
	survival.get_vitals(thirsty.player_id).thirst = _survival_settings.need_max
	assert_true(survival.apply_damage(bleeding.player_id, DamageInput.create("zombie_000001", BodyPart.Part.TORSO, Wound.Type.LACERATION, _survival_settings.max_health - 0.001)).ok)
	_run(world, 1.0)
	var events: Array[Dictionary] = survival.drain_events()
	assert_eq(_death_causes(events, healthy.player_id), [SurvivalService.CAUSE_COMBAT])
	assert_eq(_death_causes(events, infected.player_id), [SurvivalService.CAUSE_COMBAT])
	assert_eq(_death_causes(events, thirsty.player_id), [SurvivalService.CAUSE_DEHYDRATION])
	assert_eq(_death_causes(events, bleeding.player_id), [SurvivalService.CAUSE_BLEEDING])
	assert_eq(zombies.zombie_count(), 0, "no death here was caused by infection")
	assert_eq(zombies.player_zombie_count, 0)
	assert_eq(zombies.skipped_player_zombie_count, 0, "nothing was skipped either: no zombie was due")


func test_which_causes_count_as_death_by_infection() -> void:
	assert_true(SurvivalService.is_infection_death(SurvivalService.CAUSE_INFECTION))
	# Infection health loss that killed together with something else.
	assert_true(SurvivalService.is_infection_death("bleeding_infection"))
	assert_true(SurvivalService.is_infection_death("starvation_dehydration_infection"))
	for cause: String in [SurvivalService.CAUSE_COMBAT, SurvivalService.CAUSE_BLEEDING, SurvivalService.CAUSE_STARVATION, SurvivalService.CAUSE_DEHYDRATION, SurvivalService.CAUSE_STARVATION_DEHYDRATION, "bleeding_starvation", "", "infection_x", "reinfection"]:
		assert_false(SurvivalService.is_infection_death(cause), cause)


func test_health_lost_to_the_infection_itself_is_a_death_by_infection() -> void:
	# The terminal stage drains health fast enough to kill before it ends.
	_survival_settings.infection_terminal_hours = 1000.0
	_survival_settings.infection_terminal_health_loss_per_world_sec = 1000.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var zombies: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	alice.position = DEATH_AT
	_infect(world, alice.player_id)
	survival.drain_events()
	_run(world, INFECTION_RUN_SEC)
	assert_false(survival.is_alive(alice.player_id))
	assert_eq(survival.infection_stage(alice.player_id), InfectionState.Stage.TERMINAL, "died before turning")
	assert_eq(_death_causes(survival.drain_events(), alice.player_id), [SurvivalService.CAUSE_INFECTION])
	assert_eq(zombies.zombie_count(), 1)
	assert_eq(zombies.get_zombie(zombies.zombie_ids()[0]).position, DEATH_AT)


# ------------------------------------------------------------ rule setting, limit

func test_the_rule_is_a_setting() -> void:
	# Never: an infection death leaves nothing.
	_zombie_settings.player_death_zombie_rule = ZombieSettings.PlayerDeathZombieRule.NEVER
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	_infect(world, alice.player_id)
	_run(world, INFECTION_RUN_SEC)
	assert_false(_survival(world).is_alive(alice.player_id))
	assert_eq(_zombies(world).zombie_count(), 0, "rule: never")

	# Any death while infected: the infected player killed by a hit turns,
	# a healthy player does not.
	_zombie_settings.player_death_zombie_rule = ZombieSettings.PlayerDeathZombieRule.INFECTED_AT_DEATH
	_survival_settings.infection_latent_hours = 1000.0
	world = _world()
	var infected: PlayerState = world.join("infected")
	var healthy: PlayerState = world.join("healthy")
	infected.position = DEATH_AT
	_infect(world, infected.player_id)
	_kill(world, healthy.player_id)
	assert_eq(_zombies(world).zombie_count(), 0, "a healthy player never turns")
	_kill(world, infected.player_id)
	assert_eq(_zombies(world).zombie_count(), 1, "rule: any death while infected")
	assert_eq(_zombies(world).get_zombie(_zombies(world).zombie_ids()[0]).position, DEATH_AT)

	# Settings validation.
	assert_eq(ZombieSettings.new().player_death_zombie_rule, ZombieSettings.PlayerDeathZombieRule.INFECTION_DEATH, "default rule")
	assert_eq(ZombieSettings.load_or_default().player_death_zombie_rule, ZombieSettings.PlayerDeathZombieRule.INFECTION_DEATH, "shipped rule")
	assert_eq(ZombieSettings.load_or_default().validate().size(), 0)
	var broken: ZombieSettings = ZombieSettings.new()
	broken.player_death_zombie_rule = 7
	assert_true(broken.validate().size() > 0, "an unknown rule is invalid")


func test_at_the_zombie_limit_the_player_zombie_is_skipped_and_logged() -> void:
	_zombie_settings.max_active_zombies = 1
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var zombies: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	assert_true(zombies.spawn_zombie(world, Vector3(50.0, 0.0, 50.0)).ok)
	var existing: PackedStringArray = zombies.zombie_ids()
	alice.position = DEATH_AT
	_infect(world, alice.player_id)
	_run(world, INFECTION_RUN_SEC)
	assert_false(survival.is_alive(alice.player_id), "the player still dies")
	assert_eq(zombies.zombie_ids(), existing, "no zombie beyond the limit")
	assert_eq(zombies.player_zombie_count, 0)
	assert_eq(zombies.skipped_player_zombie_count, 1, "the skipped spawn is counted")
	assert_contains(_captured_text(), "player zombie not spawned")
	assert_contains(_captured_text(), ZombieService.REASON_LIMIT)
	assert_not_contains(_captured_text(), "[ERROR]")
	# The death is not retried later, even when room appears.
	_zombie_settings.max_active_zombies = 10
	_run(world, 2.0)
	assert_eq(zombies.zombie_count(), 1)


func test_a_player_killed_by_a_zombie_can_turn_inside_the_zombie_step() -> void:
	# Rule "any death while infected": the lethal bite happens inside the
	# zombie system's own step. The new zombie must appear in that same step
	# without disturbing it.
	_zombie_settings.player_death_zombie_rule = ZombieSettings.PlayerDeathZombieRule.INFECTED_AT_DEATH
	_zombie_settings.sight_range_m = 25.0
	_zombie_settings.sight_half_angle_deg = 180.0
	_zombie_settings.attack_windup_sec = 0.0
	_zombie_settings.bite_chance = 1.0
	_zombie_settings.bite_damage = LETHAL_DAMAGE
	_survival_settings.infection_latent_hours = 1000.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var zombies: ZombieService = _zombies(world)
	var alice: PlayerState = world.join("alice")
	alice.position = DEATH_AT
	_infect(world, alice.player_id)
	assert_true(zombies.spawn_zombie(world, DEATH_AT + Vector3(1.0, 0.0, 0.0)).ok)
	var attacker_id: String = zombies.zombie_ids()[0]
	survival.drain_events()
	var ticks: int = 0
	while survival.is_alive(alice.player_id) and ticks < 100:
		world.step_systems(TICK)
		ticks += 1
	assert_false(survival.is_alive(alice.player_id), "the zombie killed alice")
	assert_eq(_death_causes(survival.drain_events(), alice.player_id), [SurvivalService.CAUSE_COMBAT])
	assert_eq(zombies.zombie_count(), 2, "the bitten, infected player turned in the same step")
	var turned_id: String = zombies.zombie_ids()[1]
	assert_ne(turned_id, attacker_id)
	assert_eq(zombies.get_zombie(turned_id).position, DEATH_AT)
	assert_true(zombies.get_zombie(attacker_id).is_alive(), "the attacker is unaffected")
	_run(world, 2.0)
	assert_eq(zombies.zombie_count(), 2)
	assert_not_contains(_captured_text(), "[ERROR]")


func test_a_world_without_zombies_just_lets_the_player_die() -> void:
	# No zombie system (and so nothing connected to the death signal).
	var config: CompositionConfig = _config()
	var world: ServerWorld = ServerWorld.new(WORLD, config.gameplay, config.catalog)
	world.clock = config.clock.create_clock()
	var survival: SurvivalService = SurvivalService.new(_survival_settings, world.ids, world.clock)
	assert_eq(world.register_system(survival), OK)
	var alice: PlayerState = world.join("alice")
	_infect(world, alice.player_id)
	_run(world, INFECTION_RUN_SEC)
	assert_false(survival.is_alive(alice.player_id))
	assert_eq(world.registry.ids_of_kind(ZombieService.ENTITY_KIND_ZOMBIE).size(), 0)
	assert_not_contains(_captured_text(), "[ERROR]")


# ------------------------------------------------------------ save round trip

func test_the_player_zombie_survives_a_save_and_restart() -> void:
	_root = "user://test_saves/player_zombie_%d" % Time.get_ticks_usec()
	var config: CompositionConfig = _config()
	var persistence: WorldPersistence = WorldPersistence.new(SaveService.new(_root), config)
	var world: ServerWorld = persistence.load_or_create(WORLD)
	assert_not_null(world)
	if world == null:
		return
	var alice: PlayerState = world.join("alice")
	alice.position = DEATH_AT
	alice.yaw = DEATH_YAW
	_infect(world, alice.player_id)
	_run(world, INFECTION_RUN_SEC)
	var zombies: ZombieService = _zombies(world)
	assert_eq(zombies.zombie_count(), 1)
	var zombie_id: String = zombies.zombie_ids()[0]
	var saved: Dictionary = zombies.get_zombie(zombie_id).to_dict()
	assert_eq(persistence.save(world), OK)

	var restored: ServerWorld = WorldPersistence.new(SaveService.new(_root), config).load_or_create(WORLD)
	assert_not_null(restored, "world restored from save")
	if restored == null:
		return
	var restored_zombies: ZombieService = _zombies(restored)
	assert_eq(restored_zombies.zombie_ids(), PackedStringArray([zombie_id]), "the same zombie, once")
	var zombie: ZombieState = restored_zombies.get_zombie(zombie_id)
	assert_eq(zombie.position, DEATH_AT)
	assert_true(zombie.is_alive())
	assert_eq(JSON.stringify(zombie.to_dict()), JSON.stringify(saved), "restored exactly as saved")
	assert_false(_survival(restored).is_alive(alice.player_id), "the player is still dead")
	# Logging in again does not make the death happen a second time.
	restored.join("alice")
	_run(restored, 3.0)
	assert_eq(restored_zombies.zombie_count(), 1)
	# New zombies get new ids.
	assert_true(restored_zombies.spawn_zombie(restored, Vector3.ZERO).ok)
	assert_true(EntityIdGenerator.sequence_of(restored_zombies.zombie_ids()[1]) > EntityIdGenerator.sequence_of(zombie_id))
