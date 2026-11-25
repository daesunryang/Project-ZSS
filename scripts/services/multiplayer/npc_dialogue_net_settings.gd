class_name NpcDialogueNetSettings
extends Resource
## Network tuning of the NPC dialogue module (NpcDialogueNetModule, F-31,
## docs/09 §17.16). Defaults in
## `res://data/tuning/npc_dialogue_net_settings.tres`. PROVISIONAL. Only the
## server reads the request rate.

const DEFAULT_PATH: String = "res://data/tuning/npc_dialogue_net_settings.tres"

## Dialogue requests of every kind (talk, choose, end) accepted per second
## per peer (token bucket rate / burst). One bucket for all three: a
## conversation is a few requests in a row, never many.
@export_range(0.01, 240.0) var dialogue_intent_rate_per_sec: float = 4.0
@export_range(1, 240) var dialogue_intent_burst: int = 6


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not is_finite(dialogue_intent_rate_per_sec) or dialogue_intent_rate_per_sec <= 0.0 or dialogue_intent_burst < 1:
		errors.append("npc dialogue net intent rate must be > 0 and burst >= 1")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcDialogueNetSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcDialogueNetSettings:
		return loaded as NpcDialogueNetSettings
	GameLogger.warning("config", "npc dialogue net settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcDialogueNetSettings.new()
