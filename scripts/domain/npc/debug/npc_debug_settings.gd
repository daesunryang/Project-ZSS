class_name NpcDebugSettings
extends Resource
## Development-only access and sampling limits for the private NPC debug
## stream (P4-8). A shipped dedicated server is disabled by default.

const DEFAULT_PATH: String = "res://data/tuning/npc_debug_settings.tres"
const MAX_ALLOWED_KEYS: int = 64
const MAX_PLAYER_KEY_LENGTH: int = 64

@export var enabled: bool = false
## Explicit development composition switch. Production keeps this false and
## lists individual player keys in allowed_player_keys when needed.
@export var allow_all_player_keys: bool = false
@export var allowed_player_keys: PackedStringArray = []
@export_range(0.1, 10.0, 0.1) var update_rate_hz: float = 2.0
@export_range(1, 16) var top_candidate_count: int = 5
@export_range(1, 16) var recent_memory_count: int = 5
@export_range(0.1, 20.0, 0.1) var request_rate_per_sec: float = 4.0
@export_range(1, 20) var request_burst: int = 4


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(update_rate_hz) or update_rate_hz <= 0.0:
		errors.append("npc debug update_rate_hz must be > 0")
	if top_candidate_count < 1 or recent_memory_count < 1:
		errors.append("npc debug candidate and memory counts must be >= 1")
	if not is_finite(request_rate_per_sec) or request_rate_per_sec <= 0.0 or request_burst < 1:
		errors.append("npc debug request rate and burst must be > 0")
	if allowed_player_keys.size() > MAX_ALLOWED_KEYS:
		errors.append("npc debug allowed player key count exceeds %d" % MAX_ALLOWED_KEYS)
	var seen: Dictionary[String, bool] = {}
	for player_key: String in allowed_player_keys:
		if player_key.is_empty() or player_key.length() > MAX_PLAYER_KEY_LENGTH:
			errors.append("npc debug allowed player keys must be non-empty and short")
		elif seen.has(player_key):
			errors.append("npc debug allowed player keys must be unique")
		seen[player_key] = true
	return errors


func allows(player_key: String) -> bool:
	return enabled and not player_key.is_empty() and (allow_all_player_keys or allowed_player_keys.has(player_key))


static func load_or_default(path: String = DEFAULT_PATH) -> NpcDebugSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcDebugSettings:
		return loaded as NpcDebugSettings
	GameLogger.warning("config", "npc debug settings missing, using disabled defaults", {"path": path, "operation": "load_settings"})
	return NpcDebugSettings.new()
