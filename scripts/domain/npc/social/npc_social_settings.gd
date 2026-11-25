class_name NpcSocialSettings
extends Resource
## Tuning of F-31 (docs/09 §17.16): how an NPC notices a player, how it
## reacts, when it talks and what a choice of a conversation does to what
## it thinks of that player. Defaults in
## `res://data/tuning/npc_social_settings.tres`. Every value is PROVISIONAL
## (docs/15 §27, F31-001 ...). Times are action seconds (the scheduler's
## clock) unless the name says "world".

const DEFAULT_PATH: String = "res://data/tuning/npc_social_settings.tres"

@export_group("Noticing")
## Every awake NPC looks for players once per this period (bucketed).
@export_range(0.05, 60.0, 0.05, "suffix:s") var notice_check_period_sec: float = 0.5
## How long an NPC that notices a player answers with its body (watching,
## coming over, backing off) before it goes on with its day.
@export_range(0.0, 600.0, 0.5, "suffix:s") var attention_sec: float = 8.0
## A player that was out of sight for this long is noticed anew.
@export_range(0.0, 86400.0, 1.0, "suffix:s") var renotice_after_sec: float = 60.0
## How near an NPC that greets comes, and how far one that keeps its
## distance backs off.
@export_range(0.5, 50.0, 0.1, "suffix:m") var greet_distance_m: float = 2.5
@export_range(0.5, 100.0, 0.5, "suffix:m") var back_off_distance_m: float = 8.0
## A player nearer than this is no reason to come nearer or to back off.
@export_range(0.0, 100.0, 0.5, "suffix:m") var back_off_within_m: float = 10.0

@export_group("How threatening a player is (0..1)")
## Somebody the NPC knows nothing about.
@export_range(0.0, 1.0, 0.01) var stranger_threat: float = 0.3
## The player carries a weapon.
@export_range(0.0, 1.0, 0.01) var armed_threat: float = 0.15
## Per time the player hurt this NPC (at most `counted_harm` times).
@export_range(0.0, 1.0, 0.01) var harmed_threat: float = 0.45
## Per NPC the NPC saw this player kill (at most `counted_harm`).
@export_range(0.0, 1.0, 0.01) var killer_threat: float = 0.35
@export_range(1, 10) var counted_harm: int = 2
@export_range(0.0, 2.0, 0.01) var fear_threat_weight: float = 0.5
@export_range(0.0, 2.0, 0.01) var resentment_threat_weight: float = 0.25
@export_range(0.0, 2.0, 0.01) var trust_threat_relief: float = 0.5
@export_range(0.0, 2.0, 0.01) var liking_threat_relief: float = 0.15

@export_group("Reaction")
## fear = threat x (fear_base - boldness); boldness is made of courage,
## risk tolerance and calm (1 - neuroticism), weights below.
@export_range(0.0, 3.0, 0.01) var fear_base: float = 1.5
@export_range(0.0, 1.0, 0.01) var boldness_courage_weight: float = 0.5
@export_range(0.0, 1.0, 0.01) var boldness_risk_weight: float = 0.2
@export_range(0.0, 1.0, 0.01) var boldness_calm_weight: float = 0.3
## A hurt NPC is less bold; so is one that is afraid already (x emotion).
@export_range(0.0, 1.0, 0.01) var hurt_boldness_loss: float = 0.15
@export_range(0.0, 1.0, 0.01) var fear_emotion_boldness_loss: float = 0.2
## At or above: it runs away / it keeps its distance.
@export_range(0.0, 2.0, 0.01) var flee_fear: float = 0.7
@export_range(0.0, 2.0, 0.01) var hide_fear: float = 0.45
## warmth = extraversion, agreeableness, trust, liking (weights below);
## warmth - threat at or above `greet_warmth`: it comes over and greets.
@export_range(0.0, 1.0, 0.01) var warmth_extraversion_weight: float = 0.45
@export_range(0.0, 1.0, 0.01) var warmth_agreeableness_weight: float = 0.3
@export_range(0.0, 1.0, 0.01) var warmth_trust_weight: float = 0.6
@export_range(0.0, 1.0, 0.01) var warmth_liking_weight: float = 0.2
@export_range(-1.0, 2.0, 0.01) var greet_warmth: float = 0.3

