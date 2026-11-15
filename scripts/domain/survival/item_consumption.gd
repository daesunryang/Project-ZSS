class_name ItemConsumption
extends RefCounted
## Server rule for using up an item (P2-T3 eating and drinking, docs/00
## ADR-010, docs/09 §14.18; P2-T6 bandage, docs/09 §14.21; P2-T7 cure,
## docs/09 §14.22): an online, living player uses up ONE unit of an item it
## carries and the server applies the use effects of the item definition to
## that player.
##
## Effects (ItemDefinition) and when each applies:
##   eating / drinking (consume_*_reduction)  always: hunger / thirst drop,
##       also when they are already 0 (docs/15 P2-122).
##   bandage (treat_bleeding_wound_count)     when at least one wound of the
##       player bleeds: the worst bleeding wounds stop bleeding
##       (SurvivalService.stop_worst_bleeding).
##   cure (cures_infection)                   when the player is infected and
##       the infection is still treatable: it is cleared
##       (SurvivalService.apply_infection_treatment).
## A use is accepted when at least one effect of the item applies now; the
## effects that do not apply are skipped. When none applies the request is
## refused with the reason of the first treatment that cannot be given, in
## the order bandage (`not_bleeding`), cure (`not_infected`, `too_late`), and
## the item is kept: a treatment is never wasted.
##
## All or nothing: every condition is checked first, then the unit leaves
## the inventory (ServerWorld.remove_player_item, replicated by InventoryNet)
## and the effects are applied. A refused request changes neither the item
## nor the player.
##
## No networking and no state here. The caller supplies only who and which
## item; the effect comes from the item definition, never from a client, and
## it is always applied to the player who uses the item.
##
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

const EVENT_ITEM_CONSUMED: String = "item_consumed"
## The item's definition has no use effect.
const REASON_NOT_CONSUMABLE: String = "not_consumable"
## The world has no survival system (composition error).
const REASON_UNAVAILABLE: String = "consumption_unavailable"
## Units used up by one use.
const CONSUMED_QUANTITY: int = 1
## Event value of `infection_cured_from` when no infection was cured.
const NOT_CURED: String = ""


## Uses up one unit of `item_instance_id` for `player_id`.
static func try_consume(world: ServerWorld, player_id: String, item_instance_id: String) -> ActionResult:
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

	# Which effects apply now. Eating has no precondition beyond usable data;
	# a treatment needs something to treat.
	var feeds: bool = definition.lowers_needs()
	if feeds:
		var need_reason: String = survival.check_reduce_needs(player_id, definition.consume_hunger_reduction, definition.consume_thirst_reduction)
		if not need_reason.is_empty():
			return ActionResult.failure(need_reason)
	# Reason of the first treatment that cannot be given.
	var refusal: String = ""
	var bandages: bool = false
	if definition.stops_bleeding():
		var bleeding_reason: String = survival.check_stop_worst_bleeding(player_id, definition.treat_bleeding_wound_count)
		bandages = bleeding_reason.is_empty()
		if not bandages and refusal.is_empty():
			refusal = bleeding_reason
	var cures: bool = false
	if definition.cures_infection:
		var infection_reason: String = survival.check_infection_treatment(player_id)
		cures = infection_reason.is_empty()
		if not cures and refusal.is_empty():
			refusal = infection_reason
	if not feeds and not bandages and not cures:
		return ActionResult.failure(refusal)

	# Commit: everything was checked above, nothing can refuse now.
	var removal: ActionResult = world.remove_player_item(player_id, item_instance_id, CONSUMED_QUANTITY)
	if not removal.ok:
		return ActionResult.failure(removal.reason)
	var hunger_reduced: float = 0.0
	var thirst_reduced: float = 0.0
	if feeds:
		var reduction: ActionResult = survival.reduce_needs(player_id, definition.consume_hunger_reduction, definition.consume_thirst_reduction, item_instance_id)
		if not reduction.ok:
			return _effect_lost(player_id, item_instance_id, reduction.reason)
		hunger_reduced = float(reduction.event.get("hunger_reduced", 0.0))
		thirst_reduced = float(reduction.event.get("thirst_reduced", 0.0))
	var stopped_wound_ids: Array = []
	if bandages:
		var treated: ActionResult = survival.stop_worst_bleeding(player_id, definition.treat_bleeding_wound_count, item_instance_id)
		if not treated.ok:
			return _effect_lost(player_id, item_instance_id, treated.reason)
		stopped_wound_ids = (treated.event.get("wound_ids", []) as Array).duplicate()
	var cured_from: String = NOT_CURED
	if cures:
		var cured: ActionResult = survival.apply_infection_treatment(player_id, item_instance_id)
		if not cured.ok:
			return _effect_lost(player_id, item_instance_id, cured.reason)
		cured_from = str(cured.event.get("from", NOT_CURED))
	var event: Dictionary = {
		"event_type": EVENT_ITEM_CONSUMED,
		"player_id": player_id,
		"item_instance_id": item_instance_id,
		"definition_id": definition.definition_id,
		"remaining_quantity": int(removal.event.get("remaining_quantity", 0)),
		"hunger_reduced": hunger_reduced,
		"thirst_reduced": thirst_reduced,
		"bleeding_stopped_wound_ids": stopped_wound_ids,
		"infection_cured_from": cured_from,
		"world_time": world.clock.world_time_sec,
	}
	GameLogger.info("survival", "item consumed", event)
	return ActionResult.success(event)


## Unreachable while the preflight checks and the effects agree: the unit is
## gone and an effect refused. Logged as an error, reported as a failure.
static func _effect_lost(player_id: String, item_instance_id: String, reason: String) -> ActionResult:
	GameLogger.error("survival", "item used up without effect", {"player_id": player_id, "entity_id": item_instance_id, "reason": reason, "operation": "consume_item"})
	return ActionResult.failure(reason)
