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


## Name shown for an item definition: its display name, or its id when the
## definition or its name is missing.
static func item_display_name(definition_id: String, catalog: ItemCatalog) -> String:
	var definition: ItemDefinition = catalog.get_definition(definition_id) if catalog != null else null
	return definition.display_name if definition != null and not definition.display_name.is_empty() else definition_id


## HUD inventory list from the local inventory mirror (ItemInstance
## dictionaries), P2-T15: a header with the number of carried stacks and the
## cursor / drop keys, then one line per stack ("name x quantity") in cursor
## order (InventorySelectionPolicy), the line of `selected_id` marked with
## ">". At most `settings.hud_inventory_line_count` stacks are listed, a
## window that always contains the cursor; the stacks above and below it are
## counted. Names come from the static item catalog (the definition id when
## a definition or its name is missing). Malformed entries are skipped.
static func build_inventory_lines(inventory: Array[Dictionary], catalog: ItemCatalog, selected_id: String, settings: ClientPresentationSettings) -> PackedStringArray:
	var ids: PackedStringArray = InventorySelectionPolicy.ordered_item_ids(inventory)
	if ids.is_empty():
		return PackedStringArray(["소지품: 없음"])
	var rows: Dictionary[String, Dictionary] = {}
	for entry: Dictionary in inventory:
		if InventorySelectionPolicy.quantity_of_row(entry) >= 1:
			rows[str(entry["item_instance_id"])] = entry
	var drop: String = key_label(settings.drop_key)
	var lines: PackedStringArray = ["소지품 (%d) | 선택 [%s/%s] 내려놓기 [%s] 묶음째 [%s+%s]" % [
		ids.size(),
		key_label(settings.select_previous_key), key_label(settings.select_next_key),
		drop,
		key_label(settings.drop_stack_modifier_key), drop,
	]]
	var listed: int = mini(ids.size(), maxi(settings.hud_inventory_line_count, 1))
	var first: int = clampi(maxi(ids.find(selected_id), 0) - (listed >> 1), 0, ids.size() - listed)
	if first > 0:
		lines.append("  ... 위 %d개" % first)
	for index: int in range(first, first + listed):
		var entry: Dictionary = rows[ids[index]]
		var definition_id: Variant = entry.get("definition_id", null)
		var item_name: String = item_display_name(str(definition_id), catalog) if typeof(definition_id) == TYPE_STRING else "?"
		lines.append("%s %s x%d" % [">" if ids[index] == selected_id else " ", item_name, InventorySelectionPolicy.quantity_of_row(entry)])
	if first + listed < ids.size():
		lines.append("  ... 아래 %d개" % (ids.size() - first - listed))
	return lines


## Label of an item lying in the world (a mirror row of
## ClientWorldState.world_items): "name x quantity". "" for a row that is no
## world item.
static func world_item_label(entry: Dictionary, catalog: ItemCatalog) -> String:
	var definition_id: Variant = entry.get(ClientWorldState.KEY_DEFINITION_ID, null)
	var quantity: Variant = entry.get(ClientWorldState.KEY_QUANTITY, null)
	if typeof(definition_id) != TYPE_STRING or str(definition_id).is_empty() or not ItemInstance.is_integer_value(quantity) or int(quantity) < 1:
		return ""
	return "%s x%d" % [item_display_name(str(definition_id), catalog), int(quantity)]


## HUD line about what the pickup key would pick up now (P2-T15):
## `candidate` is the mirror row of the nearest world item in reach, {} when
## there is none.
static func build_pickup_lines(candidate: Dictionary, catalog: ItemCatalog, pickup_key: Key) -> PackedStringArray:
	var label: String = world_item_label(candidate, catalog)
	return PackedStringArray(["줍기 [%s]: %s" % [key_label(pickup_key), label if not label.is_empty() else "가까이에 없음"]])


## Server answer to a drop request (P2-T15). What the player can do
## something about is told as a sentence; everything else keeps its code.
static func format_drop_result(ok: bool, reason: String) -> String:
	if ok:
		return "내려놓기 승인"
	match reason:
		InventoryService.REASON_NOT_IN_INVENTORY:
			return "내려놓기 거부: 가지고 있지 않은 아이템입니다"
		InventoryService.REASON_BAD_QUANTITY:
			return "내려놓기 거부: 수량이 맞지 않습니다"
	return "내려놓기 거부: %s" % reason


