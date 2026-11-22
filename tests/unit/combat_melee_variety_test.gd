extends TestCase
## F-3 (FD-3): the shipped melee weapons, their durability (one use per hit,
## kept in ItemInstance.condition, decided on the server), breaking at 0,
## durability across save -> recreate -> load, and the weapon loot pools
## (sub-tables themselves: loot_roll_test.gd).

const WORLD: String = "melee_variety_test_world"
const NEVER: float = 1.0e9
const AIM_MINUS_Z: float = 0.0
const AIM_PLUS_Z: float = PI
const AHEAD: Vector3 = Vector3(0.0, 0.0, -1.0)

const UNARMED: String = "unarmed"
## A test weapon that wears out fast: the FD-3 minimum of 60 uses.
const CLUB: String = "test_club"
const CLUB_USES: int = 60
const CLUB_DAMAGE: float = 30.0
## A weaker second weapon to fall back on.
const STICK: String = "test_stick"
const STICK_DAMAGE: float = 12.0

## The F-3 list (feature plan "목록": 근접 무기), shipped ids.
const FOUND_WEAPONS: PackedStringArray = [
	"dev_melee_pipe", "melee_wooden_bat", "melee_metal_bat", "melee_kitchen_knife",
	"melee_hunting_knife", "melee_machete", "melee_katana", "melee_hatchet", "melee_fire_axe",
	"melee_crowbar", "melee_hammer", "melee_sledgehammer", "melee_wrench", "melee_shovel",
	"melee_pickaxe", "melee_sickle", "melee_chainsaw", "melee_baton", "melee_stun_baton",
]
const CRAFTED_WEAPONS: PackedStringArray = ["melee_spear", "melee_nail_bat", "melee_barbed_wire_bat"]
const WEAPON_POOLS: PackedStringArray = ["melee_household", "melee_store", "melee_tools"]
const LOOT_SAMPLES: int = 400

var _config: CompositionConfig = null
var _root: String = ""


func before_each() -> void:
	GameLogger.set_capture(true)
	_root = "user://test_saves/melee_variety_%d" % Time.get_ticks_usec()
	var weapons: MeleeWeaponCatalog = MeleeWeaponCatalog.new()
	weapons.add(_weapon(UNARMED, MeleeWeaponDefinition.Category.UNARMED, "", 10.0, 0))
	weapons.add(_weapon(CLUB, MeleeWeaponDefinition.Category.BLUNT, CLUB, CLUB_DAMAGE, CLUB_USES))
	weapons.add(_weapon(STICK, MeleeWeaponDefinition.Category.BLUNT, STICK, STICK_DAMAGE, 100))
	var items: ItemCatalog = ItemCatalog.new()
	for definition_id: String in [CLUB, STICK]:
		var definition: ItemDefinition = ItemDefinition.new()
		definition.definition_id = definition_id
		definition.display_name = definition_id
		items.add(definition)
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
	_config.zombie = ZombieSettings.new()
	_config.zombie.dev_spawn_count = 0
	_config.zombie.wander_pause_min_sec = NEVER
	_config.zombie.wander_pause_max_sec = NEVER
	_config.zombie.sight_range_m = 0.0
	_config.zombie.wander_speed_mps = 0.0
	_config.zombie.investigate_speed_mps = 0.0
	_config.zombie.chase_speed_mps = 0.0
	_config.zombie.search_speed_mps = 0.0
	# A zombie that never dies, so every swing can hit it.
	_config.zombie.max_health = 1.0e7
	_config.combat = CombatSettings.new()
	_config.combat.damage_roll_min = 1.0
	_config.combat.damage_roll_max = 1.0
	_config.melee_weapons = weapons


func after_each() -> void:
	SaveService.remove_tree(_root)
	GameLogger.set_capture(false)


## A weapon that costs no stamina and has no cooldown, so a test can swing
## as often as it likes.
func _weapon(weapon_id: String, category: MeleeWeaponDefinition.Category, item_id: String, damage: float, uses: int) -> MeleeWeaponDefinition:
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
	if uses > 0:
		weapon.max_durability = uses
	return weapon


