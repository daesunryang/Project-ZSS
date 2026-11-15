extends TestCase
## P2-N1a: ClientZombieState (client mirror) and ZombieNetProtocol (wire
## format) without a network: join fragment, snapshot ordering, event
## application, payload validation and the P2-9 information filter.

const ID_A: String = "zombie_000001"
const ID_B: String = "zombie_000002"
const PLAYER: String = "player_000001"
const JOIN_TICK: int = 10

var _settings: ZombieNetSettings = null
var _state: ClientZombieState = null
var _change_count: int = 0
var _added: PackedStringArray = []
var _removed: PackedStringArray = []
var _received: Array[Dictionary] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = ZombieNetSettings.new()
	_use(ClientZombieState.new(_settings))


func after_each() -> void:
	# The signal lambdas hold this test case: drop the mirror to break the cycle.
	_state = null
	GameLogger.set_capture(false)


func _use(state: ClientZombieState) -> void:
	_state = state
	_change_count = 0
	_added = PackedStringArray()
	_removed = PackedStringArray()
	_received = []
	state.changed.connect(func() -> void: _change_count += 1)
	state.zombie_added.connect(func(zombie_id: String) -> void: _added.append(zombie_id))
	state.zombie_removed.connect(func(zombie_id: String) -> void: _removed.append(zombie_id))
	state.event_received.connect(func(event: Dictionary) -> void: _received.append(event))


func _row(zombie_id: Variant, position: Variant = Vector3(1, 0, 2), yaw: Variant = 0.5, state: String = "idle", health: Variant = 1.0) -> Array:
	return [zombie_id, position, yaw, ZombieState.STATE_NAMES.find(state), health]


func _join(rows: Array = [], tick: int = JOIN_TICK, sequence: int = 0) -> String:
	return _state.apply_join({"tick": tick, "event_sequence": sequence, "rows": rows})


func _event(event_type: String, zombie_id: String, fields: Dictionary = {}) -> Dictionary:
	var event: Dictionary = {"event_type": event_type, "zombie_id": zombie_id, "world_time": 12.5}
	event.merge(fields)
	return event


func _spawned(zombie_id: String) -> Dictionary:
	return _event(ZombieService.EVENT_SPAWNED, zombie_id, {"position": [3.0, 0.0, 4.0], "yaw": 1.0})


func _state_changed(zombie_id: String, to: String) -> Dictionary:
	return _event(ZombieService.EVENT_STATE_CHANGED, zombie_id, {"from": "idle", "to": to, "cause": "sight", "target_id": PLAYER})


func _attacked(zombie_id: String) -> Dictionary:
	return _event(ZombieService.EVENT_ATTACKED, zombie_id, {
		"target_id": PLAYER, "wound_type": "bite", "body_part": "torso", "damage": 15.0,
		"target_health_after": 85.0, "target_died": false, "infection": "player_infected",
	})


func _mirror_text() -> String:
	return var_to_str(_state.zombies)


# ------------------------------------------------------------ settings

func test_default_settings_load_and_validate() -> void:
	assert_true(ResourceLoader.exists(ZombieNetSettings.DEFAULT_PATH))
	var loaded: ZombieNetSettings = ZombieNetSettings.load_or_default()
	assert_eq(loaded.validate().size(), 0, "; ".join(loaded.validate()))
	assert_true(loaded.snapshot_rows_per_message <= ZombieNetProtocol.MAX_ROWS_PER_MESSAGE)
	assert_true(loaded.events_per_message <= ZombieNetProtocol.MAX_EVENTS_PER_MESSAGE)
	var broken: ZombieNetSettings = ZombieNetSettings.new()
	broken.snapshot_rate_hz = 0.0
	broken.snapshot_rows_per_message = ZombieNetProtocol.MAX_ROWS_PER_MESSAGE + 1
	broken.events_per_message = 0
	broken.recent_event_capacity = 0
	broken.max_mirrored_zombies = 0
	assert_eq(broken.validate().size(), 5, "; ".join(broken.validate()))
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_not_null(config.zombie_net, "composition carries the zombie net settings")
	assert_eq(config.validate().size(), 0, "; ".join(config.validate()))


