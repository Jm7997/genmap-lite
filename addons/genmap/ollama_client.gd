@tool
extends Node
## Capa de red de GenMap: pide a Ollama un layout de mazmorra (y opcionalmente entidades)
## y lo devuelve validado. Una petición a la vez; cada una usa su propio HTTPRequest,
## que se libera al terminar. Sin clases del editor: funciona en juegos exportados.
##
## Todo resultado se emite por `completed` ({"data"} o {"error"}) y además por
## `generation_success` / `error_occurred`. Siempre de forma diferida, nunca dentro de
## generate(), para que quien hace `await client.completed` no pierda la señal.

signal completed(outcome: Dictionary)
signal generation_success(map_data: Dictionary)
signal error_occurred(message: String)
## Resultado de check_status(): {"ok": true, "models": PackedStringArray, "host"} o {"ok": false, "error", "host"}.
signal status_checked(result: Dictionary)

const DEFAULT_HOST := "127.0.0.1:11434"  # 127.0.0.1 y no localhost: en Windows localhost puede ir por IPv6
const DEFAULT_TIMEOUT_SECONDS := 180.0  # la primera petición carga el modelo en memoria
const STATUS_TIMEOUT_SECONDS := 5.0  # /api/tags responde al instante si Ollama está vivo
const BODY_SIZE_LIMIT := 1 << 20  # 1 MiB; un layout válido ocupa < 10 KiB
const KEEP_ALIVE := "10m"
const TEMPERATURE := 0.3
const SMALL_MAP_TEMPERATURE := 0.6  # mapas pequeños: más variedad, el esquema sigue garantizando el formato
const SMALL_MAP_AREA := 900  # < 30x30 se considera pequeño: sin ejemplo y con ancla aleatoria
const MIN_ROOM_SIZE := 3
const MAX_ROOMS := 64
const MAX_CORRIDORS := 128
const MAX_CHESTS := 64
const MAX_ABS_VALUE := 4096  # descarta números absurdos; el recorte al mapa lo hace map_generator
const MAX_REQUESTED_SIZE := 48  # GenMap Pro admite hasta 128x128

const MAP_KEYS := ["map_width", "map_height"]
const ROOM_KEYS := ["x", "y", "width", "height"]
const CORRIDOR_KEYS := ["start_x", "start_y", "end_x", "end_y"]
const POINT_KEYS := ["x", "y"]

const PROMPT_RULES := """You are GenMap, a 2D dungeon layout generator for a tile-based game engine.
Output ONLY one JSON object that matches the provided schema.
Never write conversational text, explanations, markdown, code fences or comments.

Coordinates are integer tile positions. Origin (0,0) is the top-left corner; x grows to the right, y grows down.

Fields:
- map_width, map_height: map size in tiles. Use the size the user asks for. Default 32x32. Minimum 8, maximum {max_size}.
- rooms: rectangles {x, y, width, height}. (x, y) is the top-left tile of the room.
- corridors: paths {start_x, start_y, end_x, end_y}. Start inside one room and end inside another.
  The path goes horizontally from start_x to end_x along row start_y, then vertically from start_y to end_y along column end_x.

Rules:
- Create exactly the number of rooms the user asks for (default 4). Minimum room size 3x3.
- Keep every room fully inside the map with a 1-tile margin: x >= 1, y >= 1, x + width <= map_width - 1, y + height <= map_height - 1.
- Rooms must not overlap; leave at least 2 tiles between them.
- Every room must be reachable from every other room through corridors.
- Use different widths and heights for different rooms.
- If the request is ambiguous, pick sensible values. Never ask questions."""

## Regla generada para mapas pequeños, donde el modelo tiende a repetir salas conocidas.
const PROMPT_ANCHOR_RULE := """Variation rule (mandatory, overrides any habit):
- Room 0 must have its top-left corner exactly at x=%d, y=%d.
- Spread the other rooms over the remaining free space of the map; do not reuse positions from previous answers."""

# Tamaño poco habitual a propósito: si el modelo copia el ejemplo, no coincide con lo que se pide.
const EXAMPLE_REQUEST := "dungeon 46x34 with 2 rooms"
const EXAMPLE_LAYOUT := {
	"map_width": 46,
	"map_height": 34,
	"rooms": [{"x": 3, "y": 4, "width": 7, "height": 5}, {"x": 28, "y": 18, "width": 9, "height": 6}],
	"corridors": [{"start_x": 6, "start_y": 6, "end_x": 32, "end_y": 20}],
}