func _world() -> ServerWorld:
	var world: ServerWorld = ServerComposition.create_world(WORLD, _config)
	world.seed_new_world(DevWorldSeed.new())
	return world


func _combat(world: ServerWorld) -> CombatService:
	return world.get_system(CombatService.SYSTEM_ID) as CombatService


func _zombies(world: ServerWorld) -> ZombieService:
	return world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _give(world: ServerWorld, player: PlayerState, definition_id: String) -> String:
	var item_id: String = world.inventory.spawn_world_item(definition_id, 1, DevWorldSeed.DEV_CELL_ID, player.position)
	assert_true(world.try_pickup(player.player_id, item_id).ok, "test setup: pick up " + definition_id)
	return item_id


func _attack(world: ServerWorld, player: PlayerState, aim_yaw: float = AIM_MINUS_Z) -> ActionResult:
	return _combat(world).request_melee_attack(world, player.player_id, aim_yaw)


func _uses_left(world: ServerWorld, item_id: String) -> int:
	var item: ItemInstance = world.inventory.get_item(item_id)
	return -1 if item == null else _config.melee_weapons.get_definition(item.definition_id).uses_left(item.condition)


# ------------------------------------------------------------ shipped data

func test_the_shipped_weapons_cover_the_f3_list_and_are_valid() -> void:
	var weapons: MeleeWeaponCatalog = MeleeWeaponCatalog.load_directory()
	var items: ItemCatalog = ItemCatalog.load_directory()
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))
	var all_ids: PackedStringArray = FOUND_WEAPONS.duplicate()
	all_ids.append_array(CRAFTED_WEAPONS)
	assert_eq(weapons.size(), all_ids.size() + 1, "the F-3 list plus bare hands, nothing else")
	assert_eq(weapons.get_definition(UNARMED).base_damage, 10.0, "bare hands stay at 10 (user: 맨손은 10대)")
	assert_false(weapons.get_definition(UNARMED).wears(), "bare hands never wear")
	for weapon_id: String in all_ids:
		var weapon: MeleeWeaponDefinition = weapons.get_definition(weapon_id)
		assert_not_null(weapon, "shipped: " + weapon_id)
		if weapon == null:
			continue
		assert_eq(weapon.validate().size(), 0, "; ".join(weapon.validate()))
		assert_true(weapon.wears(), weapon_id + " wears")
		assert_true(weapon.max_durability >= 60 and weapon.max_durability <= 200, "FD-3 60~200 uses: %s %d" % [weapon_id, weapon.max_durability])
		assert_eq(weapon.item_definition_id, weapon_id, "a weapon and its item share the id")
		var item: ItemDefinition = items.get_definition(weapon.item_definition_id)
		assert_not_null(item, "item exists: " + weapon_id)
		if item != null:
			assert_eq(item.max_stack, 1, "a weapon item does not stack: " + weapon_id)
			assert_false(item.is_consumable(), "a weapon is not eaten: " + weapon_id)
		assert_eq(weapon.rarity == MeleeWeaponDefinition.Rarity.CRAFTED_ONLY, CRAFTED_WEAPONS.has(weapon_id), "crafted-only rarity: " + weapon_id)
	# Numbers differ between weapons (not one table copied 20 times).
	var damages: Dictionary[float, bool] = {}
	var cooldowns: Dictionary[float, bool] = {}
	var ranges: Dictionary[float, bool] = {}
	var uses: Dictionary[int, bool] = {}
	for weapon_id: String in all_ids:
		var weapon: MeleeWeaponDefinition = weapons.get_definition(weapon_id)
		damages[weapon.base_damage] = true
		cooldowns[weapon.cooldown_sec] = true
		ranges[weapon.range_m] = true
		uses[weapon.max_durability] = true
	assert_true(damages.size() >= 10 and cooldowns.size() >= 6 and ranges.size() >= 6 and uses.size() >= 6, "weapons differ in damage, speed, reach and durability")
	# The chainsaw is the loudest melee weapon by far (fuel: docs/15 F3-04).
	var chainsaw: MeleeWeaponDefinition = weapons.get_definition("melee_chainsaw")
	for weapon_id: String in all_ids:
		if weapon_id != "melee_chainsaw":
			assert_true(chainsaw.noise_loudness >= 2.0 * weapons.get_definition(weapon_id).noise_loudness, "chainsaw louder than " + weapon_id)
	assert_true(chainsaw.noise_loudness <= config.noise.max_loudness)


