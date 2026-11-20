extends TestCase
## P2-C1: pure melee rules (MeleeHitRules), weapon definitions, the weapon
## catalog and CombatSettings validation. No world, no nodes.

## Yaw 0 faces -Z (same convention as players and zombies).
const AIM_MINUS_Z: float = 0.0
const AIM_PLUS_X: float = -PI / 2.0
const RANGE: float = 2.0
const ARC: float = 90.0
const TOLERANCE: float = 0.000001


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func _weapon(weapon_id: String, item_id: String, damage: float, category: MeleeWeaponDefinition.Category = MeleeWeaponDefinition.Category.BLUNT) -> MeleeWeaponDefinition:
	var weapon: MeleeWeaponDefinition = MeleeWeaponDefinition.new()
	weapon.weapon_id = weapon_id
	weapon.display_name = weapon_id
	weapon.category = category
	weapon.item_definition_id = item_id
	weapon.base_damage = damage
	weapon.range_m = RANGE
	weapon.arc_angle_deg = ARC
	weapon.cooldown_sec = 1.0
	weapon.stamina_cost = 5.0
	weapon.noise_loudness = 6.0
	return weapon


func _item(definition_id: String) -> ItemDefinition:
	var definition: ItemDefinition = ItemDefinition.new()
	definition.definition_id = definition_id
	definition.display_name = definition_id
	return definition


# ------------------------------------------------------------ hit rules

func test_aim_uses_the_shared_yaw_convention() -> void:
	for yaw: float in [0.0, 0.7, -2.1, PI]:
		assert_true(MeleeHitRules.aim_direction(yaw).is_equal_approx(ZombiePerception.forward_of(yaw)), "yaw %f" % yaw)
	assert_true(MeleeHitRules.aim_direction(AIM_MINUS_Z).is_equal_approx(Vector3(0, 0, -1)))
	assert_true(MeleeHitRules.aim_direction(AIM_PLUS_X).is_equal_approx(Vector3(1, 0, 0)))


func test_in_arc_needs_range_and_angle() -> void:
	var origin: Vector3 = Vector3(10, 0, 10)
	assert_true(MeleeHitRules.is_in_arc(origin, AIM_MINUS_Z, origin + Vector3(0, 0, -1.9), RANGE, ARC), "straight ahead, inside range")
	assert_false(MeleeHitRules.is_in_arc(origin, AIM_MINUS_Z, origin + Vector3(0, 0, -2.1), RANGE, ARC), "straight ahead, out of range")
	assert_false(MeleeHitRules.is_in_arc(origin, AIM_MINUS_Z, origin + Vector3(0, 0, 1.0), RANGE, ARC), "behind")
	# 40 and 50 degrees off the aim with a 90 degree arc (45 each side).
	var inside: Vector3 = Vector3(sin(deg_to_rad(40.0)), 0, -cos(deg_to_rad(40.0)))
	var outside: Vector3 = Vector3(sin(deg_to_rad(50.0)), 0, -cos(deg_to_rad(50.0)))
	assert_true(MeleeHitRules.is_in_arc(origin, AIM_MINUS_Z, origin + inside, RANGE, ARC))
	assert_false(MeleeHitRules.is_in_arc(origin, AIM_MINUS_Z, origin + outside, RANGE, ARC))
	assert_true(MeleeHitRules.is_in_arc(origin, AIM_MINUS_Z, origin + Vector3(-inside.x, 0, inside.z), RANGE, ARC), "the arc is symmetric")
	assert_true(MeleeHitRules.is_in_arc(origin, AIM_PLUS_X, origin + Vector3(1.5, 0, 0), RANGE, ARC), "aim turns the arc")
	assert_false(MeleeHitRules.is_in_arc(origin, AIM_PLUS_X, origin + Vector3(0, 0, -1.5), RANGE, ARC))
	assert_true(MeleeHitRules.is_in_arc(origin, AIM_MINUS_Z, origin + Vector3(0, 0, 1.0), RANGE, 360.0), "a full circle reaches behind")
	assert_true(MeleeHitRules.is_in_arc(origin, AIM_MINUS_Z, origin + Vector3(0, 50.0, -1.0), RANGE, ARC), "height is ignored (XZ plane)")
	assert_true(MeleeHitRules.is_in_arc(origin, AIM_MINUS_Z, origin, RANGE, ARC), "a target on top of the attacker is always in the arc")


