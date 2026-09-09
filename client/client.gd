extends Node
## Client: connects, sends discrete inputs, receives snapshots, drives the World renderer.
## Nothing here decides game state. The server does.

const C := preload("res://shared/constants.gd")
const WorldScript := preload("res://client/world.gd")
const HudScript := preload("res://client/hud.gd")

signal finished(summary: Dictionary)

var host := "127.0.0.1"
var port: int = C.PORT
var role: int = C.Role.WARRIOR
var zone_id: String = Zones.DEFAULT_ZONE
var run_id := 0          # meta mode: the run to join, with its ticket secret
var secret := ""
var bot := false            # --bot: send random inputs, print events. For headless tests / load testing.
var screenshot_path := ""   # --screenshot=PATH: save a frame a few seconds after joining, then quit.
var _bot_timer := 0.0
var _screenshot_timer := 3.0

var party_id := -1
var latest_snapshot := {}
var snapshot_age := 0.0     # seconds since latest_snapshot arrived
var _client_tick := 0

var world: Node3D
var hud: CanvasLayer

# What this run was, for the end screen.
var _stats := { "kills": 0, "hits": 0, "earned": 0, "lost": 0, "avoided": 0 }
var _end_shown := false
var _run_committed := false
var _last_summary := {}
var screenshot_on_end := false  # --screenshot-end: capture the end screen instead of the run
var demo_action := ""           # --demo=jump|slide|ability: send it 0.4 s before the screenshot (debug)
var _net_timer := 0.0
var _demo_sent := false

@onready var net: Node = get_node("../Net")


