extends TestCase
## P4-7: pure NPC wire format and client mirror. No nodes or ENet.

const NPC_A: String = "npc_000001"
const NPC_B: String = "npc_000002"
const JOIN_TICK: int = 10
const PRIVATE_SENTINEL: String = "must_never_cross_the_npc_wire"

var _settings: NpcNetSettings = null
var _state: ClientNpcState = null
var _added: PackedStringArray = []
var _removed: PackedStringArray = []
var _events: Array[Dictionary] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = NpcNetSettings.new()
	_state = ClientNpcState.new(_settings)
	_added = PackedStringArray()
	_removed = PackedStringArray()
	_events = []
	_state.npc_added.connect(func(npc_id: String) -> void: _added.append(npc_id))
	_state.npc_removed.connect(func(npc_id: String) -> void: _removed.append(npc_id))
	_state.event_received.connect(func(event: Dictionary) -> void: _events.append(event))


func after_each() -> void:
	_state = null
	GameLogger.set_capture(false)


func _source(npc_id: String = NPC_A, position: Vector3 = Vector3(3.0, 0.0, 4.0), action_label: String = "idle") -> Dictionary:
	return {
		NpcNetProtocol.KEY_NPC_ID: npc_id,
		NpcNetProtocol.KEY_NAME: "한서윤",
		NpcNetProtocol.KEY_APPEARANCE: {"body_scale": "average", "hair_style": "short", "hair_color": "blue"},
		NpcNetProtocol.KEY_POSITION: position,
		NpcNetProtocol.KEY_YAW: 1.0,
		NpcNetProtocol.KEY_ACTION_LABEL: action_label,
		NpcNetProtocol.KEY_POSTURE: "standing",
		# These deliberately resemble future private NPC state. Encoding must
		# be a whitelist, so neither their keys nor values can leave.
		"hunger": 0.91,
		"emotions": {"fear": 0.8},
		"memory": PRIVATE_SENTINEL,
		"relationships": {"player_000001": -0.5},
		"personality": {"courage": 0.2},
		"skills": {"medical": 0.7},
		"goal": "private_goal",
		"rng_state": "private_rng",
		"components": {"secret": PRIVATE_SENTINEL},
	}


func _row(npc_id: String = NPC_A, position: Vector3 = Vector3(3.0, 0.0, 4.0), action_label: String = "idle") -> Array:
	return NpcNetProtocol.encode_public_row(_source(npc_id, position, action_label))


func _join(rows: Array = [_row()]) -> String:
	return _state.apply_join({
		NpcNetProtocol.KEY_TICK: JOIN_TICK,
		NpcNetProtocol.KEY_EVENT_SEQUENCE: 0,
		NpcNetProtocol.KEY_ROWS: rows,
	})


func test_defaults_are_five_hz_and_composition_carries_the_settings() -> void:
	assert_eq(_settings.snapshot_rate_hz, 5.0)
	assert_eq(_settings.validate(), PackedStringArray())
	assert_true(ResourceLoader.exists(NpcNetSettings.DEFAULT_PATH))
	var loaded: NpcNetSettings = NpcNetSettings.load_or_default()
	assert_eq(loaded.validate(), PackedStringArray())
	var config: CompositionConfig = CompositionConfig.from_defaults()
	assert_not_null(config.npc_net)
	assert_eq(config.npc_net.validate(), PackedStringArray())


