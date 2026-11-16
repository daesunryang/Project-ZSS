class_name ContainerSettings
extends Resource
## Server rules of containers (ContainerService, P3-3, docs/00 ADR-026,
## docs/09 §15.3). Defaults in `res://data/tuning/container_settings.tres`.
## Every value is PROVISIONAL (docs/15 §15.3) until play-tested.

const DEFAULT_PATH: String = "res://data/tuning/container_settings.tres"

## Greatest distance between a player's SERVER position and a container at
## which the player can open it, take from it and put into it, metres. An
## open container closes when its player is farther away.
@export_range(0.1, 50.0) var interact_range_m: float = 2.5
## How long the first opening of a container that was never searched takes,
## action time (real seconds). 0 = it opens at once. A search that is
## interrupted (the searcher walks out of reach, lies down, dies or is hit)
## finds nothing and starts from the beginning the next time. A searched
## container opens at once for everybody.
@export_range(0.0, 600.0) var search_duration_sec: float = 1.5
## true: a hit (SurvivalService.apply_damage) interrupts a running search.
## A container that is already open stays open.
@export var search_interrupted_by_damage: bool = true
## The world's loot seed: with a container's id it decides what the
## container holds (LootRoller.seed_for). Every container records the value
## it was created with (ContainerInstance.loot_seed), so changing it affects
## only containers created afterwards. The same seed gives the same loot in
## every new world (PROVISIONAL, docs/15 P3-064). 0..2^53 - 1 (JSON-exact).
@export var loot_seed: int = 20261116
## Most containers one world cell holds.
@export_range(1, 100000) var max_containers_per_cell: int = 500
## Events kept between two drains (ContainerNetModule drains every tick).
@export_range(1, 1000000) var max_pending_events: int = 4096


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(interact_range_m) or interact_range_m <= 0.0:
		errors.append("container interact_range_m must be > 0")
	if not is_finite(search_duration_sec) or search_duration_sec < 0.0:
		errors.append("container search_duration_sec must be >= 0")
	if not ContainerInstance.is_valid_loot_seed(loot_seed):
		errors.append("container loot_seed must be within [0, %d]" % ContainerInstance.MAX_LOOT_SEED)
	if max_containers_per_cell < 1:
		errors.append("max_containers_per_cell must be >= 1")
	if max_pending_events < 1:
		errors.append("container max_pending_events must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> ContainerSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is ContainerSettings:
		return loaded as ContainerSettings
	GameLogger.warning("config", "container settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return ContainerSettings.new()
