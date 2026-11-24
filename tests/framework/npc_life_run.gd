class_name NpcLifeRun
extends RefCounted
## One headless run of a world in which the NPCs live by themselves, and
## what was seen of it (P4-Z: tests/scenarios/phase4_acceptance_test.gd and
## tests/unit/npc_measure_test.gd). The composition is the one of a
## dedicated server (GameBootstrap): the shipped settings, the test map
## with its buildings, doors and containers, the dev NPC roster, the
## shipped NPC spots. What differs from a dedicated server, and why:
##   - no dev zombies (an NPC flees whatever it sees; the tests put their
##     own zombie where they want one);
##   - one player, "alice", stands at the spawn point for the whole run (the
##     clock stops without a player, docs/13 §16.3 D4) and her needs do not
##     grow, so that she is still alive days later;
##   - the cells are refreshed every tick (no real-time period);
##   - no generated map unless the caller gives one (`procedural`): without
##     it the NPCs live in the houses of the test map their definitions
##     name, with the shipped spots, a work place and the stocked food (the
##     controlled setup of the behaviour tests). With it they live alone in
##     generated buildings (F-28), as on a dedicated server;
##   - `survival` false: without the survival layer of F-29 (nobody
##     scavenges, remembers zombies or fights): the NPCs live as they did
##     before it (tests of living at home).
## Fixed ticks: the caller says how long a tick is.

const NEVER: float = 1.0e9
const OBSERVER: String = "alice"
## The actions whose counts are kept per calendar day.
const COUNTED: PackedStringArray = ["eat", "drink", "rest", "rest_cut", "sleep", "sleep_cut", "work", "wander", "failed"]

var world: ServerWorld = null
var persistence: WorldPersistence = null
var decider: NpcUtilityDecider = null
var behaviours: NpcBehaviours = null
var observer: PlayerState = null
var tick: int = 0
var tick_sec: float = 0.05
## "<tick> <npc> <sequence> <outcome> <chosen> <state after>" per decision.
var decisions: PackedStringArray = []
## "<tick> <event> <npc> <action> [<code>]" per behaviour event.
var events: PackedStringArray = []
## npc_id -> {need kind: the highest value seen at a decision}.
var highest: Dictionary = {}
## npc_id -> {need kind: ticks spent in the danger category}. Counted at
## the NPC's decisions: the ticks since its decision before are added when
## the need is in danger now (a decision comes every 2 s or 10 s).
var danger_ticks: Dictionary = {}
var decision_counts: Dictionary = {}
## npc_id -> {label: true}: what other players would have seen.
var labels: Dictionary = {}
## One entry per finished calendar day: npc_id -> {count name: that day}.
var days: Array[Dictionary] = []

var _danger: float = 75.0
var _last_decision_tick: Dictionary = {}
var _day_start: Dictionary = {}


## The composition of a dedicated server with the differences above.
## `new_decider` is the world's decider (one per world). `procedural`: the
## generated map of the world (null = none, see the header).
static func config(new_decider: NpcUtilityDecider, procedural: ProceduralMapSettings = null, survival: bool = true) -> CompositionConfig:
	var result: CompositionConfig = CompositionConfig.from_defaults()
	# from_defaults() returns cached, shared resources: replace, never edit.
	result.survival = SurvivalSettings.load_or_default().duplicate() as SurvivalSettings
	result.survival.hunger_hours_to_max = NEVER
	result.survival.thirst_hours_to_max = NEVER
	result.survival.fatigue_hours_to_max = NEVER
	result.survival.respawn_delay_sec = NEVER
	result.zombie = ZombieSettings.load_or_default().duplicate() as ZombieSettings
	result.zombie.dev_spawn_count = 0
	result.dev_seed = DevWorldSeed.new()
	result.world_cells = WorldCellSettings.load_or_default().duplicate() as WorldCellSettings
	result.world_cells.refresh_period_sec = 0.0
	result.world_cells.preload_lookahead_sec = 0.0
	result.map_content = MapContentDefinition.load_or_null()
	result.npc_roster = NpcRoster.load_or_null()
	result.procedural_map = procedural
	result.npc_decider = new_decider
	if not survival:
		result.npc_scavenge = null
	return result


static func new_decider() -> NpcUtilityDecider:
	return NpcUtilityDecider.new(NpcDecisionSettings.load_or_default(), NpcActionCatalog.load_directory(), NpcNeedSettings.load_or_default())