## Server answer to a pickup request (P2-T15: shown since items travel over
## the ground and a full inventory must be noticed).
static func format_pickup_result(ok: bool, reason: String) -> String:
	if ok:
		return "줍기 승인"
	match reason:
		InventoryService.REASON_INVENTORY_FULL:
			return "줍기 거부: 소지품이 가득 찼습니다"
		InventoryService.REASON_TOO_FAR:
			return "줍기 거부: 너무 멉니다"
		InventoryService.REASON_NOT_IN_WORLD, InventoryService.REASON_UNKNOWN_ITEM:
			return "줍기 거부: 이미 없는 아이템입니다"
	return "줍기 거부: %s" % reason


## Local notice: the drop key was pressed but the cursor is on nothing (no
## request was sent).
static func nothing_selected_text() -> String:
	return "내려놓을 아이템이 없습니다"


## Local notice: the pickup key was pressed but nothing lies in reach (no
## request was sent).
static func nothing_to_pick_up_text() -> String:
	return "가까이에 주울 것이 없습니다"


## HUD line about where the local player is on the map (P3-2): the id of the
## world cell it stands in (worked out from the layout the server sent), its
## position and what the cell overlay key does now. No line while the cell
## is not known (`cell_id` "": not joined, no layout, no character yet).
static func build_map_lines(cell_id: String, position: Vector3, overlay_visible: bool, settings: ClientPresentationSettings) -> PackedStringArray:
	if cell_id.is_empty():
		return PackedStringArray()
	return PackedStringArray(["셀 %s | 위치 x %d, z %d | 셀 경계 [%s] %s" % [
		cell_id,
		floori(position.x),
		floori(position.z),
		key_label(settings.cell_overlay_key),
		"켜짐" if overlay_visible else "꺼짐",
	]])


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


# ------------------------------------------------------------ treating another player (P2-T12)

## HUD line about whom a "use on another player" key would treat: the name
## of the candidate and the key combinations, or that there is nobody.
## Nothing for a dead character or without a mirror.
static func build_treat_target_lines(vitals: Dictionary, target_name: String, settings: ClientPresentationSettings) -> PackedStringArray:
	if vitals.is_empty() or vitals.get("alive", true) != true:
		return PackedStringArray()
	if target_name.is_empty():
		return PackedStringArray(["줄 대상: 없음 (가까이서 바라보기)"])
	var modifier: String = key_label(settings.treat_other_modifier_key)
	# Food and drink can be given too (P2-T13), with the same modifier.
	return PackedStringArray(["줄 대상: %s | 음식 [%s+%s] 물 [%s+%s] 붕대 [%s+%s] 치료제 [%s+%s]" % [
		target_name,
		modifier, key_label(settings.consume_key),
		modifier, key_label(settings.drink_key),
		modifier, key_label(settings.bandage_key),
		modifier, key_label(settings.cure_key),
	]])


## Server answer to a use-on-another-player request (a treatment, or food /
## drink: P2-T13). What the answer says about the other player (it does not
## bleed, it is not infected, it is too late) is the only thing the user
## learns about it, told as a sentence.
static func format_use_on_result(ok: bool, reason: String) -> String:
	if ok:
		return "남에게 사용 승인"
	match reason:
		SurvivalService.REASON_NOT_BLEEDING:
			return "남에게 사용 거부: 상대에게 출혈이 없습니다"
		SurvivalService.REASON_NOT_INFECTED:
			return "남에게 사용 거부: 상대는 감염되지 않았습니다"
		SurvivalService.REASON_TOO_LATE:
			return "남에게 사용 거부: 상대의 감염이 너무 진행되어 늦었습니다"
		ItemConsumption.REASON_TARGET_TOO_FAR:
			return "남에게 사용 거부: 대상이 너무 멉니다"
		ItemConsumption.REASON_TARGET_DEAD:
			return "남에게 사용 거부: 대상이 사망했습니다"
		ItemConsumption.REASON_TARGET_UNAVAILABLE:
			return "남에게 사용 거부: 그런 대상이 없습니다"
		ItemConsumption.REASON_NOT_USABLE_ON_OTHERS:
			return "남에게 사용 거부: 줄 수 없는 아이템입니다"
	return "남에게 사용 거부: %s" % reason


## Local notice: a use-on-another-player key was pressed but nobody is in
## reach.
static func no_treat_target_text() -> String:
	return "가까이에 줄 대상이 없습니다"


