class_name ItemConsumption
extends RefCounted
## Server rule for using up an item (P2-T3 eating and drinking, docs/00
## ADR-010, docs/09 §14.18; P2-T6 bandage, docs/09 §14.21; P2-T7 cure,
## docs/09 §14.22; P2-T12 on another player, docs/00 ADR-018, docs/09
## §14.27): an online, living player uses up ONE unit of an item it carries
## and the server applies the use effects of the item definition, to that
## player (try_consume) or to another player close by (try_use_on).
##
## Effects (ItemDefinition) and when each applies:
##   eating / drinking (consume_*_reduction)  always: hunger / thirst drop,
##       also when they are already 0 (docs/15 P2-122).
##   bandage (treat_bleeding_wound_count)     when at least one wound of the
##       treated player bleeds: its worst bleeding wounds stop bleeding
##       (SurvivalService.stop_worst_bleeding).
##   cure (cures_infection)                   when the treated player is
##       infected and the infection is still treatable: it is cleared
##       (SurvivalService.apply_infection_treatment).
## A use is accepted when at least one effect of the item applies now; the
## effects that do not apply are skipped. When none applies the request is
## refused with the reason of the first treatment that cannot be given, in
## the order bandage (`not_bleeding`), cure (`not_infected`, `too_late`), and
## the item is kept: a treatment is never wasted.
##
## All or nothing: every condition is checked first, then the unit leaves
## the user's inventory (ServerWorld.remove_player_item, replicated by
## InventoryNet) and the effects are applied. A refused request changes
## neither the item nor any player.
##
## No networking and no state here. The caller supplies only who, which item
## and (try_use_on) which other player; the effect comes from the item
## definition, positions and conditions from server state, never from a
## client.
##
## Using an item on oneself: try_consume(world, player_id, item_instance_id).
## Success event (JSON-safe):
##   {event_type: "item_consumed", player_id, item_instance_id, definition_id,
##    remaining_quantity (0 = the item is gone), hunger_reduced,
##    thirst_reduced (what was actually taken off),
##    bleeding_stopped_wound_ids: Array of String (worst first, [] = none),
##    infection_cured_from: String (stage name that was cured, "" = none),
##    world_time}
## Failure reasons, in check order: not_online, consumption_unavailable (no
## survival system), unknown_player / player_dead, player_resting (or another
## system's ServerSystem.player_action_block_reason), unknown_item,
## item_not_in_inventory, not_consumable (no use effect), bad_need_amount,
## not_bleeding, not_infected / too_late.
##
## Using an item on another player (P2-T12): try_use_on(world, user_id,
## item_instance_id, target_id). An empty target or the user's own id is a
## use on oneself (try_consume, with its event and reasons). Otherwise only
## what may be given to others is applied to the target: the treatments
## (bandage, cure), and food / drink only when
## GameplaySettings.allow_feeding_others is on. The target does not have to
## agree, may be asleep or prone and is not woken; it must be in the world
## (online, with a character), alive and within GameplaySettings.treat_range_m
## of the user (server positions). The unit is the user's; the effect is the
## target's. Success event (JSON-safe), the fields of "item_consumed" plus
## the target:
##   {event_type: "item_used_on_player", player_id (the user), target_id,
##    item_instance_id, definition_id, remaining_quantity, hunger_reduced,
##    thirst_reduced, bleeding_stopped_wound_ids, infection_cured_from,
##    world_time}
## Failure reasons, in check order: the user and item reasons above up to
## not_consumable, then not_usable_on_others (the item has nothing for
## another player), target_unavailable (unknown, away or without a
## character: one reason, so player ids cannot be probed), target_dead,
## target_too_far, bad_need_amount, and the target's condition: not_bleeding,
## not_infected / too_late. The order matters for what a requester can learn:
## nothing about a target is looked at before the user holds a usable item,
## and the target's condition is looked at last, only next to it.

