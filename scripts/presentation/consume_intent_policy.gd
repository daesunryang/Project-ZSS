class_name ConsumeIntentPolicy
extends RefCounted
## Pure client-side choice of what the consume key asks for (P2-T3). It only
## picks an item id from the mirrored inventory; whether that item may be
## consumed, and what it does, is decided by the server.


## Id of the first entry of the mirrored inventory whose definition is
## consumable, in mirror order (the order the server sent the items), or ""
## when there is none. Entries that are not usable ItemInstance dictionaries
## and unknown definitions are skipped.
static func first_consumable_item_id(inventory: Array[Dictionary], catalog: ItemCatalog) -> String:
	if catalog == null:
		return ""
	for entry: Dictionary in inventory:
		var item_id: Variant = entry.get("item_instance_id", null)
		var definition_id: Variant = entry.get("definition_id", null)
		if typeof(item_id) != TYPE_STRING or typeof(definition_id) != TYPE_STRING or str(item_id).is_empty():
			continue
		var definition: ItemDefinition = catalog.get_definition(str(definition_id))
		if definition != null and definition.is_consumable():
			return str(item_id)
	return ""