func test_public_rows_are_an_exact_whitelist_and_round_trip() -> void:
	var source: Dictionary = _source(NPC_A, Vector3(1.5, 0.0, -2.5), "walk")
	var row: Array = NpcNetProtocol.encode_public_row(source)
	assert_eq(NpcNetProtocol.public_row_error(row), "")
	assert_eq(NpcNetProtocol.decode_public_row(row), {
		NpcNetProtocol.KEY_NPC_ID: NPC_A,
		NpcNetProtocol.KEY_NAME: "한서윤",
		NpcNetProtocol.KEY_APPEARANCE: source[NpcNetProtocol.KEY_APPEARANCE],
		NpcNetProtocol.KEY_POSITION: Vector3(1.5, 0.0, -2.5),
		NpcNetProtocol.KEY_YAW: 1.0,
		NpcNetProtocol.KEY_ACTION_LABEL: "walk",
		NpcNetProtocol.KEY_POSTURE: "standing",
	})
	var wire_text: String = var_to_str(row)
	for forbidden: String in ["hunger", "emotions", "memory", "relationships", "personality", "skills", "goal", "rng_state", "components", PRIVATE_SENTINEL, "private_goal", "private_rng"]:
		assert_not_contains(wire_text, forbidden, "private NPC data is absent: " + forbidden)
	assert_eq(NpcNetProtocol.ACTION_LABELS, PackedStringArray(["idle", "walk", "eat", "sleep", "work", "flee"]))
	assert_eq(NpcNetProtocol.POSTURES, PlayerPosture.NAMES)


func test_position_snapshots_carry_only_id_position_and_yaw() -> void:
	var snapshot: Array = NpcNetProtocol.encode_snapshot_row(_source(NPC_A, Vector3(8.0, 0.0, 9.0)))
	assert_eq(snapshot, [NPC_A, Vector3(8.0, 0.0, 9.0), 1.0])
	assert_eq(NpcNetProtocol.snapshot_row_error(snapshot), "")
	assert_eq(NpcNetProtocol.decode_snapshot_row(snapshot), {
		NpcNetProtocol.KEY_NPC_ID: NPC_A,
		NpcNetProtocol.KEY_POSITION: Vector3(8.0, 0.0, 9.0),
		NpcNetProtocol.KEY_YAW: 1.0,
	})
	assert_not_contains(var_to_str(snapshot), "한서윤", "static identity is not repeated at 5 Hz")


func test_scope_and_action_events_have_exact_public_fields() -> void:
	var entered: Dictionary = NpcNetProtocol.entered_event(_row(), 12.5)
	assert_eq(NpcNetProtocol.event_error(entered), "")
	assert_eq(entered.keys().size(), 4)
	assert_eq(entered[NpcNetProtocol.KEY_EVENT_TYPE], NpcNetProtocol.EVENT_ENTERED)
	assert_eq(entered[NpcNetProtocol.KEY_NPC_ID], NPC_A)
	assert_eq(entered[NpcNetProtocol.KEY_ROW], _row())
	var action: Dictionary = NpcNetProtocol.action_changed_event(NPC_A, "flee", 13.0)
	assert_eq(action, {
		NpcNetProtocol.KEY_EVENT_TYPE: NpcNetProtocol.EVENT_ACTION_CHANGED,
		NpcNetProtocol.KEY_NPC_ID: NPC_A,
		NpcNetProtocol.KEY_WORLD_TIME: 13.0,
		NpcNetProtocol.KEY_ACTION_LABEL: "flee",
	})
	assert_eq(NpcNetProtocol.event_error(action), "")
	var left: Dictionary = NpcNetProtocol.left_event(NPC_A, 14.0)
	assert_eq(left, {
		NpcNetProtocol.KEY_EVENT_TYPE: NpcNetProtocol.EVENT_LEFT,
		NpcNetProtocol.KEY_NPC_ID: NPC_A,
		NpcNetProtocol.KEY_WORLD_TIME: 14.0,
	})
	assert_eq(NpcNetProtocol.event_error(left), "")
	var extra: Dictionary = entered.duplicate(true)
	extra["needs"] = PRIVATE_SENTINEL
	assert_eq(NpcNetProtocol.event_error(extra), NpcNetProtocol.REASON_UNKNOWN_EVENT_FIELD)