const LAYOUT_SCHEMA := {
	"type": "object",
	"properties": {
		"map_width": {"type": "integer"},
		"map_height": {"type": "integer"},
		"rooms": {
			"type": "array",
			"items": {
				"type": "object",
				"properties": {
					"x": {"type": "integer"},
					"y": {"type": "integer"},
					"width": {"type": "integer"},
					"height": {"type": "integer"},
				},
				"required": ["x", "y", "width", "height"],
				"additionalProperties": false,
			},
		},
		"corridors": {
			"type": "array",
			"items": {
				"type": "object",
				"properties": {
					"start_x": {"type": "integer"},
					"start_y": {"type": "integer"},
					"end_x": {"type": "integer"},
					"end_y": {"type": "integer"},
				},
				"required": ["start_x", "start_y", "end_x", "end_y"],
				"additionalProperties": false,
			},
		},
	},
	"required": ["map_width", "map_height", "rooms", "corridors"],
	"additionalProperties": false,
}

var host := DEFAULT_HOST
var timeout_seconds := DEFAULT_TIMEOUT_SECONDS

var _http: HTTPRequest
var _model := ""
var _include_entities := true
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()


func is_busy() -> bool:
	return _http != null


func generate(prompt: String, model: String, include_entities := true) -> void:
	if is_busy():
		_finish.call_deferred(_fail("Ya hay una generación en curso."))
		return
	if not is_inside_tree():
		_finish.call_deferred(_fail("El cliente de Ollama no está activo (fuera del árbol de escena)."))
		return
	prompt = prompt.strip_edges()
	model = model.strip_edges()
	if prompt.is_empty():
		_finish.call_deferred(_fail("El prompt está vacío."))
		return
	if model.is_empty():
		_finish.call_deferred(_fail("No hay ningún modelo seleccionado."))
		return

	_model = model
	_include_entities = include_entities
	_http = HTTPRequest.new()
	_http.timeout = timeout_seconds
	_http.body_size_limit = BODY_SIZE_LIMIT
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)

	var body := JSON.stringify(build_request_body(prompt, model, include_entities, _rng))
	var err := _http.request(_endpoint(), ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		_release_http()
		_finish.call_deferred(_fail("No se pudo enviar la petición a Ollama: %s." % error_string(err)))


## Aborta la petición en curso. Emite `completed` con error para que nadie quede esperando.
func cancel() -> void:
	if _http == null:
		return
	_http.cancel_request()
	_release_http()
	_finish.call_deferred(_fail("Generación cancelada."))


## Comprueba si Ollama responde en target_host (o en `host`) y qué modelos tiene instalados.
## Usa su propio HTTPRequest: puede llamarse aunque haya una generación en curso.
## El resultado llega por `status_checked`, siempre de forma diferida.
func check_status(target_host := "") -> void:
	var used_host := host if target_host.is_empty() else target_host
	if not is_inside_tree():
		_emit_status.call_deferred({"ok": false, "host": used_host, "error": "El cliente de Ollama no está activo."})
		return
	var http := HTTPRequest.new()
	http.timeout = STATUS_TIMEOUT_SECONDS
	add_child(http)
	var on_done := func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
		http.queue_free()
		status_checked.emit(parse_tags_response(result, code, body, used_host))
	http.request_completed.connect(on_done)
	var err := http.request("http://%s/api/tags" % used_host)
	if err != OK:
		http.queue_free()
		_emit_status.call_deferred({"ok": false, "host": used_host, "error": "No se pudo consultar Ollama: %s." % error_string(err)})


## Interpreta la respuesta de GET /api/tags. Pública y estática para poder probarla sin red.
static func parse_tags_response(result: int, code: int, body: PackedByteArray, used_host: String) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "host": used_host, "error": "Ollama no responde en %s. Abre la app de Ollama o ejecuta `ollama serve`." % used_host}
	if code != 200:
		return {"ok": false, "host": used_host, "error": "Ollama respondió HTTP %d en %s." % [code, used_host]}
	var data: Variant = _parse_json(body.get_string_from_utf8())
	if not (data is Dictionary) or not (data.get("models") is Array):
		return {"ok": false, "host": used_host, "error": "La respuesta de %s no parece de Ollama." % used_host}
	var names := PackedStringArray()
	for model in data.models:
		if model is Dictionary and model.get("name") is String:
			names.append(model.name)
	return {"ok": true, "host": used_host, "models": names}


## Cuerpo completo de /api/generate. Público y estático para poder probarlo sin red.
static func build_request_body(prompt: String, model: String, include_entities: bool, rng: RandomNumberGenerator) -> Dictionary:
	var requested := parse_requested_size(prompt)
	var small := is_small_map(requested)
	var options := {"temperature": SMALL_MAP_TEMPERATURE if small else TEMPERATURE}
	if small:
		options.seed = rng.randi_range(1, 2147483646)
	return {
		"model": model,
		"system": build_system_prompt(include_entities, requested, rng),
		"prompt": prompt,
		"format": build_schema(include_entities),
		"stream": false,
		"think": false,  # Qwen3: sin razonamiento oculto, ~10x más rápido
		"keep_alive": KEEP_ALIVE,
		"options": options,
	}