# ------------------------------------------------------------ join fragment

func test_join_fragment_replaces_the_mirror() -> void:
	assert_eq(_join([_row(ID_A, Vector3(1, 0, 2), 0.5, "chase", 0.75), _row(ID_B, Vector3(5, 0, 6), -1.0, "dead", 0.0)], 42, 7), "")
	assert_eq(_state.zombie_ids(), PackedStringArray([ID_A, ID_B]), "spawn order is kept")
	assert_eq(_state.zombie_count(), 2)
	assert_true(_state.has_zombie(ID_A))
	assert_eq(_state.get_zombie(ID_A), {"position": Vector3(1, 0, 2), "yaw": 0.5, "state": "chase", "health_fraction": 0.75})
	assert_eq(_state.get_zombie(ID_B)["state"], "dead")
	assert_eq(_state.get_zombie("zombie_999999"), {}, "unknown id -> empty")
	assert_eq(_state.last_snapshot_tick, 42)
	assert_eq(_state.last_event_sequence, 7)
	assert_eq(_change_count, 1)
	# A later join (reconnect) starts from scratch; {} means "no zombies".
	assert_eq(_state.apply_join({}), "")
	assert_eq(_state.zombie_count(), 0)
	assert_eq(_state.last_event_sequence, 0)
	assert_eq(_state.recent_events().size(), 0)


func test_bad_join_fragments_leave_an_empty_mirror() -> void:
	_settings.max_mirrored_zombies = 2
	var bad_fragments: Array[Dictionary] = [
		{"tick": "1", "event_sequence": 0, "rows": []},
		{"tick": 1, "event_sequence": -1, "rows": []},
		{"tick": -1, "event_sequence": 0, "rows": []},
		{"tick": 1, "event_sequence": 0, "rows": "none"},
		{"tick": 1, "event_sequence": 0},
		{"tick": 1, "event_sequence": 0, "rows": [_row(ID_A), _row(ID_A)]},
		{"tick": 1, "event_sequence": 0, "rows": [_row(ID_A), _row(ID_B), _row("zombie_000003")]},
		{"tick": 1, "event_sequence": 0, "rows": [_row(ID_A, Vector3(NAN, 0, 0))]},
	]
	for index: int in range(bad_fragments.size()):
		_use(ClientZombieState.new(_settings))
		assert_eq(_join([_row(ID_A)]), "")
		assert_ne(_state.apply_join(bad_fragments[index]), "", "fragment %d" % index)
		assert_eq(_state.zombie_count(), 0, "fragment %d leaves nothing behind" % index)
		assert_eq(_state.rejected_payload_count, 1, "fragment %d counted" % index)


# ------------------------------------------------------------ snapshots

func test_snapshots_update_known_zombies_and_drop_stale_ticks() -> void:
	assert_eq(_join([_row(ID_A)]), "")
	assert_eq(_state.apply_snapshot(JOIN_TICK + 5, [_row(ID_A, Vector3(2, 0, 3), 1.5, "chase", 0.5)]), "")
	assert_eq(_state.get_zombie(ID_A), {"position": Vector3(2, 0, 3), "yaw": 1.5, "state": "chase", "health_fraction": 0.5})
	assert_eq(_state.last_snapshot_tick, JOIN_TICK + 5)
	assert_eq(_change_count, 2)
	# Older tick: dropped, mirror untouched, not counted as malformed.
	assert_eq(_state.apply_snapshot(JOIN_TICK + 4, [_row(ID_A, Vector3(9, 0, 9), 0.0, "idle", 1.0)]), ClientZombieState.REASON_STALE)
	assert_eq(_state.get_zombie(ID_A)["position"], Vector3(2, 0, 3))
	assert_eq(_state.stale_snapshot_count, 1)
	assert_eq(_state.rejected_payload_count, 0)
	assert_eq(_change_count, 2)
	# Same tick = another message of the same snapshot (rows are chunked).
	assert_eq(_state.apply_snapshot(JOIN_TICK + 5, [_row(ID_A, Vector3(2, 0, 4), 1.5, "chase", 0.5)]), "")
	assert_eq(_state.get_zombie(ID_A)["position"], Vector3(2, 0, 4))
	# Identical data again: accepted, but nothing changed.
	var changes: int = _change_count
	assert_eq(_state.apply_snapshot(JOIN_TICK + 6, [_row(ID_A, Vector3(2, 0, 4), 1.5, "chase", 0.5)]), "")
	assert_eq(_change_count, changes, "no change signal for identical rows")


