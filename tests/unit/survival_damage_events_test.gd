extends TestCase
## Time-based survival damage (bleeding, starvation, dehydration, infection)
## is applied every tick, but its events are batched per player so a bleeding
## player does not produce one reliable RPC and one log line per server tick
## (docs/15 P2-88). Regression test for the flood found by the Phase 2
## acceptance scenario.

const WORLD: String = "survival_damage_events_test_world"
const TICK_SEC: float = 1.0 / 60.0
const EPSILON: float = 0.000001

var _settings: SurvivalSettings = null


func before_each() -> void:
	GameLogger.set_capture(true)
	_settings = SurvivalSettings.new()
	# Only bleeding changes health in these tests.
	_settings.health_recovery_per_world_sec = 0.0
	_settings.wound_recovery_per_world_sec = 0.0


func after_each() -> void:
	GameLogger.set_capture(false)


func _world() -> ServerWorld:
	var config: CompositionConfig = CompositionConfig.from_defaults()
	config.survival = _settings
	# from_defaults() returns cached, shared resources: never mutate them.
	config.zombie = ZombieSettings.new()
	config.zombie.dev_spawn_count = 0
	return ServerComposition.create_world(WORLD, config)


func _survival(world: ServerWorld) -> SurvivalService:
	return world.get_system(SurvivalService.SYSTEM_ID) as SurvivalService


## Joins alice and gives her one bleeding torso laceration. Returns her id.
func _bleeding_player(world: ServerWorld) -> String:
	var alice: PlayerState = world.join("alice")
	var survival: SurvivalService = _survival(world)
	var hit: ActionResult = survival.apply_damage(alice.player_id, DamageInput.create("z", BodyPart.Part.TORSO, Wound.Type.LACERATION, 30.0))
	assert_true(hit.ok, hit.reason)
	assert_true(survival.get_vitals(alice.player_id).injuries[0].is_bleeding, "the wound bleeds")
	survival.drain_events()
	return alice.player_id


func _damage_events(events: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in events:
		if event["event_type"] == SurvivalService.EVENT_PLAYER_SURVIVAL_DAMAGE:
			result.append(event)
	return result


func _total_damage(events: Array[Dictionary]) -> float:
	var total: float = 0.0
	for event: Dictionary in events:
		total += float(event["damage"])
	return total


func test_bleeding_damage_events_are_batched_per_interval() -> void:
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var player_id: String = _bleeding_player(world)
	var health_before: float = survival.get_vitals(player_id).health
	var ticks: int = 180  # 3 world seconds at 60 Hz
	for _tick: int in ticks:
		world.step_systems(TICK_SEC)
	var events: Array[Dictionary] = _damage_events(survival.drain_events())
	var lost: float = health_before - survival.get_vitals(player_id).health
	assert_true(lost > 0.0, "bleeding still drains health every tick")
	assert_true(events.size() >= 2 and events.size() <= 3, "about one event per world second, not %d for %d ticks" % [events.size(), ticks])
	var previous_health: float = health_before
	for event: Dictionary in events:
		assert_eq(event["cause"], SurvivalService.CAUSE_BLEEDING)
		assert_true(float(event["health_after"]) < previous_health, "health_after decreases")
		previous_health = float(event["health_after"])
	var reported: float = _total_damage(events)
	assert_true(reported <= lost + EPSILON, "events never report more than was lost")

	# Leaving flushes what is still pending, so nothing is lost from the record.
	world.leave(player_id)
	events.append_array(_damage_events(survival.drain_events()))
	assert_true(absf(_total_damage(events) - lost) < EPSILON, "reported %f, lost %f" % [_total_damage(events), lost])


func test_interval_zero_reports_every_tick() -> void:
	_settings.survival_damage_event_interval_world_sec = 0.0
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var player_id: String = _bleeding_player(world)
	for _tick: int in 30:
		world.step_systems(TICK_SEC)
	assert_eq(_damage_events(survival.drain_events()).size(), 30, "interval 0 keeps the per-tick behaviour")
	assert_true(survival.is_alive(player_id))


func test_death_flushes_pending_damage_before_the_death_event() -> void:
	_settings.bleeding_health_loss_per_severity_per_world_sec = 100.0
	_settings.respawn_delay_world_sec = 1.0e9
	var world: ServerWorld = _world()
	var survival: SurvivalService = _survival(world)
	var player_id: String = _bleeding_player(world)
	var health_before: float = survival.get_vitals(player_id).health
	for _tick: int in 120:
		world.step_systems(TICK_SEC)
	assert_false(survival.is_alive(player_id), "the player bled out")
	var events: Array[Dictionary] = survival.drain_events()
	var died_index: int = -1
	var last_damage_index: int = -1
	for index: int in events.size():
		if events[index]["event_type"] == SurvivalService.EVENT_PLAYER_DIED:
			died_index = index
		elif events[index]["event_type"] == SurvivalService.EVENT_PLAYER_SURVIVAL_DAMAGE:
			last_damage_index = index
	assert_true(died_index >= 0, "death is reported")
	assert_true(last_damage_index >= 0 and last_damage_index < died_index, "pending damage is reported before the death")
	assert_eq(events[last_damage_index]["health_after"], 0.0)
	assert_true(absf(_total_damage(_damage_events(events)) - health_before) < EPSILON, "all lost health is accounted for")


func test_interval_setting_is_validated() -> void:
	assert_true(SurvivalSettings.new().validate().is_empty())
	var bad: SurvivalSettings = SurvivalSettings.new()
	bad.survival_damage_event_interval_world_sec = -1.0
	assert_false(bad.validate().is_empty())