func test_in_arc_rejects_invalid_input() -> void:
	var target: Vector3 = Vector3(0, 0, -1)
	assert_false(MeleeHitRules.is_in_arc(Vector3(NAN, 0, 0), AIM_MINUS_Z, target, RANGE, ARC))
	assert_false(MeleeHitRules.is_in_arc(Vector3.ZERO, NAN, target, RANGE, ARC))
	assert_false(MeleeHitRules.is_in_arc(Vector3.ZERO, AIM_MINUS_Z, Vector3(0, 0, INF), RANGE, ARC))
	assert_false(MeleeHitRules.is_in_arc(Vector3.ZERO, AIM_MINUS_Z, target, 0.0, ARC))
	assert_false(MeleeHitRules.is_in_arc(Vector3.ZERO, AIM_MINUS_Z, target, INF, ARC))
	assert_false(MeleeHitRules.is_in_arc(Vector3.ZERO, AIM_MINUS_Z, target, RANGE, -1.0))
	assert_false(MeleeHitRules.is_in_arc(Vector3.ZERO, AIM_MINUS_Z, target, RANGE, NAN))


func test_pick_target_takes_the_nearest_in_arc() -> void:
	var ids: PackedStringArray = ["zombie_000005", "zombie_000002", "zombie_000009", "zombie_000001"]
	var positions: PackedVector3Array = [
		Vector3(0, 0, -1.8),  # in arc, far
		Vector3(0.2, 0, -1.0),  # in arc, nearest
		Vector3(0, 0, 0.3),  # nearest of all, but behind
		Vector3(0, 0, -5.0),  # out of range
	]
	assert_eq(MeleeHitRules.pick_target(Vector3.ZERO, AIM_MINUS_Z, RANGE, ARC, ids, positions), "zombie_000002")
	assert_eq(MeleeHitRules.pick_target(Vector3.ZERO, PI, RANGE, ARC, ids, positions), "zombie_000009", "turning around changes the target")
	assert_eq(MeleeHitRules.pick_target(Vector3.ZERO, AIM_PLUS_X, RANGE, ARC, ids, positions), "", "nobody in the arc")
	assert_eq(MeleeHitRules.pick_target(Vector3.ZERO, AIM_MINUS_Z, RANGE, ARC, PackedStringArray(), PackedVector3Array()), "")
	assert_eq(MeleeHitRules.pick_target(Vector3.ZERO, AIM_MINUS_Z, RANGE, ARC, ids, PackedVector3Array([Vector3.ZERO])), "", "mismatched lists select nothing")


func test_pick_target_breaks_ties_by_id() -> void:
	var positions: PackedVector3Array = [Vector3(0.5, 0, -1.0), Vector3(-0.5, 0, -1.0)]
	assert_eq(MeleeHitRules.pick_target(Vector3.ZERO, AIM_MINUS_Z, RANGE, ARC, PackedStringArray(["zombie_000007", "zombie_000003"]), positions), "zombie_000003")
	assert_eq(MeleeHitRules.pick_target(Vector3.ZERO, AIM_MINUS_Z, RANGE, ARC, PackedStringArray(["zombie_000003", "zombie_000007"]), positions), "zombie_000003", "independent of the list order")


func test_damage_is_base_times_handling_times_roll() -> void:
	assert_true(absf(MeleeHitRules.damage(20.0, 0.75, 1.1) - 16.5) <= TOLERANCE)
	assert_eq(MeleeHitRules.damage(20.0, 1.0, 1.0), 20.0)
	assert_eq(MeleeHitRules.damage(20.0, 0.0, 1.0), 0.0)
	assert_eq(MeleeHitRules.damage(NAN, 1.0, 1.0), 0.0, "invalid factors give no damage")
	assert_eq(MeleeHitRules.damage(20.0, INF, 1.0), 0.0)
	assert_eq(MeleeHitRules.damage(20.0, 1.0, -1.0), 0.0)


