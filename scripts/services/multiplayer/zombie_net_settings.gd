class_name ZombieNetSettings
extends Resource
## Zombie replication tuning (P2-N1a, docs/09 §14.12). Defaults in
## `res://data/tuning/zombie_net_settings.tres`. Every value is PROVISIONAL
## (docs/15 §6.7 P2-80..P2-85): nothing here was chosen by measuring a real
## network. The same resource is used on the server (send side) and on
## clients (mirror limits).

const DEFAULT_PATH: String = "res://data/tuning/zombie_net_settings.tres"

@export_group("Server")
## Zombie position snapshots broadcast per second (channel 2).
@export_range(1.0, 60.0) var snapshot_rate_hz: float = 10.0
## Rows per snapshot message; a snapshot with more zombies is split into
## several messages with the same tick so each stays below one datagram
## (ZombieNetProtocol.SNAPSHOT_MESSAGE_BUDGET_BYTES).
@export_range(1, 64) var snapshot_rows_per_message: int = 12
## Events per reliable event message; longer queues are split.
@export_range(1, 64) var events_per_message: int = 32

@export_group("Client")
## Newest events kept for polling (ClientZombieState.recent_events()).
@export_range(1, 100000) var recent_event_capacity: int = 256
## The mirror refuses to grow beyond this many zombies.
@export_range(1, 1000000) var max_mirrored_zombies: int = 1024


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(snapshot_rate_hz) or snapshot_rate_hz <= 0.0:
		errors.append("zombie net snapshot_rate_hz must be > 0")
	if snapshot_rows_per_message < 1 or snapshot_rows_per_message > ZombieNetProtocol.MAX_ROWS_PER_MESSAGE:
		errors.append("zombie net snapshot_rows_per_message must be within [1, %d]" % ZombieNetProtocol.MAX_ROWS_PER_MESSAGE)
	if events_per_message < 1 or events_per_message > ZombieNetProtocol.MAX_EVENTS_PER_MESSAGE:
		errors.append("zombie net events_per_message must be within [1, %d]" % ZombieNetProtocol.MAX_EVENTS_PER_MESSAGE)
	if recent_event_capacity < 1:
		errors.append("zombie net recent_event_capacity must be >= 1")
	if max_mirrored_zombies < 1:
		errors.append("zombie net max_mirrored_zombies must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> ZombieNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is ZombieNetSettings:
		return loaded as ZombieNetSettings
	GameLogger.warning("config", "zombie net settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return ZombieNetSettings.new()
