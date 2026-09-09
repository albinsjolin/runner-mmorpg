extends CanvasLayer
## Minimal debug HUD: connection status, own stats, party list, recent events.

signal back_to_town

const C := preload("res://shared/constants.gd")
const EVENT_LINES := 6

var _net: Label
var _end_layer: CanvasLayer
var _end_title: Label
var _end_lines: Label
var _end_note: Label
var _end_button: Button

var zone: Dictionary = Zones.get_zone(Zones.DEFAULT_ZONE)

var _status: Label
var _zone_label: Label
var _stats: Label
var _party: Label
var _events: Label
var _log: Array[String] = []


func _ready() -> void:
	_status = _make_label(Vector2(0, 0), HORIZONTAL_ALIGNMENT_CENTER, 28)
	_status.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_status.offset_top = 40
	_status.offset_left = -400
	_status.offset_right = 400

	_zone_label = _make_label(Vector2(16, 8), HORIZONTAL_ALIGNMENT_LEFT, 22)
	_zone_label.modulate = Color(1.0, 0.9, 0.6)
	_stats = _make_label(Vector2(16, 40), HORIZONTAL_ALIGNMENT_LEFT, 20)
	_party = _make_label(Vector2(16, 205), HORIZONTAL_ALIGNMENT_LEFT, 16)
	_events = _make_label(Vector2(16, 0), HORIZONTAL_ALIGNMENT_LEFT, 15)
	_events.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_events.offset_top = -EVENT_LINES * 22 - 16
	_events.offset_left = 16
	_events.offset_right = 600
	_events.modulate = Color(0.85, 0.85, 0.85)

	var help := _make_label(Vector2(-16, 12), HORIZONTAL_ALIGNMENT_RIGHT, 15)
	help.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	help.offset_left = -900
	help.offset_right = -16
	help.text = "A/D or arrows: dodge (switch lane)   Space/W: jump   S: slide   K: ability   E: extract at camp   (swings land on impact)"

	_net = _make_label(Vector2(-16, 36), HORIZONTAL_ALIGNMENT_RIGHT, 16)
	_net.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_net.offset_left = -600
	_net.offset_right = -16
	_net.modulate = Color(0.8, 0.95, 0.8)


func set_status(text: String) -> void:
	_status.text = text


## Round trip to the run server, packet loss, and how stale the newest snapshot is.
func set_net_stats(rtt_ms: float, loss_pct: float, snapshot_age_ms: float, host: String) -> void:
	_net.text = "%s   ping %d ms   loss %.1f%%   snapshot age %d ms" % [host, int(rtt_ms), loss_pct, int(snapshot_age_ms)]
	_net.modulate = Color(0.8, 0.95, 0.8) if rtt_ms < 80 else (Color(1.0, 0.9, 0.5) if rtt_ms < 150 else Color(1.0, 0.6, 0.5))


## Full-screen end-of-run card. `kind` is "defeat" or "extracted".
func show_end_screen(kind: String, lines: Array[String]) -> void:
	if _end_layer == null:
		_build_end_screen()
	var defeat := kind == "defeat"
	_end_title.text = "DEFEAT" if defeat else "EXTRACTED"
	_end_title.modulate = Color(1.0, 0.35, 0.3) if defeat else Color(1.0, 0.85, 0.4)
	_end_lines.text = "\n".join(lines)
	_end_note.text = "Your party is still running. Loot is committed when the run ends; you can head back now."
	_end_layer.visible = true
	_status.visible = false


## Called once the server has committed the run: the numbers are final.
func mark_run_committed() -> void:
	if _end_layer != null and _end_layer.visible:
		_end_note.text = "Run committed. Your loot is safe in town."


func is_end_screen_shown() -> bool:
	return _end_layer != null and _end_layer.visible


func _build_end_screen() -> void:
	_end_layer = CanvasLayer.new()
	_end_layer.layer = 10
	add_child(_end_layer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_end_layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_end_layer.add_child(center)
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(620, 0)
	center.add_child(card)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 28)
	card.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)
	_end_title = Label.new()
	_end_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_title.add_theme_font_size_override("font_size", 44)
	box.add_child(_end_title)
	_end_lines = Label.new()
	_end_lines.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_lines.add_theme_font_size_override("font_size", 20)
	box.add_child(_end_lines)
	_end_note = Label.new()
	_end_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_note.autowrap_mode = TextServer.AUTOWRAP_WORD
	_end_note.modulate = Color(0.8, 0.8, 0.8)
	box.add_child(_end_note)
	_end_button = Button.new()
	_end_button.text = "Back to Town"
	_end_button.custom_minimum_size = Vector2(200, 44)
	_end_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_end_button.pressed.connect(func() -> void: back_to_town.emit())
	box.add_child(_end_button)


