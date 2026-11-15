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
	# Which character of the player this is (permanent death, ADR-007); only
	# shown once the server has told the owner.
	var generation: int = int(vitals.get("character_generation", 0))
	if generation > 0:
		lines.append("캐릭터 #%d" % generation)
	lines.append("체력 %.1f | 스태미나 %.1f" % [float(vitals.get("health", 0.0)), float(vitals.get("stamina", 0.0))])
	var needs: Dictionary = vitals.get("needs", {})
	lines.append("허기 %s | 갈증 %s | 피로 %s" % [
		_need_category_text(str(needs.get("hunger", ""))),
		_need_category_text(str(needs.get("thirst", ""))),
		_need_category_text(str(needs.get("fatigue", ""))),
	])
	lines.append("감염 단계: %s" % _infection_stage_text(str(vitals.get("infection_stage", ""))))
	var wounds: Array = vitals.get("wounds", [])
	lines.append("상처 %d | 출혈 %s" % [wounds.size(), "있음" if bleeding_wound_count(vitals) > 0 else "없음"])
	if not bool(vitals.get("alive", true)):
		lines.append(settings.death_message)
	return lines


## Number of the owner's wounds that bleed (malformed entries are skipped).
static func bleeding_wound_count(vitals: Dictionary) -> int:
	var count: int = 0
	var wounds: Variant = vitals.get("wounds", [])
	if typeof(wounds) != TYPE_ARRAY:
		return count
	for value: Variant in wounds as Array:
		if typeof(value) == TYPE_DICTIONARY and (value as Dictionary).get("is_bleeding", false) == true:
			count += 1
	return count


## HUD lines about what the owner can treat, one per kind of treatment
## (P2-T6, P2-T7): how many wounds bleed and the own infection stage, how
## many bandages / cures are carried (all stacks of the inventory mirror) and
## the key that uses one. Empty input (no owner mirror) produces no line.
static func build_treatment_lines(vitals: Dictionary, inventory: Array[Dictionary], catalog: ItemCatalog, settings: ClientPresentationSettings) -> PackedStringArray:
	if vitals.is_empty():
		return PackedStringArray()
	var lines: PackedStringArray = []
	var bleeding: int = bleeding_wound_count(vitals)
	lines.append("%s | 붕대 %d개 [%s]" % [
		"출혈 중 (%d곳)" % bleeding if bleeding > 0 else "출혈 없음",
		ConsumeIntentPolicy.count_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.BANDAGE),
		key_label(settings.bandage_key),
	])
	# P2-T7. The stage is shown as the server told it; whether a cure still
	# works at that stage is the server's rule, not judged here.
	var stage: String = str(vitals.get("infection_stage", ""))
	var infected: bool = not stage.is_empty() and stage != InfectionState.STAGE_NAMES[InfectionState.Stage.NONE]
	lines.append("%s | 치료제 %d개 [%s]" % [
		"감염: %s" % _infection_stage_text(stage) if infected else "감염 없음",
		ConsumeIntentPolicy.count_of_kind(inventory, catalog, ConsumeIntentPolicy.Kind.CURE),
		key_label(settings.cure_key),
	])
	return lines


## HUD line about resting (P2-T8) for a living owner: that it is resting and
## the key to get up, or the key to lie down. `vitals["resting"]` is what the
## server told the owner. Nothing for a dead character or without a mirror.
static func build_rest_lines(vitals: Dictionary, settings: ClientPresentationSettings) -> PackedStringArray:
	if vitals.is_empty() or vitals.get("alive", true) != true:
		return PackedStringArray()
	var key: String = key_label(settings.rest_key)
	if vitals.get("resting", false) == true:
		return PackedStringArray(["휴식 중 (피로 회복) | 일어나기 [%s]" % key])
	return PackedStringArray(["눕기 [%s]" % key])


## Server answer to a rest request (lie down / get up).
static func format_rest_result(ok: bool, reason: String) -> String:
	return "휴식 요청 승인" if ok else "휴식 요청 거부: %s" % reason


## True when a player's capsule lies on the ground: dead, or resting.
static func player_is_lying(alive: bool, resting: bool) -> bool:
	return not alive or resting


## Tilt of a player's capsule: upright, lying down to rest, or lying dead
## (death wins).
static func player_tilt_rad(alive: bool, resting: bool, settings: ClientPresentationSettings) -> float:
	if not alive:
		return settings.dead_tilt_rad
	return settings.rest_tilt_rad if resting else 0.0


## Name of a key as shown in the HUD ("B", "F1", ...).
static func key_label(key: Key) -> String:
	return OS.get_keycode_string(key)


static func format_attack_result(ok: bool, reason: String) -> String:
	return "공격 요청 승인" if ok else "공격 요청 거부: %s" % reason


## Server answer to a use request (eat, drink, bandage).
static func format_consume_result(ok: bool, reason: String) -> String:
	return "아이템 사용 승인" if ok else "아이템 사용 거부: %s" % reason


## Local notice: a use key was pressed but the mirrored inventory holds
## nothing of that kind (no request was sent).
static func nothing_to_use_text(kind: ConsumeIntentPolicy.Kind) -> String:
	match kind:
		ConsumeIntentPolicy.Kind.FOOD:
			return "먹을 것이 없습니다"
		ConsumeIntentPolicy.Kind.DRINK:
			return "마실 것이 없습니다"
		ConsumeIntentPolicy.Kind.BANDAGE:
			return "붕대가 없습니다"
		ConsumeIntentPolicy.Kind.CURE:
			return "치료제가 없습니다"
	return "쓸 수 있는 것이 없습니다"


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
