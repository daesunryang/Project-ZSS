class_name CompositionConfig
extends RefCounted
## Settings bundle used by ServerComposition to build a ServerWorld and its
## systems. Production uses from_defaults(); tests replace individual
## resources before building (e.g. config.gameplay = GameplaySettings.new()).
## Feature bundles add their own settings fields here only together with
## their composition line (docs/09 §14.5).

var gameplay: GameplaySettings
var catalog: ItemCatalog
var clock: WorldClockSettings
var dev_seed: DevWorldSeed
## Phase 2-B (survival).
var survival: SurvivalSettings
## Phase 2-N1c (server -> client survival replication).
var survival_net: SurvivalNetSettings
## Phase 2-A (noise, player movement noise, zombies).
var noise: NoiseSettings
var player_noise: PlayerNoiseSettings
var zombie: ZombieSettings
## Phase 2-C (melee combat).
var combat: CombatSettings
var melee_weapons: MeleeWeaponCatalog
## Phase 2-N1a (zombie replication; used by servers and clients).
var zombie_net: ZombieNetSettings
## Phase 2-N1b (combat network module).
var combat_net: CombatNetSettings
## P2-T2 (inventory network module).
var inventory_net: InventoryNetSettings
## P2-T9 (character name and appearance, docs/09 §14.24): the creation rules
## and the appearance definitions. Used by the server world, the network
## module (servers and clients) and the creation screen.
var character: CharacterSettings
var appearance: AppearanceCatalog
## P2-T11 (posture and stealth, docs/09 §14.26): the server rules and the
## network module (request rate; servers and clients).
var posture: PostureSettings
var posture_net: PostureNetSettings
## P2-T16 (trades between two players, docs/09 §14.30): the server rules
## and the network module (request rate; servers and clients).
var trade: TradeSettings
var trade_net: TradeNetSettings
## P2-T9: true = a player must create its character (name and appearance)
## before it is in the world, and again after every death. False (the
## default of a composition built directly: tests, tools) = ServerWorld.join()
## gives a new player a default character at once and a dead player's next
## character starts by itself after the delay. A dedicated server sets this
## from CharacterSettings.server_requires_character_creation (GameBootstrap).
var require_character_creation: bool = false
## P3-1 (world cells, docs/09 §15.1): the cell grid and the cell lifecycle.
var world_cells: WorldCellSettings


## Loads every settings resource from res://data/tuning and the item catalog.
static func from_defaults() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.new()
	config.gameplay = GameplaySettings.load_or_default()
	config.catalog = ItemCatalog.load_directory()
	config.clock = WorldClockSettings.load_or_default()
	config.dev_seed = DevWorldSeed.load_or_default()
	config.survival = SurvivalSettings.load_or_default()
	config.survival_net = SurvivalNetSettings.load_or_default()
	config.noise = NoiseSettings.load_or_default()
	config.player_noise = PlayerNoiseSettings.load_or_default()
	config.zombie = ZombieSettings.load_or_default()
	config.combat = CombatSettings.load_or_default()
	config.melee_weapons = MeleeWeaponCatalog.load_directory()
	config.zombie_net = ZombieNetSettings.load_or_default()
	config.combat_net = CombatNetSettings.load_or_default()
	config.inventory_net = InventoryNetSettings.load_or_default()
	config.character = CharacterSettings.load_or_default()
	config.appearance = AppearanceCatalog.load_directory()
	config.posture = PostureSettings.load_or_default()
	config.posture_net = PostureNetSettings.load_or_default()
	config.world_cells = WorldCellSettings.load_or_default()
	config.trade = TradeSettings.load_or_default()
	config.trade_net = TradeNetSettings.load_or_default()
	return config


## Collects validation errors of all contained settings.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if gameplay == null or catalog == null or clock == null or dev_seed == null or survival == null or survival_net == null or noise == null or zombie == null or zombie_net == null:
		errors.append("composition config is incomplete")
		return errors
	if combat == null or melee_weapons == null:
		errors.append("composition config is incomplete (combat)")
		return errors
	if player_noise == null:
		errors.append("composition config is incomplete (player_noise)")
		return errors
	if combat_net == null:
		errors.append("composition config is incomplete (combat_net)")
		return errors
	if inventory_net == null:
		errors.append("composition config is incomplete (inventory_net)")
		return errors
	if character == null or appearance == null:
		errors.append("composition config is incomplete (character)")
		return errors
	if posture == null or posture_net == null:
		errors.append("composition config is incomplete (posture)")
		return errors
	if world_cells == null:
		errors.append("composition config is incomplete (world_cells)")
		return errors
	if trade == null or trade_net == null:
		errors.append("composition config is incomplete (trade)")
		return errors
	errors.append_array(gameplay.validate())
	errors.append_array(clock.validate())
	errors.append_array(dev_seed.validate())
	errors.append_array(survival.validate())
	errors.append_array(survival_net.validate())
	errors.append_array(noise.validate())
	errors.append_array(player_noise.validate())
	errors.append_array(player_noise.validate_against(noise))
	errors.append_array(zombie.validate())
	errors.append_array(combat.validate())
	errors.append_array(melee_weapons.validate_against(combat.unarmed_weapon_id, catalog, noise))
	errors.append_array(zombie_net.validate())
	errors.append_array(combat_net.validate())
	errors.append_array(inventory_net.validate())
	errors.append_array(character.validate())
	errors.append_array(appearance.validate())
	errors.append_array(posture.validate())
	errors.append_array(posture_net.validate())
	errors.append_array(world_cells.validate())
	errors.append_array(world_cells.validate_play_area(gameplay.world_half_extent_m))
	errors.append_array(trade.validate())
	errors.append_array(trade_net.validate())
	errors.append_array(trade_net.validate_against(trade))
	return errors