## Event log line for a treatment notice (InventoryNetModule.treatment_seen):
## for the target who used what on it and whether it did anything, for a
## bystander only who tended to whom. `names` maps player ids to character
## names (ids are shown for players without one). "" for anything else.
static func format_treatment_notice(notice: Dictionary, names: Dictionary, catalog: ItemCatalog) -> String:
	var user_id: String = str(notice.get("user_id", ""))
	var target_id: String = str(notice.get("target_id", ""))
	var user_name: String = str(names.get(user_id, user_id))
	match str(notice.get("scope", "")):
		InventoryNetModule.NOTICE_SCOPE_PUBLIC:
			# A bystander is not told what was used (a treatment or food).
			return "%s → %s 돌봄" % [user_name, str(names.get(target_id, target_id))]
		InventoryNetModule.NOTICE_SCOPE_TARGET:
			var definition_id: String = str(notice.get("definition_id", ""))
			var definition: ItemDefinition = catalog.get_definition(definition_id) if catalog != null else null
			var item_name: String = definition.display_name if definition != null and not definition.display_name.is_empty() else definition_id
			var outcome: String = "" if notice.get("ok", false) == true else " (효과 없음)"
			return "%s이(가) 나에게 %s 사용%s" % [user_name, item_name, outcome]
	return ""


# ------------------------------------------------------------ trade (P2-T16)

## One offer of a trade as text: "name x quantity, name x quantity", or
## "(없음)" for an empty one. `entries` are offer rows of a mirrored session
## state ({definition_id, quantity}, the own offer also has item ids).
## Malformed rows are skipped.
static func format_trade_offer(entries: Array, catalog: ItemCatalog) -> String:
	var parts: PackedStringArray = []
	for entry: Variant in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var label: String = world_item_label(entry as Dictionary, catalog)
		if not label.is_empty():
			parts.append(label)
	return ", ".join(parts) if not parts.is_empty() else "(없음)"


## HUD block about the local player's trade (P2-T16). `state` is the
## mirrored session state (ClientTradeState.session(), {} = none), `names`
## maps player ids to character names (ids are shown for players without
## one), `candidate_name` is whom the request key would ask now ("" =
## nobody in reach).
##   - no session: whom the request key would ask (nothing for a dead
##     character);
##   - a request: who asked whom and the keys to answer or take it back;
##   - an open session: the other player, both offers with their
##     confirmation states, and the keys.
static func build_trade_lines(state: Dictionary, local_player_id: String, names: Dictionary, candidate_name: String, alive: bool, catalog: ItemCatalog, settings: ClientPresentationSettings) -> PackedStringArray:
	var accept: String = key_label(settings.trade_accept_key)
	var decline: String = key_label(settings.trade_decline_key)
	var partner_id: String = ClientTradeState.partner_of(state, local_player_id)
	var partner: String = str(names.get(partner_id, partner_id))
	match str(state.get("phase", "")):
		TradeSession.PHASE_REQUESTED:
			if str(state.get("requester_id", "")) == local_player_id:
				return PackedStringArray(["거래 요청 중: %s | 취소 [%s]" % [partner, decline]])
			return PackedStringArray(["%s의 거래 요청 | 수락 [%s] 거절 [%s]" % [partner, accept, decline]])
		TradeSession.PHASE_OPEN:
			var mine: Variant = state.get("my_offer", [])
			var theirs: Variant = state.get("their_offer", [])
			var my_confirmed: bool = state.get("my_confirmed", false) == true
			return PackedStringArray([
				"거래 중: %s" % partner,
				"내 제안 (%s): %s" % [_confirmed_text(my_confirmed), format_trade_offer(mine as Array if typeof(mine) == TYPE_ARRAY else [], catalog)],
				"상대 제안 (%s): %s" % [_confirmed_text(state.get("their_confirmed", false) == true), format_trade_offer(theirs as Array if typeof(theirs) == TYPE_ARRAY else [], catalog)],
				"올리기 [%s] 내리기 [%s] | %s [%s] | 거래 취소 [%s]" % [key_label(settings.trade_offer_add_key), key_label(settings.trade_offer_remove_key), "확정 취소" if my_confirmed else "확정", accept, decline],
			])
	if not alive:
		return PackedStringArray()
	return PackedStringArray(["거래 요청 [%s]: %s" % [key_label(settings.trade_request_key), candidate_name if not candidate_name.is_empty() else "상대 없음 (가까이서 바라보기)"]])


static func _confirmed_text(confirmed: bool) -> String:
	return "확정" if confirmed else "미확정"


