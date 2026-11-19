class_name NpcNeeds
extends NpcComponent
## Saved NPC hunger, thirst and fatigue (P4-2, docs/09 §17.2). The
## component never runs every tick. A decision/evaluation asks advance_to()
## to integrate the calendar interval since the stored baseline, then uses
## next_category_boundary_world_time() to schedule the next relevant wakeup.

const COMPONENT_ID: String = "needs"
const SCHEMA_VERSION: int = 2
const LEGACY_SCHEMA_VERSION: int = 1
const EVENT_SATISFIED: String = "npc_need_satisfied"
const EVENT_ACTIVITY_CHANGED: String = "npc_need_activity_changed"
const EVENT_MODIFIERS_CHANGED: String = "npc_need_modifiers_changed"

const REASON_UNSUPPORTED_NEED: String = "unsupported_npc_need"
const REASON_BAD_AMOUNT: String = "bad_npc_need_amount"
const REASON_BAD_SOURCE: String = "bad_npc_need_source"
const REASON_BAD_ACTIVITY: String = "bad_npc_need_activity"
const REASON_BAD_MODIFIER: String = "bad_npc_need_modifier"
const REASON_BAD_WORLD_TIME: String = "bad_npc_need_world_time"

const KEY_VALUES: String = "values"
const KEY_ACTIVITY: String = "activity"
const KEY_PERSONALITY_MODIFIER: String = "personality_modifier"
const KEY_ABILITY_MODIFIER: String = "ability_modifier"
const KEY_LAST_UPDATED: String = "last_updated_world_time"
const KEY_SEGMENT_STARTED: String = "rate_segment_started_world_time"
const KEY_SEGMENT_VALUES: String = "rate_segment_start_values"
const KEY_SEGMENT_RATES: String = "rate_segment_rates_per_world_sec"
const FLOAT64_BYTE_COUNT: int = 8
const FLOAT64_BASE64_PATTERN: String = "^[A-Za-z0-9+/]{11}=$"
const SOURCE_MAX_LENGTH: int = 128
const MODIFIER_MAX: float = NpcNeedSettings.MAX_RATE_MODIFIER
## A falling continuous value changes category immediately after reaching an
## inclusive threshold. Scheduling this tiny value distance beyond it avoids
## repeatedly returning the same timestamp while remaining far below gameplay
## precision.
const FALLING_BOUNDARY_VALUE_EPSILON: float = 0.000001
const RESTORE_TOLERANCE: float = 0.00001

var _settings: NpcNeedSettings
var _values: Dictionary[String, float] = {}
var _activity: String = NpcNeedKind.IDLE
var _personality_modifier: float = 1.0
var _ability_modifier: float = 1.0
## Most recent calendar instant to which `_values` was evaluated.
var _last_updated_world_time: float = 0.0
## Start of the current constant-rate segment. Keeping this origin (and
## saving it) makes repeated 1-second and 10-second evaluations bit-equal.
var _rate_segment_started_world_time: float = 0.0
var _rate_segment_start_values: Dictionary[String, float] = {}
## Rates are saved with the segment. A tuning file change cannot make an
## existing save invalid or rewrite elapsed history; the new tuning starts
## with the next activity/modifier segment.
var _rate_segment_rates: Dictionary[String, float] = {}

var _world_ref: WeakRef = null
var _npc_id: String = ""


func _init(settings: NpcNeedSettings = null) -> void:
	_settings = settings if settings != null else NpcNeedSettings.load_or_default()
	_reset_values()


static func create(settings: NpcNeedSettings) -> NpcComponent:
	return NpcNeeds.new(settings)


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func on_created(npc: NpcState, _definition: NpcDefinition, clock: WorldClock) -> void:
	_npc_id = npc.npc_id
	_reset_values()
	_activity = NpcNeedKind.IDLE
	_personality_modifier = _settings.default_personality_modifier
	_ability_modifier = _settings.default_ability_modifier
	_last_updated_world_time = clock.world_time_sec
	_rate_segment_started_world_time = clock.world_time_sec
	_rate_segment_start_values = _values.duplicate()
	_set_segment_rates()


