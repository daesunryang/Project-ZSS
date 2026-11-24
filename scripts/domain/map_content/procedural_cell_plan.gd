class_name ProceduralCellPlan
extends RefCounted
## What the generated map puts in one world cell (F-33, docs/09 §15.3.1):
## the buildings that lie wholly inside it and where its first zombies
## stand. Made by ProceduralMapGenerator.plan_cell(); pure data, the same
## for the same world seed whenever it is asked for.

var cell: Vector2i = Vector2i.ZERO
## ProceduralMapGenerator.CellKind.
var kind: int = 0
## Index into ProceduralMapGenerator.towns(), -1 outside every town.
var town_index: int = -1
var buildings: Array[ProceduralBuilding] = []
## Street positions of the zombies the cell is given once.
var zombie_positions: PackedVector3Array = []


## True when nothing is placed in the cell.
func is_empty() -> bool:
	return buildings.is_empty() and zombie_positions.is_empty()


## Number of structure pieces of all buildings.
func piece_count(place_floors: bool = true) -> int:
	var total: int = 0
	for building: ProceduralBuilding in buildings:
		total += building.pieces(place_floors).size()
	return total


func container_count() -> int:
	var total: int = 0
	for building: ProceduralBuilding in buildings:
		total += building.definition.containers.size()
	return total


## JSON-safe description of everything in the plan (tests, tools).
func summary() -> Dictionary:
	var rows: Array = []
	for building: ProceduralBuilding in buildings:
		rows.append(building.summary())
	var zombies: Array = []
	for position: Vector3 in zombie_positions:
		zombies.append([position.x, position.z])
	return {"cell": [cell.x, cell.y], "kind": kind, "town_index": town_index, "buildings": rows, "zombies": zombies}
