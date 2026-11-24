class_name NpcSurvivalSense
extends RefCounted
## What an NPC knows about its own survival (F-29, docs/09 §17.14): what it
## has and what it lacks, whether it can treat itself, and where it met
## danger. The decision layer (NpcUtilityDecider) asks it when it scores the
## actions "scavenge" and "treat" and when a zombie is seen; the behaviours
## (NpcScavenging) ask it which buildings to avoid. It decides nothing and
## keeps no state of its own: supplies are counted from the inventories,
## danger is read from the NPC's memories (NpcMemoryStore).
##
## Supplies, by what an item does (ItemDefinition):
##   food     lowers hunger;
##   drink    lowers thirst and not hunger;
##   medical  a treatment (stops bleeding, cures the infection);
##   weapon   an item that grants a melee weapon (MeleeWeaponCatalog).
## Anything else is of no use to an NPC yet.
##
## Shortage (0..1, the need term of the action "scavenge"): the largest of
##   food     1 - (food it carries + food in its home) / what it wants,
##   medical  medical_shortage_weight when it has fewer treatments than it
##            wants; 1 when it bleeds and has none,
##   weapon   weapon_shortage_weight when it carries no weapon.
## What its home holds is counted from the home's containers while they are
## in memory and remembered in its NpcScavengeState for when they are not.
##
## Danger: a zombie it sees leaves the memory "zombie_seen" at the zombie's
## place (not again near a recent one), a zombie's hit the memory
## "hurt_by_zombie" where it stood, and fear. Both carry the tag "danger"
## and fade with danger_half_life_world_sec. danger_at() adds up, over those
## memories, strength x importance x nearness.

const KIND_FOOD: String = "food"
const KIND_DRINK: String = "drink"
const KIND_MEDICAL: String = "medical"
const KIND_WEAPON: String = "weapon"
const KIND_OTHER: String = ""

const MEMORY_ZOMBIE_SEEN: String = "zombie_seen"
const MEMORY_HURT: String = "hurt_by_zombie"
const TAG_DANGER: String = "danger"
const TAG_ZOMBIE: String = "zombie"
const TAG_HURT: String = "hurt"
const ROLE_WITNESS: String = "witness"
const ROLE_TARGET: String = "target"
const EMOTION_FEAR: String = "fear"
const ZOMBIE_ID_PREFIX: String = "zombie_"
const TRAIT_CONSCIENTIOUSNESS: String = "conscientiousness"
const TRAIT_RISK_TOLERANCE: String = "risk_tolerance"
const AVERAGE_TRAIT: float = 0.5

## Keys of supplies().
const SUPPLY_FOOD: String = "food"
const SUPPLY_DRINK: String = "drink"
const SUPPLY_MEDICAL: String = "medical"
const SUPPLY_WEAPONS: String = "weapons"

## Diagnostics (tests / profiling).
var danger_note_count: int = 0

var settings: NpcScavengeSettings

var _homes: NpcHomes
var _weapons: MeleeWeaponCatalog
var _world_ref: WeakRef = null
var _npcs_ref: WeakRef = null


func _init(scavenge_settings: NpcScavengeSettings, homes: NpcHomes, weapons: MeleeWeaponCatalog) -> void:
	settings = scavenge_settings if scavenge_settings != null else NpcScavengeSettings.new()
	_homes = homes
	_weapons = weapons


## The world this sense reads (ServerComposition, once).
func attach(world: ServerWorld, npcs: NpcService) -> void:
	_world_ref = weakref(world)
	_npcs_ref = weakref(npcs)


func homes() -> NpcHomes:
	return _homes


func weapons() -> MeleeWeaponCatalog:
	return _weapons


# ------------------------------------------------------------ items

## What an item is good for (KIND_*).
func kind_of(definition: ItemDefinition) -> String:
	if definition == null:
		return KIND_OTHER
	if definition.is_treatment():
		return KIND_MEDICAL
	if definition.consume_hunger_reduction > 0.0:
		return KIND_FOOD
	if definition.consume_thirst_reduction > 0.0:
		return KIND_DRINK
	if _weapons != null and _weapons.for_item(definition.definition_id) != null:
		return KIND_WEAPON
	return KIND_OTHER


## The weapon an item grants (null = none).
func weapon_of(definition: ItemDefinition) -> MeleeWeaponDefinition:
	return _weapons.for_item(definition.definition_id) if _weapons != null and definition != null else null


## The items of an inventory in slot order ([] for an unknown one).
static func items_of(world: ServerWorld, inventory_id: String) -> Array[ItemInstance]:
	var held: Array[ItemInstance] = []
	if world == null or inventory_id.is_empty() or not world.inventory.has_inventory(inventory_id):
		return held
	held = world.inventory.items_in_inventory(inventory_id)
	held.sort_custom(func(a: ItemInstance, b: ItemInstance) -> bool: return InventoryService.slot_index_of(a.slot_id) < InventoryService.slot_index_of(b.slot_id))
	return held


