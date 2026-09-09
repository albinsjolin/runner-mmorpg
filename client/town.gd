extends Control
## The town: the chill screen between runs. No movement, clickable buildings, chat,
## party board. Everything shown comes straight from SpacetimeDB rows; every action
## is a reducer. When the party's run turns ready, run_ready fires and main.gd takes over.

signal run_ready(run: RunnerRun, secret: String)

const C := preload("res://shared/constants.gd")
const ROLE_NAMES := ["Warrior", "Healer", "Tank", "Rogue"]
const ZONE_IDS := ["forest", "canyon", "spine"]

var meta: Node               # client/meta.gd
var welcome_message := ""    # shown on arrival, e.g. a run summary
var bot_name := ""           # --townbot=Name: automate the town (register, party up, launch)
var bot_lead := false        # --lead: this bot creates the party and launches; others join it
var bot_party_size := 2      # --party-size=N: the lead launches once this many are in and ready

var _bot_busy := false
var screenshot_path := ""   # --screenshot=PATH: save the town a few seconds in, then quit
var open_building := ""     # --open=shop|inventory|party: start with that panel open (debug)
var _shot_timer := 4.0

var _db: RunnerModuleDb
var _dirty := true
var _building := ""          # which panel is open
var _launched_run_id := 0
var _chat_channel := "town"
var _chat_seen := 0

# widgets
var _status: Label
var _header: Label
var _panel: VBoxContainer
var _right: PanelContainer
var _panel_title: Label
var _online: ItemList
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _chat_channel_btn: OptionButton
var _name_dialog: PanelContainer
var _name_input: LineEdit


func _ready() -> void:
	# The town hangs under a plain Node, so size it to the viewport by hand.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fit_viewport()
	get_viewport().size_changed.connect(_fit_viewport)
	_build_ui()
	_building = open_building
	_status.text = "Connecting to town..."
	meta.connected_and_subscribed.connect(_on_meta_ready)
	meta.failed.connect(func(reason: String) -> void: _status.text = reason)
	if meta.client != null and meta.client.is_connected_db() and meta.client.db != null:
		_on_meta_ready()


func _fit_viewport() -> void:
	position = Vector2.ZERO
	size = get_viewport().get_visible_rect().size


func _on_meta_ready() -> void:
	_db = meta.client.db
	meta.client.row_inserted.connect(func(_t, _r) -> void: _dirty = true)
	meta.client.row_updated.connect(func(_t, _o, _n) -> void: _dirty = true)
	meta.client.row_deleted.connect(func(_t, _r) -> void: _dirty = true)
	if meta.me() == null and bot_name != "":
		_bot_call(meta.client.reducers.register(bot_name), "registered")
	elif meta.me() == null:
		_name_dialog.visible = true
		_status.text = "Welcome, stranger. Pick a name."
	else:
		_status.text = welcome_message if welcome_message != "" else "Welcome back, %s." % meta.me().name
	_dirty = true


func _process(delta: float) -> void:
	if _dirty and _db != null:
		_dirty = false
		_refresh()
	if screenshot_path != "":
		_shot_timer -= delta
		if _shot_timer <= 0.0:
			var path := screenshot_path
			screenshot_path = ""
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(path)
			print("[town] screenshot saved to " + path)
			get_tree().quit()


# ---------------------------------------------------------------- refresh

func _refresh() -> void:
	var me: RunnerPlayer = meta.me()
	if me == null:
		return
	var online := _db.player.find_by_online(true)
	_header.text = "%s   Gold %d   %s   Online %d" % [me.name, me.gold, ROLE_NAMES[me.role], online.size()]
	_online.clear()
	for p in online:
		var party_tag := "  [party %d]" % p.party_id if p.party_id != 0 else ""
		_online.add_item("%s (%s)%s" % [p.name, ROLE_NAMES[p.role], party_tag])
	_refresh_chat(me)
	_refresh_panel(me)
	_watch_for_run(me)
	if bot_name != "":
		_bot_step(me)


func _refresh_chat(me: RunnerPlayer) -> void:
	var channel := "town" if _chat_channel == "town" else "party:%d" % me.party_id
	var msgs := _db.chat_message.find_by_channel(channel)
	msgs.sort_custom(func(a, b) -> bool: return a.id < b.id)
	_chat_log.clear()
	for m in msgs.slice(maxi(0, msgs.size() - 40)):
		var who: String = "[color=#f0d080]%s[/color]" % m.sender_name if meta.is_me(m.sender) else m.sender_name
		_chat_log.append_text("%s: %s\n" % [who, m.text.xml_escape()])
	_chat_channel_btn.set_item_disabled(1, me.party_id == 0)


