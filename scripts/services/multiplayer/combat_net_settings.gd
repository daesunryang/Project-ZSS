class_name CombatNetSettings
extends Resource
## Network tuning of the combat module (CombatNetModule, docs/09 §14.13).
## Defaults in `res://data/tuning/combat_net_settings.tres`. Every value is
## PROVISIONAL (docs/15 §6.9 P2-60..P2-65) and must be tuned by measurement.
## The request limiter and the broadcast options are read by the server;
## `recent_event_capacity` is used by every peer for its own event list.

const DEFAULT_PATH: String = "res://data/tuning/combat_net_settings.tres"

## Melee attack requests accepted per second per peer (token bucket rate /
## burst). This only bounds the request traffic; how often a player may
## really swing is the weapon cooldown, decided by CombatService.
@export_range(0.01, 240.0) var melee_intent_rate_per_sec: float = 4.0
@export_range(1, 240) var melee_intent_burst: int = 4
## Combat events packed into one broadcast message; a tick with more events
## sends several messages. At most CombatNetModule.MAX_EVENTS_PER_MESSAGE,
## the limit clients accept.
@export_range(1, 64) var max_events_per_message: int = 32
## Newest combat events kept for `CombatNetModule.recent_events()`.
@export_range(1, 100000) var recent_event_capacity: int = 64
## Whether `damage` and `target_health_after` of a melee attack are sent to
## every client (docs/15 P2-9, P2-62). When false the two fields are left
## out of the broadcast for everyone, the attacker included.
@export var broadcast_damage_numbers: bool = true


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(melee_intent_rate_per_sec) or melee_intent_rate_per_sec <= 0.0 or melee_intent_burst < 1:
		errors.append("combat net melee intent rate must be > 0 and burst >= 1")
	if max_events_per_message < 1 or max_events_per_message > CombatNetModule.MAX_EVENTS_PER_MESSAGE:
		errors.append("combat net max_events_per_message must be 1..%d" % CombatNetModule.MAX_EVENTS_PER_MESSAGE)
	if recent_event_capacity < 1:
		errors.append("combat net recent_event_capacity must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> CombatNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is CombatNetSettings:
		return loaded as CombatNetSettings
	GameLogger.warning("config", "combat net settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return CombatNetSettings.new()