## Server answer to a trade request of any kind. An accepted request needs
## no text ("": the HUD shows the new state). What the player can do
## something about is told as a sentence; everything else keeps its code.
static func format_trade_result(ok: bool, reason: String) -> String:
	if ok:
		return ""
	match reason:
		TradeService.REASON_TARGET_TOO_FAR:
			return "거래 거부: 상대가 너무 멉니다"
		TradeService.REASON_TARGET_DEAD:
			return "거래 거부: 상대가 사망했습니다"
		TradeService.REASON_TARGET_UNAVAILABLE:
			return "거래 거부: 그런 상대가 없습니다"
		TradeService.REASON_TARGET_RESTING:
			return "거래 거부: 상대가 자고 있습니다"
		TradeService.REASON_TARGET_BUSY:
			return "거래 거부: 상대가 다른 거래 중입니다"
		TradeService.REASON_TARGET_IS_SELF:
			return "거래 거부: 자기 자신과는 거래할 수 없습니다"
		TradeService.REASON_ALREADY_TRADING:
			return "거래 거부: 이미 거래 중입니다"
		TradeService.REASON_STALE_OFFER, TradeService.REASON_OFFER_CHANGED:
			return "거래 거부: 제안이 바뀌었습니다. 다시 확인하세요"
		TradeService.REASON_NOTHING_OFFERED:
			return "거래 거부: 올린 물건이 없습니다"
		TradeService.REASON_INVENTORY_FULL:
			return "거래 거부: 내 소지품에 자리가 없습니다"
		TradeService.REASON_OTHER_INVENTORY_FULL:
			return "거래 거부: 상대의 소지품에 자리가 없습니다"
		TradeService.REASON_OFFER_FULL:
			return "거래 거부: 더 올릴 수 없습니다"
		TradeService.REASON_SESSION_CANCELLED, TradeService.REASON_NOT_IN_SESSION, TradeService.REASON_NO_SUCH_REQUEST:
			return "거래 거부: 거래가 이미 끝났습니다"
		InventoryService.REASON_NOT_IN_INVENTORY:
			return "거래 거부: 가지고 있지 않은 아이템입니다"
		InventoryService.REASON_BAD_QUANTITY:
			return "거래 거부: 수량이 맞지 않습니다"
	return "거래 거부: %s" % reason


## Notice for a party when its request or session ended (`state` is the
## closed state of ClientTradeState.session_closed): that the trade was
## completed, or why it was cancelled and by whom. "" for a state that is
## not closed.
static func format_trade_closed(state: Dictionary, local_player_id: String, names: Dictionary) -> String:
	if str(state.get("phase", "")) != TradeSession.PHASE_CLOSED:
		return ""
	var partner_id: String = ClientTradeState.partner_of(state, local_player_id)
	var partner: String = str(names.get(partner_id, partner_id))
	if str(state.get("outcome", "")) == TradeSession.OUTCOME_COMPLETED:
		return "거래 완료: %s" % partner
	var by_me: bool = str(state.get("by_player_id", "")) == local_player_id
	var cause: String = str(state.get("cause", ""))
	match cause:
		TradeService.CAUSE_DECLINED:
			return "거래 요청을 거절했습니다" if by_me else "%s이(가) 거래 요청을 거절했습니다" % partner
		TradeService.CAUSE_WITHDRAWN:
			return "거래 요청을 취소했습니다" if by_me else "%s이(가) 거래 요청을 취소했습니다" % partner
		TradeService.CAUSE_CANCELLED:
			return "거래를 취소했습니다" if by_me else "%s이(가) 거래를 취소했습니다" % partner
		TradeService.CAUSE_TOO_FAR:
			return "거래 취소: 서로 너무 멀어졌습니다"
		TradeService.CAUSE_PLAYER_DEAD:
			return "거래 취소: 사망했습니다" if by_me else "거래 취소: 상대가 사망했습니다"
		TradeService.CAUSE_PLAYER_RESTING:
			return "거래 취소: 잠들었습니다" if by_me else "거래 취소: 상대가 잠들었습니다"
		TradeService.CAUSE_DISCONNECTED:
			return "거래 취소: 상대가 접속을 끊었습니다"
		TradeService.CAUSE_NEW_CHARACTER:
			return "거래 취소: 새 캐릭터를 시작했습니다" if by_me else "거래 취소: 상대가 새 캐릭터를 시작했습니다"
		TradeService.CAUSE_REQUEST_TIMEOUT:
			return "거래 요청이 응답 없이 취소됐습니다"
		TradeService.CAUSE_IDLE_TIMEOUT:
			return "거래 취소: 오랫동안 진행이 없었습니다"
	return "거래 취소: %s" % cause


