extends SceneTree
## Deterministic tests for PartySim. No networking, no nodes.
## Run:  godot --headless --path . -s tests/sim_test.gd

const C := preload("res://shared/constants.gd")
const Z := preload("res://shared/zones.gd")
const DT := 1.0 / C.TICK_RATE
const PEER := 7
const MATE := 8
const WOLF_HP := 30      # forest level 1, see zones.gd
const WOLF_DMG := 15
const RETURN_TICKS := int(1.2 * C.TICK_RATE)  # forest spawn_seconds

var _failures := 0


func _init() -> void:
	test_seeded_spawns_include_obstacles()
	test_hurdle_jumped()
	test_hurdle_not_jumped_hurts()
	test_tower_cannot_be_jumped_or_slid()
	test_beam_slid()
	test_low_monster_jumped_high_monster_slid()
	test_body_monster_ignores_jump()
	test_lane_switch_costs_dodge_charge()
	test_impact_survivor_hits_back_and_flies_back()
	test_impact_kill_means_no_damage()
	test_teammate_joins_for_the_return()
	test_stack_each_player_swings_once_every_survivor_strikes()
	test_shield_absorbs_impact()
	test_windows_hold_at_3x()
	test_speed_eases_toward_target()
	test_zone_sets_pace_and_monster()
	test_monster_level_rises_with_depth()
	test_camps_bank_loot_and_allow_extract()
	test_death_loses_unbanked_loot()
	test_raid_segments_cycle_pace()
	test_loadout_overrides_role_base()
	if _failures == 0:
		print("ALL TESTS PASSED")
	else:
		print("%d FAILURE(S)" % _failures)
	quit(1 if _failures > 0 else 0)


# ---------------------------------------------------------------- track

func test_seeded_spawns_include_obstacles() -> void:
	var sim := PartySim.new("forest", 42)
	sim.add_player(PEER, C.Role.WARRIOR)
	var kinds := {}
	for i in 900:  # 30 s of running, ~25 spawns
		sim.step(DT)
		for o in sim.obstacles.values():
			kinds[o.kind] = true
	_check(sim.monsters.size() > 0, "monsters spawn")
	_check(kinds.has(C.Obstacle.TOWER) and kinds.has(C.Obstacle.HURDLE) and kinds.has(C.Obstacle.BEAM),
		"all obstacle kinds spawn from the seed (got %s)" % [kinds.keys()])
	var again := PartySim.new("forest", 42)
	again.add_player(PEER, C.Role.WARRIOR)
	for i in 900:
		again.step(DT)
	_check(sim.obstacles.keys() == again.obstacles.keys(), "same seed gives same track")


# ---------------------------------------------------------------- avoidance

func test_hurdle_jumped() -> void:
	var ev := _run_into("obstacle", C.Obstacle.HURDLE, C.Action.JUMP)
	_check(ev.type == "avoided" and ev.how == "jump", "hurdle avoided by jump, got %s" % ev)


func test_hurdle_not_jumped_hurts() -> void:
	var ev := _run_into("obstacle", C.Obstacle.HURDLE, C.Action.SLIDE)
	_check(ev.type == "damage" and ev.damage == C.OBSTACLE_DAMAGE, "hurdle hurts when sliding, got %s" % ev)


func test_tower_cannot_be_jumped_or_slid() -> void:
	var a := _run_into("obstacle", C.Obstacle.TOWER, C.Action.JUMP)
	var b := _run_into("obstacle", C.Obstacle.TOWER, C.Action.SLIDE)
	_check(a.type == "damage" and b.type == "damage", "tower hits regardless of jump/slide")
	var c := _run_into("obstacle", C.Obstacle.TOWER, C.Action.LANE_LEFT)
	_check(c.is_empty(), "tower avoided by changing lane, got %s" % c)


func test_beam_slid() -> void:
	var ev := _run_into("obstacle", C.Obstacle.BEAM, C.Action.SLIDE)
	_check(ev.type == "avoided" and ev.how == "slide", "beam avoided by slide, got %s" % ev)
	var bad := _run_into("obstacle", C.Obstacle.BEAM, C.Action.JUMP)
	_check(bad.type == "damage", "beam hurts when jumping")


