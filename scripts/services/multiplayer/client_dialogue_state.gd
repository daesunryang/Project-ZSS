class_name ClientDialogueState
extends RefCounted
## Non-authoritative client mirror of the local player's conversation with
## an NPC (F-31, docs/09 §17.16): what the server last said of it. It has no
## send / RPC API. Every incoming view is validated before mutation.
##
## A VIEW as the server sends it to the talker (exact keys):
##   {npc_id: String (an NPC id),
##    npc_name: String (0..NpcDefinition.NAME_MAX_LENGTH characters),
##    open: bool,
##    turn: int >= 0 (counts the views of one conversation; a choice names
##      the turn it answers),
##    line: String (what the NPC says, 0..LINE_MAX_LENGTH characters),
##    choices: Array of [choice_id: String, text: String] (what the player
##      can answer; at most MAX_CHOICES, ids unique; [] exactly when the
##      conversation is not open),
##    end_reason: String ("" exactly while open, otherwise one of
##      NpcDialogue.END_REASONS)}
## `open` false = the conversation is over, or never began (the NPC would
## not talk: `line` is what it said). Only the talker is ever sent a view:
## everybody else sees the NPC's public reaction "talk" (NpcNetProtocol).

signal changed
## A conversation began, or went on with a new line (`view` is open).
signal view_shown(view: Dictionary)
## The conversation ended or never began (`view` is its last view).
signal conversation_closed(view: Dictionary)

const VIEW_KEYS: Array = [NpcDialogue.KEY_NPC_ID, NpcDialogue.KEY_NPC_NAME, NpcDialogue.KEY_OPEN, NpcDialogue.KEY_TURN, NpcDialogue.KEY_LINE, NpcDialogue.KEY_CHOICES, NpcDialogue.KEY_END_REASON]
## Protocol limits. The texts are longer than the templates of
## NpcDialogueLines may be: a filled-in placeholder (an item's name, the
## NPC's name) makes a line longer.
const LINE_MAX_LENGTH: int = NpcDialogueLines.LINE_MAX_LENGTH * 2
const CHOICE_TEXT_MAX_LENGTH: int = NpcDialogueLines.CHOICE_MAX_LENGTH * 2
const CHOICE_ID_MAX_LENGTH: int = NpcDialogue.CHOICE_ID_MAX_LENGTH
const MAX_CHOICES: int = 16
const MAX_TURN: int = 1000000
const NPC_ID_MAX_LENGTH: int = IntentValidator.ENTITY_ID_MAX_LENGTH
## A choice id: lower case ASCII letters, digits, "_" and ":" ("greet",
## "give:0", "trade:2").
const CHOICE_ID_PATTERN: String = "^[a-z0-9_:]+$"
const CHOICE_ID: int = 0
const CHOICE_TEXT: int = 1
const CHOICE_SIZE: int = 2

const REASON_BAD_VIEW: String = "bad_view"
const REASON_OTHER_NPC: String = "other_npc"

## True while the local player is in a conversation.
var open: bool = false
## The NPC of the current or the last conversation ("" = none yet).
var npc_id: String = ""
var npc_name: String = ""
## What the NPC said last.
var line: String = ""
## The answers the player can give now: [[choice_id, text], ...].
var choices: Array = []
var turn: int = 0
## Why the last conversation is over ("" while open or before the first).
var end_reason: String = ""
## Why the server refused this client's last request ("" = it did not).
var last_error: String = ""
## Views from the server that failed validation.
var rejected_payload_count: int = 0
## Valid views that were not about the conversation the mirror is in.
var ignored_view_count: int = 0

static var _choice_id_regex: RegEx = null


## Applies a (re)join: a player that just joined talks to nobody.
func apply_join() -> void:
	open = false
	npc_id = ""
	npc_name = ""
	line = ""
	choices = []
	turn = 0
	end_reason = ""
	last_error = ""
	changed.emit()


## Applies a view from the server. Returns "" when it was taken, otherwise
## why not (a malformed view is counted and changes nothing).
## `answer` true = the view answers a request of this client: it is what
## the player's conversation is now, whatever the mirror held (asking
## another NPC ends the conversation one was in). False = the server
## announced the end of a conversation by itself: that says nothing about
## another conversation the mirror is in.
func apply_view(view: Variant, answer: bool = true) -> String:
	var reason: String = view_error(view)
	if not reason.is_empty():
		rejected_payload_count += 1
		GameLogger.warning("net", "npc dialogue view ignored", {"reason": reason, "operation": "apply_view"})
		return reason
	var accepted: Dictionary = (view as Dictionary).duplicate(true)
	var view_open: bool = accepted[NpcDialogue.KEY_OPEN]
	if not answer and open and not view_open and str(accepted[NpcDialogue.KEY_NPC_ID]) != npc_id:
		ignored_view_count += 1
		return REASON_OTHER_NPC
	open = view_open
	npc_id = str(accepted[NpcDialogue.KEY_NPC_ID])
	npc_name = str(accepted[NpcDialogue.KEY_NPC_NAME])
	line = str(accepted[NpcDialogue.KEY_LINE])
	choices = (accepted[NpcDialogue.KEY_CHOICES] as Array).duplicate(true)
	turn = int(accepted[NpcDialogue.KEY_TURN])
	end_reason = str(accepted[NpcDialogue.KEY_END_REASON])
	last_error = ""
	changed.emit()
	if view_open:
		view_shown.emit(accepted)
	else:
		conversation_closed.emit(accepted)
	return ""