func on_attached(world: ServerWorld, npc: NpcState) -> void:
	_world_ref = weakref(world)
	_npc_id = npc.npc_id


func on_detached(_world: ServerWorld, _npc: NpcState, _retired: bool) -> void:
	_world_ref = null
	_npc_id = ""


func to_document() -> Dictionary:
	return {
		KEY_VALUES: _encoded_values(_values),
		KEY_ACTIVITY: _activity,
		KEY_PERSONALITY_MODIFIER: _encode_float64(_personality_modifier),
		KEY_ABILITY_MODIFIER: _encode_float64(_ability_modifier),
		KEY_LAST_UPDATED: _encode_float64(_last_updated_world_time),
		KEY_SEGMENT_STARTED: _encode_float64(_rate_segment_started_world_time),
		KEY_SEGMENT_VALUES: _encoded_values(_rate_segment_start_values),
		KEY_SEGMENT_RATES: _encoded_values(_rate_segment_rates),
	}


## Validates the complete component document before changing this instance.
func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	var raw_version: Variant = document.get(NpcComponent.KEY_SCHEMA_VERSION, null)
	if not ItemInstance.is_integer_value(raw_version) or not [LEGACY_SCHEMA_VERSION, SCHEMA_VERSION].has(int(raw_version)):
		errors.append("unsupported schema_version")
		return errors
	var saved_version: int = int(raw_version)
	var parsed_values: Dictionary[String, float] = _parse_values(document.get(KEY_VALUES, null), KEY_VALUES, saved_version, errors)
	var parsed_segment_values: Dictionary[String, float] = _parse_values(document.get(KEY_SEGMENT_VALUES, null), KEY_SEGMENT_VALUES, saved_version, errors)
	var parsed_segment_rates: Dictionary[String, float] = _parse_rates(document.get(KEY_SEGMENT_RATES, null), saved_version, errors)
	var activity_value: Variant = document.get(KEY_ACTIVITY, null)
	if typeof(activity_value) != TYPE_STRING or not NpcNeedKind.is_valid_activity(str(activity_value)):
		errors.append("activity must be idle, resting or working")
	var personality_value: float = _parse_saved_float(document.get(KEY_PERSONALITY_MODIFIER, null), KEY_PERSONALITY_MODIFIER, saved_version, errors)
	var ability_value: float = _parse_saved_float(document.get(KEY_ABILITY_MODIFIER, null), KEY_ABILITY_MODIFIER, saved_version, errors)
	if not _is_valid_modifier(personality_value):
		errors.append("personality_modifier must be finite and within (0, 100]")
	if not _is_valid_modifier(ability_value):
		errors.append("ability_modifier must be finite and within (0, 100]")
	var updated_value: float = _parse_saved_float(document.get(KEY_LAST_UPDATED, null), KEY_LAST_UPDATED, saved_version, errors)
	var segment_started_value: float = _parse_saved_float(document.get(KEY_SEGMENT_STARTED, null), KEY_SEGMENT_STARTED, saved_version, errors)
	if not _is_non_negative_number(updated_value):
		errors.append("last_updated_world_time must be finite and >= 0")
	if not _is_non_negative_number(segment_started_value):
		errors.append("rate_segment_started_world_time must be finite and >= 0")
	if errors.is_empty() and float(segment_started_value) > float(updated_value):
		errors.append("rate segment cannot start after last_updated_world_time")
	if errors.is_empty():
		var expected: Dictionary[String, float] = _project_values(
			parsed_segment_values,
			parsed_segment_rates,
			float(updated_value) - float(segment_started_value)
		)
		for kind: String in NpcNeedKind.SIMULATED_KINDS:
			if absf(parsed_values[kind] - expected[kind]) > RESTORE_TOLERANCE:
				errors.append("values do not match the saved rate segment")
				break
	if not errors.is_empty():
		return errors
	_values = parsed_values
	_activity = str(activity_value)
	_personality_modifier = personality_value
	_ability_modifier = ability_value
	_last_updated_world_time = updated_value
	_rate_segment_started_world_time = segment_started_value
	_rate_segment_start_values = parsed_segment_values
	_rate_segment_rates = parsed_segment_rates
	return errors


