class_name ServerComposition
extends RefCounted
## The single place where server systems and network modules are assembled
## (docs/09 §14.5). GameBootstrap, WorldPersistence and NetTestCluster all go
## through here, so production and tests run the same composition.
##
## Ownership (Phase 2 plan): each feature bundle adds only its own lines in
## create_world() / install_net_modules(); bundles merge in the agreed order.


## Builds an empty ServerWorld with its clock and all registered systems.
## Returns null (and logs) if a system cannot be registered.
static func create_world(world_id: String, config: CompositionConfig) -> ServerWorld:
	var world: ServerWorld = ServerWorld.new(world_id, config.gameplay, config.catalog)
	world.clock = config.clock.create_clock()
	# P2-T9 (docs/09 §14.24): name rules, appearance data and whether players
	# create their characters themselves (false unless the caller says so).
	world.character_rules = CharacterRules.new(config.character, config.appearance)
	world.require_character_creation = config.require_character_creation
	# --- systems (registration order = step order = save order) ---
	# P3-1 (docs/09 §15.1): world cells. The grid is set before anything is
	# placed in the world; the cell service is registered first, so every
	# other system sees this tick's active cells and a player entering the
	# world has its cells loaded before the other systems hear of it.
	world.cell_grid = WorldCellGrid.new(config.world_cells)
	if world.register_system(WorldCellService.new(config.world_cells)) != OK:
		return null
	# Phase 2-B: survival (B1). Registered before the systems that use it.
	var survival: SurvivalService = SurvivalService.new(config.survival, world.ids, world.clock)
	if world.register_system(survival) != OK:
		return null
	# P2-T11: posture (standing / prone / asleep), movement and visibility.
	# After survival, whose rest it reads; before the footsteps and the
	# zombies, so both see this tick's posture and movement. Survival only
	# announces rests and deaths; it does not know this system.
	var posture: PostureService = PostureService.new(config.posture, world.clock)
	if world.register_system(posture) != OK:
		return null
	survival.rest_changed.connect(posture.on_rest_changed)
	survival.player_died.connect(posture.on_player_died)
	# Phase 2-A: noise (A1). Before its listeners (zombies) so expired noise
	# is gone before they query it in the same tick.
	if world.register_system(NoiseService.new(config.noise, world.clock, config.gameplay.world_half_extent_m)) != OK:
		return null
	# Phase 2-A: player movement noise (A3). After noise (it emits into it)
	# and before zombies, so a footstep is heard in the tick it is made.
	if world.register_system(PlayerNoiseService.new(config.player_noise)) != OK:
		return null
	# Phase 2-A: zombies (A2). After survival and noise, which they use.
	var zombies: ZombieService = ZombieService.new(config.zombie, world.ids, world.registry, world.clock)
	if world.register_system(zombies) != OK:
		return null
	# P2-T5 (docs/00 ADR-008): a player who dies of infection leaves a zombie.
	# Survival only announces deaths; the zombie system decides. The world
	# owns both systems, and the connection holds no reference to either.
	survival.player_died.connect(zombies.on_player_died)
	# P3-4a (docs/09 §15.4): grid structures. After the zombies, whose
	# positions a placement looks at. It constrains the movement of players
	# and zombies. P3-5 (docs/09 §15.5): its step() advances the work on
	# structures under construction; after survival, whose deaths, rests and
	# handling multipliers of this tick it reads.
	if world.register_system(BuildingService.new(config.building, config.structures, world.ids, world.registry, world.clock)) != OK:
		return null
	# P3-6: live structure edge queries for bounded zombie paths and opaque
	# line checks. It must follow building, whose public grid state it reads.
	if world.register_system(NavigationService.new(config.navigation)) != OK:
		return null
	# Phase 2-C: melee combat (C1). After survival, noise and zombies, which
	# it uses. It acts on requests (request_melee_attack), not in step().
	if world.register_system(CombatService.new(config.combat, config.melee_weapons, world.clock)) != OK:
		return null
	# P3-3 (docs/09 §15.3): containers. After survival and posture, which can
	# stop a player from acting, so its step sees what this tick did to
	# whoever has a container open (a death, a rest, a move). A hit interrupts
	# a search: survival only announces hits; it does not know this system.
	var containers: ContainerService = ContainerService.new(config.containers, config.container_definitions, config.loot_tables, world.ids, world.registry, world.clock)
	if world.register_system(containers) != OK:
		return null
	survival.player_damaged.connect(containers.on_player_damaged)
	# P3-3: the map content (buildings and the containers inside), placed once
	# per world through the building and the container system, after both.
	# Without content (config.map_content null: tests, tools) it places nothing.
	if world.register_system(MapContentService.new(config.map_content, config.structures)) != OK:
		return null
	# P4-1 (docs/09 §17.1): NPCs. After the map content, in whose buildings
	# the roster places them (once per world; without a roster nobody).
	# Components and stages of later tickets are registered here, before the
	# world is seeded or restored.
	var npcs: NpcService = NpcService.new(config.npc, config.npc_definitions, config.npc_roster, config.map_content, StructureGrid.new(config.building.grid_module_m), world.ids, world.registry, world.clock)
	if world.register_system(npcs) != OK:
		return null
	# P2-T16: trades between two players. Last, so its step sees what this
	# tick did to its parties (a death, a rest, a move). It is told about
	# every inventory transaction, to keep offers backed by what is carried.
	var trade: TradeService = TradeService.new(config.trade, world.clock)
	if world.register_system(trade) != OK:
		return null
	world.inventory.transaction_committed.connect(trade.on_inventory_transaction)
	return world


