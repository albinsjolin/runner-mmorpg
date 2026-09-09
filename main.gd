extends Node
## Entry point. Same binary, two modes:
##   godot --headless --server           dedicated server
##   godot --headless -- --server --speed=3     server forcing every party to 3x pace
##   godot -- --zone=canyon --host=IP       direct client (no town) joining a zone on an offline server
##   godot                                  town: connects to SpacetimeDB (--stdb=http://127.0.0.1:3000)
##   godot -- --profile=alice               separate identity file per profile (several clients, one machine)
##   godot --headless -- --townbot=Bob --lead --party-size=2 --bot
##                                          headless town bot: registers, parties up, launches, runs, quits
##   godot --headless -- --server --stdb=http://127.0.0.1:3000 --address=1.2.3.4:7777
##                                          run server registered with the meta server
##   godot                               client (connects to --host=IP, default 127.0.0.1)
##   godot --host=1.2.3.4 --role=2       client picking a role (0 Warrior, 1 Healer, 2 Tank, 3 Rogue)
##   godot --headless -- --bot           headless client that spams random inputs (testing / load)
##   godot -- --screenshot=C:/x.png      client saves a frame ~3 s after joining, then quits

const ServerScript := preload("res://server/server.gd")
const ClientScript := preload("res://client/client.gd")
const TownScript := preload("res://client/town.gd")
const MetaScript := preload("res://client/meta.gd")

var _meta: Node
var _args := {}


func _ready() -> void:
	var args := _parse_args()
	_args = args
	if args.has("server"):
		var server: Node = ServerScript.new()
		server.name = "Server"
		server.speed_override = float(args.get("speed", "0"))
		server.stdb_url = str(args.get("stdb", ""))
		server.stdb_secret = str(args.get("stdb-secret", "dev-run-server-secret"))
		server.public_address = str(args.get("address", "127.0.0.1:%d" % Constants.PORT))
		add_child(server)
	elif args.has("host"):
		# Direct run, no town: for offline testing against a server started without --stdb.
		var hp := str(args.get("host")).split(":")
		var client: Node = _make_client(hp[0], int(hp[1]) if hp.size() > 1 else Constants.PORT)
		client.role = int(args.get("role", str(randi() % Constants.Role.size())))
		client.zone_id = str(args.get("zone", Zones.DEFAULT_ZONE))
		add_child(client)
	else:
		_meta = MetaScript.new()
		_meta.name = "Meta"
		_meta.url = str(args.get("stdb", "http://127.0.0.1:3000"))
		# One identity per profile, so several clients on one machine are different players.
		var profile := str(args.get("profile", args.get("townbot", "default")))
		_meta.token_path = "user://player_token_%s.dat" % profile
		add_child(_meta)
		_meta.start(PackedStringArray([
			"SELECT * FROM player", "SELECT * FROM item_def", "SELECT * FROM inventory_item",
			"SELECT * FROM equipment", "SELECT * FROM party", "SELECT * FROM party_member",
			"SELECT * FROM chat_message", "SELECT * FROM run", "SELECT * FROM run_ticket",
			"SELECT * FROM run_server",
		]))
		_enter_town("")


func _make_client(host: String, port: int) -> Node:
	var client: Node = ClientScript.new()
	client.name = "Client"
	client.host = host
	client.port = port
	client.bot = _args.has("bot")
	client.screenshot_path = str(_args.get("screenshot", ""))
	client.screenshot_on_end = _args.has("screenshot-end")
	client.demo_action = str(_args.get("demo", ""))
	return client


func _enter_town(message: String) -> void:
	var town: Node = TownScript.new()
	town.name = "Town"
	town.meta = _meta
	town.welcome_message = message
	town.bot_name = str(_args.get("townbot", ""))
	town.bot_lead = _args.has("lead")
	town.bot_party_size = int(_args.get("party-size", "2"))
	town.screenshot_path = str(_args.get("screenshot", ""))
	town.open_building = str(_args.get("open", ""))
	town.run_ready.connect(_start_run)
	add_child(town)


func _start_run(run: RunnerRun, secret: String) -> void:
	var town := get_node_or_null("Town")
	if town:
		town.queue_free()
	var parts := run.address.split(":")
	var client: Node = _make_client(parts[0], int(parts[1]) if parts.size() > 1 else Constants.PORT)
	client.run_id = run.id
	client.secret = secret
	client.zone_id = run.zone
	client.finished.connect(_end_run)
	add_child(client)


func _end_run(summary: Dictionary) -> void:
	var client := get_node_or_null("Client")
	if client:
		client.queue_free()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var text := "Run over: %s with %d loot banked." % [summary.get("outcome", "?"), summary.get("loot", 0)]
	print("[client] " + text)
	if _args.has("townbot"):
		get_tree().quit()  # headless end-to-end test: one run, then out
		return
	_enter_town(text)


## Turns ["--server", "--host=1.2.3.4"] into {"server": true, "host": "1.2.3.4"}.
func _parse_args() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if not arg.begins_with("--"):
			continue
		var kv := arg.trim_prefix("--").split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else true
	return out