func test_aim_yaw_validation() -> void:
	assert_true(MeleeHitRules.is_valid_aim_yaw(0.0, TAU))
	assert_true(MeleeHitRules.is_valid_aim_yaw(-TAU, TAU))
	assert_true(MeleeHitRules.is_valid_aim_yaw(TAU, TAU))
	assert_false(MeleeHitRules.is_valid_aim_yaw(TAU + 0.01, TAU))
	assert_false(MeleeHitRules.is_valid_aim_yaw(-100.0, TAU))
	assert_false(MeleeHitRules.is_valid_aim_yaw(NAN, TAU))
	assert_false(MeleeHitRules.is_valid_aim_yaw(INF, TAU))
	assert_false(MeleeHitRules.is_valid_aim_yaw(-INF, TAU))


# ------------------------------------------------------------ definitions

func test_weapon_definition_validation() -> void:
	assert_eq(_weapon("pipe", "pipe", 25.0).validate().size(), 0)
	assert_eq(MeleeWeaponDefinition.category_name(MeleeWeaponDefinition.Category.UNARMED), "unarmed")
	assert_eq(MeleeWeaponDefinition.category_name(MeleeWeaponDefinition.Category.BLUNT), "blunt")
	assert_eq(MeleeWeaponDefinition.category_name(MeleeWeaponDefinition.Category.BLADE), "blade")
	assert_eq(MeleeWeaponDefinition.category_name(MeleeWeaponDefinition.Category.AXE), "axe")
	var broken: MeleeWeaponDefinition = _weapon("Bad Id", "pipe", 0.0)
	broken.range_m = 0.0
	broken.arc_angle_deg = 400.0
	broken.cooldown_sec = -1.0
	broken.stamina_cost = NAN
	broken.noise_loudness = -2.0
	assert_true(broken.validate().size() >= 7, "; ".join(broken.validate()))
	var unarmed_with_item: MeleeWeaponDefinition = _weapon("fists", "pipe", 5.0, MeleeWeaponDefinition.Category.UNARMED)
	assert_true(unarmed_with_item.validate().size() > 0, "unarmed weapons are not granted by items")
	var weapon_without_item: MeleeWeaponDefinition = _weapon("pipe", "", 5.0)
	assert_true(weapon_without_item.validate().size() > 0, "a real weapon needs the item that grants it")


func test_shipped_unarmed_damage_is_ten() -> void:
	var catalog: MeleeWeaponCatalog = MeleeWeaponCatalog.load_directory()
	var unarmed: MeleeWeaponDefinition = catalog.get_definition("unarmed")
	assert_not_null(unarmed)
	if unarmed != null:
		assert_eq(unarmed.base_damage, 10.0)
		assert_eq(MeleeHitRules.damage(unarmed.base_damage, 1.0, 0.9), 9.0)
		assert_eq(MeleeHitRules.damage(unarmed.base_damage, 1.0, 1.1), 11.0)


func test_catalog_lookup_and_duplicates() -> void:
	var catalog: MeleeWeaponCatalog = MeleeWeaponCatalog.new()
	assert_eq(catalog.add(_weapon("unarmed", "", 8.0, MeleeWeaponDefinition.Category.UNARMED)), OK)
	assert_eq(catalog.add(_weapon("pipe", "pipe_item", 25.0)), OK)
	assert_eq(catalog.add(_weapon("pipe", "other_item", 25.0)), ERR_ALREADY_EXISTS, "duplicate weapon id")
	assert_eq(catalog.add(_weapon("club", "pipe_item", 20.0)), ERR_ALREADY_EXISTS, "one item grants one weapon")
	assert_eq(catalog.add(_weapon("", "x", 1.0)), ERR_INVALID_DATA)
	assert_eq(catalog.size(), 2)
	assert_true(catalog.has("pipe"))
	assert_eq(catalog.get_definition("pipe").base_damage, 25.0)
	assert_null(catalog.get_definition("sword"))
	assert_eq(catalog.for_item("pipe_item").weapon_id, "pipe")
	assert_null(catalog.for_item("unknown_item"))
	assert_null(catalog.for_item(""), "unarmed is never looked up by item")
	assert_eq(catalog.weapon_ids(), PackedStringArray(["pipe", "unarmed"]), "sorted ids")


