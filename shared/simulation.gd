class_name PartySim
extends RefCounted
## Authoritative simulation for one party running one zone. Pure data + logic, no nodes.
## The server owns the real instance. Clients only read snapshots from it,
## but because this file is shared they can run it locally later for prediction.

const C := preload("res://shared/constants.gd")
const Z := preload("res://shared/zones.gd")

var zone_id := ""
var zone := {}
var tick := 0
var distance := 0.0
var speed := C.BASE_SPEED         # current metres per second
var target_speed := C.BASE_SPEED  # what speed eases toward (zone segment sets this)
var lookahead_seconds := 6.0      # client-side visibility budget, from zone / segment
var seed := 0
var players := {}       # peer_id -> Dictionary (see add_player)
var monsters := {}      # id -> Dictionary (see _spawn_monster)
var obstacles := {}     # id -> Dictionary (see _spawn_obstacle)
var camps := {}         # id -> Dictionary (see _spawn_camp)
var events: Array = []  # {type, ...} feedback for clients. Owner clears after each snapshot.

var _rng := RandomNumberGenerator.new()
var _next_spawn_time := C.FIRST_SPAWN_SECONDS   # run-seconds at which the party meets the next spawn
var _next_camp_time := 0.0
var _next_id := 1
var _spawn_weight_total := 0


func _init(p_zone_id: String = Z.DEFAULT_ZONE, p_seed: int = 0) -> void:
	zone_id = p_zone_id if Z.is_valid(p_zone_id) else Z.DEFAULT_ZONE
	zone = Z.get_zone(zone_id)
	seed = p_seed if p_seed != 0 else randi()
	_rng.seed = seed
	for entry in zone.spawn_table:
		_spawn_weight_total += entry.weight
	_next_camp_time = zone.camp_every_seconds
	lookahead_seconds = zone.lookahead_seconds
	set_speed_multiplier(zone.speed, true)
	_apply_segment()


# ---------------------------------------------------------------- speed & time

## Seconds the party has been running. Depth is measured in time so it holds at any pace.
func run_seconds() -> float:
	return tick / float(C.TICK_RATE)


## Set the pace: 1.0 is BASE_SPEED. Eases in over a moment unless `instant`.
func set_speed_multiplier(multiplier: float, instant: bool = false) -> void:
	target_speed = C.BASE_SPEED * maxf(0.1, multiplier)
	if instant:
		speed = target_speed


func speed_multiplier() -> float:
	return speed / C.BASE_SPEED


# Distances that are really time budgets, at the current speed.
func hit_radius() -> float:
	return speed * (C.HIT_WINDOW_TICKS / float(C.TICK_RATE)) / 2.0

func knockback_distance() -> float:
	return speed * zone.spawn_seconds

func spawn_interval() -> float:
	return speed * zone.spawn_seconds

func ability_range() -> float:
	return speed * C.ABILITY_SECONDS


## Monster level the track is producing at the current depth.
func current_level() -> int:
	return 1 + int(floor(run_seconds() / zone.level_every_seconds))


## Are we in the quiet stretch just past a camp, where extraction is allowed?
func at_camp() -> bool:
	for camp in camps.values():
		if camp.reached and run_seconds() < camp.leave_until:
			return true
	return false


func _apply_segment() -> void:
	var seg := Z.segment_at(zone, run_seconds())
	if seg.is_empty():
		return
	set_speed_multiplier(seg.speed)
	lookahead_seconds = seg.get("lookahead_seconds", zone.lookahead_seconds)


# ---------------------------------------------------------------- players

## `loadout` overrides the role base: {damage, armor, max_hp, dodge_charges}. The meta
## server computes it from equipped gear; offline runs use the role base alone.
func add_player(peer_id: int, role: int, loadout: Dictionary = {}) -> void:
	role = clampi(role, 0, C.Role.size() - 1)
	var stats: Dictionary = C.ROLE_STATS[role]
	var max_hp: int = loadout.get("max_hp", stats.max_hp)
	var max_dodge: int = loadout.get("dodge_charges", stats.dodge_charges)
	players[peer_id] = {
		"role": role,
		"lane": C.LANE_COUNT / 2,
		"hp": max_hp,
		"max_hp": max_hp,
		"damage": loadout.get("damage", stats.damage),
		"armor": loadout.get("armor", 0),
		"max_dodge": max_dodge,
		"shield": 0,
		"dodge_charges": max_dodge,
		"dodge_recharge_ticks": 0,
		"jump_ticks": 0,
		"slide_ticks": 0,
		"ability_cd_ticks": 0,
		"alive": true,
		"loot": 0,        # banked at camps, kept on death
		"unbanked": 0,    # earned since the last camp, lost on death
		"extracted": false,
	}