func _watch_for_run(me: RunnerPlayer) -> void:
	if me.party_id == 0:
		return
	for run in _db.run.find_by_party_id(me.party_id):
		if run.state != "ready" or run.id == _launched_run_id:
			continue
		var ticket: RunnerRunTicket = _db.run_ticket.first_where(
			func(t) -> bool: return t.run_id == run.id and meta.is_me(t.identity))
		if ticket == null:
			continue
		_launched_run_id = run.id
		_status.text = "Run %d ready on %s, joining..." % [run.id, run.address]
		run_ready.emit(run, ticket.secret)


# ---------------------------------------------------------------- panels

func _open(building: String) -> void:
	_building = "" if _building == building else building
	_dirty = true


func _refresh_panel(me: RunnerPlayer) -> void:
	for child in _panel.get_children():
		child.queue_free()
	_right.visible = _building != ""
	match _building:
		"shop": _panel_shop(me)
		"inventory": _panel_inventory(me)
		"party": _panel_party(me)
		"run": _panel_run(me)


func _panel_shop(me: RunnerPlayer) -> void:
	_panel_title.text = "Blacksmith"
	var defs := _db.item_def.iter()
	defs.sort_custom(func(a, b) -> bool: return a.id < b.id)
	for d in defs:
		var row := HBoxContainer.new()
		var stats := _item_stats(d)
		var label := _label("%s  %s" % [d.name, stats])
		row.add_child(label)
		var buy := Button.new()
		buy.text = "Buy %dg" % d.price
		buy.disabled = me.gold < d.price
		buy.pressed.connect(_do.bind(meta.client.reducers.buy_item.bind(d.id), "Bought %s" % d.name))
		row.add_child(buy)
		_panel.add_child(row)


func _panel_inventory(me: RunnerPlayer) -> void:
	_panel_title.text = "Home"
	var eq: RunnerEquipment = _db.equipment.owner.find(me.identity)
	var role_row := HBoxContainer.new()
	role_row.add_child(_label("Role"))
	var role_btn := OptionButton.new()
	for r in ROLE_NAMES:
		role_btn.add_item(r)
	role_btn.selected = me.role
	role_btn.item_selected.connect(func(i: int) -> void: _do(meta.client.reducers.set_role.bind(i), "Role set"))
	role_row.add_child(role_btn)
	_panel.add_child(role_row)
	_panel.add_child(_label("Loadout: %s" % _loadout_text(me, eq)))
	_panel.add_child(HSeparator.new())
	var items := _db.inventory_item.find_by_owner(me.identity)
	items.sort_custom(func(a, b) -> bool: return a.id < b.id)
	for it in items:
		var d: RunnerItemDef = _db.item_def.id.find(it.item_def_id)
		if d == null:
			continue
		var row := HBoxContainer.new()
		var equipped := eq != null and (eq.weapon_item == it.id or eq.armor_item == it.id)
		var label := _label("%s x%d  %s%s" % [d.name, it.quantity, _item_stats(d), "  [equipped]" if equipped else ""])
		row.add_child(label)
		if d.slot != RunnerTypes.Slot.Potion and not equipped:
			var b := Button.new()
			b.text = "Equip"
			b.pressed.connect(_do.bind(meta.client.reducers.equip.bind(it.id), "Equipped %s" % d.name))
			row.add_child(b)
		_panel.add_child(row)


