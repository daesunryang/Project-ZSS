extends TestCase
## CombatBotPolicy (docs/12 §9.3): what the combat bot decides from what its
## client knows. Pure rules, no network.
## Behaviour under test: stand up when prone; pick up and bandage; wait for
## a coming zombie, walk to one that is not; swing only inside the weapon's
## reach; step in on a zombie that stopped at its own reach; keep away while
## the swing is not ready; open a closed door in the way; retreat away from
## every zombie and not out of the arena; the same input gives the same
## output.

const UNARMED_RANGE_M: float = 1.5
const UNARMED_COST: float = 5.0
const DOOR_RANGE_M: float = 2.5
const TOLERANCE: float = 1.0e-5


func _obs(zombies: Array[Dictionary] = []) -> CombatBotPolicy.Observation:
	var obs: CombatBotPolicy.Observation = CombatBotPolicy.Observation.new()
	obs.stamina = 100.0
	obs.weapon_range_m = UNARMED_RANGE_M
	obs.weapon_stamina_cost = UNARMED_COST
	obs.swing_ready = true
	obs.door_range_m = DOOR_RANGE_M
	obs.zombies = zombies
	return obs


func _zombie(id: String, position: Vector3, state: String = "chase") -> Dictionary:
	return {"id": id, "position": position, "state": state}


func _decide(obs: CombatBotPolicy.Observation) -> CombatBotPolicy.Action:
	return CombatBotPolicy.new().decide(obs)


func _is_idle(action: CombatBotPolicy.Action) -> bool:
	return action.move == Vector2.ZERO and not action.attack and not action.stand_up and action.pickup_item_id.is_empty() and action.consume_item_id.is_empty() and action.open_door_id.is_empty()


func test_a_dead_bot_does_nothing() -> void:
	var obs: CombatBotPolicy.Observation = _obs([_zombie("zombie_000001", Vector3(0.0, 0.0, -1.0))])
	obs.alive = false
	assert_true(_is_idle(_decide(obs)))


func test_a_prone_bot_stands_up_first_and_asks_once() -> void:
	var obs: CombatBotPolicy.Observation = _obs([_zombie("zombie_000001", Vector3(0.0, 0.0, -1.0))])
	obs.prone = true
	var action: CombatBotPolicy.Action = _decide(obs)
	assert_true(action.stand_up, "it asks to stand up")
	assert_true(action.move == Vector2.ZERO and not action.attack, "and does nothing else: a prone player cannot attack")
	obs.posture_pending = true
	assert_false(_decide(obs).stand_up, "not again while the request is unanswered")


func test_it_picks_up_what_is_in_reach_and_bandages_a_bleeding_wound() -> void:
	var obs: CombatBotPolicy.Observation = _obs()
	obs.reachable_pickups = PackedStringArray(["item_000002", "item_000005"])
	obs.bleeding = true
	obs.bandage_item_id = "item_000009"
	var action: CombatBotPolicy.Action = _decide(obs)
	assert_eq(action.pickup_item_id, "item_000002", "the first item in reach")
	assert_eq(action.consume_item_id, "item_000009", "the carried bandage")
	assert_true(action.move == Vector2.ZERO and not action.attack, "with no zombie it stays where it is")
	obs.pickup_pending = true
	obs.consume_pending = true
	assert_true(_is_idle(_decide(obs)), "one request of each kind at a time")
	obs.consume_pending = false
	obs.bleeding = false
	assert_eq(_decide(obs).consume_item_id, "", "no bandage without a bleeding wound")


func test_it_walks_up_to_a_zombie_that_is_not_coming_and_faces_it() -> void:
	var action: CombatBotPolicy.Action = _decide(_obs([_zombie("zombie_000001", Vector3(6.0, 0.0, 0.0), "idle")]))
	assert_true(action.move.distance_to(Vector2(1.0, 0.0)) < TOLERANCE, "towards +X: %s" % str(action.move))
	assert_true(absf(action.yaw - ZombiePerception.yaw_towards(Vector3(1.0, 0.0, 0.0), 0.0)) < TOLERANCE, "facing it")
	assert_false(action.attack)


func test_it_waits_for_a_zombie_that_is_coming() -> void:
	var action: CombatBotPolicy.Action = _decide(_obs([_zombie("zombie_000001", Vector3(0.0, 0.0, -5.0), "chase")]))
	assert_true(action.move == Vector2.ZERO and not action.attack, "it lets the zombie come")
	var far: CombatBotPolicy.Action = _decide(_obs([_zombie("zombie_000001", Vector3(0.0, 0.0, -(CombatBotPolicy.WAIT_DISTANCE_M + 2.0)), "chase")]))
	assert_true(far.move.distance_to(Vector2(0.0, -1.0)) < TOLERANCE, "but closes in from far away")


func test_it_swings_only_inside_the_weapons_reach() -> void:
	var inside: float = UNARMED_RANGE_M - CombatBotPolicy.STRIKE_MARGIN_M - 0.05
	var action: CombatBotPolicy.Action = _decide(_obs([_zombie("zombie_000001", Vector3(0.0, 0.0, -inside))]))
	assert_true(action.attack, "inside the reach it swings")
	assert_true(absf(action.aim_yaw) < TOLERANCE, "aimed at the zombie (-Z is yaw 0)")
	assert_eq(action.move, Vector2.ZERO)
	var outside: CombatBotPolicy.Action = _decide(_obs([_zombie("zombie_000001", Vector3(0.0, 0.0, -(UNARMED_RANGE_M + 1.0)))]))
	assert_false(outside.attack, "outside it does not")