func has_definition(kind: String) -> bool:
	return _settings.defined_kinds.has(kind)


func is_simulated(kind: String) -> bool:
	return NpcNeedKind.is_simulated(kind)


func value(kind: String) -> float:
	return _values.get(kind, 0.0)


func category(kind: String) -> NpcNeedKind.Category:
	if not NpcNeedKind.is_simulated(kind):
		return NpcNeedKind.Category.NORMAL
	return NpcNeedKind.category_for(value(kind), _settings.caution_threshold, _settings.danger_threshold)


func activity() -> String:
	return _activity


func personality_modifier() -> float:
	return _personality_modifier


func ability_modifier() -> float:
	return _ability_modifier


func last_updated_world_time() -> float:
	return _last_updated_world_time


## Integrates to an absolute calendar timestamp and returns the next category
## boundary after it (absolute calendar time, INF when none). Invalid or
## backwards time changes nothing and returns INF.
func advance_to(world_time: float) -> float:
	if not is_finite(world_time) or world_time < _last_updated_world_time:
		GameLogger.error("npc", "npc needs refused invalid calendar time", {"entity_id": _npc_id, "world_time": world_time, "last_updated_world_time": _last_updated_world_time, "operation": "advance_needs"})
		return INF
	if world_time == _last_updated_world_time:
		return next_category_boundary_world_time()
	_values = _project_values(
		_rate_segment_start_values,
		_rate_segment_rates,
		world_time - _rate_segment_started_world_time
	)
	_last_updated_world_time = world_time
	_mark_dirty()
	return next_category_boundary_world_time()


## Absolute calendar time of the first future NORMAL/CAUTION/DANGER boundary.
## INF means no current rate can change a category.
func next_category_boundary_world_time() -> float:
	var next_time: float = INF
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		var rate: float = _rate(kind)
		if rate == 0.0:
			continue
		var current: float = _values[kind]
		if rate > 0.0:
			for threshold: float in [_settings.caution_threshold, _settings.danger_threshold]:
				if current < threshold:
					next_time = minf(next_time, _last_updated_world_time + (threshold - current) / rate)
					break
		else:
			# Highest crossed threshold is first for a falling value.
			for threshold: float in [_settings.danger_threshold, _settings.caution_threshold]:
				if current >= threshold:
					var distance: float = current - threshold + FALLING_BOUNDARY_VALUE_EPSILON
					next_time = minf(next_time, _last_updated_world_time + distance / -rate)
					break
	return next_time


## Changes the activity at `world_time`, after integrating the old activity
## through that instant. Work accelerates fatigue; rest reverses it.
func set_activity(next_activity: String, world_time: float) -> ActionResult:
	if not NpcNeedKind.is_valid_activity(next_activity):
		return ActionResult.failure(REASON_BAD_ACTIVITY)
	if not _is_forward_time(world_time):
		return ActionResult.failure(REASON_BAD_WORLD_TIME)
	advance_to(world_time)
	var previous: String = _activity
	if previous != next_activity:
		_activity = next_activity
		_start_rate_segment(world_time)
		_mark_dirty()
	return ActionResult.success({
		"event_type": EVENT_ACTIVITY_CHANGED,
		"npc_id": _npc_id,
		"from": previous,
		"to": next_activity,
		"world_time": world_time,
	})


