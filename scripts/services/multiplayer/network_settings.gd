class_name NetworkSettings
extends Resource
## Network/session settings. Defaults in `res://data/tuning/network_settings.tres`.
## All values are PROVISIONAL (docs/15 §5): port, player limit, rates and
## timeouts are not product decisions and must be tuned by measurement.

const DEFAULT_PATH: String = "res://data/tuning/network_settings.tres"
## Reliable, ordered: join, inventory, pickup results, join/leave notices.
const CHANNEL_RELIABLE: int = 0
## Unreliable ordered: player move intents and position snapshots.
const CHANNEL_SNAPSHOT: int = 1
## Unreliable ordered: AI entity (zombie) snapshots. Used by ZombieNetModule (P2-N1a).
const CHANNEL_ENTITY_SNAPSHOT: int = 2
const CHANNEL_COUNT: int = 3
## Extra transport slots so a full server can still answer "server_full".
const TRANSPORT_HEADROOM: int = 2

@export_range(1, 65535) var port: int = 24680
@export var bind_address: String = "*"
## Maximum simultaneously joined players (docs/00: 1~4 initial target).
@export_range(1, 64) var max_players: int = 4
## Seconds a connected peer may take to complete the join handshake.
@export_range(0.5, 60.0) var handshake_timeout_sec: float = 5.0
## Delay before a rejected peer is disconnected (lets the reason arrive).
@export_range(0.05, 5.0) var reject_disconnect_delay_sec: float = 0.25
## Accepted player_key length range.
@export_range(1, 256) var player_key_max_length: int = 64
## Position snapshots broadcast per second.
@export_range(1.0, 60.0) var snapshot_rate_hz: float = 20.0
## Move intents accepted per second per peer (token bucket rate / burst).
@export_range(1.0, 240.0) var move_intent_rate_per_sec: float = 60.0
@export_range(1, 240) var move_intent_burst: int = 30
## Pickup intents accepted per second per peer (rate / burst).
@export_range(0.1, 60.0) var pickup_intent_rate_per_sec: float = 4.0
@export_range(1, 60) var pickup_intent_burst: int = 4
## Seconds without a move intent after which the server stops the player.
@export_range(0.05, 10.0) var move_input_timeout_sec: float = 0.5
## Periodic world save interval in seconds (0 disables).
@export_range(0.0, 3600.0) var autosave_interval_sec: float = 60.0


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if port < 1 or port > 65535:
		errors.append("port out of range")
	if max_players < 1:
		errors.append("max_players must be >= 1")
	if handshake_timeout_sec <= 0.0:
		errors.append("handshake_timeout_sec must be > 0")
	if snapshot_rate_hz <= 0.0 or move_intent_rate_per_sec <= 0.0 or pickup_intent_rate_per_sec <= 0.0:
		errors.append("rates must be > 0")
	if autosave_interval_sec < 0.0:
		errors.append("autosave_interval_sec must be >= 0")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NetworkSettings:
	if ResourceLoader.exists(path):
		var loaded: Resource = ResourceLoader.load(path)
		if loaded is NetworkSettings:
			return loaded as NetworkSettings
		GameLogger.error("config", "network settings has wrong type, using defaults", {"path": path, "operation": "load_settings"})
	else:
		GameLogger.warning("config", "network settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NetworkSettings.new()
