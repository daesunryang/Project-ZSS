class_name CharacterNetModule
extends NetModule
## Character creation intent and replication of names and appearance
## (P2-T9, docs/00 ADR-015, docs/09 §14.24). Network only: every rule is in
## ServerWorld.create_character / CharacterRules / SurvivalService.
##
## RPC table (channel 0 = reliable ordered):
##   client -> server  _rpc_request_create_character(request_id:int, name:String, appearance:Dictionary)  reliable, ch0
##   server -> owner   _rpc_create_result(request_id:int, ok:bool, reason:String)                         reliable, ch0
##   server -> clients _rpc_character_rows(rows:Array[Dictionary])                                        reliable, ch0
##   server -> owner   _rpc_creation_state(can_create:bool, reason:String)                                reliable, ch0
##
## Request: "I want a character with this name and this appearance". There
## is no player argument: the actor is the player of the sending peer.
## `appearance` is {slot_id: option_id}; colours are palette ids, never RGB.
## Server checks, in order: joined (`not_joined`), argument types
## (`bad_type`), request id >= 0 (`bad_sequence`), size (`payload_too_large`:
## a name longer than the protocol limit, more entries than the protocol
## allows, an id longer than an id can be), request rate (`rate_limited`),
## then ServerWorld.create_character: the player's state (`character_alive`,
## `respawn_wait`), the name (`name_empty`, `name_too_short`, `name_too_long`,
## `name_bad_characters`, `name_banned`), the appearance
## (`appearance_too_large`, `unknown_appearance_slot`,
## `unknown_appearance_option`) and `name_taken`. Every refusal is counted
## (NetworkService.rejected_intent_count) and changes nothing. The result
## goes to the requester only, for every request of a joined peer whose
## request id is usable (int >= 0); `reason` is "" exactly when ok.
##
## Replication (docs/00 ADR-009: a name and an appearance are what anybody
## looking at a character sees, so they are public):
##   - Every joined peer gets a row {player_id, name, appearance,
##     character_generation} for every player in the world: in the join
##     fragment, when a player enters the world, and when a player's next
##     character starts (created by request, or started by the server where
##     creation is not required: the module compares generations every
##     server tick). The generation is the real one for the owner
##     and 0 for everybody else unless
##     CharacterSettings.share_character_generation is on.
##   - A player without a character is not in the world and appears in no
##     row. A joined peer without a character still receives the rows of the
##     others.
##   - Each peer is told, for itself only, whether it may create a character
##     now (`_rpc_creation_state`), in the join fragment and whenever that
##     changes (checked every server tick: the wait after a death ends by
##     time).
##   - An accepted request is replicated before its result is sent (same
##     ordered channel): rows, then the requester's creation state, then the
##     result. The survival side of a new character after a death
##     ("player_respawned", alive again) follows with SurvivalNet's next tick.
##
## Saving: an accepted creation saves the world before the result is sent
## (CharacterSettings.save_after_create).
##
## Client surface (presentation): request_create_character(), the
## `create_result` signal, the mirror `client_state`, and set_auto_create()
## for clients that have no creation screen (headless, `--character-name=`).

## Client: answer to one of this client's own creation requests.
signal create_result(request_id: int, ok: bool, reason: String)

const MODULE_NAME: String = "CharacterNet"
## Join fragment format (same value as ClientCharacterState).
const SCHEMA_VERSION: int = 1
## Intent name in rejection logs.
const INTENT_CREATE: String = "create_character"
## Returned by request_create_character() when nothing was sent.
const NO_REQUEST: int = 0
## Longest reason code a client accepts.
const REASON_MAX_LENGTH: int = ClientCharacterState.REASON_MAX_LENGTH
## Protocol limit on the rows of one message (a server never has more
## players than this).
const MAX_ROWS_PER_MESSAGE: int = ClientCharacterState.MAX_ROWS_PER_MESSAGE
## The request is bigger than any valid request can be.
const REASON_PAYLOAD_TOO_LARGE: String = "payload_too_large"
## Save reason (logs only).
const SAVE_REASON_CREATE: String = "character_created"

var client_state: ClientCharacterState
## Client: results from the server that failed validation.
var rejected_payload_count: int = 0

