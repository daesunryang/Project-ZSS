class_name ZombieSettings
extends Resource
## Common infected ("zombie") tuning (docs/02 §6). Defaults in
## `res://data/tuning/zombie_settings.tres`. Every value is PROVISIONAL
## (docs/15 §6.1 P2-24..P2-32) and must be balanced by play-testing.
## All times are real seconds and speeds are metres per real second (action
## time, docs/09 §14.16): the calendar time scale does not change them.

const DEFAULT_PATH: String = "res://data/tuning/zombie_settings.tres"

## Which player deaths leave a zombie where the player died (docs/00
## ADR-008, docs/15 P2-132).
##   NEVER              no player death leaves a zombie.
##   INFECTION_DEATH    the death was caused by the infection: the player
##                      turned at the end of the terminal stage, or the
##                      health loss of the infection killed (alone or
##                      together with bleeding / starvation / dehydration).
##   INFECTED_AT_DEATH  any death of a player who was infected at that
##                      moment, whatever killed it (also a hit).
enum PlayerDeathZombieRule { NEVER = 0, INFECTION_DEATH = 1, INFECTED_AT_DEATH = 2 }

@export_group("Population")
## Zombies (alive or corpses) that may exist at once; spawns beyond fail.
@export_range(1, 100000) var max_active_zombies: int = 64
## Development zombies placed in a brand-new world (docs/13: 10~20).
@export_range(0, 100000) var dev_spawn_count: int = 12
## Dev zombies are placed on a ring around this point.
@export var dev_spawn_center: Vector3 = Vector3.ZERO
@export_range(0.0, 100000.0) var dev_spawn_min_radius_m: float = 40.0
@export_range(0.0, 100000.0) var dev_spawn_max_radius_m: float = 90.0
## Base seed: placement RNG and per-zombie RNG (hash("<seed>:<zombie_id>")).
@export var rng_seed: int = 0
## PlayerDeathZombieRule: which player deaths leave a zombie (P2-T5). The
## zombie counts against max_active_zombies; at the limit it is skipped.
@export_enum("Never:0", "Death by infection:1", "Any death while infected:2") var player_death_zombie_rule: int = PlayerDeathZombieRule.INFECTED_AT_DEATH

@export_group("Health")
@export_range(1.0, 100000.0) var max_health: float = 100.0
## A dead zombie stays as a corpse this long, then is removed.
@export_range(0.0, 1000000.0) var corpse_remove_delay_sec: float = 30.0

@export_group("Senses")
@export_range(0.0, 10000.0) var sight_range_m: float = 25.0
## Half of the field of view, degrees (60 = 120 degree cone).
@export_range(0.0, 180.0) var sight_half_angle_deg: float = 60.0
## Lighting factor applied to sight range (1 = daylight). Constant until a
## day/night and light model exists.
@export_range(0.0, 10.0) var light_sight_multiplier: float = 1.0
## Passed to NoiseService.query_audible().
@export_range(0.0, 100.0) var hearing_multiplier: float = 1.0

@export_group("Movement")
@export_range(0.0, 100.0) var wander_speed_mps: float = 0.8
@export_range(0.0, 100.0) var investigate_speed_mps: float = 1.5
@export_range(0.0, 100.0) var chase_speed_mps: float = 3.2
@export_range(0.0, 100.0) var search_speed_mps: float = 1.2
## Distance at which a movement goal counts as reached.
@export_range(0.01, 100.0) var arrive_radius_m: float = 0.5
## Chasing zombies stop this close to the target (must be <= attack range).
@export_range(0.0, 100.0) var chase_stop_distance_m: float = 1.0
## Idle wandering stays within this radius of the zombie's home point.
@export_range(0.0, 10000.0) var wander_radius_m: float = 8.0
@export_range(0.0, 1000000.0) var wander_pause_min_sec: float = 3.0
@export_range(0.0, 1000000.0) var wander_pause_max_sec: float = 10.0
## Give up walking to a noise after this long.
@export_range(0.0, 1000000.0) var investigate_timeout_sec: float = 20.0
## How long a zombie searches around the last known position.
@export_range(0.0, 1000000.0) var search_duration_sec: float = 12.0
@export_range(0.0, 10000.0) var search_radius_m: float = 6.0

