@tool
extends EditorScript
## Abrir en el Script Editor → File > Run (Ctrl+Shift+X). Ejecuta todos los tests.


func _run() -> void:
	preload("res://tests/run_tests.gd").run_all()
