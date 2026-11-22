extends TestCase
## F-3 (FD-3) over the network: a melee weapon wears down on the server, one
## use per hit, and breaks at 0. The owner's client mirror follows through
## the existing inventory messages (the changed item's condition, then the
## item's removal); other clients are told nothing about that inventory.
## No new message: BuildInfo.PROTOCOL_VERSION is unchanged.

const WORLD: String = "combat_durability_net_test_world"
const NEVER: float = 1.0e9
const AIM_MINUS_Z: float = 0.0
const CLUB: String = "f3n_club"
const CLUB_USES: int = 60
const CLUB_DAMAGE: float = 25.0
const CELL: String = DevWorldSeed.DEV_CELL_ID
const ITEM_AT: Vector3 = Vector3(1.0, 0.0, 0.5)
const ZOMBIE_AHEAD: Vector3 = Vector3(0.0, 0.0, -1.5)
const WAIT_MSEC: int = 6000
const SETTLE_TICKS: int = 20
const GENEROUS_RATE: float = 240.0
const GENEROUS_BURST: int = 240

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _world: ServerWorld = null


func before_each() -> void:
	GameLogger.set_capture(true)
	var net_settings: NetworkSettings = NetworkSettings.new()
	net_settings.autosave_interval_sec = 0.0
	var combat_net: CombatNetSettings = CombatNetSettings.new()
	combat_net.melee_intent_rate_per_sec = GENEROUS_RATE
	combat_net.melee_intent_burst = GENEROUS_BURST
	var weapons: MeleeWeaponCatalog = MeleeWeaponCatalog.new()
	weapons.add(_weapon("unarmed", MeleeWeaponDefinition.Category.UNARMED, "", 10.0))
	weapons.add(_weapon(CLUB, MeleeWeaponDefinition.Category.BLUNT, CLUB, CLUB_DAMAGE))
	var items: ItemCatalog = ItemCatalog.new()
	var club: ItemDefinition = ItemDefinition.new()
	club.definition_id = CLUB
	club.display_name = CLUB
	items.add(club)
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.catalog = items
	_config.clock = WorldClockSettings.new()
	_config.survival = SurvivalSettings.new()
	_config.survival.health_recovery_per_world_sec = 0.0
	_config.survival.wound_recovery_per_world_sec = 0.0
	_config.survival.stamina_regen_per_sec = 0.0
	_config.survival.respawn_delay_sec = NEVER
	_config.noise = NoiseSettings.new()
	_config.player_noise = PlayerNoiseSettings.new()
	_config.player_noise.footstep_loudness = 0.0
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.max_health = 1.0e7
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	_config.zombie.sight_range_m = 0.0
	_config.zombie.wander_speed_mps = 0.0
	_config.zombie.investigate_speed_mps = 0.0
	_config.zombie.chase_speed_mps = 0.0
	_config.zombie.search_speed_mps = 0.0
	_config.combat = CombatSettings.new()
	_config.combat.damage_roll_min = 1.0
	_config.combat.damage_roll_max = 1.0
	_config.melee_weapons = weapons
	_config.combat_net = combat_net
	_cluster = NetTestCluster.new(tree, net_settings, _config)
	_world = null


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _weapon(weapon_id: String, category: MeleeWeaponDefinition.Category, item_id: String, damage: float) -> MeleeWeaponDefinition:
	var weapon: MeleeWeaponDefinition = MeleeWeaponDefinition.new()
	weapon.weapon_id = weapon_id
	weapon.display_name = weapon_id
	weapon.category = category
	weapon.item_definition_id = item_id
	weapon.base_damage = damage
	weapon.range_m = 2.0
	weapon.arc_angle_deg = 90.0
	weapon.cooldown_sec = 0.0
	weapon.stamina_cost = 0.0
	weapon.noise_loudness = 0.0
	weapon.max_durability = CLUB_USES
	return weapon


func _inventory_module(service: NetworkService) -> InventoryNetModule:
	return service.get_module(InventoryNetModule.MODULE_NAME) as InventoryNetModule


func _combat_module(service: NetworkService) -> CombatNetModule:
	return service.get_module(CombatNetModule.MODULE_NAME) as CombatNetModule


