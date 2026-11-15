class_name TradeSession
extends RefCounted
## One trade between two players (P2-T16, docs/09 §14.30): a request that is
## waiting for an answer, or an open session with both offers and both
## confirmations. Plain server-side state owned by TradeService; never
## saved (a trade does not survive a restart or a disconnect).

## The requester asked, the target has not answered yet.
const PHASE_REQUESTED: String = "requested"
## The target accepted: both sides put offers together and confirm.
const PHASE_OPEN: String = "open"
## Over: completed (the exchange happened) or cancelled (nothing moved).
const PHASE_CLOSED: String = "closed"
const OUTCOME_NONE: String = ""
const OUTCOME_COMPLETED: String = "completed"
const OUTCOME_CANCELLED: String = "cancelled"
## Keys of one offer entry.
const KEY_ITEM_ID: String = "item_instance_id"
const KEY_DEFINITION_ID: String = "definition_id"
const KEY_QUANTITY: String = "quantity"

## Unique within one server run, starting at 1.
var session_id: int = 0
## Who asked whom.
var requester_id: String = ""
var target_id: String = ""
var phase: String = PHASE_REQUESTED
## Counts the changes of either offer. A confirmation names the revision it
## saw, so nobody confirms an offer that changed on the way.
var revision: int = 0
## player_id -> Array of {item_instance_id, definition_id, quantity}, in the
## order the stacks were put into the offer.
var offers: Dictionary[String, Array] = {}
## player_id -> has confirmed the current offers.
var confirmed: Dictionary[String, bool] = {}
## Action time (real seconds) of the request and of the last accepted action.
var created_at: float = 0.0
var last_activity_at: float = 0.0
## Set when the session is closed.
var outcome: String = OUTCOME_NONE
## Why it was cancelled (a TradeService CAUSE_* code), "" otherwise.
var cause: String = ""
## Who caused the end ("" = nobody in particular: distance, a timeout, the
## completed exchange).
var by_player_id: String = ""


func _init(id: int, requester: String, target: String, now: float) -> void:
	session_id = id
	requester_id = requester
	target_id = target
	created_at = now
	last_activity_at = now
	offers[requester] = []
	offers[target] = []
	confirmed[requester] = false
	confirmed[target] = false


func has_party(player_id: String) -> bool:
	return player_id == requester_id or player_id == target_id


## The other party of `player_id` ("" for a player that is no party).
func other_of(player_id: String) -> String:
	if player_id == requester_id:
		return target_id
	return requester_id if player_id == target_id else ""


## Index of an item in a player's offer, -1 when it is not offered.
func offer_index(player_id: String, item_instance_id: String) -> int:
	var offer: Array = offers.get(player_id, [])
	for index: int in range(offer.size()):
		if str((offer[index] as Dictionary)[KEY_ITEM_ID]) == item_instance_id:
			return index
	return -1


## True when neither side offers anything.
func is_empty() -> bool:
	return (offers[requester_id] as Array).is_empty() and (offers[target_id] as Array).is_empty()


func both_confirmed() -> bool:
	return confirmed[requester_id] and confirmed[target_id]


func clear_confirmations() -> void:
	confirmed[requester_id] = false
	confirmed[target_id] = false


## A player's offer as exchange_items takes it: [{item_instance_id, quantity}].
func exchange_offer(player_id: String) -> Array:
	var entries: Array = []
	for entry: Dictionary in offers.get(player_id, []):
		entries.append({InventoryService.OFFER_ITEM_ID: str(entry[KEY_ITEM_ID]), InventoryService.OFFER_QUANTITY: int(entry[KEY_QUANTITY])})
	return entries


## Everything about the session as plain data (JSON-safe; a deep copy).
func to_dict() -> Dictionary:
	return {
		"session_id": session_id,
		"requester_id": requester_id,
		"target_id": target_id,
		"phase": phase,
		"revision": revision,
		"offers": {
			requester_id: (offers[requester_id] as Array).duplicate(true),
			target_id: (offers[target_id] as Array).duplicate(true),
		},
		"confirmed": {requester_id: confirmed[requester_id], target_id: confirmed[target_id]},
		"outcome": outcome,
		"cause": cause,
		"by_player_id": by_player_id,
	}