func test_low_monster_jumped_high_monster_slid() -> void:
	var a := _run_into("monster", C.Attack.LOW, C.Action.JUMP)
	_check(a.type == "avoided" and a.how == "jump", "LOW monster jumped, got %s" % a)
	var b := _run_into("monster", C.Attack.HIGH, C.Action.SLIDE)
	_check(b.type == "avoided" and b.how == "slide", "HIGH monster slid, got %s" % b)
	var c := _run_into("monster", C.Attack.LOW, C.Action.SLIDE)
	_check(c.type == "damage" and c.damage == WOLF_DMG, "LOW monster hurts when sliding")
	# Passing over it is not a clash: no swing, no knockback, it drifts behind.
	var sim := _empty_sim(C.Role.WARRIOR)
	sim._spawn_monster(sim.distance + sim.speed * 0.5, 1, C.Attack.LOW)
	_steps(sim, 9)
	sim.apply_input(PEER, C.Action.JUMP, 0)
	_steps(sim, 10)
	var m: Dictionary = sim.monsters.values()[0]
	_check(m.hp == WOLF_HP and m.distance < sim.distance, "jumped-over monster is untouched and behind us")


func test_body_monster_ignores_jump() -> void:
	var ev := _run_into("monster", C.Attack.BODY, C.Action.JUMP)
	_check(ev.type == "damage", "BODY monster hurts through a jump")


func test_lane_switch_costs_dodge_charge() -> void:
	var sim := PartySim.new("forest", 1)
	sim.add_player(PEER, C.Role.TANK)  # 2 charges
	var p: Dictionary = sim.players[PEER]
	sim.apply_input(PEER, C.Action.LANE_LEFT, 0)
	sim.apply_input(PEER, C.Action.LANE_RIGHT, 0)
	_check(p.lane == 1 and p.dodge_charges == 0, "two switches use two charges")
	sim.events.clear()
	sim.apply_input(PEER, C.Action.LANE_LEFT, 0)
	_check(p.lane == 1 and sim.events[0].type == "no_dodge", "no charge, no switch")
	_steps(sim, C.seconds_to_ticks(C.ROLE_STATS[C.Role.TANK].dodge_recharge) + 1)
	_check(p.dodge_charges >= 1, "charge recharges")


# ---------------------------------------------------------------- impact combat

func test_impact_survivor_hits_back_and_flies_back() -> void:
	var sim := _empty_sim(C.Role.WARRIOR)  # 15 damage vs 30 hp
	var p: Dictionary = sim.players[PEER]
	sim._spawn_monster(sim.distance + sim.speed * 0.5, p.lane, C.Attack.BODY)
	var m: Dictionary = sim.monsters.values()[0]
	var impact_at := _run_until_event(sim, "knockback", 40)
	_check(impact_at > 0, "first impact knocks the monster back")
	_check(m.hp == WOLF_HP - 15, "weapon damage subtracted on impact (hp %d)" % m.hp)
	_check(p.hp == p.max_hp - WOLF_DMG, "survivor hit us back (hp %d)" % p.hp)
	_check(m.distance - sim.distance > sim.knockback_distance() - 2.0, "monster is one spawn interval ahead again")
	sim.events.clear()
	var return_at := _run_until_event(sim, "kill", RETURN_TICKS + 10)
	_check(return_at > 0, "it comes back and the second swing kills it")
	_check(p.hp == p.max_hp - WOLF_DMG, "no damage taken on the killing impact")
	_check(not _has_event(sim, "damage"), "no damage event on the killing impact")
	_check(p.unbanked == 10, "kill is worth loot_per_level x level, unbanked (got %d)" % p.unbanked)


func test_impact_kill_means_no_damage() -> void:
	var sim := _empty_sim(C.Role.WARRIOR)
	sim.add_player(MATE, C.Role.ROGUE)  # 15 + 12 = 27 < 30: survives
	sim._spawn_monster(sim.distance + sim.speed * 0.5, 1, C.Attack.BODY)
	_run_until_event(sim, "knockback", 40)
	_check(sim.players[PEER].hp < sim.players[PEER].max_hp and sim.players[MATE].hp < sim.players[MATE].max_hp,
		"27 damage leaves it alive and both get hit")
	var sim2 := _empty_sim(C.Role.WARRIOR)
	sim2.add_player(MATE, C.Role.ROGUE)
	sim2.add_player(9, C.Role.TANK)      # 15 + 12 + 10 = 37 >= 30: dies on impact
	sim2._spawn_monster(sim2.distance + sim2.speed * 0.5, 1, C.Attack.BODY)
	_run_until_event(sim2, "kill", 40)
	var untouched := true
	for pl in sim2.players.values():
		untouched = untouched and pl.hp == pl.max_hp
	_check(untouched and sim2.monsters.is_empty(), "three swings kill it on impact, nobody is hurt")
	_check(sim2.players[9].unbanked == 10, "everyone who hit it gets the loot")


