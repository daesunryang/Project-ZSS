class_name NpcSocialState
extends NpcComponent
## What an NPC keeps about the players it met that is not a score of its
## relationship (F-31, docs/09 §17.16 "저장"): how often they talked, what
## went wrong, what it was given, whether it was asked to join. One record
## per player it had to do with (it was talked to, or hurt: being seen
## makes none), saved with the NPC. The scores themselves (trust, fear, ...)
## are in RelationshipStore.
##
## NOT saved (it is made again from what the NPC sees): the public reaction
## (`reaction`, `reaction_player_id`) and the conversation an NPC is in.

const COMPONENT_ID: String = "social"
const SCHEMA_VERSION: int = 1
const NO_DAY: int = -1
const NO_TIME: float = -1.0
const MAX_SAFE_INT: int = 9007199254740991
const REASON_MAX_LENGTH: int = 48
## Hard bound of a saved document (the settings' bound is smaller).
const MAX_RECORDS: int = 256

const KEY_PLAYERS: String = "players"
const KEY_LINE_COUNTER: String = "line_counter"

## Why a conversation went badly (Record.last_bad_reason).
const BAD_THREATENED: String = "threatened"
const BAD_WOKEN: String = "woken"
const BAD_PESTERED: String = "pestered"
const BAD_REASONS: PackedStringArray = [BAD_THREATENED, BAD_WOKEN, BAD_PESTERED]


## What the NPC keeps about one player. Whole numbers, calendar world
## seconds and a name: JSON-safe as it is.
class Record extends RefCounted:
	const INT_KEYS: PackedStringArray = ["talks", "refusals", "pester_streak", "bad_talks", "gift_day", "gifts_today", "gifts_total", "greeted_day", "harmed", "join_requests", "wakes"]
	const TIME_KEYS: PackedStringArray = ["first_seen_at", "last_talk_at", "last_bad_at", "harmed_last_at", "join_last_at"]
	const KEY_LAST_BAD_REASON: String = "last_bad_reason"
	const KEY_JOIN_LAST_LEAN: String = "join_last_lean"

	## Calendar time the record was made (the first time the player talked
	## to the NPC or hurt it) and of the latest conversation.
	var first_seen_at: float = NO_TIME
	var last_talk_at: float = NO_TIME
	## Conversations begun / times the NPC would not talk.
	var talks: int = 0
	var refusals: int = 0
	## Times in a row the player asked again while the NPC would not talk.
	var pester_streak: int = 0
	## Conversations that went badly (F-32 reads this), the latest reason
	## (BAD_REASONS) and when.
	var bad_talks: int = 0
	var last_bad_reason: String = ""
	var last_bad_at: float = NO_TIME
	## Gifts: the calendar day of the latest, how many that day, how many ever.
	var gift_day: int = NO_DAY
	var gifts_today: int = 0
	var gifts_total: int = 0
	## The calendar day the greeting last counted.
	var greeted_day: int = NO_DAY
	## Times the player hurt the NPC, and when last.
	var harmed: int = 0
	var harmed_last_at: float = NO_TIME
	## "Join me": how often it was asked, when last, and how the NPC leaned
	## then (NpcReactionRules.join_lean). F-32 decides what it means.
	var join_requests: int = 0
	var join_last_at: float = NO_TIME
	var join_last_lean: float = 0.0
	## Times the player woke the NPC.
	var wakes: int = 0

	func to_document() -> Dictionary:
		# Written out (not a loop over the key lists): this is built for every
		# NPC of a cell document.
		return {
			"first_seen_at": first_seen_at, "last_talk_at": last_talk_at, "talks": talks, "refusals": refusals,
			"pester_streak": pester_streak, "bad_talks": bad_talks, KEY_LAST_BAD_REASON: last_bad_reason, "last_bad_at": last_bad_at,
			"gift_day": gift_day, "gifts_today": gifts_today, "gifts_total": gifts_total, "greeted_day": greeted_day,
			"harmed": harmed, "harmed_last_at": harmed_last_at, "join_requests": join_requests, "join_last_at": join_last_at,
			KEY_JOIN_LAST_LEAN: join_last_lean, "wakes": wakes,
		}

	static func from_document(document: Dictionary) -> Record:
		var record: Record = Record.new()
		for key: String in INT_KEYS:
			var value: Variant = document.get(key, null)
			var least: int = NO_DAY if key.ends_with("_day") else 0
			if not ItemInstance.is_integer_value(value) or int(value) < least or int(value) > MAX_SAFE_INT:
				return null
			record.set(key, int(value))
		for key: String in TIME_KEYS:
			var value: Variant = document.get(key, null)
			if (typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT) or not is_finite(float(value)) or float(value) < NO_TIME:
				return null
			record.set(key, float(value))
		var reason: Variant = document.get(KEY_LAST_BAD_REASON, null)
		if typeof(reason) != TYPE_STRING or (reason as String).length() > REASON_MAX_LENGTH or (not (reason as String).is_empty() and not NpcComponent.is_valid_id(reason as String)):
			return null
		record.last_bad_reason = str(reason)
		var lean: Variant = document.get(KEY_JOIN_LAST_LEAN, null)
		if (typeof(lean) != TYPE_FLOAT and typeof(lean) != TYPE_INT) or not is_finite(float(lean)) or float(lean) < 0.0 or float(lean) > 1.0:
			return null
		record.join_last_lean = float(lean)
		return record


