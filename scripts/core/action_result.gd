class_name ActionResult
extends RefCounted
## Outcome of a server-validated command (docs/14 §5: commands can fail,
## events are approved facts). `reason` is a stable machine-readable code
## sent to clients; `event` holds the resulting domain event on success.

var ok: bool = false
var reason: String = ""
var event: Dictionary = {}


static func success(event_data: Dictionary = {}) -> ActionResult:
	var result: ActionResult = ActionResult.new()
	result.ok = true
	result.event = event_data
	return result


static func failure(reason_code: String) -> ActionResult:
	var result: ActionResult = ActionResult.new()
	result.ok = false
	result.reason = reason_code
	return result