## The scenario from the design: one player clashes, takes a hit, then a teammate joins the
## lane while the monster flies back, and the pair kill it on its return unharmed.
func test_teammate_joins_for_the_return() -> void:
	_teammate_scenario(1.0)


## Returns the tick gap between the first impact and the return kill.
func _teammate_scenario(mult: float) -> int:
	var tag := " @%.0fx" % mult
	var sim := _empty_sim(C.Role.ROGUE, mult)   # 12 damage alone: 12, then 24 < 30 would not kill
	sim.add_player(MATE, C.Role.WARRIOR)        # 15 damage, starts in another lane
	sim.players[MATE].lane = 0
	sim._spawn_monster(sim.distance + sim.speed * 0.5, 1, C.Attack.BODY)
	var m: Dictionary = sim.monsters.values()[0]
	var first := _run_until_event(sim, "knockback", 40)
	_check(m.hp == 18 and sim.players[PEER].hp == 70 - WOLF_DMG and sim.players[MATE].hp == 100,
		"rogue clashes alone: 12 damage dealt, rogue hit, warrior untouched" + tag)
	sim.apply_input(MATE, C.Action.LANE_RIGHT, 0)  # warrior steps in while it flies back
	sim.events.clear()
	var second := _run_until_event(sim, "kill", RETURN_TICKS + 10)
	_check(sim.monsters.is_empty(), "it returns into both of them and dies (12 + 15 >= 18)" + tag)
	_check(sim.players[PEER].hp == 70 - WOLF_DMG and sim.players[MATE].hp == 100,
		"nobody takes damage on the return" + tag)
	return second - first


func test_stack_each_player_swings_once_every_survivor_strikes() -> void:
	var sim := _empty_sim(C.Role.WARRIOR)
	sim._spawn_monster(sim.distance + sim.speed * 0.5, 1, C.Attack.BODY)
	sim._spawn_monster(sim.distance + sim.speed * 0.5, 1, C.Attack.BODY)  # stacked on the same spot
	_run_until_event(sim, "knockback", 40)
	var hps: Array = []
	for m in sim.monsters.values():
		hps.append(m.hp)
	hps.sort()
	_check(hps == [15, 30], "one swing lands on one monster of the stack, got %s" % [hps])
	_check(sim.players[PEER].hp == 100 - 2 * WOLF_DMG, "both survivors strike back")
	var same_spot: bool = is_equal_approx(sim.monsters.values()[0].distance, sim.monsters.values()[1].distance)
	_check(same_spot, "stack stays together after knockback")


func test_shield_absorbs_impact() -> void:
	var sim := _empty_sim(C.Role.TANK)
	sim.apply_input(PEER, C.Action.ABILITY, 0)  # shield 30
	sim._spawn_monster(sim.distance + sim.speed * 0.5, 1, C.Attack.BODY)
	_run_until_event(sim, "knockback", 40)
	_check(sim.players[PEER].hp == 160 and sim.players[PEER].shield == 15, "shield soaks the strike")


# ---------------------------------------------------------------- speed

## Same plays, same windows, three times the pace.
func test_windows_hold_at_3x() -> void:
	var gap_1x := _teammate_scenario(1.0)
	var gap_3x := _teammate_scenario(3.0)
	_check(gap_1x == gap_3x and gap_1x > 0, "return window is the same number of ticks at 1x and 3x (%d vs %d)" % [gap_1x, gap_3x])
	var ev := _run_into("obstacle", C.Obstacle.HURDLE, C.Action.JUMP, 3.0)
	_check(ev.type == "avoided" and ev.how == "jump", "hurdle still jumpable at 3x, got %s" % ev)
	ev = _run_into("monster", C.Attack.HIGH, C.Action.SLIDE, 3.0)
	_check(ev.type == "avoided" and ev.how == "slide", "HIGH monster still slid at 3x, got %s" % ev)
	ev = _run_into("obstacle", C.Obstacle.TOWER, C.Action.LANE_LEFT, 3.0)
	_check(ev.is_empty(), "tower still avoided by lane switch at 3x")
	var sim := _empty_sim(C.Role.WARRIOR, 3.0)
	_check(is_equal_approx(sim.knockback_distance(), sim.spawn_interval()), "knockback equals spawn interval at 3x")


