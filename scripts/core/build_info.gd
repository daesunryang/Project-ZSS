class_name BuildInfo
extends RefCounted
## Static build/version information for logs, UI and diagnostics.
##
## The game version is read from ProjectSettings `application/config/version`
## so there is exactly one place to bump it.
## PROTOCOL_VERSION is the network protocol revision checked in the join
## handshake. PROVISIONAL (docs/15 P1-3): clients must match it exactly; the
## game version is only logged. Save schema versions live with each saved
## document type (ItemInstance/PlayerState/ServerWorld SCHEMA_VERSION).

## Engine version this project is pinned to (docs/00 ADR-001).
const REQUIRED_ENGINE_MAJOR: int = 4
const REQUIRED_ENGINE_MINOR: int = 7
const REQUIRED_ENGINE_PATCH: int = 2
const REQUIRED_ENGINE_STATUS: String = "stable"
## Network protocol revision. Bump on any RPC signature/semantics change.
## 2: Phase 2 P2-0 (third ENet channel, join snapshot "modules").
## 3: Phase 2 N1 (ZombieNet, SurvivalNet, CombatNet modules: zombie
##    snapshots/events, survival replication, melee attack intent).
## 4: P2-T2 (InventoryNet module: drop intent and its result, world items
##    added, owner inventory items removed/changed).
## 5: P2-T3..T5 (InventoryNet: consume intent and its result; P2-T4: the
##    SurvivalNet owner snapshot / join fragment carry "character_generation",
##    format 2; the pickup result may say "player_dead").
## 6: P2-T6..T8, bumped once for the three tickets. P2-T8 changes the wire:
##    SurvivalNet gets the rest intent and its result (_rpc_request_rest,
##    _rpc_rest_result), the owner snapshot and every status row / join
##    fragment row carry "resting" (format 3), there are public and owner
##    events "player_rest_started" / "player_rest_ended", and pickup, drop,
##    consume and melee results may say "player_resting". P2-T6 / P2-T7 only
##    add result reasons to the consume intent ("not_bleeding",
##    "not_infected", "too_late"); its messages are unchanged.
## 7: P2-T9 (character name and appearance). New module CharacterNet: the
##    creation intent and its result (_rpc_request_create_character,
##    _rpc_create_result), character rows (_rpc_character_rows), the owner's
##    creation state (_rpc_creation_state) and a join fragment. A joined peer
##    may now be without a character: it is in nobody's snapshot, gets a
##    SurvivalNet join fragment without "self", and other peers get
##    _rpc_player_joined for it only when its first character exists. Where
##    creation is required a dead character no longer respawns by itself.
## 8: P2-T10..T12, bumped once for the three tickets. P2-T10 (sleep tuning):
##    the owner event "player_rest_ended" may carry the causes "low_health",
##    "thirst", "hunger" and "infection" (a client of protocol 7 drops such an
##    event), and the rest result may say "cannot_rest_<danger>". No RPC or
##    message format changed in P2-T10. P2-T11 (prone and stealth): new
##    module PostureNet with the wanted-posture intent and its result
##    (_rpc_request_posture, _rpc_posture_result), posture rows to every
##    peer (_rpc_posture_rows) and a join fragment; the melee result may say
##    "player_prone". The rest RPCs of SurvivalNet are unchanged. P2-T12
##    (treating other players): InventoryNet gets the use-on-a-player intent
##    and its result (_rpc_request_use_on, _rpc_use_on_result) and treatment
##    notices to the target and to bystanders (_rpc_treatment_notice). The
##    consume intent is unchanged.
## 9: P2-T14 (handing an item over to another player). InventoryNet gets the
##    hand-over intent and its result (_rpc_request_hand_over,
##    _rpc_hand_over_result) and hand-over notices to the receiver and to
##    bystanders (_rpc_hand_over_notice). The receiver's new or grown stacks
##    arrive through the existing owner-only _rpc_inventory_item_changed. No
##    existing RPC or message format changed.
## 10: P2-T15 (items travel over the ground, docs/00 ADR-021). The three
##    hand-over RPCs of protocol 9 are gone. The drop intent carries a
##    quantity: _rpc_request_drop(request_id, item_instance_id, quantity),
##    0 = the whole stack; a part of a stack reaches the owner as
##    _rpc_inventory_item_changed and everybody as _rpc_world_items_added. A
##    pickup may merge into carried stacks: the owner then gets
##    _rpc_inventory_item_changed for the stacks that grew and
##    _rpc_inventory_item only if the picked-up item still exists.
## 11: P2-T16 (trades between two players, docs/00 ADR-022). New module
##    TradeNet: five intents (_rpc_request_trade, _rpc_request_trade_accept,
##    _rpc_request_trade_cancel, _rpc_request_trade_offer,
##    _rpc_request_trade_confirm) with one result (_rpc_trade_result),
##    session states to the two parties (_rpc_trade_state) and a notice of a
##    completed trade to everybody else (_rpc_trade_notice). The join
##    snapshot has an empty "TradeNet" fragment. No existing RPC or message
##    format changed; both sides of a completed trade get their inventory
##    change through the existing owner-only InventoryNet messages.
## 12: P3-4a (grid structures, docs/00 ADR-024, docs/09 §15.4). New module
##    StructureNet: three intents (_rpc_request_place, _rpc_request_demolish,
##    _rpc_request_door) with one result (_rpc_structure_result), and
##    structures to everybody (_rpc_structure_rows for added or changed
##    structures, _rpc_structures_removed). The join snapshot has a
##    "StructureNet" fragment with every structure the server has in memory.
##    No existing RPC or message format changed.
## 13: P3-2 (replication scope by world cell, docs/09 §15.2). A client is told
##    only about the world items and zombies of the cells around its player.
##    New: InventoryNet._rpc_world_items_removed(item_instance_ids) (the
##    items of a cell the client is no longer told about, one message for
##    many); the zombie wire events "zombie_entered" and "zombie_left"; the
##    join fragments "WorldCellNet" (the map layout: cell size and bounds)
##    and "InterestNet" (empty). Changed meaning: the join snapshot's
##    "world_items" and the ZombieNet join fragment hold the joining peer's
##    cells only; zombie event sequence numbers count per client (the
##    ZombieNet join fragment starts each client at 0); combat event
##    sequences may have holes; a refused pickup reports an unknown id as
##    "item_not_in_world". No existing RPC signature changed.
const PROTOCOL_VERSION: int = 13

