class_name NpcDebugPresentation
extends RefCounted
## Client-only P4-8 panel and path line. Selection is the mirrored NPC name
## tag closest to the camera centre; the server remains authoritative over
## whether the requested private snapshot exists and may be sent.

const PANEL_TITLE: String = "NPC AI 디버그 [F4]"

var _root: Node3D
var _label: Label
var _camera: Camera3D
var _settings: ClientPresentationSettings
var _module: NpcDebugNetModule
var _state: NpcDebugClientState
var _line: MeshInstance3D
var _material: StandardMaterial3D = StandardMaterial3D.new()
var _open: bool = false
var _target_npc_id: String = ""


func _init(root: Node3D, label: Label, camera: Camera3D, settings: ClientPresentationSettings, module: NpcDebugNetModule) -> void:
	_root = root
	_label = label
	_camera = camera
	_settings = settings
	_module = module
	_state = module.client_state if module != null else null
	_material.albedo_color = settings.npc_debug_path_color
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line = MeshInstance3D.new()
	_line.name = "NpcDebugPath"
	_line.material_override = _material
	_root.add_child(_line)
	_label.visible = false
	if _state != null and not _state.changed.is_connected(_refresh):
		_state.changed.connect(_refresh)


func toggle() -> void:
	set_open(not _open)


func set_open(open: bool) -> void:
	if _open == open:
		return
	_open = open
	_label.visible = open
	if not open:
		_target_npc_id = ""
		_clear_path()
		if _module != null:
			_module.request_unsubscribe()
	else:
		_refresh()


func is_open() -> bool:
	return _open


func target_npc_id() -> String:
	return _target_npc_id


## Called from ClientView's physics tick after the camera was updated.
func tick(npcs: ClientNpcState) -> void:
	if not _open or _module == null or _state == null:
		return
	if not _state.server_enabled or not _state.allowed:
		_refresh()
		return
	var target: String = _pick_target(npcs)
	if target == _target_npc_id:
		return
	_target_npc_id = target
	if target.is_empty():
		_module.request_unsubscribe()
	else:
		_module.request_subscribe(target)
	_refresh()


func shutdown() -> void:
	if _module != null and not _target_npc_id.is_empty():
		_module.request_unsubscribe()
	_target_npc_id = ""
	_clear_path()


func _pick_target(npcs: ClientNpcState) -> String:
	if npcs == null or _camera == null or _camera.get_viewport() == null:
		return ""
	var center: Vector2 = _camera.get_viewport().get_visible_rect().size * 0.5
	var best_id: String = ""
	var best_screen_sq: float = _settings.npc_debug_target_radius_px * _settings.npc_debug_target_radius_px
	var best_distance_sq: float = INF
	var max_distance_sq: float = _settings.npc_debug_target_max_distance_m * _settings.npc_debug_target_max_distance_m
	for npc_id: String in npcs.npcs:
		var row: Dictionary = npcs.npcs[npc_id]
		var position_value: Variant = row.get(NpcNetProtocol.KEY_POSITION, null)
		if typeof(position_value) != TYPE_VECTOR3:
			continue
		var tag_position: Vector3 = (position_value as Vector3) + Vector3.UP * (_settings.npc_capsule_height_m + _settings.npc_name_tag_margin_m)
		var distance_sq: float = _camera.global_position.distance_squared_to(tag_position)
		if distance_sq > max_distance_sq or _camera.is_position_behind(tag_position):
			continue
		var screen_sq: float = _camera.unproject_position(tag_position).distance_squared_to(center)
		if screen_sq < best_screen_sq or (screen_sq == best_screen_sq and (distance_sq < best_distance_sq or (distance_sq == best_distance_sq and npc_id < best_id))):
			best_screen_sq = screen_sq
			best_distance_sq = distance_sq
			best_id = npc_id
	return best_id


