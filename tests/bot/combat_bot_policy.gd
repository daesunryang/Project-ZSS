class_name CombatBotPolicy
extends RefCounted
## What the combat bot does next (docs/12 §9.3). Pure and deterministic: it
## sees an Observation (what a player's own client knows: the mirrors) and
## answers with an Action (what a player's client can send: move, facing,
## melee attack, posture, pickup, item use, door). No nodes, no network, no
## server state, no randomness; the same observations give the same actions.
##
## The policy is deliberately simple ("stick and move"):
##   1. lying prone: stand up (a prone player cannot attack);
##   2. pick up what lies within reach, bandage a bleeding wound;
##   3. the target is the nearest living zombie;
##   4. swing ready: hit the target once it is inside the weapon's reach;
##      until then wait for a zombie that is coming, walk up to one that is
##      not, and open a closed door that is in the way;
##   5. swing not ready (cooldown, no stamina): keep every zombie further
##      away than a zombie can reach, backing off in the direction that
##      stays clearest of all of them.
## It is a measuring stick for combat changes, not a good player: passing
## says nothing about whether the fight is fun (AGENTS.md §0).

## A zombie reaches this far (the bot keeps out of it while it cannot
## swing). What a player learns by playing; equals ZombieSettings
## .attack_range_m of the shipped tuning.
const THREAT_RANGE_M: float = 1.5
## Kept between the bot and the nearest zombie while it cannot swing.
const KEEP_AWAY_M: float = THREAT_RANGE_M + 0.6
## The bot swings when the target is this much inside the weapon's reach
## (the mirrors lag the server by a few ticks).
const STRIKE_MARGIN_M: float = 0.2
## A zombie that is coming is waited for from this distance on (walking
## towards it as well would make the meeting point hard to hit).
const WAIT_DISTANCE_M: float = 8.0
## A door is opened from this much inside the interaction range.
const DOOR_MARGIN_M: float = 0.5
## A closed door counts as "in the way" when it is this close to the
## straight line from the bot to its target.
const DOOR_LANE_M: float = 1.0
## Retreat: the directions tried, how far ahead each is judged, the bonus
## for keeping the previous direction (no zigzag) and how strongly leaving
## the arena is punished (metres of clearance per metre outside).
const RETREAT_DIRECTIONS: int = 16
const RETREAT_LOOKAHEAD_M: float = 1.5
const RETREAT_KEEP_BONUS_M: float = 0.25
const ARENA_PENALTY_PER_M: float = 2.0
const NO_DIRECTION: int = -1
## Mirror states (ZombieState.STATE_NAMES) of a zombie that comes at a player.
const COMING_STATES: PackedStringArray = ["chase", "attack"]


## What the bot's own client knows at one tick.
class Observation extends RefCounted:
	var alive: bool = true
	var position: Vector3 = Vector3.ZERO
	var prone: bool = false
	var bleeding: bool = false
	var stamina: float = 0.0
	## Living zombies of the mirror: {id: String, position: Vector3, state: String}.
	var zombies: Array[Dictionary] = []
	## The weapon the bot would swing now (from what it carries).
	var weapon_range_m: float = 0.0
	var weapon_stamina_cost: float = 0.0
	## The cooldown of the last swing is over and no request is unanswered.
	var swing_ready: bool = false
	## Useful items on the ground within pickup range (ids, sorted).
	var reachable_pickups: PackedStringArray = []
	## A carried bandage ("" = none).
	var bandage_item_id: String = ""
	## Closed doors of the mirror: {id: String, position: Vector3}.
	var closed_doors: Array[Dictionary] = []
	var door_range_m: float = 0.0
	## Requests sent and not answered yet (one of each kind at a time).
	var posture_pending: bool = false
	var pickup_pending: bool = false
	var consume_pending: bool = false
	var door_pending: bool = false
	## The open ground the fight should stay on.
	var arena_center: Vector3 = Vector3.ZERO
	var arena_radius_m: float = 40.0


## What the bot's client sends this tick.
class Action extends RefCounted:
	## Move intent: direction on XZ (zero = stand) and facing.
	var move: Vector2 = Vector2.ZERO
	var yaw: float = 0.0
	## Melee attack request aimed at `aim_yaw`.
	var attack: bool = false
	var aim_yaw: float = 0.0
	## Posture request: stand up.
	var stand_up: bool = false
	## Pickup request ("" = none).
	var pickup_item_id: String = ""
	## Item use request: consume this carried item ("" = none).
	var consume_item_id: String = ""
	## Door request: open this door ("" = none).
	var open_door_id: String = ""


var _yaw: float = 0.0
var _retreat_index: int = NO_DIRECTION


