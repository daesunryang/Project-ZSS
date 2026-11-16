class_name LootRoller
extends RefCounted
## Turns a loot table and a seed into the stacks a container holds (P3-3,
## docs/03 §6 "중요한 자원은 서버 측 스폰 시드로 결정", docs/09 §15.3). Pure: no
## world, no clock, no global random state. The same table and the same seed
## always give the same stacks, so what a container holds does not depend on
## who searches it or when, and a server restart cannot change it.
##
## The seed of one container is seed_for(world loot seed, container id). The
## container id is stable and unique in its world, so two containers of one
## table get different rolls.

## Hex digits of the SHA-256 that become the seed (15 digits = 60 bits: it
## always fits a signed 64-bit integer as a positive number).
const SEED_HEX_DIGITS: int = 15
## Keys of one rolled stack.
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_QUANTITY: String = "quantity"


## The roll seed of one container: a hash of the world's loot seed and the
## container's id. It does not depend on the engine's random generator or on
## how GDScript hashes strings.
static func seed_for(world_seed: int, container_id: String) -> int:
	return ("%d|%s" % [world_seed, container_id]).sha256_text().substr(0, SEED_HEX_DIGITS).hex_to_int()


## The stacks one search of `table` finds with `roll_seed`, in roll order:
## [{definition_id: String, quantity: int}]. A roll that found nothing adds
## no stack. No table or a table without rolls gives nothing. The table is
## expected to be valid (LootTable.validate).
static func roll(table: LootTable, roll_seed: int) -> Array[Dictionary]:
	var stacks: Array[Dictionary] = []
	if table == null:
		return stacks
	var total_weight: float = table.total_weight()
	if total_weight <= 0.0:
		return stacks
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = roll_seed
	var roll_count: int = rng.randi_range(table.rolls_min, maxi(table.rolls_max, table.rolls_min))
	for roll_index: int in range(roll_count):
		var pick: float = rng.randf() * total_weight
		var entry: int = _entry_at(table, pick)
		if entry < 0:
			continue
		stacks.append({
			KEY_DEFINITION_ID: table.item_definition_ids[entry],
			KEY_QUANTITY: rng.randi_range(table.quantities_min[entry], table.quantities_max[entry]),
		})
	return stacks


## Index of the entry the weight position `pick` falls on, -1 for "nothing"
## (the weights of the entries come first, then `nothing_weight`).
static func _entry_at(table: LootTable, pick: float) -> int:
	var passed: float = 0.0
	for index: int in range(table.entry_count()):
		passed += table.weights[index]
		if pick < passed:
			return index
	return -1