func test_catalog_picks_weapon_for_carried_items() -> void:
	var catalog: MeleeWeaponCatalog = MeleeWeaponCatalog.new()
	catalog.add(_weapon("unarmed", "", 8.0, MeleeWeaponDefinition.Category.UNARMED))
	catalog.add(_weapon("knife", "knife_item", 15.0, MeleeWeaponDefinition.Category.BLADE))
	catalog.add(_weapon("pipe", "pipe_item", 25.0))
	catalog.add(_weapon("bat", "bat_item", 25.0))
	var carried: PackedStringArray = ["bandage", "knife_item", "pipe_item", "bat_item"]
	assert_eq(catalog.pick_for_items(carried, CombatSettings.WeaponRule.FIRST_SLOT).weapon_id, "knife")
	assert_eq(catalog.pick_for_items(carried, CombatSettings.WeaponRule.HIGHEST_DAMAGE).weapon_id, "bat", "equal damage -> smaller weapon id")
	assert_null(catalog.pick_for_items(carried, CombatSettings.WeaponRule.UNARMED_ONLY))
	assert_null(catalog.pick_for_items(PackedStringArray(["bandage"]), CombatSettings.WeaponRule.HIGHEST_DAMAGE))
	assert_null(catalog.pick_for_items(PackedStringArray(), CombatSettings.WeaponRule.FIRST_SLOT))


func test_catalog_cross_validation() -> void:
	var items: ItemCatalog = ItemCatalog.new()
	items.add(_item("pipe_item"))
	var noise: NoiseSettings = NoiseSettings.new()
	var catalog: MeleeWeaponCatalog = MeleeWeaponCatalog.new()
	catalog.add(_weapon("unarmed", "", 8.0, MeleeWeaponDefinition.Category.UNARMED))
	catalog.add(_weapon("pipe", "pipe_item", 25.0))
	assert_eq(catalog.validate_against("unarmed", items, noise).size(), 0, "; ".join(catalog.validate_against("unarmed", items, noise)))
	assert_true(catalog.validate_against("fists", items, noise).size() > 0, "the unarmed weapon must exist")
	assert_true(catalog.validate_against("pipe", items, noise).size() > 0, "the unarmed weapon cannot need an item")
	catalog.add(_weapon("axe", "axe_item", 30.0, MeleeWeaponDefinition.Category.AXE))
	assert_true(catalog.validate_against("unarmed", items, noise).size() > 0, "weapon item missing from the item catalog")
	items.add(_item("axe_item"))
	assert_eq(catalog.validate_against("unarmed", items, noise).size(), 0)
	catalog.get_definition("axe").noise_loudness = noise.max_loudness + 1.0
	assert_true(catalog.validate_against("unarmed", items, noise).size() > 0, "louder than the noise system accepts")
	catalog.get_definition("axe").noise_loudness = 10.0
	catalog.get_definition("axe").noise_frequency_profile = "ultrasonic"
	assert_true(catalog.validate_against("unarmed", items, noise).size() > 0, "unknown frequency profile")


func test_settings_validation() -> void:
	var settings: CombatSettings = CombatSettings.new()
	assert_eq(settings.validate().size(), 0, "; ".join(settings.validate()))
	assert_false(settings.pvp_enabled, "PvP is off by default (docs/00)")
	settings.pvp_enabled = true
	assert_eq(settings.validate().size(), 1, "PvP has no implementation yet, so enabling it is a configuration error")
	settings.pvp_enabled = false
	settings.unarmed_weapon_id = ""
	settings.damage_roll_min = 1.2
	settings.damage_roll_max = 1.0
	settings.max_abs_aim_yaw = 0.0
	settings.max_pending_events = 0
	assert_true(settings.validate().size() >= 4, "; ".join(settings.validate()))
	settings = CombatSettings.new()
	settings.damage_roll_min = 0.0
	assert_true(settings.validate().size() > 0, "a zero roll would produce zero damage")