func test_speed_eases_toward_target() -> void:
	var sim := _empty_sim(C.Role.WARRIOR)
	sim.set_speed_multiplier(3.0)
	sim.step(DT)
	_check(sim.speed > C.BASE_SPEED and sim.speed < 3.0 * C.BASE_SPEED, "speed ramps instead of snapping")
	_steps(sim, C.TICK_RATE * 5)
	_check(is_equal_approx(sim.speed, 3.0 * C.BASE_SPEED), "speed reaches the target")


# ---------------------------------------------------------------- zones

func test_zone_sets_pace_and_monster() -> void:
	var canyon := PartySim.new("canyon", 5)
	canyon.add_player(PEER, C.Role.WARRIOR)
	_check(is_equal_approx(canyon.speed, 1.6 * C.BASE_SPEED), "canyon starts at its own pace (1.6x)")
	_check(is_equal_approx(canyon.lookahead_seconds, 4.5), "canyon look-ahead from the zone")
	_steps(canyon, 300)
	var m: Dictionary = canyon.monsters.values()[0]
	_check(m.max_hp == 45 and m.damage == 20 and m.level == 1, "canyon spawns level 1 raptors (45 hp, 20 dmg)")
	var bogus := PartySim.new("nowhere", 5)
	_check(bogus.zone_id == Z.DEFAULT_ZONE, "unknown zone falls back to the default")


func test_monster_level_rises_with_depth() -> void:
	var sim := PartySim.new("forest", 9)
	sim.add_player(PEER, C.Role.WARRIOR)
	sim.players[PEER].lane = -1  # off the track: never clash, just watch what spawns
	var seen := {}
	for i in C.TICK_RATE * 100:  # 100 s of forest: levels 1, 2 and 3 (every 45 s)
		sim.step(DT)
		for m in sim.monsters.values():
			seen[m.level] = m.max_hp
	_check(seen.has(1) and seen.has(2) and seen.has(3), "levels 1..3 appear over 100 s (got %s)" % [seen.keys()])
	_check(seen.get(2, 0) == 45 and seen.get(3, 0) == 68, "hp scales x1.5 per level: 30, 45, 68 (got %s)" % [seen])
	_check(Z.monster_damage(sim.zone, 3) == 25, "damage adds 5 per level: 25 at L3")


func test_camps_bank_loot_and_allow_extract() -> void:
	var sim := PartySim.new("forest", 3)
	sim.add_player(PEER, C.Role.WARRIOR)
	var p: Dictionary = sim.players[PEER]
	p.lane = -1  # spectate the track, no clashes
	sim.apply_input(PEER, C.Action.EXTRACT, 0)
	_check(_has_event(sim, "no_extract") and not p.extracted, "cannot extract away from a camp")
	p.unbanked = 50
	var camp_at := _run_until_event(sim, "camp", C.TICK_RATE * 60)
	_check(camp_at > 0 and camp_at / float(C.TICK_RATE) > 39.0 and camp_at / float(C.TICK_RATE) < 42.0,
		"first camp is reached ~40 s in (tick %d)" % camp_at)
	_check(p.loot == 50 and p.unbanked == 0, "reaching the camp banks unbanked loot")
	_check(sim.at_camp(), "extraction window is open just past the camp")
	var quiet := true
	for m in sim.monsters.values():
		if absf(m.distance - sim.distance) < sim.speed * 2.0:
			quiet = false
	_check(quiet, "no spawns right around the camp")
	p.unbanked = 7
	sim.events.clear()
	sim.apply_input(PEER, C.Action.EXTRACT, 0)
	_check(p.extracted and not p.alive and p.loot == 57, "extract banks and leaves the run with everything")
	_steps(sim, C.TICK_RATE * 5)
	_check(not sim.at_camp(), "window closes after camp_window_seconds")


func test_death_loses_unbanked_loot() -> void:
	var sim := _empty_sim(C.Role.ROGUE)  # 70 hp
	var p: Dictionary = sim.players[PEER]
	p.loot = 100
	p.unbanked = 40
	p.hp = 10
	sim._spawn_monster(sim.distance + sim.speed * 0.5, 1, C.Attack.BODY)
	_run_until_event(sim, "death", 40)
	_check(not p.alive and p.loot == 100 and p.unbanked == 0, "death keeps banked loot, loses unbanked")
	var death := {}
	for ev in sim.events:
		if ev.type == "death":
			death = ev
	_check(death.get("lost", -1) == 40, "death event reports what was lost")