@export_group("A stranger (no relationship record yet)")
@export_range(0.0, 1.0, 0.01) var stranger_trust_base: float = 0.15
@export_range(0.0, 1.0, 0.01) var stranger_trust_agreeableness: float = 0.2

@export_group("Conversation")
## How near the player must be to begin, and how far it may go before the
## conversation ends by itself.
@export_range(0.5, 20.0, 0.1, "suffix:m") var talk_range_m: float = 3.0
@export_range(0.5, 40.0, 0.1, "suffix:m") var talk_leave_range_m: float = 5.0
## A conversation nobody chose anything in for this long ends.
@export_range(1.0, 3600.0, 1.0, "suffix:s") var talk_idle_timeout_sec: float = 60.0
## Choices one conversation may have before the NPC has had enough; an
## extraverted NPC bears up to `talk_turns_extraversion_bonus` more.
@export_range(1, 200) var talk_max_turns: int = 12
@export_range(0, 200) var talk_turns_extraversion_bonus: int = 8
## After the NPC refused to talk, or ended a conversation itself, it does
## not talk to that player again for this long.
@export_range(0.0, 86400.0, 1.0, "suffix:s") var refuse_cooldown_sec: float = 20.0
## Asking again within the cooldown this many times in a row is a
## conversation that went badly ("pestered").
@export_range(1, 100) var pester_limit: int = 3
## It refuses to talk at or above this fear (NpcReactionRules.fear), or
## below this trust when it also resents the player.
@export_range(0.0, 2.0, 0.01) var refuse_fear: float = 0.55
@export_range(0.0, 1.0, 0.01) var refuse_resentment: float = 0.5
## It says who it is / tells what it knows / trades at or above this trust.
@export_range(0.0, 1.0, 0.01) var who_min_trust: float = 0.2
@export_range(0.0, 1.0, 0.01) var news_min_trust: float = 0.3
@export_range(0.0, 1.0, 0.01) var trade_min_trust: float = 0.25
## Items shown in the give list / offers in the trade list.
@export_range(1, 8) var give_list_size: int = 5
@export_range(1, 8) var trade_list_size: int = 4
## News: places farther than this are not worth telling.
@export_range(1.0, 5000.0, 1.0, "suffix:m") var news_range_m: float = 400.0
## News: a danger memory weaker than this is forgotten talk.
@export_range(0.0, 1.0, 0.01) var news_min_strength: float = 0.15

@export_group("What a choice does (added to the 0..1 axes)")
@export_range(0.0, 1.0, 0.005) var greet_trust: float = 0.02
@export_range(0.0, 1.0, 0.005) var greet_liking: float = 0.02
## A gift: trust and liking, times how much the NPC needed it (1 .. 2),
## halved for every gift it already got from that player this day.
@export_range(0.0, 1.0, 0.005) var gift_trust: float = 0.08
@export_range(0.0, 1.0, 0.005) var gift_liking: float = 0.06
@export_range(0.0, 1.0, 0.005) var gift_fear_relief: float = 0.05
@export_range(0.0, 1.0, 0.005) var gift_dependence: float = 0.02
@export_range(1.0, 5.0, 0.05) var gift_need_bonus: float = 2.0
## It takes no gift at or above this fear (it does not dare come near).
@export_range(0.0, 2.0, 0.01) var gift_refuse_fear: float = 0.6
@export_range(0.0, 1.0, 0.005) var trade_trust: float = 0.03
## A threat: fear (more for a timid NPC), trust lost, resentment.
@export_range(0.0, 1.0, 0.005) var threaten_fear: float = 0.35
@export_range(0.0, 1.0, 0.005) var threaten_trust_loss: float = 0.25
@export_range(0.0, 1.0, 0.005) var threaten_resentment: float = 0.25
@export_range(0.0, 1.0, 0.005) var threaten_anger: float = 0.3
## Boldness at or above which a threatened NPC talks back instead of
## giving in.
@export_range(0.0, 1.0, 0.01) var defiant_boldness: float = 0.55
## Waking a sleeper: trust lost, anger; it is startled (and the
## conversation is over) at or above this fear.
@export_range(0.0, 1.0, 0.005) var wake_trust_loss: float = 0.05
@export_range(0.0, 1.0, 0.005) var wake_anger: float = 0.2
@export_range(0.0, 2.0, 0.01) var wake_startle_fear: float = 0.3
## Pestering: resentment.
@export_range(0.0, 1.0, 0.005) var pester_resentment: float = 0.1
## The player hurt the NPC (once per hit).
@export_range(0.0, 1.0, 0.005) var harmed_fear: float = 0.35
@export_range(0.0, 1.0, 0.005) var harmed_trust_loss: float = 0.4
@export_range(0.0, 1.0, 0.005) var harmed_resentment: float = 0.3
@export_range(0.0, 1.0, 0.005) var harmed_emotion_fear: float = 0.4
@export_range(0.0, 1.0, 0.005) var harmed_emotion_anger: float = 0.3
@export_range(0.0, 1.0, 0.01) var harmed_memory_importance: float = 0.9
@export_range(0.0, 1.0, 0.01) var harmed_memory_intensity: float = 0.9

