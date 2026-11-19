extends SceneTree
## Development tool: counts specks, line breaks, halo pixels and colours in
## image files and prints (or saves) the result as JSON. Not used by the game.
## What each number means and its thresholds: docs/19_art_loop.md.
##
## Usage (headless):
##   "$GODOT" --headless --path . --script res://tools/art_metrics.gd -- \
##       [--settings=<json>] [--out=<json>] <image> [<image>...]
## --settings defaults to art/loop/settings.json (its "metrics" block).
## Exit code 0 when every image was measured, 1 otherwise.

const MetricsLib: GDScript = preload("res://tools/art_metrics_lib.gd")
const LoopLib: GDScript = preload("res://tools/art_loop_lib.gd")
const DEFAULT_SETTINGS: String = "res://art/loop/settings.json"
const ARG_SETTINGS: String = "--settings="
const ARG_OUT: String = "--out="
const EXIT_OK: int = 0
const EXIT_FAIL: int = 1


func _initialize() -> void:
	var settings_path: String = ProjectSettings.globalize_path(DEFAULT_SETTINGS)
	var out_path: String = ""
	var images: PackedStringArray = []
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(ARG_SETTINGS):
			settings_path = arg.substr(ARG_SETTINGS.length())
		elif arg.begins_with(ARG_OUT):
			out_path = arg.substr(ARG_OUT.length())
		else:
			images.append(arg)
	if images.is_empty():
		printerr("[art-metrics] usage: art_metrics.gd -- [--settings=<json>] [--out=<json>] <image>...")
		quit(EXIT_FAIL)
		return
	var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(settings_path))
	if not (settings is Dictionary):
		printerr("[art-metrics] settings could not be read: " + settings_path)
		quit(EXIT_FAIL)
		return
	var settings_dictionary: Dictionary = settings
	var metrics_settings: Dictionary = MetricsLib.merged_settings(settings_dictionary.get("metrics", {}))
	var snapshots: Array = []
	for path: String in images:
		var measured: Dictionary = MetricsLib.measure_file(path, metrics_settings)
		if measured.is_empty():
			printerr("[art-metrics] not a readable image: " + path)
			quit(EXIT_FAIL)
			return
		snapshots.append(measured)
	var report: Dictionary = {
		"settings": metrics_settings,
		"snapshots": snapshots,
		"totals": LoopLib.metric_totals(snapshots),
	}
	var text: String = JSON.stringify(report, "\t")
	if out_path.is_empty():
		print(text)
	else:
		var file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
		if file == null:
			printerr("[art-metrics] could not write: " + out_path)
			quit(EXIT_FAIL)
			return
		file.store_string(text + "\n")
		file.close()
		print("[art-metrics] wrote %s (%d image(s))" % [out_path, snapshots.size()])
	quit(EXIT_OK)
