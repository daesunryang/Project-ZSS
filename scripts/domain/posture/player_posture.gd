class_name PlayerPosture
extends RefCounted
## Posture of a player (P2-T11, docs/00 ADR-017, docs/09 §14.26). A posture
## is a fact anybody near the player can see, so it is replicated to every
## client (docs/00 ADR-009).
##   STANDING  upright: walking or standing still
##   PRONE     flat on the stomach: slow, quiet, hard for zombies to see
##   RESTING   lying down asleep (rest, docs/09 §14.23): cannot move or act

enum Kind { STANDING, PRONE, RESTING }

## Network / event names, indexed by Kind.
const NAMES: PackedStringArray = ["standing", "prone", "resting"]
## Returned by from_name() for a name that is no posture.
const INVALID: int = -1


static func is_valid(value: int) -> bool:
	return value >= 0 and value < NAMES.size()


static func name_of(kind: Kind) -> String:
	return NAMES[kind]


## Kind for a name, or INVALID.
static func from_name(posture_name: String) -> int:
	return NAMES.find(posture_name)