func test_definition_rules_for_durability_and_rarity() -> void:
	var weapon: MeleeWeaponDefinition = _weapon("w", MeleeWeaponDefinition.Category.BLADE, "w_item", 10.0, 100)
	assert_eq(weapon.validate().size(), 0)
	weapon.max_durability = MeleeWeaponDefinition.MIN_DURABILITY_USES - 1
	assert_true(weapon.validate().size() > 0, "below the FD-3 minimum")
	weapon.max_durability = MeleeWeaponDefinition.MAX_DURABILITY_USES + 1
	assert_true(weapon.validate().size() > 0, "above the FD-3 maximum")
	var hands: MeleeWeaponDefinition = _weapon("hands", MeleeWeaponDefinition.Category.UNARMED, "", 10.0, 0)
	hands.max_durability = 1
	assert_eq(hands.validate().size(), 0, "bare hands have no durability rule")
	# Uses <-> condition, robust to lost float digits.
	weapon.max_durability = 60
	assert_eq(weapon.uses_left(1.0), 60)
	assert_eq(weapon.uses_left(weapon.condition_for_uses(59)), 59)
	assert_eq(weapon.uses_left(weapon.condition_for_uses(59) + 1.0e-12), 59)
	assert_eq(weapon.uses_left(weapon.condition_for_uses(59) - 1.0e-12), 59)
	assert_eq(weapon.uses_left(0.0), 0)
	assert_eq(weapon.uses_left(NAN), 0)
	assert_eq(weapon.uses_left(2.0), 60, "clamped")
	assert_eq(weapon.condition_for_uses(0), 0.0)
	assert_eq(weapon.condition_for_uses(60), 1.0)
	for uses: int in range(61):
		assert_eq(weapon.uses_left(str_to_var(var_to_str(weapon.condition_for_uses(uses)))), uses, "text round trip %d" % uses)
		assert_eq(weapon.uses_left(float(JSON.parse_string(JSON.stringify(weapon.condition_for_uses(uses))))), uses, "JSON round trip %d" % uses)
	assert_eq(weapon.loot_weight(), MeleeWeaponDefinition.RARITY_LOOT_WEIGHTS[MeleeWeaponDefinition.Rarity.COMMON])
	weapon.rarity = MeleeWeaponDefinition.Rarity.CRAFTED_ONLY
	assert_eq(weapon.loot_weight(), 0.0)
	# A weapon item that stacks is refused: each item keeps its own uses.
	var weapons: MeleeWeaponCatalog = MeleeWeaponCatalog.new()
	weapons.add(_weapon(UNARMED, MeleeWeaponDefinition.Category.UNARMED, "", 10.0, 0))
	weapons.add(_weapon("w", MeleeWeaponDefinition.Category.BLADE, "w_item", 10.0, 100))
	var items: ItemCatalog = ItemCatalog.new()
	var stacking: ItemDefinition = ItemDefinition.new()
	stacking.definition_id = "w_item"
	stacking.max_stack = 5
	items.add(stacking)
	assert_true(weapons.validate_against(UNARMED, items, NoiseSettings.new()).size() > 0)
	stacking.max_stack = 1
	assert_eq(weapons.validate_against(UNARMED, items, NoiseSettings.new()).size(), 0)


# ------------------------------------------------------------ loot

