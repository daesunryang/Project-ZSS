extends TestCase
## The performance bench result is a simulation-state contract, not a timer.

const TICKS: int = 30
const DELTA: float = 1.0 / 60.0
const PLAYERS: int = 2
const ZOMBIES: int = 12
const WORLD_ITEMS: int = 24


func before_each() -> void:
	GameLogger.set_capture(true)


func after_each() -> void:
	GameLogger.set_capture(false)


func test_digest_repeats_for_the_same_seed_and_changes_with_the_seed() -> void:
	var first: String = _run(71337)
	var repeated: String = _run(71337)
	var different: String = _run(71338)
	assert_eq(first, repeated, "the same fixed seed has the same final state")
	assert_ne(first, different, "the seed changes the final state")
	assert_eq(first.length(), 64, "SHA-256 is written as 64 hexadecimal characters")


func _run(seed: int) -> String:
	var scenario: PerfBenchScenario = PerfBenchScenario.create(seed, PLAYERS, ZOMBIES, WORLD_ITEMS)
	assert_true(scenario.is_valid(), scenario.setup_error)
	if not scenario.is_valid():
		return ""
	scenario.run_ticks(TICKS, DELTA)
	return scenario.state_digest()
