extends CharacterBody2D
## Jugador del demo: movimiento top-down con las flechas. Choca con los muros por la capa
## de física del TileSet.

const SPEED := 90.0


func _physics_process(_delta: float) -> void:
	velocity = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down") * SPEED
	move_and_slide()
