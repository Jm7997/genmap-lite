@tool
extends VBoxContainer
## Dock de GenMap: recoge prompt, modelo, ajustes y TileMapLayer destino, y emite peticiones.
## No habla con Ollama ni pinta: eso lo hace el plugin a través de GenMapAPI.
##
## El último estado (modelo, ajustes, panel abierto) se guarda en la metadata del proyecto (.godot/).

signal generate_requested(prompt: String, model: String, layer: TileMapLayer, settings: Dictionary)
signal cancel_requested
signal check_ollama_requested

enum Status { INFO, SUCCESS, ERROR }

const MapGenerator := preload("res://addons/genmap/map_generator.gd")
const MODELS := [
	{"id": "qwen3:4b", "label": "Qwen3 4B · ligero (CPU / 8 GB RAM)"},
	{"id": "qwen3:8b", "label": "Qwen3 8B · recomendado (GPU 8 GB)"},
	{"id": "qwen3:14b", "label": "Qwen3 14B · calidad (GPU 12 GB+)"},
]
const DEFAULT_MODEL := "qwen3:8b"
const MAX_PROMPT_LENGTH := 500
const SETTINGS_SECTION := "genmap"
const GENERATE_TEXT := "Generar mapa"
const CANCEL_TEXT := "Cancelar"
const ADVANCED_OPEN_TEXT := "▾ Ajustes avanzados"
const ADVANCED_CLOSED_TEXT := "▸ Ajustes avanzados"
const STAGE_TEXT := {
	"ollama": "Esperando al modelo...",
	"plan": "Calculando el mapa...",
	"paint": "Pintando tiles...",
}

@onready var _prompt_edit: TextEdit = %PromptEdit
@onready var _model_option: OptionButton = %ModelOption
@onready var _check_ollama_button: Button = %CheckOllamaButton
@onready var _advanced_toggle: Button = %AdvancedToggle
@onready var _advanced_panel: VBoxContainer = %AdvancedPanel
@onready var _manual_grid: GridContainer = %ManualGrid
@onready var _floor_source_spin: SpinBox = %FloorSourceSpin
@onready var _floor_atlas_x_spin: SpinBox = %FloorAtlasXSpin
@onready var _floor_atlas_y_spin: SpinBox = %FloorAtlasYSpin
@onready var _wall_source_spin: SpinBox = %WallSourceSpin
@onready var _wall_atlas_x_spin: SpinBox = %WallAtlasXSpin
@onready var _wall_atlas_y_spin: SpinBox = %WallAtlasYSpin
@onready var _reset_button: Button = %ResetButton
@onready var _target_label: Label = %TargetLabel
@onready var _generate_button: Button = %GenerateButton
@onready var _progress_bar: ProgressBar = %ProgressBar
@onready var _status_label: Label = %StatusLabel

var _busy := false
var _installed_models := PackedStringArray()
var _ollama_checked := false
var _target: TileMapLayer


## Lo llama el plugin tras añadir el dock. No se hace en _ready para que
## abrir genmap_dock.tscn en el editor no conecte señales del editor.
func setup() -> void:
	_model_option.clear()
	for i in MODELS.size():
		_model_option.add_item(MODELS[i].label, i)
		_model_option.set_item_metadata(i, MODELS[i].id)
	_select_model(str(_load_setting("model", DEFAULT_MODEL)))

	_apply_settings(_load_saved_settings())
	var advanced_open: bool = _load_setting("advanced_open", false) == true
	_advanced_toggle.set_pressed_no_signal(advanced_open)
	_show_advanced(advanced_open)

	_model_option.item_selected.connect(_on_model_selected)
	_prompt_edit.text_changed.connect(_refresh_buttons)
	_prompt_edit.gui_input.connect(_on_prompt_gui_input)
	_generate_button.pressed.connect(_on_generate_pressed)
	_check_ollama_button.pressed.connect(_on_check_ollama_pressed)
	_advanced_toggle.toggled.connect(_on_advanced_toggled)
	_reset_button.pressed.connect(_on_reset_pressed)
	for spin in _spin_boxes():
		spin.value_changed.connect(_on_setting_changed.unbind(1))
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)

	_on_selection_changed()
	set_status("Escribe un prompt y selecciona un TileMapLayer en la escena.", Status.INFO)


func get_selected_model() -> String:
	var index := _model_option.selected
	return str(_model_option.get_item_metadata(index)) if index >= 0 else DEFAULT_MODEL