func _panel_party(me: RunnerPlayer) -> void:
	_panel_title.text = "Guild Board"
	if me.party_id == 0:
		_panel.add_child(_label("You are not in a party."))
		var create_row := HBoxContainer.new()
		var zone_btn := OptionButton.new()
		for z in ZONE_IDS:
			zone_btn.add_item(Zones.get_zone(z).name)
		create_row.add_child(zone_btn)
		var create := Button.new()
		create.text = "Create party"
		create.pressed.connect(func() -> void:
			_do(meta.client.reducers.create_party.bind(ZONE_IDS[zone_btn.selected]), "Party created"))
		create_row.add_child(create)
		_panel.add_child(create_row)
		_panel.add_child(HSeparator.new())
		_panel.add_child(_label("Parties looking for members:"))
		var any := false
		for party in _db.party.iter():
			if party.state != "town":
				continue
			var members := _db.party_member.find_by_party_id(party.id)
			if members.size() >= C.PARTY_SIZE:
				continue
			any = true
			var row := HBoxContainer.new()
			var leader: RunnerPlayer = _db.player.identity.find(party.leader)
			var label := _label("%s's party  %s  %d/%d" % [leader.name if leader else "?", Zones.get_zone(party.zone).name, members.size(), C.PARTY_SIZE])
			row.add_child(label)
			var join := Button.new()
			join.text = "Join"
			join.pressed.connect(_do.bind(meta.client.reducers.join_party.bind(party.id), "Joined party"))
			row.add_child(join)
			_panel.add_child(row)
		if not any:
			_panel.add_child(_label("(none yet)"))
		return

	var party: RunnerParty = _db.party.id.find(me.party_id)
	if party == null:
		return
	var is_leader: bool = meta.is_me(party.leader)
	_panel.add_child(_label("Party %d   %s   state: %s" % [party.id, Zones.get_zone(party.zone).name, party.state]))
	var members := _db.party_member.find_by_party_id(party.id)
	var all_ready := true
	for m in members:
		var p: RunnerPlayer = _db.player.identity.find(m.identity)
		var eq: RunnerEquipment = _db.equipment.owner.find(m.identity) if p else null
		var line := "%s%s  %s  %s  %s" % [
			"* " if m.identity == party.leader else "  ", p.name if p else "?",
			ROLE_NAMES[p.role] if p else "", "READY" if m.ready else "not ready",
			_loadout_text(p, eq) if p else ""]
		_panel.add_child(_label(line))
		all_ready = all_ready and m.ready
	_panel.add_child(HSeparator.new())
	var mine: RunnerPartyMember = _db.party_member.identity.find(me.identity)
	var controls := HBoxContainer.new()
	if is_leader:
		var zone_btn := OptionButton.new()
		for z in ZONE_IDS:
			zone_btn.add_item(Zones.get_zone(z).name)
		zone_btn.selected = ZONE_IDS.find(party.zone)
		zone_btn.item_selected.connect(func(i: int) -> void:
			_do(meta.client.reducers.set_party_zone.bind(ZONE_IDS[i]), "Zone set"))
		controls.add_child(zone_btn)
		var run := Button.new()
		run.text = "RUN"
		run.disabled = not all_ready or party.state != "town" or _db.run_server.count() == 0
		run.pressed.connect(_do.bind(meta.client.reducers.launch_run, "Launching..."))
		controls.add_child(run)
		if _db.run_server.count() == 0:
			controls.add_child(_label("(no run server online)"))
	else:
		var ready := Button.new()
		ready.text = "Unready" if (mine and mine.ready) else "Ready"
		ready.pressed.connect(func() -> void:
			_do(meta.client.reducers.set_ready.bind(not mine.ready), "Ready toggled"))
		controls.add_child(ready)
	var leave := Button.new()
	leave.text = "Leave"
	leave.pressed.connect(_do.bind(meta.client.reducers.leave_party, "Left party"))
	controls.add_child(leave)
	_panel.add_child(controls)


# ---------------------------------------------------------------- bot

## One decision per refresh: get into a party, ready up, and (as lead) launch.
func _bot_step(me: RunnerPlayer) -> void:
	if _bot_busy or _launched_run_id != 0:
		return
	if me.party_id == 0:
		if bot_lead and bot_party_size <= 1:
			_bot_call(meta.client.reducers.quick_run("forest"), "picked the forest at the gate (solo)")
		elif bot_lead:
			_bot_call(meta.client.reducers.create_party("forest"), "created a party")
		else:
			for party in _db.party.iter():
				if party.state == "town" and _db.party_member.find_by_party_id(party.id).size() < C.PARTY_SIZE:
					_bot_call(meta.client.reducers.join_party(party.id), "joined party %d" % party.id)
					return
		return
	var mine: RunnerPartyMember = _db.party_member.identity.find(me.identity)
	if mine != null and not mine.ready:
		_bot_call(meta.client.reducers.set_ready(true), "ready")
		return
	var party: RunnerParty = _db.party.id.find(me.party_id)
	if party == null or not meta.is_me(party.leader) or party.state != "town":
		return
	var members := _db.party_member.find_by_party_id(party.id)
	if members.size() < bot_party_size or _db.run_server.count() == 0:
		return
	for m in members:
		if not m.ready:
			return
	_bot_call(meta.client.reducers.launch_run(), "launched the run")


