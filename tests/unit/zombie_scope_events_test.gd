extends TestCase
## P3-2 (docs/09 §15.2): the two wire-only zombie events that bring a zombie
## into and out of the cells a client is told about (ZombieNetProtocol) and
## what the client mirror does with them (ClientZombieState). No network.

const ID_A: String = "zombie_000001"
const ID_B: String = "zombie_000002"
const WORLD_TIME: float = 12.5

var _state: ClientZombieState = null
var _added: PackedStringArray = []
var _removed: PackedStringArray = []
var _received: Array[Dictionary] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_state = ClientZombieState.new(ZombieNetSettings.new())
	_added = PackedStringArray()
	_removed = PackedStringArray()
	_received = []
	_state.zombie_added.connect(func(zombie_id: String) -> void: _added.append(zombie_id))
	_state.zombie_removed.connect(func(zombie_id: String) -> void: _removed.append(zombie_id))
	_state.event_received.connect(func(event: Dictionary) -> void: _received.append(event))


func after_each() -> void:
	# The signal lambdas hold this test case: drop the mirror to break the cycle.
	_state = null
	GameLogger.set_capture(false)


## A row as ZombieService.snapshot_rows() gives it.
func _row(zombie_id: Variant, state: Variant = "chase", health: Variant = 0.75) -> Dictionary:
	return {"id": zombie_id, "position": Vector3(3.0, 0.0, 4.0), "yaw": 1.0, "state": state, "health_fraction": health}


func _entered(zombie_id: String, state: String = "chase", health: float = 0.75) -> Dictionary:
	return ZombieNetProtocol.entered_event(_row(zombie_id, state, health), WORLD_TIME)


# ------------------------------------------------------------ wire format

func test_an_entered_event_carries_what_a_snapshot_row_carries() -> void:
	var event: Dictionary = _entered(ID_A)
	assert_eq(event, {
		"event_type": "zombie_entered", "zombie_id": ID_A, "world_time": WORLD_TIME,
		"position": [3.0, 0.0, 4.0], "yaw": 1.0, "state": "chase", "health_fraction": 0.75,
	})
	assert_eq(ZombieNetProtocol.event_error(event), "", "the server only sends what a client accepts")
	assert_eq(ZombieNetProtocol.private_owner(event), "", "nothing in it is private")
	assert_true(is_same(ZombieNetProtocol.public_event(event), event))
	# Integers from the domain become floats on the wire.
	var whole: Dictionary = ZombieNetProtocol.entered_event({"id": ID_A, "position": Vector3(1, 0, 2), "yaw": 0, "state": "idle", "health_fraction": 1}, 3)
	assert_eq(typeof(whole["yaw"]), TYPE_FLOAT)
	assert_eq(typeof(whole["health_fraction"]), TYPE_FLOAT)
	assert_eq(typeof(whole["world_time"]), TYPE_FLOAT)
	assert_eq(ZombieNetProtocol.event_error(whole), "")


func test_a_row_that_does_not_fit_the_format_gives_no_entered_event() -> void:
	var bad_rows: Array[Dictionary] = [
		_row(""),
		_row(null),
		_row(ID_A, "sleeping"),
		_row(ID_A, 3),
		_row(ID_A, "idle", 1.5),
		_row(ID_A, "idle", -0.1),
		_row(ID_A, "idle", NAN),
		{"id": ID_A, "position": "here", "yaw": 0.0, "state": "idle", "health_fraction": 1.0},
		{"id": ID_A, "position": Vector3(INF, 0, 0), "yaw": 0.0, "state": "idle", "health_fraction": 1.0},
		{"id": ID_A, "position": Vector3.ZERO, "yaw": 100.0, "state": "idle", "health_fraction": 1.0},
		{"id": ID_A, "position": Vector3.ZERO, "yaw": 0.0, "state": "idle"},
		{},
	]
	for row: Dictionary in bad_rows:
		assert_eq(ZombieNetProtocol.entered_event(row, WORLD_TIME), {}, "refused: %s" % str(row))


func test_a_left_event_names_the_zombie_and_nothing_else() -> void:
	var event: Dictionary = ZombieNetProtocol.left_event(ID_A, WORLD_TIME)
	assert_eq(event, {"event_type": "zombie_left", "zombie_id": ID_A, "world_time": WORLD_TIME})
	assert_eq(ZombieNetProtocol.event_error(event), "")
	assert_eq(ZombieNetProtocol.left_event("", WORLD_TIME), {}, "no zombie, no event")


func test_a_client_refuses_malformed_scope_events() -> void:
	var good: Dictionary = _entered(ID_A)
	for key: String in ["position", "yaw", "state", "health_fraction", "zombie_id", "world_time"]:
		var missing: Dictionary = good.duplicate(true)
		missing.erase(key)
		assert_ne(ZombieNetProtocol.event_error(missing), "", "without %s" % key)
	var wrong: Dictionary = {"state": "flying", "health_fraction": 1.01, "yaw": 99.0, "position": [1.0, 2.0], "zombie_id": ""}
	for key: String in wrong:
		var bad: Dictionary = good.duplicate(true)
		bad[key] = wrong[key]
		assert_eq(ZombieNetProtocol.event_error(bad), ZombieNetProtocol.REASON_BAD_EVENT_FIELD, "bad %s" % key)
	var extra: Dictionary = good.duplicate(true)
	extra["health"] = 75.0
	assert_eq(ZombieNetProtocol.event_error(extra), ZombieNetProtocol.REASON_UNKNOWN_EVENT_FIELD, "an exact health value has no place in it")
	var left_extra: Dictionary = ZombieNetProtocol.left_event(ID_A, WORLD_TIME)
	left_extra["position"] = [0.0, 0.0, 0.0]
	assert_eq(ZombieNetProtocol.event_error(left_extra), ZombieNetProtocol.REASON_UNKNOWN_EVENT_FIELD)


