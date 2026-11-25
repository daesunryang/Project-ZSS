class_name NpcTalkPresentationFormatter
extends RefCounted
## Pure text of the NPC reactions and conversations (F-31, docs/09 §17.16):
## the word behind an NPC's name, the dialogue panel, and why a request was
## refused or a conversation ended. No nodes, no state, no rules: it turns
## the mirrors into Korean lines.


## The word shown for an NPC's public reaction ("" = nothing to show).
static func reaction_text(reaction: String) -> String:
	match reaction:
		NpcReactionRules.WARY:
			return "경계"
		NpcReactionRules.HIDE:
			return "거리 둠"
		NpcReactionRules.GREET:
			return "인사"
		NpcReactionRules.AFRAID:
			return "겁먹음"
		NpcReactionRules.TALK:
			return "대화 중"
	return ""


## What is written after an NPC's name for its reaction ("" for none).
static func reaction_tag(reaction: String, settings: ClientPresentationSettings) -> String:
	var text: String = reaction_text(reaction)
	return "" if text.is_empty() else settings.npc_reaction_tag_format % text


## Why a conversation is over, for the panel ("" = nothing worth saying:
## the player ended it).
static func end_reason_text(end_reason: String) -> String:
	match end_reason:
		"", NpcDialogue.END_PLAYER_LEFT:
			return ""
		NpcDialogue.END_NPC_ENDED:
			return "상대가 대화를 끝냈습니다"
		NpcDialogue.END_REFUSED:
			return "상대가 대화를 거절했습니다"
		NpcDialogue.END_TOO_FAR:
			return "멀어져서 대화가 끝났습니다"
		NpcDialogue.END_TIMEOUT:
			return "오래 말이 없어 대화가 끝났습니다"
		NpcDialogue.END_NPC_BUSY:
			return "상대가 달아나 대화가 끝났습니다"
		NpcDialogue.END_NPC_HURT:
			return "상대가 다쳐 대화가 끝났습니다"
		NpcDialogue.END_NPC_GONE:
			return "상대가 사라져 대화가 끝났습니다"
		NpcDialogue.END_PLAYER_GONE:
			return "대화가 끝났습니다"
		NpcDialogue.END_PLAYER_UNABLE:
			return "대화를 이어갈 수 없는 상태가 되어 끝났습니다"
	return "대화가 끝났습니다: %s" % end_reason


## The answer to a talk request of any kind: "" when it was accepted (the
## panel shows what happened), otherwise why not.
static func format_result(ok: bool, reason: String) -> String:
	if ok:
		return ""
	match reason:
		NpcDialogue.REASON_TOO_FAR:
			return "말을 걸기에는 너무 멉니다"
		NpcDialogue.REASON_NO_LINE_OF_SIGHT:
			return "벽에 가려 말을 걸 수 없습니다"
		NpcDialogue.REASON_NPC_DEAD:
			return "죽은 사람과는 말할 수 없습니다"
		NpcDialogue.REASON_NPC_TALKING:
			return "다른 사람과 대화하는 중입니다"
		NpcDialogue.REASON_NPC_BUSY:
			return "지금은 말을 걸 수 없습니다 (달아나는 중)"
		NpcDialogue.REASON_NPC_UNAVAILABLE, NpcDialogue.REASON_UNKNOWN_NPC:
			return "말을 걸 상대가 없습니다"
		NpcDialogue.REASON_NOT_TALKING:
			return "대화 중이 아닙니다"
		NpcDialogue.REASON_STALE_TURN:
			return "대화가 이미 넘어갔습니다. 다시 골라 주세요"
		NpcDialogue.REASON_BAD_CHOICE:
			return "지금은 고를 수 없는 답입니다"
		NpcDialogue.REASON_UNAVAILABLE:
			return "이 서버에서는 대화를 할 수 없습니다"
		NetworkService.RATE_LIMITED:
			return "너무 빨리 눌렀습니다. 잠시 뒤에 다시 해 주세요"
		"player_dead":
			return "죽은 상태에서는 말을 걸 수 없습니다"
		"player_resting":
			return "누운 채로는 말을 걸 수 없습니다"
	return "대화 요청이 거절됐습니다: %s" % reason


## Local notices: a talk key was pressed but there is nothing to ask for
## (no request was sent).
static func nobody_to_talk_to_text() -> String:
	return "가까이에 말을 걸 사람이 없습니다"


static func no_such_choice_text() -> String:
	return "그 번호의 답은 없습니다"


## The dialogue panel. While a conversation is open: the NPC's name, what it
## said, the numbered answers and the keys. For `show_closed` (a
## conversation that just ended, or an NPC that would not talk): the last
## line and why it is over. Otherwise the hint of whom the talk key would
## ask (`candidate_name`, "" = nobody). Nothing while dead.
## `number_keys_free` false = the number keys mean something else now (the
## build mode), so the answers cannot be chosen.
static func build_lines(view: Dictionary, show_closed: bool, candidate_name: String, alive: bool, number_keys_free: bool, settings: ClientPresentationSettings) -> PackedStringArray:
	var lines: PackedStringArray = []
	if not alive:
		return lines
	var talk_key: String = ClientPresentationFormatter.key_label(settings.npc_talk_key)
	var open: bool = view.get(NpcDialogue.KEY_OPEN, false) == true
	if not open and not (show_closed and not view.is_empty()):
		if not candidate_name.is_empty():
			lines.append("말 걸기 [%s]: %s" % [talk_key, candidate_name])
		return lines
	var npc_name: String = str(view.get(NpcDialogue.KEY_NPC_NAME, ""))
	lines.append(npc_name if not npc_name.is_empty() else "?")
	var said: String = str(view.get(NpcDialogue.KEY_LINE, ""))
	if not said.is_empty():
		lines.append("\"%s\"" % said)
	if not open:
		var why: String = end_reason_text(str(view.get(NpcDialogue.KEY_END_REASON, "")))
		if not why.is_empty():
			lines.append("(%s)" % why)
		return lines
	var raw_choices: Variant = view.get(NpcDialogue.KEY_CHOICES, [])
	var choices: Array = raw_choices if typeof(raw_choices) == TYPE_ARRAY else []
	for index: int in choices.size():
		var entry: Variant = choices[index]
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() != ClientDialogueState.CHOICE_SIZE:
			continue
		lines.append("%d. %s" % [index + 1, str((entry as Array)[ClientDialogueState.CHOICE_TEXT])])
	var end_key: String = ClientPresentationFormatter.key_label(settings.npc_talk_end_key)
	if number_keys_free:
		lines.append("답 고르기 [1-%d] | 대화 끝내기 [%s]" % [mini(choices.size(), ClientInputActions.TALK_CHOICE_COUNT), end_key])
	else:
		lines.append("건축 모드에서는 답을 고를 수 없습니다 | 대화 끝내기 [%s]" % end_key)
	return lines
