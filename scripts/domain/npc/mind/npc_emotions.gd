class_name NpcEmotions
extends NpcComponent
## Thirteen independent normalized emotion axes (docs/05 §5). Values are
## stored at one calendar timestamp and decay lazily by half-life; reads do
## not mutate the component and there is no per-frame work.

const COMPONENT_ID: String = "emotions"
const SCHEMA_VERSION: int = 1
const AXES: PackedStringArray = [
	"happiness",
	"sadness",
	"anger",
	"fear",
	"disgust",
	"surprise",
	"loneliness",
	"shame",
	"guilt",
	"jealousy",
	"hope",
	"grief",
	"frustration",
]
const REASON_UNKNOWN_EMOTION: String = "unknown_emotion"
const REASON_BAD_VALUE: String = "bad_emotion_value"
const REASON_TIME_REWIND: String = "emotion_time_rewind"

const KEY_STORED_AT: String = "stored_at_world_time"
const KEY_VALUES: String = "values"

var _settings: NpcMindSettings
var _stored_at_world_time: float = 0.0
var _values: Dictionary[String, float] = {}
var _service_ref: WeakRef = null
var _npc_id: String = ""


func _init(settings: NpcMindSettings = null) -> void:
	_settings = settings if settings != null else NpcMindSettings.new()
	_reset_values()


static func create(settings: NpcMindSettings) -> NpcComponent:
	return NpcEmotions.new(settings)


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func on_created(_npc: NpcState, _definition: NpcDefinition, clock: WorldClock) -> void:
	_reset_values()
	_stored_at_world_time = clock.world_time_sec


func on_attached(world: ServerWorld, npc: NpcState) -> void:
	var service: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
	_service_ref = weakref(service) if service != null else null
	_npc_id = npc.npc_id


func on_detached(_world: ServerWorld, _npc: NpcState, _retired: bool) -> void:
	_service_ref = null
	_npc_id = ""


## Adds `delta` to one axis after materializing every axis at
## `world_time_sec`. The new value is clamped to [0, 1].
func apply_emotion(axis: String, delta: float, world_time_sec: float) -> ActionResult:
	if not AXES.has(axis):
		return ActionResult.failure(REASON_UNKNOWN_EMOTION)
	if not is_finite(delta) or not is_finite(world_time_sec) or world_time_sec < 0.0:
		return ActionResult.failure(REASON_BAD_VALUE)
	if world_time_sec < _stored_at_world_time:
		return ActionResult.failure(REASON_TIME_REWIND)
	var timestamp_changed: bool = world_time_sec > _stored_at_world_time
	_materialize(world_time_sec)
	var previous: float = _values[axis]
	var next: float = clampf(previous + delta, 0.0, 1.0)
	_values[axis] = next
	if timestamp_changed or next != previous:
		_mark_dirty()
	return ActionResult.success({"emotion": axis, "previous": previous, "value": next, "world_time": world_time_sec})


## Decayed value without changing the saved base value or timestamp.
func value_at(axis: String, world_time_sec: float) -> float:
	if not AXES.has(axis) or not is_finite(world_time_sec) or world_time_sec < _stored_at_world_time:
		return 0.0
	return _decayed(_values[axis], world_time_sec - _stored_at_world_time)


## All 13 decayed values, in the stable axis names above.
func emotion_values_at(world_time_sec: float) -> Dictionary[String, float]:
	var result: Dictionary[String, float] = {}
	for axis: String in AXES:
		result[axis] = value_at(axis, world_time_sec)
	return result


func to_document() -> Dictionary:
	var saved_values: Dictionary = {}
	for axis: String in AXES:
		saved_values[axis] = _values[axis]
	return {KEY_STORED_AT: _stored_at_world_time, KEY_VALUES: saved_values}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("unsupported schema_version")
	var stored_at: Variant = document.get(KEY_STORED_AT, null)
	if not _is_nonnegative_finite_number(stored_at):
		errors.append("stored_at_world_time must be finite and >= 0")
	var raw_values: Variant = document.get(KEY_VALUES, null)
	if typeof(raw_values) != TYPE_DICTIONARY:
		errors.append("values must be an object")
	else:
		if (raw_values as Dictionary).size() != AXES.size():
			errors.append("values must contain all 13 emotion axes")
		for axis: String in AXES:
			var value: Variant = (raw_values as Dictionary).get(axis, null)
			if not _is_unit_number(value):
				errors.append("%s must be within 0..1" % axis)
	if not errors.is_empty():
		return errors
	_stored_at_world_time = float(stored_at)
	_values.clear()
	for axis: String in AXES:
		_values[axis] = float((raw_values as Dictionary)[axis])
	return errors


func _reset_values() -> void:
	_values.clear()
	for axis: String in AXES:
		_values[axis] = 0.0


func _materialize(world_time_sec: float) -> void:
	var elapsed: float = world_time_sec - _stored_at_world_time
	if elapsed <= 0.0:
		return
	for axis: String in AXES:
		_values[axis] = _decayed(_values[axis], elapsed)
	_stored_at_world_time = world_time_sec


func _decayed(value: float, elapsed_world_sec: float) -> float:
	if value <= 0.0 or elapsed_world_sec <= 0.0:
		return value
	return value * pow(0.5, elapsed_world_sec / _settings.emotion_half_life_world_sec)


func _mark_dirty() -> void:
	var service: NpcService = _service_ref.get_ref() as NpcService if _service_ref != null else null
	if service != null and not _npc_id.is_empty():
		service.mark_npc_dirty(_npc_id)


static func _is_unit_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= 1.0


static func _is_nonnegative_finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value)) and float(value) >= 0.0
