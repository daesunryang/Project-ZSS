class_name PostureNetSettings
extends Resource
## Network tuning of the posture module (PostureNetModule, docs/09 §14.26).
## Defaults in `res://data/tuning/posture_net_settings.tres`. PROVISIONAL
## (docs/15 P2-193). Only the server reads the request rate.

const DEFAULT_PATH: String = "res://data/tuning/posture_net_settings.tres"

## Posture requests (stand / go prone / lie down) accepted per second per
## peer (token bucket rate / burst).
@export_range(0.01, 240.0) var posture_intent_rate_per_sec: float = 4.0
@export_range(1, 240) var posture_intent_burst: int = 4
## Defensive DTO bound for server-generated player ids (client side).
@export_range(1, 10000) var max_player_id_length: int = 128


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(posture_intent_rate_per_sec) or posture_intent_rate_per_sec <= 0.0 or posture_intent_burst < 1:
		errors.append("posture net intent rate must be > 0 and burst >= 1")
	if max_player_id_length < 1:
		errors.append("posture net max_player_id_length must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> PostureNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is PostureNetSettings:
		return loaded as PostureNetSettings
	GameLogger.warning("config", "posture net settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return PostureNetSettings.new()
