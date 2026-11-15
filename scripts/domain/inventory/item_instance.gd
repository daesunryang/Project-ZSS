class_name ItemInstance
extends RefCounted
## Runtime item state matching schemas/item_instance.schema.json.
## Serialized with `to_dict()` / `from_dict()`; no Node or Resource refs.

const SCHEMA_VERSION: int = 1
const LOCATION_WORLD: String = "world"
const LOCATION_INVENTORY: String = "inventory"
const LOCATION_TYPES: PackedStringArray = ["world", "inventory", "container", "equipment", "work_order"]
const DEFINITION_ID_PATTERN: String = "^[a-z][a-z0-9_]*$"
const MAX_UNIT_VALUE: float = 1.0

var item_instance_id: String = ""
var definition_id: String = ""
var quantity: int = 1
var condition: float = MAX_UNIT_VALUE
var quality: float = MAX_UNIT_VALUE
var location_type: String = LOCATION_WORLD
## Cell id for world items, inventory id for carried items.
var location_id: String = ""
## Slot inside the inventory/container, "" when not applicable.
var slot_id: String = ""


func to_dict() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"item_instance_id": item_instance_id,
		"definition_id": definition_id,
		"quantity": quantity,
		"condition": condition,
		"quality": quality,
		"location_type": location_type,
		"location_id": location_id,
		"slot_id": null if slot_id.is_empty() else slot_id,
	}


## Builds an instance from saved/network data. Returns null (and logs) when
## the data is malformed.
static func from_dict(data: Dictionary) -> ItemInstance:
	var errors: PackedStringArray = validate_dict(data)
	if not errors.is_empty():
		GameLogger.error("inventory", "invalid item data", {
			"item_instance_id": str(data.get("item_instance_id", "")), "errors": "; ".join(errors), "operation": "item_from_dict",
		})
		return null
	var item: ItemInstance = ItemInstance.new()
	item.item_instance_id = str(data["item_instance_id"])
	item.definition_id = str(data["definition_id"])
	item.quantity = int(data["quantity"])
	item.condition = float(data.get("condition", MAX_UNIT_VALUE))
	item.quality = float(data.get("quality", MAX_UNIT_VALUE))
	item.location_type = str(data["location_type"])
	item.location_id = str(data["location_id"])
	var slot: Variant = data.get("slot_id", null)
	item.slot_id = "" if slot == null else str(slot)
	return item


## Validates a dictionary against the schema rules this code relies on.
static func validate_dict(data: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	for key: String in ["schema_version", "item_instance_id", "definition_id", "quantity", "location_type", "location_id"]:
		if not data.has(key):
			errors.append("missing " + key)
	if not errors.is_empty():
		return errors
	if not is_integer_value(data["schema_version"]) or int(data["schema_version"]) != SCHEMA_VERSION:
		errors.append("unsupported schema_version")
	if typeof(data["item_instance_id"]) != TYPE_STRING or str(data["item_instance_id"]).is_empty():
		errors.append("item_instance_id must be a non-empty string")
	if typeof(data["definition_id"]) != TYPE_STRING or not is_valid_definition_id(str(data["definition_id"])):
		errors.append("definition_id must be snake_case")
	if not is_integer_value(data["quantity"]) or int(data["quantity"]) < 1:
		errors.append("quantity must be an integer >= 1")
	if typeof(data["location_type"]) != TYPE_STRING or not LOCATION_TYPES.has(str(data["location_type"])):
		errors.append("unknown location_type")
	if typeof(data["location_id"]) != TYPE_STRING:
		errors.append("location_id must be a string")
	for key: String in ["condition", "quality"]:
		if data.has(key):
			var value: Variant = data[key]
			if not (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) or float(value) < 0.0 or float(value) > MAX_UNIT_VALUE:
				errors.append(key + " must be within [0, 1]")
	var slot: Variant = data.get("slot_id", null)
	if slot != null and typeof(slot) != TYPE_STRING:
		errors.append("slot_id must be a string or null")
	return errors


static func is_valid_definition_id(definition_id: String) -> bool:
	return RegEx.create_from_string(DEFINITION_ID_PATTERN).search(definition_id) != null


## JSON numbers parse as float; accept whole floats as integers.
static func is_integer_value(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	return typeof(value) == TYPE_FLOAT and is_equal_approx(float(value), roundf(float(value)))
