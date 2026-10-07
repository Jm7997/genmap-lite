extends Node2D
## Demo de GenMap Lite.
##   1. En el editor, selecciona el nodo Ground y genera un mapa desde el panel GenMap.
##   2. Guarda la escena (Ctrl+S) y pulsa F5 para recorrerlo con las flechas.
## El mapa queda guardado en la escena: así se distribuye en un juego hecho con GenMap Lite.

const FLOOR_SOURCE := 0
const FLOOR_ATLAS := Vector2i(0, 0)

@onready var _ground: TileMapLayer = $Ground
@onready var _player: CharacterBody2D = $Player
@onready var _info: Label = %Info


func _ready() -> void:
	var floors := _ground.get_used_cells_by_id(FLOOR_SOURCE, FLOOR_ATLAS)
	if floors.is_empty():
		_info.text = "Todavía no hay mapa.\nEn el editor: selecciona Ground, genera un mapa en el panel GenMap, guarda y pulsa F5."
		return
	# El jugador empieza en la celda de suelo más cercana al centro del mapa.
	var center := _ground.get_used_rect().get_center()
	var start := floors[0]
	for cell in floors:
		if (cell - center).length_squared() < (start - center).length_squared():
			start = cell
	_player.global_position = _ground.to_global(_ground.map_to_local(start))
	_info.text = "Flechas: moverse · Genera otro mapa en el editor y pulsa F5 para probarlo"
