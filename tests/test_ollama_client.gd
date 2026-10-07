extends RefCounted
## Lo ejecuta tests/run_tests.gd (terminal) o tests/run_tests_editor.gd (File > Run). No necesita Ollama (no hace peticiones).

const OllamaClient := preload("res://addons/genmap/ollama_client.gd")


func _run() -> bool:
	_test_parse_requested_size()
	_test_prompt_by_map_size()
	_test_anchor_always_fits()
	_test_validate_layout()
	_test_parse_tags_response()
	print("ollama_client OK")
	return true


func _test_parse_requested_size() -> void:
	var cases := {
		"mazmorra de 20x20 con 3 habitaciones": Vector2i(20, 20),
		"cueva 16 X 12": Vector2i(16, 12),
		"cripta de 40 por 30": Vector2i(40, 30),
		"dungeon 24×18 with 2 rooms": Vector2i(24, 18),
		"mapa 300x300": Vector2i(OllamaClient.MAX_REQUESTED_SIZE, OllamaClient.MAX_REQUESTED_SIZE),
		"3 salas de 5x5 en un mapa de 40x40": Vector2i(40, 40),
		"una mazmorra grande con 5 salas": Vector2i.ZERO,
	}
	for prompt in cases:
		var size := OllamaClient.parse_requested_size(prompt)
		assert(size == cases[prompt], "%s -> %s (esperado %s)" % [prompt, size, cases[prompt]])


func _test_prompt_by_map_size() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7

	var small := OllamaClient.build_system_prompt(true, Vector2i(16, 16), rng)
	assert(not small.contains("Example"), "mapa pequeño: sin ejemplo one-shot")
	assert(small.contains("top-left corner exactly at"), "mapa pequeño: con ancla aleatoria")

	var big := OllamaClient.build_system_prompt(true, Vector2i(64, 64), rng)
	assert(big.contains("Example") and not big.contains("exactly at"), "mapa grande: ejemplo y sin ancla")

	var unknown := OllamaClient.build_system_prompt(false, Vector2i.ZERO, rng)
	assert(unknown.contains("Example"), "sin tamaño: se trata como mapa por defecto (32x32)")
	assert(not unknown.contains("spawn_point"), "sin entidades: ni reglas ni ejemplo de entidades")

	var small_body := OllamaClient.build_request_body("cueva 12x12", "qwen3:8b", true, rng)
	assert(small_body.options.has("seed") and small_body.options.temperature == OllamaClient.SMALL_MAP_TEMPERATURE)
	assert(small_body.think == false and small_body.stream == false)
	var big_body := OllamaClient.build_request_body("mazmorra 64x64", "qwen3:8b", false, rng)
	assert(not big_body.options.has("seed") and not ("chests" in big_body.format.required))


# La sala 0 mínima (3x3) debe caber con margen 1 en cualquier mapa pequeño.
func _test_anchor_always_fits() -> void:
	var rng := RandomNumberGenerator.new()
	for i in 500:
		rng.seed = i
		var size := Vector2i(rng.randi_range(3, 29), rng.randi_range(3, 29))
		var anchor := OllamaClient.random_anchor(size, rng)
		assert(anchor.x >= 1 and anchor.y >= 1, "ancla %s en %s" % [anchor, size])
		if size.x >= 5:
			assert(anchor.x + OllamaClient.MIN_ROOM_SIZE <= size.x - 1, "ancla %s no cabe en %s" % [anchor, size])
		if size.y >= 5:
			assert(anchor.y + OllamaClient.MIN_ROOM_SIZE <= size.y - 1, "ancla %s no cabe en %s" % [anchor, size])


func _test_validate_layout() -> void:
	var good := {
		"map_width": 20.0, "map_height": 20.0,  # JSON siempre trae floats
		"rooms": [{"x": 2.0, "y": 2.0, "width": 4.0, "height": 4.0}],
		"corridors": [],
		"spawn_point": {"x": 3.0, "y": 3.0},
		"chests": [],
	}
	var ok := OllamaClient.validate_layout(good, true)
	assert(ok.has("data") and ok.data.rooms[0].x is int, str(ok))
	assert(OllamaClient.validate_layout(good, false).data.has("spawn_point") == false)

	var bad_room: Dictionary = good.duplicate(true)
	bad_room.rooms = [{"x": "2", "y": 2, "width": 4, "height": 4}]
	assert(OllamaClient.validate_layout(bad_room, false).has("error"), "coordenada no numérica")

	var no_spawn: Dictionary = good.duplicate(true)
	no_spawn.erase("spawn_point")
	assert(OllamaClient.validate_layout(no_spawn, false).has("data"), "spawn no hace falta sin entidades")

	assert(OllamaClient.validate_layout([], false).has("error"), "la raíz debe ser un objeto")


func _test_parse_tags_response() -> void:
	var host := OllamaClient.DEFAULT_HOST
	var body := '{"models":[{"name":"qwen3:8b","size":5225388164},{"name":"mistral:latest"}]}'.to_utf8_buffer()
	var ok := OllamaClient.parse_tags_response(HTTPRequest.RESULT_SUCCESS, 200, body, host)
	assert(ok.ok and "qwen3:8b" in ok.models and ok.models.size() == 2, str(ok))
	var down := OllamaClient.parse_tags_response(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray(), host)
	assert(not down.ok and down.error.contains("no responde"), str(down))
	assert(not OllamaClient.parse_tags_response(HTTPRequest.RESULT_SUCCESS, 500, body, host).ok)
	assert(not OllamaClient.parse_tags_response(HTTPRequest.RESULT_SUCCESS, 200, "<html>".to_utf8_buffer(), host).ok, "otro servidor en el puerto")
