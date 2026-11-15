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
	# The name of the local character (P2-T9), when the mirror has it.
	var character_name: String = str(vitals.get("character_name", ""))
	if generation > 0 and not character_name.is_empty():
		lines.append("%s | 캐릭터 #%d" % [character_name, generation])
	elif generation > 0:
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


## HUD lines about resting (P2-T8) for a living owner: that it is resting and
## the key to get up, or the key to lie down; then, when the fatigue category
## is caution or danger, that fatigue lowers its work ability (P2-T10).
## `vitals["resting"]` and `vitals["needs"]` are what the server told the
## owner. Nothing for a dead character or without a mirror.
static func build_rest_lines(vitals: Dictionary, settings: ClientPresentationSettings) -> PackedStringArray:
	if vitals.is_empty() or vitals.get("alive", true) != true:
		return PackedStringArray()
	var key: String = key_label(settings.rest_key)
	var lines: PackedStringArray = []
	if vitals.get("resting", false) == true:
		lines.append("휴식 중 (피로 회복) | 일어나기 [%s]" % key)
	else:
		lines.append("눕기 [%s]" % key)
	# P2-T10: fatigue lowers work ability (melee damage and later work).
	var needs: Variant = vitals.get("needs", {})
	var work_text: String = fatigue_work_text(str((needs as Dictionary).get("fatigue", ""))) if typeof(needs) == TYPE_DICTIONARY else ""
	if not work_text.is_empty():
		lines.append(work_text)
	return lines


## HUD text for the work-ability penalty of a fatigue category (P2-T10), ""
## when there is none. The category is what the server sent; the factor
## itself is a server setting and is not shown.
static func fatigue_work_text(category: String) -> String:
	match category:
		"caution":
			return "피로로 작업 능력 저하 (주의)"
		"danger":
			return "피로로 작업 능력 크게 저하 (위험)"
	return ""


## Notice for the owner when its rest ended for `cause` (P2-T10), "" when no
## notice is needed (it asked to get up, it died, unknown cause).
static func format_rest_ended(cause: String) -> String:
	match cause:
		SurvivalService.REST_END_DAMAGED:
			return "공격을 받아 잠에서 깼습니다"
		SurvivalService.REST_END_LOW_HEALTH:
			return "체력이 위험해 잠에서 깼습니다"
		SurvivalService.REST_END_THIRST:
			return "갈증이 심해 잠에서 깼습니다"
		SurvivalService.REST_END_HUNGER:
			return "허기가 심해 잠에서 깼습니다"
		SurvivalService.REST_END_INFECTION:
			return "감염이 악화되어 잠에서 깼습니다"
	return ""


## Notice for a mirrored survival event, "" for the events that need none.
## Only the owner's own waking is announced.
static func format_survival_notice(event: Dictionary) -> String:
	if str(event.get("scope", "")) != ClientSurvivalState.SCOPE_OWNER:
		return ""
	if str(event.get("event_type", "")) != SurvivalService.EVENT_PLAYER_REST_ENDED:
		return ""
	return format_rest_ended(str(event.get("cause", "")))


## Server answer to a rest request (lie down / get up). A lie-down refused
## because the player is in danger (P2-T10) is told as a sentence.
static func format_rest_result(ok: bool, reason: String) -> String:
	if ok:
		return "휴식 요청 승인"
	if reason.begins_with(SurvivalService.REASON_CANNOT_REST_PREFIX):
		match reason.trim_prefix(SurvivalService.REASON_CANNOT_REST_PREFIX):
			SurvivalService.REST_END_LOW_HEALTH:
				return "지금은 누울 수 없습니다: 체력이 너무 낮습니다"
			SurvivalService.REST_END_THIRST:
				return "지금은 누울 수 없습니다: 갈증이 위험합니다"
			SurvivalService.REST_END_HUNGER:
				return "지금은 누울 수 없습니다: 허기가 위험합니다"
			SurvivalService.REST_END_INFECTION:
				return "지금은 누울 수 없습니다: 감염이 너무 진행됐습니다"
	return "휴식 요청 거부: %s" % reason


## True when a player's capsule lies on the ground: dead, or resting.
static func player_is_lying(alive: bool, resting: bool) -> bool:
	return not alive or resting


## Tilt of a player's capsule: upright, lying down to rest, or lying dead
## (death wins).
static func player_tilt_rad(alive: bool, resting: bool, settings: ClientPresentationSettings) -> float:
	if not alive:
		return settings.dead_tilt_rad
	return settings.rest_tilt_rad if resting else 0.0


## True when a player's capsule is drawn prone (P2-T11): alive, not asleep
## (`resting` is what the survival mirror says) and the posture mirror says
## prone.
static func player_is_prone(alive: bool, resting: bool, posture: PlayerPosture.Kind) -> bool:
	return alive and not resting and posture == PlayerPosture.Kind.PRONE


