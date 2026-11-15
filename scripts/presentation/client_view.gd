class_name ClientView
extends Node3D
## Client-only presentation for the empty world: camera, light, environment
## and a version label. Never instantiated on the server (docs/09 §11).
## The free-rotating third-person camera rig is Phase 1 work.


func _ready() -> void:
	%VersionLabel.text = BuildInfo.summary()
	GameLogger.info("presentation", "client view ready", {"display_driver": DisplayServer.get_name()})
