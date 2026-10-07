extends RefCounted
## Lo ejecuta tests/run_tests.gd (terminal) o tests/run_tests_editor.gd (File > Run). No necesita Ollama.

const MapGenerator := preload("res://addons/genmap/map_generator.gd")
const NO_ENTITIES := {"generate_entities": false}
const LAYOUT := {
	"map_width": 20, "map_height": 20,
	"rooms": [
		{"x": 2, "y": 2, "width": 4, "height": 4},
		{"x": 16, "y": 5, "width": 8, "height": 3},  # se sale por la derecha → suelo x 16..18
		{"x": 30, "y": 30, "width": 5, "height": 5},  # fuera del mapa → descartada
	],
	"corridors": [{"start_x": 3, "start_y": 3, "end_x": 17, "end_y": 25}],  # end_y → 18
}


func _run() -> bool:
	var layer := _make_layer()
	_test_tiles_and_walls(layer)
	_test_plan_matches_painting(layer)
	_test_rooms_always_connected()
	_test_errors_leave_layer_intact(layer)
	layer.free()
	print("map_generator OK")
	return true


func _test_tiles_and_walls(layer: TileMapLayer) -> void:
	layer.set_cell(Vector2i(99, 99), 0, Vector2i(0, 0))  # generación anterior: debe borrarse
	var stats := MapGenerator.generate_map(LAYOUT, layer, NO_ENTITIES)
	assert(not stats.has("error"), str(stats))
	assert(stats.entities == null, "sin entidades si están desactivadas")
	assert(stats.rooms == 2 and stats.rooms_clipped == 1 and stats.rooms_discarded == 1, str(stats))
	assert(_tile_at(layer, 99, 99) == "empty", "clear() borra la generación anterior")
	assert(_tile_at(layer, 3, 3) == "floor", "interior de sala")
	assert(_tile_at(layer, 1, 1) == "wall", "esquina diagonal de la sala")
	assert(_tile_at(layer, 0, 0) == "empty", "esquina lejana vacía")
	assert(_tile_at(layer, 18, 6) == "floor", "sala recortada deja margen para la pared")
	assert(_tile_at(layer, 19, 6) == "wall", "pared en el último tile del mapa")
	assert(_tile_at(layer, 20, 6) == "empty", "nada fuera del borde derecho")
	assert(_tile_at(layer, 10, 3) == "floor", "tramo horizontal del pasillo")
	assert(_tile_at(layer, 10, 2) == "wall" and _tile_at(layer, 10, 4) == "wall", "pasillo envuelto por paredes")
	assert(_tile_at(layer, 17, 18) == "floor", "tramo vertical recortado")
	assert(_tile_at(layer, 17, 19) == "wall", "pared al final del pasillo")
	assert(_tile_at(layer, 17, 20) == "empty", "nada fuera del borde inferior")
	assert(stats.walls == layer.get_used_cells().size() - stats.cells, "paredes contadas = pintadas")

	# Ninguna celda de suelo puede tocar el vacío: el perímetro está cerrado.
	for cell in layer.get_used_cells():
		if _tile_at(layer, cell.x, cell.y) != "floor":
			continue
		for offset in MapGenerator.NEIGHBORS:
			var n: Vector2i = cell + offset
			assert(_tile_at(layer, n.x, n.y) != "empty", "suelo en %s sin pared en %s" % [cell, n])


# build_plan es la parte que corre en WorkerThreadPool: no recibe la capa y debe
# describir exactamente lo que apply_plan pinta.
func _test_plan_matches_painting(layer: TileMapLayer) -> void:
	var plan := MapGenerator.build_plan(LAYOUT, NO_ENTITIES)
	assert(not plan.has("error"), str(plan))
	var before := layer.tile_map_data
	var stats := MapGenerator.apply_plan(plan, layer, NO_ENTITIES)
	assert(plan.floors.size() == stats.cells and plan.walls.size() == stats.walls, str(stats))
	assert(stats.previous_tile_map_data == before, "apply_plan devuelve los tiles previos para deshacer")
	assert(MapGenerator.apply_plan({"error": "x"}, layer).has("error"), "un plan con error se propaga")
	# Orden por filas: los lotes del pintado por frames son franjas compactas.
	for cells in [plan.floors, plan.walls]:
		for i in range(1, cells.size()):
			var a: Vector2i = cells[i - 1]
			var b: Vector2i = cells[i]
			assert(a.y < b.y or (a.y == b.y and a.x < b.x), "orden por filas roto en %s -> %s" % [a, b])


# Salas sin pasillos (o mal conectadas por el modelo) se unen hasta que todas son alcanzables.
func _test_rooms_always_connected() -> void:
	var isolated := {
		"map_width": 30, "map_height": 20,
		"rooms": [
			{"x": 2, "y": 2, "width": 4, "height": 4},
			{"x": 20, "y": 12, "width": 5, "height": 5},
			{"x": 20, "y": 2, "width": 3, "height": 3},
		],
		"corridors": [],
	}
	var plan := MapGenerator.build_plan(isolated, NO_ENTITIES)
	assert(plan.corridors_added == 2, str(plan.corridors_added))
	var floors := {}
	for cell in plan.floors:
		floors[cell] = true
	var reached := MapGenerator._flood(floors, Vector2i(4, 4))
	for room in isolated.rooms:
		var center := Vector2i(room.x + room.width / 2, room.y + room.height / 2)
		assert(reached.has(center), "sala en %s inalcanzable" % center)
	assert(MapGenerator.build_plan(LAYOUT, NO_ENTITIES).corridors_added == 0, "ya conectado: no se añade nada")


func _test_errors_leave_layer_intact(layer: TileMapLayer) -> void:
	MapGenerator.generate_map(LAYOUT, layer, NO_ENTITIES)
	var before := layer.tile_map_data
	var cases := {
		"sin habitaciones válidas": MapGenerator.generate_map(
			{"map_width": 10, "map_height": 10, "rooms": [{"x": 50, "y": 50, "width": 3, "height": 3}], "corridors": []},
			layer, NO_ENTITIES),
		"tile de muro inexistente": MapGenerator.generate_map(LAYOUT, layer, {"wall_atlas_coords": Vector2i(5, 5)}),
		"source inexistente": MapGenerator.generate_map(LAYOUT, layer, {"floor_source_id": 7}),
	}
	for label in cases:
		assert(cases[label].has("error"), "%s debe ser un error" % label)
	assert(layer.tile_map_data == before, "un error no toca la capa")


func _make_layer() -> TileMapLayer:
	var atlas := TileSetAtlasSource.new()
	atlas.texture = ImageTexture.create_from_image(Image.create_empty(32, 16, false, Image.FORMAT_RGBA8))
	atlas.texture_region_size = Vector2i(16, 16)
	atlas.create_tile(MapGenerator.DEFAULT_SETTINGS.floor_atlas_coords)
	atlas.create_tile(MapGenerator.DEFAULT_SETTINGS.wall_atlas_coords)
	var tile_set := TileSet.new()
	tile_set.add_source(atlas, MapGenerator.DEFAULT_SETTINGS.floor_source_id)
	var layer := TileMapLayer.new()
	layer.tile_set = tile_set
	return layer


func _tile_at(layer: TileMapLayer, x: int, y: int) -> String:
	var cell := Vector2i(x, y)
	if layer.get_cell_source_id(cell) == -1:
		return "empty"
	return "floor" if layer.get_cell_atlas_coords(cell) == MapGenerator.DEFAULT_SETTINGS.floor_atlas_coords else "wall"