func test_found_weapons_are_in_the_loot_by_rarity_and_crafted_ones_are_not() -> void:
	var tables: LootTableCatalog = LootTableCatalog.load_directory()
	var weapons: MeleeWeaponCatalog = MeleeWeaponCatalog.load_directory()
	var items: ItemCatalog = ItemCatalog.load_directory()
	assert_eq(tables.validate_against(items).size(), 0, "; ".join(tables.validate_against(items)))
	var in_tables: Dictionary[String, bool] = {}
	for table_id: String in tables.table_ids():
		var table: LootTable = tables.get_table(table_id)
		for index: int in range(table.entry_count()):
			var definition_id: String = table.item_definition_ids[index]
			in_tables[definition_id] = true
			var weapon: MeleeWeaponDefinition = weapons.for_item(definition_id)
			if WEAPON_POOLS.has(table_id):
				assert_not_null(weapon, "%s holds weapons only: %s" % [table_id, definition_id])
				if weapon != null:
					assert_eq(table.weights[index], weapon.loot_weight(), "%s: %s weighs by its rarity" % [table_id, definition_id])
	for weapon_id: String in FOUND_WEAPONS:
		assert_true(in_tables.has(weapon_id), "can be found: " + weapon_id)
	for weapon_id: String in CRAFTED_WEAPONS:
		assert_false(in_tables.has(weapon_id), "only crafted, never found: " + weapon_id)
	# Every weapon pool is reachable from a building table.
	var used_pools: Dictionary[String, bool] = {}
	for table_id: String in tables.table_ids():
		for sub_id: String in tables.get_table(table_id).subtable_ids:
			used_pools[sub_id] = true
	for pool: String in WEAPON_POOLS:
		assert_true(used_pools.has(pool), "a building table rolls " + pool)
	# Searching warehouses finds tools, common ones more often than the chainsaw.
	var warehouse: LootTable = tables.get_table("dev_warehouse")
	var counts: Dictionary[String, int] = {}
	for index: int in range(LOOT_SAMPLES):
		for stack: Dictionary in LootRoller.roll(warehouse, LootRoller.seed_for(77, "container_%06d" % index), tables):
			var definition_id: String = str(stack[LootRoller.KEY_DEFINITION_ID])
			counts[definition_id] = counts.get(definition_id, 0) + 1
	assert_true(counts.get("melee_crowbar", 0) > 0, "warehouses hold tools: %s" % str(counts))
	assert_true(counts.get("melee_crowbar", 0) > counts.get("melee_chainsaw", 0), "common before very rare: %s" % str(counts))
	assert_eq(counts.get("melee_katana", 0), 0, "a katana is not a warehouse tool")


# ------------------------------------------------------------ durability

func test_each_hit_takes_one_use_and_misses_take_none() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var club: String = _give(world, alice, CLUB)
	_zombies(world).spawn_zombie(world, AHEAD)
	var changes: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: changes.append(event))
	var hit: ActionResult = _attack(world, alice)
	assert_true(hit.ok, hit.reason)
	assert_eq(hit.event["hit"], true)
	assert_eq(hit.event["weapon_id"], CLUB)
	assert_eq(hit.event["weapon_item_id"], club)
	assert_eq(hit.event["durability_left"], CLUB_USES - 1)
	assert_eq(hit.event["weapon_broke"], false)
	assert_true(SaveService.is_json_safe(hit.event))
	assert_eq(_uses_left(world, club), CLUB_USES - 1)
	assert_eq(changes.size(), 1, "one inventory change per hit")
	assert_eq(changes[0]["event_type"], InventoryService.EVENT_ITEM_CONDITION_CHANGED)
	assert_eq(changes[0]["item_instance_id"], club)
	assert_eq(changes[0]["inventory_id"], alice.inventory_id)
	assert_eq(changes[0]["condition_before"], 1.0)
	# A miss (aimed away) costs no use.
	var miss: ActionResult = _attack(world, alice, AIM_PLUS_Z)
	assert_true(miss.ok)
	assert_eq(miss.event["hit"], false)
	assert_eq(miss.event["durability_left"], CLUB_USES - 1)
	assert_eq(_uses_left(world, club), CLUB_USES - 1)
	assert_eq(changes.size(), 1, "a miss changes no item")
	# Public events never carry the server-only fields.
	var public: Dictionary = CombatNetModule.to_public_event(hit.event, 1, true)
	for key: String in ["weapon_item_id", "durability_left", "weapon_broke"]:
		assert_false(public.has(key), "not broadcast: " + key)
	# Bare hands never wear.
	var bob: PlayerState = world.join("bob")
	var bare: ActionResult = _attack(world, bob)
	assert_eq(bare.event["hit"], true)
	assert_eq(bare.event["weapon_id"], UNARMED)
	assert_eq(bare.event["weapon_item_id"], "")
	assert_eq(bare.event["durability_left"], CombatService.UNBREAKABLE)