static func build_schema(include_entities: bool) -> Dictionary:
	var schema: Dictionary = LAYOUT_SCHEMA.duplicate(true)
	return schema


## Prompt de sistema según el tamaño pedido:
## - Mapa pequeño (área < SMALL_MAP_AREA): sin ejemplo one-shot (el modelo lo copiaba) y con
##   una regla de ancla aleatoria calculada para que la sala 0 quepa con el margen obligatorio.
## - Mapa grande o tamaño no indicado: reglas + ejemplo.
static func build_system_prompt(include_entities: bool, requested_size: Vector2i, rng: RandomNumberGenerator) -> String:
	var sections: PackedStringArray = [PROMPT_RULES.replace("{max_size}", str(MAX_REQUESTED_SIZE))]

	if is_small_map(requested_size):
		var anchor := random_anchor(requested_size, rng)
		sections.append(PROMPT_ANCHOR_RULE % [anchor.x, anchor.y])
	else:
		var request := EXAMPLE_REQUEST
		var example: Dictionary = EXAMPLE_LAYOUT.duplicate(true)
		sections.append("Example\nRequest: %s\nOutput: %s" % [request, JSON.stringify(example)])
	return "\n\n".join(sections)


## Busca "20x20", "20 x 12", "20×20", "20*20", "40 por 30" o "40 by 30". Vector2i.ZERO si no hay.
## Con varias medidas ("salas de 5x5 en un mapa de 40x40") se queda con la mayor: la del mapa.
static func parse_requested_size(prompt: String) -> Vector2i:
	var regex := RegEx.create_from_string("(?i)(\\d{1,4})\\s*(?:x|×|\\*|por|by)\\s*(\\d{1,4})")
	var best := Vector2i.ZERO
	for found in regex.search_all(prompt):
		var size := Vector2i(
			clampi(found.get_string(1).to_int(), 0, MAX_REQUESTED_SIZE),
			clampi(found.get_string(2).to_int(), 0, MAX_REQUESTED_SIZE))
		if size.x * size.y > best.x * best.y:
			best = size
	return best


static func is_small_map(requested_size: Vector2i) -> bool:
	return requested_size.x > 0 and requested_size.y > 0 and requested_size.x * requested_size.y < SMALL_MAP_AREA


## Esquina superior izquierda para la sala 0 tal que una sala mínima (3x3) cabe con margen 1:
## x >= 1 y x + 3 <= w - 1  =>  x en [1, w - 4] (ídem en y). Mapas diminutos fuerzan (1, 1).
static func random_anchor(map_size: Vector2i, rng: RandomNumberGenerator) -> Vector2i:
	var max_x := maxi(1, map_size.x - 1 - MIN_ROOM_SIZE)
	var max_y := maxi(1, map_size.y - 1 - MIN_ROOM_SIZE)
	return Vector2i(rng.randi_range(1, max_x), rng.randi_range(1, max_y))


func _exit_tree() -> void:
	cancel()


func _endpoint() -> String:
	return "http://%s/api/generate" % host


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# Se libera antes de emitir para que un listener pueda lanzar otra generación al instante.
	_release_http()
	_finish(_parse_response(result, code, body))


func _emit_status(result: Dictionary) -> void:
	status_checked.emit(result)


func _finish(outcome: Dictionary) -> void:
	completed.emit(outcome)
	if outcome.has("error"):
		error_occurred.emit(outcome.error)
	else:
		generation_success.emit(outcome.data)


func _release_http() -> void:
	if _http == null:
		return
	if _http.request_completed.is_connected(_on_request_completed):
		_http.request_completed.disconnect(_on_request_completed)
	_http.queue_free()  # queue_free: puede llamarse desde dentro de su propia señal
	_http = null


