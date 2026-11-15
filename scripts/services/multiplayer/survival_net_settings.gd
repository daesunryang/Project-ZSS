class_name SurvivalNetSettings
extends Resource
## Tuning for server -> client survival replication (docs/09 §14.14) and the
## rest intent (docs/09 §14.23). Values are PROVISIONAL in docs/15
## P2-70..P2-72 and P2-154.

const DEFAULT_PATH: String = "res://data/tuning/survival_net_settings.tres"

## Owner-only full snapshot checks per real second. A snapshot is sent only
## when its validated payload differs from the last one sent to that owner.
@export_range(0.01, 1000.0) var owner_snapshot_rate_hz: float = 2.0
## Client-side bounded history exposed by ClientSurvivalState.recent_events().
@export_range(1, 100000) var max_recent_events: int = 128
## Defensive DTO bound for server-generated player ids.
@export_range(1, 10000) var max_player_id_length: int = 128
## Rest requests (lie down / get up, P2-T8) accepted per second per peer
## (token bucket rate / burst). Only the server reads these.
@export_range(0.01, 240.0) var rest_intent_rate_per_sec: float = 4.0
@export_range(1, 240) var rest_intent_burst: int = 4


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(rest_intent_rate_per_sec) or rest_intent_rate_per_sec <= 0.0 or rest_intent_burst < 1:
		errors.append("survival net rest intent rate must be > 0 and burst >= 1")
	if not is_finite(owner_snapshot_rate_hz) or owner_snapshot_rate_hz <= 0.0:
		errors.append("survival net owner_snapshot_rate_hz must be finite and > 0")
	if max_recent_events < 1:
		errors.append("survival net max_recent_events must be >= 1")
	if max_player_id_length < 1:
		errors.append("survival net max_player_id_length must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> SurvivalNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is SurvivalNetSettings:
		return loaded as SurvivalNetSettings
	GameLogger.warning("config", "survival network settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return SurvivalNetSettings.new()
