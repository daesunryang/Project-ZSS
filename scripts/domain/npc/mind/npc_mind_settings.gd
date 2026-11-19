class_name NpcMindSettings
extends Resource
## Tuning for P4-6's passive emotion and memory data. These are calendar
## world seconds (ADR-006), not action seconds. No value is updated per tick:
## callers calculate decay from the stored timestamp.

const DEFAULT_PATH: String = "res://data/tuning/npc_mind_settings.tres"

## One common half-life for the 13 emotion axes. Per-axis values and event
## response tables stay open for the Phase 4 tuning pass.
@export_range(0.001, 315360000.0, 0.001, "or_greater") var emotion_half_life_world_sec: float = 21600.0
## Default half-life copied into a new memory. A memory saves its own value,
## so later tuning does not silently rewrite existing memories.
@export_range(0.001, 315360000.0, 0.001, "or_greater") var memory_half_life_world_sec: float = 604800.0
## Hard bound per NPC (docs/13 §16.4). Long-term memories count too.
@export_range(1, 4096, 1, "or_greater") var max_memories: int = 64


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(emotion_half_life_world_sec) or emotion_half_life_world_sec <= 0.0:
		errors.append("npc mind emotion_half_life_world_sec must be finite and > 0")
	if not is_finite(memory_half_life_world_sec) or memory_half_life_world_sec <= 0.0:
		errors.append("npc mind memory_half_life_world_sec must be finite and > 0")
	if max_memories < 1:
		errors.append("npc mind max_memories must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcMindSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcMindSettings:
		return loaded as NpcMindSettings
	GameLogger.warning("config", "npc mind settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcMindSettings.new()
