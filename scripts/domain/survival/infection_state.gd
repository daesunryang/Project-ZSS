class_name InfectionState
extends RefCounted
## Infection state of one player (docs/02 §7). B1 records the exposure
## result (NONE -> LATENT); stage progression over world time is B4.

enum Stage { NONE, LATENT, EARLY, PROGRESSING, SEVERE, TERMINAL, ZOMBIFIED }
enum Exposure { BITE, SCRATCH, BLOOD }

const STAGE_NAMES: PackedStringArray = ["none", "latent", "early", "progressing", "severe", "terminal", "zombified"]
const EXPOSURE_NAMES: PackedStringArray = ["bite", "scratch", "blood"]
const NOT_INFECTED_TIME: float = -1.0

var stage: Stage = Stage.NONE
var stage_entered_at_world_time: float = NOT_INFECTED_TIME
## Active world seconds spent in the current stage. Unlike the absolute entry
## timestamp, this excludes paused, offline and dead time.
var stage_elapsed_world_sec: float = 0.0
var infected_at_world_time: float = NOT_INFECTED_TIME
var exposure: Exposure = Exposure.BITE
var source_id: String = ""


func is_infected() -> bool:
	return stage != Stage.NONE


static func is_valid_exposure(value: int) -> bool:
	return value >= 0 and value < EXPOSURE_NAMES.size()


static func stage_name(value: Stage) -> String:
	return STAGE_NAMES[value]


func to_dict() -> Dictionary:
	return {
		"stage": STAGE_NAMES[stage],
		"stage_entered_at_world_time": stage_entered_at_world_time,
		"stage_elapsed_world_sec": stage_elapsed_world_sec,
		"infected_at_world_time": infected_at_world_time,
		"exposure": EXPOSURE_NAMES[exposure],
		"source_id": source_id,
	}


## Returns null when `data` is malformed.
static func from_dict(data: Dictionary) -> InfectionState:
	var stage_index: int = STAGE_NAMES.find(str(data.get("stage", "")))
	var exposure_index: int = EXPOSURE_NAMES.find(str(data.get("exposure", "")))
	if stage_index < 0 or exposure_index < 0:
		return null
	for key: String in ["stage_entered_at_world_time", "infected_at_world_time"]:
		var value: Variant = data.get(key, null)
		if not (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) or not is_finite(float(value)):
			return null
	var elapsed: Variant = data.get("stage_elapsed_world_sec", 0.0)
	if not (typeof(elapsed) == TYPE_FLOAT or typeof(elapsed) == TYPE_INT) or not is_finite(float(elapsed)) or float(elapsed) < 0.0:
		return null
	var state: InfectionState = InfectionState.new()
	state.stage = stage_index as Stage
	state.exposure = exposure_index as Exposure
	state.stage_entered_at_world_time = float(data["stage_entered_at_world_time"])
	state.stage_elapsed_world_sec = float(elapsed)
	state.infected_at_world_time = float(data["infected_at_world_time"])
	state.source_id = str(data.get("source_id", ""))
	return state