func remove_player(peer_id: int) -> void:
	players.erase(peer_id)


func is_empty() -> bool:
	return players.is_empty()


# ---------------------------------------------------------------- inputs

## Called by the server for every validated input. Never trusts the caller beyond peer_id.
func apply_input(peer_id: int, input: int, _client_tick: int) -> void:
	if not players.has(peer_id):
		return
	var p: Dictionary = players[peer_id]
	if not p.alive:
		return
	match input:
		C.Action.LANE_LEFT:
			_switch_lane(peer_id, p, -1)
		C.Action.LANE_RIGHT:
			_switch_lane(peer_id, p, 1)
		C.Action.JUMP:
			if p.jump_ticks == 0 and p.slide_ticks == 0:
				p.jump_ticks = C.JUMP_DURATION_TICKS
		C.Action.SLIDE:
			if p.jump_ticks == 0 and p.slide_ticks == 0:
				p.slide_ticks = C.SLIDE_DURATION_TICKS
		C.Action.ABILITY:
			if p.ability_cd_ticks == 0:
				p.ability_cd_ticks = C.seconds_to_ticks(C.ROLE_STATS[p.role].ability_cd)
				_use_ability(peer_id, p)
		C.Action.EXTRACT:
			_extract(peer_id, p)


## Dodging is switching lanes. Costs a charge when LANE_SWITCH_USES_DODGE.
func _switch_lane(peer_id: int, p: Dictionary, dir: int) -> void:
	var target: int = clampi(p.lane + dir, 0, C.LANE_COUNT - 1)
	if target == p.lane:
		return
	if C.LANE_SWITCH_USES_DODGE:
		if p.dodge_charges <= 0:
			events.append({ "type": "no_dodge", "peer": peer_id })
			return
		p.dodge_charges -= 1
	p.lane = target
	events.append({ "type": "dodge", "peer": peer_id, "lane": target })


## Leave the run with everything banked. Only allowed in the window after a camp.
func _extract(peer_id: int, p: Dictionary) -> void:
	if not at_camp():
		events.append({ "type": "no_extract", "peer": peer_id })
		return
	p.loot += p.unbanked
	p.unbanked = 0
	p.extracted = true
	p.alive = false
	events.append({ "type": "extracted", "peer": peer_id, "loot": p.loot })


func _use_ability(peer_id: int, p: Dictionary) -> void:
	match p.role:
		C.Role.WARRIOR:
			# Cleave: hit the nearest monster in every lane.
			for lane in C.LANE_COUNT:
				var t := _nearest_monster_in_lane(lane)
				if not t.is_empty():
					_damage_monster(t, 25, peer_id)
		C.Role.HEALER:
			# Heal the party member with the lowest hp.
			var lowest := {}
			for other in players.values():
				if other.alive and (lowest.is_empty() or other.hp < lowest.hp):
					lowest = other
			if not lowest.is_empty():
				lowest.hp = mini(lowest.hp + 40, lowest.max_hp)
				events.append({ "type": "heal", "peer": peer_id, "amount": 40 })
		C.Role.TANK:
			# Shield wall: absorb damage for everyone.
			for other in players.values():
				other.shield = 30
			events.append({ "type": "shield", "peer": peer_id })
		C.Role.ROGUE:
			# Refill dodges.
			p.dodge_charges = p.max_dodge
			events.append({ "type": "refresh", "peer": peer_id })


func _nearest_monster_in_lane(lane: int) -> Dictionary:
	var best := {}
	for m in monsters.values():
		if not m.alive or m.lane != lane:
			continue
		var ahead: float = m.distance - distance
		if ahead < -hit_radius() or ahead > ability_range():
			continue
		if best.is_empty() or m.distance < best.distance:
			best = m
	return best


