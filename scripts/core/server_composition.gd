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
	# --- systems (registration order = step order = save order) ---
	# Phase 2-B: survival (B1). Registered first so later systems can use it.
	var survival: SurvivalService = SurvivalService.new(config.survival, world.ids, world.clock)
	if world.register_system(survival) != OK:
		return null
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
	# Phase 2-C: melee combat (C1). After survival, noise and zombies, which
	# it uses. It acts on requests (request_melee_attack), not in step().
	if world.register_system(CombatService.new(config.combat, config.melee_weapons, world.clock)) != OK:
		return null
	return world


## Adds every feature NetModule to `service` (server and client alike, so
## RPC node paths match). Must run before start_server/start_client.
static func install_net_modules(service: NetworkService, config: CompositionConfig) -> Error:
	# --- network modules ---
	# Phase 2-N1a: zombie replication (ch2 snapshots, ch0 events, join fragment).
	var zombie_net: ZombieNetModule = ZombieNetModule.new(config.zombie_net)
	var error: Error = service.register_module(zombie_net)
	if error != OK:
		zombie_net.free()
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
	return OK