## Ajustes actuales en el formato de MapGenerator.DEFAULT_SETTINGS.
func get_settings() -> Dictionary:
	return {
		"floor_source_id": int(_floor_source_spin.value),
		"floor_atlas_coords": Vector2i(int(_floor_atlas_x_spin.value), int(_floor_atlas_y_spin.value)),
		"wall_source_id": int(_wall_source_spin.value),
		"wall_atlas_coords": Vector2i(int(_wall_atlas_x_spin.value), int(_wall_atlas_y_spin.value)),
	}


## Mientras está ocupado, todo se bloquea salvo el botón principal, que pasa a "Cancelar".
func set_busy(busy: bool, message := "") -> void:
	_busy = busy
	_prompt_edit.editable = not busy
	_model_option.disabled = busy
	_check_ollama_button.disabled = busy
	_reset_button.disabled = busy
	for spin in _spin_boxes():
		spin.editable = not busy
	_generate_button.text = CANCEL_TEXT if busy else GENERATE_TEXT
	_progress_bar.visible = busy
	if busy:
		set_progress("ollama", -1.0)
	_refresh_buttons()
	if not message.is_empty():
		set_status(message, Status.INFO)


## stage: "ollama", "plan" o "paint". progress de 0 a 1, o negativo si no se puede medir.
func set_progress(stage: String, progress: float) -> void:
	_progress_bar.indeterminate = progress < 0.0
	_progress_bar.value = clampf(progress, 0.0, 1.0) * 100.0
	_progress_bar.tooltip_text = STAGE_TEXT.get(stage, stage)
	if _busy and STAGE_TEXT.has(stage):
		set_status(STAGE_TEXT[stage], Status.INFO)


## Recibe el resultado de GenMapAPI.check_ollama(): marca los modelos no instalados y avisa.
func set_ollama_status(result: Dictionary) -> void:
	_check_ollama_button.disabled = _busy
	if _busy:
		return  # no pisar el progreso de una generación en curso
	if result.get("ok") != true:
		_ollama_checked = false
		set_status(str(result.get("error", "Ollama no responde.")), Status.ERROR)
		return
	_ollama_checked = true
	_installed_models = result.get("models", PackedStringArray())
	for i in _model_option.item_count:
		var installed := _is_installed(str(_model_option.get_item_metadata(i)))
		_model_option.set_item_text(i, MODELS[i].label + ("" if installed else "  (no instalado)"))
	_report_selected_model()


func set_status(message: String, status := Status.INFO) -> void:
	_status_label.text = message
	var editor_theme := EditorInterface.get_editor_theme()
	match status:
		Status.SUCCESS:
			_status_label.add_theme_color_override("font_color", editor_theme.get_color("success_color", "Editor"))
		Status.ERROR:
			_status_label.add_theme_color_override("font_color", editor_theme.get_color("error_color", "Editor"))
		_:
			_status_label.remove_theme_color_override("font_color")


func _on_generate_pressed() -> void:
	if _busy:
		cancel_requested.emit()
		set_status("Cancelando...", Status.INFO)
		return
	var prompt := _prompt_edit.text.strip_edges()
	if prompt.is_empty():
		set_status("El prompt está vacío.", Status.ERROR)
		return
	if prompt.length() > MAX_PROMPT_LENGTH:
		set_status("El prompt supera %d caracteres (%d)." % [MAX_PROMPT_LENGTH, prompt.length()], Status.ERROR)
		return
	var target_error := _check_target()
	if not target_error.is_empty():
		set_status(target_error, Status.ERROR)
		return
	if not generate_requested.has_connections():
		set_status("No hay ningún generador conectado al dock.", Status.ERROR)
		return
	generate_requested.emit(prompt, get_selected_model(), _target, get_settings())


# Ctrl+Enter en el prompt = Generar.
func _on_prompt_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.ctrl_pressed \
			and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER):
		_prompt_edit.accept_event()
		if not _busy:
			_on_generate_pressed()


func _on_selection_changed() -> void:
	_target = null
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is TileMapLayer:
			_target = node
			break

	if _target == null:
		_target_label.text = "Destino: ninguno (selecciona un TileMapLayer)"
	elif _target.tile_set == null:
		_target_label.text = "Destino: %s (sin TileSet)" % _target.name
	else:
		_target_label.text = "Destino: %s" % _target.name
	_refresh_buttons()


