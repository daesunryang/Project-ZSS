extends TestCase
## PERF-2 CPU measurement. The legacy function reproduces the former
## per-entity mesh/label allocation; the batched function uses the shipped
## presentation classes and equivalent MultiMesh updates. GPU time is not
## available with the headless display driver.

const ITEMS: int = 300
const ZOMBIES: int = 100
const STRUCTURES: int = 370
const SAMPLES: int = 7

func _legacy_update(root: Node3D, settings: ClientPresentationSettings, items: ItemCatalog, rows: Dictionary) -> void:
	var item_mesh: BoxMesh = BoxMesh.new()
	item_mesh.size = Vector3.ONE * settings.world_item_marker_size_m
	var item_material: StandardMaterial3D = StandardMaterial3D.new()
	item_material.albedo_color = settings.world_item_marker_color
	for index: int in range(ITEMS):
		var marker: Node3D = Node3D.new()
		var body: MeshInstance3D = MeshInstance3D.new()
		body.mesh = item_mesh
		body.material_override = item_material
		body.position = Vector3.UP * settings.world_item_marker_size_m * 0.5
		marker.add_child(body)
		var label: Label3D = Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.pixel_size = settings.world_item_label_pixel_size
		label.font_size = settings.world_item_label_font_size
		label.modulate = settings.world_item_label_color
		label.position = Vector3.UP * (settings.world_item_marker_size_m + settings.world_item_label_margin_m)
		label.text = ClientPresentationFormatter.world_item_label(rows["item_%06d" % index], items)
		marker.add_child(label)
		marker.position = rows["item_%06d" % index][ClientWorldState.KEY_POSITION]
		root.add_child(marker)
	var zombie_mesh: CapsuleMesh = CapsuleMesh.new()
	zombie_mesh.radius = settings.zombie_capsule_radius_m
	zombie_mesh.height = settings.zombie_capsule_height_m
	var zombie_material: StandardMaterial3D = StandardMaterial3D.new()
	for index: int in range(ZOMBIES):
		var zombie: MeshInstance3D = MeshInstance3D.new()
		zombie.mesh = zombie_mesh
		zombie.material_override = zombie_material
		zombie.position = Vector3(float(index), settings.zombie_capsule_height_m * 0.5, 0.0)
		root.add_child(zombie)
	for index: int in range(STRUCTURES):
		var structure: Node3D = Node3D.new()
		var structure_body: MeshInstance3D = MeshInstance3D.new()
		var structure_mesh: BoxMesh = BoxMesh.new()
		structure_mesh.size = Vector3(1.0, settings.structure_floor_height_m, 1.0)
		structure_body.mesh = structure_mesh
		var structure_material: StandardMaterial3D = StandardMaterial3D.new()
		structure_material.albedo_color = settings.structure_completed_color
		structure_body.material_override = structure_material
		structure_body.position.y = settings.structure_floor_height_m * 0.5
		structure.add_child(structure_body)
		structure.position = Vector3(float(index % 20), 0.0, float(index / 20))
		root.add_child(structure)


func _item_rows() -> Dictionary:
	var rows: Dictionary[String, Dictionary] = {}
	for index: int in range(ITEMS):
		rows["item_%06d" % index] = {
			ClientWorldState.KEY_DEFINITION_ID: "dev_test_item",
			ClientWorldState.KEY_QUANTITY: 1,
			ClientWorldState.KEY_POSITION: Vector3(float(index % 30) * 2.0, 0.0, float(index / 30) * 2.0),
		}
	return rows


func _zombie_batches(root: Node3D) -> void:
	var mesh: CapsuleMesh = CapsuleMesh.new()
	for state_index: int in range(ZombieState.STATE_NAMES.size()):
		var count: int = ZOMBIES / ZombieState.STATE_NAMES.size() + (1 if state_index < ZOMBIES % ZombieState.STATE_NAMES.size() else 0)
		var multimesh: MultiMesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = count
		for index: int in range(count):
			multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY, Vector3(float(index), 1.0, float(state_index))))
		var batch: MultiMeshInstance3D = MultiMeshInstance3D.new()
		batch.multimesh = multimesh
		root.add_child(batch)