## Adds every feature NetModule to `service` (server and client alike, so
## RPC node paths match). Must run before start_server/start_client.
static func install_net_modules(service: NetworkService, config: CompositionConfig) -> Error:
	# --- network modules ---
	# P3-2 (docs/09 §15.2): which cells each joined peer is told about. FIRST:
	# its join fragment gives a joining peer its cells before the other
	# modules build theirs, and every tick it looks at the players before the
	# other modules send. No RPC.
	var interest_net: InterestNetModule = InterestNetModule.new(config.interest)
	var error: Error = service.register_module(interest_net)
	if error != OK:
		interest_net.free()
		return error
	# Phase 2-N1a: zombie replication (ch2 snapshots, ch0 events, join fragment).
	var zombie_net: ZombieNetModule = ZombieNetModule.new(config.zombie_net)
	error = service.register_module(zombie_net)
	if error != OK:
		zombie_net.free()
		return error
	# P3-1, P3-2 (docs/09 §15.1, §15.2): the map layout for the clients and
	# the world items of the cells a peer gains or loses. No RPC of its own.
	var world_cell_net: WorldCellNetModule = WorldCellNetModule.new()
	error = service.register_module(world_cell_net)
	if error != OK:
		world_cell_net.free()
		return error
	# P3-4a (docs/09 §15.4): placement / demolish / door intents and
	# replication of structures.
	var structure_net: StructureNetModule = StructureNetModule.new(config.structure_net, config.structures)
	error = service.register_module(structure_net)
	if error != OK:
		structure_net.free()
		return error
	# Phase 2-N1c: survival owner detail + public observable facts.
	var survival_net: SurvivalNetModule = SurvivalNetModule.new(config.survival_net, config.survival)
	error = service.register_module(survival_net)
	if error != OK:
		survival_net.free()
		return error
	# Phase 2-N1b: melee attack intent + combat event replication. A refused
	# module never entered the tree, so it is freed here.
	var combat_net: CombatNetModule = CombatNetModule.new(config.combat_net, config.combat.max_abs_aim_yaw)
	var combat_net_error: Error = service.register_module(combat_net)
	if combat_net_error != OK:
		combat_net.free()
		return combat_net_error
	# P2-T2: drop intent + replication of inventory changes (items put down
	# in the world, items leaving an inventory).
	var inventory_net: InventoryNetModule = InventoryNetModule.new(config.inventory_net)
	var inventory_net_error: Error = service.register_module(inventory_net)
	if inventory_net_error != OK:
		inventory_net.free()
		return inventory_net_error
	# P2-T9: character creation intent + replication of names and appearance.
	var character_net: CharacterNetModule = CharacterNetModule.new(config.character, config.appearance)
	var character_net_error: Error = service.register_module(character_net)
	if character_net_error != OK:
		character_net.free()
		return character_net_error
	# P2-T11: wanted-posture intent + replication of postures.
	var posture_net: PostureNetModule = PostureNetModule.new(config.posture_net)
	var posture_net_error: Error = service.register_module(posture_net)
	if posture_net_error != OK:
		posture_net.free()
		return posture_net_error
	# P2-T16: trade intents + session states to the two parties. After the
	# inventory module, whose pending save it flushes for a completed trade.
	var trade_net: TradeNetModule = TradeNetModule.new(config.trade_net)
	var trade_net_error: Error = service.register_module(trade_net)
	if trade_net_error != OK:
		trade_net.free()
		return trade_net_error
	# P3-3 (docs/09 §15.3): container intents, containers to the peers that
	# are told about their cell, contents to whoever has one open. After the
	# inventory module, whose pending save it flushes for a take or a put.
	var container_net: ContainerNetModule = ContainerNetModule.new(config.container_net, config.container_definitions)
	var container_net_error: Error = service.register_module(container_net)
	if container_net_error != OK:
		container_net.free()
		return container_net_error
	return OK
