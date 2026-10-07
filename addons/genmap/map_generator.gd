@tool
extends RefCounted
## Pintor de GenMap: convierte el layout validado por ollama_client en tiles y entidades.
##
## Tres etapas, separadas por hilo:
##   1. validate_layer()  hilo principal  lee el TileSet de la capa.
##   2. build_plan()      cualquier hilo  puro: recorte, suelo, muros y celdas de entidades.
##                                        No toca nodos ni recursos, así que es thread-safe.
##   3. apply_plan()      hilo principal  crea nodos, clear() y pinta de una vez.
##      apply_plan_async() igual, pero en lotes repartidos entre frames (corrutina).
## start_plan() ejecuta la etapa 2 en WorkerThreadPool y vuelve al hilo principal con
## call_deferred(); generate_map() hace las tres de forma síncrona (tests, mapas pequeños).
##
## Geometría: suelo dentro de [1, w-2] x [1, h-2]; la franja exterior queda reservada para
## que las paredes cierren siempre el perímetro sin salirse de [0, w-1] x [0, h-1].
## Nada aquí usa clases del editor: funciona igual en un juego exportado.

## Tarea en segundo plano devuelta por start_plan(). Uso: var plan = await job.done
class PlanJob extends RefCounted:
	signal done(plan: Dictionary)

	var task_id := -1

	func _finish(plan: Dictionary) -> void:
		# Obligatorio: toda tarea de WorkerThreadPool debe esperarse para liberarla.
		# Aquí ya ha terminado (esto se llama al final de la tarea), así que no bloquea.
		if task_id != -1:
			WorkerThreadPool.wait_for_task_completion(task_id)
			task_id = -1
		done.emit(plan)


const ENTITIES_NODE_NAME := "GenMapEntities"
const SPAWN_NODE_NAME := "PlayerSpawn"
const CHEST_NODE_PREFIX := "Chest"
const MIN_MAP_SIZE := 3  # 1 de suelo + 2 de pared
const INVALID_CELL := Vector2i(-1, -1)
const MAX_MAP_SIZE := 48  # GenMap Pro admite hasta 128x128
const DEFAULT_CHUNK_SIZE := 400  # celdas por frame en apply_plan_async
const ORTHOGONAL: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const NEIGHBORS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]

## Ajustes por defecto. Cualquier clave puede sobrescribirse; las que falten se toman de aquí.
const DEFAULT_SETTINGS := {
	"floor_source_id": 0,
	"floor_atlas_coords": Vector2i(0, 0),
	"wall_source_id": 0,
	"wall_atlas_coords": Vector2i(1, 0),  # pared a la derecha del suelo en el atlas
	"generate_entities": false,  # spawn y cofres: GenMap Pro
}


## Síncrono: valida, planifica y pinta en el hilo actual (debe ser el principal).
## Si algo impide generar devuelve {"error": String} y la capa queda intacta.
## Si no, devuelve estadísticas, "entities" (Node2D sin padre o null; quien llama debe
## añadirlo al árbol o liberarlo) y "previous_tile_map_data" (para deshacer).
static func generate_map(map_data: Dictionary, target_layer: TileMapLayer, settings: Dictionary = {}) -> Dictionary:
	var config := DEFAULT_SETTINGS.merged(settings, true)
	var layer_error := validate_layer(target_layer, config)
	if not layer_error.is_empty():
		return _fail(layer_error)
	return apply_plan(build_plan(map_data, config), target_layer, config)


## Lanza build_plan() en WorkerThreadPool. El resultado llega en el hilo principal por job.done.
static func start_plan(map_data: Dictionary, settings: Dictionary = {}) -> PlanJob:
	var job := PlanJob.new()
	# Copias propias: el hilo nunca comparte diccionarios mutables con el hilo principal.
	var data := map_data.duplicate(true)
	var config := DEFAULT_SETTINGS.merged(settings, true).duplicate(true)
	var work := func() -> void:
		job._finish.call_deferred(build_plan(data, config))
	# task_id se asigna antes de que _finish pueda ejecutarse: las llamadas diferidas
	# solo se procesan cuando el hilo principal termina el código actual.
	job.task_id = WorkerThreadPool.add_task(work, false, "GenMap: plan del mapa")
	return job


