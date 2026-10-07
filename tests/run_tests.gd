extends SceneTree
## Ejecuta todos los tests sin abrir el editor:
##   godot --headless --path <proyecto> --script res://tests/run_tests.gd
## Sale con código 1 si alguno falla. Un assert fallido aborta su test y lo marca como fallo.

const TESTS := [
	"res://tests/test_map_generator.gd",
	"res://tests/test_ollama_client.gd",
	"res://tests/test_genmap_api.gd",  # solo en Pro; se omite si no existe
]


func _init() -> void:
	quit(1 if run_all() > 0 else 0)


## Devuelve el número de tests fallidos. También lo usa run_tests_editor.gd.
static func run_all() -> int:
	var failures := 0
	for path in TESTS:
		if not ResourceLoader.exists(path):
			continue
		var script := load(path) as Script
		var passed: Variant = script.new()._run() if script != null and script.can_instantiate() else null
		if passed != true:
			failures += 1
			printerr("FALLO: %s" % path)
	print("Todos los tests OK" if failures == 0 else "%d test(s) con fallos" % failures)
	return failures
