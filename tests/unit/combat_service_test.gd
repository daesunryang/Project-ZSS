extends TestCase
## P2-C1: CombatService — server-decided melee attacks against zombies:
## validation, target selection, damage, cooldown, stamina, weapons, noise,
## events, determinism and persistence.

const WORLD: String = "combat_test_world"
const TICK: float = 0.05
const NEVER: float = 1.0e9
## Yaw 0 faces -Z; -PI/2 faces +X; PI faces +Z.
const AIM_MINUS_Z: float = 0.0
const AIM_PLUS_X: float = -PI / 2.0
const AIM_PLUS_Z: float = PI
const TOLERANCE: float = 0.000001

const UNARMED: String = "unarmed"
const PIPE: String = "test_pipe"
const KNIFE: String = "test_knife"
const JUNK: String = "test_junk"

const UNARMED_DAMAGE: float = 10.0
const UNARMED_RANGE: float = 2.0
const UNARMED_ARC: float = 90.0
const UNARMED_COOLDOWN: float = 1.0
const UNARMED_STAMINA: float = 5.0
const UNARMED_NOISE: float = 6.0
const PIPE_DAMAGE: float = 40.0
const PIPE_COOLDOWN: float = 2.0
const PIPE_STAMINA: float = 20.0
const KNIFE_DAMAGE: float = 20.0

var _settings: CombatSettings = null
var _weapons: MeleeWeaponCatalog = null
var _items: ItemCatalog = null
var _zombie_settings: ZombieSettings = null
var _survival_settings: SurvivalSettings = null
var _noise_settings: NoiseSettings = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = CombatSettings.new()
	# Exact damage unless a test wants the random spread.
	_settings.damage_roll_min = 1.0
	_settings.damage_roll_max = 1.0
	_weapons = MeleeWeaponCatalog.new()
	_weapons.add(_weapon(UNARMED, MeleeWeaponDefinition.Category.UNARMED, "", UNARMED_DAMAGE, UNARMED_RANGE, UNARMED_ARC, UNARMED_COOLDOWN, UNARMED_STAMINA, UNARMED_NOISE))
	_weapons.add(_weapon(PIPE, MeleeWeaponDefinition.Category.BLUNT, PIPE, PIPE_DAMAGE, 3.0, 120.0, PIPE_COOLDOWN, PIPE_STAMINA, 15.0))
	_weapons.add(_weapon(KNIFE, MeleeWeaponDefinition.Category.BLADE, KNIFE, KNIFE_DAMAGE, 1.5, 60.0, 0.5, 4.0, 3.0))
	_items = ItemCatalog.new()
	for definition_id: String in [PIPE, KNIFE, JUNK]:
		var definition: ItemDefinition = ItemDefinition.new()
		definition.definition_id = definition_id
		definition.display_name = definition_id
		_items.add(definition)
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	# Blind zombies: they never chase or hit the attacker, so combat results
	# do not depend on zombie attacks. Hearing and damage alerts still work.
	_zombie_settings.sight_range_m = 0.0
	# ... and they stand still, so a hit zombie does not walk out of the arc.
	_zombie_settings.wander_speed_mps = 0.0
	_zombie_settings.investigate_speed_mps = 0.0
	_zombie_settings.chase_speed_mps = 0.0
	_zombie_settings.search_speed_mps = 0.0
	_survival_settings = SurvivalSettings.new()
	# Isolate combat from survival time rules (see zombie_service_test).
	_survival_settings.health_recovery_per_world_sec = 0.0
	_survival_settings.wound_recovery_per_world_sec = 0.0
	_survival_settings.stamina_regen_per_world_sec = 0.0
	_survival_settings.respawn_delay_world_sec = NEVER
	_noise_settings = NoiseSettings.new()
	_root = "user://test_saves/combat_%d" % Time.get_ticks_usec()


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


func _weapon(weapon_id: String, category: MeleeWeaponDefinition.Category, item_id: String, damage: float, range_m: float, arc_deg: float, cooldown: float, stamina: float, loudness: float) -> MeleeWeaponDefinition:
	var weapon: MeleeWeaponDefinition = MeleeWeaponDefinition.new()
	weapon.weapon_id = weapon_id
	weapon.display_name = weapon_id
	weapon.category = category
	weapon.item_definition_id = item_id
	weapon.base_damage = damage
	weapon.range_m = range_m
	weapon.arc_angle_deg = arc_deg
	weapon.cooldown_sec = cooldown
	weapon.stamina_cost = stamina
	weapon.noise_loudness = loudness
	return weapon