## Comprueba que la capa y su TileSet admiten los ajustes. Hilo principal.
## Devuelve "" si todo está bien o un mensaje de error.
static func validate_layer(layer: TileMapLayer, settings: Dictionary = {}) -> String:
	if layer == null or not is_instance_valid(layer):
		return "El TileMapLayer destino ya no existe."
	var config := DEFAULT_SETTINGS.merged(settings, true)
	var tile_set := layer.tile_set
	if tile_set == null:
		return "El TileMapLayer '%s' no tiene TileSet." % layer.name

	var floor_error := _check_tile(tile_set, "suelo", _as_int(config.floor_source_id), config.floor_atlas_coords)
	if not floor_error.is_empty():
		return floor_error
	return _check_tile(tile_set, "muro", _as_int(config.wall_source_id), config.wall_atlas_coords)


## Etapa pura y thread-safe: solo lee map_data/settings y devuelve datos.
## Devuelve {"error"} o un plan con celdas de suelo, muros y entidades.
static func build_plan(map_data: Dictionary, settings: Dictionary = {}) -> Dictionary:
	var config := DEFAULT_SETTINGS.merged(settings, true)
	var w := mini(_int(map_data, "map_width"), MAX_MAP_SIZE)
	var h := mini(_int(map_data, "map_height"), MAX_MAP_SIZE)
	if w < MIN_MAP_SIZE or h < MIN_MAP_SIZE:
		return _fail("Tamaño de mapa inválido (%dx%d); mínimo %dx%d." % [w, h, MIN_MAP_SIZE, MIN_MAP_SIZE])
	var floor_bounds := Rect2i(1, 1, w - 2, h - 2)

	var floors := {}  # Vector2i -> true; conjunto para no repetir celdas
	var room_rects: Array[Rect2i] = []
	var rooms_clipped := 0
	var rooms_discarded := 0
	for room in _array(map_data, "rooms"):
		if not (room is Dictionary):
			rooms_discarded += 1
			continue
		var raw := Rect2i(_int(room, "x"), _int(room, "y"), _int(room, "width"), _int(room, "height"))
		if raw.size.x <= 0 or raw.size.y <= 0:
			rooms_discarded += 1
			continue
		var rect := raw.intersection(floor_bounds)
		if not rect.has_area():
			rooms_discarded += 1  # completamente fuera del mapa
			continue
		if rect != raw:
			rooms_clipped += 1
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				floors[Vector2i(x, y)] = true
		room_rects.append(rect)

	if room_rects.is_empty():
		return _fail("Ninguna habitación cae dentro del mapa %dx%d. Prueba de nuevo." % [w, h])

	var corridors := 0
	for corridor in _array(map_data, "corridors"):
		if not (corridor is Dictionary):
			continue
		var start := Vector2i(clampi(_int(corridor, "start_x"), 1, w - 2), clampi(_int(corridor, "start_y"), 1, h - 2))
		var end := Vector2i(clampi(_int(corridor, "end_x"), 1, w - 2), clampi(_int(corridor, "end_y"), 1, h - 2))
		_carve_l(floors, start, end)
		corridors += 1
	# El modelo no siempre conecta todas las salas: se garantiza que el nivel sea jugable.
	var corridors_added := _connect_rooms(floors, room_rects)

	var floor_cells: Array[Vector2i] = []
	floor_cells.assign(floors.keys())
	var wall_cells := _generate_walls(floors, Vector2i(w, h))
	# Orden por filas: cada lote del pintado por frames es una franja compacta, lo que reduce
	# las costuras entre llamadas a set_cells_terrain_connect. Se ordena aquí, en el hilo del pool.
	var row_major := func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x)
	floor_cells.sort_custom(row_major)
	wall_cells.sort_custom(row_major)
	var no_chests: Array[Vector2i] = []
	var plan := {
		"map_size": Vector2i(w, h),
		"floors": floor_cells,
		"walls": wall_cells,
		"rooms": room_rects.size(),
		"rooms_clipped": rooms_clipped,
		"rooms_discarded": rooms_discarded,
		"corridors": corridors,
		"corridors_added": corridors_added,
		"entities_enabled": config.generate_entities == true,
		"spawn_cell": Vector2i(-1, -1),
		"spawn_fallback": false,
		"chest_cells": no_chests,
		"chests_moved": 0,
		"chests_discarded": 0,
	}
	return plan


## Etapa de hilo principal, de una vez: crea las entidades y pinta todo en este frame.
## Un plan con "error" se devuelve tal cual. Si falla algo, la capa queda intacta.
static func apply_plan(plan: Dictionary, target_layer: TileMapLayer, settings: Dictionary = {}) -> Dictionary:
	var config := DEFAULT_SETTINGS.merged(settings, true)
	var prepared := _prepare_apply(plan, target_layer, config)
	if prepared.has("error"):
		return prepared
	target_layer.clear()
	_paint(target_layer, plan.floors, false, config)
	_paint(target_layer, plan.walls, true, config)
	return _apply_result(plan, prepared)