var _settings: CharacterSettings
var _catalog: AppearanceCatalog
# --- server state ---
var _world: ServerWorld = null
var _limiter: RateLimiter = null
## player_id -> the creation block reason last sent to that player's peer.
var _sent_creation_reasons: Dictionary[String, String] = {}
## player_id -> the character generation of the row last sent to everybody.
var _sent_generations: Dictionary[String, int] = {}
# --- client state ---
var _last_request_id: int = NO_REQUEST
## Client without a creation screen: the character to create whenever the
## server allows it ("" = off).
var _auto_name: String = ""
var _auto_appearance: Dictionary = {}
## Request id of the automatic request that is waiting for its answer.
var _auto_request_id: int = NO_REQUEST


func _init(settings: CharacterSettings, catalog: AppearanceCatalog) -> void:
	name = MODULE_NAME
	_settings = settings
	_catalog = catalog
	client_state = ClientCharacterState.new(settings, catalog)
	client_state.creation_state_changed.connect(_on_creation_state_changed)


func _ready() -> void:
	if network != null and not network.player_left.is_connected(_on_network_player_left):
		network.player_left.connect(_on_network_player_left)


## The rules this module was built with (name rules + appearance data): the
## creation screen builds its widgets from them and checks names with them.
func character_rules() -> CharacterRules:
	return CharacterRules.new(_settings, _catalog)


# ------------------------------------------------------------ pure rules

## "" when the arguments of a creation request are usable, otherwise a
## reason code. Types first, so wrongly typed input never reaches a
## conversion; then the sizes, so nothing huge reaches the rules. The name
## rules and the appearance ids are checked by ServerWorld.create_character.
static func validate_create_request(request_id: Variant, character_name: Variant, appearance: Variant) -> String:
	if typeof(request_id) != TYPE_INT or typeof(character_name) != TYPE_STRING or typeof(appearance) != TYPE_DICTIONARY:
		return IntentValidator.REASON_BAD_TYPE
	if int(request_id) < 0:
		return IntentValidator.REASON_BAD_SEQUENCE
	var selection: Dictionary = appearance
	if (character_name as String).length() > CharacterNameRules.HARD_MAX_LENGTH or selection.size() > AppearanceCatalog.MAX_SLOTS:
		return REASON_PAYLOAD_TOO_LARGE
	for key: Variant in selection:
		var value: Variant = selection[key]
		if typeof(key) != TYPE_STRING or typeof(value) != TYPE_STRING:
			return IntentValidator.REASON_BAD_TYPE
		if (key as String).length() > AppearanceSlot.ID_MAX_LENGTH or (value as String).length() > AppearanceSlot.ID_MAX_LENGTH:
			return REASON_PAYLOAD_TOO_LARGE
	return ""


# ------------------------------------------------------------ NetModule hooks

func on_server_started(world: ServerWorld) -> void:
	_world = world
	_limiter = RateLimiter.new(_settings.create_intent_rate_per_sec, _settings.create_intent_burst)
	_sent_creation_reasons.clear()
	_sent_generations.clear()


## A player is in the world now (joined with a character, or created its
## first one): everybody learns its name and appearance. The player's own
## peer is included: after a first creation it has not seen its row yet.
func on_player_joined(_peer_id: int, player_id: String) -> void:
	_send_row_to_everybody(player_id)


func on_player_left(peer_id: int, player_id: String) -> void:
	_sent_creation_reasons.erase(player_id)
	_sent_generations.erase(player_id)
	if _limiter != null:
		_limiter.forget(peer_id)


func build_join_fragment(player_id: String) -> Dictionary:
	if _world == null:
		return {}
	var rows: Array[Dictionary] = []
	for online_id: String in _world.online_player_ids():
		var row: Dictionary = _make_row(online_id, player_id)
		if not row.is_empty():
			rows.append(row)
	var reason: String = _world.character_creation_block_reason(player_id)
	_sent_creation_reasons[player_id] = reason
	return {
		"schema_version": SCHEMA_VERSION,
		"characters": rows,
		"self": {ClientCharacterState.KEY_CAN_CREATE: reason.is_empty(), ClientCharacterState.KEY_REASON: reason},
	}


