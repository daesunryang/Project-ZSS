class_name FloatBits
extends RefCounted
## A 64-bit float as text that comes back with every bit (P4-Z, docs/15
## P4-281). Godot 4.7.2 reads a JSON number with more than about 16
## significant digits one unit in the last place off (JSON.parse_string,
## String.to_float and str_to_var alike): about one in seven values of a
## clock that adds 1.2 s per tick. A save that must go on exactly as the
## run that was never stopped writes such a value twice: the number (for
## people, old readers and validation) and, beside it, these bits.
##
## The text is the base64 of the 8 bytes of the IEEE-754 double (the same
## form NpcNeeds uses for its own values).

const BYTE_COUNT: int = 8
const TEXT_LENGTH: int = 12
## The number beside the bits is the same value read back by the JSON
## reader: it may differ in its last digits, not more.
const AGREEMENT: float = 0.000000001


static func encode(value: float) -> String:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(BYTE_COUNT)
	bytes.encode_double(0, value)
	return Marshalls.raw_to_base64(bytes)


## The value `bits` holds when it is such a text for a finite number that
## agrees with `number` (what the same document says as a JSON number);
## otherwise `number` itself. A document without bits, with broken bits,
## or whose number was edited by hand is read as before.
static func restored(number: float, bits: Variant) -> float:
	if typeof(bits) != TYPE_STRING or (bits as String).length() != TEXT_LENGTH:
		return number
	var bytes: PackedByteArray = Marshalls.base64_to_raw(bits as String)
	if bytes.size() != BYTE_COUNT:
		return number
	var exact: float = bytes.decode_double(0)
	if not is_finite(exact) or absf(exact - number) > AGREEMENT * maxf(1.0, absf(number)):
		return number
	return exact
