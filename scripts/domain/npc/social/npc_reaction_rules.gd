class_name NpcReactionRules
extends RefCounted
## How an NPC takes a player it sees (F-31, docs/09 §17.16 "반응"). Pure
## functions of what is handed in: nothing is read from the world, nothing
## is changed, no random number is drawn. The same inputs always give the
## same reaction.
##
##   threat  how dangerous the player looks to this NPC (0..1): a stranger,
##           armed, somebody that hurt it or that it saw kill, less for
##           somebody it trusts;
##   fear    threat x (fear_base - boldness): the same player frightens a
##           timid NPC more than a bold one;
##   warmth  how much the NPC likes company and this player.
## reaction(): "afraid" (it runs), "hide" (it keeps its distance), "greet"
## (it comes over), "wary" (it stands and watches).

## The public reaction labels (NpcNetProtocol.REACTIONS has the same names).
const NONE: String = "none"
const WARY: String = "wary"
const HIDE: String = "hide"
const GREET: String = "greet"
const AFRAID: String = "afraid"
const TALK: String = "talk"
const REACTIONS: PackedStringArray = [NONE, WARY, HIDE, GREET, AFRAID, TALK]

const AVERAGE_TRAIT: float = 0.5


## What the rules look at. Made by NpcSocial from the world; tests fill it
## by hand.
class View extends RefCounted:
	## NpcDefinition.personality(); a missing trait counts as average.
	var traits: Dictionary = {}
	## The NPC's record of the player (null = a stranger).
	var relationship: RelationshipState = null
	## The player carries a weapon.
	var armed: bool = false
	## Times the player hurt this NPC / NPCs it saw the player kill.
	var harmed_count: int = 0
	var kills_seen: int = 0
	## The NPC bleeds or is badly hurt.
	var npc_hurt: bool = false
	## The NPC's emotion "fear" now (0..1).
	var emotion_fear: float = 0.0

	func trait_of(name: String) -> float:
		var value: Variant = traits.get(name, AVERAGE_TRAIT)
		return clampf(float(value), 0.0, 1.0) if (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value)) else AVERAGE_TRAIT


## What the NPC trusts the player: its record, or what its nature gives a
## stranger.
static func trust(view: View, settings: NpcSocialSettings) -> float:
	if view.relationship != null:
		return view.relationship.trust
	return clampf(settings.stranger_trust_base + settings.stranger_trust_agreeableness * view.trait_of("agreeableness"), 0.0, 1.0)


static func threat(view: View, settings: NpcSocialSettings) -> float:
	var total: float = settings.stranger_threat
	if view.armed:
		total += settings.armed_threat
	total += settings.harmed_threat * float(clampi(view.harmed_count, 0, settings.counted_harm))
	total += settings.killer_threat * float(clampi(view.kills_seen, 0, settings.counted_harm))
	total -= settings.trust_threat_relief * trust(view, settings)
	if view.relationship != null:
		total += settings.fear_threat_weight * view.relationship.fear
		total += settings.resentment_threat_weight * view.relationship.resentment
		total -= settings.liking_threat_relief * view.relationship.liking
	return clampf(total, 0.0, 1.0)


static func boldness(view: View, settings: NpcSocialSettings) -> float:
	var total: float = settings.boldness_courage_weight * view.trait_of("courage")
	total += settings.boldness_risk_weight * view.trait_of("risk_tolerance")
	total += settings.boldness_calm_weight * (1.0 - view.trait_of("neuroticism"))
	if view.npc_hurt:
		total -= settings.hurt_boldness_loss
	total -= settings.fear_emotion_boldness_loss * clampf(view.emotion_fear, 0.0, 1.0)
	return clampf(total, 0.0, 1.0)


static func fear(view: View, settings: NpcSocialSettings) -> float:
	return maxf(threat(view, settings) * (settings.fear_base - boldness(view, settings)), 0.0)


static func warmth(view: View, settings: NpcSocialSettings) -> float:
	var total: float = settings.warmth_extraversion_weight * view.trait_of("extraversion")
	total += settings.warmth_agreeableness_weight * view.trait_of("agreeableness")
	total += settings.warmth_trust_weight * trust(view, settings)
	if view.relationship != null:
		total += settings.warmth_liking_weight * view.relationship.liking
	return total


## One of AFRAID, HIDE, GREET, WARY.
static func reaction(view: View, settings: NpcSocialSettings) -> String:
	return str(assess(view, settings)[0])


## [reaction, fear] in one go (what an NPC's look needs of every player).
static func assess(view: View, settings: NpcSocialSettings) -> Array:
	var danger: float = threat(view, settings)
	var felt: float = maxf(danger * (settings.fear_base - boldness(view, settings)), 0.0)
	if felt >= settings.flee_fear:
		return [AFRAID, felt]
	if felt >= settings.hide_fear:
		return [HIDE, felt]
	if warmth(view, settings) - danger >= settings.greet_warmth:
		return [GREET, felt]
	return [WARY, felt]


## How ready the NPC is to throw in its lot with the player (0..1). F-31
## only shows and stores it (the "join me" choice); F-32 decides. The
## personality counts settings.join_personality_weight of it (FD-10).
static func join_lean(view: View, settings: NpcSocialSettings) -> float:
	var nature: float = 0.35 * view.trait_of("agreeableness") + 0.25 * view.trait_of("extraversion") + 0.2 * (1.0 - view.trait_of("self_interest")) + 0.2 * (1.0 - view.trait_of("neuroticism"))
	var bond: float = trust(view, settings)
	if view.relationship != null:
		bond = 0.6 * view.relationship.trust + 0.25 * view.relationship.liking + 0.15 * view.relationship.dependence - 0.5 * view.relationship.fear - 0.5 * view.relationship.resentment
	var weight: float = clampf(settings.join_personality_weight, 0.0, 1.0)
	return clampf(weight * nature + (1.0 - weight) * clampf(bond, 0.0, 1.0) - threat(view, settings) * 0.3, 0.0, 1.0)