func test_raid_segments_cycle_pace() -> void:
	var sim := PartySim.new("spine", 11)
	sim.add_player(PEER, C.Role.TANK)
	sim.players[PEER].lane = -1
	_check(is_equal_approx(sim.speed, 2.0 * C.BASE_SPEED), "spine opens at 2x")
	_steps(sim, C.TICK_RATE * 45)  # into the 3x sprint (starts at 40 s)
	_check(is_equal_approx(sim.speed, 3.0 * C.BASE_SPEED) and is_equal_approx(sim.lookahead_seconds, 3.0),
		"sprint segment: 3x with 3.0 s look-ahead (speed %.1f)" % sim.speed_multiplier())
	_steps(sim, C.TICK_RATE * 20)  # 65 s: back in the 2x segment of the next cycle
	_check(is_equal_approx(sim.speed, 2.0 * C.BASE_SPEED) and is_equal_approx(sim.lookahead_seconds, 3.5),
		"cycle repeats: back to 2x with zone look-ahead")


# ---------------------------------------------------------------- loadouts

func test_loadout_overrides_role_base() -> void:
	var sim := _empty_sim(C.Role.HEALER)
	sim.remove_player(PEER)
	sim.add_player(PEER, C.Role.HEALER, { "damage": 30, "armor": 5, "max_hp": 50, "dodge_charges": 1 })
	var p: Dictionary = sim.players[PEER]
	_check(p.hp == 50 and p.max_hp == 50 and p.dodge_charges == 1 and p.damage == 30, "gear sets hp, dodges, damage")
	sim._spawn_monster(sim.distance + sim.speed * 0.5, 1, C.Attack.BODY)
	_run_until_event(sim, "kill", 40)
	_check(sim.monsters.is_empty() and p.hp == 50, "30 weapon damage one-shots a 30 hp wolf")
	sim._spawn_obstacle(sim.distance + sim.speed * 0.5, 1, C.Obstacle.TOWER)
	_run_until_event(sim, "damage", 40)
	_check(p.hp == 50 - (C.OBSTACLE_DAMAGE - 5), "armor 5 turns 20 obstacle damage into 15 (hp %d)" % p.hp)
	var snap := PartySim.decode_snapshot(sim.to_snapshot())
	_check(snap.players[PEER].damage == 30 and snap.players[PEER].armor == 5 and snap.players[PEER].max_dodge == 1,
		"loadout rides along in the snapshot")


# ---------------------------------------------------------------- helpers

## Spawns one thing half a second ahead in the player's lane, applies `action` before
## impact, runs through the collision window, and returns the first damage/avoided event.
func _run_into(what: String, kind: int, action: int, mult: float = 1.0) -> Dictionary:
	var sim := _empty_sim(C.Role.WARRIOR, mult)
	var lane: int = sim.players[PEER].lane
	if what == "monster":
		sim._spawn_monster(sim.distance + sim.speed * 0.5, lane, kind)
	else:
		sim._spawn_obstacle(sim.distance + sim.speed * 0.5, lane, kind)
	# Half a second ahead = tick 15. The 6-tick hit window opens at tick 12 at any speed.
	# Act at tick 9 so an 18-tick jump/slide covers the whole window.
	_steps(sim, 9)
	sim.apply_input(PEER, action, 0)
	_steps(sim, 10)
	for ev in sim.events:
		if ev.type == "damage" or ev.type == "avoided":
			return ev
	return {}


## A forest sim with no seeded spawns or camps so tests control exactly what is on the track.
func _empty_sim(role: int, mult: float = 1.0) -> PartySim:
	var sim := PartySim.new("forest", 1)
	sim.set_speed_multiplier(mult, true)
	sim._next_spawn_time = 1.0e9
	sim._next_camp_time = 1.0e9
	sim.add_player(PEER, role)
	return sim


func _steps(sim: PartySim, n: int) -> void:
	for i in n:
		sim.step(DT)


## Steps until an event of `type` shows up. Returns the tick it happened on, or 0.
func _run_until_event(sim: PartySim, type: String, max_ticks: int) -> int:
	for i in max_ticks:
		sim.step(DT)
		if _has_event(sim, type):
			return sim.tick
	return 0


func _has_event(sim: PartySim, type: String) -> bool:
	for ev in sim.events:
		if ev.type == type:
			return true
	return false


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   " + what)
	else:
		_failures += 1
		print("  FAIL " + what)
