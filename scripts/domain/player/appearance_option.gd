class_name AppearanceOption
extends Resource
## One choice of an appearance slot (docs/00 ADR-015, docs/09 §14.24), e.g.
## the hair style "ponytail" or the top colour "navy". Static definition
## data: lives as a sub-resource of its AppearanceSlot file.
##
## A character stores only `option_id`; everything else is looked up here,
## so display text and colours can change without touching saved characters.

## Stable snake_case id. Saved and sent over the network: never rename it.
@export var option_id: String = ""
## Text shown in the character creation screen.
@export var display_name: String = ""
## Colour of this choice (slots of kind "color"; ignored by other kinds).
@export var color: Color = Color.WHITE
## Size factor of this choice (slots of kind "scale", 1.0 = the usual size;
## ignored by other kinds).
@export var scale: float = 1.0
