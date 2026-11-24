class_name NpcHomes
extends RefCounted
## Where NPCs live and what they use there (F-28, docs/09 §17.13): the one
## place that turns an NPC's NpcHome component into positions and spots,
## whether its home is a building of the hand-made map (its definition
## names it) or a generated building (chosen with the world seed). Shared by
## NpcService (placing), NpcExecutor (spots) and NpcBehaviours (where to
## eat, drink, sleep and wander). No state of its own is saved.
##
## Generated buildings are not loaded for any of this: the layout of a
## building (NpcHomeLayout) is derived from the generator's plan of its
## cell, and kept in a small cache.

## Layouts kept at most; the cache is emptied when it is full.
const MAX_CACHED_LAYOUTS: int = 256

var settings: NpcHomeSettings

var _map_content: MapContentDefinition
var _grid: StructureGrid
var _items: ItemCatalog
## Returns the world's ProceduralMapGenerator, or null.
var _generator_source: Callable = Callable()
## building_id -> its layout (null = not a building of the generated map).
var _layouts: Dictionary[String, NpcHomeLayout] = {}
## spot_id -> the definition of a generated spot.
var _spots: Dictionary[String, NpcSpotDefinition] = {}


## `map_content` and `grid`: where the home and work spots of the
## definitions are (both may be null: no hand-made map). `items`: to cut
## the home stock into stacks (null = no stock).
func _init(home_settings: NpcHomeSettings, map_content: MapContentDefinition, grid: StructureGrid, items: ItemCatalog = null) -> void:
	settings = home_settings if home_settings != null else NpcHomeSettings.new()
	_map_content = map_content
	_grid = grid
	_items = items


## The stacks a home is stocked with (NpcHomeSettings.stock_units of
## stock_item_id, cut by the item's largest stack). Empty = nothing.
func stock_stacks() -> PackedInt32Array:
	var stacks: PackedInt32Array = []
	var item: ItemDefinition = _items.get_definition(settings.stock_item_id) if _items != null and settings.stock_units > 0 else null
	var left: int = settings.stock_units if item != null else 0
	while left > 0:
		stacks.append(mini(left, item.max_stack))
		left -= mini(left, item.max_stack)
	return stacks


## Who gives the generator of this world (ProceduralMapService.generator).
func set_generator_source(source: Callable) -> void:
	_generator_source = source
	_layouts.clear()
	_spots.clear()


func generator() -> ProceduralMapGenerator:
	if not _generator_source.is_valid():
		return null
	var made: Variant = _generator_source.call()
	return made as ProceduralMapGenerator if made is ProceduralMapGenerator else null


## True when the NPCs of a roster get generated homes in this world: the
## setting is on and the world has a generated map.
func gives_lone_homes() -> bool:
	if not settings.lone_homes:
		return false
	var maker: ProceduralMapGenerator = generator()
	return maker != null and maker.is_usable()


## The layout of a generated building, or null (not a generated building of
## this world, or one nobody can live in).
func layout_of(building_id: String) -> NpcHomeLayout:
	if _layouts.has(building_id):
		return _layouts[building_id]
	var maker: ProceduralMapGenerator = generator()
	var building: ProceduralBuilding = maker.building_by_id(building_id) if maker != null else null
	var layout: NpcHomeLayout = NpcHomeLayout.of(building.definition) if building != null else null
	if layout != null and not layout.is_valid():
		layout = null
	if _layouts.size() >= MAX_CACHED_LAYOUTS:
		_layouts.clear()
		_spots.clear()
	_layouts[building_id] = layout
	return layout


# ------------------------------------------------------------ one NPC

## The building an NPC lives in ("" = none).
func home_building_id(npc: NpcState, definition: NpcDefinition) -> String:
	var home: NpcHome = NpcHome.of(npc)
	if home != null and home.is_generated():
		return home.building_id
	return definition.home_building_id if definition != null else ""


## Where an NPC stands when it is at home (Vector3), or null when it has no
## home in this world.
func home_position(npc: NpcState, definition: NpcDefinition) -> Variant:
	var home: NpcHome = NpcHome.of(npc)
	if home != null and home.is_generated():
		return _grid.tile_center(home.tile) if _grid != null else null
	if definition == null or definition.home_building_id.is_empty():
		return null
	return NpcRoster.spot_position(_map_content, _grid, definition.home_building_id, definition.home_tile_offset)


## The building an NPC works in ("" = none: every NPC that lives alone).
func work_building_id(npc: NpcState, definition: NpcDefinition) -> String:
	var home: NpcHome = NpcHome.of(npc)
	if definition == null or (home != null and not home.has_work_place(definition)):
		return ""
	return definition.work_building_id


func work_position(npc: NpcState, definition: NpcDefinition) -> Variant:
	if work_building_id(npc, definition).is_empty():
		return null
	return NpcRoster.spot_position(_map_content, _grid, definition.work_building_id, definition.work_tile_offset)


## True when the NPC lives in a generated building: it uses the spots of
## that building and no others.
func lives_in_generated_home(npc: NpcState) -> bool:
	var home: NpcHome = NpcHome.of(npc)
	return home != null and home.is_generated()


# ------------------------------------------------------------ generated spots

## The spots of a generated building (NpcSpotDefinition.KIND_*; "" = every
## kind), sorted. None for a building that is not generated.
func generated_spot_ids(building_id: String, kind: String = "") -> PackedStringArray:
	var layout: NpcHomeLayout = layout_of(building_id)
	return layout.spot_ids(kind) if layout != null else PackedStringArray()


## The definition of a generated spot, or null (also for an id of the
## hand-made spot set).
func generated_spot(spot_id: String) -> NpcSpotDefinition:
	if _spots.has(spot_id):
		return _spots[spot_id]
	var building_id: String = NpcHomeLayout.building_id_of_spot(spot_id)
	if building_id.is_empty() or ProceduralMapGenerator.parse_building_id(building_id).is_empty():
		return null
	var layout: NpcHomeLayout = layout_of(building_id)
	var made: NpcSpotDefinition = layout.spot(spot_id) if layout != null else null
	if made != null:
		_spots[spot_id] = made
	return made


## Where an NPC stands to use a generated spot (Vector3), or null.
func generated_spot_position(spot_id: String) -> Variant:
	var spot: NpcSpotDefinition = generated_spot(spot_id)
	var layout: NpcHomeLayout = layout_of(spot.building_id) if spot != null else null
	if layout == null or _grid == null:
		return null
	return _grid.tile_center(layout.origin_tile + spot.tile_offset)


# ------------------------------------------------------------ any generated building

## The middle of a generated building (Vector3), or null (F-29: how far a
## building is, and which cell it stands in; a building never crosses a
## cell border).
func building_center(building_id: String) -> Variant:
	var layout: NpcHomeLayout = layout_of(building_id)
	if layout == null or _grid == null:
		return null
	var low: Vector3 = _grid.tile_center(layout.origin_tile)
	var high: Vector3 = _grid.tile_center(layout.origin_tile + layout.size_tiles - Vector2i.ONE)
	return (low + high) * 0.5


## Where somebody stands to search the container at `index` of a generated
## building (Vector3: the container's own tile), or null.
func container_position(building_id: String, index: int) -> Variant:
	var layout: NpcHomeLayout = layout_of(building_id)
	if layout == null or _grid == null or index < 0 or index >= layout.food_offsets.size():
		return null
	return _grid.tile_center(layout.origin_tile + layout.food_offsets[index])
