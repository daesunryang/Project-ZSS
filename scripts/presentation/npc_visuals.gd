class_name NpcVisuals
extends RefCounted
## Client-only NPC placeholders (P4-7): one MultiMesh capsule batch for all
## bodies and one billboard Label3D per Korean/display name. The client
## mirror is the only input; this class has no gameplay or network authority.

const BATCH_NODE: String = "NpcBodies"
const LABEL_PREFIX: String = "Npc_"
const LABEL_NODE: String = "NameTag"

var _root: Node3D
var _settings: ClientPresentationSettings
var _batch: MultiMeshInstance3D
var _mesh: CapsuleMesh = CapsuleMesh.new()
var _material: StandardMaterial3D = StandardMaterial3D.new()
var _entries: Dictionary[String, Dictionary] = {}
var _transforms: Dictionary[String, Transform3D] = {}
var _labels: Dictionary[String, Node3D] = {}


func _init(root: Node3D, settings: ClientPresentationSettings) -> void:
	_root = root
	_settings = settings
	_mesh.radius = settings.npc_capsule_radius_m
	_mesh.height = settings.npc_capsule_height_m
	_material.albedo_color = settings.npc_capsule_color
	_batch = MultiMeshInstance3D.new()
	_batch.name = BATCH_NODE
	_batch.material_override = _material
	_root.add_child(_batch)


## Rebuilds the compact body batch and synchronizes name labels from
## ClientNpcState.npcs. Invalid entries are ignored defensively.
func sync(npcs: Dictionary) -> void:
	if not is_instance_valid(_root):
		return
	_entries.clear()
	_transforms.clear()
	var ids: PackedStringArray = []
	for npc_id: Variant in npcs:
		if typeof(npc_id) == TYPE_STRING and _is_drawable(npcs[npc_id]):
			_entries[npc_id] = (npcs[npc_id] as Dictionary).duplicate(true)
			ids.append(npc_id)
	ids.sort()
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _mesh
	multimesh.instance_count = ids.size()
	for index: int in range(ids.size()):
		var npc_id: String = ids[index]
		var entry: Dictionary = _entries[npc_id]
		var posture: String = str(entry[NpcNetProtocol.KEY_POSTURE])
		# F-25: a dead NPC is its body, lying where it fell.
		var condition: String = str(entry.get(NpcNetProtocol.KEY_CONDITION, NpcNetProtocol.CONDITION_OK))
		var lying: bool = posture != NpcNetProtocol.POSTURE_STANDING or condition == NpcNetProtocol.CONDITION_DEAD
		var center_height: float = _settings.npc_capsule_radius_m if lying else _settings.npc_capsule_height_m * 0.5
		var tilt: float = _settings.npc_lying_tilt_rad if lying else 0.0
		var basis := Basis.from_euler(Vector3(tilt, float(entry[NpcNetProtocol.KEY_YAW]), 0.0))
		var position: Vector3 = entry[NpcNetProtocol.KEY_POSITION]
		var transform := Transform3D(basis, position + Vector3.UP * center_height)
		multimesh.set_instance_transform(index, transform)
		_transforms[npc_id] = transform
	_batch.multimesh = multimesh
	_sync_labels()


func visual_count() -> int:
	return _entries.size()


func body_instance_count() -> int:
	return _batch.multimesh.instance_count if _batch.multimesh != null else 0


func label_count() -> int:
	return _labels.size()


func has_visual(npc_id: String) -> bool:
	return _entries.has(npc_id)


func transform_of(npc_id: String) -> Transform3D:
	return _transforms.get(npc_id, Transform3D())


func label_of(npc_id: String) -> Label3D:
	var anchor: Node3D = _labels.get(npc_id, null)
	return anchor.get_node(LABEL_NODE) as Label3D if anchor != null else null


func body_color() -> Color:
	return _material.albedo_color


func _sync_labels() -> void:
	for npc_id: String in _labels.keys():
		if _entries.has(npc_id):
			continue
		_labels[npc_id].free()
		_labels.erase(npc_id)
	for npc_id: String in _entries:
		var entry: Dictionary = _entries[npc_id]
		var anchor: Node3D = _labels.get(npc_id, null)
		if anchor == null:
			anchor = _make_label(npc_id)
			_root.add_child(anchor)
			_labels[npc_id] = anchor
		anchor.position = entry[NpcNetProtocol.KEY_POSITION]
		(anchor.get_node(LABEL_NODE) as Label3D).text = tag_text(str(entry[NpcNetProtocol.KEY_NAME]), str(entry.get(NpcNetProtocol.KEY_CONDITION, NpcNetProtocol.CONDITION_OK)), _settings)


## The name tag of an NPC: its name, and what can be seen of its body
## (F-25: hurt or dead) after it.
static func tag_text(display_name: String, condition: String, settings: ClientPresentationSettings) -> String:
	match condition:
		NpcVitals.CONDITION_HURT:
			return display_name + settings.npc_hurt_tag_suffix
		NpcVitals.CONDITION_DEAD:
			return display_name + settings.npc_dead_tag_suffix
	return display_name


func _is_drawable(value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		return false
	var entry: Dictionary = value
	var position: Variant = entry.get(NpcNetProtocol.KEY_POSITION, null)
	var yaw: Variant = entry.get(NpcNetProtocol.KEY_YAW, null)
	var display_name: Variant = entry.get(NpcNetProtocol.KEY_NAME, null)
	var posture: Variant = entry.get(NpcNetProtocol.KEY_POSTURE, null)
	return (
		typeof(position) == TYPE_VECTOR3
		and (position as Vector3).is_finite()
		and typeof(yaw) == TYPE_FLOAT
		and is_finite(float(yaw))
		and typeof(display_name) == TYPE_STRING
		and not (display_name as String).is_empty()
		and typeof(posture) == TYPE_STRING
		and NpcNetProtocol.POSTURES.has(str(posture))
	)


func _make_label(npc_id: String) -> Node3D:
	var anchor: Node3D = Node3D.new()
	anchor.name = LABEL_PREFIX + npc_id
	var label: Label3D = Label3D.new()
	label.name = LABEL_NODE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = _settings.npc_name_tag_pixel_size
	label.font_size = _settings.npc_name_tag_font_size
	label.modulate = _settings.npc_name_tag_color
	label.position = Vector3.UP * (_settings.npc_capsule_height_m + _settings.npc_name_tag_margin_m)
	anchor.add_child(label)
	return anchor