const _VERSION_SETTING: String = "application/config/version"
const _NAME_SETTING: String = "application/config/name"
const _UNKNOWN_VERSION: String = "0.0.0"


## Game version string, e.g. "0.0.1".
static func game_version() -> String:
	return str(ProjectSettings.get_setting(_VERSION_SETTING, _UNKNOWN_VERSION))


## Game display name.
static func game_name() -> String:
	return str(ProjectSettings.get_setting(_NAME_SETTING, "LAST HAVEN"))


## Running engine version as "major.minor.patch.status".
static func engine_version_string() -> String:
	var info: Dictionary = Engine.get_version_info()
	return "%d.%d.%d.%s" % [int(info["major"]), int(info["minor"]), int(info["patch"]), str(info["status"])]


## True when the running engine matches the pinned version exactly.
static func is_supported_engine(info: Dictionary = Engine.get_version_info()) -> bool:
	return (
		int(info.get("major", -1)) == REQUIRED_ENGINE_MAJOR
		and int(info.get("minor", -1)) == REQUIRED_ENGINE_MINOR
		and int(info.get("patch", -1)) == REQUIRED_ENGINE_PATCH
		and str(info.get("status", "")) == REQUIRED_ENGINE_STATUS
	)


## True when `version` is a "MAJOR.MINOR.PATCH" string of non-negative integers.
static func is_valid_semver(version: String) -> bool:
	var parts: PackedStringArray = version.split(".")
	if parts.size() != 3:
		return false
	for part: String in parts:
		if part.is_empty() or not part.is_valid_int() or int(part) < 0:
			return false
	return true


## One-line summary used in startup logs.
static func summary() -> String:
	return "%s v%s (engine %s, debug=%s)" % [
		game_name(), game_version(), engine_version_string(), str(OS.is_debug_build())
	]
