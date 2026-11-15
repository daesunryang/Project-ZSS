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
const PROTOCOL_VERSION: int = 6

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