## Future seam for authored personality/ability effects. Phase 4 defaults to
## 1.0 × 1.0. The current activity is integrated before the rate changes.
func set_rate_modifiers(personality: float, ability: float, world_time: float) -> ActionResult:
	if not _is_valid_modifier(personality) or not _is_valid_modifier(ability):
		return ActionResult.failure(REASON_BAD_MODIFIER)
	if not _is_forward_time(world_time):
		return ActionResult.failure(REASON_BAD_WORLD_TIME)
	advance_to(world_time)
	_personality_modifier = personality
	_ability_modifier = ability
	_start_rate_segment(world_time)
	_mark_dirty()
	return ActionResult.success({
		"event_type": EVENT_MODIFIERS_CHANGED,
		"npc_id": _npc_id,
		KEY_PERSONALITY_MODIFIER: personality,
		KEY_ABILITY_MODIFIER: ability,
		"world_time": world_time,
	})


## Lowers one of the three simulated needs. `source` is returned in the
## approved event for later behaviour/memory code; it is not persistent.
func satisfy(kind: String, amount: float, source: String) -> ActionResult:
	if not NpcNeedKind.is_simulated(kind):
		return ActionResult.failure(REASON_UNSUPPORTED_NEED)
	if not is_finite(amount) or amount <= 0.0:
		return ActionResult.failure(REASON_BAD_AMOUNT)
	if source.strip_edges().is_empty() or source.length() > SOURCE_MAX_LENGTH:
		return ActionResult.failure(REASON_BAD_SOURCE)
	var now: float = _calendar_now()
	advance_to(now)
	var previous: float = _values[kind]
	var moved: float = minf(previous, amount)
	_values[kind] = previous - moved
	if moved > 0.0:
		_start_rate_segment(now)
		_mark_dirty()
	var event: Dictionary = {
		"event_type": EVENT_SATISFIED,
		"npc_id": _npc_id,
		"need": kind,
		"source": source,
		"requested_amount": amount,
		"applied_amount": moved,
		"value": _values[kind],
		"category": NpcNeedKind.category_name(category(kind)),
		"world_time": now,
	}
	GameLogger.info("npc", "npc need satisfied", event.merged({"entity_id": _npc_id, "operation": "satisfy_need"}))
	return ActionResult.success(event)


func _reset_values() -> void:
	_values.clear()
	_rate_segment_start_values.clear()
	_rate_segment_rates.clear()
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		_values[kind] = 0.0
		_rate_segment_start_values[kind] = 0.0


## Schema 2 stores every float as its eight IEEE-754 bytes in base64. JSON
## then only handles strings, so even values below 0.1 and exponent-form
## rates survive Godot 4.7.2's parser bit-for-bit.
func _encoded_values(source: Dictionary[String, float]) -> Dictionary:
	var result: Dictionary = {}
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		result[kind] = _encode_float64(source.get(kind, 0.0))
	return result


func _parse_values(raw: Variant, label: String, saved_version: int, errors: PackedStringArray) -> Dictionary[String, float]:
	var parsed: Dictionary[String, float] = {}
	if typeof(raw) != TYPE_DICTIONARY or (raw as Dictionary).size() != NpcNeedKind.SIMULATED_KINDS.size():
		errors.append("%s must contain hunger, thirst and fatigue" % label)
		return parsed
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		var raw_value: Variant = (raw as Dictionary).get(kind, null)
		var error_count: int = errors.size()
		var parsed_value: float = _parse_saved_float(raw_value, "%s.%s" % [label, kind], saved_version, errors)
		if errors.size() != error_count:
			continue
		if parsed_value < 0.0 or parsed_value > _settings.need_max:
			errors.append("%s.%s must be finite and within [0, need_max]" % [label, kind])
		else:
			parsed[kind] = parsed_value
	return parsed