## Notice for a party about a change inside its session that it did not
## ask for: the exchange was refused (and whose inventory has no room), or
## the server adjusted an offer to what is carried. "" for every other
## change (the HUD shows those).
static func format_trade_change(state: Dictionary, local_player_id: String) -> String:
	match str(state.get("change", "")):
		TradeService.CHANGE_EXCHANGE_FAILED:
			var cause: String = str(state.get("cause", ""))
			if cause != TradeService.CAUSE_INVENTORY_FULL:
				return "교환 실패: %s" % cause
			return "교환 실패: 내 소지품에 자리가 없습니다" if str(state.get("by_player_id", "")) == local_player_id else "교환 실패: 상대의 소지품에 자리가 없습니다"
		TradeService.CHANGE_OFFER_ADJUSTED:
			return "제안이 소지품에 맞게 바뀌었습니다. 다시 확정하세요"
	return ""


## Event log line for a bystander's notice of a completed trade
## (ClientTradeState.notice_received): who traded with whom, never what
## (whatever the notice carries). `names` maps player ids to character
## names. "" for anything else.
static func format_trade_notice(notice: Dictionary, names: Dictionary) -> String:
	var ids: Variant = notice.get("player_ids", null)
	if typeof(ids) != TYPE_ARRAY or (ids as Array).size() != 2:
		return ""
	var first: String = str((ids as Array)[0])
	var second: String = str((ids as Array)[1])
	return "%s ↔ %s 거래" % [str(names.get(first, first)), str(names.get(second, second))]


# ------------------------------------------------------------ containers (P3-3)

## Name shown for a container definition: its display name, or its id when
## the definition or its name is missing.
static func container_display_name(definition_id: String, catalog: ContainerCatalog) -> String:
	var definition: ContainerDefinition = catalog.get_definition(definition_id) if catalog != null else null
	return definition.display_name if definition != null and not definition.display_name.is_empty() else definition_id


## Label of a container standing in the world (a mirror row of
## ClientContainerState.containers): its name, with "(수색 전)" until somebody
## searched it. "" for a row that is no container.
static func container_label(entry: Dictionary, catalog: ContainerCatalog) -> String:
	var definition_id: Variant = entry.get(ClientContainerState.KEY_DEFINITION_ID, null)
	if typeof(definition_id) != TYPE_STRING or str(definition_id).is_empty():
		return ""
	var container_name: String = container_display_name(str(definition_id), catalog)
	return container_name if entry.get(ClientContainerState.KEY_SEARCHED, false) == true else "%s (수색 전)" % container_name


## HUD block of the containers (P3-3). `phase` is the mirrored session's
## (ClientContainerState.phase()):
##   no session   one line naming what the open key would open
##                (`candidate_label`, a container_label()); nothing at all
##                when no container is in reach
##   searching    "<name> 수색 중" with the length of the search and the key
##                that gives up
##   open         a header with the container's name, the number of stacks
##                inside and the keys, then one line per stack ("name x
##                quantity") in cursor order (ContainerIntentPolicy), the line
##                of `selected_id` marked with ">". At most
##                `settings.hud_container_line_count` stacks are listed, a
##                window that always contains the cursor.
## `open_label` is the name of the container of the session. Nothing is
## shown for a dead character.
static func build_container_lines(phase: String, open_label: String, search_sec: float, contents: Array[Dictionary], item_catalog: ItemCatalog, selected_id: String, candidate_label: String, alive: bool, settings: ClientPresentationSettings) -> PackedStringArray:
	var lines: PackedStringArray = []
	if not alive:
		return lines
	var open_key: String = key_label(settings.container_open_key)
	if phase == ClientContainerState.PHASE_SEARCHING:
		lines.append("%s 수색 중 (%.1f초) | 그만두기 [%s]" % [open_label, search_sec, open_key])
		return lines
	if phase != ClientContainerState.PHASE_OPEN:
		if not candidate_label.is_empty():
			lines.append("보관함 열기 [%s]: %s" % [open_key, candidate_label])
		return lines
	var ids: PackedStringArray = ContainerIntentPolicy.ordered_item_ids(contents)
	var modifier: String = key_label(settings.drop_stack_modifier_key)
	lines.append("%s (%d) | 선택 [%s/%s] 꺼내기 [%s] 넣기 [%s] 묶음째 [%s+키] 닫기 [%s]" % [
		open_label, ids.size(),
		key_label(settings.container_previous_key), key_label(settings.container_next_key),
		key_label(settings.container_take_key), key_label(settings.container_put_key),
		modifier, open_key,
	])
	if ids.is_empty():
		lines.append("  비어 있음")
		return lines
	var rows: Dictionary[String, Dictionary] = {}
	for entry: Dictionary in contents:
		if ContainerIntentPolicy.quantity_of_row(entry) >= 1:
			rows[str(entry[ClientContainerState.KEY_ITEM_ID])] = entry
	var listed: int = mini(ids.size(), maxi(settings.hud_container_line_count, 1))
	var first: int = clampi(maxi(ids.find(selected_id), 0) - (listed >> 1), 0, ids.size() - listed)
	if first > 0:
		lines.append("  ... 위 %d개" % first)
	for index: int in range(first, first + listed):
		var entry: Dictionary = rows[ids[index]]
		var definition_id: Variant = entry.get(ClientContainerState.KEY_DEFINITION_ID, null)
		var item_name: String = item_display_name(str(definition_id), item_catalog) if typeof(definition_id) == TYPE_STRING else "?"
		lines.append("%s %s x%d" % [">" if ids[index] == selected_id else " ", item_name, ContainerIntentPolicy.quantity_of_row(entry)])
	if first + listed < ids.size():
		lines.append("  ... 아래 %d개" % (ids.size() - first - listed))
	return lines