func _config() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.gameplay = GameplaySettings.new()
	config.catalog = _items
	config.clock = WorldClockSettings.new()
	config.survival = _survival_settings
	config.noise = _noise_settings
	config.zombie = _zombie_settings
	config.combat = _settings
	config.melee_weapons = _weapons
	return config


func _world() -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	world.seed_new_world(DevWorldSeed.new())
	return world


func _combat(world: ServerWorld) -> CombatService:
	return world.get_system(CombatService.SYSTEM_ID) as CombatService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


func _noise(world: ServerWorld) -> NoiseService:
	return world.get_system(NoiseService.SYSTEM_ID) as NoiseService


func _spawn(world: ServerWorld, position: Vector3, yaw: float = 0.0) -> String:
	return str(_zombies(world).spawn_zombie(world, position, yaw).event.get("zombie_id", ""))


func _health(world: ServerWorld, zombie_id: String) -> float:
	return _zombies(world).get_zombie(zombie_id).health


func _stamina(world: ServerWorld, player_id: String) -> float:
	return _survival(world).get_vitals(player_id).stamina


## Puts one item of `definition_id` into the player's inventory.
func _give(world: ServerWorld, player: PlayerState, definition_id: String) -> void:
	var item_id: String = world.inventory.spawn_world_item(definition_id, 1, DevWorldSeed.DEV_CELL_ID, player.position)
	assert_true(world.try_pickup(player.player_id, item_id).ok, "test setup: pick up " + definition_id)


func _run(world: ServerWorld, seconds: float) -> void:
	for tick: int in range(roundi(seconds / TICK)):
		world.step_systems(TICK)


func _attack(world: ServerWorld, player: PlayerState, aim_yaw: float = AIM_MINUS_Z) -> ActionResult:
	return _combat(world).request_melee_attack(world, player.player_id, aim_yaw)


# ------------------------------------------------------------ setup

func test_default_data_and_composition() -> void:
	var settings: CombatSettings = CombatSettings.load_or_default()
	assert_true(ResourceLoader.exists(CombatSettings.DEFAULT_PATH))
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	assert_false(settings.pvp_enabled, "docs/00: PvP is disabled by default")
	var weapons: MeleeWeaponCatalog = MeleeWeaponCatalog.load_directory()
	assert_true(weapons.has(settings.unarmed_weapon_id), "the default (unarmed) weapon is shipped")
	assert_eq(weapons.get_definition(settings.unarmed_weapon_id).category, MeleeWeaponDefinition.Category.UNARMED)
	assert_true(weapons.size() >= 2, "unarmed plus at least one development weapon")
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	for weapon_id: String in weapons.weapon_ids():
		var weapon: MeleeWeaponDefinition = weapons.get_definition(weapon_id)
		assert_true(weapon.item_definition_id.is_empty() or config.catalog.has(weapon.item_definition_id), "weapon item exists: " + weapon_id)
	var world: ServerWorld = ServerComposition.create_world(WORLD, config)
	var ids: PackedStringArray = world.system_ids()
	assert_true(ids.has(CombatService.SYSTEM_ID))
	assert_true(ids.find(CombatService.SYSTEM_ID) > ids.find(ZombieService.SYSTEM_ID), "combat is registered after the zombies it hits")
	assert_true(ids.find(CombatService.SYSTEM_ID) > ids.find(SurvivalService.SYSTEM_ID))
	config.combat = CombatSettings.new()
	config.combat.unarmed_weapon_id = "missing_weapon"
	assert_true(config.validate().size() > 0, "composition validation checks the weapon catalog")


# ------------------------------------------------------------ hit / miss

