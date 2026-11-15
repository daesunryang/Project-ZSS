class_name StructureNetSettings
extends Resource
## Network tuning of the structure module (StructureNetModule, docs/09
## §15.4). Defaults in `res://data/tuning/structure_net_settings.tres`.
## PROVISIONAL (docs/15 P3-112..P3-116). Only the server reads the request rates
## and the save switches; servers and clients read the message sizes.

const DEFAULT_PATH: String = "res://data/tuning/structure_net_settings.tres"

@export_group("Intents")
## Placement requests accepted per second per peer (token bucket rate /
## burst).
@export_range(0.01, 240.0) var place_intent_rate_per_sec: float = 4.0
@export_range(1, 240) var place_intent_burst: int = 8
## Demolish requests accepted per second per peer.
@export_range(0.01, 240.0) var demolish_intent_rate_per_sec: float = 4.0
@export_range(1, 240) var demolish_intent_burst: int = 8
## Door requests accepted per second per peer.
@export_range(0.01, 240.0) var door_intent_rate_per_sec: float = 4.0
@export_range(1, 240) var door_intent_burst: int = 4

@export_group("Replication")
## Structure rows the server packs into one message (at most
## ClientStructureState.MAX_ROWS_PER_MESSAGE).
@export_range(1, 256) var rows_per_message: int = 64
## Removed structure ids the server packs into one message (at most
## ClientStructureState.MAX_IDS_PER_MESSAGE).
@export_range(1, 256) var removals_per_message: int = 128
## Structures a client mirror holds at most (a join fragment with more, or a
## row beyond it, is refused).
@export_range(1, 10000000) var max_mirror_structures: int = 200000

@export_group("Saving")
## Save the world as soon as a placement or a demolition was accepted (like
## a pickup or a drop). false = it is saved by the next autosave, cell
## unload or shutdown.
@export var persist_on_place_and_demolish: bool = true
## Save the world as soon as a door was opened or closed.
@export var persist_on_door_change: bool = false


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for rate: float in [place_intent_rate_per_sec, demolish_intent_rate_per_sec, door_intent_rate_per_sec]:
		if not is_finite(rate) or rate <= 0.0:
			errors.append("structure net intent rates must be > 0")
			break
	if place_intent_burst < 1 or demolish_intent_burst < 1 or door_intent_burst < 1:
		errors.append("structure net intent bursts must be >= 1")
	if rows_per_message < 1 or rows_per_message > ClientStructureState.MAX_ROWS_PER_MESSAGE:
		errors.append("structure net rows_per_message must be 1..%d" % ClientStructureState.MAX_ROWS_PER_MESSAGE)
	if removals_per_message < 1 or removals_per_message > ClientStructureState.MAX_IDS_PER_MESSAGE:
		errors.append("structure net removals_per_message must be 1..%d" % ClientStructureState.MAX_IDS_PER_MESSAGE)
	if max_mirror_structures < 1:
		errors.append("structure net max_mirror_structures must be >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> StructureNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is StructureNetSettings:
		return loaded as StructureNetSettings
	GameLogger.warning("config", "structure net settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return StructureNetSettings.new()