func _parse_rates(raw: Variant, saved_version: int, errors: PackedStringArray) -> Dictionary[String, float]:
	var parsed: Dictionary[String, float] = {}
	if typeof(raw) != TYPE_DICTIONARY or (raw as Dictionary).size() != NpcNeedKind.SIMULATED_KINDS.size():
		errors.append("%s must contain hunger, thirst and fatigue" % KEY_SEGMENT_RATES)
		return parsed
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		var raw_rate: Variant = (raw as Dictionary).get(kind, null)
		var error_count: int = errors.size()
		var parsed_rate: float = _parse_saved_float(raw_rate, "%s.%s" % [KEY_SEGMENT_RATES, kind], saved_version, errors)
		if errors.size() == error_count:
			parsed[kind] = parsed_rate
	return parsed


static func _encode_float64(value_to_encode: float) -> String:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(FLOAT64_BYTE_COUNT)
	bytes.encode_double(0, value_to_encode)
	return Marshalls.raw_to_base64(bytes)


## Schema 1 held JSON numbers. Schema 2 emits base64 strings, but also accepts
## finite numbers so tests and tools that construct an in-memory component
## document can still use the public restore seam without binary encoding.
func _parse_saved_float(raw: Variant, label: String, saved_version: int, errors: PackedStringArray) -> float:
	if _is_number(raw):
		return float(raw)
	if saved_version == LEGACY_SCHEMA_VERSION or typeof(raw) != TYPE_STRING:
		errors.append("%s must be a finite number" % label)
		return 0.0
	if RegEx.create_from_string(FLOAT64_BASE64_PATTERN).search(str(raw)) == null:
		errors.append("%s must be a saved float64" % label)
		return 0.0
	var bytes: PackedByteArray = Marshalls.base64_to_raw(str(raw))
	if bytes.size() != FLOAT64_BYTE_COUNT:
		errors.append("%s must be a saved float64" % label)
		return 0.0
	var decoded: float = bytes.decode_double(0)
	if not is_finite(decoded):
		errors.append("%s must be finite" % label)
		return 0.0
	return decoded


func _project_values(origin: Dictionary[String, float], rates: Dictionary[String, float], elapsed: float) -> Dictionary[String, float]:
	var projected: Dictionary[String, float] = {}
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		var rate: float = rates.get(kind, 0.0)
		projected[kind] = clampf(origin.get(kind, 0.0) + rate * elapsed, 0.0, _settings.need_max)
	return projected


func _rate(kind: String) -> float:
	return _rate_segment_rates.get(kind, 0.0)


func _start_rate_segment(world_time: float) -> void:
	_rate_segment_started_world_time = world_time
	_rate_segment_start_values = _values.duplicate()
	_last_updated_world_time = world_time
	_set_segment_rates()


func _set_segment_rates() -> void:
	_rate_segment_rates.clear()
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		_rate_segment_rates[kind] = _settings.rate_per_world_sec(kind, _activity) * _personality_modifier * _ability_modifier


func _calendar_now() -> float:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	return maxf(world.clock.world_time_sec, _last_updated_world_time) if world != null else _last_updated_world_time


func _mark_dirty() -> void:
	var world: ServerWorld = _world_ref.get_ref() as ServerWorld if _world_ref != null else null
	if world == null or _npc_id.is_empty():
		return
	var npcs: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
	if npcs != null:
		npcs.mark_npc_dirty(_npc_id)


func _is_forward_time(world_time: float) -> bool:
	return is_finite(world_time) and world_time >= _last_updated_world_time


func _is_valid_modifier(value_to_check: Variant) -> bool:
	return _is_number(value_to_check) and float(value_to_check) > 0.0 and float(value_to_check) <= MODIFIER_MAX


func _is_non_negative_number(value_to_check: Variant) -> bool:
	return _is_number(value_to_check) and float(value_to_check) >= 0.0


func _is_number(value_to_check: Variant) -> bool:
	return (typeof(value_to_check) == TYPE_FLOAT or typeof(value_to_check) == TYPE_INT) and is_finite(float(value_to_check))
