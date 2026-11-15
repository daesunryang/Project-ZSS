class_name CharacterCreationScreen
extends Control
## The character creation screen (docs/00 ADR-015, docs/09 §14.24, docs/11
## §2.8): a name field, one row per appearance slot (previous / next), a
## random button, a confirm button and a line for the reason of a refusal.
##
## The rows are built from the AppearanceCatalog the server uses, so a slot
## or an option added to the data shows up here without code changes; the
## texts of slots and options come from the data too. The screen decides
## nothing: confirming checks the name with the server's own rules (so an
## obviously bad name is explained at once) and emits `create_requested`;
## the owner (ClientView) sends the request and reports the server's answer
## with show_server_reason() or close().
##
## Client only. Never loaded by a server.

## The player confirmed: the cleaned name and a copy of the selection
## {slot_id: option_id} for every slot.
signal create_requested(character_name: String, appearance: Dictionary)

const SCENE_PATH: String = "res://scenes/ui/character_creation_screen.tscn"
## Child names of a slot row (tests and tools find widgets by these).
const ROW_PREFIX: String = "Slot_"
const NODE_SLOT_NAME: String = "SlotName"
const NODE_PREVIOUS: String = "Previous"
const NODE_SWATCH: String = "Swatch"
const NODE_VALUE: String = "Value"
const NODE_NEXT: String = "Next"
const PREVIOUS_TEXT: String = "◀"
const NEXT_TEXT: String = "▶"
const SLOT_NAME_MIN_WIDTH: float = 110.0
const VALUE_MIN_WIDTH: float = 170.0
const SWATCH_SIZE: Vector2 = Vector2(28.0, 28.0)
## setup() argument: seed the random button from the clock.
const RANDOM_SEED: int = -1

@onready var _hint_label: Label = %HintLabel
@onready var _name_edit: LineEdit = %NameEdit
@onready var _name_rule_label: Label = %NameRuleLabel
@onready var _slot_rows: VBoxContainer = %SlotRows
@onready var _error_label: Label = %ErrorLabel
@onready var _random_button: Button = %RandomButton
@onready var _confirm_button: Button = %ConfirmButton

var _model: CharacterCreationModel = null
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
## Waiting for the server's answer to a request.
var _busy: bool = false


## True when the screen has to be open: the server says the local player
## may create a character and no automatic creation (`--character-name=`)
## does it instead.
static func should_open(can_create: bool, auto_create: bool) -> bool:
	return can_create and not auto_create


func _ready() -> void:
	visible = false
	_random_button.pressed.connect(_on_random_pressed)
	_confirm_button.pressed.connect(_on_confirm_pressed)
	_name_edit.text_submitted.connect(_on_name_submitted)


## Builds the rows for `rules.catalog` (call once, after the node is in the
## tree). `rng_seed` fixes the random button for tests.
func setup(rules: CharacterRules, rng_seed: int = RANDOM_SEED) -> void:
	_model = CharacterCreationModel.new(rules)
	if rng_seed == RANDOM_SEED:
		_rng.randomize()
	else:
		_rng.seed = rng_seed
	_name_edit.max_length = rules.settings.name_max_length
	_name_rule_label.text = ClientPresentationFormatter.format_name_rule(rules.settings)
	for child: Node in _slot_rows.get_children():
		_slot_rows.remove_child(child)
		child.queue_free()
	for slot: AppearanceSlot in rules.catalog.slots():
		_slot_rows.add_child(_build_row(slot))
	_refresh_rows()


## Shows the screen. The name and look of the last time are kept (a player
## whose character died often wants a variation of it).
func open(first_character: bool) -> void:
	_hint_label.text = ClientPresentationFormatter.creation_hint(first_character)
	_error_label.text = ""
	_set_busy(false)
	visible = true
	if is_inside_tree():
		_name_edit.grab_focus()


func close() -> void:
	_set_busy(false)
	visible = false


func is_open() -> bool:
	return visible


## True between a confirmed request and the server's answer.
func is_busy() -> bool:
	return _busy


## The server refused the request (`reason` is its code), or "" to clear the
## message. The player can try again.
func show_server_reason(reason: String) -> void:
	_set_busy(false)
	_error_label.text = ClientPresentationFormatter.format_creation_reason(reason, _model.rules.settings) if _model != null else reason


## Slot ids of the rows, top to bottom.
func slot_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for row: Node in _slot_rows.get_children():
		if not row.is_queued_for_deletion():
			ids.append(str(row.name).trim_prefix(ROW_PREFIX))
	return ids


## The row of a slot (children: SlotName, Previous, Swatch, Value, Next),
## or null.
func slot_row(slot_id: String) -> Control:
	return _slot_rows.get_node_or_null(ROW_PREFIX + slot_id) as Control


## A copy of the current selection {slot_id: option_id}.
func selection() -> Dictionary:
	return _model.selection() if _model != null else {}


func _build_row(slot: AppearanceSlot) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = ROW_PREFIX + slot.slot_id
	var slot_name: Label = Label.new()
	slot_name.name = NODE_SLOT_NAME
	slot_name.text = slot.display_name
	slot_name.custom_minimum_size.x = SLOT_NAME_MIN_WIDTH
	row.add_child(slot_name)
	var previous: Button = Button.new()
	previous.name = NODE_PREVIOUS
	previous.text = PREVIOUS_TEXT
	previous.pressed.connect(_on_cycle_pressed.bind(slot.slot_id, -1))
	row.add_child(previous)
	var swatch: ColorRect = ColorRect.new()
	swatch.name = NODE_SWATCH
	swatch.custom_minimum_size = SWATCH_SIZE
	swatch.visible = slot.kind == AppearanceSlot.KIND_COLOR
	row.add_child(swatch)
	var value: Label = Label.new()
	value.name = NODE_VALUE
	value.custom_minimum_size.x = VALUE_MIN_WIDTH
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(value)
	var next: Button = Button.new()
	next.name = NODE_NEXT
	next.text = NEXT_TEXT
	next.pressed.connect(_on_cycle_pressed.bind(slot.slot_id, 1))
	row.add_child(next)
	return row


## Makes every row show the model's choice.
func _refresh_rows() -> void:
	for slot_id: String in slot_ids():
		var row: Control = slot_row(slot_id)
		var option: AppearanceOption = _model.option(slot_id)
		if row == null or option == null:
			continue
		(row.get_node(NODE_VALUE) as Label).text = option.display_name
		(row.get_node(NODE_SWATCH) as ColorRect).color = option.color


func _set_busy(busy: bool) -> void:
	_busy = busy
	_confirm_button.disabled = busy


func _on_cycle_pressed(slot_id: String, step: int) -> void:
	if _model == null:
		return
	_model.cycle(slot_id, step)
	_refresh_rows()


func _on_random_pressed() -> void:
	if _model == null:
		return
	_model.randomize_selection(_rng)
	_refresh_rows()


func _on_name_submitted(_text: String) -> void:
	_on_confirm_pressed()


func _on_confirm_pressed() -> void:
	if _model == null or _busy:
		return
	var checked: ActionResult = _model.check(_name_edit.text)
	if not checked.ok:
		_error_label.text = ClientPresentationFormatter.format_creation_reason(checked.reason, _model.rules.settings)
		return
	_error_label.text = ""
	_set_busy(true)
	create_requested.emit(str(checked.event[CharacterProfile.KEY_NAME]), (checked.event[CharacterProfile.KEY_APPEARANCE] as Dictionary).duplicate())