func test_it_steps_in_on_a_zombie_that_stopped_at_its_own_reach() -> void:
	# A zombie that has its target in reach (1.5 m) stops and attacks from
	# there; bare hands reach 1.5 m and the bot swings from 1.3 m.
	var action: CombatBotPolicy.Action = _decide(_obs([_zombie("zombie_000001", Vector3(0.0, 0.0, -1.41), "attack")]))
	assert_false(action.attack)
	assert_true(action.move.distance_to(Vector2(0.0, -1.0)) < TOLERANCE, "it takes the last step itself instead of waiting forever: %s" % str(action.move))


func test_without_a_ready_swing_it_keeps_out_of_reach() -> void:
	var near: Array[Dictionary] = [_zombie("zombie_000001", Vector3(0.0, 0.0, -1.2), "attack")]
	var cooling: CombatBotPolicy.Observation = _obs(near)
	cooling.swing_ready = false
	var action: CombatBotPolicy.Action = _decide(cooling)
	assert_false(action.attack)
	assert_true(action.move.distance_to(Vector2(0.0, 1.0)) < TOLERANCE, "straight away from the zombie: %s" % str(action.move))
	var tired: CombatBotPolicy.Observation = _obs(near)
	tired.stamina = UNARMED_COST - 1.0
	var tired_action: CombatBotPolicy.Action = _decide(tired)
	assert_true(not tired_action.attack and tired_action.move.distance_to(Vector2(0.0, 1.0)) < TOLERANCE, "no stamina for a swing is the same")
	var safe: CombatBotPolicy.Observation = _obs([_zombie("zombie_000001", Vector3(0.0, 0.0, -(CombatBotPolicy.KEEP_AWAY_M + 0.5)))])
	safe.swing_ready = false
	assert_eq(_decide(safe).move, Vector2.ZERO, "far enough: it stands")


func test_the_retreat_avoids_every_zombie_and_stays_in_the_arena() -> void:
	var obs: CombatBotPolicy.Observation = _obs([_zombie("zombie_000001", Vector3(0.0, 0.0, -1.2)), _zombie("zombie_000002", Vector3(1.6, 0.0, 0.0))])
	obs.swing_ready = false
	var move: Vector2 = _decide(obs).move
	assert_true(move.x < -0.3 and move.y > 0.3, "away from the one ahead (-Z) and the one to the right (+X): %s" % str(move))
	# At the edge of the arena, straight away would leave it.
	var edge: CombatBotPolicy.Observation = _obs([_zombie("zombie_000001", Vector3(0.0, 0.0, 8.8))])
	edge.swing_ready = false
	edge.position = Vector3(0.0, 0.0, 10.0)
	edge.arena_radius_m = 10.0
	var edge_move: Vector2 = _decide(edge).move
	assert_true(edge_move.y < 0.95, "not straight out of the arena (+Z): %s" % str(edge_move))
	assert_true(absf(edge_move.x) > 0.3, "it turns along the edge instead: %s" % str(edge_move))


func test_it_opens_a_closed_door_that_is_in_the_way() -> void:
	var obs: CombatBotPolicy.Observation = _obs([_zombie("zombie_000001", Vector3(0.0, 0.0, 6.0), "idle")])
	obs.closed_doors = [{"id": "structure_000007", "position": Vector3(0.0, 0.0, 1.5)}]
	var action: CombatBotPolicy.Action = _decide(obs)
	assert_eq(action.open_door_id, "structure_000007")
	assert_eq(action.move, Vector2.ZERO, "it waits at the door")
	obs.door_pending = true
	assert_eq(_decide(obs).open_door_id, "", "one door request at a time")
	obs.door_pending = false
	obs.closed_doors = [{"id": "structure_000007", "position": Vector3(0.0, 0.0, 4.0)}]
	var far: CombatBotPolicy.Action = _decide(obs)
	assert_true(far.open_door_id.is_empty() and far.move.distance_to(Vector2(0.0, 1.0)) < TOLERANCE, "out of the door's range it walks on towards the zombie")
	obs.closed_doors = [{"id": "structure_000007", "position": Vector3(1.8, 0.0, 1.0)}]
	assert_eq(_decide(obs).open_door_id, "", "a door beside the way is left alone")
	obs.closed_doors = [{"id": "structure_000007", "position": Vector3(0.0, 0.0, -1.0)}]
	assert_eq(_decide(obs).open_door_id, "", "so is a door behind the bot")


func test_the_target_is_the_nearest_zombie_and_ties_go_to_the_lower_id() -> void:
	var obs: CombatBotPolicy.Observation = _obs([
		_zombie("zombie_000003", Vector3(4.0, 0.0, 0.0)), _zombie("zombie_000002", Vector3(0.0, 0.0, 3.0)), _zombie("zombie_000001", Vector3(0.0, 0.0, -3.0)),
	])
	assert_eq(str(CombatBotPolicy.nearest_zombie(obs)["id"]), "zombie_000001")
	assert_true(CombatBotPolicy.nearest_zombie(_obs()).is_empty())


func test_the_same_observations_give_the_same_actions() -> void:
	var first: CombatBotPolicy = CombatBotPolicy.new()
	var second: CombatBotPolicy = CombatBotPolicy.new()
	var same: bool = true
	for step: int in range(40):
		var obs: CombatBotPolicy.Observation = _obs([
			_zombie("zombie_000001", Vector3(0.3 * float(step % 7), 0.0, -2.5 + 0.05 * float(step))),
			_zombie("zombie_000002", Vector3(-1.5, 0.0, 0.1 * float(step))),
		])
		obs.swing_ready = step % 5 == 0
		var a: CombatBotPolicy.Action = first.decide(obs)
		var b: CombatBotPolicy.Action = second.decide(obs)
		same = same and a.move == b.move and a.yaw == b.yaw and a.attack == b.attack and a.aim_yaw == b.aim_yaw
	assert_true(same, "two policies fed the same observations decide the same")