func apply_join_fragment(fragment: Dictionary) -> void:
	_last_request_id = NO_REQUEST
	_auto_request_id = NO_REQUEST
	client_state.apply_join(network.client_state.local_player_id, fragment)


## Server: tells every peer whose creation state changed (a character died,
## the wait after a death ended, a character was created), and everybody
## about a character that started without a request (the next character of
## a dead player where creation is not required).
func server_physics(_delta: float) -> void:
	if _world == null:
		return
	for player_id: String in _world.online_player_ids():
		var state: PlayerState = _world.get_player(player_id)
		if state.has_character() and _sent_generations.get(player_id, 0) != state.character_generation:
			_send_row_to_everybody(player_id)
	for peer_id: int in network.joined_peers():
		_send_creation_state_if_changed(peer_id, network.player_of_peer(peer_id))


# ------------------------------------------------------------ server side

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_request_create_character(request_id: Variant, character_name: Variant, appearance: Variant) -> void:
	if network == null or not network.is_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# The actor is whoever owns the sending peer, never an argument.
	var player_id: String = network.sender_player_id()
	if player_id.is_empty():
		network.reject_intent(peer_id, INTENT_CREATE, NetworkService.NOT_JOINED)
		return
	var reason: String = validate_create_request(request_id, character_name, appearance)
	if not reason.is_empty():
		network.reject_intent(peer_id, INTENT_CREATE, reason, player_id)
		if typeof(request_id) == TYPE_INT and int(request_id) >= 0:
			_send_result(peer_id, int(request_id), false, reason)
		return
	if not _limiter.allow(peer_id, Time.get_ticks_msec()):
		network.reject_intent(peer_id, INTENT_CREATE, NetworkService.RATE_LIMITED, player_id)
		_send_result(peer_id, int(request_id), false, NetworkService.RATE_LIMITED)
		return
	var was_in_world: bool = _world.is_online(player_id)
	var result: ActionResult = _world.create_character(player_id, character_name, appearance)
	if not result.ok:
		# Refusals by the rules are normal play (a name that is too short, a
		# request while the wait still runs): counted, not logged as warnings.
		network.count_rejection(result.reason)
		_send_result(peer_id, int(request_id), false, result.reason)
		return
	# Replicate first, so everybody learns the character before the requester
	# gets the answer (same ordered channel).
	if was_in_world:
		_send_row_to_everybody(player_id)
	else:
		# First character: the player enters the world. NetworkService tells
		# every peer and runs the module hooks (this module's on_player_joined
		# sends the row, SurvivalNet the public status).
		network.announce_player_entered(player_id)
	_send_creation_state_if_changed(peer_id, player_id)
	if _settings.save_after_create:
		network.persist(SAVE_REASON_CREATE)
	_send_result(peer_id, int(request_id), true, "")
	GameLogger.info("net", "character created", {"peer_id": peer_id, "player_id": player_id, "request_id": int(request_id), "character_generation": int(result.event.get("character_generation", 0)), "first_character": bool(result.event.get("first_character", false))})


## Row of `player_id` as `viewer_id` may see it ({} when that player has no
## character). The server holds its own output to the rule its clients apply.
func _make_row(player_id: String, viewer_id: String) -> Dictionary:
	var state: PlayerState = _world.get_player(player_id)
	if state == null or not state.has_character():
		return {}
	var shared: bool = viewer_id == player_id or _settings.share_character_generation
	return {
		ClientCharacterState.KEY_PLAYER_ID: player_id,
		ClientCharacterState.KEY_NAME: state.character.name,
		ClientCharacterState.KEY_APPEARANCE: state.character.appearance.duplicate(),
		ClientCharacterState.KEY_GENERATION: state.character_generation if shared else ClientCharacterState.GENERATION_NOT_SHARED,
	}


func _send_row_to_everybody(player_id: String) -> void:
	if _world == null:
		return
	var state: PlayerState = _world.get_player(player_id)
	if state == null or not state.has_character():
		return
	_sent_generations[player_id] = state.character_generation
	for peer_id: int in network.joined_peers():
		if not network.can_send_to(peer_id):
			continue
		var row: Dictionary = _make_row(player_id, network.player_of_peer(peer_id))
		if not row.is_empty():
			_rpc_character_rows.rpc_id(peer_id, [row])