func test_snapshots_never_create_or_resurrect_zombies() -> void:
	assert_eq(_state.apply_snapshot(5, [_row(ID_A)]), ClientZombieState.REASON_NOT_JOINED, "before the join snapshot")
	assert_eq(_join([_row(ID_A)], JOIN_TICK, 0), "")
	assert_eq(_state.apply_snapshot(JOIN_TICK + 1, [_row(ID_A), _row(ID_B)]), "")
	assert_false(_state.has_zombie(ID_B), "membership only comes from the reliable channel")
	assert_eq(_state.apply_events(JOIN_TICK + 2, 1, [_event(ZombieService.EVENT_REMOVED, ID_A)]), "")
	assert_false(_state.has_zombie(ID_A))
	# A snapshot that was built before the removal arrives late.
	assert_eq(_state.apply_snapshot(JOIN_TICK + 3, [_row(ID_A)]), "")
	assert_false(_state.has_zombie(ID_A), "a removed zombie is not resurrected by a snapshot")
	assert_eq(_state.zombie_count(), 0)


func test_older_snapshot_cannot_roll_back_event_state() -> void:
	assert_eq(_join([_row(ID_A, Vector3.ZERO, 0.0, "idle", 1.0)]), "")
	# Reliable events of server tick 20 arrive before the snapshot of tick 15
	# (different ENet channels are not ordered against each other).
	assert_eq(_state.apply_events(20, 1, [_state_changed(ID_A, "chase")]), "")
	assert_eq(_state.apply_snapshot(15, [_row(ID_A, Vector3(1, 0, 1), 0.25, "idle", 1.0)]), "")
	var entry: Dictionary = _state.get_zombie(ID_A)
	assert_eq(entry["position"], Vector3(1, 0, 1), "position still follows the newest snapshot")
	assert_eq(entry["yaw"], 0.25)
	assert_eq(entry["state"], "chase", "state from a newer event is kept")
	assert_eq(_state.apply_events(21, 2, [_event(ZombieService.EVENT_DIED, ID_A, {"source_id": PLAYER})]), "")
	assert_eq(_state.apply_snapshot(19, [_row(ID_A, Vector3(1, 0, 1), 0.25, "chase", 0.4)]), "")
	assert_eq(_state.get_zombie(ID_A)["state"], "dead")
	assert_eq(_state.get_zombie(ID_A)["health_fraction"], 0.0)
	# A snapshot taken at or after the event tick is authoritative again.
	assert_eq(_state.apply_snapshot(21, [_row(ID_A, Vector3(1, 0, 1), 0.25, "dead", 0.0)]), "")
	assert_eq(_state.get_zombie(ID_A)["state"], "dead")