func _bot_call(call: SpacetimeDBReducerCall, what: String) -> void:
	_bot_busy = true
	var err: String = await meta.invoke(call)
	_bot_busy = false
	print("[townbot %s] %s%s" % [bot_name, what, "" if err == "" else " FAILED: " + err])
	_dirty = true


## The gate: every map with what it is like, and a Run button each. Solo if you are not
## in a party; with your party if you lead it.
func _panel_run(me: RunnerPlayer) -> void:
	_panel_title.text = "Choose your run"
	var party: RunnerParty = _db.party.id.find(me.party_id) if me.party_id != 0 else null
	var members: Array = _db.party_member.find_by_party_id(me.party_id) if party else []
	var is_leader: bool = party != null and meta.is_me(party.leader)
	var blocked := ""
	if _db.run_server.count() == 0:
		blocked = "No run server is online."
	elif party != null and party.state != "town":
		blocked = "Your party is already out on a run."
	elif party != null and not is_leader:
		blocked = "Only the party leader launches. Ready up at the Guild Board."
	else:
		for m in members:
			if not m.ready:
				var who: RunnerPlayer = _db.player.identity.find(m.identity)
				blocked = "%s is not ready yet." % (who.name if who else "someone")
	if party == null:
		_panel.add_child(_label("Running solo. Form a party at the Guild Board to bring friends."))
	else:
		_panel.add_child(_label("Running with your party of %d." % members.size()))
	if blocked != "":
		var warn := _label(blocked)
		warn.modulate = Color(1.0, 0.7, 0.5)
		_panel.add_child(warn)
	_panel.add_child(HSeparator.new())
	for zone_id in ZONE_IDS:
		var z: Dictionary = Zones.get_zone(zone_id)
		var card := VBoxContainer.new()
		var head := HBoxContainer.new()
		var name_label := _label(z.name)
		name_label.add_theme_font_size_override("font_size", 18)
		head.add_child(name_label)
		var go := Button.new()
		go.text = "Run"
		go.disabled = blocked != ""
		go.pressed.connect(_do.bind(meta.client.reducers.quick_run.bind(zone_id), "Launching %s..." % z.name))
		head.add_child(go)
		card.add_child(head)
		var pace := "%.1fx" % z.speed
		if z.has("segments"):
			pace += " with %.0fx sprints" % z.segments[1].speed
		card.add_child(_label("Pace %s   See %.1f s ahead   %s every %.1f s" % [pace, z.lookahead_seconds, z.monster.name, z.spawn_seconds]))
		card.add_child(_label("%s: %d hp, %d dmg at L1, level up every %d s. Camp every %d s. Loot %d per level." % [
			z.monster.name, z.monster.hp, z.monster.damage, int(z.level_every_seconds), int(z.camp_every_seconds), z.loot_per_level]))
		_panel.add_child(card)
		_panel.add_child(HSeparator.new())


# ---------------------------------------------------------------- actions

## Calls a reducer factory, shows the outcome in the status line.
func _do(make_call: Callable, ok_text: String) -> void:
	var call: SpacetimeDBReducerCall = make_call.call()
	var err: String = await meta.invoke(call)
	_status.text = ok_text if err == "" else "Error: " + err
	_dirty = true


func _send_chat() -> void:
	var text := _chat_input.text.strip_edges()
	if text == "":
		return
	_chat_input.text = ""
	_do(meta.client.reducers.send_chat.bind(_chat_channel, text), "")


func _submit_name() -> void:
	var name := _name_input.text.strip_edges()
	var err: String = await meta.invoke(meta.client.reducers.register(name))
	if err != "":
		_status.text = "Error: " + err
		return
	_name_dialog.visible = false
	_status.text = "Welcome to town, %s. You have %d gold." % [name, 100]
	_dirty = true


# ---------------------------------------------------------------- helpers

func _item_stats(d: RunnerItemDef) -> String:
	var parts: Array[String] = []
	if d.damage != 0: parts.append("+%d dmg" % d.damage)
	if d.armor != 0: parts.append("+%d armor" % d.armor)
	if d.hp != 0: parts.append("+%d hp" % d.hp)
	if d.dodge != 0: parts.append("+%d dodge" % d.dodge)
	return " ".join(parts) if not parts.is_empty() else "(no bonus)"