func _send_creation_state_if_changed(peer_id: int, player_id: String) -> void:
	if player_id.is_empty():
		return
	var reason: String = _world.character_creation_block_reason(player_id)
	if _sent_creation_reasons.get(player_id, null) == reason:
		return
	_sent_creation_reasons[player_id] = reason
	if network.can_send_to(peer_id):
		_rpc_creation_state.rpc_id(peer_id, reason.is_empty(), reason)


func _send_result(peer_id: int, request_id: int, ok: bool, reason: String) -> void:
	if network.can_send_to(peer_id):
		_rpc_create_result.rpc_id(peer_id, request_id, ok, reason)


func _on_network_player_left(player_id: String) -> void:
	if network != null and network.is_client():
		client_state.remove_player(player_id)


# ------------------------------------------------------------ client side

## Asks the server to create the local player's character. Returns the
## request id the `create_result` signal will carry, or NO_REQUEST when
## nothing was sent (not a joined client). Nothing is decided here.
func request_create_character(character_name: String, appearance: Dictionary) -> int:
	if network == null or not network.is_client() or network.client_state.local_player_id.is_empty():
		return NO_REQUEST
	_last_request_id += 1
	send_raw_create_request(_last_request_id, character_name, appearance)
	return _last_request_id


## Sends an arbitrary request without any client-side check (tests:
## malformed or premature input through the real RPC path).
func send_raw_create_request(request_id: Variant, character_name: Variant, appearance: Variant) -> void:
	if network != null and network.is_client():
		_rpc_request_create_character.rpc_id(NetworkService.SERVER_PEER_ID, request_id, character_name, appearance)


## Client without a creation screen (headless clients, `--character-name=`):
## from now on this character is requested whenever the server says the
## local player may create one: after the join, and after every death once
## the wait is over. `appearance` may name only some slots (the rest is the
## default). A request the server refuses turns this off again (logged), so
## a bad name cannot become a request loop. Call before the client joins.
func set_auto_create(character_name: String, appearance: Dictionary = {}) -> void:
	_auto_name = character_name
	_auto_appearance = appearance.duplicate()
	_auto_request_id = NO_REQUEST
	if client_state.can_create_character():
		_send_auto_request()


## True while set_auto_create() is in effect.
func is_auto_create_enabled() -> bool:
	return not _auto_name.is_empty()


func _on_creation_state_changed(can_create: bool, _reason: String) -> void:
	if can_create and is_auto_create_enabled():
		_send_auto_request()


func _send_auto_request() -> void:
	if _auto_request_id != NO_REQUEST:
		return  # still waiting for the answer to the last one
	_auto_request_id = request_create_character(_auto_name, _auto_appearance)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_create_result(request_id: Variant, ok: Variant, reason: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	if typeof(request_id) != TYPE_INT or typeof(ok) != TYPE_BOOL or typeof(reason) != TYPE_STRING:
		_reject_result()
		return
	var reason_code: String = reason
	# "" exactly when the request was accepted.
	if int(request_id) < 0 or reason_code.length() > REASON_MAX_LENGTH or bool(ok) != reason_code.is_empty():
		_reject_result()
		return
	if int(request_id) == _auto_request_id:
		_auto_request_id = NO_REQUEST
		if bool(ok):
			GameLogger.info("character_net", "character created without a creation screen", {"player_id": network.client_state.local_player_id, "character_name": _auto_name})
		else:
			GameLogger.error("character_net", "automatic character creation refused; turned off", {"player_id": network.client_state.local_player_id, "reason": reason_code, "operation": "auto_create"})
			_auto_name = ""
	create_result.emit(int(request_id), bool(ok), reason_code)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_character_rows(rows: Variant) -> void:
	if network == null or not network.is_from_server() or typeof(rows) != TYPE_ARRAY:
		return
	client_state.apply_rows(rows as Array)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_creation_state(can_create: Variant, reason: Variant) -> void:
	if network == null or not network.is_from_server():
		return
	client_state.apply_creation_state(can_create, reason)


func _reject_result() -> void:
	rejected_payload_count += 1
	GameLogger.warning("character_net", "creation result dropped", {"module": MODULE_NAME, "operation": "apply_payload"})