## A new world in memory (no files), seeded with the map and the roster.
## null when it could not be made. `max_npcs` > 0 replaces the shipped
## limit of NPCs (the measurement with more than the limit).
static func begin_in_memory(world_id: String, tick_seconds: float, max_npcs: int = 0, procedural: ProceduralMapSettings = null, survival: bool = true) -> NpcLifeRun:
	var run: NpcLifeRun = NpcLifeRun.new()
	run.tick_sec = tick_seconds
	run.decider = new_decider()
	var composition: CompositionConfig = config(run.decider, procedural, survival)
	if max_npcs > 0:
		composition.npc = NpcSettings.load_or_default().duplicate() as NpcSettings
		composition.npc.max_npcs = max_npcs
	if not composition.validate().is_empty():
		return null
	run.world = ServerComposition.create_world(world_id, composition)
	if run.world == null:
		return null
	(run.world.get_system(WorldCellService.SYSTEM_ID) as WorldCellService).set_store(WorldCellStore.new())
	if run.world.seed_new_world(DevWorldSeed.new()) != OK:
		return null
	return run if run._attach() else null


## A server start on real files, as GameBootstrap does it: the world
## WorldPersistence finds under `save_root` (a new, seeded and saved one
## the first time; the saved one after that). null when it failed.
static func begin_on_disk(world_id: String, save_root: String, tick_seconds: float, procedural: ProceduralMapSettings = null, survival: bool = true) -> NpcLifeRun:
	var run: NpcLifeRun = NpcLifeRun.new()
	run.tick_sec = tick_seconds
	run.decider = new_decider()
	var composition: CompositionConfig = config(run.decider, procedural, survival)
	if not composition.validate().is_empty():
		return null
	run.persistence = WorldPersistence.new(SaveService.new(save_root), composition)
	run.world = run.persistence.load_or_create(world_id)
	if run.world == null:
		return null
	return run if run._attach() else null


func _attach() -> bool:
	var adapter: NpcBehaviourExecutor = decider.executor() as NpcBehaviourExecutor
	if adapter == null:
		return false
	behaviours = adapter.behaviours()
	_danger = NpcNeedSettings.load_or_default().danger_threshold
	decider.decided.connect(_on_decided)
	behaviours.behaviour_started.connect(func(npc_id: String, action_id: String, _info: Dictionary) -> void: events.append("%d started %s %s" % [tick, npc_id, action_id]))
	behaviours.behaviour_finished.connect(func(npc_id: String, action_id: String, _info: Dictionary) -> void: events.append("%d finished %s %s" % [tick, npc_id, action_id]))
	behaviours.behaviour_failed.connect(func(npc_id: String, action_id: String, code: String) -> void: events.append("%d failed %s %s %s" % [tick, npc_id, action_id, code]))
	behaviours.behaviour_cancelled.connect(func(npc_id: String, action_id: String) -> void: events.append("%d cancelled %s %s" % [tick, npc_id, action_id]))
	observer = world.join(OBSERVER)
	return observer != null


func _on_decided(npc_id: String, record: Dictionary) -> void:
	decisions.append("%d %s %d %s %s %s" % [tick, npc_id, int(record[NpcUtilityDecider.KEY_SEQUENCE]), str(record[NpcUtilityDecider.KEY_OUTCOME]), str(record[NpcUtilityDecider.KEY_CHOSEN]), str(record[NpcUtilityDecider.KEY_STATE_AFTER])])
	var needs: NpcNeeds = npcs().get_npc(npc_id).component(NpcNeeds.COMPONENT_ID) as NpcNeeds
	if not highest.has(npc_id):
		highest[npc_id] = {}
		danger_ticks[npc_id] = {}
	decision_counts[npc_id] = int(decision_counts.get(npc_id, 0)) + 1
	var since: int = tick - int(_last_decision_tick.get(npc_id, tick))
	_last_decision_tick[npc_id] = tick
	for kind: String in NpcNeedKind.SIMULATED_KINDS:
		var value: float = needs.value(kind)
		highest[npc_id][kind] = maxf(float(highest[npc_id].get(kind, 0.0)), value)
		if value >= _danger:
			danger_ticks[npc_id][kind] = int(danger_ticks[npc_id].get(kind, 0)) + since


func npcs() -> NpcService:
	return world.get_system(NpcService.SYSTEM_ID) as NpcService


func step() -> void:
	world.step_systems(tick_sec)
	tick += 1


## Runs `count` ticks. Every `label_period` ticks the labels are looked at.
func run_ticks(count: int, label_period: int = 20) -> void:
	for index: int in range(count):
		step()
		if label_period > 0 and tick % label_period == 0:
			see_labels()


