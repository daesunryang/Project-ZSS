class_name CompositionConfig
extends RefCounted
## Settings bundle used by ServerComposition to build a ServerWorld and its
## systems. Production uses from_defaults(); tests replace individual
## resources before building (e.g. config.gameplay = GameplaySettings.new()).
## Feature bundles add their own settings fields here only together with
## their composition line (docs/09 §14.5).

var gameplay: GameplaySettings
var catalog: ItemCatalog
var clock: WorldClockSettings
var dev_seed: DevWorldSeed
## Phase 2-B (survival).
var survival: SurvivalSettings


## Loads every settings resource from res://data/tuning and the item catalog.
static func from_defaults() -> CompositionConfig:
	var config: CompositionConfig = CompositionConfig.new()
	config.gameplay = GameplaySettings.load_or_default()
	config.catalog = ItemCatalog.load_directory()
	config.clock = WorldClockSettings.load_or_default()
	config.dev_seed = DevWorldSeed.load_or_default()
	config.survival = SurvivalSettings.load_or_default()
	return config


## Collects validation errors of all contained settings.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if gameplay == null or catalog == null or clock == null or dev_seed == null or survival == null:
		errors.append("composition config is incomplete")
		return errors
	errors.append_array(gameplay.validate())
	errors.append_array(clock.validate())
	errors.append_array(dev_seed.validate())
	errors.append_array(survival.validate())
	return errors
