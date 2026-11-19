class_name NpcNetSettings
extends Resource
## NPC replication tuning (P4-7, docs/09 §17.5). The server sends compact
## position snapshots on channel 2 and reliable membership/observable-action
## events on channel 0. Values are PROVISIONAL (docs/15 §17.5).

const DEFAULT_PATH: String = "res://data/tuning/npc_net_settings.tres"

@export_group("Server")
## NPC position snapshots per second (docs/13 §16.4).
@export_range(1.0, 60.0) var snapshot_rate_hz: float = 5.0
## Compact [id, position, yaw] rows per unreliable message.
@export_range(1, 64) var snapshot_rows_per_message: int = 24
## Reliable scope/action events per message.
@export_range(1, 64) var events_per_message: int = 32

@export_group("Client")
@export_range(1, 100000) var recent_event_capacity: int = 128
@export_range(1, 1000000) var max_mirrored_npcs: int = 256


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(snapshot_rate_hz) or snapshot_rate_hz <= 0.0:
		errors.append("npc net snapshot_rate_hz must be > 0")
	if snapshot_rows_per_message < 1 or snapshot_rows_per_message > NpcNetProtocol.MAX_ROWS_PER_MESSAGE:
		errors.append("npc net snapshot_rows_per_message must be within [1, %d]" % NpcNetProtocol.MAX_ROWS_PER_MESSAGE)
	if events_per_message < 1 or events_per_message > NpcNetProtocol.MAX_EVENTS_PER_MESSAGE:
		errors.append("npc net events_per_message must be within [1, %d]" % NpcNetProtocol.MAX_EVENTS_PER_MESSAGE)
	if recent_event_capacity < 1:
		errors.append("npc net recent_event_capacity must be >= 1")
	if max_mirrored_npcs < 1:
		errors.append("npc net max_mirrored_npcs must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcNetSettings:
		return loaded as NpcNetSettings
	GameLogger.warning("config", "npc net settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcNetSettings.new()