func test_a_weapon_breaks_at_zero_and_the_next_weapon_takes_over() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var stick: String = _give(world, alice, STICK)
	var club: String = _give(world, alice, CLUB)
	_zombies(world).spawn_zombie(world, AHEAD)
	var combat: CombatService = _combat(world)
	assert_eq(combat.weapon_for(world, alice.player_id).weapon_id, CLUB, "the stronger weapon first")
	# Wear the club down to its last use, one hit at a time.
	for index: int in range(CLUB_USES - 1):
		var result: ActionResult = _attack(world, alice)
		assert_true(result.ok and bool(result.event["hit"]), "hit %d" % index)
		assert_eq(result.event["weapon_id"], CLUB)
	assert_eq(_uses_left(world, club), 1)
	assert_eq(_uses_left(world, stick), 100, "only the weapon that hits wears")
	var removed: Array[Dictionary] = []
	world.inventory.transaction_committed.connect(func(event: Dictionary) -> void: removed.append(event))
	var last: ActionResult = _attack(world, alice)
	assert_true(last.ok, last.reason)
	assert_eq(last.event["weapon_id"], CLUB, "the last hit is still the club's")
	assert_eq(last.event["durability_left"], 0)
	assert_eq(last.event["weapon_broke"], true)
	assert_eq(last.event["damage"], CLUB_DAMAGE, "the breaking hit still lands in full")
	assert_null(world.inventory.get_item(club), "the broken club is gone")
	assert_eq(removed.size(), 1)
	assert_eq(removed[0]["event_type"], InventoryService.EVENT_ITEM_REMOVED)
	assert_eq(removed[0]["remaining_quantity"], 0)
	assert_eq(combat.weapon_for(world, alice.player_id).weapon_id, STICK, "the next carried weapon takes over")
	var next: ActionResult = _attack(world, alice)
	assert_eq(next.event["weapon_id"], STICK)
	assert_eq(next.event["damage"], STICK_DAMAGE)
	# The stick broken too (from its last use): bare hands remain.
	assert_true(world.inventory.set_item_condition(alice.inventory_id, stick, 0.01).ok)
	assert_eq(_attack(world, alice).event["weapon_broke"], true)
	assert_eq(combat.weapon_for(world, alice.player_id).weapon_id, UNARMED, "nothing left: bare hands")
	assert_eq(world.inventory.items_in_inventory(alice.inventory_id).size(), 0)
	var bare: ActionResult = _attack(world, alice)
	assert_eq(bare.event["weapon_id"], UNARMED)


func test_two_copies_wear_one_after_the_other_lowest_slot_first() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var first: String = _give(world, alice, CLUB)
	var second: String = _give(world, alice, CLUB)
	_zombies(world).spawn_zombie(world, AHEAD)
	assert_true(world.inventory.set_item_condition(alice.inventory_id, first, 1.0 / CLUB_USES).ok)
	var result: ActionResult = _attack(world, alice)
	assert_eq(result.event["weapon_item_id"], first, "the copy in the lower slot is used")
	assert_eq(result.event["weapon_broke"], true)
	result = _attack(world, alice)
	assert_eq(result.event["weapon_item_id"], second)
	assert_eq(_uses_left(world, second), CLUB_USES - 1)