## Runtime only: what everybody sees of how the NPC takes the player it
## attends to (NpcReactionRules.REACTIONS), and who that is ("" = nobody).
var reaction: String = NpcReactionRules.NONE
var reaction_player_id: String = ""
## Counts the lines the NPC said: which variant of a line comes next.
var line_counter: int = 0

var _records: Dictionary[String, Record] = {}
var _service_ref: WeakRef = null
var _npc_id: String = ""


static func make() -> NpcComponent:
	return NpcSocialState.new()


static func of(npc: NpcState) -> NpcSocialState:
	return npc.component(COMPONENT_ID) as NpcSocialState if npc != null else null


## The public reaction of an NPC: the function NpcNetModule is given.
## "none" for an NPC without this component.
static func reaction_of(npc: NpcState) -> String:
	var state: NpcSocialState = of(npc)
	return state.reaction if state != null else NpcReactionRules.NONE


func component_id() -> String:
	return COMPONENT_ID


func schema_version() -> int:
	return SCHEMA_VERSION


func on_attached(world: ServerWorld, npc: NpcState) -> void:
	var service: NpcService = world.get_system(NpcService.SYSTEM_ID) as NpcService
	_service_ref = weakref(service) if service != null else null
	_npc_id = npc.npc_id


func on_detached(_world: ServerWorld, _npc: NpcState, _retired: bool) -> void:
	_service_ref = null
	reaction = NpcReactionRules.NONE
	reaction_player_id = ""


## The record of a player, or null when the NPC has none.
func record_of(player_id: String) -> Record:
	return _records.get(player_id, null)


func known_player_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray(_records.keys())
	ids.sort()
	return ids


## The record of a player, made when the NPC has none. At most `capacity`
## records are kept: the player the NPC has not talked to for longest (then
## the one it saw first) is forgotten. Call touch() after changing it.
func ensure_record(player_id: String, world_time_sec: float, capacity: int) -> Record:
	var record: Record = _records.get(player_id, null)
	if record != null:
		return record
	while _records.size() >= clampi(capacity, 1, MAX_RECORDS):
		var oldest: String = ""
		for known_id: String in known_player_ids():
			if oldest.is_empty() or _is_older(_records[known_id], _records[oldest]):
				oldest = known_id
		_records.erase(oldest)
	record = Record.new()
	record.first_seen_at = maxf(world_time_sec, 0.0)
	_records[player_id] = record
	touch()
	return record


## The next line variant index (0, 1, 2, ...): saved, so a restart does not
## repeat the lines from the start.
func next_line_index() -> int:
	var index: int = line_counter
	line_counter = (line_counter + 1) % MAX_SAFE_INT
	touch()
	return index


## Tells the NPC service that what is saved changed.
func touch() -> void:
	var service: NpcService = _service_ref.get_ref() as NpcService if _service_ref != null else null
	if service != null and not _npc_id.is_empty():
		service.mark_npc_dirty(_npc_id)


func to_document() -> Dictionary:
	var players: Dictionary = {}
	for player_id: String in known_player_ids():
		players[player_id] = _records[player_id].to_document()
	return {KEY_PLAYERS: players, KEY_LINE_COUNTER: line_counter}


func restore_document(document: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not ItemInstance.is_integer_value(document.get(KEY_SCHEMA_VERSION, null)) or int(document[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		errors.append("unsupported schema_version")
	var counter: Variant = document.get(KEY_LINE_COUNTER, null)
	if not ItemInstance.is_integer_value(counter) or int(counter) < 0 or int(counter) > MAX_SAFE_INT:
		errors.append("line_counter must be a whole number >= 0")
	var raw_players: Variant = document.get(KEY_PLAYERS, null)
	if typeof(raw_players) != TYPE_DICTIONARY or (raw_players as Dictionary).size() > MAX_RECORDS:
		errors.append("players must be an object of at most %d records" % MAX_RECORDS)
		return errors
	var restored: Dictionary[String, Record] = {}
	for player_id: Variant in (raw_players as Dictionary):
		var row: Variant = (raw_players as Dictionary)[player_id]
		var record: Record = Record.from_document(row as Dictionary) if typeof(row) == TYPE_DICTIONARY else null
		if typeof(player_id) != TYPE_STRING or RegEx.create_from_string(RelationshipState.PLAYER_ID_PATTERN).search(str(player_id)) == null or record == null:
			errors.append("invalid social record")
			continue
		restored[str(player_id)] = record
	if not errors.is_empty():
		return errors
	_records = restored
	line_counter = int(counter)
	return errors


static func _is_older(a: Record, b: Record) -> bool:
	if a.last_talk_at != b.last_talk_at:
		return a.last_talk_at < b.last_talk_at
	return a.first_seen_at < b.first_seen_at
