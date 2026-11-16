class_name StructurePresentationFormatter
extends RefCounted
## Pure Korean strings for the building HUD and server results.

const REASONS: Dictionary[String, String] = {
	"bad_type": "요청 형식이 올바르지 않습니다",
	"bad_sequence": "요청 순서가 올바르지 않습니다",
	"bad_definition_id": "구조물 종류가 올바르지 않습니다",
	"bad_structure_id": "구조물 ID가 올바르지 않습니다",
	"bad_item_id": "자재 ID가 올바르지 않습니다",
	"bad_quantity": "자재 수량이 올바르지 않습니다",
	"not_joined": "아직 월드에 접속하지 않았습니다",
	"rate_limited": "요청이 너무 잦습니다",
	"unknown_structure_definition": "알 수 없는 구조물 종류입니다",
	"bad_rotation": "회전값이 올바르지 않습니다",
	"out_of_bounds": "맵 바깥에는 지을 수 없습니다",
	"too_far": "너무 멉니다",
	"cell_not_loaded": "아직 불러오지 않은 지역입니다",
	"slot_occupied": "이미 다른 구조물이 차지한 자리입니다",
	"blocked_by_entity": "사람이나 좀비가 자리를 막고 있습니다",
	"structure_limit": "이 지역의 구조물 한도에 도달했습니다",
	"structure_id_failed": "구조물 ID를 만들지 못했습니다",
	"unknown_structure": "이미 없거나 알 수 없는 구조물입니다",
	"not_owner": "배치한 사람만 취소하거나 철거할 수 있습니다",
	"not_a_door": "문이 아닙니다",
	"structure_not_usable": "지금 사용할 수 없는 구조물입니다",
	"door_already_in_state": "문이 이미 그 상태입니다",
	"building_unavailable": "건축 시스템을 사용할 수 없습니다",
	"structure_not_under_construction": "짓는 중인 구조물이 아닙니다",
	"structure_under_construction": "짓는 중에는 철거할 수 없습니다",
	"materials_complete": "필요한 자재가 이미 모두 들어갔습니다",
	"material_not_needed": "그 자재는 필요하지 않습니다",
	"no_materials_carried": "넣을 수 있는 자재를 들고 있지 않습니다",
	"item_not_in_inventory": "그 자재를 들고 있지 않습니다",
	"unknown_inventory": "소지품을 찾을 수 없습니다",
	"nothing_to_move": "옮길 자재가 없습니다",
	"bad_offer": "자재 목록 형식이 올바르지 않습니다",
	"duplicate_item": "같은 자재 묶음이 중복됐습니다",
	"unknown_item": "알 수 없는 자재입니다",
	"materials_missing": "자재가 부족해 작업할 수 없습니다",
	"already_working": "이미 작업 중입니다",
	"not_working": "현재 작업 중이 아닙니다",
	"too_many_workers": "이 구조물의 작업자가 너무 많습니다",
	"refund_failed": "자재를 돌려놓지 못했습니다",
	"player_dead": "사망한 상태에서는 할 수 없습니다",
	"player_resting": "쉬는 중에는 할 수 없습니다",
	"not_online": "플레이어가 월드에 없습니다",
}


static func result_text(ok: bool, reason: String) -> String:
	if ok:
		return "건축 요청 승인"
	return "건축 요청 거부: %s" % REASONS.get(reason, reason if not reason.is_empty() else "알 수 없는 사유")


static func work_stop_text(reason: String) -> String:
	var labels: Dictionary[String, String] = {
		"stopped": "작업을 멈췄습니다", "switched": "다른 구조물로 작업을 옮겼습니다",
		"work_finished": "작업이 끝났습니다", "structure_removed": "구조물이 없어져 작업을 멈췄습니다",
		"structure_unloaded": "구조물이 보이는 범위에서 벗어났습니다",
	}
	return labels.get(reason, REASONS.get(reason, reason))


static func material_text(required: Dictionary, delivered: Dictionary, items: ItemCatalog) -> String:
	var parts: PackedStringArray = []
	var ids: PackedStringArray = PackedStringArray(required.keys())
	ids.sort()
	for item_id: String in ids:
		var definition: ItemDefinition = items.get_definition(item_id) if items != null else null
		var development_names: Dictionary[String, String] = {"dev_wood": "목재", "dev_nails": "못"}
		var name: String = development_names.get(item_id, definition.display_name if definition != null else item_id)
		parts.append("%s %d/%d" % [name, int(delivered.get(item_id, 0)), int(required[item_id])])
	return " · ".join(parts) if not parts.is_empty() else "자재 없음"


static func structure_summary(entry: Dictionary, worker_count: int, items: ItemCatalog) -> String:
	if entry.is_empty():
		return "대상 구조물: 없음"
	var state: String = str(entry.get(ClientStructureState.KEY_STATE, ""))
	var progress: int = roundi(float(entry.get(ClientStructureState.KEY_PROGRESS, 0.0)) * 100.0)
	var materials: String = material_text(entry.get(ClientStructureState.KEY_REQUIRED, {}), entry.get(ClientStructureState.KEY_DELIVERED, {}), items)
	return "대상: %s | %s | %d%% | 작업자 %d명" % [state_label(state), materials, progress, worker_count]


static func state_label(state: String) -> String:
	return {"blueprint": "청사진", "constructing": "건설 중", "completed": "완공", "damaged": "손상", "destroyed": "파괴"}.get(state, state)
