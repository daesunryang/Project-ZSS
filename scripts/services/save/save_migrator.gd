class_name SaveMigrator
extends RefCounted
## Upgrades saved documents one schema_version step at a time (docs/10 §6).
##
## `migrations[N]` is a Callable(Dictionary) -> Dictionary converting a
## version-N document into version N+1 (it must set schema_version itself).
## Documents newer than `current_version` are rejected (no downgrade).

const KEY_SCHEMA_VERSION: String = "schema_version"

var current_version: int
var last_error: String = ""
var _migrations: Dictionary[int, Callable] = {}


func _init(version: int, migrations: Dictionary[int, Callable] = {}) -> void:
	current_version = version
	_migrations = migrations


## Returns the migrated document, or {} on failure (see `last_error`).
## The input dictionary is never modified.
func migrate(document: Dictionary) -> Dictionary:
	last_error = ""
	var raw_version: Variant = document.get(KEY_SCHEMA_VERSION, null)
	if raw_version == null or not ItemInstance.is_integer_value(raw_version):
		last_error = "missing or non-integer schema_version"
		return {}
	var version: int = int(raw_version)
	if version > current_version:
		last_error = "schema_version %d is newer than supported %d" % [version, current_version]
		return {}
	if version < 1:
		last_error = "schema_version must be >= 1"
		return {}
	var result: Dictionary = document.duplicate(true)
	while version < current_version:
		if not _migrations.has(version):
			last_error = "no migration from schema_version %d" % version
			return {}
		result = _migrations[version].call(result)
		var next_version: Variant = result.get(KEY_SCHEMA_VERSION, null)
		if next_version == null or int(next_version) != version + 1:
			last_error = "migration from %d did not produce %d" % [version, version + 1]
			return {}
		version += 1
	result[KEY_SCHEMA_VERSION] = current_version
	return result