func test_set_item_condition_rules() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var bob: PlayerState = world.join("bob")
	var club: String = _give(world, alice, CLUB)
	var lying: String = world.inventory.spawn_world_item(CLUB, 1, DevWorldSeed.DEV_CELL_ID, Vector3(5, 0, 5))
	var inventory: InventoryService = world.inventory
	assert_eq(inventory.set_item_condition("inventory_999999", club, 0.5).reason, InventoryService.REASON_UNKNOWN_INVENTORY)
	assert_eq(inventory.set_item_condition(alice.inventory_id, "item_999999", 0.5).reason, InventoryService.REASON_UNKNOWN_ITEM)
	assert_eq(inventory.set_item_condition(bob.inventory_id, club, 0.5).reason, InventoryService.REASON_NOT_IN_INVENTORY)
	assert_eq(inventory.set_item_condition(alice.inventory_id, lying, 0.5).reason, InventoryService.REASON_NOT_IN_INVENTORY, "world items are not worn by this rule")
	for bad: float in [-0.1, 1.1, NAN, INF]:
		assert_eq(inventory.set_item_condition(alice.inventory_id, club, bad).reason, InventoryService.REASON_BAD_CONDITION, str(bad))
	assert_eq(inventory.get_item(club).condition, 1.0, "refusals change nothing")
	var committed: Array[Dictionary] = []
	inventory.transaction_committed.connect(func(event: Dictionary) -> void: committed.append(event))
	assert_true(inventory.set_item_condition(alice.inventory_id, club, 1.0).ok)
	assert_eq(committed.size(), 0, "the same value commits nothing")
	assert_true(inventory.set_item_condition(alice.inventory_id, club, 0.25).ok)
	assert_eq(committed.size(), 1)
	assert_eq(inventory.get_item(club).condition, 0.25)


func test_durability_survives_save_recreate_load_and_keeps_wearing() -> void:
	var world: ServerWorld = _world()
	var alice: PlayerState = world.join("alice")
	var club: String = _give(world, alice, CLUB)
	_zombies(world).spawn_zombie(world, AHEAD)
	var hits: int = 7
	for index: int in range(hits):
		assert_true(bool(_attack(world, alice).event["hit"]))
	assert_eq(_uses_left(world, club), CLUB_USES - hits)
	# A second, worn weapon keeps its own uses.
	var spare: String = _give(world, alice, STICK)
	assert_true(world.inventory.set_item_condition(alice.inventory_id, spare, 0.37).ok)

	var documents: Dictionary = world.to_documents()
	assert_eq(SaveService.new(_root).save_world(WORLD, documents["world_state"], documents["players"]), OK)
	var loaded: Dictionary = SaveService.new(_root).load_world(WORLD)
	assert_eq(loaded["error"], OK)
	var restored: ServerWorld = ServerComposition.create_world(WORLD, _config)
	assert_eq(restored.restore_documents(loaded["world_state"], loaded["players"]).size(), 0)
	var restored_alice: PlayerState = restored.join("alice")
	assert_eq(_uses_left(restored, club), CLUB_USES - hits, "uses left survive save -> recreate -> load")
	assert_eq(_uses_left(restored, spare), roundi(0.37 * 100), "each weapon keeps its own uses")
	# It goes on wearing from there, and breaks after exactly the uses left.
	if _zombies(restored).living_count() == 0:
		_zombies(restored).spawn_zombie(restored, AHEAD)
	var broke_after: int = 0
	for index: int in range(CLUB_USES):
		var result: ActionResult = _attack(restored, restored_alice)
		assert_true(bool(result.event["hit"]), "hit %d after the load" % index)
		broke_after += 1
		if bool(result.event["weapon_broke"]):
			break
	assert_eq(broke_after, CLUB_USES - hits, "breaks after the saved uses left")
	assert_null(restored.inventory.get_item(club))