# ---------------------------------------------------------------- tick

func step(dt: float) -> void:
	tick += 1
	_apply_segment()
	speed = move_toward(speed, target_speed, C.SPEED_RAMP * dt)
	distance += speed * dt
	_spawn_ahead()
	_tick_players()
	_reach_camps()
	_resolve_collisions()
	_cull()


func _tick_players() -> void:
	for peer_id in players:
		var p: Dictionary = players[peer_id]
		var stats: Dictionary = C.ROLE_STATS[p.role]
		if p.jump_ticks > 0:
			p.jump_ticks -= 1
		if p.slide_ticks > 0:
			p.slide_ticks -= 1
		if p.ability_cd_ticks > 0:
			p.ability_cd_ticks -= 1
		if p.dodge_charges < p.max_dodge:
			p.dodge_recharge_ticks += 1
			if p.dodge_recharge_ticks >= C.seconds_to_ticks(stats.dodge_recharge):
				p.dodge_recharge_ticks = 0
				p.dodge_charges += 1


## Passing a camp banks everyone's unbanked loot and opens the extraction window.
func _reach_camps() -> void:
	for camp in camps.values():
		if camp.reached or camp.distance > distance:
			continue
		camp.reached = true
		camp.leave_until = run_seconds() + zone.camp_window_seconds
		var banked := {}
		for peer_id in players:
			var p: Dictionary = players[peer_id]
			if p.unbanked > 0:
				banked[peer_id] = p.unbanked
				p.loot += p.unbanked
				p.unbanked = 0
		events.append({ "type": "camp", "camp": camp.id, "banked": banked })


func _resolve_collisions() -> void:
	# Monsters in the impact window, oldest first so a stack resolves in a stable order.
	var arriving: Array = []
	for m in monsters.values():
		if m.alive and not m.touched and absf(m.distance - distance) <= hit_radius():
			arriving.append(m)
	arriving.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.id < b.id)
	var swung := {}  # peer_id -> true: each player lands one weapon hit per tick
	for m in arriving:
		_impact(m, swung)
	for o in obstacles.values():
		if not o.has_hit and absf(o.distance - distance) <= hit_radius():
			_collide_obstacle(o)


## A monster meets the party. Everyone in its lane who is not hopping over or sliding
## under it swings first. If it dies, nobody is hurt. If it survives, it strikes every
## player who clashed with it and reels one spawn interval backwards.
func _impact(m: Dictionary, swung: Dictionary) -> void:
	var clashing: Array = []
	var anyone_in_lane := false
	for peer_id in players:
		var p: Dictionary = players[peer_id]
		if not p.alive or p.lane != m.lane:
			continue
		anyone_in_lane = true
		var how := _avoided_by(m, "monster", p)
		if how != "":
			events.append({ "type": "avoided", "peer": peer_id, "monster": m.id, "how": how })
			continue
		clashing.append(peer_id)
	if not anyone_in_lane:
		return  # lane is empty; leave it untouched so a late lane switch still engages it
	m.touched = true
	if clashing.is_empty():
		return  # everyone passed over or under it; it drifts behind the party
	for peer_id in clashing:
		if swung.has(peer_id):
			continue
		swung[peer_id] = true
		_damage_monster(m, players[peer_id].damage, peer_id)
		if not m.alive:
			return
	# It survived the volley: it strikes back, then flies backwards to come at us again.
	for peer_id in clashing:
		_hurt_player(peer_id, m.damage, "monster", m.id)
	m.distance += knockback_distance()
	m.touched = false
	events.append({ "type": "knockback", "monster": m.id, "lane": m.lane })


func _collide_obstacle(o: Dictionary) -> void:
	for peer_id in players:
		var p: Dictionary = players[peer_id]
		if not p.alive or p.lane != o.lane:
			continue
		o.has_hit = true
		var how := _avoided_by(o, "obstacle", p)
		if how != "":
			events.append({ "type": "avoided", "peer": peer_id, "obstacle": o.id, "how": how })
			continue
		_hurt_player(peer_id, C.OBSTACLE_DAMAGE, "obstacle", o.id)