func test_hit_in_range_and_arc_damages_the_zombie() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, -1.5))
	var result: ActionResult = _attack(world, alice)
	assert_true(result.ok, result.reason)
	var event: Dictionary = result.event
	assert_eq(event["event_type"], CombatService.EVENT_MELEE_ATTACK)
	assert_eq(event["attacker_id"], alice.player_id)
	assert_eq(event["weapon_id"], UNARMED)
	assert_eq(event["aim_yaw"], AIM_MINUS_Z)
	assert_eq(event["hit"], true)
	assert_eq(event["target_id"], zombie_id)
	assert_eq(event["damage"], UNARMED_DAMAGE)
	assert_eq(event["target_health_after"], _zombie_settings.max_health - UNARMED_DAMAGE)
	assert_eq(event["target_died"], false)
	assert_eq(event["world_time"], world.clock.world_time_sec)
	assert_eq(event["position"], [alice.position.x, alice.position.y, alice.position.z])
	assert_true(SaveService.is_json_safe(event), "events are JSON-safe")
	assert_eq(_health(world, zombie_id), _zombie_settings.max_health - UNARMED_DAMAGE)
	assert_eq(_stamina(world, alice.player_id), _survival_settings.max_stamina - UNARMED_STAMINA)
	var drained: Array[Dictionary] = _combat(world).drain_events()
	assert_eq(drained.size(), 1)
	assert_eq(drained[0], event, "the queued event is the returned event")
	assert_eq(_combat(world).drain_events().size(), 0, "drain clears the queue")
	# The zombie learns who hit it through the zombie contract.
	var zombie_events: Array[Dictionary] = _zombies(world).drain_events()
	var damaged: Dictionary = zombie_events[zombie_events.size() - 1]
	assert_eq(damaged["event_type"], ZombieService.EVENT_DAMAGED)
	assert_eq(damaged["source_id"], alice.player_id)


func test_out_of_range_is_a_miss_that_still_costs_stamina_cooldown_and_noise() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, -(UNARMED_RANGE + 0.5)))
	var result: ActionResult = _attack(world, alice)
	assert_true(result.ok, "a swing at nothing is still an approved action")
	assert_eq(result.event["hit"], false)
	assert_eq(result.event["target_id"], "")
	assert_eq(result.event["damage"], 0.0)
	assert_eq(result.event["target_health_after"], 0.0)
	assert_eq(result.event["target_died"], false)
	assert_eq(_health(world, zombie_id), _zombie_settings.max_health)
	assert_eq(_stamina(world, alice.player_id), _survival_settings.max_stamina - UNARMED_STAMINA)
	assert_true(_combat(world).cooldown_remaining(alice.player_id) > 0.0)
	assert_eq(_noise(world).active_count(), 1, "a miss is as loud as a hit")
	assert_eq(_combat(world).drain_events().size(), 1)


func test_target_must_be_inside_the_arc() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	alice.position = Vector3(20, 0, 20)
	var zombie_id: String = _spawn(world, alice.position + Vector3(1.5, 0, 0))
	assert_eq(_attack(world, alice, AIM_MINUS_Z).event["hit"], false, "the zombie is 90 degrees to the side")
	_run(world, UNARMED_COOLDOWN + TICK)
	assert_eq(_attack(world, alice, AIM_PLUS_Z).event["hit"], false, "and not behind either")
	_run(world, UNARMED_COOLDOWN + TICK)
	var hit: ActionResult = _attack(world, alice, AIM_PLUS_X)
	assert_eq(hit.event["hit"], true, "aiming at it hits")
	assert_eq(hit.event["target_id"], zombie_id)
	assert_eq(_health(world, zombie_id), _zombie_settings.max_health - UNARMED_DAMAGE)
	# The stored facing of the player is not used and not changed.
	assert_eq(alice.yaw, 0.0)


func test_nearest_living_zombie_in_the_arc_is_chosen() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var far: String = _spawn(world, Vector3(0, 0, -1.8))
	var corpse: String = _spawn(world, Vector3(0, 0, -0.5))
	var behind: String = _spawn(world, Vector3(0, 0, 0.4))
	var near: String = _spawn(world, Vector3(0.2, 0, -1.0))
	assert_true(_zombies(world).apply_damage_to_zombie(corpse, 1000.0, alice.player_id).ok)
	var result: ActionResult = _attack(world, alice)
	assert_eq(result.event["target_id"], near, "nearest living zombie in front")
	for untouched: String in [far, behind]:
		assert_eq(_health(world, untouched), _zombie_settings.max_health, "only one zombie is hit per swing")
	assert_eq(_health(world, corpse), 0.0)


