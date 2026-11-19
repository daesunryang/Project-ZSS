class_name NpcSettings
extends Resource
## Server rules of NPCs (NpcService, P4-1, docs/09 §17.1). Defaults in
## `res://data/tuning/npc_settings.tres`. Every value is PROVISIONAL
## (docs/15 §17.1) until Phase 4 is tuned as a whole.

const DEFAULT_PATH: String = "res://data/tuning/npc_settings.tres"

## Most NPCs one world has, counting the ones whose cell is not in memory
## (docs/13 §16.3 D1: 5 are the feature goal, 25 the budget the design is
## made for, 50 this limit). A spawn over the limit is refused and logged.
@export_range(1, 1000) var max_npcs: int = 50
## The world's NPC seed: with an NPC's id it decides that NPC's own random
## generator (NpcState.seed_for). Changing it affects only NPCs created
## afterwards (an NPC saves its generator). The same seed gives the same
## NPCs in every new world. 0..2^53 - 1 (JSON-exact).
@export var world_seed: int = 20261119


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if max_npcs < 1:
		errors.append("npc max_npcs must be >= 1")
	if world_seed < 0 or world_seed > NpcState.MAX_WORLD_SEED:
		errors.append("npc world_seed must be within [0, %d]" % NpcState.MAX_WORLD_SEED)
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcSettings:
		return loaded as NpcSettings
	GameLogger.warning("config", "npc settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcSettings.new()
