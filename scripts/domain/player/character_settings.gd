class_name CharacterSettings
extends Resource
## Rules of character creation (docs/00 ADR-015, docs/09 §14.24): the name
## rules, whether names may repeat, what other players are told, and the
## request rate of the creation intent. Defaults live in
## `res://data/tuning/character_settings.tres`. Every value is PROVISIONAL
## (docs/15 §13).

const DEFAULT_PATH: String = "res://data/tuning/character_settings.tres"
## Code points that can never be allowed in a name: C0 controls, DEL and C1
## controls.
const LAST_C0_CONTROL: int = 0x1F
const FIRST_DEL_OR_C1_CONTROL: int = 0x7F
const LAST_C1_CONTROL: int = 0x9F

## Whether a dedicated server asks every player to create a character
## (name and appearance) before it enters the world and after every death.
## GameBootstrap copies this into CompositionConfig.require_character_creation
## when it starts a server. Compositions built directly (tests, tools) keep
## that field false: there `ServerWorld.join()` gives a new player a default
## character at once and a dead player's next character starts by itself.
@export var server_requires_character_creation: bool = true

## Name length in characters (Unicode code points), after the clean-up.
@export_range(1, 64) var name_min_length: int = 2
@export_range(1, 64) var name_max_length: int = 16
## Characters a name may contain, as pairs [first, last] of Unicode code
## points (inclusive). Default: digits, A-Z, a-z, Hangul syllables and the
## space. Everything else (punctuation, control characters, other scripts,
## emoji) is refused. Add a pair to allow another script.
@export var allowed_codepoint_ranges: PackedInt32Array = PackedInt32Array([
	0x20, 0x20,      # space (inside a name; the ends are trimmed)
	0x30, 0x39,      # 0-9
	0x41, 0x5A,      # A-Z
	0x61, 0x7A,      # a-z
	0xAC00, 0xD7A3,  # Hangul syllables
])
## Names containing one of these words are refused (case-insensitive, also
## when spaces are put between the letters). Empty: a seam for later.
@export var banned_words: PackedStringArray = PackedStringArray()
## False: a name another player's current character already has is refused
## (`name_taken`, compared without case).
@export var allow_duplicate_names: bool = true
## Name of a character nobody named: players saved before P2-T9 and default
## characters created without a creation request.
@export var default_name: String = "생존자"

## False: other players are told a character's name and appearance but not
## its generation (how many characters that player has had). The owner
## always knows its own (docs/00 ADR-009, docs/15 P2-168).
@export var share_character_generation: bool = false

## Creation requests accepted per second per peer (token bucket rate /
## burst). Only the server reads these.
@export_range(0.01, 240.0) var create_intent_rate_per_sec: float = 1.0
@export_range(1, 240) var create_intent_burst: int = 3
## Save the world as soon as a character was created (a name the player
## typed is not lost when the server stops unexpectedly).
@export var save_after_create: bool = true
## Defensive DTO bound for server-generated player ids (client mirror).
@export_range(1, 10000) var max_player_id_length: int = 128


## True when `codepoint` is inside one of the allowed ranges.
func is_allowed_codepoint(codepoint: int) -> bool:
	for index: int in range(0, allowed_codepoint_ranges.size() - 1, 2):
		if codepoint >= allowed_codepoint_ranges[index] and codepoint <= allowed_codepoint_ranges[index + 1]:
			return true
	return false


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if name_min_length < 1 or name_max_length < name_min_length:
		errors.append("character name length range must satisfy 1 <= min <= max")
	if name_max_length > CharacterNameRules.HARD_MAX_LENGTH:
		errors.append("character name_max_length must be <= %d" % CharacterNameRules.HARD_MAX_LENGTH)
	if allowed_codepoint_ranges.is_empty() or allowed_codepoint_ranges.size() % 2 != 0:
		errors.append("character allowed_codepoint_ranges must be pairs [first, last]")
	else:
		for index: int in range(0, allowed_codepoint_ranges.size(), 2):
			var first: int = allowed_codepoint_ranges[index]
			var last: int = allowed_codepoint_ranges[index + 1]
			if first > last:
				errors.append("character allowed range %d..%d is not ordered" % [first, last])
			elif first <= LAST_C0_CONTROL or (first <= LAST_C1_CONTROL and last >= FIRST_DEL_OR_C1_CONTROL):
				errors.append("character allowed range %d..%d contains control characters" % [first, last])
	for word: String in banned_words:
		if word.strip_edges().is_empty():
			errors.append("character banned_words must not contain an empty word")
			break
	if not is_finite(create_intent_rate_per_sec) or create_intent_rate_per_sec <= 0.0 or create_intent_burst < 1:
		errors.append("character create intent rate must be > 0 and burst >= 1")
	if max_player_id_length < 1:
		errors.append("character max_player_id_length must be >= 1")
	# Checked last: it needs the ranges above to be usable.
	if errors.is_empty():
		var reason: String = CharacterNameRules.check(default_name, self).reason
		if not reason.is_empty():
			errors.append("character default_name is not a valid name (%s)" % reason)
		elif CharacterNameRules.sanitize(default_name) != default_name:
			errors.append("character default_name must not need a clean-up")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> CharacterSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is CharacterSettings:
		return loaded as CharacterSettings
	GameLogger.warning("config", "character settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return CharacterSettings.new()