## Igual que apply_plan pero repartido en frames: pinta lotes de chunk_size celdas y cede el
## control al motor con `await process_frame` tras cada uno, para no congelar el editor ni el
## juego en mapas grandes (set_cells_terrain_connect solo puede ir en el hilo principal).
## on_progress(ratio: float) se llama tras cada lote. Si is_cancelled() devuelve true o la capa
## se libera entre lotes, se restauran los tiles anteriores, se liberan las entidades y se
## devuelve {"error"}. Uso: var result = await MapGenerator.apply_plan_async(...)
static func apply_plan_async(plan: Dictionary, target_layer: TileMapLayer, settings: Dictionary = {},
		chunk_size := DEFAULT_CHUNK_SIZE, on_progress := Callable(), is_cancelled := Callable()) -> Dictionary:
	var config := DEFAULT_SETTINGS.merged(settings, true)
	var prepared := _prepare_apply(plan, target_layer, config)
	if prepared.has("error"):
		return prepared
	var tree := target_layer.get_tree()
	if tree == null:
		_free_entities(prepared)
		return _fail("El TileMapLayer destino no está en el árbol de escena.")

	var layer_id := target_layer.get_instance_id()
	var layer: TileMapLayer = target_layer
	var batch := maxi(chunk_size, 1)
	var total: int = plan.floors.size() + plan.walls.size()
	var painted := 0
	layer.clear()
	# Suelo completo antes que muros: con terrenos, el muro ajusta los bordes del suelo vecino.
	for pass_cells in [[plan.floors, false], [plan.walls, true]]:
		var cells: Array[Vector2i] = pass_cells[0]
		var is_wall: bool = pass_cells[1]
		for start in range(0, cells.size(), batch):
			var chunk: Array[Vector2i] = []
			chunk.assign(cells.slice(start, start + batch))
			_paint(layer, chunk, is_wall, config)
			painted += chunk.size()
			if on_progress.is_valid():
				on_progress.call(float(painted) / maxf(total, 1.0))
			await tree.process_frame

			# Tras el await nada está garantizado: la capa se recupera por id.
			layer = instance_from_id(layer_id) as TileMapLayer
			if layer == null or not layer.is_inside_tree():
				_free_entities(prepared)
				return _fail("El TileMapLayer destino se eliminó durante el pintado.")
			if is_cancelled.is_valid() and is_cancelled.call():
				layer.tile_map_data = prepared.previous
				_free_entities(prepared)
				return _fail("Generación cancelada.")

	return _apply_result(plan, prepared)


## Validación y entidades, todo antes de tocar un solo tile.
## Devuelve {"entities": Node2D o null, "previous": PackedByteArray} o {"error"}.
static func _prepare_apply(plan: Dictionary, layer: TileMapLayer, config: Dictionary) -> Dictionary:
	if plan.has("error"):
		return plan
	# Se revalida: el TileSet pudo cambiar mientras el plan se calculaba en otro hilo.
	var layer_error := validate_layer(layer, config)
	if not layer_error.is_empty():
		return _fail(layer_error)
	var entities: Node2D = null
	return {"entities": entities, "previous": layer.tile_map_data}


static func _paint(layer: TileMapLayer, cells: Array[Vector2i], is_wall: bool, config: Dictionary) -> void:
	if cells.is_empty():
		return
	var source := _as_int(config.wall_source_id if is_wall else config.floor_source_id)
	var atlas: Vector2i = config.wall_atlas_coords if is_wall else config.floor_atlas_coords
	for cell in cells:
		layer.set_cell(cell, source, atlas)


static func _apply_result(plan: Dictionary, prepared: Dictionary) -> Dictionary:
	return {
		"map_size": plan.map_size,
		"rooms": plan.rooms,
		"rooms_clipped": plan.rooms_clipped,
		"rooms_discarded": plan.rooms_discarded,
		"corridors": plan.corridors,
		"corridors_added": plan.corridors_added,
		"cells": plan.floors.size(),
		"walls": plan.walls.size(),
		"entities": prepared.entities,
		"spawn_fallback": plan.spawn_fallback,
		"chests": plan.chest_cells.size() if plan.entities_enabled else 0,
		"chests_moved": plan.chests_moved,
		"chests_discarded": plan.chests_discarded,
		"previous_tile_map_data": prepared.previous,
	}