## Server answer to a container request of any kind (open, close, take,
## put). "" for an accepted one: what changed shows in the HUD. What the
## player can do something about is told as a sentence; everything else keeps
## its code.
static func format_container_result(ok: bool, reason: String) -> String:
	if ok:
		return ""
	match reason:
		ContainerService.REASON_TOO_FAR:
			return "보관함 거부: 너무 멉니다"
		ContainerService.REASON_UNKNOWN_CONTAINER:
			return "보관함 거부: 그런 보관함이 없습니다"
		ContainerService.REASON_NOT_OPEN:
			return "보관함 거부: 먼저 보관함을 여세요"
		ContainerService.REASON_SEARCHING:
			return "보관함 거부: 아직 수색 중입니다"
		ContainerService.REASON_ALREADY_OPEN:
			return "보관함 거부: 이미 열려 있습니다"
		ContainerService.REASON_ITEM_NOT_INSIDE:
			return "꺼내기 거부: 보관함에 없는 아이템입니다 (다른 사람이 먼저 꺼냈을 수 있습니다)"
		ContainerService.REASON_ITEM_NOT_CARRIED:
			return "넣기 거부: 가지고 있지 않은 아이템입니다"
		ContainerService.REASON_CONTAINER_FULL:
			return "넣기 거부: 보관함이 가득 찼습니다"
		InventoryService.REASON_INVENTORY_FULL:
			return "꺼내기 거부: 소지품이 가득 찼습니다"
		InventoryService.REASON_BAD_QUANTITY:
			return "보관함 거부: 수량이 맞지 않습니다 (다른 사람이 먼저 꺼냈을 수 있습니다)"
		NetworkService.RATE_LIMITED:
			return "보관함 거부: 요청이 너무 잦습니다"
	return "보관함 거부: %s" % reason


## Notice for a session the server ended (ClientContainerState.
## session_closed). "" when the player asked for it or opened another
## container, and for a dead character (the death message says enough).
static func format_container_closed(reason: String) -> String:
	match reason:
		ContainerService.REASON_CLOSED, ContainerService.REASON_SWITCHED, "player_dead":
			return ""
		ContainerService.REASON_TOO_FAR:
			return "보관함에서 멀어져 닫혔습니다"
		ContainerService.REASON_INTERRUPTED:
			return "공격을 받아 수색이 중단됐습니다"
		ContainerService.REASON_CONTAINER_GONE:
			return "보관함이 범위를 벗어나 닫혔습니다"
		"player_resting":
			return "누워서 보관함이 닫혔습니다"
	return "보관함이 닫혔습니다: %s" % reason


## Local notices: a container key was pressed but there is nothing to ask
## for (no request was sent).
static func nothing_to_open_text() -> String:
	return "가까이에 보관함이 없습니다"


static func container_not_open_text() -> String:
	return "열린 보관함이 없습니다"


static func nothing_to_take_text() -> String:
	return "꺼낼 아이템이 없습니다"


static func nothing_to_put_text() -> String:
	return "넣을 아이템이 없습니다"