func apply_snapshot(snap: Dictionary, my_id: int) -> void:
	var run_seconds: float = snap.tick / float(C.TICK_RATE)
	var level := 1 + int(floor(run_seconds / zone.level_every_seconds))
	_zone_label.text = "%s   %s L%d   %d:%02d" % [zone.name, zone.monster.name, level, int(run_seconds) / 60, int(run_seconds) % 60]
	if snap.players.has(my_id):
		var p: Dictionary = snap.players[my_id]
		var stats: Dictionary = C.ROLE_STATS[p.role]
		var pose := "[JUMPING]" if p.jumping else ("[SLIDING]" if p.sliding else "")
		_stats.text = "%s   HP %d/%d%s\nDodges %d/%d   %s\nWeapon %d   Armor %d   Ability %s\nLoot %d banked   +%d unbanked\nDistance %dm   Speed %.1fx   Tick %d" % [
			stats.name, p.hp, p.max_hp, "   Shield %d" % p.shield if p.shield > 0 else "",
			p.dodge_charges, p.max_dodge, pose,
			p.damage, p.armor,
			"ready" if p.ability_cd == 0 else "%.1fs" % (p.ability_cd / float(C.TICK_RATE)),
			p.loot, p.unbanked,
			int(snap.distance), snap.speed / C.BASE_SPEED, snap.tick]
		if p.extracted:
			set_status("EXTRACTED with %d loot. Watching the party." % p.loot)
		elif not p.alive:
			set_status("YOU DIED. Watching the party.")
		elif snap.at_camp:
			set_status("AT CAMP: loot banked. Press E to extract, or keep running.")
		else:
			set_status("")
	var lines: Array[String] = []
	for peer_id in snap.players:
		var o: Dictionary = snap.players[peer_id]
		lines.append("%s%s  %d/%d%s" % [
			"> " if peer_id == my_id else "   ", C.ROLE_STATS[o.role].name, o.hp, o.max_hp,
			"  (extracted)" if o.extracted else ("" if o.alive else "  (dead)")])
	_party.text = "Party\n" + "\n".join(lines) + "\n\nMonsters ahead: %d   Obstacles: %d" % [snap.monsters.size(), snap.obstacles.size()]

	for ev in snap.events:
		_push_event(_describe(ev, snap, my_id))


func _describe(ev: Dictionary, snap: Dictionary, my_id: int) -> String:
	var who := "You" if ev.get("peer", -1) == my_id else _name_of(ev.get("peer", -1), snap)
	match ev.type:
		"hit": return "%s hit monster %d for %d" % [who, ev.monster, ev.damage]
		"kill": return "%s killed monster %d" % [who, ev.monster]
		"knockback": return "monster %d survived and flew back" % ev.monster
		"loot": return "%s looted %d" % [who, ev.amount]
		"camp": return "Camp reached: loot banked"
		"extracted": return "%s extracted with %d loot" % [who, ev.loot]
		"no_extract": return "%s can only extract at a camp" % who
		"damage": return "%s took %d damage from %s" % [who, ev.damage, _thing(ev)]
		"avoided": return "%s %s %s" % [who, "jumped over" if ev.how == "jump" else "slid under", _thing(ev)]
		"dodge": return "%s dodged to lane %d" % [who, ev.lane + 1]
		"no_dodge": return "%s has no dodge charges!" % who
		"heal": return "%s healed the party for %d" % [who, ev.amount]
		"shield": return "%s raised a shield wall" % who
		"refresh": return "%s refreshed dodges" % who
		"death": return "%s died, losing %d unbanked loot" % [who, ev.lost]
	return str(ev)


func _thing(ev: Dictionary) -> String:
	if ev.has("monster"):
		return "monster %d" % ev.monster
	return "obstacle %d" % ev.get("obstacle", -1)


func _name_of(peer_id: int, snap: Dictionary) -> String:
	if snap.players.has(peer_id):
		return "%s(%d)" % [C.ROLE_STATS[snap.players[peer_id].role].name, peer_id]
	return "peer %d" % peer_id


func _push_event(text: String) -> void:
	_log.append(text)
	while _log.size() > EVENT_LINES:
		_log.pop_front()
	_events.text = "\n".join(_log)


func _make_label(pos: Vector2, align: int, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	add_child(l)
	return l
