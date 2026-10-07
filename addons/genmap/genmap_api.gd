@tool
class_name GenMap
extends Node
## Motor de generación de GenMap Lite: lo usa el panel del editor. Pide el layout a Ollama,
## calcula el plan en un hilo aparte y pinta por lotes, con deshacer.
##
## GenMap Pro añade la API para usar GenMap desde el código de tu juego (autoload
## [code]GenMapAPI[/code]), exportar e importar mapas JSON, terrenos (autotiling) y entidades.

## Emitida al empezar una generación. [param prompt] está vacío si viene de un layout o archivo.
signal generation_started(prompt: String)
## Emitida durante la generación. [param stage] es [code]"ollama"[/code] (esperando al modelo),
## [code]"plan"[/code] (cálculo en segundo plano) o [code]"paint"[/code] (pintado por lotes).
## [param progress] va de 0.0 a 1.0, o vale -1.0 cuando no se puede medir.
signal generation_progress(stage: String, progress: float)
## Emitida al terminar con éxito, con el mismo diccionario que devuelve la corrutina.
signal generation_finished(result: Dictionary)
## Emitida si la generación falla o se cancela.
signal generation_failed(message: String)

const OllamaClient := preload("res://addons/genmap/ollama_client.gd")
const MapGenerator := preload("res://addons/genmap/map_generator.gd")
## Modelo de Ollama usado si [code]config[/code] no indica otro.
const DEFAULT_MODEL := "qwen3:8b"
const UNDO_ACTION_NAME := "GenMap: generar mapa"

var _client: OllamaClient
# EditorUndoRedoManager en el editor. Sin tipo a propósito: nombrar la clase rompería las
# builds exportadas, y tiparlo como Object haría fallar las llamadas en el análisis estático.
var _editor_undo_redo = null
var _busy := false
var _generation := 0  # se incrementa al empezar o cancelar; descarta resultados obsoletos


## Solo para el plugin del editor: activa el registro de cada generación en el historial de deshacer.
func set_editor_undo_redo(undo_redo) -> void:
	_editor_undo_redo = undo_redo


## Devuelve [code]true[/code] mientras hay una generación en curso. Solo puede haber una a la vez.
func is_busy() -> bool:
	return _busy


## Cancela la generación en curso. Si ya se estaba pintando, la capa vuelve a su estado anterior.
## Quien la esperaba recibe [code]{"error": "Generación cancelada."}[/code].
func cancel() -> void:
	if not _busy:
		return
	_generation += 1
	if _client != null:
		_client.cancel()


## Genera un mapa a partir de un prompt en lenguaje natural usando Ollama.
## Pasos: petición a Ollama, cálculo del plan en [WorkerThreadPool] y pintado por lotes en el hilo principal.
func generate_dungeon(prompt: String, config: Dictionary = {}) -> Dictionary:
	if not Engine.is_editor_hint():
		return _reject("GenMap Lite genera desde el panel del editor. La generación en tu juego es de GenMap Pro.")
	var start_error := _check_can_start(config)
	if not start_error.is_empty():
		return _reject(start_error)
	if prompt.strip_edges().is_empty():
		return _reject("El prompt está vacío.")

	var generation := _begin(prompt)
	var settings := _settings_from(config)
	var layer_id := (config.layer as TileMapLayer).get_instance_id()
	var model := str(config.get("model", DEFAULT_MODEL))

	var client := _get_client()
	client.host = str(config.get("host", OllamaClient.DEFAULT_HOST))
	client.timeout_seconds = float(config.get("timeout", OllamaClient.DEFAULT_TIMEOUT_SECONDS))
	generation_progress.emit("ollama", -1.0)
	client.generate(prompt, model, settings.generate_entities == true)
	var outcome: Dictionary = await client.completed

	if generation != _generation:
		return _stale()
	if outcome.has("error"):
		return _end(outcome)
	var meta := {"prompt": prompt, "model": model}
	return await _build_and_apply(outcome.data, meta, layer_id, settings, config, generation)


## Comprueba si Ollama responde y qué modelos tiene instalados, sin generar nada.
## Devuelve [code]{"ok": true, "models": PackedStringArray, "host": String}[/code] o
## [code]{"ok": false, "error": String, "host": String}[/code]. Tarda como mucho 5 segundos.
func check_ollama(config: Dictionary = {}) -> Dictionary:
	var client := _get_client()
	client.check_status(str(config.get("host", OllamaClient.DEFAULT_HOST)))
	return await client.status_checked


func _exit_tree() -> void:
	cancel()


func _build_and_apply(map_data: Dictionary, meta: Dictionary, layer_id: int, settings: Dictionary,
		config: Dictionary, generation: int) -> Dictionary:
	# Matemáticas en un hilo del pool; job.done llega ya en el hilo principal (call_deferred).
	generation_progress.emit("plan", -1.0)
	var job := MapGenerator.start_plan(map_data, settings)
	var plan: Dictionary = await job.done
	if generation != _generation:
		return _stale()

	# Tras cada await la capa pudo liberarse: se recupera por id, nunca por referencia guardada.
	var layer := instance_from_id(layer_id) as TileMapLayer
	if layer == null or not layer.is_inside_tree():
		return _end({"error": "El TileMapLayer destino se eliminó durante la generación."})

	var chunk_size := int(config.get("chunk_size", MapGenerator.DEFAULT_CHUNK_SIZE))
	var result: Dictionary
	if chunk_size <= 0:
		result = MapGenerator.apply_plan(plan, layer, settings)
	else:
		generation_progress.emit("paint", 0.0)
		result = await MapGenerator.apply_plan_async(plan, layer, settings, chunk_size,
				func(ratio: float) -> void: generation_progress.emit("paint", ratio),
				func() -> bool: return generation != _generation)
	if generation != _generation:
		return _stale()
	if result.has("error"):
		return _end(result)

	layer = instance_from_id(layer_id) as TileMapLayer
	_attach(layer, result.previous_tile_map_data, result.entities)
	return _end(result)


