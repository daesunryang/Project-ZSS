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
	if world.register_system(SurvivalService.new(config.survival, world.ids, world.clock)) != OK:
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
	if world.register_system(ZombieService.new(config.zombie, world.ids, world.registry, world.clock)) != OK:
		return null
	# Phase 2-C: melee combat (C1). After survival, noise and zombies, which
	# it uses. It acts on requests (request_melee_attack), not in step().
	if world.register_system(CombatService.new(config.combat, config.melee_weapons, world.clock)) != OK:
		return null
	return world


## Adds every feature NetModule to `service` (server and client alike, so
## RPC node paths match). Must run before start_server/start_client.
static func install_net_modules(_service: NetworkService, _config: CompositionConfig) -> Error:
	# --- network modules ---
	return OK
