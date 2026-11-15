extends TestCase
## Every GDScript under res://scripts compiles (catches errors in scripts that
## no other test loads, including the untyped-declaration error rule).

const SCRIPT_ROOT: String = "res://scripts"


func test_all_project_scripts_compile() -> void:
	var paths: PackedStringArray = []
	_collect(SCRIPT_ROOT, paths)
	assert_true(paths.size() > 0, "no scripts found")
	for path: String in paths:
		var script: GDScript = load(path) as GDScript
		assert_true(script != null and script.can_instantiate(), "compile " + path)


func _collect(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for sub_dir: String in dir.get_directories():
		_collect(dir_path.path_join(sub_dir), out)
	for file_name: String in dir.get_files():
		if file_name.ends_with(".gd"):
			out.append(dir_path.path_join(file_name))