@export_group("Join request (recorded only; F-32 decides)")
## The lean F-31 shows (and stores): personality counts `join_personality_weight`,
## the relationship the rest (FD-10: personality weighs heavily).
@export_range(0.0, 1.0, 0.01) var join_personality_weight: float = 0.6
## "maybe" at or above, "no" below `join_no_lean`, "later" between.
@export_range(0.0, 1.0, 0.01) var join_maybe_lean: float = 0.55
@export_range(0.0, 1.0, 0.01) var join_no_lean: float = 0.3

@export_group("Trade (worth of one unit, by kind)")
@export_range(0.0, 100.0, 0.1) var worth_food: float = 2.0
@export_range(0.0, 100.0, 0.1) var worth_drink: float = 2.0
@export_range(0.0, 100.0, 0.1) var worth_medical: float = 4.0
@export_range(0.0, 100.0, 0.1) var worth_weapon: float = 5.0
@export_range(0.0, 100.0, 0.1) var worth_other: float = 1.0
## What it needs is worth this much more to it.
@export_range(1.0, 10.0, 0.05) var trade_need_bonus: float = 1.5
## It wants this much more than it gives, times its self interest; trust
## takes `trade_trust_discount` x trust off again.
@export_range(0.0, 2.0, 0.01) var trade_greed: float = 0.5
@export_range(0.0, 2.0, 0.01) var trade_trust_discount: float = 0.3
## Units of food and of drink it never trades away.
@export_range(0, 100) var trade_keep_units: int = 1

@export_group("Bounds")
## Players one NPC keeps a record of (the one not met for longest goes).
@export_range(1, 256) var max_known_players: int = 32


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	for name: String in ["notice_check_period_sec", "greet_distance_m", "back_off_distance_m", "talk_range_m", "talk_leave_range_m", "talk_idle_timeout_sec", "fear_base", "gift_need_bonus", "trade_need_bonus", "news_range_m"]:
		var value: float = float(get(name))
		if not is_finite(value) or value <= 0.0:
			errors.append("npc social %s must be finite and > 0" % name)
	for name: String in ["attention_sec", "renotice_after_sec", "back_off_within_m", "refuse_cooldown_sec", "flee_fear", "hide_fear"]:
		var value: float = float(get(name))
		if not is_finite(value) or value < 0.0:
			errors.append("npc social %s must be finite and >= 0" % name)
	if talk_leave_range_m < talk_range_m:
		errors.append("npc social talk_leave_range_m must be >= talk_range_m")
	if flee_fear < hide_fear:
		errors.append("npc social flee_fear must be >= hide_fear")
	if greet_distance_m > talk_range_m:
		errors.append("npc social greet_distance_m must be <= talk_range_m (an NPC that greets comes within talking range)")
	if talk_max_turns < 1 or pester_limit < 1 or counted_harm < 1 or max_known_players < 1:
		errors.append("npc social talk_max_turns, pester_limit, counted_harm and max_known_players must be >= 1")
	if join_no_lean > join_maybe_lean:
		errors.append("npc social join_no_lean must be <= join_maybe_lean")
	return errors


static func load_or_default(path: String = DEFAULT_PATH) -> NpcSocialSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is NpcSocialSettings:
		return loaded as NpcSocialSettings
	GameLogger.warning("config", "npc social settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return NpcSocialSettings.new()
