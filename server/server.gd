extends Node
## Dedicated run server. Owns every PartySim, ticks them at a fixed rate,
## validates inputs, and broadcasts snapshots to party members.
##
## Two modes:
##   offline (no --stdb): anyone joins with a role and zone; nothing persists. Good for tests.
##   meta (--stdb=URL): registers with the SpacetimeDB meta server, picks up runs assigned to
##   it, admits players by run ticket, builds loadouts from run_member rows, and commits the
##   result when the run is over. Loot only becomes gold through commit_run.

const C := preload("res://shared/constants.gd")
const MetaScript := preload("res://client/meta.gd")
const HEARTBEAT_SECONDS := 5.0

var speed_override := 0.0          # --speed=N: force this pace on every party (0 = use the zone's)
var stdb_url := ""                 # --stdb=http://host:3000; empty = offline mode
var stdb_secret := "dev-run-server-secret"
var public_address := "127.0.0.1:%d" % C.PORT   # --address=host:port players connect to

# party_id -> { sim, members: [peer_id], run_id, identities: {peer_id: bytes}, left: {hex: RunnerRunResult},
#               had_members, committed }
var parties := {}
var peer_party := {}         # peer_id -> party_id
var _inputs_this_tick := {}  # peer_id -> int, reset every tick (rate limit)
var _next_party_id := 1
var _meta: Node
var _heartbeat := 0.0
var _claimed := {}           # run_id -> party_id

@onready var net: Node = get_node("../Net")