## The server refused a request of this client. `closes`: the refusal says
## the player is in no conversation, so a mirror that thought otherwise is
## brought in line.
func apply_error(reason: String, closes: bool = false) -> void:
	last_error = reason
	if closes and open:
		open = false
		choices = []
	changed.emit()


## True when the current view offers `choice_id`.
func has_choice(choice_id: String) -> bool:
	for entry: Variant in choices:
		if str((entry as Array)[CHOICE_ID]) == choice_id:
			return true
	return false


## The id of the `index`-th choice of the current view (0-based), or "".
func choice_id_at(index: int) -> String:
	if not open or index < 0 or index >= choices.size():
		return ""
	return str((choices[index] as Array)[CHOICE_ID])


## A copy of the mirror as one view ({} before the first conversation).
func snapshot() -> Dictionary:
	if npc_id.is_empty():
		return {}
	return {
		NpcDialogue.KEY_NPC_ID: npc_id,
		NpcDialogue.KEY_NPC_NAME: npc_name,
		NpcDialogue.KEY_OPEN: open,
		NpcDialogue.KEY_TURN: turn,
		NpcDialogue.KEY_LINE: line,
		NpcDialogue.KEY_CHOICES: choices.duplicate(true),
		NpcDialogue.KEY_END_REASON: end_reason,
	}


# ------------------------------------------------------------ pure rules

## "" when `value` is a view exactly as described in the header, otherwise
## REASON_BAD_VIEW. Used by the client on everything it receives and by the
## server on everything it is about to send.
static func view_error(value: Variant) -> String:
	if typeof(value) != TYPE_DICTIONARY:
		return REASON_BAD_VIEW
	var view: Dictionary = value
	if view.size() != VIEW_KEYS.size():
		return REASON_BAD_VIEW
	for key: Variant in view:
		if typeof(key) != TYPE_STRING or not VIEW_KEYS.has(key):
			return REASON_BAD_VIEW
	var raw_npc_id: Variant = view[NpcDialogue.KEY_NPC_ID]
	if not is_npc_id(raw_npc_id):
		return REASON_BAD_VIEW
	var raw_name: Variant = view[NpcDialogue.KEY_NPC_NAME]
	if typeof(raw_name) != TYPE_STRING or (raw_name as String).length() > NpcDefinition.NAME_MAX_LENGTH or not _is_plain_text(raw_name as String):
		return REASON_BAD_VIEW
	if typeof(view[NpcDialogue.KEY_OPEN]) != TYPE_BOOL or typeof(view[NpcDialogue.KEY_TURN]) != TYPE_INT:
		return REASON_BAD_VIEW
	if int(view[NpcDialogue.KEY_TURN]) < 0 or int(view[NpcDialogue.KEY_TURN]) > MAX_TURN:
		return REASON_BAD_VIEW
	var raw_line: Variant = view[NpcDialogue.KEY_LINE]
	if typeof(raw_line) != TYPE_STRING or (raw_line as String).length() > LINE_MAX_LENGTH or not _is_plain_text(raw_line as String):
		return REASON_BAD_VIEW
	var raw_reason: Variant = view[NpcDialogue.KEY_END_REASON]
	var raw_choices: Variant = view[NpcDialogue.KEY_CHOICES]
	if typeof(raw_reason) != TYPE_STRING or typeof(raw_choices) != TYPE_ARRAY:
		return REASON_BAD_VIEW
	var entries: Array = raw_choices
	if bool(view[NpcDialogue.KEY_OPEN]):
		# An open conversation always has an answer (at least "leave").
		if not (raw_reason as String).is_empty() or entries.is_empty() or entries.size() > MAX_CHOICES:
			return REASON_BAD_VIEW
	elif not NpcDialogue.END_REASONS.has(raw_reason as String) or not entries.is_empty():
		return REASON_BAD_VIEW
	var seen: Dictionary = {}
	for entry: Variant in entries:
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() != CHOICE_SIZE:
			return REASON_BAD_VIEW
		var choice_id: Variant = (entry as Array)[CHOICE_ID]
		var text: Variant = (entry as Array)[CHOICE_TEXT]
		if not is_choice_id(choice_id) or seen.has(choice_id):
			return REASON_BAD_VIEW
		if typeof(text) != TYPE_STRING or (text as String).is_empty() or (text as String).length() > CHOICE_TEXT_MAX_LENGTH or not _is_plain_text(text as String):
			return REASON_BAD_VIEW
		seen[choice_id] = true
	return ""


## True for a String that has the shape of an NPC id. (A regular
## expression's "$" also matches before a last line break: such an id is
## refused here.)
static func is_npc_id(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and (value as String).length() <= NPC_ID_MAX_LENGTH and not (value as String).contains("\n") and NpcState.is_valid_npc_id(value as String)


## True for a String that has the shape of a choice id.
static func is_choice_id(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING or (value as String).is_empty() or (value as String).length() > CHOICE_ID_MAX_LENGTH or (value as String).contains("\n"):
		return false
	if _choice_id_regex == null:
		_choice_id_regex = RegEx.create_from_string(CHOICE_ID_PATTERN)
	return _choice_id_regex.search(value as String) != null


## Text the presentation can put on the screen as it is: no control
## characters.
static func _is_plain_text(text: String) -> bool:
	for index: int in text.length():
		var codepoint: int = text.unicode_at(index)
		if codepoint <= 0x1F or (codepoint >= 0x7F and codepoint <= 0x9F):
			return false
	return true
