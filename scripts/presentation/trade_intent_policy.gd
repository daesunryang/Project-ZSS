class_name TradeIntentPolicy
extends RefCounted
## Pure client-side choice of what the trade keys ask for (P2-T16, docs/09
## §14.30), from the mirrored session state. It only decides which intent to
## send and with which numbers; whether the trade goes on is decided by the
## server.
##
## There are five keys. Two of them mean different things in different
## states of the session, so the player's hands stay on the same keys:
##   request key   ask the player the camera looks at (no session only)
##   accept key    accept a request addressed to me; in a session confirm
##                 the offers, or take my confirmation back
##   decline key   decline a request, take my own request back, cancel the
##                 session
##   offer keys    more / fewer units of the selected stack in my offer

## What the accept key means in the current state.
enum AcceptAction { NONE, ACCEPT, CONFIRM, UNCONFIRM }
## What the decline key means in the current state.
enum DeclineAction { NONE, DECLINE, WITHDRAW, CANCEL }
## Returned by offer_quantity_after when there is nothing to ask for. Not a
## quantity the server accepts.
const NO_CHANGE: int = -1
## Phase of "the local player is in no request and no session".
const NO_SESSION: String = ""


## True when the request key may ask somebody: the local player is in no
## request and no session (`phase` is the mirror's, "" = none).
static func can_request(phase: String) -> bool:
	return phase == NO_SESSION


## What the accept key asks for: accept a request that was addressed to me
## (never my own), confirm the offers of an open session, or take my
## confirmation back when I have confirmed.
static func accept_action(phase: String, is_requester: bool, my_confirmed: bool) -> AcceptAction:
	match phase:
		TradeSession.PHASE_REQUESTED:
			return AcceptAction.NONE if is_requester else AcceptAction.ACCEPT
		TradeSession.PHASE_OPEN:
			return AcceptAction.UNCONFIRM if my_confirmed else AcceptAction.CONFIRM
	return AcceptAction.NONE


## What the decline key asks for: decline a request addressed to me, take my
## own request back, or cancel an open session.
static func decline_action(phase: String, is_requester: bool) -> DeclineAction:
	match phase:
		TradeSession.PHASE_REQUESTED:
			return DeclineAction.WITHDRAW if is_requester else DeclineAction.DECLINE
		TradeSession.PHASE_OPEN:
			return DeclineAction.CANCEL
	return DeclineAction.NONE


## The quantity an offer key asks to offer of the stack `item_instance_id`:
## what the mirrored own offer (`my_offer`) holds of it, changed by `delta`
## units, kept between 0 (out of the offer) and what the mirrored inventory
## says the stack holds. NO_CHANGE when that is what is offered already
## (also: the stack is neither carried nor offered). A stack that is
## offered but not carried any more can only come out. The server checks
## the quantity against its own stack.
static func offer_quantity_after(inventory: Array[Dictionary], my_offer: Array, item_instance_id: String, delta: int) -> int:
	var offered: int = 0
	for entry: Variant in my_offer:
		if typeof(entry) != TYPE_DICTIONARY or typeof((entry as Dictionary).get("item_instance_id", null)) != TYPE_STRING:
			continue
		var quantity: Variant = (entry as Dictionary).get("quantity", null)
		if str((entry as Dictionary)["item_instance_id"]) == item_instance_id and ItemInstance.is_integer_value(quantity):
			offered = maxi(int(quantity), 0)
	var held: int = 0
	for row: Dictionary in inventory:
		var row_quantity: int = InventorySelectionPolicy.quantity_of_row(row)
		if row_quantity >= 1 and str(row["item_instance_id"]) == item_instance_id:
			held = row_quantity
	var wanted: int = clampi(offered + delta, 0, held)
	return NO_CHANGE if wanted == offered else wanted