func see_labels() -> void:
	var service: NpcService = npcs()
	for npc_id: String in service.npc_ids():
		if not labels.has(npc_id):
			labels[npc_id] = {}
		labels[npc_id][NpcDecisionComponent.label_of(service.get_npc(npc_id))] = true


func behaviour_of(npc_id: String) -> NpcBehaviourState:
	return npcs().get_npc(npc_id).component(NpcBehaviourState.COMPONENT_ID) as NpcBehaviourState


func counts_of(npc_id: String) -> Dictionary:
	var state: NpcBehaviourState = behaviour_of(npc_id)
	var result: Dictionary = {}
	for name: String in COUNTED:
		result[name] = state.count_of(name)
	result["worked_usec"] = state.worked_usec
	return result


## Closes a calendar day: what every NPC did since the day before.
func close_day() -> void:
	var day: Dictionary = {}
	for npc_id: String in npcs().npc_ids():
		var now: Dictionary = counts_of(npc_id)
		var before: Dictionary = _day_start.get(npc_id, {})
		var done: Dictionary = {}
		for name: String in now:
			done[name] = int(now[name]) - int(before.get(name, 0))
		day[npc_id] = done
		_day_start[npc_id] = now
	days.append(day)


## The longest run of the same failure of one NPC with nothing finished by
## that NPC in between.
func longest_failure_streak() -> int:
	var streak: Dictionary = {}
	var last: Dictionary = {}
	var longest: int = 0
	for line: String in events:
		var parts: PackedStringArray = line.split(" ")
		if parts[1] == "finished":
			streak[parts[2]] = 0
		elif parts[1] == "failed":
			var what: String = "%s %s" % [parts[3], parts[4]]
			streak[parts[2]] = int(streak.get(parts[2], 0)) + 1 if str(last.get(parts[2], "")) == what else 1
			last[parts[2]] = what
			longest = maxi(longest, int(streak[parts[2]]))
	return longest


## "<action> <code>" -> how often, over the whole run.
func failure_counts() -> Dictionary:
	var result: Dictionary = {}
	for line: String in events:
		var parts: PackedStringArray = line.split(" ")
		if parts[1] == "failed":
			var what: String = "%s %s" % [parts[3], parts[4]]
			result[what] = int(result.get(what, 0)) + 1
	return result


## "<action> " -> how often the decision layer chose it and it could not
## even begin (the executor refused: no food, no free spot, ...). Such a
## refusal is no behaviour event; from tick `from_tick` on.
func refusal_counts(from_tick: int = 0) -> Dictionary:
	var result: Dictionary = {}
	for line: String in decisions:
		var parts: PackedStringArray = line.split(" ")
		if parts[3] == NpcUtilityDecider.OUTCOME_FAILED and parts[0].to_int() >= from_tick and not parts[4].is_empty() and parts[5] == NpcDecisionState.RECOVER:
			result[parts[4]] = int(result.get(parts[4], 0)) + 1
	return result


## Units of `definition_id` in the containers that are in memory.
func units_in_containers(definition_id: String) -> int:
	var containers: ContainerService = world.get_system(ContainerService.SYSTEM_ID) as ContainerService
	var total: int = 0
	for container_id: String in containers.container_ids():
		for item: ItemInstance in world.inventory.items_in_inventory(containers.get_container(container_id).inventory_id):
			if item.definition_id == definition_id:
				total += item.quantity
	return total


## Save data of every NPC in memory, by id, without "simulated until" (for
## an awake NPC that is the time the document was made).
func npc_documents() -> Dictionary:
	var result: Dictionary = {}
	for npc_id: String in npcs().npc_ids():
		var document: Dictionary = npcs().npc_document(npc_id)
		document.erase(NpcState.KEY_LAST_SIMULATED)
		result[npc_id] = document
	return result


## Lets go of the world (the world's signals hold this object).
func finish() -> void:
	world = null
	persistence = null
	decider = null
	behaviours = null
	observer = null


# ------------------------------------------------------------ comparing

## A document as a save holds it: text, at full precision.
static func as_saved(value: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(value, "", true, true)) as Dictionary


## The hash of a document (sorted keys, full precision).
static func hash_of(value: Dictionary) -> String:
	return JSON.stringify(value, "", true, true).sha256_text()


## "" when two documents are the same to the last bit, otherwise the first
## places (at most `limit`) where they differ. No tolerance.
static func differences(actual: Variant, expected: Variant, path: String, limit: int = 8) -> String:
	var found: PackedStringArray = []
	_collect(actual, expected, path, limit, found)
	return "; ".join(found)


