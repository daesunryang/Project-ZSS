class_name ContainerNetSettings
extends Resource
## Network tuning of the container module (ContainerNetModule, P3-3, docs/09
## §15.3). Defaults in `res://data/tuning/container_net_settings.tres`.
## PROVISIONAL (docs/15 P3-075). Only the server reads the request rate;
## servers and clients read the message sizes.

const DEFAULT_PATH: String = "res://data/tuning/container_net_settings.tres"

@export_group("Intents")
## Container requests of every kind (open, close, take, put) accepted per
## second per peer (token bucket rate / burst). One bucket for all four:
## emptying a container is several requests in a row.
@export_range(0.01, 240.0) var container_intent_rate_per_sec: float = 8.0
@export_range(1, 240) var container_intent_burst: int = 8

@export_group("Replication")
## Container rows the server packs into one message (at most
## ClientContainerState.MAX_ROWS_PER_MESSAGE).
@export_range(1, 256) var rows_per_message: int = 64
## Removed container ids the server packs into one message (at most
## ClientContainerState.MAX_IDS_PER_MESSAGE).
@export_range(1, 256) var removals_per_message: int = 128
## Containers a client mirror holds at most (a join fragment with more, or a
## row beyond it, is refused).
@export_range(1, 10000000) var max_mirror_containers: int = 100000


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(container_intent_rate_per_sec) or container_intent_rate_per_sec <= 0.0 or container_intent_burst < 1:
		errors.append("container net intent rate must be > 0 and burst >= 1")
	if rows_per_message < 1 or rows_per_message > ClientContainerState.MAX_ROWS_PER_MESSAGE:
		errors.append("container rows_per_message must be within [1, %d]" % ClientContainerState.MAX_ROWS_PER_MESSAGE)
	if removals_per_message < 1 or removals_per_message > ClientContainerState.MAX_IDS_PER_MESSAGE:
		errors.append("container removals_per_message must be within [1, %d]" % ClientContainerState.MAX_IDS_PER_MESSAGE)
	if max_mirror_containers < 1:
		errors.append("max_mirror_containers must be >= 1")
	return errors


## Errors of the container definitions that the wire format cannot carry: a
## container may not hold more stacks than a client accepts as the content
## of one container.
func validate_against(definitions: ContainerCatalog) -> PackedStringArray:
	var errors: PackedStringArray = []
	if definitions != null and definitions.max_slot_count() > ClientContainerState.MAX_CONTENT_ENTRIES:
		errors.append("a container slot_count must be <= %d (the limit clients accept)" % ClientContainerState.MAX_CONTENT_ENTRIES)
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> ContainerNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is ContainerNetSettings:
		return loaded as ContainerNetSettings
	GameLogger.warning("config", "container net settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return ContainerNetSettings.new()