static func _free_entities(prepared: Dictionary) -> void:
	var entities: Variant = prepared.get("entities")
	if entities is Node and is_instance_valid(entities):
		entities.free()


## Pasillo en L: primero en X por la fila de start, luego en Y por la columna de end.
## Ambos extremos ya vienen recortados, así que todo el trazado queda dentro de la zona de suelo.
static func _carve_l(floors: Dictionary, start: Vector2i, end: Vector2i) -> void:
	for x in range(mini(start.x, end.x), maxi(start.x, end.x) + 1):
		floors[Vector2i(x, start.y)] = true
	for y in range(mini(start.y, end.y), maxi(start.y, end.y) + 1):
		floors[Vector2i(end.x, y)] = true


## Garantiza que todas las salas sean alcanzables desde la sala 0 caminando en 4 direcciones:
## cada sala aislada se une con un pasillo en L a la sala ya conectada más cercana.
## Devuelve cuántos pasillos ha añadido.
static func _connect_rooms(floors: Dictionary, rooms: Array[Rect2i]) -> int:
	var origin := rooms[0].get_center()
	var reached := _flood(floors, origin)
	var added := 0
	# Cada vuelta conecta al menos una sala, así que nunca hacen falta más de rooms.size() vueltas.
	for _attempt in rooms.size():
		# Las celdas de una sala son contiguas: si su centro es alcanzable, toda la sala lo es.
		var best_distance := -1
		var best_from := Vector2i.ZERO
		var best_to := Vector2i.ZERO
		for room in rooms:
			var center := room.get_center()
			if reached.has(center):
				continue
			for other in rooms:
				var other_center := other.get_center()
				if not reached.has(other_center):
					continue
				var distance := absi(center.x - other_center.x) + absi(center.y - other_center.y)
				if best_distance == -1 or distance < best_distance:
					best_distance = distance
					best_from = other_center
					best_to = center
		if best_distance == -1:
			return added  # todas conectadas
		_carve_l(floors, best_from, best_to)
		added += 1
		# ponytail: re-flood completo por cada pasillo, O(salas × celdas); con ≤ 64 salas y
		# ≤ 16k celdas son milisegundos en el hilo del pool. Flood incremental si hiciera falta.
		reached = _flood(floors, origin)
	return added


## Celdas de suelo alcanzables desde start moviéndose en 4 direcciones.
static func _flood(floors: Dictionary, start: Vector2i) -> Dictionary:
	var reached := {start: true}
	var frontier: Array[Vector2i] = [start]
	while not frontier.is_empty():
		var cell: Vector2i = frontier.pop_back()
		for offset in ORTHOGONAL:
			var next: Vector2i = cell + offset
			if floors.has(next) and not reached.has(next):
				reached[next] = true
				frontier.append(next)
	return reached


## Perímetro: todo vecino (8 direcciones) de un suelo que no sea suelo es pared.
static func _generate_walls(floors: Dictionary, map_size: Vector2i) -> Array[Vector2i]:
	var bounds := Rect2i(Vector2i.ZERO, map_size)
	var seen := {}
	var walls: Array[Vector2i] = []
	for cell in floors:
		for offset in NEIGHBORS:
			var neighbor: Vector2i = cell + offset
			# Recorte de seguridad; con el margen de 1 tile nunca debería descartar nada.
			if not bounds.has_point(neighbor) or floors.has(neighbor) or seen.has(neighbor):
				continue
			seen[neighbor] = true
			walls.append(neighbor)
	return walls


static func _check_tile(tile_set: TileSet, label: String, source_id: int, coords: Variant) -> String:
	if not (coords is Vector2i):
		return "Coordenadas de atlas inválidas para %s." % label
	if not tile_set.has_source(source_id):
		return "El TileSet no tiene source %d para %s. Revisa los ajustes avanzados." % [source_id, label]
	var atlas := tile_set.get_source(source_id) as TileSetAtlasSource
	if atlas == null:
		return "El source %d (%s) no es un atlas de tiles." % [source_id, label]
	if not atlas.has_tile(coords):
		return "El atlas %d no tiene tile de %s en %s. Revisa los ajustes avanzados." % [source_id, label, coords]
	return ""


static func _int(data: Dictionary, key: String) -> int:
	return _as_int(data.get(key))


static func _as_int(value: Variant) -> int:
	return int(value) if value is int or value is float else 0


static func _array(data: Dictionary, key: String) -> Array:
	var value: Variant = data.get(key)
	return value if value is Array else []


static func _fail(message: String) -> Dictionary:
	return {"error": message}
