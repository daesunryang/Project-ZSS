class_name InventoryNetSettings
extends Resource
## Network tuning of the inventory module (InventoryNetModule, docs/09 §14.17).
## Defaults in `res://data/tuning/inventory_net_settings.tres`. Every value is
## PROVISIONAL (docs/15 §10 P2-110..P2-116) and must be tuned by measurement.
## Only the server reads these values.

const DEFAULT_PATH: String = "res://data/tuning/inventory_net_settings.tres"

## Drop requests accepted per second per peer (token bucket rate / burst).
@export_range(0.01, 240.0) var drop_intent_rate_per_sec: float = 4.0
@export_range(1, 240) var drop_intent_burst: int = 4
## Items (world items added / inventory ids removed) packed into one message;
## a larger change is sent as several messages. At most
## InventoryNetModule.MAX_ITEMS_PER_MESSAGE, the limit clients accept.
@export_range(1, 64) var max_items_per_message: int = 32


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(drop_intent_rate_per_sec) or drop_intent_rate_per_sec <= 0.0 or drop_intent_burst < 1:
		errors.append("inventory net drop intent rate must be > 0 and burst >= 1")
	if max_items_per_message < 1 or max_items_per_message > InventoryNetModule.MAX_ITEMS_PER_MESSAGE:
		errors.append("inventory net max_items_per_message must be 1..%d" % InventoryNetModule.MAX_ITEMS_PER_MESSAGE)
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> InventoryNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is InventoryNetSettings:
		return loaded as InventoryNetSettings
	GameLogger.warning("config", "inventory net settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return InventoryNetSettings.new()
