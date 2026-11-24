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
## P3-2 (docs/09 §15.2): which cells each joined peer is told about.
var interest: InterestSettings
## P3-4a (grid structures, docs/09 §15.4): the building rules, the structure
## definitions (servers and client mirrors) and the network module.
var building: BuildingSettings
var structures: StructureCatalog
var structure_net: StructureNetSettings
## P3-6 (bounded zombie path finding and structure line blocking).
var navigation: NavigationSettings
## F-9 (player skill levels): skill ids, level curve, material reduction
## and experience per action (servers; clients for the HUD).
var skills: SkillSettings
## P3-3 (containers, docs/09 §15.3): the container rules, the container
## definitions (servers and client mirrors) and the loot tables (servers).
var containers: ContainerSettings
var container_definitions: ContainerCatalog
var loot_tables: LootTableCatalog
var container_net: ContainerNetSettings
## P3-3: the buildings and containers a world is seeded with, once
## (MapContentService). null (the default of from_defaults(): tests, tools) =
## the world gets no map content. A dedicated server sets the test map
## (MapContentDefinition.DEFAULT_PATH, GameBootstrap).
var map_content: MapContentDefinition = null
## P4-1 (NPCs, docs/09 §17.1): the NPC rules and the NPC definitions.
var npc: NpcSettings
var npc_definitions: NpcCatalog
## P4-2 (docs/09 §17.2): calendar-time NPC need definitions and rates.
var npc_needs: NpcNeedSettings
## P4-6: passive emotion decay and bounded memory tuning.
var npc_mind: NpcMindSettings
## P4-7 (docs/09 §17.5): NPC public replication settings.
var npc_net: NpcNetSettings
## P4-8: development-only private NPC debug query and subscription.
var npc_debug: NpcDebugSettings
## P4-1: the NPCs a world is given, once (NpcService). null (the default of
## from_defaults(): tests, tools) = the world gets no NPCs. A dedicated
## server sets the dev roster (NpcRoster.DEFAULT_PATH, GameBootstrap), which
## needs the map content its home spots are in.
var npc_roster: NpcRoster = null
## P4-3 (docs/09 §17.3): when NPCs think (NpcScheduler), and what they do
## when their turn comes. null decider (the default) = P4-4's
## NpcUtilityDecider, made from `npc_decision` and `npc_actions`; a test
## gives its own decider here.
var npc_schedule: NpcScheduleSettings
var npc_decider: NpcDecider = null
## P4-4 (docs/09 §17.6): how NPCs choose what to do, and the actions they
## choose from.
var npc_decision: NpcDecisionSettings
var npc_actions: NpcActionCatalog
## P4-5a (docs/09 §17.7): how NPCs carry out actions (NpcExecutor), and the
## NPC spots (beds, work places, water, food containers) of the map. Spots
## that name a building are only used with the map content they belong to.
var npc_executor: NpcExecutorSettings
var npc_spots: NpcSpotSet = null
## P4-5b (docs/09 §17.8): what the basic NPC actions do (NpcBehaviours).
## null = no behaviour layer: the utility decider gets no executor and the
## NPCs stand still (tests of other things than what NPCs do).
var npc_behaviour: NpcBehaviourSettings = null
## F-25 (docs/09 §17.12): the NPCs' bodies (NpcHealth): damage, infection,
## treatment, death, rising. null = NPCs have no health: nothing can hurt
## them and zombies do not see them (tests of other things).
var npc_health: NpcHealthSettings = null


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
	config.interest = InterestSettings.load_or_default()
	config.trade = TradeSettings.load_or_default()
	config.trade_net = TradeNetSettings.load_or_default()
	config.building = BuildingSettings.load_or_default()
	config.structures = StructureCatalog.load_directory()
	config.structure_net = StructureNetSettings.load_or_default()
	config.navigation = NavigationSettings.load_or_default()
	config.skills = SkillSettings.load_or_default()
	config.containers = ContainerSettings.load_or_default()
	config.container_definitions = ContainerCatalog.load_directory()
	config.loot_tables = LootTableCatalog.load_directory()
	config.container_net = ContainerNetSettings.load_or_default()
	config.npc = NpcSettings.load_or_default()
	config.npc_definitions = NpcCatalog.load_directory()
	config.npc_needs = NpcNeedSettings.load_or_default()
	config.npc_mind = NpcMindSettings.load_or_default()
	config.npc_net = NpcNetSettings.load_or_default()
	config.npc_debug = NpcDebugSettings.load_or_default()
	config.npc_schedule = NpcScheduleSettings.load_or_default()
	config.npc_decision = NpcDecisionSettings.load_or_default()
	config.npc_actions = NpcActionCatalog.load_directory()
	config.npc_executor = NpcExecutorSettings.load_or_default()
	config.npc_spots = NpcSpotSet.load_or_null()
	config.npc_behaviour = NpcBehaviourSettings.load_or_default()
	config.npc_health = NpcHealthSettings.load_or_default()
	return config