func test_malformed_snapshots_do_not_touch_the_mirror() -> void:
	assert_eq(_join([_row(ID_A)]), "")
	var before: String = _mirror_text()
	var too_many: Array = []
	for index: int in range(ZombieNetProtocol.MAX_ROWS_PER_MESSAGE + 1):
		too_many.append(_row(ID_A))
	var future: int = JOIN_TICK + 100
	var payloads: Array[Array] = [
		["11", [_row(ID_A)]],
		[11.0, [_row(ID_A)]],
		[-1, [_row(ID_A)]],
		[future, "rows"],
		[future, {"rows": []}],
		[future, too_many],
		[future, [_row(ID_A), "row"]],
		[future, [[ID_A, Vector3.ZERO, 0.0, 0]]],
		[future, [[ID_A, Vector3.ZERO, 0.0, 0, 1.0, "extra"]]],
		[future, [_row(42)]],
		[future, [_row("")]],
		[future, [_row("z".repeat(ZombieNetProtocol.MAX_ID_LENGTH + 1))]],
		[future, [_row(ID_A, [1.0, 0.0, 2.0])]],
		[future, [_row(ID_A, Vector3(NAN, 0, 0))]],
		[future, [_row(ID_A, Vector3(INF, 0, 0))]],
		[future, [_row(ID_A, Vector3.ZERO, NAN)]],
		[future, [_row(ID_A, Vector3.ZERO, 100.0)]],
		[future, [_row(ID_A, Vector3.ZERO, 1)]],
		[future, [[ID_A, Vector3.ZERO, 0.0, ZombieState.STATE_NAMES.size(), 1.0]]],
		[future, [[ID_A, Vector3.ZERO, 0.0, -1, 1.0]]],
		[future, [[ID_A, Vector3.ZERO, 0.0, "idle", 1.0]]],
		[future, [_row(ID_A, Vector3.ZERO, 0.0, "idle", 1.5)]],
		[future, [_row(ID_A, Vector3.ZERO, 0.0, "idle", -0.1)]],
		[future, [_row(ID_A, Vector3.ZERO, 0.0, "idle", NAN)]],
		# One bad row rejects the whole message, including its good rows.
		[future, [_row(ID_A, Vector3(7, 0, 7)), _row(ID_B, Vector3(NAN, 0, 0))]],
	]
	for index: int in range(payloads.size()):
		assert_ne(_state.apply_snapshot(payloads[index][0], payloads[index][1]), "", "payload %d is rejected" % index)
		assert_eq(_mirror_text(), before, "payload %d left the mirror alone" % index)
	assert_eq(_state.rejected_payload_count, payloads.size())
	assert_eq(_state.last_snapshot_tick, JOIN_TICK, "a rejected snapshot does not advance the tick")
	assert_eq(_change_count, 1)
	assert_eq(_state.apply_snapshot(JOIN_TICK + 1, [_row(ID_A, Vector3(7, 0, 7))]), "", "valid snapshots still apply afterwards")


# ------------------------------------------------------------ events

func test_events_drive_membership_state_and_signals() -> void:
	assert_eq(_join([], JOIN_TICK, 4), "")
	var batch: Array = [
		_spawned(ID_A),
		_event(ZombieService.EVENT_DETECTED, ID_A, {"sense": "sight", "target_id": PLAYER, "position": [0.0, 0.0, 0.0]}),
		_state_changed(ID_A, "chase"),
		_attacked(ID_A),
	]
	assert_eq(_state.apply_events(JOIN_TICK + 1, 5, batch), "")
	assert_eq(_added, PackedStringArray([ID_A]))
	assert_eq(_state.get_zombie(ID_A), {"position": Vector3(3, 0, 4), "yaw": 1.0, "state": "chase", "health_fraction": 1.0})
	assert_eq(_state.last_event_sequence, 8)
	assert_eq(_received.size(), 4, "every event is announced in order")
	for index: int in range(batch.size()):
		var expected: Dictionary = (batch[index] as Dictionary).duplicate(true)
		expected["sequence"] = 5 + index
		assert_eq(_received[index], expected, "event %d" % index)
	assert_false((batch[0] as Dictionary).has("sequence"), "the caller's payload is not modified")
	assert_eq(_change_count, 2, "one change signal per applied message")

	assert_eq(_state.apply_events(JOIN_TICK + 2, 9, [
		_event(ZombieService.EVENT_DAMAGED, ID_A, {"source_id": PLAYER, "damage": 100.0, "health_after": 0.0, "died": true}),
		_event(ZombieService.EVENT_DIED, ID_A, {"source_id": PLAYER}),
	]), "")
	assert_eq(_state.get_zombie(ID_A)["state"], "dead")
	assert_eq(_state.get_zombie(ID_A)["health_fraction"], 0.0)
	assert_eq(_state.apply_events(JOIN_TICK + 3, 11, [_event(ZombieService.EVENT_REMOVED, ID_A)]), "")
	assert_false(_state.has_zombie(ID_A))
	assert_eq(_removed, PackedStringArray([ID_A]))
	assert_eq(_state.last_event_sequence, 11)
	# Read surface for presentation polling.
	assert_eq(_state.recent_events().size(), 7)
	assert_eq(_state.recent_events()[6]["event_type"], ZombieService.EVENT_REMOVED)
	var newer: Array[Dictionary] = _state.events_after(9)
	assert_eq(newer.size(), 2)
	assert_eq(newer[0]["event_type"], ZombieService.EVENT_DIED)
	assert_eq(newer[0]["sequence"], 10)
	assert_eq(_state.events_after(11).size(), 0)


