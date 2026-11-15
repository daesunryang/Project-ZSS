class_name NoiseOcclusion
extends RefCounted
## Occlusion seam for noise (docs/02 §5.3 `occlusion_context`, §6.2
## "장애물 차폐"). The world has no geometry yet, so this default lets every
## noise through unchanged; a later ticket subclasses it (walls, doors,
## indoors/outdoors) and installs it with NoiseService.set_occlusion().
## PROVISIONAL (docs/15 P2-22).

const FULL_TRANSMISSION: float = 1.0
const NO_TRANSMISSION: float = 0.0


## Fraction of the loudness that reaches `listener_position`
## (0 = fully blocked, 1 = open air). Must be deterministic and must not
## keep Node references. Values outside [0, 1] are clamped by the service.
func transmission(_event: NoiseEvent, _listener_position: Vector3) -> float:
	return FULL_TRANSMISSION