func _structure_fragment() -> Dictionary:
	var rows: Array = []
	for index: int in range(STRUCTURES):
		rows.append(["structure_%06d" % index, BuildPresentation.FLOOR_ID, index % 20, index / 20, 0, "completed", false, 1.0, 1.0, {"dev_wood": 4}, {"dev_wood": 4}])
	return {ClientStructureState.KEY_SCHEMA_VERSION: ClientStructureState.SCHEMA_VERSION, ClientStructureState.KEY_STRUCTURES: rows, ClientStructureState.KEY_WORKERS: []}


func _batched_update(root: Node3D, settings: ClientPresentationSettings, items: ItemCatalog, rows: Dictionary, mirror: ClientStructureState, catalog: StructureCatalog) -> Dictionary:
	var markers: WorldItemMarkers = WorldItemMarkers.new(root, items, settings)
	markers.sync(rows, Vector3.ZERO)
	_zombie_batches(root)
	var visuals: StructureVisuals = StructureVisuals.new(root, mirror, catalog, items, StructureGrid.new(1.0), settings)
	return {"item_instances": markers.body_instance_count(), "labels": markers.label_count(), "structure_instances": visuals.batch_instance_count()}


func _median(values: Array[int]) -> int:
	values.sort()
	return values[values.size() / 2]


func test_measure_legacy_nodes_and_batched_updates_headless() -> void:
	# Static catalogs and mirror decoding are shared costs, not drawing update
	# work, so prepare them outside both timed regions.
	var settings: ClientPresentationSettings = ClientPresentationSettings.new()
	var items: ItemCatalog = ItemCatalog.load_directory()
	var rows: Dictionary = _item_rows()
	var catalog: StructureCatalog = StructureCatalog.load_directory()
	var mirror: ClientStructureState = ClientStructureState.new(StructureNetSettings.new(), catalog)
	assert_true(mirror.apply_join(_structure_fragment()))
	var legacy_samples: Array[int] = []
	var batched_samples: Array[int] = []
	var legacy_children: int = 0
	var batched_children: int = 0
	var result: Dictionary = {}
	# Alternate both paths so transient machine load is less likely to favor
	# one implementation. Median removes a single scheduler interruption.
	for sample: int in range(SAMPLES):
		var legacy_root: Node3D = Node3D.new()
		tree.root.add_child(legacy_root)
		var started: int = Time.get_ticks_usec()
		_legacy_update(legacy_root, settings, items, rows)
		legacy_samples.append(Time.get_ticks_usec() - started)
		legacy_children = legacy_root.get_child_count()
		legacy_root.free()
		var batched_root: Node3D = Node3D.new()
		tree.root.add_child(batched_root)
		started = Time.get_ticks_usec()
		result = _batched_update(batched_root, settings, items, rows, mirror, catalog)
		batched_samples.append(Time.get_ticks_usec() - started)
		batched_children = batched_root.get_child_count()
		batched_root.free()
	assert_eq(result["item_instances"], ITEMS)
	assert_eq(result["structure_instances"], STRUCTURES)
	assert_true(int(result["labels"]) < ITEMS, "distance setting limits Label3D nodes")
	assert_true(batched_children < legacy_children, "batch roots replace per-entity body nodes")
	print("[measure] PERF-2 client update headless (%d-sample median): legacy %d usec, batched %d usec for %d items + %d zombies + %d structures; root children %d -> %d; labels %d (GPU frame time unavailable headless)" % [SAMPLES, _median(legacy_samples), _median(batched_samples), ITEMS, ZOMBIES, STRUCTURES, legacy_children, batched_children, result["labels"]])