func _on_model_selected(index: int) -> void:
	_save_setting("model", _model_option.get_item_metadata(index))
	if _ollama_checked:
		_report_selected_model()


func _on_check_ollama_pressed() -> void:
	_check_ollama_button.disabled = true
	set_status("Comprobando Ollama...", Status.INFO)
	check_ollama_requested.emit()


func _report_selected_model() -> void:
	var model := get_selected_model()
	if _is_installed(model):
		set_status("Ollama funcionando. Modelo %s listo." % model, Status.SUCCESS)
	else:
		set_status("Ollama funciona, pero falta el modelo %s. Ejecuta en una terminal: ollama pull %s" % [model, model], Status.ERROR)


func _is_installed(model: String) -> bool:
	return model in _installed_models


func _on_advanced_toggled(pressed: bool) -> void:
	_show_advanced(pressed)
	_save_setting("advanced_open", pressed)


func _on_setting_changed() -> void:
	_update_mode_visibility()
	_save_setting("settings", get_settings())


func _on_reset_pressed() -> void:
	_apply_settings(MapGenerator.DEFAULT_SETTINGS)
	_save_setting("settings", get_settings())
	set_status("Ajustes restaurados a los valores por defecto.", Status.INFO)


func _check_target() -> String:
	if not is_instance_valid(_target):
		_on_selection_changed()
		return "Selecciona un nodo TileMapLayer en la escena."
	if _target.tile_set == null:
		return "El TileMapLayer '%s' no tiene TileSet asignado." % _target.name
	return ""


func _show_advanced(open: bool) -> void:
	_advanced_panel.visible = open
	_advanced_toggle.text = ADVANCED_OPEN_TEXT if open else ADVANCED_CLOSED_TEXT


func _update_mode_visibility() -> void:
	pass  # GenMap Lite solo tiene el modo manual


## Vuelca un diccionario de ajustes en los controles sin disparar señales.
## Valores corruptos o ausentes caen al valor por defecto.
func _apply_settings(settings: Dictionary) -> void:
	var defaults := MapGenerator.DEFAULT_SETTINGS
	var s := defaults.merged(settings, true)
	_floor_source_spin.set_value_no_signal(_number_or(s.floor_source_id, defaults.floor_source_id))
	_wall_source_spin.set_value_no_signal(_number_or(s.wall_source_id, defaults.wall_source_id))
	var floor_atlas: Vector2i = s.floor_atlas_coords if s.floor_atlas_coords is Vector2i else defaults.floor_atlas_coords
	var wall_atlas: Vector2i = s.wall_atlas_coords if s.wall_atlas_coords is Vector2i else defaults.wall_atlas_coords
	_floor_atlas_x_spin.set_value_no_signal(floor_atlas.x)
	_floor_atlas_y_spin.set_value_no_signal(floor_atlas.y)
	_wall_atlas_x_spin.set_value_no_signal(wall_atlas.x)
	_wall_atlas_y_spin.set_value_no_signal(wall_atlas.y)
	_update_mode_visibility()


func _load_saved_settings() -> Dictionary:
	var saved: Variant = _load_setting("settings", {})
	return saved if saved is Dictionary else {}


func _spin_boxes() -> Array[SpinBox]:
	return [
		_floor_source_spin, _floor_atlas_x_spin, _floor_atlas_y_spin,
		_wall_source_spin, _wall_atlas_x_spin, _wall_atlas_y_spin,
	]


func _refresh_buttons() -> void:
	# Ocupado: el botón principal es "Cancelar" y siempre está activo.
	_generate_button.disabled = not _busy and (
			_prompt_edit.text.strip_edges().is_empty() or not is_instance_valid(_target))


func _select_model(model_id: String) -> void:
	for i in _model_option.item_count:
		if _model_option.get_item_metadata(i) == model_id:
			_model_option.select(i)
			return
	# Modelo guardado ya no está en la lista: volver al recomendado.
	if model_id != DEFAULT_MODEL:
		_select_model(DEFAULT_MODEL)
	else:
		_model_option.select(0)


static func _number_or(value: Variant, fallback: Variant) -> float:
	return float(value) if value is int or value is float else float(fallback)


# Último estado por proyecto, guardado fuera de res:// (no ensucia el repo del usuario).
func _load_setting(key: String, default_value: Variant) -> Variant:
	return EditorInterface.get_editor_settings().get_project_metadata(SETTINGS_SECTION, key, default_value)


func _save_setting(key: String, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(SETTINGS_SECTION, key, value)