@export_group("Attack")
@export_range(0.0, 100.0) var attack_range_m: float = 1.5
## Delay between getting in range and the first hit.
@export_range(0.0, 1000.0) var attack_windup_sec: float = 0.5
@export_range(0.0, 1000.0) var attack_cooldown_sec: float = 1.5
## Chance that a hit is a bite; otherwise it is a scratch (docs/02 §7.1).
@export_range(0.0, 1.0) var bite_chance: float = 0.3
@export_range(0.001, 100000.0) var bite_damage: float = 15.0
@export_range(0.001, 100000.0) var scratch_damage: float = 8.0
## Body parts a hit can land on (BodyPart.NAMES), chosen uniformly.
@export var attack_body_parts: PackedStringArray = ["torso", "left_arm", "right_arm", "left_hand", "right_hand"]

@export_group("Scheduling")
## Every living zombie makes one AI decision per period (BucketScheduler).
@export_range(0.01, 1000.0) var ai_period_sec: float = 0.5
@export_range(1, 1000) var ai_bucket_count: int = 10
## AI decisions processed per server tick; the rest wait for the next tick.
@export_range(1, 100000) var max_ai_updates_per_tick: int = 8
## Undrained events kept for the network layer; the oldest are dropped.
@export_range(1, 1000000) var max_pending_events: int = 256


func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if max_active_zombies < 1:
		errors.append("zombie max_active_zombies must be >= 1")
	if dev_spawn_count < 0 or dev_spawn_count > max_active_zombies:
		errors.append("zombie dev_spawn_count must be within [0, max_active_zombies]")
	if not dev_spawn_center.is_finite():
		errors.append("zombie dev_spawn_center must be finite")
	if player_death_zombie_rule < PlayerDeathZombieRule.NEVER or player_death_zombie_rule > PlayerDeathZombieRule.INFECTED_AT_DEATH:
		errors.append("zombie player_death_zombie_rule must be a PlayerDeathZombieRule value")
	if dev_spawn_min_radius_m < 0.0 or dev_spawn_max_radius_m < dev_spawn_min_radius_m:
		errors.append("zombie dev spawn radii must satisfy 0 <= min <= max")
	if max_health <= 0.0:
		errors.append("zombie max_health must be > 0")
	for value: float in [corpse_remove_delay_sec, sight_range_m, light_sight_multiplier, hearing_multiplier, wander_speed_mps, investigate_speed_mps, chase_speed_mps, search_speed_mps, chase_stop_distance_m, wander_radius_m, wander_pause_min_sec, investigate_timeout_sec, search_duration_sec, search_radius_m, attack_range_m, attack_windup_sec, attack_cooldown_sec]:
		if not is_finite(value) or value < 0.0:
			errors.append("zombie distances, speeds and durations must be finite and >= 0")
			break
	if sight_half_angle_deg < 0.0 or sight_half_angle_deg > 180.0:
		errors.append("zombie sight_half_angle_deg must be within [0, 180]")
	if arrive_radius_m <= 0.0:
		errors.append("zombie arrive_radius_m must be > 0")
	if chase_stop_distance_m > attack_range_m:
		errors.append("zombie chase_stop_distance_m must be <= attack_range_m")
	if wander_pause_max_sec < wander_pause_min_sec:
		errors.append("zombie wander_pause_max_sec must be >= wander_pause_min_sec")
	if bite_chance < 0.0 or bite_chance > 1.0:
		errors.append("zombie bite_chance must be within [0, 1]")
	if bite_damage <= 0.0 or scratch_damage <= 0.0:
		errors.append("zombie bite_damage and scratch_damage must be > 0")
	if attack_body_parts.is_empty():
		errors.append("zombie attack_body_parts must not be empty")
	for part_name: String in attack_body_parts:
		if BodyPart.from_name(part_name) < 0:
			errors.append("zombie attack_body_parts has unknown body part " + part_name)
	if ai_period_sec <= 0.0 or ai_bucket_count < 1 or max_ai_updates_per_tick < 1:
		errors.append("zombie ai_period_sec, ai_bucket_count and max_ai_updates_per_tick must be > 0")
	if max_pending_events < 1:
		errors.append("zombie max_pending_events must be >= 1")
	return errors


## Sight range after the lighting factor.
func effective_sight_range_m() -> float:
	return sight_range_m * light_sight_multiplier


static func load_or_default(path: String = DEFAULT_PATH) -> ZombieSettings:
	var loaded: Resource = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if loaded is ZombieSettings:
		return loaded as ZombieSettings
	GameLogger.warning("config", "zombie settings missing, using defaults", {"path": path, "operation": "load_settings"})
	return ZombieSettings.new()
