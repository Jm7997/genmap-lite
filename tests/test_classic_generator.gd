extends RefCounted
## Lo ejecuta tests/run_tests.gd (terminal) o tests/run_tests_editor.gd (File > Run). No necesita Ollama.

const Classic := preload("res://addons/genmap/classic_generator.gd")
const MapGenerator := preload("res://addons/genmap/map_generator.gd")


func _run() -> bool:
	var same := Classic.generate({"seed": 42})
	assert(same == Classic.generate({"seed": 42}), "misma semilla, mismo mapa")
	assert(same != Classic.generate({"seed": 43}), "otra semilla, otro mapa")

	var layout := Classic.generate({"width": 48, "height": 48, "rooms": 6, "chests": 5,
			"treasure_rooms": 2, "boss": true, "seed": 7})
	var w: int = layout.map_width
	var h: int = layout.map_height
	var rects: Array[Rect2i] = []
	for room: Dictionary in layout.rooms:
		var rect := Rect2i(room.x, room.y, room.width, room.height)
		assert(rect.position.x >= 1 and rect.position.y >= 1 and rect.end.x <= w - 1 and rect.end.y <= h - 1,
				"sala %s dentro del margen" % rect)
		for other in rects:
			assert(not other.grow(Classic.ROOM_GAP).intersects(rect), "salas separadas")
		rects.append(rect)
	assert(rects.size() == 6, "caben las 6 salas")
	assert(layout.corridors.size() == rects.size() - 1, "árbol de pasillos")
	var types: Array = layout.rooms.map(func(room: Dictionary) -> String: return room.type)
	assert(types[0] == "start" and types.count("boss") == 1 and types.count("treasure") == 2, str(types))

	var spawn := Vector2i(int(layout.spawn_point.x), int(layout.spawn_point.y))
	assert(rects[0].has_point(spawn), "spawn en la entrada")
	var seen := {}
	for chest: Dictionary in layout.chests:
		var cell := Vector2i(chest.x, chest.y)
		assert(not seen.has(cell) and cell != spawn, "cofres sin repetir ni encima del spawn")
		seen[cell] = true
		var in_treasure := false
		for i in rects.size():
			in_treasure = in_treasure or (types[i] == "treasure" and rects[i].has_point(cell))
		assert(in_treasure, "cofres en salas de tesoro")
	assert(layout.chests.size() == 5)

	var tiny := Classic.generate({"width": 12, "height": 12, "rooms": 20, "seed": 1})
	assert(tiny.rooms.size() >= 1 and tiny.rooms.size() < 20, "mapa diminuto: solo las salas que caben")

	# El layout pasa por el pipeline normal sin errores y ya viene conectado.
	var plan := MapGenerator.build_plan(layout, {"generate_entities": false})
	assert(not plan.has("error") and plan.corridors_added == 0, str(plan.get("error", "")))
	print("classic_generator OK")
	return true
