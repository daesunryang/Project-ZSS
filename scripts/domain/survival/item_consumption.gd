class_name ItemConsumption
extends RefCounted
## Server rule for eating and drinking (P2-T3, docs/00 ADR-010, docs/09
## §14.18): an online, living player uses up ONE unit of a consumable item it
## carries and its hunger / thirst drop by the amounts in the item definition
## (ItemDefinition.consume_*_reduction).
##
## All or nothing: every condition of both halves is checked first, then the
## unit leaves the inventory (ServerWorld.remove_player_item, replicated by
## InventoryNet) and the needs are lowered (SurvivalService.reduce_needs).
## A refused request changes neither the item nor the needs.
##
## No networking and no state here. The caller supplies only who and which
## item; the effect comes from the item definition, never from a client.
##
## Success event (JSON-safe):
##   {event_type: "item_consumed", player_id, item_instance_id, definition_id,
##    remaining_quantity (0 = the item is gone), hunger_reduced,
##    thirst_reduced (what was actually taken off), world_time}
## Failure reasons, in check order: not_online, consumption_unavailable (no
## survival system), unknown_player / player_dead, unknown_item,
## item_not_in_inventory, not_consumable, bad_need_amount.

const EVENT_ITEM_CONSUMED: String = "item_consumed"
## The item's definition has no consumption effect.
const REASON_NOT_CONSUMABLE: String = "not_consumable"
## The world has no survival system (composition error).
const REASON_UNAVAILABLE: String = "consumption_unavailable"
## Units used up by one consumption.
const CONSUMED_QUANTITY: int = 1


## Consumes one unit of `item_instance_id` for `player_id`.
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
	var reason: String = survival.check_reduce_needs(player_id, definition.consume_hunger_reduction, definition.consume_thirst_reduction)
	if not reason.is_empty():
		return ActionResult.failure(reason)

	# Commit: both halves were checked above, neither can refuse now.
	var removal: ActionResult = world.remove_player_item(player_id, item_instance_id, CONSUMED_QUANTITY)
	if not removal.ok:
		return ActionResult.failure(removal.reason)
	var reduction: ActionResult = survival.reduce_needs(player_id, definition.consume_hunger_reduction, definition.consume_thirst_reduction, item_instance_id)
	if not reduction.ok:
		# Unreachable while check_reduce_needs and reduce_needs agree.
		GameLogger.error("survival", "item used up without effect", {"player_id": player_id, "entity_id": item_instance_id, "reason": reduction.reason, "operation": "consume_item"})
		return ActionResult.failure(reduction.reason)
	var event: Dictionary = {
		"event_type": EVENT_ITEM_CONSUMED,
		"player_id": player_id,
		"item_instance_id": item_instance_id,
		"definition_id": definition.definition_id,
		"remaining_quantity": int(removal.event.get("remaining_quantity", 0)),
		"hunger_reduced": float(reduction.event.get("hunger_reduced", 0.0)),
		"thirst_reduced": float(reduction.event.get("thirst_reduced", 0.0)),
		"world_time": world.clock.world_time_sec,
	}
	GameLogger.info("survival", "item consumed", event)
	return ActionResult.success(event)