func test_equally_near_zombies_resolve_by_id() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var first: String = _spawn(world, Vector3(0.5, 0, -1.0))
	var second: String = _spawn(world, Vector3(-0.5, 0, -1.0))
	assert_true(first < second)
	assert_eq(_attack(world, alice).event["target_id"], first)


func test_players_are_never_targets_while_pvp_is_disabled() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	bob.position = Vector3(0, 0, -1.0)
	var result: ActionResult = _attack(world, alice)
	assert_true(result.ok)
	assert_eq(result.event["hit"], false)
	assert_eq(_survival(world).get_vitals(bob.player_id).health, _survival_settings.max_health)
	assert_eq(_survival(world).get_vitals(bob.player_id).injuries.size(), 0)


# ------------------------------------------------------------ validation

func test_cooldown_runs_on_world_time() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, -1.0))
	var combat: CombatService = _combat(world)
	assert_eq(combat.cooldown_remaining(alice.player_id), 0.0)
	assert_true(_attack(world, alice).ok)
	assert_true(absf(combat.cooldown_remaining(alice.player_id) - UNARMED_COOLDOWN) <= TOLERANCE)
	var stamina: float = _stamina(world, alice.player_id)
	combat.drain_events()
	var noises: int = _noise(world).active_count()

	var early: ActionResult = _attack(world, alice)
	assert_false(early.ok)
	assert_eq(early.reason, CombatService.REASON_ON_COOLDOWN)
	_run(world, UNARMED_COOLDOWN * 0.5)
	assert_eq(_attack(world, alice).reason, CombatService.REASON_ON_COOLDOWN)
	assert_eq(_stamina(world, alice.player_id), stamina, "a rejected attack costs nothing")
	assert_eq(_health(world, zombie_id), _zombie_settings.max_health - UNARMED_DAMAGE)
	assert_eq(combat.drain_events().size(), 0, "and makes no event")
	assert_eq(_noise(world).active_count(), noises, "and no noise")

	# Reconnecting does not reset the cooldown.
	world.leave(alice.player_id)
	assert_not_null(world.join("alice"))
	assert_eq(_attack(world, alice).reason, CombatService.REASON_ON_COOLDOWN)

	_run(world, UNARMED_COOLDOWN * 0.5 + TICK)
	assert_eq(combat.cooldown_remaining(alice.player_id), 0.0)
	assert_true(_attack(world, alice).ok, "ready again after the weapon cooldown")
	assert_eq(_health(world, zombie_id), _zombie_settings.max_health - UNARMED_DAMAGE * 2.0)


func test_not_enough_stamina_is_rejected_without_side_effects() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, -1.0))
	assert_true(_survival(world).try_spend_stamina(alice.player_id, _survival_settings.max_stamina - UNARMED_STAMINA + 1.0))
	var left: float = _stamina(world, alice.player_id)
	var result: ActionResult = _attack(world, alice)
	assert_false(result.ok)
	assert_eq(result.reason, CombatService.REASON_NOT_ENOUGH_STAMINA)
	assert_eq(_stamina(world, alice.player_id), left)
	assert_eq(_health(world, zombie_id), _zombie_settings.max_health)
	assert_eq(_combat(world).cooldown_remaining(alice.player_id), 0.0, "no cooldown for a rejected attack")
	assert_eq(_combat(world).drain_events().size(), 0)
	assert_eq(_noise(world).active_count(), 0)


