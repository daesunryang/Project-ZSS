class_name NoiseEvent
extends RefCounted
## One noise made by an action (docs/02 §5.3 fields). Transient: lives in
## NoiseService only and is never written to a save document.

## Runtime id ("noise:<n>"); not an entity id, never saved (docs/09 §14.8).
var noise_id: String = ""
## Emit order within this server session (stable tie-breaker).
var sequence: int = 0
## Entity that made the noise (player id, zombie id, "environment", ...).
var source_id: String = ""
var position: Vector3 = Vector3.ZERO
## Loudness at the source when emitted (NoiseSettings model).
var loudness: float = 0.0
var frequency_profile: String = ""
## Action time (WorldClock.action_time_sec, real seconds) of the emit.
var event_time: float = 0.0
## Opaque JSON-safe hints for NoiseOcclusion (room id, indoors, ...).
var occlusion_context: Dictionary = {}


## JSON-safe description for ActionResult events / logs.
func to_event_dict(event_type: String) -> Dictionary:
	return {
		"event_type": event_type,
		"noise_id": noise_id,
		"source_id": source_id,
		"position": [position.x, position.y, position.z],
		"loudness": loudness,
		"frequency_profile": frequency_profile,
		"event_time": event_time,
	}