## Units of every kind in an inventory: {food, drink, medical, weapons}.
func supplies(world: ServerWorld, inventory_id: String) -> Dictionary:
	var counts: Dictionary = {SUPPLY_FOOD: 0, SUPPLY_DRINK: 0, SUPPLY_MEDICAL: 0, SUPPLY_WEAPONS: 0}
	for item: ItemInstance in items_of(world, inventory_id):
		match kind_of(world.inventory.definition_of(item.item_instance_id)):
			KIND_FOOD:
				counts[SUPPLY_FOOD] = int(counts[SUPPLY_FOOD]) + item.quantity
			KIND_DRINK:
				counts[SUPPLY_DRINK] = int(counts[SUPPLY_DRINK]) + item.quantity
			KIND_MEDICAL:
				counts[SUPPLY_MEDICAL] = int(counts[SUPPLY_MEDICAL]) + item.quantity
			KIND_WEAPON:
				counts[SUPPLY_WEAPONS] = int(counts[SUPPLY_WEAPONS]) + item.quantity
	return counts


## The best weapon item in an inventory (the highest base damage; ties: the
## lower slot), or null.
func best_weapon_item(world: ServerWorld, inventory_id: String) -> ItemInstance:
	var best: ItemInstance = null
	var best_damage: float = -1.0
	for item: ItemInstance in items_of(world, inventory_id):
		var weapon: MeleeWeaponDefinition = weapon_of(world.inventory.definition_of(item.item_instance_id))
		if weapon != null and weapon.base_damage > best_damage:
			best = item
			best_damage = weapon.base_damage
	return best


## The inventory an NPC carries ("" = none).
static func inventory_of(npc: NpcState) -> String:
	var carried: NpcBehaviourState = npc.component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState if npc != null else null
	return carried.inventory_id if carried != null else ""


# ------------------------------------------------------------ home

## True when the NPC lives alone in a generated building: only such an NPC
## scavenges.
func is_lone(npc: NpcState) -> bool:
	return _homes != null and _homes.lives_in_generated_home(npc)


## The containers of a generated building that are in memory, by their
## index in the building (null where one is not in memory).
func containers_of(world: ServerWorld, building_id: String) -> Array[ContainerInstance]:
	var found: Array[ContainerInstance] = []
	var layout: NpcHomeLayout = _homes.layout_of(building_id) if _homes != null else null
	var containers: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService if world != null else null
	if layout == null or containers == null:
		return found
	for index: int in range(layout.food_offsets.size()):
		found.append(containers.get_container(containers.container_id_of_source(MapBuildingPlan.container_source_key(ProceduralMapGenerator.MAP_ID, building_id, index))))
	return found


## What the NPC's home holds: {food, medical, drink}. Counted from the containers
## while every one of them is in memory (and written into the NPC's
## NpcScavengeState when it changed), remembered otherwise.
func home_supplies(world: ServerWorld, npc: NpcState) -> Dictionary:
	var known: NpcScavengeState = NpcScavengeState.of(npc)
	var result: Dictionary = {SUPPLY_FOOD: known.home_food_units if known != null else 0, SUPPLY_MEDICAL: known.home_medical_units if known != null else 0, SUPPLY_DRINK: 0}
	var home: NpcHome = NpcHome.of(npc)
	if home == null or not home.is_generated():
		return result
	var food: int = 0
	var medical: int = 0
	var drink: int = 0
	var in_memory: bool = _is_building_in_memory(world, home.building_id)
	for container: ContainerInstance in containers_of(world, home.building_id):
		if container == null:
			if in_memory:
				# The building never got this container.
				continue
			return result
		var counts: Dictionary = supplies(world, container.inventory_id)
		food += int(counts[SUPPLY_FOOD])
		medical += int(counts[SUPPLY_MEDICAL])
		drink += int(counts[SUPPLY_DRINK])
	if known != null and (known.home_food_units != food or known.home_medical_units != medical):
		known.home_food_units = food
		known.home_medical_units = medical
		var npcs: NpcService = _npcs()
		if npcs != null:
			npcs.mark_npc_dirty(npc.npc_id)
	result[SUPPLY_FOOD] = food
	result[SUPPLY_MEDICAL] = medical
	result[SUPPLY_DRINK] = drink
	return result


## True when the cell a generated building stands in is in memory.
func _is_building_in_memory(world: ServerWorld, building_id: String) -> bool:
	var center: Variant = _homes.building_center(building_id) if _homes != null else null
	return center != null and world.is_cell_loaded(world.cell_id_at(center as Vector3))