func test_unknown_offline_and_dead_players_are_rejected() -> void:
	var world: ServerWorld = _world()
	var combat: CombatService = _combat(world)
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var zombie_id: String = _spawn(world, Vector3(0, 0, -1.0))
	assert_eq(combat.request_melee_attack(world, "player_999999", AIM_MINUS_Z).reason, CombatService.REASON_UNKNOWN_PLAYER)
	assert_eq(combat.request_melee_attack(world, "", AIM_MINUS_Z).reason, CombatService.REASON_UNKNOWN_PLAYER)
	assert_eq(combat.request_melee_attack(world, zombie_id, AIM_MINUS_Z).reason, CombatService.REASON_UNKNOWN_PLAYER, "only players attack")
	assert_eq(combat.request_melee_attack(null, alice.player_id, AIM_MINUS_Z).reason, CombatService.REASON_UNAVAILABLE)

	world.leave(bob.player_id)
	assert_eq(combat.request_melee_attack(world, bob.player_id, AIM_MINUS_Z).reason, CombatService.REASON_NOT_ONLINE)

	var fatal: DamageInput = DamageInput.create("zombie_000099", BodyPart.Part.TORSO, Wound.Type.BITE, 1000.0)
	assert_true(_survival(world).apply_damage(alice.player_id, fatal).ok)
	assert_eq(_attack(world, alice).reason, CombatService.REASON_PLAYER_DEAD)

	assert_eq(_health(world, zombie_id), _zombie_settings.max_health)
	assert_eq(combat.drain_events().size(), 0)
	assert_eq(_noise(world).active_count(), 0)
	assert_eq(combat.to_world_document()["rng_state"], _combat(_world()).to_world_document()["rng_state"], "rejected requests do not advance the RNG")


func test_invalid_aim_yaw_is_rejected() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, -1.0))
	for bad: float in [NAN, INF, -INF, _settings.max_abs_aim_yaw + 0.5, -100.0]:
		var result: ActionResult = _attack(world, alice, bad)
		assert_false(result.ok)
		assert_eq(result.reason, CombatService.REASON_BAD_AIM_YAW, "aim %s" % str(bad))
	assert_eq(_stamina(world, alice.player_id), _survival_settings.max_stamina)
	assert_eq(_health(world, zombie_id), _zombie_settings.max_health)
	assert_eq(_combat(world).drain_events().size(), 0)
	# A full turn is still a valid facing and is reported normalized.
	var full_turn: ActionResult = _attack(world, alice, TAU)
	assert_true(full_turn.ok, full_turn.reason)
	assert_true(absf(float(full_turn.event["aim_yaw"])) <= TOLERANCE, "TAU is the same facing as 0")
	assert_eq(full_turn.event["target_id"], zombie_id)


func test_combat_needs_its_companion_systems() -> void:
	var world: ServerWorld = ServerWorld.new(WORLD, GameplaySettings.new(), _items)
	var combat: CombatService = CombatService.new(_settings, _weapons, world.clock)
	assert_eq(world.register_system(combat), OK)
	var alice: PlayerState = world.join("alice")
	assert_eq(combat.request_melee_attack(world, alice.player_id, AIM_MINUS_Z).reason, CombatService.REASON_UNAVAILABLE)


# ------------------------------------------------------------ damage

func test_arm_wounds_reduce_damage() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var survival: SurvivalService = _survival(world)
	var zombie_id: String = _spawn(world, Vector3(0, 0, -1.0))
	# A leg wound does not change weapon handling.
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000099", BodyPart.Part.LEFT_LEG, Wound.Type.BRUISE, 10.0)).ok)
	assert_eq(_attack(world, alice).event["damage"], UNARMED_DAMAGE)
	_run(world, UNARMED_COOLDOWN + TICK)
	assert_true(survival.apply_damage(alice.player_id, DamageInput.create("zombie_000099", BodyPart.Part.RIGHT_ARM, Wound.Type.BRUISE, 25.0)).ok)
	var handling: float = survival.handling_multiplier(alice.player_id)
	assert_true(handling < 1.0 and handling > 0.0, "the arm wound lowers handling")
	var before: float = _health(world, zombie_id)
	var result: ActionResult = _attack(world, alice)
	assert_true(result.ok, result.reason)
	assert_true(absf(float(result.event["damage"]) - UNARMED_DAMAGE * handling) <= TOLERANCE)
	assert_true(float(result.event["damage"]) < UNARMED_DAMAGE)
	assert_true(absf(_health(world, zombie_id) - (before - UNARMED_DAMAGE * handling)) <= TOLERANCE)