const EVENT_ITEM_CONSUMED: String = "item_consumed"
## The item's definition has no use effect.
const REASON_NOT_CONSUMABLE: String = "not_consumable"
## The world has no survival system (composition error).
const REASON_UNAVAILABLE: String = "consumption_unavailable"
## Units used up by one use.
const CONSUMED_QUANTITY: int = 1
## Event value of `infection_cured_from` when no infection was cured.
const NOT_CURED: String = ""
## A unit was used on another player (P2-T12, try_use_on).
const EVENT_ITEM_USED_ON_PLAYER: String = "item_used_on_player"
## The target is no player a treatment can reach: unknown, not connected, or
## connected without a character. One reason for all three, so a requester
## cannot probe which player ids exist.
const REASON_TARGET_UNAVAILABLE: String = "target_unavailable"
const REASON_TARGET_DEAD: String = "target_dead"
const REASON_TARGET_TOO_FAR: String = "target_too_far"
## The item has nothing that may be given to another player (food, drink).
const REASON_NOT_USABLE_ON_OTHERS: String = "not_usable_on_others"
## Value of `target_id` that means the user itself.
const NO_TARGET: String = ""
## Refusals that say something about the treated player's condition.
const TARGET_STATE_REFUSALS: PackedStringArray = [
	SurvivalService.REASON_NOT_BLEEDING,
	SurvivalService.REASON_NOT_INFECTED,
	SurvivalService.REASON_TOO_LATE,
]


## Uses up one unit of `item_instance_id` for `player_id`.
static func try_consume(world: ServerWorld, player_id: String, item_instance_id: String) -> ActionResult:
	var checked: ActionResult = _check_user_and_item(world, player_id, item_instance_id)
	if not checked.ok:
		return checked
	var definition: ItemDefinition = world.inventory.definition_of(item_instance_id)
	var survival: SurvivalService = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	return _use(world, survival, player_id, player_id, item_instance_id, definition, definition.lowers_needs())


## Uses up one unit of `item_instance_id` of `user_id` on `target_id`
## (P2-T12; see the header). `target_id` "" or the user's own id is
## try_consume().
static func try_use_on(world: ServerWorld, user_id: String, item_instance_id: String, target_id: String) -> ActionResult:
	if target_id == NO_TARGET or target_id == user_id:
		return try_consume(world, user_id, item_instance_id)
	var checked: ActionResult = _check_user_and_item(world, user_id, item_instance_id)
	if not checked.ok:
		return checked
	var definition: ItemDefinition = world.inventory.definition_of(item_instance_id)
	var survival: SurvivalService = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	# What of this item may be given to another player. Asked before anything
	# about the target: an item with nothing to give says nothing about it.
	var feeds: bool = world.gameplay.allow_feeding_others and definition.lowers_needs()
	if not feeds and not definition.is_treatment():
		return ActionResult.failure(REASON_NOT_USABLE_ON_OTHERS)
	# The target: in the world, alive, close. Server state only.
	var target: PlayerState = world.get_player(target_id)
	if target == null or not world.is_online(target_id) or not survival.has_player(target_id):
		return ActionResult.failure(REASON_TARGET_UNAVAILABLE)
	if not survival.is_alive(target_id):
		return ActionResult.failure(REASON_TARGET_DEAD)
	if world.get_player(user_id).position.distance_to(target.position) > world.gameplay.treat_range_m:
		return ActionResult.failure(REASON_TARGET_TOO_FAR)
	return _use(world, survival, user_id, target_id, item_instance_id, definition, feeds)


## True when `reason` is a refusal that says something about the target's
## condition (nothing to treat). Such a request was a real attempt next to
## the target: the target and bystanders are told that it was made.
static func is_target_state_refusal(reason: String) -> bool:
	return TARGET_STATE_REFUSALS.has(reason)


## The checks every use starts with: the user is in the world, alive and
## able to act, and carries a usable item. Success carries no event.
static func _check_user_and_item(world: ServerWorld, player_id: String, item_instance_id: String) -> ActionResult:
	if not world.is_online(player_id):
		return ActionResult.failure(ServerWorld.REASON_NOT_ONLINE)
	var survival: SurvivalService = world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService
	if survival == null:
		return ActionResult.failure(REASON_UNAVAILABLE)
	if not survival.has_player(player_id):
		return ActionResult.failure(SurvivalService.REASON_UNKNOWN_PLAYER)
	if not survival.is_alive(player_id):
		return ActionResult.failure(SurvivalService.REASON_PLAYER_DEAD)
	# Any other state in which the player cannot handle items (a resting
	# player must get up first, P2-T8).
	var blocked: String = world.player_action_block_reason(player_id)
	if not blocked.is_empty():
		return ActionResult.failure(blocked)
	var player: PlayerState = world.get_player(player_id)
	var item: ItemInstance = world.inventory.get_item(item_instance_id)
	if item == null:
		return ActionResult.failure(InventoryService.REASON_UNKNOWN_ITEM)
	# Ownership before the definition: a requester learns nothing about an
	# item it does not carry.
	if item.location_type != ItemInstance.LOCATION_INVENTORY or item.location_id != player.inventory_id:
		return ActionResult.failure(InventoryService.REASON_NOT_IN_INVENTORY)
	var definition: ItemDefinition = world.inventory.definition_of(item_instance_id)
	if definition == null or not definition.is_consumable():
		return ActionResult.failure(REASON_NOT_CONSUMABLE)
	return ActionResult.success({})


