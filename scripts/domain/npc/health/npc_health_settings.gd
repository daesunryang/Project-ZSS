class_name NpcHealthSettings
extends Resource
## Rules of the NPCs' bodies that are NOT the players' numbers (F-25,
## docs/09 §17.12). Health, wounds, bleeding and infection use the players'
## SurvivalSettings as they are. Defaults in
## `res://data/tuning/npc_health_settings.tres`. Every value is PROVISIONAL
## (docs/15 §22); the rules of rising are the user's to confirm
## (F25-001, F25-002).

const DEFAULT_PATH: String = "res://data/tuning/npc_health_settings.tres"

@export_group("Condition")
## At or below this share of its health (or while it bleeds) an NPC looks
## "hurt" to the players.
@export_range(0.0, 1.0, 0.01) var hurt_health_fraction: float = 0.5

@export_group("Hits by players")
## Body part a player's melee hit lands on (BodyPart.NAMES). The request
## carries no aimed part yet.
@export var melee_body_part: String = "torso"

@export_group("Rising")
## True: an NPC that dies infected rises as a zombie.
@export var infected_rise: bool = true
## True: an NPC that dies with a zombie's bite among its wounds rises too,
## whether or not the bite infected it.
@export var bitten_rise: bool = true
## Chance (0..1) that a body that may rise does (the NPC's own generator).
@export_range(0.0, 1.0, 0.01) var rise_chance: float = 1.0
## Calendar seconds between the death and the rising.
@export_range(0.0, 8640000.0, 1.0) var rise_delay_world_sec: float = 1440.0
## Calendar seconds a body that does not rise stays before it is taken out
## of the world (what it carried lies on the ground, not in the body).
@export_range(0.0, 86400000.0, 1.0) var body_remove_delay_world_sec: float = 86400.0
## Calendar seconds after which a spawn that was refused (the zombie limit)
## is tried again; the body stays until then.
@export_range(1.0, 864000.0, 1.0) var rise_retry_world_sec: float = 240.0

@export_group("Self treatment")
## True: an NPC that bleeds or is infected uses a treatment it carries.
@export var self_treat_enabled: bool = true
## Calendar seconds between two treatments an NPC gives itself.
@export_range(0.0, 864000.0, 1.0) var self_treat_cooldown_world_sec: float = 240.0

@export_group("Witnesses")
## NPCs this close to a death (metres, with a free line to it) remember it.
@export_range(0.0, 500.0, 0.5) var witness_range_m: float = 30.0
## Importance and emotional intensity of that memory (0..1).
@export_range(0.0, 1.0, 0.01) var death_memory_importance: float = 0.9
@export_range(0.0, 1.0, 0.01) var death_memory_intensity: float = 0.8
## What a witness feels at once (added to the axis, 0..1).
@export_range(0.0, 1.0, 0.01) var witness_fear: float = 0.4
@export_range(0.0, 1.0, 0.01) var witness_grief: float = 0.3


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if BodyPart.from_name(melee_body_part) < 0:
		errors.append("npc health melee_body_part is not a body part")
	for row: Array in [
		["hurt_health_fraction", hurt_health_fraction], ["rise_chance", rise_chance],
		["death_memory_importance", death_memory_importance], ["death_memory_intensity", death_memory_intensity],
		["witness_fear", witness_fear], ["witness_grief", witness_grief],
	]:
		if not is_finite(float(row[1])) or float(row[1]) < 0.0 or float(row[1]) > 1.0:
			errors.append("npc health %s must be within 0..1" % str(row[0]))
	for row: Array in [
		["rise_delay_world_sec", rise_delay_world_sec], ["body_remove_delay_world_sec", body_remove_delay_world_sec],
		["self_treat_cooldown_world_sec", self_treat_cooldown_world_sec], ["witness_range_m", witness_range_m],
	]:
		if not is_finite(float(row[1])) or float(row[1]) < 0.0:
			errors.append("npc health %s must be finite and >= 0" % str(row[0]))
	if not is_finite(rise_retry_world_sec) or rise_retry_world_sec <= 0.0:
		errors.append("npc health rise_retry_world_sec must be finite and > 0")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcHealthSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcHealthSettings:
		return loaded as NpcHealthSettings
	GameLogger.warning("config", "npc health settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcHealthSettings.new()