func test_repeated_attacks_kill_the_zombie() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	_give(world, alice, PIPE)
	var zombie_id: String = _spawn(world, Vector3(0, 0, -2.5))
	var hits: int = 0
	var last: Dictionary = {}
	while _zombies(world).get_zombie(zombie_id).is_alive() and hits < 10:
		var result: ActionResult = _attack(world, alice)
		assert_true(result.ok, result.reason)
		assert_eq(result.event["weapon_id"], PIPE)
		assert_eq(result.event["target_id"], zombie_id)
		last = result.event
		hits += 1
		_run(world, PIPE_COOLDOWN + TICK)
	assert_eq(hits, ceili(_zombie_settings.max_health / PIPE_DAMAGE), "100 health / 40 damage = 3 hits")
	assert_eq(last["target_died"], true)
	assert_eq(last["target_health_after"], 0.0)
	assert_eq(_zombies(world).living_count(), 0)
	assert_eq(_stamina(world, alice.player_id), _survival_settings.max_stamina - PIPE_STAMINA * hits)
	var died: Array[Dictionary] = _zombies(world).drain_events().filter(func(event: Dictionary) -> bool: return event["event_type"] == ZombieService.EVENT_DIED)
	assert_eq(died.size(), 1)
	assert_eq(died[0]["source_id"], alice.player_id)
	var after: ActionResult = _attack(world, alice)
	assert_true(after.ok)
	assert_eq(after.event["hit"], false, "a corpse is not a target")


# ------------------------------------------------------------ weapons

func test_weapon_comes_from_the_inventory() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var combat: CombatService = _combat(world)
	assert_eq(combat.weapon_for(world, alice.player_id).weapon_id, UNARMED, "empty hands by default")
	_give(world, alice, JUNK)
	assert_eq(combat.weapon_for(world, alice.player_id).weapon_id, UNARMED, "items that are not weapons are ignored")
	_give(world, alice, KNIFE)
	assert_eq(combat.weapon_for(world, alice.player_id).weapon_id, KNIFE)
	_give(world, alice, PIPE)
	assert_eq(combat.weapon_for(world, alice.player_id).weapon_id, PIPE, "default rule: highest base damage")
	assert_null(combat.weapon_for(world, "player_999999"))

	_settings.inventory_weapon_rule = CombatSettings.WeaponRule.FIRST_SLOT
	assert_eq(combat.weapon_for(world, alice.player_id).weapon_id, KNIFE, "first weapon by slot")
	_settings.inventory_weapon_rule = CombatSettings.WeaponRule.UNARMED_ONLY
	assert_eq(combat.weapon_for(world, alice.player_id).weapon_id, UNARMED)

	# Another player's items do not count, and the weapon decides the numbers.
	_settings.inventory_weapon_rule = CombatSettings.WeaponRule.HIGHEST_DAMAGE
	var bob: PlayerState = world.join("bob")
	assert_eq(combat.weapon_for(world, bob.player_id).weapon_id, UNARMED)
	var zombie_id: String = _spawn(world, Vector3(0, 0, -2.5))
	assert_eq(_attack(world, bob).event["hit"], false, "out of reach of bare hands")
	var hit: ActionResult = _attack(world, alice)
	assert_eq(hit.event["weapon_id"], PIPE)
	assert_eq(hit.event["target_id"], zombie_id, "the pipe reaches further")
	assert_eq(hit.event["damage"], PIPE_DAMAGE)
	assert_eq(_stamina(world, alice.player_id), _survival_settings.max_stamina - PIPE_STAMINA)
	assert_true(absf(combat.cooldown_remaining(alice.player_id) - PIPE_COOLDOWN) <= TOLERANCE)


func test_first_slot_rule_orders_slots_numerically() -> void:
	_settings.inventory_weapon_rule = CombatSettings.WeaponRule.FIRST_SLOT
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	# slot_0, slot_1: junk; slot_2: pipe; slot_3..slot_9: junk; slot_10: knife.
	for index: int in range(11):
		_give(world, alice, PIPE if index == 2 else (KNIFE if index == 10 else JUNK))
	assert_eq(_combat(world).weapon_for(world, alice.player_id).weapon_id, PIPE, "slot_2 comes before slot_10")


# ------------------------------------------------------------ noise

