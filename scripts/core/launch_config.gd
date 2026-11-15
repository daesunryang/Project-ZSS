class_name LaunchConfig
extends RefCounted
## Parsed launch options (pure: no engine side effects, unit testable).
##
## User options come after `--` on the Godot command line, e.g.
##   godot --headless --path . -- --server --log-level=DEBUG --run-frames=120
##
## Role resolution order:
##   1. explicit `--server` / `--client`
##   2. the `dedicated_server` feature tag (dedicated server export)
##   3. client
## `--headless` alone does NOT imply server: a client can run headless for tests.

enum Role { CLIENT, SERVER }

const ARG_SERVER: String = "--server"
const ARG_CLIENT: String = "--client"
const ARG_LOG_LEVEL: String = "--log-level="
const ARG_WORLD_ID: String = "--world-id="
const ARG_RUN_FRAMES: String = "--run-frames="
const MAX_WORLD_ID_LENGTH: int = 64
const WORLD_ID_PATTERN: String = "^[a-z0-9_]+$"
## 0 means "run until stopped".
const RUN_FOREVER: int = 0

var role: Role = Role.CLIENT
## How the role was chosen: "argument", "feature_tag" or "default".
var role_source: String = "default"
## Empty string means "use AppSettings.log_level".
var log_level_override: String = ""
## Empty string means "use AppSettings.default_world_id".
var world_id_override: String = ""
## Number of main-loop frames before a graceful shutdown (smoke tests). 0 = forever.
var run_frames: int = RUN_FOREVER
## Parse problems. A non-empty list means the launch must be aborted.
var errors: PackedStringArray = []


## Parses `user_args` (OS.get_cmdline_user_args()). `is_dedicated_build`
## should be OS.has_feature("dedicated_server").
static func parse(user_args: PackedStringArray, is_dedicated_build: bool) -> LaunchConfig:
	var config: LaunchConfig = LaunchConfig.new()
	var wants_server: bool = false
	var wants_client: bool = false
	for arg: String in user_args:
		if arg == ARG_SERVER:
			wants_server = true
		elif arg == ARG_CLIENT:
			wants_client = true
		elif arg.begins_with(ARG_LOG_LEVEL):
			var level_text: String = arg.substr(ARG_LOG_LEVEL.length())
			if GameLogger.parse_level(level_text) < 0:
				config.errors.append("unknown log level '%s'" % level_text)
			else:
				config.log_level_override = level_text.to_upper()
		elif arg.begins_with(ARG_WORLD_ID):
			var world_id: String = arg.substr(ARG_WORLD_ID.length())
			if is_valid_world_id(world_id):
				config.world_id_override = world_id
			else:
				config.errors.append("invalid world id '%s'" % world_id)
		elif arg.begins_with(ARG_RUN_FRAMES):
			var frames_text: String = arg.substr(ARG_RUN_FRAMES.length())
			if frames_text.is_valid_int() and int(frames_text) >= 0:
				config.run_frames = int(frames_text)
			else:
				config.errors.append("invalid frame count '%s'" % frames_text)
		else:
			config.errors.append("unknown argument '%s'" % arg)

	if wants_server and wants_client:
		config.errors.append("--server and --client are mutually exclusive")
	elif wants_server:
		config.role = Role.SERVER
		config.role_source = "argument"
	elif wants_client:
		if is_dedicated_build:
			config.errors.append("--client is not available in a dedicated server build")
		config.role = Role.CLIENT
		config.role_source = "argument"
	elif is_dedicated_build:
		config.role = Role.SERVER
		config.role_source = "feature_tag"
	return config


## World ids are lowercase ASCII letters, digits and underscores (safe as a
## save directory name, docs/10 §3).
static func is_valid_world_id(world_id: String) -> bool:
	if world_id.is_empty() or world_id.length() > MAX_WORLD_ID_LENGTH:
		return false
	var regex: RegEx = RegEx.create_from_string(WORLD_ID_PATTERN)
	return regex.search(world_id) != null


func is_server() -> bool:
	return role == Role.SERVER


func role_name() -> String:
	return "server" if role == Role.SERVER else "client"