func _loadout_text(p: RunnerPlayer, eq: RunnerEquipment) -> String:
	var stats: Dictionary = C.ROLE_STATS[p.role]
	var damage: int = stats.damage
	var armor := 0
	var hp: int = stats.max_hp
	var dodge: int = stats.dodge_charges
	if eq != null:
		for item_id in [eq.weapon_item, eq.armor_item]:
			var it: RunnerInventoryItem = _db.inventory_item.id.find(item_id)
			var d: RunnerItemDef = _db.item_def.id.find(it.item_def_id) if it else null
			if d:
				damage += d.damage
				armor += d.armor
				hp += d.hp
				dodge += d.dodge
	return "dmg %d  armor %d  hp %d  dodges %d" % [damage, armor, hp, dodge]


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


# ---------------------------------------------------------------- ui construction

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.1, 0.09)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	add_child(root)

	var title := Label.new()
	title.text = "EMBERFALL TOWN"
	title.add_theme_font_size_override("font_size", 26)
	title.modulate = Color(1.0, 0.85, 0.5)
	root.add_child(title)
	_header = Label.new()
	root.add_child(_header)
	_status = Label.new()
	_status.modulate = Color(0.85, 0.95, 1.0)
	root.add_child(_status)

	var middle := HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(middle)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 200
	left.add_child(_label("In town"))
	_online = ItemList.new()
	_online.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_online)
	middle.add_child(left)

	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	var buildings := HBoxContainer.new()
	buildings.alignment = BoxContainer.ALIGNMENT_CENTER
	for b in [["Blacksmith", "shop", Color(0.75, 0.45, 0.25)], ["Home", "inventory", Color(0.35, 0.6, 0.85)], ["Guild Board", "party", Color(0.45, 0.75, 0.4)], ["RUN", "run", Color(0.95, 0.3, 0.25)]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.custom_minimum_size = Vector2(140, 110)
		btn.modulate = b[2]
		btn.pressed.connect(_open.bind(b[1]))
		buildings.add_child(btn)
	center.add_child(buildings)
	var hint := Label.new()
	hint.text = "Buy gear at the Blacksmith, equip it at Home, party up at the Guild Board (or not), then pick a map at RUN."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.custom_minimum_size.x = 300
	center.add_child(hint)
	middle.add_child(center)

	var right := PanelContainer.new()
	_right = right
	right.custom_minimum_size.x = 400
	right.size_flags_horizontal = Control.SIZE_SHRINK_END
	right.visible = false
	var right_box := VBoxContainer.new()
	_panel_title = Label.new()
	_panel_title.add_theme_font_size_override("font_size", 20)
	right_box.add_child(_panel_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel = VBoxContainer.new()
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_panel)
	right_box.add_child(scroll)
	right.add_child(right_box)
	middle.add_child(right)

	var chat := VBoxContainer.new()
	chat.custom_minimum_size.y = 170
	var chat_top := HBoxContainer.new()
	_chat_channel_btn = OptionButton.new()
	_chat_channel_btn.add_item("Town")
	_chat_channel_btn.add_item("Party")
	_chat_channel_btn.item_selected.connect(func(i: int) -> void:
		_chat_channel = "town" if i == 0 else "party"
		_dirty = true)
	chat_top.add_child(_chat_channel_btn)
	chat_top.add_child(_label("chat"))
	chat.add_child(chat_top)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat.add_child(_chat_log)
	var chat_row := HBoxContainer.new()
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Say something..."
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.text_submitted.connect(func(_t: String) -> void: _send_chat())
	chat_row.add_child(_chat_input)
	var send := Button.new()
	send.text = "Send"
	send.pressed.connect(_send_chat)
	chat_row.add_child(send)
	chat.add_child(chat_row)
	root.add_child(chat)

	# Name dialog (first visit)
	_name_dialog = PanelContainer.new()
	_name_dialog.set_anchors_preset(Control.PRESET_CENTER)
	_name_dialog.visible = false
	var nd := VBoxContainer.new()
	nd.add_child(_label("Choose your name (2-16 characters)"))
	_name_input = LineEdit.new()
	_name_input.custom_minimum_size.x = 260
	_name_input.text_submitted.connect(func(_t: String) -> void: _submit_name())
	nd.add_child(_name_input)
	var ok := Button.new()
	ok.text = "Enter town"
	ok.pressed.connect(_submit_name)
	nd.add_child(ok)
	_name_dialog.add_child(nd)
	add_child(_name_dialog)