func test_attack_noise_makes_a_nearby_zombie_investigate() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombies: ZombieService = _zombies(world)
	# Both are outside the arc. `near` is inside the hearing distance of the
	# swing, `far` is not.
	var near: String = _spawn(world, Vector3(0, 0, 4.0), AIM_PLUS_Z)
	var far: String = _spawn(world, Vector3(0, 0, 30.0), AIM_PLUS_Z)
	assert_true(_noise(world).max_audible_distance(UNARMED_NOISE, _zombie_settings.hearing_multiplier) > 4.0)
	assert_true(_noise(world).max_audible_distance(UNARMED_NOISE, _zombie_settings.hearing_multiplier) < 30.0)
	_run(world, 1.0)
	assert_eq(ZombieState.state_name(zombies.get_zombie(near).state), "idle")
	zombies.drain_events()

	var result: ActionResult = _attack(world, alice)
	assert_eq(result.event["hit"], false, "nothing was hit: the reaction comes from the noise alone")
	var noise: NoiseService = _noise(world)
	assert_eq(noise.active_count(), 1)
	var heard: Array[NoisePerception] = noise.query_audible(alice.position, 1.0, NoiseService.SINCE_ALWAYS)
	assert_eq(heard.size(), 1)
	assert_eq(heard[0].event.source_id, alice.player_id)
	assert_eq(heard[0].event.loudness, UNARMED_NOISE)
	assert_eq(heard[0].event.position, alice.position)
	_run(world, 1.0)

	assert_eq(ZombieState.state_name(zombies.get_zombie(near).state), "investigate")
	assert_eq(ZombieState.state_name(zombies.get_zombie(far).state), "idle")
	var detected: Array[Dictionary] = zombies.drain_events().filter(func(event: Dictionary) -> bool: return event["event_type"] == ZombieService.EVENT_DETECTED)
	assert_eq(detected.size(), 1)
	assert_eq(detected[0]["zombie_id"], near)
	assert_eq(detected[0]["sense"], ZombieService.SENSE_SOUND)
	assert_eq(detected[0]["target_id"], alice.player_id, "the noise source is the attacker")


func test_silent_weapon_makes_no_noise() -> void:
	_weapons.get_definition(UNARMED).noise_loudness = 0.0
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	assert_true(_attack(world, alice).ok)
	assert_eq(_noise(world).active_count(), 0)


# ------------------------------------------------------------ events

func test_event_queue_is_capped_and_drops_the_oldest() -> void:
	_settings.max_pending_events = 3
	_weapons.get_definition(UNARMED).cooldown_sec = 0.0
	_weapons.get_definition(UNARMED).stamina_cost = 0.0
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var combat: CombatService = _combat(world)
	var yaws: Array[float] = [0.0, 0.1, 0.2, 0.3, 0.4]
	for yaw: float in yaws:
		assert_true(_attack(world, alice, yaw).ok)
	var events: Array[Dictionary] = combat.drain_events()
	assert_eq(events.size(), 3)
	assert_eq(combat.dropped_event_count, 2)
	assert_eq(events[0]["aim_yaw"], 0.2, "the oldest events were dropped")
	assert_eq(events[2]["aim_yaw"], 0.4)


# ------------------------------------------------------------ determinism

## Runs a fixed sequence of attacks with the random damage spread and
## returns every event as JSON.
func _simulate(rng_seed: int) -> String:
	_settings.rng_seed = rng_seed
	_settings.damage_roll_min = 0.5
	_settings.damage_roll_max = 1.5
	_zombie_settings.max_health = 100000.0
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	_spawn(world, Vector3(0, 0, -1.0))
	_spawn(world, Vector3(1.0, 0, 0))
	var entries: Array[Dictionary] = []
	for index: int in range(12):
		var result: ActionResult = _attack(world, alice, AIM_MINUS_Z if index % 3 != 2 else AIM_PLUS_X)
		entries.append(result.event)
		_run(world, UNARMED_COOLDOWN + TICK)
	return JSON.stringify(entries)


