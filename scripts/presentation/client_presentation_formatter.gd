class_name ClientPresentationFormatter
extends RefCounted
## Pure conversion from mirrored state/events to placeholder colors and HUD text.


static func zombie_color(state: String, settings: ClientPresentationSettings) -> Color:
	match state:
		"investigate":
			return settings.zombie_investigate_color
		"chase":
			return settings.zombie_chase_color
		"attack":
			return settings.zombie_attack_color
		"search":
			return settings.zombie_search_color
		"dormant":
			return settings.zombie_dormant_color
		"dead":
			return settings.zombie_dead_color
	return settings.zombie_idle_color


## Empty input means no owner-only mirror is available and produces no HUD.
static func build_survival_lines(vitals: Dictionary, settings: ClientPresentationSettings) -> PackedStringArray:
	if vitals.is_empty():
		return PackedStringArray()
	var lines: PackedStringArray = []
	lines.append("체력 %.1f | 스태미나 %.1f" % [float(vitals.get("health", 0.0)), float(vitals.get("stamina", 0.0))])
	var needs: Dictionary = vitals.get("needs", {})
	lines.append("허기 %s | 갈증 %s | 피로 %s" % [
		_need_category_text(str(needs.get("hunger", ""))),
		_need_category_text(str(needs.get("thirst", ""))),
		_need_category_text(str(needs.get("fatigue", ""))),
	])
	lines.append("감염 단계: %s" % _infection_stage_text(str(vitals.get("infection_stage", ""))))
	var wounds: Array = vitals.get("wounds", [])
	var bleeding: bool = false
	for value: Variant in wounds:
		if typeof(value) == TYPE_DICTIONARY and bool((value as Dictionary).get("is_bleeding", false)):
			bleeding = true
			break
	lines.append("상처 %d | 출혈 %s" % [wounds.size(), "있음" if bleeding else "없음"])
	if not bool(vitals.get("alive", true)):
		lines.append(settings.death_message)
	return lines


static func format_attack_result(ok: bool, reason: String) -> String:
	return "공격 요청 승인" if ok else "공격 요청 거부: %s" % reason


## Server answer to a consume (eat / drink) request.
static func format_consume_result(ok: bool, reason: String) -> String:
	return "먹기/마시기 요청 승인" if ok else "먹기/마시기 요청 거부: %s" % reason


## Local notice: the consume key was pressed but the mirrored inventory holds
## nothing consumable (no request was sent).
static func nothing_to_consume_text() -> String:
	return "먹거나 마실 것이 없습니다"


## HUD inventory summary from the local inventory mirror (ItemInstance
## dictionaries): a header with the number of carried stacks, then one line
## per item kind ("name x quantity", stacks of the same definition summed) in
## first-seen order. At most `max_kinds` kinds are listed; the rest is
## counted in a last line. Names come from the static item catalog (the
## definition id when a definition or its name is missing). Malformed
## entries are skipped.
static func build_inventory_lines(inventory: Array[Dictionary], catalog: ItemCatalog, max_kinds: int) -> PackedStringArray:
	var order: PackedStringArray = []
	var quantities: Dictionary[String, int] = {}
	var stacks: int = 0
	for entry: Dictionary in inventory:
		var definition_id: Variant = entry.get("definition_id", null)
		var quantity: Variant = entry.get("quantity", null)
		if typeof(definition_id) != TYPE_STRING or not ItemInstance.is_integer_value(quantity) or int(quantity) < 1:
			continue
		stacks += 1
		var key: String = str(definition_id)
		if not quantities.has(key):
			order.append(key)
			quantities[key] = 0
		quantities[key] += int(quantity)
	if stacks == 0:
		return PackedStringArray(["소지품: 없음"])
	var lines: PackedStringArray = ["소지품 (%d)" % stacks]
	var listed: int = mini(order.size(), maxi(max_kinds, 1))
	for index: int in range(listed):
		var definition: ItemDefinition = catalog.get_definition(order[index]) if catalog != null else null
		var item_name: String = definition.display_name if definition != null and not definition.display_name.is_empty() else order[index]
		lines.append("%s x%d" % [item_name, quantities[order[index]]])
	if order.size() > listed:
		lines.append("... 외 %d종" % (order.size() - listed))
	return lines


static func format_combat_event(event: Dictionary) -> String:
	if str(event.get(ClientCombatState.KEY_EVENT_TYPE, "")) != ClientCombatState.EVENT_MELEE_ATTACK:
		return ""
	var attacker: String = str(event.get(ClientCombatState.KEY_ATTACKER_ID, ""))
	if not bool(event.get(ClientCombatState.KEY_HIT, false)):
		return "%s 근접 공격: 빗나감" % attacker
	var suffix: String = "처치" if bool(event.get(ClientCombatState.KEY_TARGET_DIED, false)) else "명중"
	var text: String = "%s 근접 공격: %s (%s)" % [attacker, suffix, str(event.get(ClientCombatState.KEY_TARGET_ID, ""))]
	if event.has(ClientCombatState.KEY_DAMAGE):
		text += " 피해 %.1f" % float(event[ClientCombatState.KEY_DAMAGE])
	return text


## Infection is appended only for the local target even if a malformed caller
## passes a private-looking field for somebody else's event.
static func format_zombie_event(event: Dictionary, local_player_id: String) -> String:
	if str(event.get("event_type", "")) != ZombieService.EVENT_ATTACKED:
		return ""
	var wound_text: String = "물림" if str(event.get("wound_type", "")) == "bite" else "할퀴기"
	var text: String = "%s → %s %s" % [str(event.get("zombie_id", "")), str(event.get("target_id", "")), wound_text]
	if event.has("damage"):
		text += " (피해 %.1f)" % float(event["damage"])
	if bool(event.get("target_died", false)):
		text += " · 사망"
	if str(event.get("target_id", "")) == local_player_id and event.has("infection"):
		var infection: String = str(event["infection"])
		if infection == SurvivalService.EVENT_PLAYER_INFECTED:
			text += " · 감염"
		elif infection == SurvivalService.EVENT_INFECTION_RESISTED:
			text += " · 감염 저항"
	return text


static func _need_category_text(category: String) -> String:
	match category:
		"good":
			return "양호"
		"caution":
			return "주의"
		"danger":
			return "위험"
	return "-"


static func _infection_stage_text(stage: String) -> String:
	match stage:
		"none":
			return "없음"
		"latent":
			return "잠복"
		"early":
			return "초기"
		"progressing":
			return "진행"
		"severe":
			return "중증"
		"terminal":
			return "말기"
		"zombified":
			return "좀비화"
	return "-"