func _damage_monster(m: Dictionary, damage: int, by_peer: int) -> void:
	m.hp -= damage
	m.hitters[by_peer] = true
	events.append({ "type": "hit", "peer": by_peer, "monster": m.id, "damage": damage })
	if m.hp <= 0:
		m.hp = 0
		m.alive = false
		events.append({ "type": "kill", "peer": by_peer, "monster": m.id, "level": m.level })
		# Everyone who landed a hit on it shares the loot. Unbanked until the next camp.
		var worth: int = zone.loot_per_level * m.level
		for peer_id in m.hitters:
			if players.has(peer_id):
				players[peer_id].unbanked += worth
				events.append({ "type": "loot", "peer": peer_id, "amount": worth })


func _hurt_player(peer_id: int, damage: int, what: String, thing_id: int) -> void:
	var p: Dictionary = players[peer_id]
	damage = maxi(0, damage - p.armor)  # armor is a flat reduction, then the shield soaks
	if p.shield > 0:
		var absorbed: int = mini(p.shield, damage)
		p.shield -= absorbed
		damage -= absorbed
	p.hp -= damage
	events.append({ "type": "damage", "peer": peer_id, what: thing_id, "damage": damage })
	if p.hp <= 0:
		p.hp = 0
		p.alive = false
		var lost: int = p.unbanked
		p.unbanked = 0
		events.append({ "type": "death", "peer": peer_id, "lost": lost })


## "" if the player meets the thing head on, otherwise the move that carried them past it.
func _avoided_by(thing: Dictionary, what: String, p: Dictionary) -> String:
	var wants_jump: bool
	var wants_slide: bool
	if what == "monster":
		wants_jump = thing.attack == C.Attack.LOW
		wants_slide = thing.attack == C.Attack.HIGH
	else:
		wants_jump = thing.kind == C.Obstacle.HURDLE
		wants_slide = thing.kind == C.Obstacle.BEAM
	if wants_jump and p.jump_ticks > 0:
		return "jump"
	if wants_slide and p.slide_ticks > 0:
		return "slide"
	return ""


# ---------------------------------------------------------------- spawning (seeded)

## The spawn pointer is a time: the run-second at which the party will meet the thing.
## It is placed on the track at the distance the party will have covered by then, so the
## spacing in seconds holds even while the pace ramps.
func _spawn_ahead() -> void:
	while _next_spawn_time < run_seconds() + C.SPAWN_AHEAD_SECONDS:
		var at := distance + (_next_spawn_time - run_seconds()) * speed
		if _next_spawn_time >= _next_camp_time:
			_spawn_camp(at)
			_next_camp_time += zone.camp_every_seconds
			_next_spawn_time += zone.camp_window_seconds  # the quiet stretch past the camp
			continue
		var entry := _draw_spawn()
		var lane := _rng.randi_range(0, C.LANE_COUNT - 1)
		var level := 1 + int(floor(_next_spawn_time / zone.level_every_seconds))
		if entry.kind == "monster":
			_spawn_monster(at, lane, entry.attack, level)
		else:
			_spawn_obstacle(at, lane, entry.obstacle)
		_next_spawn_time += zone.spawn_seconds


func _draw_spawn() -> Dictionary:
	var roll := _rng.randi_range(1, _spawn_weight_total)
	for entry in zone.spawn_table:
		roll -= entry.weight
		if roll <= 0:
			return entry
	return zone.spawn_table[0]


func _spawn_monster(at_distance: float, lane: int, attack: int, level: int = 1) -> void:
	var id := _next_id
	_next_id += 1
	var hp := Z.monster_hp(zone, level)
	monsters[id] = {
		"id": id, "lane": lane, "distance": at_distance, "attack": attack, "level": level,
		"hp": hp, "max_hp": hp, "damage": Z.monster_damage(zone, level),
		"alive": true, "touched": false, "hitters": {},
	}


func _spawn_obstacle(at_distance: float, lane: int, kind: int) -> void:
	var id := _next_id
	_next_id += 1
	obstacles[id] = { "id": id, "lane": lane, "distance": at_distance, "kind": kind, "has_hit": false }