func test_same_seed_gives_identical_damage() -> void:
	var first: String = _simulate(42)
	var second: String = _simulate(42)
	assert_true(first == second, "same seed + same requests -> identical events")
	assert_true(_simulate(43) != first, "another seed rolls other damage")
	var damages: Dictionary = {}
	for event: Variant in JSON.parse_string(first) as Array:
		var damage: float = float((event as Dictionary)["damage"])
		assert_true(damage >= UNARMED_DAMAGE * 0.5 and damage <= UNARMED_DAMAGE * 1.5, "inside the configured spread: %f" % damage)
		damages[damage] = true
	assert_true(damages.size() > 6, "the rolls differ from each other")


# ------------------------------------------------------------ persistence

func test_save_load_continues_the_rng_and_drops_cooldowns() -> void:
	_settings.rng_seed = 7
	_settings.damage_roll_min = 0.5
	_settings.damage_roll_max = 1.5
	_zombie_settings.max_health = 100000.0
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var zombie_id: String = _spawn(world, Vector3(0, 0, -1.0))
	for index: int in range(3):
		assert_true(_attack(world, alice).ok)
		_run(world, UNARMED_COOLDOWN + TICK)
	assert_true(_attack(world, alice).ok)  # leaves a running cooldown behind
	assert_true(_combat(world).cooldown_remaining(alice.player_id) > 0.0)

	var documents: Dictionary = world.to_documents()
	var saved: Dictionary = (documents["world_state"] as Dictionary)[ServerWorld.KEY_SYSTEMS][CombatService.SYSTEM_ID]
	assert_eq(saved["schema_version"], CombatService.SCHEMA_VERSION)
	assert_true(SaveService.is_json_safe(saved), "the combat document is JSON-safe")
	assert_eq(saved.size(), 3, "only schema_version, rng_seed and rng_state are saved")
	assert_eq(SaveService.new(_root).save_world(WORLD, documents["world_state"], documents["players"]), OK)

	var loaded: Dictionary = SaveService.new(_root).load_world(WORLD)
	assert_eq(loaded["error"], OK)
	var restored_world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_eq(restored_world.restore_documents(loaded["world_state"], loaded["players"]).size(), 0)
	var restored: CombatService = _combat(restored_world)
	assert_eq(restored.to_world_document(), _combat(world).to_world_document(), "RNG seed and state survive save -> recreate -> load")
	var restored_alice: PlayerState = restored_world.join("alice")
	assert_eq(restored_alice.player_id, alice.player_id)
	assert_eq(restored.cooldown_remaining(alice.player_id), 0.0, "cooldowns are not saved")

	# The damage rolls continue exactly where the saved world stopped.
	_run(world, UNARMED_COOLDOWN + TICK)
	for index: int in range(4):
		var expected: ActionResult = _attack(world, alice)
		var actual: ActionResult = _attack(restored_world, restored_alice)
		assert_true(expected.ok and actual.ok, expected.reason + actual.reason)
		assert_eq(actual.event["damage"], expected.event["damage"], "roll %d after the load" % index)
		assert_eq(actual.event["target_id"], zombie_id)
		_run(world, UNARMED_COOLDOWN + TICK)
		_run(restored_world, UNARMED_COOLDOWN + TICK)


func test_corrupt_combat_documents_are_rejected() -> void:
	var world: ServerWorld = _world()
	var good: Dictionary = _combat(world).to_world_document()
	var cases: Array[Dictionary] = [
		{"schema_version": 99, "rng_seed": "1", "rng_state": "2"},
		{"rng_seed": "1", "rng_state": "2"},
		{"schema_version": CombatService.SCHEMA_VERSION, "rng_seed": "abc", "rng_state": "2"},
		{"schema_version": CombatService.SCHEMA_VERSION, "rng_seed": "1"},
	]
	for broken: Dictionary in cases:
		var target: CombatService = _combat(_world())
		assert_true(target.restore_world_document(broken).size() > 0, str(broken))
		assert_eq(target.to_world_document(), good, "a rejected document changes nothing")
	var documents: Dictionary = world.to_documents()
	(documents["world_state"][ServerWorld.KEY_SYSTEMS] as Dictionary)[CombatService.SYSTEM_ID] = cases[0]
	var restored_world: ServerWorld = ServerComposition.create_world(WORLD, _config())
	assert_true(restored_world.restore_documents(documents["world_state"], documents["players"]).size() > 0, "a corrupt combat document fails the world restore")