func _parse_response(result: int, code: int, body: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		return _fail(_describe_network_error(result))

	var text := body.get_string_from_utf8()
	if code != 200:
		return _fail(_describe_http_error(code, text))

	var envelope: Variant = _parse_json(text)
	if not (envelope is Dictionary):
		return _fail("Ollama devolvió una respuesta que no es JSON.")
	if envelope.has("error"):
		return _fail("Ollama: %s" % str(envelope.error))

	var content: Variant = envelope.get("response")
	if not (content is String) or content.strip_edges().is_empty():
		return _fail("El modelo devolvió una respuesta vacía. Prueba de nuevo.")
	if envelope.get("done_reason", "") == "length":
		return _fail("La respuesta del modelo se cortó por longitud. Pide un mapa con menos habitaciones.")

	var layout: Variant = _parse_json(_extract_object(content))
	if layout == null:
		return _fail("El modelo devolvió JSON malformado. Prueba de nuevo o usa un modelo mayor.")
	return validate_layout(layout, _include_entities)


func _describe_network_error(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_CANT_RESOLVE:
			return "No se puede conectar con Ollama en %s. ¿Está abierto? Inicia la app de Ollama o ejecuta `ollama serve`." % host
		HTTPRequest.RESULT_TIMEOUT:
			return "Ollama no respondió en %d s. Prueba un modelo más pequeño (%s puede ser demasiado para este equipo)." % [int(timeout_seconds), _model]
		HTTPRequest.RESULT_NO_RESPONSE:
			return "Ollama cerró la conexión sin responder. Revisa la consola de Ollama."
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "La respuesta de Ollama supera %d KiB; se descarta." % (BODY_SIZE_LIMIT / 1024)
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "Error TLS al conectar con Ollama; la URL debe ser http://, no https://."
		_:
			return "Error de red al contactar con Ollama (código %d)." % result


func _describe_http_error(code: int, text: String) -> String:
	var detail := text.strip_edges().left(200)
	var parsed: Variant = _parse_json(text)
	if parsed is Dictionary and parsed.has("error"):
		detail = str(parsed.error)
	if code == 404:
		return "El modelo '%s' no está instalado. Ejecuta: ollama pull %s" % [_model, _model]
	if code >= 500:
		return "Ollama falló (HTTP %d): %s. Si es falta de memoria, usa un modelo más pequeño." % [code, detail]
	return "Ollama rechazó la petición (HTTP %d): %s" % [code, detail]


## Comprueba tipos y rangos y devuelve {"data": copia limpia con enteros} o {"error"}.
## La geometría (recortar al mapa, entidades fuera de salas) es responsabilidad de map_generator.
## Pública y estática para validar layouts guardados (p. ej. JSON pregenerados para runtime).
static func validate_layout(layout: Variant, include_entities: bool) -> Dictionary:
	if not (layout is Dictionary):
		return _fail("El JSON del modelo no es un objeto.")

	var map_size := _read_ints(layout, MAP_KEYS)
	if map_size.is_empty() or map_size.map_width <= 0 or map_size.map_height <= 0:
		return _fail("El modelo no indicó un tamaño de mapa válido.")

	var rooms := _read_list(layout, "rooms", ROOM_KEYS, MAX_ROOMS)
	if rooms.has("error"):
		return rooms
	if rooms.items.is_empty():
		return _fail("El modelo no generó ninguna habitación.")
	for i in rooms.items.size():
		var room: Dictionary = rooms.items[i]
		if room.width <= 0 or room.height <= 0:
			return _fail("La habitación %d tiene tamaño %dx%d." % [i, room.width, room.height])

	var corridors := _read_list(layout, "corridors", CORRIDOR_KEYS, MAX_CORRIDORS)
	if corridors.has("error"):
		return corridors

	var data := {
		"map_width": map_size.map_width,
		"map_height": map_size.map_height,
		"rooms": rooms.items,
		"corridors": corridors.items,
	}


	return {"data": data}


## Lee layout[key] como lista de objetos con `keys` enteras. Devuelve {"items": Array} o {"error"}.
static func _read_list(layout: Dictionary, key: String, keys: Array, max_items: int) -> Dictionary:
	var list: Variant = layout.get(key)
	if not (list is Array):
		return _fail("El campo '%s' falta o no es una lista." % key)
	if list.size() > max_items:
		return _fail("El modelo generó %d elementos en '%s' (máximo %d)." % [list.size(), key, max_items])
	var items: Array = []
	for i in list.size():
		var item := _read_ints(list[i], keys)
		if item.is_empty():
			return _fail("El elemento %d de '%s' tiene campos ausentes o no numéricos." % [i, key])
		items.append(item)
	return {"items": items}


## Devuelve {clave: int} o {} si falta alguna clave o no es un número razonable.
static func _read_ints(item: Variant, keys: Array) -> Dictionary:
	if not (item is Dictionary):
		return {}
	var out := {}
	for key in keys:
		var value: Variant = item.get(key)
		if not (value is int or value is float):
			return {}
		var number := float(value)
		if not is_finite(number) or absf(number) > MAX_ABS_VALUE:
			return {}
		out[key] = roundi(number)
	return out


## Si el modelo envolvió el JSON en texto o en ```json```, se queda con el objeto exterior.
static func _extract_object(text: String) -> String:
	var start := text.find("{")
	var end := text.rfind("}")
	return text.substr(start, end - start + 1) if start != -1 and end > start else text


static func _parse_json(text: String) -> Variant:
	var json := JSON.new()  # JSON.new().parse no ensucia la consola con errores, a diferencia de parse_string
	if json.parse(text) != OK:
		return null
	return json.data


static func _fail(message: String) -> Dictionary:
	return {"error": message}
