extends TestCase
## P2-N1a: zombie replication over real ENet (server + clients in one
## process): position snapshots on channel 2, events on channel 0, join
## snapshot for late joiners, the P2-9 private-field filter and forged/malformed
## payloads.
##
## Convergence tolerance (docs/09 §14.12): while a zombie moves, a mirror may
## lag by the snapshot period plus delivery, so the test allows two snapshot
## periods of travel; once the zombie stands still the mirror must be equal
## to the server row (values are sent without quantisation).

const WORLD: String = "zombie_net_world"
const NEVER: float = 1.0e9
## Yaw facing -Z, towards a player at the origin from +Z.
const YAW_MINUS_Z: float = 0.0
const REST_TOLERANCE: float = 0.0001
const FAR_AWAY: Vector3 = Vector3(-150, 0, -150)
## Real-time budget of one wait. The scenarios take seconds of world time
## and the headless frame rate is not fixed, so waits are timed, not counted
## in frames.
const WAIT_SEC: float = 15.0

var _cluster: NetTestCluster = null
var _config: CompositionConfig = null
var _zombie_settings: ZombieSettings = null
var _survival_settings: SurvivalSettings = null
var _net_settings: ZombieNetSettings = null
var _world: ServerWorld = null
## Every event the server drained, in server order.
var _server_events: Array[Dictionary] = []


func before_each() -> void:
	GameLogger.set_capture(true)
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	_zombie_settings = ZombieSettings.new()
	_zombie_settings.dev_spawn_count = 0
	# Idle zombies stand still; decisions and attacks are quick so the tests
	# stay short. Hits are weak so nobody dies unless a test wants it.
	_zombie_settings.wander_pause_min_sec = NEVER
	_zombie_settings.wander_pause_max_sec = NEVER
	_zombie_settings.ai_period_sec = 0.1
	_zombie_settings.attack_windup_sec = 0.1
	_zombie_settings.attack_cooldown_sec = 0.3
	_zombie_settings.bite_damage = 1.0
	_zombie_settings.scratch_damage = 1.0
	_survival_settings = SurvivalSettings.new()
	# Isolate from B3 time rules: no natural healing, no respawn.
	_survival_settings.health_recovery_per_world_sec = 0.0
	_survival_settings.respawn_delay_world_sec = NEVER
	_net_settings = ZombieNetSettings.new()
	# from_defaults() hands out shared cached resources: replace, never edit.
	_config = CompositionConfig.from_defaults()
	_config.gameplay = GameplaySettings.new()
	_config.clock = WorldClockSettings.new()
	_config.survival = _survival_settings
	_config.noise = NoiseSettings.new()
	_config.zombie = _zombie_settings
	_config.zombie_net = _net_settings
	_cluster = NetTestCluster.new(tree, network_settings, _config)
	_server_events = []


func after_each() -> void:
	await _cluster.shutdown()
	GameLogger.set_capture(false)


func _start() -> bool:
	_world = ServerComposition.create_world(WORLD, _config)
	if _world == null or _cluster.start_server(_world, null) != OK:
		return false
	_module(_cluster.server).server_events_drained.connect(func(events: Array[Dictionary]) -> void: _server_events.append_array(events))
	return true


