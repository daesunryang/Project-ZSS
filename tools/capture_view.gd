extends SceneTree
## Development tool: runs the game's main scene in a real window and saves
## what the game's own viewport shows as a PNG, then lets the game quit on
## its own (--run-seconds=). It captures only the game window, never the
## desktop. Not used by the game or the tests.
##
## Settings come from environment variables so they never mix with the
## game's own command-line arguments (LaunchConfig):
##   ZSS_CAPTURE_PATH    default PNG path and base directory (required)
##   ZSS_CAPTURE_FRAMES  frames to wait before one default capture (default 240)
##   ZSS_CAPTURE_SCRIPT  optional semicolon-separated wait/press/capture steps
##
## Script steps:
##   wait:120                 wait this many rendered frames
##   press:toggle_build_mode  press a ClientInputActions action and release it
##                            on the next frame
##   capture:a.png            capture beside ZSS_CAPTURE_PATH (absolute paths
##                            are also accepted); several captures are allowed
## Tool aliases build_toggle and build_piece_1..4 are also accepted for the
## build mode and its four piece actions.
##
## Example (window, no --headless):
##   ZSS_CAPTURE_PATH=C:/tmp/default.png \
##   ZSS_CAPTURE_SCRIPT="wait:120;press:build_toggle;wait:30;press:build_piece_2;wait:30;capture:a.png;press:container_open;wait:90;capture:b.png" \
##   "$GODOT" --path . --script res://tools/capture_view.gd \
##       -- --client --connect=127.0.0.1:24567 --character-name=A --run-seconds=12

const MAIN_SCENE: String = "res://scenes/main/main.tscn"
const DEFAULT_FRAMES: int = 240
const STEP_WAIT: String = "wait"
const STEP_PRESS: String = "press"
const STEP_CAPTURE: String = "capture"
const ACTION_ALIASES: Dictionary = {
	"build_toggle": "toggle_build_mode",
	"build_piece_1": "build_floor",
	"build_piece_2": "build_wall",
	"build_piece_3": "build_door",
	"build_piece_4": "build_storage_box",
}

var _path: String = ""
var _base_directory: String = ""
var _steps: Array[Dictionary] = []
var _step_index: int = 0
var _wait_frames: int = 0
var _release_action: StringName = &""
var _done: bool = false


func _initialize() -> void:
	_path = OS.get_environment("ZSS_CAPTURE_PATH")
	if _path.is_empty():
		push_error("[capture] ZSS_CAPTURE_PATH is not set; nothing will be captured")
		_done = true
	else:
		_base_directory = _path.get_base_dir()
		_build_steps()
	var scene: PackedScene = load(MAIN_SCENE) as PackedScene
	if scene == null:
		push_error("[capture] main scene could not be loaded: " + MAIN_SCENE)
		quit(1)
		return
	root.add_child(scene.instantiate())


func _process(_delta: float) -> bool:
	if _done:
		return false
	if not _release_action.is_empty():
		Input.action_release(_release_action)
		_release_action = &""
		return false
	if _wait_frames > 0:
		_wait_frames -= 1
		return false
	while _step_index < _steps.size():
		var step: Dictionary = _steps[_step_index]
		_step_index += 1
		match str(step["kind"]):
			STEP_WAIT:
				_wait_frames = int(step["frames"])
				if _wait_frames > 0:
					return false
			STEP_PRESS:
				var action: StringName = StringName(str(step["action"]))
				if not InputMap.has_action(action):
					push_error("[capture] input action is not registered: %s" % action)
					_done = true
					return false
				Input.action_press(action)
				_release_action = action
				return false
			STEP_CAPTURE:
				_capture(str(step["path"]))
	_done = true
	return false


func _build_steps() -> void:
	var script_text: String = OS.get_environment("ZSS_CAPTURE_SCRIPT").strip_edges()
	if script_text.is_empty():
		var frames: int = DEFAULT_FRAMES
		var frames_text: String = OS.get_environment("ZSS_CAPTURE_FRAMES")
		if frames_text.is_valid_int() and int(frames_text) > 0:
			frames = int(frames_text)
		_steps = [{"kind": STEP_WAIT, "frames": frames}, {"kind": STEP_CAPTURE, "path": _path}]
		return
	var capture_count: int = 0
	for raw_step: String in script_text.split(";", false):
		var separator: int = raw_step.find(":")
		if separator <= 0:
			_fail_script("step must be kind:value: %s" % raw_step)
			return
		var kind: String = raw_step.left(separator).strip_edges()
		var value: String = raw_step.substr(separator + 1).strip_edges()
		match kind:
			STEP_WAIT:
				if not value.is_valid_int() or int(value) < 0:
					_fail_script("wait must use a non-negative frame count: %s" % value)
					return
				_steps.append({"kind": STEP_WAIT, "frames": int(value)})
			STEP_PRESS:
				if value.is_empty():
					_fail_script("press needs an input action")
					return
				_steps.append({"kind": STEP_PRESS, "action": ACTION_ALIASES.get(value, value)})
			STEP_CAPTURE:
				if value.is_empty():
					_fail_script("capture needs a PNG path")
					return
				var capture_path: String = value if value.is_absolute_path() else _base_directory.path_join(value)
				_steps.append({"kind": STEP_CAPTURE, "path": capture_path})
				capture_count += 1
			_:
				_fail_script("unknown step kind: %s" % kind)
				return
	if capture_count == 0:
		_fail_script("ZSS_CAPTURE_SCRIPT has no capture step")


func _fail_script(message: String) -> void:
	push_error("[capture] invalid ZSS_CAPTURE_SCRIPT: " + message)
	_steps.clear()
	_done = true


func _capture(capture_path: String) -> void:
	var image: Image = root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("[capture] the viewport gave no image (headless run?)")
		return
	var error: Error = image.save_png(capture_path)
	if error != OK:
		push_error("[capture] could not save %s: %s" % [capture_path, error_string(error)])
	else:
		print("[capture] saved %s (%dx%d)" % [capture_path, image.get_width(), image.get_height()])
