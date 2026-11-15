class_name TradeSettings
extends Resource
## Tuning of the trade rules (TradeService, P2-T16, docs/00 ADR-022, docs/09
## §14.30). Defaults in `res://data/tuning/trade_settings.tres`. Every value
## is PROVISIONAL (docs/15 §14.7 P2-226..P2-245): the user decided that two
## players exchange items by mutual agreement, not these numbers. Only the
## server reads these values.

const DEFAULT_PATH: String = "res://data/tuning/trade_settings.tres"

## Maximum distance between two players for one to ask the other for a
## trade, metres. Measured between server positions, like the pickup and the
## treat range (3D distance, the range included).
@export_range(0.1, 50.0) var request_range_m: float = 2.5
## A pending request or an open session is cancelled once the two players
## are further apart than this, metres. Not smaller than `request_range_m`:
## the difference keeps a session from ending because somebody shifts a
## step.
@export_range(0.1, 100.0) var session_range_m: float = 4.0
## An unanswered request is cancelled after this many real seconds (action
## time, docs/09 §14.16).
@export_range(1.0, 600.0) var request_timeout_sec: float = 20.0
## An open session in which nothing was accepted for this many real seconds
## (no offer change, no confirmation) is cancelled.
@export_range(1.0, 3600.0) var session_idle_timeout_sec: float = 120.0
## Stacks one player can have in its offer at a time.
@export_range(1, 32) var max_offer_entries: int = 8
## Session events kept between two drains by the network module (oldest
## dropped).
@export_range(1, 10000) var max_pending_events: int = 256


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(request_range_m) or request_range_m <= 0.0:
		errors.append("trade request_range_m must be > 0")
	if not is_finite(session_range_m) or session_range_m < request_range_m:
		errors.append("trade session_range_m must be >= request_range_m")
	if not is_finite(request_timeout_sec) or request_timeout_sec <= 0.0:
		errors.append("trade request_timeout_sec must be > 0")
	if not is_finite(session_idle_timeout_sec) or session_idle_timeout_sec <= 0.0:
		errors.append("trade session_idle_timeout_sec must be > 0")
	if max_offer_entries < 1:
		errors.append("trade max_offer_entries must be >= 1")
	if max_pending_events < 1:
		errors.append("trade max_pending_events must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> TradeSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is TradeSettings:
		return loaded as TradeSettings
	GameLogger.warning("config", "trade settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return TradeSettings.new()
