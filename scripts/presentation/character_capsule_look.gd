class_name CharacterCapsuleLook
extends RefCounted
## Appearance selection -> the placeholder capsule (docs/09 §14.24, docs/11
## §2.8). Until character models exist a character is a capsule, so only
## three things can be shown: the slot with visual role "capsule_color"
## gives the colour, "capsule_height" scales the height and
## "capsule_radius" scales the radius. Every other slot (skin tone, hair
## style, hair colour, bottom colour) is stored and replicated but not
## visible yet. Pure: no nodes.

const KEY_RADIUS: String = "radius"
const KEY_HEIGHT: String = "height"
const KEY_COLOR: String = "color"
## A capsule is at least as high as it is wide.
const MIN_HEIGHT_PER_RADIUS: float = 2.0


## {"radius": float, "height": float, "color": Color} for `selection`
## ({slot_id: option_id}). Slots or options this client does not know are
## ignored: the base size and `fallback_color` are used for them.
static func build(catalog: AppearanceCatalog, selection: Dictionary, base_radius: float, base_height: float, fallback_color: Color) -> Dictionary:
	var radius: float = base_radius
	var height: float = base_height
	var color: Color = fallback_color
	var color_option: AppearanceOption = _chosen(catalog, selection, AppearanceSlot.ROLE_CAPSULE_COLOR)
	if color_option != null:
		color = color_option.color
	var height_option: AppearanceOption = _chosen(catalog, selection, AppearanceSlot.ROLE_CAPSULE_HEIGHT)
	if height_option != null:
		height = base_height * height_option.scale
	var radius_option: AppearanceOption = _chosen(catalog, selection, AppearanceSlot.ROLE_CAPSULE_RADIUS)
	if radius_option != null:
		radius = base_radius * radius_option.scale
	height = maxf(height, radius * MIN_HEIGHT_PER_RADIUS)
	return {KEY_RADIUS: radius, KEY_HEIGHT: height, KEY_COLOR: color}


## The option `selection` holds for the slot with `role`, or null.
static func _chosen(catalog: AppearanceCatalog, selection: Dictionary, role: String) -> AppearanceOption:
	var slot: AppearanceSlot = catalog.slot_with_role(role)
	if slot == null:
		return null
	var option_id: Variant = selection.get(slot.slot_id, null)
	if typeof(option_id) != TYPE_STRING:
		return null
	return slot.get_option(option_id as String)