func test_events_for_unknown_zombies_are_announced_but_change_nothing() -> void:
	assert_eq(_join([_row(ID_A)]), "")
	var before: String = _mirror_text()
	assert_eq(_state.apply_events(JOIN_TICK + 1, 1, [_state_changed(ID_B, "chase"), _event(ZombieService.EVENT_REMOVED, ID_B)]), "")
	assert_eq(_mirror_text(), before)
	assert_eq(_received.size(), 2)
	assert_eq(_removed.size(), 0)
	assert_eq(_change_count, 1)


func test_duplicate_sequences_are_skipped_and_gaps_are_logged() -> void:
	assert_eq(_join([], JOIN_TICK, 3), "")
	# Sequences 2..4: 2 and 3 are already part of the join snapshot.
	assert_eq(_state.apply_events(JOIN_TICK + 1, 2, [_spawned(ID_A), _spawned(ID_B), _spawned("zombie_000003")]), "")
	assert_eq(_state.zombie_ids(), PackedStringArray(["zombie_000003"]), "only the event after the join snapshot applies")
	assert_eq(_received.size(), 1)
	assert_eq(_state.last_event_sequence, 4)
	assert_eq(_state.rejected_payload_count, 0, "duplicates are expected, not malformed")
	# A gap can only mean lost reliable data: applied, but reported.
	assert_eq(_state.apply_events(JOIN_TICK + 2, 9, [_spawned(ID_B)]), "")
	assert_true(_state.has_zombie(ID_B))
	assert_eq(_state.last_event_sequence, 9)
	assert_eq(_state.event_gap_count, 1)
	assert_contains("\n".join(GameLogger.captured_lines()), "zombie event sequence gap")


func test_malformed_event_messages_are_rejected() -> void:
	assert_eq(_join([_row(ID_A)], JOIN_TICK, 0), "")
	var before: String = _mirror_text()
	var too_many: Array = []
	for index: int in range(ZombieNetProtocol.MAX_EVENTS_PER_MESSAGE + 1):
		too_many.append(_event(ZombieService.EVENT_REMOVED, ID_A))
	var removal: Array = [_event(ZombieService.EVENT_REMOVED, ID_A)]
	var payloads: Array[Array] = [
		["1", 1, removal],
		[JOIN_TICK + 1, "1", removal],
		[JOIN_TICK + 1, 1.0, removal],
		[JOIN_TICK + 1, 0, removal],
		[JOIN_TICK + 1, -5, removal],
		[-1, 1, removal],
		[JOIN_TICK + 1, 1, "events"],
		[JOIN_TICK + 1, 1, {}],
		[JOIN_TICK + 1, 1, []],
		[JOIN_TICK + 1, 1, too_many],
	]
	for index: int in range(payloads.size()):
		assert_ne(_state.apply_events(payloads[index][0], payloads[index][1], payloads[index][2]), "", "payload %d is rejected" % index)
		assert_eq(_mirror_text(), before, "payload %d left the mirror alone" % index)
	assert_eq(_state.rejected_payload_count, payloads.size())
	assert_eq(_state.last_event_sequence, 0, "rejected messages do not consume sequence numbers")
	assert_eq(_received.size(), 0)
	_use(ClientZombieState.new(_settings))
	assert_eq(_state.apply_events(1, 1, [_spawned(ID_A)]), ClientZombieState.REASON_NOT_JOINED, "events before the join snapshot")
	assert_eq(_state.zombie_count(), 0)


