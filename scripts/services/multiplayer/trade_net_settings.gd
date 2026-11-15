class_name TradeNetSettings
extends Resource
## Network tuning of the trade module (TradeNetModule, P2-T16, docs/09
## §14.30). Defaults in `res://data/tuning/trade_net_settings.tres`.
## PROVISIONAL (docs/15 §14.7 P2-240). Only the server reads the request
## rate.

const DEFAULT_PATH: String = "res://data/tuning/trade_net_settings.tres"

## Trade requests of every kind (ask, accept, cancel, offer, confirm)
## accepted per second per peer (token bucket rate / burst). One bucket for
## all five: putting an offer together is several requests in a row.
@export_range(0.01, 240.0) var trade_intent_rate_per_sec: float = 8.0
@export_range(1, 240) var trade_intent_burst: int = 8


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(trade_intent_rate_per_sec) or trade_intent_rate_per_sec <= 0.0 or trade_intent_burst < 1:
		errors.append("trade net intent rate must be > 0 and burst >= 1")
	return errors


## Errors of the trade rules that the wire format cannot carry: an offer may
## not hold more stacks than a client accepts in one session state.
func validate_against(trade: TradeSettings) -> PackedStringArray:
	var errors: PackedStringArray = []
	if trade.max_offer_entries > ClientTradeState.MAX_OFFER_ENTRIES:
		errors.append("trade max_offer_entries must be <= %d (the limit clients accept)" % ClientTradeState.MAX_OFFER_ENTRIES)
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> TradeNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is TradeNetSettings:
		return loaded as TradeNetSettings
	GameLogger.warning("config", "trade net settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return TradeNetSettings.new()