func _refresh() -> void:
	if not _open or _state == null:
		return
	if not _state.server_enabled:
		_label.text = "%s\n서버에서 디버그가 꺼져 있음" % PANEL_TITLE
		_clear_path()
		return
	if not _state.allowed:
		_label.text = "%s\n이 접속자에게 디버그 권한이 없음" % PANEL_TITLE
		_clear_path()
		return
	if _target_npc_id.is_empty():
		_label.text = "%s\n화면 중앙의 NPC 이름표를 바라보세요." % PANEL_TITLE
		_clear_path()
		return
	var snapshot: Dictionary = _state.snapshot
	if snapshot.is_empty() or str(snapshot.get("npc_id", "")) != _target_npc_id:
		_label.text = "%s\n%s 구독 중…" % [PANEL_TITLE, _target_npc_id]
		_clear_path()
		return
	if not bool(snapshot.get("found", false)):
		_label.text = "%s\nNPC 없음 (관심 범위 밖 또는 메모리 밖)\n%s" % [PANEL_TITLE, _target_npc_id]
		_clear_path()
		return
	_label.text = _panel_text(snapshot)
	_draw_path(snapshot)


func _panel_text(snapshot: Dictionary) -> String:
	var lines: PackedStringArray = [
		PANEL_TITLE,
		"%s (%s)" % [str(snapshot.get("name", "")), str(snapshot.get("npc_id", ""))],
		"상태 %s | 행동 %s | 목표 %s | LOD %s" % [str(snapshot.get("state", "")), str(snapshot.get("current_action", "")), str(snapshot.get("goal", "")), str(snapshot.get("lod", ""))],
	]
	var failure: Dictionary = snapshot.get("failure", {})
	lines.append("실패/취소: %s" % (str(failure.get("code", failure.get("result", "없음"))) if not failure.is_empty() else "없음"))
	lines.append("상위 후보       점수    항별 점수")
	var candidates: Array = snapshot.get("candidates", [])
	if candidates.is_empty():
		lines.append("  없음")
	else:
		for candidate_value: Variant in candidates:
			if typeof(candidate_value) != TYPE_DICTIONARY:
				continue
			var candidate: Dictionary = candidate_value
			var term_parts: PackedStringArray = []
			var terms: Dictionary = candidate.get("terms", {})
			var term_ids: PackedStringArray = PackedStringArray(terms.keys())
			term_ids.sort()
			for term_id: String in term_ids:
				term_parts.append("%s %.2f" % [term_id, float(terms[term_id])])
			lines.append("  %-12s %5.2f  %s" % [str(candidate.get("action_id", "")), float(candidate.get("score", 0.0)), ", ".join(term_parts)])
	lines.append("욕구")
	var needs: Dictionary = snapshot.get("needs", {})
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		var need: Dictionary = needs.get(kind, {})
		var value: float = clampf(float(need.get("value", 0.0)), 0.0, 100.0)
		var filled: int = clampi(int(round(value / 10.0)), 0, 10)
		lines.append("  %-8s [%s%s] %5.1f %s" % [kind, "■".repeat(filled), "·".repeat(10 - filled), value, str(need.get("category", ""))])
	var path: Array = snapshot.get("path", [])
	lines.append("경로 %d waypoint | 다음 결정 %.2fs" % [path.size(), float((snapshot.get("schedule", {}) as Dictionary).get("next_decision_in_sec", -1.0))])
	return "\n".join(lines)


func _draw_path(snapshot: Dictionary) -> void:
	var points: PackedVector3Array = []
	var start: Variant = _as_vector3(snapshot.get("position", null))
	if start == null:
		_clear_path()
		return
	points.append((start as Vector3) + Vector3.UP * _settings.npc_debug_path_height_m)
	for row: Variant in snapshot.get("path", []):
		var point: Variant = _as_vector3(row)
		if point != null:
			points.append((point as Vector3) + Vector3.UP * _settings.npc_debug_path_height_m)
	if points.size() < 2:
		_clear_path()
		return
	var segments: PackedVector3Array = []
	for index: int in range(points.size() - 1):
		segments.append(points[index])
		segments.append(points[index + 1])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = segments
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_line.mesh = mesh


func _clear_path() -> void:
	if _line != null:
		_line.mesh = null


static func _as_vector3(value: Variant) -> Variant:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 3:
		return null
	for coordinate: Variant in value as Array:
		if (typeof(coordinate) != TYPE_FLOAT and typeof(coordinate) != TYPE_INT) or not is_finite(float(coordinate)):
			return null
	return Vector3(float(value[0]), float(value[1]), float(value[2]))