## P4-1: errors of the NPC settings and definitions, and of the roster (when
## the world is to get one) against the definitions and the map content.
func _validate_npcs() -> PackedStringArray:
	var errors: PackedStringArray = []
	if npc == null or npc_definitions == null or npc_needs == null or npc_mind == null or npc_net == null or npc_debug == null:
		errors.append("composition config is incomplete (npc)")
		return errors
	errors.append_array(npc.validate())
	errors.append_array(npc_mind.validate())
	errors.append_array(npc_definitions.validate_against(appearance))
	errors.append_array(npc_needs.validate())
	errors.append_array(npc_net.validate())
	errors.append_array(npc_debug.validate())
	errors.append_array(npc_schedule.validate() if npc_schedule != null else PackedStringArray(["composition config is incomplete (npc_schedule)"]))
	if npc_decision == null or npc_actions == null:
		errors.append("composition config is incomplete (npc_decision)")
	else:
		errors.append_array(npc_decision.validate())
		errors.append_array(npc_decision.validate_against(npc_actions))
	errors.append_array(npc_executor.validate() if npc_executor != null else PackedStringArray(["composition config is incomplete (npc_executor)"]))
	if npc_spots != null:
		errors.append_array(npc_spots.validate())
		errors.append_array(npc_spots.validate_against(map_content, StructureGrid.new(building.grid_module_m), gameplay.world_half_extent_m, catalog))
	if npc_behaviour != null:
		errors.append_array(npc_behaviour.validate())
	if npc_health != null:
		errors.append_array(npc_health.validate())
	if npc_roster != null:
		errors.append_array(npc_roster.validate())
		errors.append_array(npc_roster.validate_against(npc_definitions, map_content, StructureGrid.new(building.grid_module_m), npc.max_npcs))
	return errors


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
	if interest == null:
		errors.append("composition config is incomplete (interest)")
		return errors
	if trade == null or trade_net == null:
		errors.append("composition config is incomplete (trade)")
		return errors
	if building == null or structures == null or structure_net == null:
		errors.append("composition config is incomplete (building)")
		return errors
	if navigation == null:
		errors.append("composition config is incomplete (navigation)")
		return errors
	if skills == null:
		errors.append("composition config is incomplete (skills)")
		return errors
	errors.append_array(skills.validate())
	errors.append_array(building.validate())
	errors.append_array(structures.validate_against(catalog))
	errors.append_array(structure_net.validate())
	errors.append_array(navigation.validate())
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
	errors.append_array(interest.validate())
	errors.append_array(interest.validate_against(world_cells))
	errors.append_array(trade.validate())
	errors.append_array(trade_net.validate())
	errors.append_array(trade_net.validate_against(trade))
	errors.append_array(_validate_containers())
	errors.append_array(_validate_npcs())
	return errors


## P3-3: errors of the container settings, definitions and loot tables, and
## of the map content (when the world is to get one) against all of them.
func _validate_containers() -> PackedStringArray:
	var errors: PackedStringArray = []
	if containers == null or container_definitions == null or loot_tables == null or container_net == null:
		errors.append("composition config is incomplete (containers)")
		return errors
	errors.append_array(containers.validate())
	errors.append_array(loot_tables.validate_against(catalog))
	errors.append_array(container_definitions.validate_against(loot_tables))
	errors.append_array(container_net.validate())
	errors.append_array(container_net.validate_against(container_definitions))
	if map_content != null:
		errors.append_array(map_content.validate())
		errors.append_array(map_content.validate_against(structures, container_definitions, loot_tables, StructureGrid.new(building.grid_module_m), gameplay.world_half_extent_m))
	return errors
