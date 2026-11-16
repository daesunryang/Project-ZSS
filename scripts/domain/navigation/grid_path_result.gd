class_name GridPathResult
extends RefCounted
## Result of one bounded grid search. Waypoints exclude the start position
## and end at the caller's exact goal when a path was found.

var found: bool = false
var bound_hit: bool = false
var expanded_nodes: int = 0
var waypoints: Array[Vector3] = []