func _spawn_camp(at_distance: float) -> void:
	var id := _next_id
	_next_id += 1
	camps[id] = { "id": id, "distance": at_distance, "reached": false, "leave_until": 0.0 }


func _cull() -> void:
	var behind := distance - speed * C.DESPAWN_BEHIND_SECONDS
	var gone: Array = []
	for id in monsters:
		var m: Dictionary = monsters[id]
		if not m.alive or m.distance < behind:
			gone.append(id)
	for id in gone:
		monsters.erase(id)
	gone.clear()
	for id in obstacles:
		if obstacles[id].distance < behind:
			gone.append(id)
	for id in gone:
		obstacles.erase(id)
	gone.clear()
	for id in camps:
		var camp: Dictionary = camps[id]
		if camp.distance < behind and (not camp.reached or run_seconds() >= camp.leave_until):
			gone.append(id)
	for id in gone:
		camps.erase(id)


# ---------------------------------------------------------------- snapshot

## Wire format. Arrays instead of string-keyed dictionaries keep a 4-player party with
## ~8 things around 300-400 bytes, comfortably under ENet's ~1400 byte unreliable MTU.
##   players:   peer_id -> [role, lane, hp, shield, dodge_charges, jumping, sliding, ability_cd, alive, loot, unbanked, extracted,
##                          damage, armor, max_dodge, max_hp]
##   monsters:  id -> [lane, distance, hp, max_hp, attack, level]
##   obstacles: id -> [lane, distance, kind]
##   camps:     id -> [distance]
func to_snapshot() -> Dictionary:
	var ps := {}
	for peer_id in players:
		var p: Dictionary = players[peer_id]
		ps[peer_id] = [p.role, p.lane, p.hp, p.shield, p.dodge_charges, p.jump_ticks > 0, p.slide_ticks > 0,
			p.ability_cd_ticks, p.alive, p.loot, p.unbanked, p.extracted, p.damage, p.armor, p.max_dodge, p.max_hp]
	var ms := {}
	for id in monsters:
		var m: Dictionary = monsters[id]
		ms[id] = [m.lane, m.distance, m.hp, m.max_hp, m.attack, m.level]
	var os := {}
	for id in obstacles:
		var o: Dictionary = obstacles[id]
		os[id] = [o.lane, o.distance, o.kind]
	var cs := {}
	for id in camps:
		cs[id] = [camps[id].distance]
	var snap := {
		"t": tick, "d": distance, "s": speed, "l": lookahead_seconds, "k": at_camp(),
		"p": ps, "m": ms, "o": os, "c": cs,
	}
	if not events.is_empty():
		snap["e"] = events.duplicate()
	return snap


## Client side: expand the wire format back into readable dictionaries.
static func decode_snapshot(wire: Dictionary) -> Dictionary:
	var ps := {}
	for peer_id in wire.p:
		var a: Array = wire.p[peer_id]
		ps[peer_id] = {
			"role": a[0], "lane": a[1], "hp": a[2], "max_hp": a[15], "shield": a[3],
			"dodge_charges": a[4], "jumping": a[5], "sliding": a[6], "ability_cd": a[7], "alive": a[8],
			"loot": a[9], "unbanked": a[10], "extracted": a[11], "damage": a[12], "armor": a[13], "max_dodge": a[14],
		}
	var ms := {}
	for id in wire.m:
		var a: Array = wire.m[id]
		ms[id] = { "lane": a[0], "distance": a[1], "hp": a[2], "max_hp": a[3], "attack": a[4], "level": a[5] }
	var os := {}
	for id in wire.o:
		var a: Array = wire.o[id]
		os[id] = { "lane": a[0], "distance": a[1], "kind": a[2] }
	var cs := {}
	for id in wire.c:
		cs[id] = { "distance": wire.c[id][0] }
	return {
		"tick": wire.t, "distance": wire.d, "speed": wire.s, "lookahead_seconds": wire.l, "at_camp": wire.k,
		"players": ps, "monsters": ms, "obstacles": os, "camps": cs, "events": wire.get("e", []),
	}
