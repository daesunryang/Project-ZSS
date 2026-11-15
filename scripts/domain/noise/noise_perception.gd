class_name NoisePerception
extends RefCounted
## One audible noise as heard by one listener (result row of
## NoiseService.query_audible). `event` is read-only for callers.

var event: NoiseEvent = null
## Heard intensity after distance, time and occlusion (>= min audible).
var intensity: float = 0.0
## Distance between listener and source, metres.
var distance: float = 0.0