# ------------------------------------------------------------ what it lacks

## One of the NPC's personality traits (0..1; the average without a
## definition).
func trait_of(npc: NpcState, trait_name: String) -> float:
	var npcs: NpcService = _npcs()
	var definition: NpcDefinition = npcs.definition_of(npc.npc_id) if npcs != null and npc != null else null
	return clampf(float(definition.get(trait_name)), 0.0, 1.0) if definition != null else AVERAGE_TRAIT


## Units of food this NPC wants to have (see NpcScavengeSettings).
func food_target(npc: NpcState) -> int:
	return maxi(roundi(float(settings.food_target_units) * (0.5 + trait_of(npc, TRAIT_CONSCIENTIOUSNESS))), 1)


## Units of food the NPC still wants (what it wants less what it carries
## and what its home holds; never below 0).
func wanted_food(world: ServerWorld, npc: NpcState) -> int:
	return maxi(food_target(npc) - int(supplies(world, inventory_of(npc))[SUPPLY_FOOD]) - int(home_supplies(world, npc)[SUPPLY_FOOD]), 0)


## Units of drinks it still wants. (Drinks of a home whose cell is not in
## memory are not remembered: it may then take a few too many.)
func wanted_drinks(world: ServerWorld, npc: NpcState) -> int:
	return maxi(settings.drink_target_units - int(supplies(world, inventory_of(npc))[SUPPLY_DRINK]) - int(home_supplies(world, npc)[SUPPLY_DRINK]), 0)


## How badly the NPC lacks supplies, 0 (it has what it wants) .. 1 (see the
## header). 0 for an NPC that does not live alone, and without a world.
func supply_shortage(npc: NpcState) -> float:
	var world: ServerWorld = _world()
	if world == null or not is_lone(npc):
		return 0.0
	var carried: Dictionary = supplies(world, inventory_of(npc))
	var home: Dictionary = home_supplies(world, npc)
	var food: int = int(carried[SUPPLY_FOOD]) + int(home[SUPPLY_FOOD])
	var shortage: float = clampf(1.0 - float(food) / float(food_target(npc)), 0.0, 1.0)
	var medical: int = int(carried[SUPPLY_MEDICAL]) + int(home[SUPPLY_MEDICAL])
	var vitals: NpcVitals = NpcVitals.of(npc)
	if vitals != null:
		if vitals.is_bleeding() and medical == 0:
			return 1.0
		if medical < settings.medical_target_units:
			shortage = maxf(shortage, settings.medical_shortage_weight)
	if int(carried[SUPPLY_WEAPONS]) == 0:
		shortage = maxf(shortage, settings.weapon_shortage_weight)
	return shortage


## The first item the NPC carries that would treat it now (slot order), or
## null: it is whole, it has no body, or it carries nothing that helps.
func treatment_item(npc: NpcState) -> ItemInstance:
	var world: ServerWorld = _world()
	var vitals: NpcVitals = NpcVitals.of(npc)
	if world == null or vitals == null or not vitals.is_alive() or (not vitals.is_bleeding() and not vitals.infection.is_infected()):
		return null
	var health: NpcHealth = NpcHealth.of_world(world)
	if health == null:
		return null
	for item: ItemInstance in items_of(world, inventory_of(npc)):
		if health.check_treatment(npc.npc_id, world.inventory.definition_of(item.item_instance_id)).is_empty():
			return item
	return null


func can_treat(npc: NpcState) -> bool:
	return treatment_item(npc) != null


# ------------------------------------------------------------ danger

## The NPC sees a zombie at `position`: it remembers the place, unless it
## remembers a zombie near it from a short while ago. True when a memory
## was made.
func note_zombie_seen(world: ServerWorld, npc: NpcState, position: Vector3) -> bool:
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore if npc != null else null
	if world == null or memories == null or not position.is_finite():
		return false
	var now: float = world.clock.world_time_sec
	for memory_id: String in memories.memory_ids():
		var memory: NpcMemory = memories.memory(memory_id)
		if memory.event_type == MEMORY_ZOMBIE_SEEN and now - memory.event_world_time < settings.danger_note_interval_world_sec and _flat_distance(memory.location, position) <= settings.danger_merge_radius_m:
			return false
	return _remember(memories, npc, MEMORY_ZOMBIE_SEEN, position, now, settings.seen_importance, settings.seen_intensity, PackedStringArray([TAG_DANGER, TAG_ZOMBIE]), ROLE_WITNESS)


