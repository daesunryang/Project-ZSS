class_name NpcThreatSensor
extends NpcStage
## Notices threats between an NPC's decisions (P4-4, docs/09 §17.6 "하드
## 인터럽트"). One NpcStage, stage id "threat_sensor", added after the
## scheduler. Every `threat_check_period_sec` (bucketed like the decisions:
## the NPCs of one bucket per slot) an awake NPC looks for a visible zombie
## (NpcThreatSense); when it sees one and could flee, the sensor asks the
## scheduler for a decision at once (interrupt "threat_seen"). The decider
## then looks again itself and starts the flee action: the sensor decides
## nothing and changes no NPC. F-29: an NPC that cannot start to flee (it
## flees already, or the flee action just failed) but could fight is looked
## at too, and a decision is asked for when the zombie is adjacent
## (NpcUtilityDecider.fight_alert_range): that decision finds it cornered.
##
## No state of its own: the slots come from the scheduler's saved clock, so
## a restored run looks at the same NPCs in the same ticks. Without an
## executor on the decider (nobody could flee) and without zombies it costs
## a few comparisons.

const STAGE_ID: String = "threat_sensor"
## Slots a check period is cut into; an NPC's slot is its id number modulo
## this (stateless, like the scheduler's buckets).
const BUCKET_COUNT: int = 10

## Diagnostics: NPCs looked at / interrupts asked for so far, NPCs looked
## at in the latest tick, and the wall clock time of the latest tick in
## which any were.
var check_count: int = 0
var alert_count: int = 0
var last_check_count: int = 0
var last_step_usec: int = 0

var _settings: NpcDecisionSettings
var _decider: NpcUtilityDecider
var _scheduler_ref: WeakRef
var _slot_usec: int


func _init(settings: NpcDecisionSettings, decider: NpcUtilityDecider, scheduler: NpcScheduler) -> void:
	_settings = settings
	_decider = decider
	_scheduler_ref = weakref(scheduler)
	_slot_usec = maxi(NpcScheduleSettings.to_usec(settings.threat_check_period_sec) / BUCKET_COUNT, 1)


func stage_id() -> String:
	return STAGE_ID


## The slot of an NPC id (0 .. BUCKET_COUNT - 1).
static func bucket_of(npc_id: String) -> int:
	return npc_id.get_slice("_", 1).to_int() % BUCKET_COUNT


func step(world: ServerWorld, npcs: NpcService, action_delta: float, _world_delta: float) -> void:
	last_check_count = 0
	last_step_usec = 0
	var scheduler: NpcScheduler = _scheduler_ref.get_ref() as NpcScheduler
	if scheduler == null or _decider.executor() == null or not is_finite(action_delta) or action_delta <= 0.0:
		return
	# The scheduler ran before this stage and moved its clock by this tick.
	var now: int = scheduler.clock_usec()
	var from_slot: int = maxi(now - NpcScheduleSettings.to_usec(action_delta), 0) / _slot_usec
	var to_slot: int = now / _slot_usec
	if to_slot == from_slot or npcs.awake_count() == 0:
		return
	var started_usec: int = Time.get_ticks_usec()
	var zombies: Array[Array] = NpcThreatSense.living_zombies(world)
	if zombies.is_empty():
		return
	var ids: PackedStringArray = npcs.awake_npc_ids()
	for slot: int in range(maxi(from_slot + 1, to_slot - BUCKET_COUNT + 1), to_slot + 1):
		var bucket: int = slot % BUCKET_COUNT
		for npc_id: String in ids:
			if bucket_of(npc_id) != bucket:
				continue
			var npc: NpcState = npcs.get_npc(npc_id)
			var state: NpcDecisionComponent = npc.component(NpcDecisionComponent.COMPONENT_ID) as NpcDecisionComponent
			var may_flee: bool = _decider.may_start_fleeing(state, now)
			var fight_range_m: float = _decider.fight_alert_range(state, now)
			if not may_flee and fight_range_m <= 0.0:
				continue
			check_count += 1
			last_check_count += 1
			var threat: Dictionary = NpcThreatSense.nearest_visible(world, npc.position, _settings.threat_sight_range_m, zombies)
			if threat.is_empty() or not (may_flee or float(threat[NpcThreatSense.KEY_DISTANCE]) <= fight_range_m):
				continue
			if scheduler.request_interrupt(npc_id, NpcUtilityDecider.REASON_THREAT_SEEN):
				alert_count += 1
	last_step_usec = Time.get_ticks_usec() - started_usec
