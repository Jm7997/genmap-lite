@tool
extends EditorPlugin
## Integra GenMap Lite en el editor: añade el panel y lo conecta con el motor de generación,
## que registra cada mapa en el historial de deshacer.

const GenMapDock := preload("res://addons/genmap/genmap_dock.gd")
const DockScene := preload("res://addons/genmap/genmap_dock.tscn")
const GenMapApi := preload("res://addons/genmap/genmap_api.gd")

var _dock: GenMapDock
var _api: GenMapApi


func _enter_tree() -> void:
	_api = GenMapApi.new()
	_api.name = "GenMapEditorAPI"
	_api.set_editor_undo_redo(get_undo_redo())
	add_child(_api)
	_api.generation_progress.connect(_on_generation_progress)
	_api.generation_finished.connect(_on_generation_finished)
	_api.generation_failed.connect(_on_generation_failed)

	_dock = DockScene.instantiate() as GenMapDock
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	_dock.setup()
	_dock.generate_requested.connect(_on_generate_requested)
	_dock.cancel_requested.connect(_api.cancel)
	_dock.check_ollama_requested.connect(_check_ollama)
	# Al abrir el editor: marca qué modelos están instalados y avisa si Ollama no está abierto.
	_check_ollama.call_deferred()


func _exit_tree() -> void:
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()
	_dock = null
	if is_instance_valid(_api):
		_api.queue_free()  # su _exit_tree cancela la generación en curso
	_api = null


func _on_generate_requested(prompt: String, model: String, layer: TileMapLayer, settings: Dictionary) -> void:
	_dock.set_busy(true, "Generando con %s... (la primera vez carga el modelo y tarda más)" % model)
	# Sin await: el resultado llega por las señales, que se desconectan solas si el plugin se libera.
	_api.generate_dungeon(prompt, _config(layer, settings, model))


func _check_ollama() -> void:
	var result: Dictionary = await _api.check_ollama()
	if is_instance_valid(_dock):
		_dock.set_ollama_status(result)


func _on_generation_progress(stage: String, progress: float) -> void:
	if is_instance_valid(_dock):
		_dock.set_progress(stage, progress)


func _on_generation_finished(result: Dictionary) -> void:
	if not is_instance_valid(_dock):
		return
	_dock.set_busy(false)
	_dock.set_status(_describe(result), GenMapDock.Status.SUCCESS)


func _on_generation_failed(message: String) -> void:
	if not is_instance_valid(_dock):
		return
	_dock.set_busy(false)
	_dock.set_status(message, GenMapDock.Status.ERROR)


# Los ajustes se copian al pulsar: cambiarlos durante la espera no afecta a esta generación.
static func _config(layer: TileMapLayer, settings: Dictionary, model: String) -> Dictionary:
	var config := settings.duplicate(true)
	config.layer = layer
	if not model.is_empty():
		config.model = model
	return config


static func _describe(result: Dictionary) -> String:
	var parts: PackedStringArray = [
		"Mapa %dx%d: %d habitaciones, %d pasillos, %d suelos, %d paredes" % [
			result.map_size.x, result.map_size.y, result.rooms, result.corridors, result.cells, result.walls,
		],
	]
	if result.get("corridors_added", 0) > 0:
		parts.append("%d pasillos añadidos para conectar salas aisladas" % result.corridors_added)
	if result.rooms_clipped > 0 or result.rooms_discarded > 0:
		parts.append("salas ajustadas al mapa: %d recortadas, %d descartadas" % [result.rooms_clipped, result.rooms_discarded])
	return ". ".join(parts) + ". Ctrl+Z para deshacer."