func _wait(condition: Callable, timeout_msec: int = WAIT_MSEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func _settle() -> void:
	for tick: int in range(SETTLE_TICKS):
		await tree.physics_frame


## Condition of `item_id` in the client's own inventory mirror (-1 = absent).
func _mirrored_condition(client: NetworkService, item_id: String) -> float:
	var entry: Dictionary = client.client_state.get_inventory_item(item_id)
	return -1.0 if entry.is_empty() else float(entry["condition"])


## Sends one melee request and waits for its result: [ok, reason].
func _swing(client: NetworkService) -> Array:
	var rows: Array[Array] = []
	_combat_module(client).melee_result.connect(func(request_id: int, ok: bool, reason: String) -> void: rows.append([request_id, ok, reason]))
	var request_id: int = _combat_module(client).request_melee_attack(AIM_MINUS_Z)
	if not await _wait(func() -> bool: return rows.size() >= 1):
		fail("the melee request %d was not answered" % request_id)
		return [false, "no_answer"]
	return [rows[0][1], rows[0][2]]


func test_wear_and_break_reach_the_owner_only() -> void:
	_world = ServerComposition.create_world(WORLD, _config)
	_world.seed_new_world(DevWorldSeed.new())
	assert_eq(_cluster.start_server(_world, null), OK, "server started")
	var club: String = _world.inventory.spawn_world_item(CLUB, 1, CELL, ITEM_AT)
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var picked: Array[Array] = []
	a.pickup_result.connect(func(request_id: int, ok: bool, reason: String) -> void: picked.append([request_id, ok, reason]))
	a.request_pickup(club)
	assert_true(await _wait(func() -> bool: return picked.size() == 1 and a.client_state.has_inventory_item(club)), "alice picked the club up")
	if picked.is_empty() or not bool(picked[0][1]):
		fail("test setup: pickup refused %s" % str(picked))
		return
	assert_eq(_mirrored_condition(a, club), 1.0, "a new weapon")
	var weapon: MeleeWeaponDefinition = _config.melee_weapons.get_definition(CLUB)
	var alice_id: String = a.client_state.local_player_id
	var alice_inventory: String = _world.get_player(alice_id).inventory_id
	(_world.get_system(ZombieService.SYSTEM_ID) as ZombieService).spawn_zombie(_world, ZOMBIE_AHEAD)
	var b_owner_messages: int = _inventory_module(b).owner_message_count
	var a_changed: Array[String] = []
	var a_removed: Array[String] = []
	_inventory_module(a).inventory_item_changed.connect(func(item_id: String) -> void: a_changed.append(item_id))
	_inventory_module(a).inventory_items_removed.connect(func(ids: PackedStringArray) -> void: a_removed.append_array(ids))

	# One hit: one use less, on the server and in alice's mirror.
	assert_eq(await _swing(a), [true, ""])
	var one_less: float = weapon.condition_for_uses(CLUB_USES - 1)
	assert_true(await _wait(func() -> bool: return _mirrored_condition(a, club) == one_less), "alice sees one use less (%s)" % str(_mirrored_condition(a, club)))
	assert_eq(weapon.uses_left(_world.inventory.get_item(club).condition), CLUB_USES - 1, "the server decided the wear")
	assert_eq(a_changed, [club])

	# Down to the last use (a server rule, replicated the same way), then break.
	assert_true(_world.inventory.set_item_condition(alice_inventory, club, weapon.condition_for_uses(1)).ok)
	assert_true(await _wait(func() -> bool: return _mirrored_condition(a, club) == weapon.condition_for_uses(1)), "alice sees the last use")
	assert_eq(await _swing(a), [true, ""])
	assert_true(await _wait(func() -> bool: return not a.client_state.has_inventory_item(club)), "the broken club left alice's mirror")
	assert_null(_world.inventory.get_item(club), "the club is gone on the server")
	assert_eq(a_removed, [club])
	assert_eq((_world.get_system(CombatService.SYSTEM_ID) as CombatService).weapon_for(_world, alice_id).weapon_id, "unarmed")
	await _settle()
	assert_eq(_inventory_module(b).owner_message_count, b_owner_messages, "bob is told nothing about alice's inventory")
	assert_eq(a.client_state.inventory.size(), 0)