# ------------------------------------------------------------ the mirror

func test_a_zombie_enters_the_mirror_as_what_it_is() -> void:
	assert_eq(_state.apply_join({"tick": 10, "event_sequence": 0, "rows": []}), "")
	assert_eq(_state.apply_events(11, 1, [_entered(ID_A, "dead", 0.0), _entered(ID_B, "chase", 0.4)]), "")
	assert_eq(_state.zombie_ids(), PackedStringArray([ID_A, ID_B]))
	assert_eq(_state.get_zombie(ID_A), {"position": Vector3(3.0, 0.0, 4.0), "yaw": 1.0, "state": "dead", "health_fraction": 0.0}, "a corpse arrives as a corpse, not as a standing zombie")
	assert_eq(_state.get_zombie(ID_B)["state"], "chase")
	assert_eq(_state.get_zombie(ID_B)["health_fraction"], 0.4)
	assert_eq(_added, PackedStringArray([ID_A, ID_B]))
	assert_eq(_received.size(), 2)
	assert_eq(_received[0]["sequence"], 1)
	assert_eq(_state.last_event_sequence, 2)
	assert_eq(_state.event_gap_count, 0)


func test_a_zombie_that_left_is_out_of_the_mirror_and_stays_out() -> void:
	assert_eq(_state.apply_join({"tick": 10, "event_sequence": 0, "rows": []}), "")
	assert_eq(_state.apply_events(11, 1, [_entered(ID_A)]), "")
	assert_eq(_state.apply_events(12, 2, [ZombieNetProtocol.left_event(ID_A, WORLD_TIME)]), "")
	assert_false(_state.has_zombie(ID_A))
	assert_eq(_removed, PackedStringArray([ID_A]))
	# A snapshot that was on its way when the zombie left cannot bring it back.
	assert_eq(_state.apply_snapshot(13, [[ID_A, Vector3(9, 0, 9), 0.0, 0, 1.0]]), "")
	assert_false(_state.has_zombie(ID_A), "snapshots never add a zombie")
	# Leaving twice, or leaving without ever having been there, changes nothing.
	assert_eq(_state.apply_events(14, 3, [ZombieNetProtocol.left_event(ID_A, WORLD_TIME), ZombieNetProtocol.left_event(ID_B, WORLD_TIME)]), "")
	assert_eq(_removed, PackedStringArray([ID_A]), "one removal signal")
	assert_eq(_state.rejected_payload_count, 0)
	# It can come back later, as it is then.
	assert_eq(_state.apply_events(20, 5, [_entered(ID_A, "idle", 0.5)]), "")
	assert_eq(_state.get_zombie(ID_A)["health_fraction"], 0.5)
	assert_eq(_added, PackedStringArray([ID_A, ID_A]))
	assert_eq(_state.event_gap_count, 0, "the numbers of this client's own stream have no hole")


func test_entering_twice_updates_the_zombie_without_a_second_copy() -> void:
	assert_eq(_state.apply_join({"tick": 10, "event_sequence": 0, "rows": [[ID_A, Vector3(1, 0, 1), 0.0, 0, 1.0]]}), "")
	assert_eq(_state.apply_events(11, 1, [_entered(ID_A, "search", 0.25)]), "")
	assert_eq(_state.zombie_count(), 1, "no duplicate")
	assert_eq(_added, PackedStringArray(), "it was there already: nothing was added")
	assert_eq(_state.get_zombie(ID_A)["state"], "search", "but it is up to date")
	assert_eq(_state.get_zombie(ID_A)["position"], Vector3(3.0, 0.0, 4.0))
	# The entry counts as an event: an older snapshot may move the zombie but
	# not change its state or health back.
	assert_eq(_state.apply_snapshot(10, [[ID_A, Vector3(2, 0, 2), 0.0, 0, 1.0]]), "")
	assert_eq(_state.get_zombie(ID_A)["state"], "search")
	assert_eq(_state.get_zombie(ID_A)["health_fraction"], 0.25)


func test_the_mirror_does_not_grow_beyond_its_limit_by_entered_events() -> void:
	var settings: ZombieNetSettings = ZombieNetSettings.new()
	settings.max_mirrored_zombies = 1
	_state = ClientZombieState.new(settings)
	assert_eq(_state.apply_join({"tick": 1, "event_sequence": 0, "rows": []}), "")
	assert_eq(_state.apply_events(2, 1, [_entered(ID_A), _entered(ID_B)]), "")
	assert_eq(_state.zombie_ids(), PackedStringArray([ID_A]))
	assert_eq(_state.rejected_payload_count, 1, "the second one was refused and counted")
	# The one that is there can still be brought up to date.
	assert_eq(_state.apply_events(3, 3, [_entered(ID_A, "idle", 0.1)]), "")
	assert_eq(_state.get_zombie(ID_A)["health_fraction"], 0.1)