## A zombie hurt the NPC where it stands: it remembers the place and is
## afraid. (NpcHealth.npc_damaged; a hit by anybody else is not this
## ticket's, docs/15 F29-012.)
func on_npc_damaged(npc_id: String, source_id: String) -> void:
	var world: ServerWorld = _world()
	var npcs: NpcService = _npcs()
	var npc: NpcState = npcs.get_npc(npc_id) if npcs != null else null
	var vitals: NpcVitals = NpcVitals.of(npc)
	if world == null or npc == null or vitals == null or not vitals.is_alive() or not source_id.begins_with(ZOMBIE_ID_PREFIX):
		return
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore
	if memories != null:
		_remember(memories, npc, MEMORY_HURT, npc.position, world.clock.world_time_sec, settings.hurt_importance, settings.hurt_intensity, PackedStringArray([TAG_DANGER, TAG_HURT, TAG_ZOMBIE]), ROLE_TARGET)
	var emotions: NpcEmotions = npc.component(NpcEmotions.COMPONENT_ID) as NpcEmotions
	if emotions != null and settings.hurt_fear > 0.0:
		emotions.apply_emotion(EMOTION_FEAR, settings.hurt_fear, world.clock.world_time_sec)


## What the NPC remembers as dangerous now (F-30): [[Vector3 place, float
## weight]] per danger memory, the weight being strength x importance. The
## danger at a place is the sum of weight x nearness over these, which is
## what danger_at() returns; whoever asks about many places asks this once.
func danger_sources(npc: NpcState, world_time_sec: float) -> Array[Array]:
	var sources: Array[Array] = []
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore if npc != null else null
	if memories == null or memories.count() == 0:
		return sources
	for memory_id: String in memories.memory_ids():
		var memory: NpcMemory = memories.memory(memory_id)
		if memory.interpretation_tags.has(TAG_DANGER):
			sources.append([memory.location, memory.strength_at(world_time_sec) * memory.importance])
	return sources


## True when the NPC remembers a zombie's hit within `radius_m` of `place`
## that is still at least `min_strength` strong (F-30: hurt at home).
func remembers_hurt_near(npc: NpcState, place: Vector3, radius_m: float, min_strength: float, world_time_sec: float) -> bool:
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore if npc != null else null
	if memories == null or memories.count() == 0:
		return false
	for memory_id: String in memories.memory_ids():
		var memory: NpcMemory = memories.memory(memory_id)
		if memory.event_type == MEMORY_HURT and _flat_distance(memory.location, place) <= radius_m and memory.strength_at(world_time_sec) >= min_strength:
			return true
	return false


## How dangerous the NPC remembers a place to be (>= 0, see the header).
func danger_at(npc: NpcState, position: Vector3, world_time_sec: float) -> float:
	var memories: NpcMemoryStore = npc.component(NpcMemoryStore.COMPONENT_ID) as NpcMemoryStore if npc != null else null
	if memories == null or memories.count() == 0:
		return 0.0
	var total: float = 0.0
	for memory_id: String in memories.memory_ids():
		var memory: NpcMemory = memories.memory(memory_id)
		if not memory.interpretation_tags.has(TAG_DANGER):
			continue
		var distance: float = _flat_distance(memory.location, position)
		if distance < settings.danger_radius_m:
			total += memory.strength_at(world_time_sec) * memory.importance * (1.0 - distance / settings.danger_radius_m)
	return total


## The danger at which this NPC stays away from a place: the setting,
## halved for an NPC with no risk tolerance, doubled for one with all of it.
func danger_limit(npc: NpcState) -> float:
	return settings.danger_avoid_threshold * pow(2.0, 2.0 * trait_of(npc, TRAIT_RISK_TOLERANCE) - 1.0)


# ------------------------------------------------------------ internals

func _remember(memories: NpcMemoryStore, npc: NpcState, event_type: String, position: Vector3, now: float, importance: float, intensity: float, tags: PackedStringArray, role: String) -> bool:
	var participants: Array[Dictionary] = [{"entity_id": npc.npc_id, "role": role}]
	var recorded: ActionResult = memories.record_memory("", event_type, participants, position, now, NpcMemory.OBSERVATION_DIRECT, importance, intensity, tags, 1.0, false, settings.danger_half_life_world_sec)
	if not recorded.ok:
		# A full memory that holds only more important things: nothing is lost
		# but this note.
		GameLogger.debug("npc", "a danger was not remembered", {"entity_id": npc.npc_id, "reason": recorded.reason, "operation": "note_danger"})
		return false
	danger_note_count += 1
	return true


func _world() -> ServerWorld:
	return _world_ref.get_ref() as ServerWorld if _world_ref != null else null


func _npcs() -> NpcService:
	return _npcs_ref.get_ref() as NpcService if _npcs_ref != null else null


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