## Decides which effects of the item apply to `treated_id` now, then takes
## the unit from `user_id` and applies them. `feeds`: whether the eating /
## drinking effect is part of this use. `user_id` and `treated_id` are the
## same player for a use on oneself.
static func _use(world: ServerWorld, survival: SurvivalService, user_id: String, treated_id: String, item_instance_id: String, definition: ItemDefinition, feeds: bool) -> ActionResult:
	# Which effects apply now. Eating has no precondition beyond usable data;
	# a treatment needs something to treat.
	if feeds:
		var need_reason: String = survival.check_reduce_needs(treated_id, definition.consume_hunger_reduction, definition.consume_thirst_reduction)
		if not need_reason.is_empty():
			return ActionResult.failure(need_reason)
	# Reason of the first treatment that cannot be given.
	var refusal: String = ""
	var bandages: bool = false
	if definition.stops_bleeding():
		var bleeding_reason: String = survival.check_stop_worst_bleeding(treated_id, definition.treat_bleeding_wound_count)
		bandages = bleeding_reason.is_empty()
		if not bandages and refusal.is_empty():
			refusal = bleeding_reason
	var cures: bool = false
	if definition.cures_infection:
		var infection_reason: String = survival.check_infection_treatment(treated_id)
		cures = infection_reason.is_empty()
		if not cures and refusal.is_empty():
			refusal = infection_reason
	if not feeds and not bandages and not cures:
		return ActionResult.failure(refusal)

	# Commit: everything was checked above, nothing can refuse now.
	var removal: ActionResult = world.remove_player_item(user_id, item_instance_id, CONSUMED_QUANTITY)
	if not removal.ok:
		return ActionResult.failure(removal.reason)
	var hunger_reduced: float = 0.0
	var thirst_reduced: float = 0.0
	if feeds:
		var reduction: ActionResult = survival.reduce_needs(treated_id, definition.consume_hunger_reduction, definition.consume_thirst_reduction, item_instance_id)
		if not reduction.ok:
			return _effect_lost(user_id, item_instance_id, reduction.reason)
		hunger_reduced = float(reduction.event.get("hunger_reduced", 0.0))
		thirst_reduced = float(reduction.event.get("thirst_reduced", 0.0))
	var stopped_wound_ids: Array = []
	if bandages:
		var treated: ActionResult = survival.stop_worst_bleeding(treated_id, definition.treat_bleeding_wound_count, item_instance_id)
		if not treated.ok:
			return _effect_lost(user_id, item_instance_id, treated.reason)
		stopped_wound_ids = (treated.event.get("wound_ids", []) as Array).duplicate()
	var cured_from: String = NOT_CURED
	if cures:
		var cured: ActionResult = survival.apply_infection_treatment(treated_id, item_instance_id)
		if not cured.ok:
			return _effect_lost(user_id, item_instance_id, cured.reason)
		cured_from = str(cured.event.get("from", NOT_CURED))
	var on_other: bool = treated_id != user_id
	var event: Dictionary = {
		"event_type": EVENT_ITEM_USED_ON_PLAYER if on_other else EVENT_ITEM_CONSUMED,
		"player_id": user_id,
		"item_instance_id": item_instance_id,
		"definition_id": definition.definition_id,
		"remaining_quantity": int(removal.event.get("remaining_quantity", 0)),
		"hunger_reduced": hunger_reduced,
		"thirst_reduced": thirst_reduced,
		"bleeding_stopped_wound_ids": stopped_wound_ids,
		"infection_cured_from": cured_from,
		"world_time": world.clock.world_time_sec,
	}
	if on_other:
		event["target_id"] = treated_id
	GameLogger.info("survival", "item used on another player" if on_other else "item consumed", event)
	return ActionResult.success(event)


## Unreachable while the preflight checks and the effects agree: the unit is
## gone and an effect refused. Logged as an error, reported as a failure.
static func _effect_lost(player_id: String, item_instance_id: String, reason: String) -> ActionResult:
	GameLogger.error("survival", "item used up without effect", {"player_id": player_id, "entity_id": item_instance_id, "reason": reason, "operation": "consume_item"})
	return ActionResult.failure(reason)