# Inserta las entidades nuevas en lugar de las anteriores y, en el editor, registra
# tiles + entidades en una sola acción de deshacer.
func _attach(layer: TileMapLayer, previous_tiles: PackedByteArray, entities: Node2D) -> void:
	var old_entities := layer.get_node_or_null(NodePath(MapGenerator.ENTITIES_NODE_NAME))
	if Engine.is_editor_hint() and _editor_undo_redo != null:
		_commit_editor_action(layer, previous_tiles, old_entities, entities)
		return

	if old_entities != null:
		layer.remove_child(old_entities)
		old_entities.queue_free()
	if entities != null:
		layer.add_child(entities, true)
		if Engine.is_editor_hint():
			# Llamado desde un @tool sin plugin: al menos que se guarde con la escena.
			var scene_owner: Node = layer.owner if layer.owner != null else layer
			entities.owner = scene_owner
			for child in entities.get_children():
				child.owner = scene_owner


# Ctrl+Z restaura los tiles y las entidades anteriores; Ctrl+Shift+Z vuelve a poner las nuevas.
func _commit_editor_action(layer: TileMapLayer, previous_tiles: PackedByteArray, old_entities: Node, entities: Node2D) -> void:
	var scene_owner: Node = layer.owner if layer.owner != null else layer
	# Al sacar un nodo del árbol pierde su owner; se guardan para restaurarlos al deshacer.
	var old_owned: Array[Node] = []
	if old_entities != null:
		old_owned = _nodes_owned_by(old_entities, scene_owner)
	var new_owned: Array[Node] = []
	if entities != null:
		new_owned.append(entities)
		new_owned.append_array(entities.get_children())

	var undo_redo = _editor_undo_redo
	undo_redo.create_action(UNDO_ACTION_NAME, UndoRedo.MERGE_DISABLE, layer)
	undo_redo.add_do_property(layer, "tile_map_data", layer.tile_map_data)
	undo_redo.add_undo_property(layer, "tile_map_data", previous_tiles)

	# Do: quitar las entidades viejas y luego añadir las nuevas (mismo nombre, nunca a la vez).
	if old_entities != null:
		undo_redo.add_do_method(layer, "remove_child", old_entities)
		undo_redo.add_undo_reference(old_entities)
	if entities != null:
		undo_redo.add_do_method(layer, "add_child", entities, true)
		for node in new_owned:
			undo_redo.add_do_method(node, "set_owner", scene_owner)
		undo_redo.add_do_reference(entities)

	# Undo: quitar las nuevas y luego devolver las viejas, en ese orden.
	if entities != null:
		undo_redo.add_undo_method(layer, "remove_child", entities)
	if old_entities != null:
		undo_redo.add_undo_method(layer, "add_child", old_entities, true)
		for node in old_owned:
			undo_redo.add_undo_method(node, "set_owner", scene_owner)

	# Ejecuta el do: los tiles ya están pintados (asignación idempotente) y se insertan los nodos.
	undo_redo.commit_action()


func _check_can_start(config: Dictionary) -> String:
	if _busy:
		return "Ya hay una generación en curso."
	if not is_inside_tree():
		return "GenMapAPI no está en el árbol de escena."
	var layer: Variant = config.get("layer")
	# is_instance_valid primero: `is` sobre un objeto liberado da error.
	if not is_instance_valid(layer) or not (layer is TileMapLayer):
		return "config.layer debe ser un TileMapLayer válido."
	if not (layer as TileMapLayer).is_inside_tree():
		return "El TileMapLayer destino no está en el árbol de escena."
	return MapGenerator.validate_layer(layer, _settings_from(config))


func _settings_from(config: Dictionary) -> Dictionary:
	var settings := {}
	for key in MapGenerator.DEFAULT_SETTINGS:
		if config.has(key):
			settings[key] = config[key]
	return MapGenerator.DEFAULT_SETTINGS.merged(settings, true)


func _get_client() -> OllamaClient:
	# Perezoso: el cliente HTTP no se crea hasta la primera petición.
	if _client == null:
		_client = OllamaClient.new()
		_client.name = "OllamaClient"
		add_child(_client)
	return _client


func _begin(prompt: String) -> int:
	_busy = true
	_generation += 1
	generation_started.emit(prompt)
	return _generation


func _end(result: Dictionary) -> Dictionary:
	_busy = false
	if result.has("error"):
		generation_failed.emit(result.error)
	else:
		generation_finished.emit(result)
	return result


# Resultado de una generación cancelada o sustituida: no se pinta nada.
func _stale() -> Dictionary:
	_busy = false
	var result := {"error": "Generación cancelada."}
	generation_failed.emit(result.error)
	return result


# Error antes de empezar: no cambia el estado (puede haber otra generación en curso).
func _reject(message: String) -> Dictionary:
	generation_failed.emit(message)
	return {"error": message}


static func _nodes_owned_by(root: Node, scene_owner: Node) -> Array[Node]:
	var result: Array[Node] = []
	if root.owner == scene_owner:
		result.append(root)
	for child in root.get_children():
		result.append_array(_nodes_owned_by(child, scene_owner))
	return result
