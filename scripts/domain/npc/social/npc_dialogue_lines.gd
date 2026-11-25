class_name NpcDialogueLines
extends Resource
## The words of the conversations (F-31, docs/09 §17.16 "대사"). Data only:
## `res://resources/definitions/npc_dialogue/lines_ko.tres`. Nothing is
## generated: the server computes WHICH line an NPC says (a key below) and
## this resource gives the text, one of a few variants. `{name}` style
## placeholders are filled by the caller.
##
## A key that is missing gives "" and is logged once: a conversation never
## breaks on missing text.

const DEFAULT_PATH: String = "res://resources/definitions/npc_dialogue/lines_ko.tres"
const LINE_MAX_LENGTH: int = 200
const CHOICE_MAX_LENGTH: int = 80

## What an NPC can say. NpcDialogue uses exactly these keys;
## validate() wants at least one variant of each.
const LINE_KEYS: PackedStringArray = [
	"refuse_fear", "refuse_distrust", "refuse_busy", "refuse_again",
	"asleep", "wake_grumpy", "wake_startled",
	"open_warm", "open_neutral", "open_cold",
	"greet_warm", "greet_neutral", "greet_cold", "greet_again",
	"who_open", "who_guarded", "who_refuse",
	"give_ask", "give_nothing", "give_cannot", "give_thanks_need", "give_thanks", "give_wary", "give_refuse_fear", "give_full",
	"news_danger", "news_emptied", "news_none", "news_refuse",
	"trade_ask", "trade_nothing", "trade_refuse", "trade_done", "trade_failed",
	"join_maybe", "join_later", "join_no",
	"threat_cowed", "threat_defiant",
	"back", "bye_warm", "bye_neutral", "bye_cold", "enough",
	"dir_0", "dir_1", "dir_2", "dir_3", "dir_4", "dir_5", "dir_6", "dir_7",
]
## What a player can choose (the text of a choice).
const CHOICE_KEYS: PackedStringArray = ["greet", "who", "give", "news", "trade", "join", "threaten", "leave", "back", "wake", "give_item", "trade_item"]

## key -> PackedStringArray of variants.
@export var lines: Dictionary = {}
## choice key -> text.
@export var choices: Dictionary = {}

var _warned: Dictionary[String, bool] = {}


## The `index`-th variant (wrapping) of a line, with `params` filled in.
func line(key: String, index: int = 0, params: Dictionary = {}) -> String:
	var raw: Variant = lines.get(key, null)
	if typeof(raw) != TYPE_PACKED_STRING_ARRAY or (raw as PackedStringArray).is_empty():
		_warn(key)
		return ""
	var variants: PackedStringArray = raw
	return variants[posmod(index, variants.size())].format(params)


func variant_count(key: String) -> int:
	var raw: Variant = lines.get(key, null)
	return (raw as PackedStringArray).size() if typeof(raw) == TYPE_PACKED_STRING_ARRAY else 0


func choice(key: String, params: Dictionary = {}) -> String:
	var raw: Variant = choices.get(key, null)
	if typeof(raw) != TYPE_STRING or (raw as String).is_empty():
		_warn("choice:" + key)
		return key
	return (raw as String).format(params)


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for key: String in LINE_KEYS:
		var raw: Variant = lines.get(key, null)
		if typeof(raw) != TYPE_PACKED_STRING_ARRAY or (raw as PackedStringArray).is_empty():
			errors.append("npc dialogue line '%s' has no text" % key)
			continue
		for text: String in (raw as PackedStringArray):
			if text.is_empty() or text.length() > LINE_MAX_LENGTH:
				errors.append("npc dialogue line '%s' must be 1..%d characters" % [key, LINE_MAX_LENGTH])
	for key: Variant in lines:
		if typeof(key) != TYPE_STRING or not LINE_KEYS.has(str(key)):
			errors.append("npc dialogue line '%s' is not a known key" % str(key))
	for key: String in CHOICE_KEYS:
		var raw: Variant = choices.get(key, null)
		if typeof(raw) != TYPE_STRING or (raw as String).is_empty() or (raw as String).length() > CHOICE_MAX_LENGTH:
			errors.append("npc dialogue choice '%s' must be 1..%d characters" % [key, CHOICE_MAX_LENGTH])
	return errors


func _warn(key: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	GameLogger.warning("npc", "npc dialogue text missing", {"key": key, "operation": "dialogue_line"})


static func load_or_default(path: String = DEFAULT_PATH) -> NpcDialogueLines:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcDialogueLines:
		return loaded as NpcDialogueLines
	GameLogger.warning("config", "npc dialogue lines missing, conversations have no text", {"path": path, "operation": "load_settings"})
	return NpcDialogueLines.new()
