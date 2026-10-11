@tool
extends RefCounted
## Generador clásico de GenMap: crea el layout de una mazmorra a partir de parámetros
## (tamaño, número de salas, cofres...) sin necesitar Ollama ni ningún programa externo.
##
## Produce exactamente el mismo formato de layout que el modo descripción, así que pasa por el
## mismo pipeline: recorte, conectividad, paredes, entidades y deshacer. Es puro (no toca nodos),
## determinista con la misma semilla y se puede llamar desde cualquier hilo.

const MapGenerator := preload("res://addons/genmap/map_generator.gd")
const MIN_SIZE := 12
const MIN_ROOM := 4
const MAX_ROOM := 12
const ROOM_GAP := 2  # tiles libres entre salas: deja sitio a paredes y pasillos
const ATTEMPTS_PER_ROOM := 40

## Parámetros por defecto. Cualquier clave puede sobrescribirse.
const DEFAULT_PARAMS := {
	"width": 40,
	"height": 30,
	"rooms": 6,
	"chests": 3,
	"treasure_rooms": 1,
	"boss": true,
	"seed": 0,  # 0 = aleatoria en cada generación
}


## Devuelve un layout {map_width, map_height, rooms, corridors, spawn_point, chests}.
## Si el mapa es pequeño para tantas salas, coloca las que quepan.
static func generate(params: Dictionary = {}) -> Dictionary:
	var p := DEFAULT_PARAMS.merged(params, true)
	var rng := RandomNumberGenerator.new()
	if int(p.seed) != 0:
		rng.seed = int(p.seed)
	else:
		rng.randomize()

	var w := clampi(int(p.width), MIN_SIZE, MapGenerator.MAX_MAP_SIZE)
	var h := clampi(int(p.height), MIN_SIZE, MapGenerator.MAX_MAP_SIZE)
	var rooms := _place_rooms(w, h, clampi(int(p.rooms), 1, 64), rng)

	# Pasillos: cada sala se une a la más cercana de las ya colocadas (árbol sin ciclos).
	var corridors: Array = []
	for i in range(1, rooms.size()):
		var from := rooms[i].get_center()
		var nearest := 0
		for j in i:
			if _manhattan(from, rooms[j].get_center()) < _manhattan(from, rooms[nearest].get_center()):
				nearest = j
		var to := rooms[nearest].get_center()
		corridors.append({"start_x": from.x, "start_y": from.y, "end_x": to.x, "end_y": to.y})

	# Tipos: la primera sala es la entrada; el jefe se marca en otra y map_generator lo lleva
	# siempre a la sala más lejana; las de tesoro se eligen al azar entre las restantes.
	var types: Array[String] = []
	types.resize(rooms.size())
	types.fill("normal")
	types[0] = "start"
	var free: Array[int] = []
	for i in range(1, rooms.size()):
		free.append(i)
	if p.boss == true and not free.is_empty():
		types[free.pop_back()] = "boss"
	_shuffle(free, rng)
	for i in mini(int(p.treasure_rooms), free.size()):
		types[free[i]] = "treasure"

	var room_dicts: Array = []
	for i in rooms.size():
		var r := rooms[i]
		room_dicts.append({"x": r.position.x, "y": r.position.y, "width": r.size.x, "height": r.size.y, "type": types[i]})

	var spawn := rooms[0].get_center()
	return {
		"map_width": w,
		"map_height": h,
		"rooms": room_dicts,
		"corridors": corridors,
		"spawn_point": {"x": spawn.x, "y": spawn.y},
		"chests": _place_chests(rooms, types, maxi(int(p.chests), 0), spawn, rng),
	}


static func _place_rooms(w: int, h: int, count: int, rng: RandomNumberGenerator) -> Array[Rect2i]:
	var rooms: Array[Rect2i] = []
	var max_w := clampi(w / 3, MIN_ROOM, MAX_ROOM)
	var max_h := clampi(h / 3, MIN_ROOM, MAX_ROOM)
	for attempt in count * ATTEMPTS_PER_ROOM:
		if rooms.size() == count:
			break
		var size := Vector2i(rng.randi_range(MIN_ROOM, max_w), rng.randi_range(MIN_ROOM, max_h))
		# Margen de 1 tile en el borde: ahí van las paredes.
		var max_x := w - 1 - size.x
		var max_y := h - 1 - size.y
		if max_x < 1 or max_y < 1:
			continue
		var rect := Rect2i(Vector2i(rng.randi_range(1, max_x), rng.randi_range(1, max_y)), size)
		var free := true
		for other in rooms:
			if other.grow(ROOM_GAP).intersects(rect):
				free = false
				break
		if free:
			rooms.append(rect)
	if rooms.is_empty():  # mapa diminuto: una sala que ocupa casi todo
		rooms.append(Rect2i(1, 1, w - 2, h - 2))
	return rooms


## Cofres: primero en las salas de tesoro, después en el resto (nunca en la entrada si hay más
## salas). Nunca dos en la misma celda ni encima del spawn.
static func _place_chests(rooms: Array[Rect2i], types: Array[String], count: int, spawn: Vector2i,
		rng: RandomNumberGenerator) -> Array:
	var preferred: Array[int] = []
	var others: Array[int] = []
	for i in rooms.size():
		if types[i] == "treasure":
			preferred.append(i)
		elif types[i] != "start" or rooms.size() == 1:
			others.append(i)
	var order := preferred if not preferred.is_empty() else others
	if order.is_empty():
		return []
	var used := {spawn: true}
	var chests: Array = []
	for k in count:
		var room := rooms[order[k % order.size()]]
		for attempt in 20:
			var cell := Vector2i(rng.randi_range(room.position.x, room.end.x - 1),
					rng.randi_range(room.position.y, room.end.y - 1))
			if not used.has(cell):
				used[cell] = true
				chests.append({"x": cell.x, "y": cell.y})
				break
	return chests


static func _shuffle(values: Array[int], rng: RandomNumberGenerator) -> void:
	for i in range(values.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := values[i]
		values[i] = values[j]
		values[j] = tmp


static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)
