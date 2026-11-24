class_name GameplaySettings
extends Resource
## Gameplay tuning values used by server rules (docs/14 §7: no hard-coded
## balance numbers). Defaults live in `res://data/tuning/gameplay_settings.tres`.
## Every value here is PROVISIONAL (docs/15 §5) until play-tested.

const DEFAULT_PATH: String = "res://data/tuning/gameplay_settings.tres"

## Server-side walking speed, metres per second.
@export_range(0.1, 20.0) var move_speed_mps: float = 4.0
## Server-side running speed while the validated run bit is accepted.
@export_range(0.1, 20.0) var run_speed_mps: float = 6.0
## Half size of the square play area around the origin, metres. F-33: the
## 4 km x 4 km map (2000); the hand-made 500 m test map is its middle.
@export_range(1.0, 10000.0) var world_half_extent_m: float = 2000.0
## Maximum distance between player and world item for pickup, metres.
@export_range(0.1, 50.0) var pickup_range_m: float = 2.5
## Maximum distance between two players for one to use a treatment item on
## the other, metres (P2-T12, docs/09 §14.27; PROVISIONAL, docs/15 P2-195).
## Measured between server positions, like the pickup range.
@export_range(0.1, 50.0) var treat_range_m: float = 2.5
## true (default, user decision 2026-11-15, docs/00 ADR-019, P2-T13): food
## and drink can also be given to another player (their hunger / thirst
## drops). false: only treatments (bandage, cure) can be used on others
## (P2-T12, docs/15 P2-196).
@export var allow_feeding_others: bool = true
## true (default, P2-T15, docs/00 ADR-021; PROVISIONAL, docs/15 P2-216): an
## item that is picked up joins the carried stacks of the same kind before
## it takes a slot of its own. false: every picked-up item takes a free slot
## (the rule before P2-T15).
@export var merge_stacks_on_pickup: bool = true
## Number of item stacks a player inventory can hold.
@export_range(1, 1000) var inventory_slot_capacity: int = 20
## Where new players appear.
@export var player_spawn_position: Vector3 = Vector3.ZERO


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if move_speed_mps <= 0.0:
		errors.append("move_speed_mps must be > 0")
	if not is_finite(run_speed_mps) or run_speed_mps < move_speed_mps:
		errors.append("run_speed_mps must be finite and >= move_speed_mps")
	if world_half_extent_m <= 0.0:
		errors.append("world_half_extent_m must be > 0")
	if pickup_range_m <= 0.0:
		errors.append("pickup_range_m must be > 0")
	if not is_finite(treat_range_m) or treat_range_m <= 0.0:
		errors.append("treat_range_m must be > 0")
	if inventory_slot_capacity < 1:
		errors.append("inventory_slot_capacity must be >= 1")
	if absf(player_spawn_position.x) > world_half_extent_m or absf(player_spawn_position.z) > world_half_extent_m:
		errors.append("player_spawn_position is outside the world")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> GameplaySettings:
	if ResourceLoader.exists(path):
		var loaded: Resource = ResourceLoader.load(path)
		if loaded is GameplaySettings:
			return loaded as GameplaySettings
		GameLogger.error("config", "gameplay settings has wrong type, using defaults", {"path": path, "operation": "load_settings"})
	else:
		GameLogger.warning("config", "gameplay settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return GameplaySettings.new()