## Tilt of a player's capsule about its X axis: upright (0), prone (leaning
## forward, negative), lying asleep on its back, or lying dead. Death wins
## over sleep, sleep over prone.
static func player_pose_tilt_rad(alive: bool, resting: bool, prone: bool, settings: ClientPresentationSettings) -> float:
	if not alive:
		return settings.dead_tilt_rad
	if resting:
		return settings.rest_tilt_rad
	return -settings.prone_tilt_rad if prone else 0.0


## Height of the centre of a capsule tilted by `tilt_rad` whose lowest point
## touches the ground: half the height when upright, the radius when flat.
static func player_body_center_height(radius: float, height: float, tilt_rad: float) -> float:
	return radius + maxf(height * 0.5 - radius, 0.0) * absf(cos(tilt_rad))


## HUD line about the owner's posture (P2-T11): standing, prone ("hidden")
## or asleep, and the prone key. `vitals["posture"]` is a PlayerPosture name
## the server told. Nothing for a dead character or without a mirror.
static func build_posture_lines(vitals: Dictionary, settings: ClientPresentationSettings) -> PackedStringArray:
	if vitals.is_empty() or vitals.get("alive", true) != true:
		return PackedStringArray()
	var key: String = key_label(settings.prone_key)
	match str(vitals.get("posture", "")):
		"prone":
			return PackedStringArray(["자세: 엎드림 (은신 중) | 일어서기 [%s]" % key])
		"resting":
			return PackedStringArray(["자세: 누워 잠 | 엎드리기 [%s]" % key])
	return PackedStringArray(["자세: 서 있음 | 엎드리기 [%s]" % key])


## Server answer to a posture request (stand up / lie prone). A refused
## lie-down is told like the rest key's (format_rest_result).
static func format_posture_result(ok: bool, reason: String) -> String:
	if ok:
		return "자세 변경 승인"
	if reason.begins_with(SurvivalService.REASON_CANNOT_REST_PREFIX):
		return format_rest_result(false, reason)
	return "자세 변경 거부: %s" % reason


## Name of a key as shown in the HUD ("B", "F1", ...).
static func key_label(key: Key) -> String:
	return OS.get_keycode_string(key)


static func format_attack_result(ok: bool, reason: String) -> String:
	if ok:
		return "공격 요청 승인"
	# P2-T11: a prone player must stand up first.
	if reason == PostureService.REASON_PLAYER_PRONE:
		return "공격 요청 거부: 엎드린 채로는 공격할 수 없습니다"
	return "공격 요청 거부: %s" % reason


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


# ------------------------------------------------------------ character creation (P2-T9)

## Text for the reason code of a refused character creation, from the local
## check or from the server ("" for ""). A code this client does not know is
## shown as it is, so nothing is hidden from the player.
static func format_creation_reason(reason: String, settings: CharacterSettings) -> String:
	match reason:
		"":
			return ""
		CharacterNameRules.REASON_EMPTY:
			return "이름을 입력하세요."
		CharacterNameRules.REASON_TOO_SHORT:
			return "이름이 너무 짧습니다. %d자 이상이어야 합니다." % settings.name_min_length
		CharacterNameRules.REASON_TOO_LONG:
			return "이름이 너무 깁니다. %d자 이하여야 합니다." % settings.name_max_length
		CharacterNameRules.REASON_BAD_CHARACTERS:
			return "이름에 쓸 수 없는 문자가 있습니다."
		CharacterNameRules.REASON_BANNED:
			return "이 이름은 사용할 수 없습니다."
		ServerWorld.REASON_NAME_TAKEN:
			return "이미 다른 캐릭터가 쓰는 이름입니다."
		AppearanceCatalog.REASON_UNKNOWN_SLOT, AppearanceCatalog.REASON_UNKNOWN_OPTION, AppearanceCatalog.REASON_TOO_LARGE:
			return "서버가 모르는 외형 선택입니다. 게임 버전을 확인하세요."
		SurvivalService.REASON_CHARACTER_ALIVE:
			return "이미 살아 있는 캐릭터가 있습니다."
		SurvivalService.REASON_RESPAWN_WAIT:
			return "아직 새 캐릭터를 만들 수 없습니다. 잠시 기다리세요."
		NetworkService.RATE_LIMITED:
			return "요청이 너무 잦습니다. 잠시 뒤 다시 시도하세요."
		CharacterNetModule.REASON_PAYLOAD_TOO_LARGE, IntentValidator.REASON_BAD_TYPE, IntentValidator.REASON_BAD_SEQUENCE:
			return "요청 형식이 잘못되었습니다."
	return "서버가 거부했습니다: %s" % reason


## One line about what a name may be (shown under the name field).
static func format_name_rule(settings: CharacterSettings) -> String:
	return "이름은 %d~%d자입니다. 앞뒤 공백은 지워집니다." % [settings.name_min_length, settings.name_max_length]


## The line under the title of the creation screen.
static func creation_hint(first_character: bool) -> String:
	if first_character:
		return "이름과 외형을 정하면 스폰 지점에서 시작합니다."
	return "이전 캐릭터는 끝났습니다. 새 캐릭터의 이름과 외형을 정하세요."