func _ready() -> void:
	hud = HudScript.new()
	add_child(hud)
	hud.set_status("Connecting to %s:%d ..." % [host, port])

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		hud.set_status("Failed to create client: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func() -> void: hud.set_status("Connection failed"))
	multiplayer.server_disconnected.connect(func() -> void: hud.set_status("Server disconnected"))
	net.welcomed.connect(_on_welcomed)
	net.rejected.connect(func(reason: String) -> void: hud.set_status("Rejected: " + reason))
	net.snapshot_received.connect(_on_snapshot)
	net.run_over.connect(_on_run_over)
	hud.back_to_town.connect(func() -> void: finished.emit(_last_summary))


func _on_connected() -> void:
	hud.set_status("Connected, joining as %s ..." % C.ROLE_STATS[role].name)
	net.request_join.rpc_id(1, role, zone_id, run_id, secret)


func _on_welcomed(p_party_id: int, seed: int, _server_tick: int, p_zone_id: String) -> void:
	party_id = p_party_id
	zone_id = p_zone_id
	hud.set_status("")
	hud.zone = Zones.get_zone(zone_id)
	world = WorldScript.new()
	world.local_peer_id = multiplayer.get_unique_id()
	world.zone = hud.zone
	add_child(world)
	print("[client] joined party %d in %s (seed %d) as peer %d" % [party_id, zone_id, seed, world.local_peer_id])


func _on_snapshot(wire: Dictionary) -> void:
	# Drop out-of-order packets: unreliable channel can reorder.
	if not latest_snapshot.is_empty() and wire.t <= latest_snapshot.tick:
		return
	var snapshot := PartySim.decode_snapshot(wire)
	if latest_snapshot.is_empty():
		print("[client] first snapshot: tick %d, %d players, %d monsters" % [
			snapshot.tick, snapshot.players.size(), snapshot.monsters.size()])
	latest_snapshot = snapshot
	snapshot_age = 0.0
	if world:
		world.speed = snapshot.speed
		world.lookahead_seconds = snapshot.lookahead_seconds
	_track_stats(snapshot)
	_check_for_end(snapshot)
	if bot:
		for ev in snapshot.events:
			print("[client %d] tick %d %s" % [multiplayer.get_unique_id(), snapshot.tick, ev])
	if world:
		world.apply_snapshot(snapshot)
	hud.apply_snapshot(snapshot, multiplayer.get_unique_id())


func _on_run_over(summary: Dictionary) -> void:
	_run_committed = true
	_last_summary = summary
	hud.mark_run_committed()
	if bot or not _end_shown:
		# Bots (and the odd case of a commit before we saw our own death) go straight back.
		if not _end_shown and not latest_snapshot.is_empty():
			_check_for_end(latest_snapshot)
		if bot:
			finished.emit(summary)


func _track_stats(snapshot: Dictionary) -> void:
	var me := multiplayer.get_unique_id()
	for ev in snapshot.events:
		if ev.get("peer", -1) != me:
			continue
		match ev.type:
			"kill": _stats.kills += 1
			"hit": _stats.hits += 1
			"loot": _stats.earned += ev.amount
			"avoided": _stats.avoided += 1
			"death": _stats.lost = ev.lost


## The moment our own player is no longer alive, put up the card. Loot becomes real when
## the server commits the whole run, which for a solo run is right away.
func _check_for_end(snapshot: Dictionary) -> void:
	if _end_shown:
		return
	var me := multiplayer.get_unique_id()
	if not snapshot.players.has(me):
		return
	var p: Dictionary = snapshot.players[me]
	if p.alive:
		return
	_end_shown = true
	var zone_name: String = Zones.get_zone(zone_id).name
	var seconds: int = int(snapshot.tick / float(C.TICK_RATE))
	var level: int = 1 + int(floor(seconds / Zones.get_zone(zone_id).level_every_seconds))
	var where := "%s, %d m in, %d:%02d on the clock" % [zone_name, int(snapshot.distance), seconds / 60, seconds % 60]
	var lines: Array[String] = []
	if p.extracted:
		_last_summary = { "outcome": "extracted", "loot": p.loot }
		lines.append("You made it out of " + where + ".")
		lines.append("")
		lines.append("Loot banked this run: %d" % p.loot)
	else:
		_last_summary = { "outcome": "died", "loot": p.loot }
		lines.append("You fell in " + where + ".")
		lines.append("")
		lines.append("Loot lost (unbanked): %d" % _stats.lost)
		lines.append("Loot kept (banked at camps): %d" % p.loot)
	lines.append("Kills: %d   Hits landed: %d   Jumped or slid past: %d" % [_stats.kills, _stats.hits, _stats.avoided])
	lines.append("Monster level reached: %d" % level)
	hud.show_end_screen("extracted" if p.extracted else "defeat", lines)
	if _run_committed:
		hud.mark_run_committed()
	if screenshot_on_end and screenshot_path != "":
		_screenshot_timer = 0.5  # let the card draw, then the existing hook captures it


func _physics_process(_delta: float) -> void:
	_client_tick += 1


func _process(delta: float) -> void:
	snapshot_age += delta
	if party_id < 0:
		return
	_net_timer += delta
	if _net_timer >= 0.5:
		_net_timer = 0.0
		_report_net_stats()
	if bot:
		_bot_tick(delta)
	else:
		_poll_input()
	if screenshot_path != "" and (not screenshot_on_end or _end_shown):
		_screenshot_timer -= delta
		if demo_action != "" and not _demo_sent and _screenshot_timer <= 0.4:
			_demo_sent = true
			match demo_action:
				"jump": _send(C.Action.JUMP)
				"slide": _send(C.Action.SLIDE)
				"ability": _send(C.Action.ABILITY)
		if _screenshot_timer <= 0.0:
			var path := screenshot_path
			screenshot_path = ""
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(path)
			print("[client] screenshot saved to %s" % path)
			get_tree().quit()
	if world and not latest_snapshot.is_empty():
		# Extrapolate forward motion between snapshots; the server speed is constant so this is cheap.
		var target: float = latest_snapshot.distance + latest_snapshot.speed * snapshot_age
		world.render_distance = lerpf(world.render_distance, target, minf(1.0, delta * 15.0))


## ENet keeps round-trip and loss estimates per peer; peer 1 is the server.
func _report_net_stats() -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var server := enet.get_peer(1)
	if server == null:
		return
	var rtt: float = server.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
	var loss: float = server.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / float(ENetPacketPeer.PACKET_LOSS_SCALE) * 100.0
	hud.set_net_stats(rtt, loss, snapshot_age * 1000.0, "%s:%d" % [host, port])


func _poll_input() -> void:
	if Input.is_action_just_pressed("lane_left"):
		_send(C.Action.LANE_LEFT)
	if Input.is_action_just_pressed("lane_right"):
		_send(C.Action.LANE_RIGHT)
	if Input.is_action_just_pressed("jump"):
		_send(C.Action.JUMP)
	if Input.is_action_just_pressed("slide"):
		_send(C.Action.SLIDE)
	if Input.is_action_just_pressed("ability"):
		_send(C.Action.ABILITY)
	if Input.is_action_just_pressed("extract"):
		_send(C.Action.EXTRACT)


func _bot_tick(delta: float) -> void:
	_bot_timer -= delta
	if _bot_timer > 0.0:
		return
	_bot_timer = randf_range(0.2, 0.6)
	if not latest_snapshot.is_empty() and latest_snapshot.at_camp:
		_send(C.Action.EXTRACT)  # bots bank and leave at the first camp
		return
	# Cautious bot: mostly hops and slides, uses the ability when it can, rarely changes lane.
	var roll := randf()
	if roll < 0.15:
		_send(randi_range(C.Action.LANE_LEFT, C.Action.LANE_RIGHT))
	elif roll < 0.4:
		_send(C.Action.ABILITY)
	else:
		_send(randi_range(C.Action.JUMP, C.Action.SLIDE))


func _send(input: int) -> void:
	net.send_input.rpc_id(1, input, _client_tick)
