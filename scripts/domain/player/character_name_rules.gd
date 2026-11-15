class_name CharacterNameRules
extends RefCounted
## Pure rules of a character name (docs/00 ADR-015, docs/09 §14.24). The
## creation screen and the server run this same code; the server's answer is
## the one that counts.
##
## Clean-up (sanitize): whitespace and control characters at both ends are
## cut off and runs of spaces inside become one space. Nothing else is ever
## removed or replaced: a name that still contains a character outside the
## configured ranges (a control character, punctuation, another script) is
## refused, so a player always gets the name it typed or a refusal.
##
## Checks, in order: raw length (protocol limit, before any work), empty,
## too short, too long, characters, banned words.

const REASON_EMPTY: String = "name_empty"
const REASON_TOO_SHORT: String = "name_too_short"
const REASON_TOO_LONG: String = "name_too_long"
const REASON_BAD_CHARACTERS: String = "name_bad_characters"
const REASON_BANNED: String = "name_banned"
## Longest raw name (characters) that is looked at, and the upper bound of
## CharacterSettings.name_max_length. Also what a client mirror accepts.
const HARD_MAX_LENGTH: int = 64
const SPACE: String = " "
const DOUBLE_SPACE: String = "  "


## `raw` without whitespace / control characters at its ends and with every
## run of spaces reduced to one space.
static func sanitize(raw: String) -> String:
	var cleaned: String = raw.strip_edges()
	while cleaned.contains(DOUBLE_SPACE):
		cleaned = cleaned.replace(DOUBLE_SPACE, SPACE)
	return cleaned


## "" when the (already cleaned) name satisfies `settings`, otherwise a
## reason code.
static func validate(name: String, settings: CharacterSettings) -> String:
	if name.is_empty():
		return REASON_EMPTY
	if name.length() < settings.name_min_length:
		return REASON_TOO_SHORT
	if name.length() > settings.name_max_length:
		return REASON_TOO_LONG
	for index: int in name.length():
		if not settings.is_allowed_codepoint(name.unicode_at(index)):
			return REASON_BAD_CHARACTERS
	if _contains_banned_word(name, settings):
		return REASON_BANNED
	return ""


## Cleans and checks a name as typed / as sent. Success event:
##   {"name": the cleaned name}
## Failure: one of the REASON_* codes.
static func check(raw: String, settings: CharacterSettings) -> ActionResult:
	# A name far beyond any limit is refused before it is copied around.
	if raw.length() > HARD_MAX_LENGTH:
		return ActionResult.failure(REASON_TOO_LONG)
	var cleaned: String = sanitize(raw)
	var reason: String = validate(cleaned, settings)
	if not reason.is_empty():
		return ActionResult.failure(reason)
	return ActionResult.success({"name": cleaned})


static func _contains_banned_word(name: String, settings: CharacterSettings) -> bool:
	if settings.banned_words.is_empty():
		return false
	var lowered: String = name.to_lower()
	var squeezed: String = lowered.replace(SPACE, "")
	for word: String in settings.banned_words:
		var banned: String = word.strip_edges().to_lower()
		if banned.is_empty():
			continue
		if lowered.contains(banned) or squeezed.contains(banned.replace(SPACE, "")):
			return true
	return false