## Polls `condition` once per frame for up to `timeout_sec` of real time.
func _eventually(condition: Callable, timeout_sec: float = WAIT_SEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await tree.process_frame
	return bool(condition.call())


func _module(service: NetworkService) -> ZombieNetModule:
	return service.get_module(ZombieNetModule.MODULE_NAME) as ZombieNetModule


func _mirror(service: NetworkService) -> ClientZombieState:
	return _module(service).client_state


func _zombies() -> ZombieService:
	return _world.get_system(ZombieService.SYSTEM_ID) as ZombieService


func _spawn(position: Vector3, yaw: float = YAW_MINUS_Z) -> String:
	return str(_zombies().spawn_zombie(_world, position, yaw).event.get("zombie_id", ""))


func _collect(client: NetworkService) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_mirror(client).event_received.connect(func(event: Dictionary) -> void: events.append(event))
	return events


func _server_row(zombie_id: String) -> Dictionary:
	for row: Dictionary in _zombies().snapshot_rows():
		if row["id"] == zombie_id:
			return row
	return {}


## True when the client's mirror has exactly the server's zombies (same
## order) and every row is within `position_tolerance` metres / equal.
func _mirror_matches(client: NetworkService, position_tolerance: float) -> bool:
	var rows: Array[Dictionary] = _zombies().snapshot_rows()
	var mirror: ClientZombieState = _mirror(client)
	if mirror.zombie_count() != rows.size():
		return false
	var ids: PackedStringArray = mirror.zombie_ids()
	for index: int in range(rows.size()):
		var row: Dictionary = rows[index]
		if ids[index] != row["id"]:
			return false
		var entry: Dictionary = mirror.get_zombie(row["id"])
		if (entry["position"] as Vector3).distance_to(row["position"]) > position_tolerance:
			return false
		if entry["state"] != row["state"]:
			return false
		if position_tolerance <= REST_TOLERANCE:
			if absf(angle_difference(entry["yaw"], row["yaw"])) > REST_TOLERANCE or absf(entry["health_fraction"] - row["health_fraction"]) > REST_TOLERANCE:
				return false
	return true


func _all_match(clients: Array[NetworkService], position_tolerance: float = REST_TOLERANCE) -> bool:
	for client: NetworkService in clients:
		if not _mirror_matches(client, position_tolerance):
			return false
	return true


func _count_events(events: Array[Dictionary], event_type: String) -> int:
	var count: int = 0
	for event: Dictionary in events:
		if event["event_type"] == event_type:
			count += 1
	return count


func _first_event(events: Array[Dictionary], event_type: String) -> Dictionary:
	for event: Dictionary in events:
		if event["event_type"] == event_type:
			return event
	return {}


## The event as every client may see it: no private fields, no client-side
## sequence number.
func _observable(event: Dictionary) -> Dictionary:
	var copy: Dictionary = event.duplicate(true)
	copy.erase("infection")
	copy.erase("target_health_after")
	copy.erase("sequence")
	return copy


# ------------------------------------------------------------ 1. convergence

func test_chase_and_attack_replicate_to_both_clients_in_server_order() -> void:
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var clients: Array[NetworkService] = [a, b]
	var alice_id: String = a.client_state.local_player_id
	var bob_id: String = b.client_state.local_player_id
	var a_events: Array[Dictionary] = _collect(a)
	var b_events: Array[Dictionary] = _collect(b)
	# Bob stands out of sight, so alice is the only possible target.
	_world.get_player(bob_id).position = FAR_AWAY
	var start: Vector3 = Vector3(0, 0, 8)
	var zombie_id: String = _spawn(start)
	assert_false(zombie_id.is_empty())

	# While it runs at alice, both mirrors follow within the moving tolerance.
	var moving_tolerance: float = _zombie_settings.chase_speed_mps * 2.0 / _net_settings.snapshot_rate_hz
	var following: Callable = func() -> bool:
		var row: Dictionary = _server_row(zombie_id)
		if row["state"] != "chase" or (row["position"] as Vector3).distance_to(start) < 2.0:
			return false
		for client: NetworkService in clients:
			if not _mirror(client).has_zombie(zombie_id) or (_mirror(client).get_zombie(zombie_id)["position"] as Vector3).distance_to(start) < 1.0:
				return false
		return _all_match(clients, moving_tolerance)
	var followed: bool = await _eventually(following)
	assert_true(followed, "both mirrors follow the chasing zombie within %.2f m" % moving_tolerance)

	var attacked: bool = await _eventually(func() -> bool: return _count_events(_server_events, ZombieService.EVENT_ATTACKED) >= 2)
	assert_true(attacked, "the zombie reached alice and hit her twice")
	# In attack state the zombie stands still: mirrors become equal to the server.
	var converged: bool = await _eventually(func() -> bool: return _server_row(zombie_id)["state"] == "attack" and _all_match(clients))
	assert_true(converged, "both mirrors converge on the server snapshot rows")
	assert_eq(_mirror(a).get_zombie(zombie_id), _mirror(b).get_zombie(zombie_id), "both clients hold the same row")
	assert_eq(_mirror(a).get_zombie(zombie_id)["state"], "attack")

	# Both clients received the events the server produced, in that order.
	var total: int = _server_events.size()
	var delivered: bool = await _eventually(func() -> bool: return _mirror(a).last_event_sequence >= total and _mirror(b).last_event_sequence >= total)
	assert_true(delivered, "all %d server events reached both clients" % total)
	if a_events.size() < total or b_events.size() < total:
		fail("clients received %d and %d of %d events" % [a_events.size(), b_events.size(), total])
		return
	for index: int in range(total):
		var expected: Dictionary = _observable(_server_events[index])
		assert_eq(a_events[index]["sequence"], index + 1, "alice sequence %d" % index)
		assert_eq(b_events[index]["sequence"], index + 1, "bob sequence %d" % index)
		assert_eq(_observable(a_events[index]), expected, "alice event %d" % index)
		assert_eq(_observable(b_events[index]), expected, "bob event %d" % index)
	var types: PackedStringArray = []
	for index: int in range(total):
		types.append(str(a_events[index]["event_type"]))
	assert_eq(types[0], ZombieService.EVENT_SPAWNED, "the stream starts with the spawn")
	var saw: int = types.find(ZombieService.EVENT_DETECTED)
	var chase: int = types.find(ZombieService.EVENT_STATE_CHANGED)
	var hit: int = types.find(ZombieService.EVENT_ATTACKED)
	assert_true(saw > 0 and chase > saw and hit > chase, "spawn -> detect -> state change -> attack: %s" % ", ".join(types))
	assert_eq(a_events[hit]["target_id"], alice_id)
	assert_eq(_module(_cluster.server).client_state.zombie_count(), 0, "the server keeps no mirror")


# ------------------------------------------------------------ 2. late join

func test_late_joiner_receives_all_zombies_in_the_join_snapshot() -> void:
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("alice did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var a_events: Array[Dictionary] = _collect(a)
	# Out of sight of the spawn point, so they stay where they are.
	var healthy: String = _spawn(Vector3(60, 0, 0), 1.0)
	var wounded: String = _spawn(Vector3(0, 0, 70), -2.0)
	var corpse: String = _spawn(Vector3(-80, 0, 10), 0.5)
	assert_true(_zombies().apply_damage_to_zombie(corpse, 1000.0, alice_id).ok)
	var before_join: bool = await _eventually(func() -> bool: return _all_match([a]))
	assert_true(before_join, "alice mirrors the three zombies")

	# Events that are still queued when a join snapshot is built are already
	# part of its rows; the fragment's sequence tells the joiner to skip them.
	var server_module: ZombieNetModule = _module(_cluster.server)
	var sequence_before: int = _mirror(a).last_event_sequence
	assert_true(_zombies().apply_damage_to_zombie(wounded, 40.0, "test_source").ok)
	var fragment: Dictionary = server_module.build_join_fragment(alice_id)
	assert_eq(fragment["event_sequence"], sequence_before + 1, "the queued damage event is covered by the fragment")
	assert_eq((fragment["rows"] as Array).size(), 3)
	var late_state: ClientZombieState = ClientZombieState.new(_net_settings)
	assert_eq(late_state.apply_join(fragment), "")
	assert_eq(late_state.get_zombie(wounded)["health_fraction"], 0.6)
	var a_got_it: bool = await _eventually(func() -> bool: return _mirror(a).last_event_sequence == sequence_before + 1)
	assert_true(a_got_it, "the event is still delivered to clients that were already joined")
	assert_eq(a_events[a_events.size() - 1]["event_type"], ZombieService.EVENT_DAMAGED)

	var b: NetworkService = await _cluster.join_client("bob")
	if b == null:
		fail("bob did not join")
		return
	var b_events: Array[Dictionary] = _collect(b)
	assert_eq(_mirror(b).zombie_ids(), PackedStringArray([healthy, wounded, corpse]), "full list, in spawn order, straight from the join snapshot")
	assert_eq(_mirror(b).zombie_ids(), _zombies().zombie_ids())
	assert_eq(_mirror(b).get_zombie(healthy), {"position": Vector3(60, 0, 0), "yaw": 1.0, "state": "idle", "health_fraction": 1.0})
	assert_eq(_mirror(b).get_zombie(corpse)["state"], "dead")
	assert_eq(_mirror(b).get_zombie(corpse)["health_fraction"], 0.0)
	assert_eq(_mirror(b).last_event_sequence, _mirror(a).last_event_sequence, "bob starts at the same point of the event stream")
	var both: Array[NetworkService] = [a, b]
	var same: bool = await _eventually(func() -> bool: return _all_match(both))
	assert_true(same, "late joiner matches the server rows")
	await _cluster.wait_frames(10)
	assert_eq(b_events.size(), 0, "no event from before the join is replayed")

	# From here on both clients see the same stream.
	var newcomer: String = _spawn(Vector3(90, 0, 90))
	var spawned: bool = await _eventually(func() -> bool: return _mirror(a).has_zombie(newcomer) and _mirror(b).has_zombie(newcomer) and _all_match(both))
	assert_true(spawned, "a zombie spawned after the join reaches both clients")
	assert_eq(b_events.size(), 1)
	assert_eq(_observable(b_events[0]), _observable(a_events[a_events.size() - 1]))
	assert_eq(b_events[0]["sequence"], a_events[a_events.size() - 1]["sequence"])


func test_default_new_world_join_snapshot_lists_the_dev_zombies() -> void:
	# The production composition: 12 development zombies in a new world.
	var defaults: CompositionConfig = CompositionConfig.from_defaults()
	var network_settings: NetworkSettings = NetworkSettings.new()
	network_settings.autosave_interval_sec = 0.0
	var cluster: NetTestCluster = NetTestCluster.new(tree, network_settings, defaults)
	_world = ServerComposition.create_world(WORLD, defaults)
	assert_eq(_world.seed_new_world(defaults.dev_seed), OK)
	assert_eq(cluster.start_server(_world, null), OK)
	var a: NetworkService = await cluster.join_client("alice")
	if a == null:
		fail("alice did not join")
	else:
		assert_eq(_mirror(a).zombie_count(), defaults.zombie.dev_spawn_count)
		assert_eq(_mirror(a).zombie_ids(), _zombies().zombie_ids())
		# Dev zombies wander slowly; two snapshot periods of chase speed is ample.
		var tolerance: float = defaults.zombie.chase_speed_mps * 2.0 / defaults.zombie_net.snapshot_rate_hz
		var matched: bool = await _eventually(func() -> bool: return _mirror_matches(a, tolerance))
		assert_true(matched, "mirror follows the dev zombies")
	await cluster.shutdown()


# ------------------------------------------------------------ 3. infection

func test_infection_result_only_reaches_the_attacked_player() -> void:
	_zombie_settings.bite_chance = 1.0
	_survival_settings.infection_chance_bite = 1.0
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var a_events: Array[Dictionary] = _collect(a)
	var b_events: Array[Dictionary] = _collect(b)
	_world.get_player(b.client_state.local_player_id).position = FAR_AWAY
	_spawn(Vector3(0, 0, 1.2))
	var both_hit: Callable = func() -> bool:
		return _count_events(a_events, ZombieService.EVENT_ATTACKED) >= 2 and _count_events(b_events, ZombieService.EVENT_ATTACKED) >= 2
	var hit_twice: bool = await _eventually(both_hit)
	assert_true(hit_twice, "both clients observed the bites")
	var server_hit: Dictionary = _first_event(_server_events, ZombieService.EVENT_ATTACKED)
	assert_eq(server_hit["infection"], SurvivalService.EVENT_PLAYER_INFECTED, "the server decided the infection")
	var alice_hit: Dictionary = _first_event(a_events, ZombieService.EVENT_ATTACKED)
	var bob_hit: Dictionary = _first_event(b_events, ZombieService.EVENT_ATTACKED)
	assert_eq(alice_hit["target_id"], alice_id)
	assert_eq(alice_hit["infection"], SurvivalService.EVENT_PLAYER_INFECTED, "the attacked player learns the result")
	assert_eq(alice_hit["target_health_after"], server_hit["target_health_after"], "and her own health")
	assert_false(bob_hit.has("infection"), "the bystander does not")
	assert_false(bob_hit.has("target_health_after"), "nor the exact health of another player (docs/15 P2-9)")
	assert_eq(_observable(bob_hit), _observable(server_hit), "but sees every observable fact")
	assert_eq(bob_hit["wound_type"], "bite")
	assert_eq(bob_hit["target_id"], alice_id)
	assert_eq(bob_hit["damage"], _zombie_settings.bite_damage)
	assert_eq(bob_hit["target_died"], false)
	for event: Dictionary in b_events:
		assert_false(event.has("infection") or event.has("target_health_after"), "no private field in any of bob's events (%s)" % event["event_type"])
	for event: Dictionary in a_events:
		if event["event_type"] == ZombieService.EVENT_ATTACKED:
			assert_true(event.has("infection") and event.has("target_health_after"), "every hit on alice carries her result")


# ------------------------------------------------------------ 4. death / removal

func test_zombie_damage_death_and_removal_reach_both_clients() -> void:
	_zombie_settings.corpse_remove_delay_sec = 0.5
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	var b: NetworkService = await _cluster.join_client("bob")
	if a == null or b == null:
		fail("clients did not join")
		return
	var clients: Array[NetworkService] = [a, b]
	var a_events: Array[Dictionary] = _collect(a)
	var b_events: Array[Dictionary] = _collect(b)
	var removed_on_a: PackedStringArray = []
	_mirror(a).zombie_removed.connect(func(zombie_id: String) -> void: removed_on_a.append(zombie_id))
	var zombie_id: String = _spawn(Vector3(70, 0, 70))
	var other_id: String = _spawn(Vector3(-70, 0, 70))

	# Combat RPCs are another ticket: the server applies the damage directly.
	assert_true(_zombies().apply_damage_to_zombie(zombie_id, 25.0, "test_source").ok)
	var wounded: bool = await _eventually(func() -> bool: return _all_match(clients) and _mirror(a).get_zombie(zombie_id)["health_fraction"] == 0.75)
	assert_true(wounded, "health fraction replicates")
	assert_eq(_mirror(b).get_zombie(zombie_id)["health_fraction"], 0.75)

	# What each mirror says about the zombie at the moment its death event
	# is announced (the corpse only exists for a short time).
	var rows_at_death: Array[Dictionary] = []
	for client: NetworkService in clients:
		_mirror(client).event_received.connect(func(event: Dictionary) -> void:
			if event["event_type"] == ZombieService.EVENT_DIED and event["zombie_id"] == zombie_id:
				rows_at_death.append(_mirror(client).get_zombie(zombie_id).duplicate(true)))
	assert_true(_zombies().apply_damage_to_zombie(zombie_id, 500.0, "test_source").ok)
	var dead: bool = await _eventually(func() -> bool: return rows_at_death.size() == clients.size())
	assert_true(dead, "death reaches both clients")
	for row: Dictionary in rows_at_death:
		assert_eq(row.get("state", ""), "dead", "the mirror already shows the corpse when the event is announced")
		assert_eq(row.get("health_fraction", -1.0), 0.0)

	var removed: bool = await _eventually(func() -> bool: return not _zombies().has_zombie(zombie_id) and not _mirror(a).has_zombie(zombie_id) and not _mirror(b).has_zombie(zombie_id))
	assert_true(removed, "the removed corpse disappears from both mirrors")
	assert_eq(removed_on_a, PackedStringArray([zombie_id]))
	assert_eq(_mirror(a).zombie_ids(), PackedStringArray([other_id]), "the other zombie is untouched")
	var settled: bool = await _eventually(func() -> bool: return _all_match(clients))
	assert_true(settled, "mirrors match the server after the removal")
	for events: Array[Dictionary] in [a_events, b_events]:
		var types: PackedStringArray = []
		for event: Dictionary in events:
			if event["zombie_id"] == zombie_id:
				types.append(str(event["event_type"]))
		assert_eq(types, PackedStringArray([ZombieService.EVENT_SPAWNED, ZombieService.EVENT_DAMAGED, ZombieService.EVENT_DAMAGED, ZombieService.EVENT_DIED, ZombieService.EVENT_REMOVED]), "same lifecycle, same order")
	# A snapshot that was built before the removal must not bring it back.
	_mirror(a).apply_snapshot(_mirror(a).last_snapshot_tick + 1, [[zombie_id, Vector3(70, 0, 70), 0.0, 0, 1.0]])
	assert_false(_mirror(a).has_zombie(zombie_id))


# ------------------------------------------------------------ 5. stale / forged

func test_stale_forged_and_malformed_payloads_are_ignored() -> void:
	assert_true(_start())
	var a: NetworkService = await _cluster.join_client("alice")
	if a == null:
		fail("alice did not join")
		return
	var alice_id: String = a.client_state.local_player_id
	var zombie_id: String = _spawn(Vector3(60, 0, 60))
	var only_a: Array[NetworkService] = [a]
	var synced: bool = await _eventually(func() -> bool: return _all_match(only_a) and _mirror(a).last_snapshot_tick > 0)
	assert_true(synced, "mirror in sync")
	var mirror: ClientZombieState = _mirror(a)
	var before: Dictionary = mirror.get_zombie(zombie_id).duplicate(true)
	var forged_row: Array = [zombie_id, Vector3(9, 0, 9), 0.0, ZombieState.State.CHASE, 0.5]
	var removal: Dictionary = {"event_type": ZombieService.EVENT_REMOVED, "zombie_id": zombie_id, "world_time": 1.0}

	# Forged: handlers invoked by anything but an RPC from the server (here a
	# local call, remote sender id 0) do nothing. A real client cannot even
	# reach another client: relay is off and the engine refuses "authority"
	# RPCs from non-authority peers before the handler runs.
	var client_module: ZombieNetModule = _module(a)
	client_module._rpc_zombie_snapshot(mirror.last_snapshot_tick + 1000, [forged_row])
	client_module._rpc_zombie_events(mirror.last_snapshot_tick + 1000, mirror.last_event_sequence + 1, [removal])
	assert_eq(mirror.get_zombie(zombie_id), before, "forged snapshot ignored")
	assert_true(mirror.has_zombie(zombie_id), "forged removal ignored")
	assert_eq(client_module.ignored_sender_count, 2)
	var server_module: ZombieNetModule = _module(_cluster.server)
	server_module._rpc_zombie_snapshot(5, [forged_row])
	server_module._rpc_zombie_events(5, 1, [removal])
	assert_eq(server_module.client_state.zombie_count(), 0, "the server never applies client-bound payloads")

	# Stale and malformed payloads sent by the real server over the real RPC path.
	var peer: int = _cluster.server.peer_of_player(alice_id)
	var future: int = mirror.last_snapshot_tick + 100000
	server_module._rpc_zombie_snapshot.rpc_id(peer, 0, [forged_row])  # stale tick
	server_module._rpc_zombie_snapshot.rpc_id(peer, "tick", [forged_row])
	server_module._rpc_zombie_snapshot.rpc_id(peer, future, "rows")
	server_module._rpc_zombie_snapshot.rpc_id(peer, future, [[zombie_id, Vector3(NAN, 0, 0), 0.0, 0, 1.0]])
	server_module._rpc_zombie_snapshot.rpc_id(peer, future, [[zombie_id, Vector3(9, 0, 9), 0.0, 99, 1.0]])
	server_module._rpc_zombie_snapshot.rpc_id(peer, future, [[zombie_id, "position", 0.0, 0, 1.0]])
	server_module._rpc_zombie_events.rpc_id(peer, future, "first", [removal])
	server_module._rpc_zombie_events.rpc_id(peer, future, 0, [removal])
	server_module._rpc_zombie_events.rpc_id(peer, future, mirror.last_event_sequence + 1, "events")
	var seen: bool = await _eventually(func() -> bool: return mirror.stale_snapshot_count == 1 and mirror.rejected_payload_count == 8)
	assert_true(seen, "stale=%d rejected=%d" % [mirror.stale_snapshot_count, mirror.rejected_payload_count])
	assert_true(mirror.has_zombie(zombie_id))
	assert_eq(mirror.get_zombie(zombie_id), before, "nothing reached the mirror")
	assert_true(mirror.last_snapshot_tick < future, "rejected snapshots do not advance the tick")
	assert_contains("\n".join(GameLogger.captured_lines()), "zombie snapshot ignored")

	# Replication is still alive afterwards.
	var second: String = _spawn(Vector3(-60, 0, 60))
	var alive: bool = await _eventually(func() -> bool: return mirror.has_zombie(second) and _all_match(only_a))
	assert_true(alive, "valid traffic still applies")


func test_rpc_channels_and_modes() -> void:
	var script: Script = ZombieNetModule
	var config: Dictionary = script.get_rpc_config()
	var snapshot: Dictionary = config[&"_rpc_zombie_snapshot"]
	var events: Dictionary = config[&"_rpc_zombie_events"]
	assert_eq(config.size(), 2, "server -> client only: no client -> server RPC in this ticket")
	assert_eq(snapshot["channel"], NetworkSettings.CHANNEL_ENTITY_SNAPSHOT)
	assert_eq(snapshot["transfer_mode"], MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
	assert_eq(snapshot["rpc_mode"], MultiplayerAPI.RPC_MODE_AUTHORITY)
	assert_eq(events["channel"], NetworkSettings.CHANNEL_RELIABLE)
	assert_eq(events["transfer_mode"], MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	assert_eq(events["rpc_mode"], MultiplayerAPI.RPC_MODE_AUTHORITY)
	assert_false(snapshot["call_local"] or events["call_local"])