## The action for this tick.
func decide(obs: Observation) -> Action:
	var action: Action = Action.new()
	action.yaw = _yaw
	if not obs.alive:
		return action
	if obs.prone:
		action.stand_up = not obs.posture_pending
		return action
	if not obs.reachable_pickups.is_empty() and not obs.pickup_pending:
		action.pickup_item_id = obs.reachable_pickups[0]
	if obs.bleeding and not obs.bandage_item_id.is_empty() and not obs.consume_pending:
		action.consume_item_id = obs.bandage_item_id
	var target: Dictionary = nearest_zombie(obs)
	if target.is_empty():
		return action
	var target_position: Vector3 = target["position"]
	var offset: Vector3 = target_position - obs.position
	var distance: float = ZombiePerception.flat_distance(obs.position, target_position)
	_yaw = ZombiePerception.yaw_towards(offset, _yaw)
	action.yaw = _yaw
	if not (obs.swing_ready and obs.stamina >= obs.weapon_stamina_cost):
		if distance < KEEP_AWAY_M:
			action.move = _retreat(obs)
		return action
	_retreat_index = NO_DIRECTION
	if distance <= obs.weapon_range_m - STRIKE_MARGIN_M:
		action.attack = true
		action.aim_yaw = _yaw
		return action
	var door: Dictionary = door_in_the_way(obs, target_position)
	if not door.is_empty() and ZombiePerception.flat_distance(obs.position, door["position"]) <= obs.door_range_m - DOOR_MARGIN_M:
		if not obs.door_pending:
			action.open_door_id = str(door["id"])
		return action
	# A zombie that has the bot in its reach stops there: the last step is
	# the bot's.
	if COMING_STATES.has(str(target["state"])) and distance > KEEP_AWAY_M and distance <= WAIT_DISTANCE_M:
		return action
	action.move = Vector2(offset.x, offset.z).normalized()
	return action


## The living zombie nearest to the bot; ties go to the lower id. Empty when
## there is none.
static func nearest_zombie(obs: Observation) -> Dictionary:
	var best: Dictionary = {}
	var best_distance: float = INF
	for zombie: Dictionary in obs.zombies:
		var distance: float = ZombiePerception.flat_distance(obs.position, zombie["position"])
		if distance < best_distance or (distance == best_distance and str(zombie["id"]) < str(best.get("id", ""))):
			best = zombie
			best_distance = distance
	return best


## The closed door nearest to the bot that lies between it and `goal`
## (within DOOR_LANE_M of the straight line). Empty when there is none.
static func door_in_the_way(obs: Observation, goal: Vector3) -> Dictionary:
	var from: Vector2 = Vector2(obs.position.x, obs.position.z)
	var along: Vector2 = Vector2(goal.x, goal.z) - from
	var length_squared: float = along.length_squared()
	if length_squared <= 0.0:
		return {}
	var best: Dictionary = {}
	var best_distance: float = INF
	for door: Dictionary in obs.closed_doors:
		var door_position: Vector3 = door["position"]
		var point: Vector2 = Vector2(door_position.x, door_position.z)
		var t: float = (point - from).dot(along) / length_squared
		if t < 0.0 or t > 1.0 or point.distance_to(from + along * t) > DOOR_LANE_M:
			continue
		var distance: float = point.distance_to(from)
		if distance < best_distance:
			best = door
			best_distance = distance
	return best


## The direction that keeps the bot clearest of every zombie: of
## RETREAT_DIRECTIONS compass directions, the one whose point
## RETREAT_LOOKAHEAD_M ahead is furthest from the nearest zombie, less a
## penalty for leaving the arena, plus a bonus for the previous choice.
func _retreat(obs: Observation) -> Vector2:
	var best_index: int = NO_DIRECTION
	var best_score: float = -INF
	for index: int in range(RETREAT_DIRECTIONS):
		var direction: Vector2 = Vector2.from_angle(TAU * float(index) / float(RETREAT_DIRECTIONS))
		var ahead: Vector3 = obs.position + Vector3(direction.x, 0.0, direction.y) * RETREAT_LOOKAHEAD_M
		var score: float = INF
		for zombie: Dictionary in obs.zombies:
			score = minf(score, ZombiePerception.flat_distance(ahead, zombie["position"]))
		score -= maxf(ZombiePerception.flat_distance(ahead, obs.arena_center) - obs.arena_radius_m, 0.0) * ARENA_PENALTY_PER_M
		if index == _retreat_index:
			score += RETREAT_KEEP_BONUS_M
		if score > best_score:
			best_score = score
			best_index = index
	_retreat_index = best_index
	return Vector2.from_angle(TAU * float(best_index) / float(RETREAT_DIRECTIONS))