static func _collect(actual: Variant, expected: Variant, path: String, limit: int, found: PackedStringArray) -> void:
	if found.size() >= limit:
		return
	if typeof(actual) == TYPE_DICTIONARY and typeof(expected) == TYPE_DICTIONARY:
		var keys: Array = (expected as Dictionary).keys()
		for key: Variant in (actual as Dictionary).keys():
			if not keys.has(key):
				keys.append(key)
		keys.sort()
		for key: Variant in keys:
			if not (actual as Dictionary).has(key) or not (expected as Dictionary).has(key):
				found.append("%s.%s is only in one of them" % [path, str(key)])
			else:
				_collect((actual as Dictionary)[key], (expected as Dictionary)[key], "%s.%s" % [path, str(key)], limit, found)
		return
	if typeof(actual) == TYPE_ARRAY and typeof(expected) == TYPE_ARRAY and (actual as Array).size() == (expected as Array).size():
		for index: int in range((actual as Array).size()):
			_collect((actual as Array)[index], (expected as Array)[index], "%s[%d]" % [path, index], limit, found)
		return
	var one: String = first_difference(actual, expected, path)
	if not one.is_empty():
		found.append(one)


## "" when two documents are the same to the last bit, otherwise where they
## differ first. No tolerance.
static func first_difference(actual: Variant, expected: Variant, path: String) -> String:
	if typeof(actual) == TYPE_DICTIONARY and typeof(expected) == TYPE_DICTIONARY:
		var keys: Array = (expected as Dictionary).keys()
		for key: Variant in (actual as Dictionary).keys():
			if not keys.has(key):
				keys.append(key)
		keys.sort()
		for key: Variant in keys:
			if not (actual as Dictionary).has(key) or not (expected as Dictionary).has(key):
				return "%s.%s is only in one of them" % [path, str(key)]
			var inner: String = first_difference((actual as Dictionary)[key], (expected as Dictionary)[key], "%s.%s" % [path, str(key)])
			if not inner.is_empty():
				return inner
		return ""
	if typeof(actual) == TYPE_ARRAY and typeof(expected) == TYPE_ARRAY:
		if (actual as Array).size() != (expected as Array).size():
			return "%s has %d entries, expected %d" % [path, (actual as Array).size(), (expected as Array).size()]
		for index: int in range((actual as Array).size()):
			var inner: String = first_difference((actual as Array)[index], (expected as Array)[index], "%s[%d]" % [path, index])
			if not inner.is_empty():
				return inner
		return ""
	if typeof(actual) == typeof(expected) and typeof(actual) == TYPE_FLOAT:
		return "" if var_to_bytes(actual) == var_to_bytes(expected) else "%s is %s, expected %s" % [path, var_to_str(actual), var_to_str(expected)]
	if typeof(actual) == typeof(expected) and actual == expected:
		return ""
	return "%s is %s, expected %s" % [path, var_to_str(actual), var_to_str(expected)]


## "" when the two lists are the same, otherwise the first line that differs.
static func first_line_difference(actual: PackedStringArray, expected: PackedStringArray) -> String:
	for index: int in range(mini(actual.size(), expected.size())):
		if actual[index] != expected[index]:
			return "line %d is \"%s\", expected \"%s\"" % [index, actual[index], expected[index]]
	if actual.size() != expected.size():
		return "%d lines, expected %d" % [actual.size(), expected.size()]
	return ""


## The lines whose tick (the first word) is at least `from_tick`.
static func lines_from(lines: PackedStringArray, from_tick: int, before_tick: int = -1) -> PackedStringArray:
	var result: PackedStringArray = []
	for line: String in lines:
		var at: int = line.get_slice(" ", 0).to_int()
		if at >= from_tick and (before_tick < 0 or at < before_tick):
			result.append(line)
	return result


## Copies a directory with everything in it. OK or the first error.
static func copy_tree(from: String, to: String) -> Error:
	var error: Error = DirAccess.make_dir_recursive_absolute(to)
	if error != OK:
		return error
	var dir: DirAccess = DirAccess.open(from)
	if dir == null:
		return DirAccess.get_open_error()
	dir.include_hidden = true
	for name: String in dir.get_directories():
		error = copy_tree(from.path_join(name), to.path_join(name))
		if error != OK:
			return error
	for name: String in dir.get_files():
		error = dir.copy(from.path_join(name), to.path_join(name))
		if error != OK:
			return error
	return OK