func test_malformed_events_are_skipped_without_poisoning_the_mirror() -> void:
	assert_eq(_join([_row(ID_A)], JOIN_TICK, 0), "")
	var missing_field: Dictionary = _state_changed(ID_A, "chase")
	missing_field.erase("cause")
	var extra_field: Dictionary = _event(ZombieService.EVENT_REMOVED, ID_A, {"position": [0.0, 0.0, 0.0]})
	var bad_state: Dictionary = _state_changed(ID_A, "flying")
	var bad_point: Dictionary = _spawned(ID_B)
	bad_point["position"] = [NAN, 0.0, 0.0]
	var short_point: Dictionary = _spawned(ID_B)
	short_point["position"] = [1.0, 2.0]
	var vector_point: Dictionary = _spawned(ID_B)
	vector_point["position"] = Vector3(1, 2, 3)
	var bad_yaw: Dictionary = _spawned(ID_B)
	bad_yaw["yaw"] = 1000.0
	var bad_number: Dictionary = _attacked(ID_A)
	bad_number["damage"] = INF
	var bad_flag: Dictionary = _attacked(ID_A)
	bad_flag["target_died"] = 1
	var bad_private: Dictionary = _attacked(ID_A)
	bad_private["infection"] = 7
	var long_text: Dictionary = _state_changed(ID_A, "chase")
	long_text["cause"] = "c".repeat(ZombieNetProtocol.MAX_TEXT_LENGTH + 1)
	var bad_events: Array = [
		"not an event",
		{},
		_event("zombie_exploded", ID_A),
		_event(ZombieService.EVENT_REMOVED, ""),
		{"event_type": ZombieService.EVENT_REMOVED, "zombie_id": ID_A},
		{"event_type": ZombieService.EVENT_REMOVED, "zombie_id": ID_A, "world_time": "now"},
		{"event_type": ZombieService.EVENT_REMOVED, "zombie_id": 5, "world_time": 1.0},
		missing_field, extra_field, bad_state, bad_point, short_point, vector_point, bad_yaw,
		bad_number, bad_flag, bad_private, long_text,
	]
	var before: String = _mirror_text()
	assert_eq(_state.apply_events(JOIN_TICK + 1, 1, bad_events), "", "the message itself is well formed")
	assert_eq(_mirror_text(), before, "no bad event reached the mirror")
	assert_eq(_received.size(), 0)
	assert_eq(_state.rejected_payload_count, bad_events.size())
	assert_eq(_state.last_event_sequence, bad_events.size(), "their sequence numbers are consumed")
	assert_contains("\n".join(GameLogger.captured_lines()), "zombie event ignored")
	# Good events around a bad one still apply.
	var first: int = bad_events.size() + 1
	assert_eq(_state.apply_events(JOIN_TICK + 2, first, [_spawned(ID_B), bad_state, _state_changed(ID_B, "investigate")]), "")
	assert_eq(_state.get_zombie(ID_B)["state"], "investigate")
	assert_eq(_received.size(), 2)
	assert_eq(_received[1]["sequence"], first + 2)


func test_recent_events_and_mirror_size_are_bounded() -> void:
	_settings.recent_event_capacity = 3
	_settings.max_mirrored_zombies = 2
	_use(ClientZombieState.new(_settings))
	assert_eq(_join(), "")
	assert_eq(_state.apply_events(JOIN_TICK + 1, 1, [_spawned(ID_A), _spawned(ID_B), _spawned("zombie_000003"), _state_changed(ID_A, "chase")]), "")
	assert_eq(_state.zombie_ids(), PackedStringArray([ID_A, ID_B]), "the mirror never grows past its limit")
	assert_eq(_state.rejected_payload_count, 1)
	assert_eq(_state.recent_events().size(), 3, "only the newest events are kept")
	assert_eq(_state.recent_events()[0]["sequence"], 2)
	assert_eq(_state.recent_events()[2]["sequence"], 4)


# ------------------------------------------------------------ protocol