func _ready() -> void:
	Engine.max_fps = C.TICK_RATE * 2  # headless would otherwise spin a core at 100%
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(C.PORT, C.MAX_PEERS)
	if err != OK:
		push_error("Server failed to bind UDP %d: %s" % [C.PORT, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	net.join_requested.connect(_on_join_requested)
	net.input_received.connect(_on_input_received)
	print("[server] listening on UDP %d, tick %d Hz%s" % [C.PORT, C.TICK_RATE,
		"" if speed_override <= 0.0 else ", speed forced to %.1fx" % speed_override])
	if stdb_url != "":
		_meta = MetaScript.new()
		_meta.name = "Meta"
		_meta.url = stdb_url
		_meta.token_path = "user://run_server_token.dat"  # not the player's identity, even on one machine
		_meta.connected_and_subscribed.connect(_on_meta_ready)
		_meta.failed.connect(func(reason: String) -> void: printerr("[server] meta: " + reason))
		add_child(_meta)
		_meta.start(PackedStringArray(["SELECT * FROM run", "SELECT * FROM run_member", "SELECT * FROM run_ticket"]))
	else:
		print("[server] offline mode: joins by role and zone, nothing persists")


# ---------------------------------------------------------------- meta server

func _on_meta_ready() -> void:
	var err: String = await _meta.invoke(_meta.client.reducers.server_register(stdb_secret, public_address))
	if err != "":
		printerr("[server] registration refused: " + err)
		return
	print("[server] registered with meta server as %s, address %s" % [_meta.identity.hex_encode().substr(0, 12), public_address])
	_meta.client.db.run.on_insert(_on_run_row)
	_meta.client.db.run.on_update(func(_old: RunnerRun, new_row: RunnerRun) -> void: _on_run_row(new_row))
	for run in _meta.client.db.run.iter():
		_on_run_row(run)


## A run assigned to us is waiting: build its party and claim it.
func _on_run_row(run: RunnerRun) -> void:
	if run.state != "requested" or run.server != _meta.identity or _claimed.has(run.id):
		return
	var party_id := _create_party(run.zone, run.seed)
	var party: Dictionary = parties[party_id]
	party.run_id = run.id
	_claimed[run.id] = party_id
	print("[server] run %d assigned: party %d in %s (seed %d)" % [run.id, party_id, run.zone, run.seed])
	var err: String = await _meta.invoke(_meta.client.reducers.server_claim_run(run.id, public_address))
	if err != "":
		printerr("[server] could not claim run %d: %s" % [run.id, err])
		parties.erase(party_id)
		_claimed.erase(run.id)


## Everyone is dead, extracted, or gone: make the loot real and send the party home.
func _commit_run(party_id: int) -> void:
	var party: Dictionary = parties[party_id]
	party.committed = true
	var sim: PartySim = party.sim
	var results: Array[RunnerRunResult] = []
	var summaries := {}  # peer_id -> summary for finish_run
	for peer_id in party.identities:
		var p: Dictionary = sim.players.get(peer_id, {})
		if p.is_empty():
			continue
		var extracted: bool = p.extracted
		results.append(RunnerRunResult.create(party.identities[peer_id], p.loot, extracted, not extracted))
		summaries[peer_id] = { "outcome": "extracted" if extracted else "died", "loot": p.loot }
	for hex in party.left:
		results.append(party.left[hex])
	var err: String = await _meta.invoke(_meta.client.reducers.commit_run(party.run_id, results))
	if err != "":
		printerr("[server] commit_run %d failed: %s" % [party.run_id, err])
	else:
		print("[server] run %d committed (%d results)" % [party.run_id, results.size()])
	for peer_id in summaries:
		net.finish_run.rpc_id(peer_id, summaries[peer_id])
	for peer_id in party.members.duplicate():
		peer_party.erase(peer_id)
	parties.erase(party_id)


func _run_is_over(party: Dictionary) -> bool:
	if party.run_id == 0 or party.committed or not party.had_members:
		return false
	for p in party.sim.players.values():
		if p.alive:
			return false
	return true


# ---------------------------------------------------------------- tick

func _physics_process(delta: float) -> void:
	_inputs_this_tick.clear()
	var finished: Array = []
	var to_commit: Array = []
	for party_id in parties:
		var party: Dictionary = parties[party_id]
		var sim: PartySim = party.sim
		sim.step(delta)
		if sim.tick % C.SNAPSHOT_EVERY_TICKS == 0:
			var snap := sim.to_snapshot()
			for member in party.members:
				net.receive_snapshot.rpc_id(member, snap)
			sim.events.clear()  # events accumulate between snapshots, then go out once
		if _run_is_over(party):
			to_commit.append(party_id)
		elif party.run_id == 0 and sim.is_empty():
			finished.append(party_id)
	for party_id in finished:
		parties.erase(party_id)
		print("[server] party %d closed" % party_id)
	for party_id in to_commit:
		_commit_run(party_id)
	if _meta != null and _meta.client != null and _meta.client.is_connected_db():
		_heartbeat += delta
		if _heartbeat >= HEARTBEAT_SECONDS:
			_heartbeat = 0.0
			_meta.client.reducers.server_heartbeat(parties.size())


# ---------------------------------------------------------------- peers

func _on_peer_connected(peer_id: int) -> void:
	print("[server] peer %d connected" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("[server] peer %d disconnected" % peer_id)
	_leave_party(peer_id)


func _on_join_requested(peer_id: int, role: int, zone_id: String, run_id: int, secret: String) -> void:
	if peer_party.has(peer_id):
		return  # already in; ignore duplicate joins
	if run_id > 0:
		_join_by_ticket(peer_id, run_id, secret)
		return
	if role < 0 or role >= C.Role.size():
		net.reject.rpc_id(peer_id, "invalid role")
		return
	if not Zones.is_valid(zone_id):
		net.reject.rpc_id(peer_id, "unknown zone: " + zone_id)
		return
	var party_id := _find_or_create_party(zone_id)
	var party: Dictionary = parties[party_id]
	party.members.append(peer_id)
	party.had_members = true
	party.sim.add_player(peer_id, role)
	peer_party[peer_id] = party_id
	net.welcome.rpc_id(peer_id, party_id, party.sim.seed, party.sim.tick, zone_id)
	print("[server] peer %d joined party %d (%s) as %s (%d/%d)" % [
		peer_id, party_id, zone_id, C.ROLE_STATS[role].name, party.members.size(), C.PARTY_SIZE])


## Meta mode admission: the secret must match a run_ticket for this run, and the loadout
## comes from the run_member row the meta server wrote. Nothing is taken from the client.
func _join_by_ticket(peer_id: int, run_id: int, secret: String) -> void:
	if _meta == null:
		net.reject.rpc_id(peer_id, "this server has no meta connection")
		return
	if not _claimed.has(run_id) or not parties.has(_claimed[run_id]):
		net.reject.rpc_id(peer_id, "unknown run")
		return
	var db: RunnerModuleDb = _meta.client.db
	var ticket: RunnerRunTicket = db.run_ticket.first_where(
		func(t: RunnerRunTicket) -> bool: return t.run_id == run_id and t.secret == secret)
	if ticket == null:
		net.reject.rpc_id(peer_id, "bad ticket")
		return
	var member: RunnerRunMember = db.run_member.first_where(
		func(m: RunnerRunMember) -> bool: return m.run_id == run_id and m.identity == ticket.identity)
	if member == null:
		net.reject.rpc_id(peer_id, "not a member of this run")
		return
	var party_id: int = _claimed[run_id]
	var party: Dictionary = parties[party_id]
	if party.identities.values().has(ticket.identity):
		net.reject.rpc_id(peer_id, "already joined")
		return
	party.members.append(peer_id)
	party.had_members = true
	party.identities[peer_id] = ticket.identity
	party.sim.add_player(peer_id, member.role, {
		"damage": member.damage, "armor": member.armor, "max_hp": member.max_hp, "dodge_charges": member.dodge_charges,
	})
	peer_party[peer_id] = party_id
	net.welcome.rpc_id(peer_id, party_id, party.sim.seed, party.sim.tick, party.sim.zone_id)
	print("[server] %s joined run %d as %s (dmg %d, armor %d, hp %d)" % [
		member.name, run_id, C.ROLE_STATS[member.role].name, member.damage, member.armor, member.max_hp])


func _on_input_received(peer_id: int, input: int, client_tick: int) -> void:
	if not peer_party.has(peer_id):
		return
	if input <= C.Action.NONE or input >= C.Action.size():
		return
	var count: int = _inputs_this_tick.get(peer_id, 0)
	if count >= C.MAX_INPUTS_PER_TICK:
		return  # flooding; drop silently
	_inputs_this_tick[peer_id] = count + 1
	var sim: PartySim = parties[peer_party[peer_id]].sim
	sim.apply_input(peer_id, input, client_tick)


# ---------------------------------------------------------------- parties

func _find_or_create_party(zone_id: String) -> int:
	for party_id in parties:
		var party: Dictionary = parties[party_id]
		if party.run_id == 0 and party.sim.zone_id == zone_id and party.members.size() < C.PARTY_SIZE:
			return party_id
	return _create_party(zone_id, 0)


func _create_party(zone_id: String, seed: int) -> int:
	var party_id := _next_party_id
	_next_party_id += 1
	var sim := PartySim.new(zone_id, seed)
	if speed_override > 0.0:
		# Forced pace for testing: pin the zone speed and drop its segments.
		sim.zone = sim.zone.duplicate(true)
		sim.zone.erase("segments")
		sim.zone.speed = speed_override
		sim.set_speed_multiplier(speed_override, true)
	parties[party_id] = {
		"sim": sim, "members": [], "run_id": 0, "identities": {}, "left": {},
		"had_members": false, "committed": false,
	}
	print("[server] party %d created in %s (seed %d)" % [party_id, zone_id, sim.seed])
	return party_id


func _leave_party(peer_id: int) -> void:
	if not peer_party.has(peer_id):
		return
	var party_id: int = peer_party[peer_id]
	peer_party.erase(peer_id)
	if not parties.has(party_id):
		return
	var party: Dictionary = parties[party_id]
	if party.identities.has(peer_id):
		# Leaving mid-run counts as dying, unless they had already extracted. Banked loot stays.
		var p: Dictionary = party.sim.players.get(peer_id, {})
		var identity: PackedByteArray = party.identities[peer_id]
		if not p.is_empty():
			party.left[identity.hex_encode()] = RunnerRunResult.create(identity, p.loot, p.extracted, not p.extracted)
		party.identities.erase(peer_id)
	party.members.erase(peer_id)
	party.sim.remove_player(peer_id)