func test_join_snapshot_and_reliable_events_own_membership() -> void:
	assert_eq(_join(), "")
	assert_eq(_state.npc_ids(), PackedStringArray([NPC_A]))
	assert_eq(_state.get_npc(NPC_A)[NpcNetProtocol.KEY_NAME], "한서윤")
	assert_eq(_state.get_npc(NPC_A)[NpcNetProtocol.KEY_ACTION_LABEL], "idle")
	# Unreliable snapshots update a known NPC, but never invent a member.
	assert_eq(_state.apply_snapshot(11, [NpcNetProtocol.encode_snapshot_row(_source(NPC_A, Vector3(6.0, 0.0, 6.0))), NpcNetProtocol.encode_snapshot_row(_source(NPC_B))]), "")
	assert_eq(_state.get_npc(NPC_A)[NpcNetProtocol.KEY_POSITION], Vector3(6.0, 0.0, 6.0))
	assert_false(_state.has_npc(NPC_B))
	assert_eq(_state.apply_events(12, 1, [NpcNetProtocol.entered_event(_row(NPC_B, Vector3(7.0, 0.0, 7.0)), 1.0)]), "")
	assert_true(_state.has_npc(NPC_B))
	assert_eq(_added, PackedStringArray([NPC_B]))
	assert_eq(_state.apply_events(13, 2, [NpcNetProtocol.left_event(NPC_A, 2.0)]), "")
	assert_false(_state.has_npc(NPC_A))
	assert_eq(_removed, PackedStringArray([NPC_A]))
	assert_eq(_events.size(), 2)


func test_action_event_updates_the_observable_label_and_bad_payloads_do_not() -> void:
	assert_eq(_join(), "")
	assert_eq(_state.apply_events(11, 1, [NpcNetProtocol.action_changed_event(NPC_A, "work", 1.0)]), "")
	assert_eq(_state.get_npc(NPC_A)[NpcNetProtocol.KEY_ACTION_LABEL], "work")
	var bad: Dictionary = NpcNetProtocol.action_changed_event(NPC_A, "walk", 2.0)
	bad[NpcNetProtocol.KEY_ACTION_LABEL] = "think_about_secret_goal"
	assert_eq(_state.apply_events(12, 2, [bad]), "")
	assert_eq(_state.get_npc(NPC_A)[NpcNetProtocol.KEY_ACTION_LABEL], "work")
	assert_eq(_state.rejected_payload_count, 1)
	assert_eq(_state.last_event_sequence, 2, "a malformed event still consumes its reliable sequence")


func test_malformed_rows_are_rejected_without_mutating_the_mirror() -> void:
	assert_eq(_join(), "")
	var before: Dictionary = _state.get_npc(NPC_A).duplicate(true)
	var bad_rows: Array = [
		[],
		[NPC_A, "name", {}, Vector3.ZERO, 0.0, 99, 0],
		[NPC_A, "name", {"slot": PRIVATE_SENTINEL}, Vector3.ZERO, 0.0, 0, 0],
		[NPC_A, "name", {}, Vector3(INF, 0.0, 0.0), 0.0, 0, 0],
	]
	for bad: Array in bad_rows:
		assert_ne(_state.apply_join({NpcNetProtocol.KEY_TICK: 1, NpcNetProtocol.KEY_EVENT_SEQUENCE: 0, NpcNetProtocol.KEY_ROWS: [bad]}), "")
	assert_eq(_state.npc_count(), 0, "an invalid join is cleared rather than partly applied")
	assert_ne(before, {}, "the setup row was valid before the malformed joins")


func test_npc_presentation_batches_bodies_and_keeps_korean_name_tags() -> void:
	assert_eq(_join([_row(NPC_A), _row(NPC_B, Vector3(8.0, 0.0, 9.0))]), "")
	var root: Node3D = Node3D.new()
	var presentation: ClientPresentationSettings = ClientPresentationSettings.new()
	var visuals: NpcVisuals = NpcVisuals.new(root, presentation)
	visuals.sync(_state.npcs)
	assert_eq(visuals.visual_count(), 2)
	assert_eq(visuals.body_instance_count(), 2, "NPC bodies share one MultiMesh")
	assert_eq(visuals.label_count(), 2)
	assert_eq(visuals.label_of(NPC_A).text, "한서윤")
	assert_eq(visuals.transform_of(NPC_B).origin.x, 8.0)
	assert_ne(visuals.body_color(), presentation.zombie_idle_color, "NPC and zombie colours are distinct")
	root.free()