func test_rows_round_trip_through_the_wire_format() -> void:
	var source: Dictionary = {"id": ID_A, "position": Vector3(1.5, 0, -2.5), "yaw": -3.0, "state": "search", "health_fraction": 0.25}
	var row: Array = ZombieNetProtocol.encode_row(source)
	assert_eq(row, [ID_A, Vector3(1.5, 0, -2.5), -3.0, ZombieState.STATE_NAMES.find("search"), 0.25])
	assert_eq(ZombieNetProtocol.row_error(row), "")
	assert_eq(ZombieNetProtocol.decode_row(row), {"position": Vector3(1.5, 0, -2.5), "yaw": -3.0, "state": "search", "health_fraction": 0.25})
	var unknown_state: Dictionary = source.duplicate()
	unknown_state["state"] = "flying"
	assert_eq(ZombieNetProtocol.encode_row(unknown_state), [], "rows that do not fit the format are not sent")
	assert_eq(ZombieNetProtocol.encode_row({"id": ID_A}), [])


func test_events_are_whitelisted_and_private_fields_are_owner_only() -> void:
	var domain: Dictionary = _attacked(ID_A)
	domain["server_only_debug"] = "must not leak"
	var full: Dictionary = ZombieNetProtocol.encode_event(domain)
	assert_false(full.has("server_only_debug"), "fields outside the wire format are never sent")
	assert_eq(full["infection"], "player_infected")
	assert_eq(ZombieNetProtocol.event_error(full), "")
	assert_eq(ZombieNetProtocol.private_owner(full), PLAYER, "only the attacked player may see the private fields")
	var shared: Dictionary = ZombieNetProtocol.public_event(full)
	assert_false(shared.has("infection"), "infection result is private")
	assert_false(shared.has("target_health_after"), "exact health is a detailed vital (docs/15 P2-9)")
	assert_true(full.has("infection") and full.has("target_health_after"), "the full event is not modified")
	assert_eq(ZombieNetProtocol.event_error(shared), "", "the public form is valid on its own")
	for key: String in ["event_type", "zombie_id", "world_time", "target_id", "wound_type", "body_part", "damage", "target_died"]:
		assert_eq(shared[key], full[key], "observable fact " + key)
	# Events without private fields are shared as they are.
	var spawned: Dictionary = ZombieNetProtocol.encode_event(_spawned(ID_A))
	assert_true(is_same(ZombieNetProtocol.public_event(spawned), spawned))
	assert_eq(ZombieNetProtocol.private_owner(spawned), "")
	# Integers from the domain are sent as floats; broken events are dropped.
	var integer_damage: Dictionary = _attacked(ID_A)
	integer_damage["damage"] = 15
	assert_eq(typeof(ZombieNetProtocol.encode_event(integer_damage)["damage"]), TYPE_FLOAT)
	assert_eq(ZombieNetProtocol.encode_event(_event("zombie_exploded", ID_A)), {})
	var incomplete: Dictionary = _attacked(ID_A)
	incomplete.erase("target_id")
	assert_eq(ZombieNetProtocol.encode_event(incomplete), {})
	# Every event type the domain can emit has a wire format.
	for event_type: String in [ZombieService.EVENT_SPAWNED, ZombieService.EVENT_DETECTED, ZombieService.EVENT_STATE_CHANGED, ZombieService.EVENT_ATTACKED, ZombieService.EVENT_DAMAGED, ZombieService.EVENT_DIED, ZombieService.EVENT_REMOVED]:
		assert_true(ZombieNetProtocol.EVENT_FIELDS.has(event_type), event_type)


func test_snapshot_message_fits_the_size_budget() -> void:
	# Worst case row: longest accepted id, values that need 64-bit floats.
	var rows: Array = []
	for index: int in range(_settings.snapshot_rows_per_message):
		rows.append(["zombie_%06d" % (index + 1), Vector3(-249.123, 0.0, 249.987), -3.0123456789, 4, 0.123456789])
	var bytes: int = var_to_bytes(rows).size()
	assert_true(bytes <= ZombieNetProtocol.SNAPSHOT_MESSAGE_BUDGET_BYTES, "%d rows encode to %d bytes" % [rows.size(), bytes])
