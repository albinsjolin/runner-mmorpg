class_name Zones
## Zone definitions. A zone is a place you run through: its pace, how far you can see,
## how dense the track is, what lives there and how it scales with depth, and where the
## camps are. Everything time-based is in seconds so it holds at any speed.
##
## Fields:
##   name                 shown in the HUD
##   speed                pace multiplier of Constants.BASE_SPEED (zone identity)
##   lookahead_seconds    how much track the client can see (fog). The pressure dial.
##   spawn_seconds        time between spawns. Also the knockback return time, so
##                        survivors land on the next spawn's spot and stack.
##   monster              base creature: name, hp, damage at level 1
##   level_every_seconds  depth at which the monster level goes up by one
##   level_hp_mult        hp multiplier per level above 1
##   level_damage_add     damage added per level above 1
##   loot_per_level       loot a kill is worth per monster level, to everyone who hit it
##   camp_every_seconds   a camp appears this often. Reaching it banks unbanked loot.
##   camp_window_seconds  quiet stretch after the camp where you may extract (E)
##   spawn_table          weighted kinds drawn by the seeded RNG
##   segments (optional)  repeating pace cycle: [{seconds, speed, lookahead_seconds?}]
##                        Lets a raid alternate between 2x runs and 3x sprints.

const C := preload("res://shared/constants.gd")

const DEFAULT_ZONE := "forest"

const ZONES := {
	"forest": {
		"name": "Whispering Forest",
		"speed": 1.0,
		"lookahead_seconds": 6.0,
		"spawn_seconds": 1.2,
		"monster": { "name": "Wolf", "hp": 30, "damage": 15 },
		"level_every_seconds": 45.0,
		"level_hp_mult": 1.5,
		"level_damage_add": 5,
		"loot_per_level": 10,
		"camp_every_seconds": 40.0,
		"camp_window_seconds": 4.0,
		"spawn_table": [
			{ "kind": "monster", "attack": C.Attack.BODY, "weight": 3 },
			{ "kind": "monster", "attack": C.Attack.LOW, "weight": 2 },
			{ "kind": "monster", "attack": C.Attack.HIGH, "weight": 2 },
			{ "kind": "obstacle", "obstacle": C.Obstacle.TOWER, "weight": 2 },
			{ "kind": "obstacle", "obstacle": C.Obstacle.HURDLE, "weight": 2 },
			{ "kind": "obstacle", "obstacle": C.Obstacle.BEAM, "weight": 2 },
		],
	},
	"canyon": {
		"name": "Red Canyon",
		"speed": 1.6,
		"lookahead_seconds": 4.5,
		"spawn_seconds": 1.0,
		"monster": { "name": "Raptor", "hp": 45, "damage": 20 },
		"level_every_seconds": 40.0,
		"level_hp_mult": 1.5,
		"level_damage_add": 6,
		"loot_per_level": 18,
		"camp_every_seconds": 45.0,
		"camp_window_seconds": 4.0,
		"spawn_table": [
			{ "kind": "monster", "attack": C.Attack.BODY, "weight": 2 },
			{ "kind": "monster", "attack": C.Attack.LOW, "weight": 3 },
			{ "kind": "monster", "attack": C.Attack.HIGH, "weight": 3 },
			{ "kind": "obstacle", "obstacle": C.Obstacle.TOWER, "weight": 3 },
			{ "kind": "obstacle", "obstacle": C.Obstacle.HURDLE, "weight": 2 },
			{ "kind": "obstacle", "obstacle": C.Obstacle.BEAM, "weight": 2 },
		],
	},
	"spine": {
		"name": "Dragon's Spine (raid)",
		"speed": 2.0,
		"lookahead_seconds": 3.5,
		"spawn_seconds": 1.0,
		"monster": { "name": "Drake", "hp": 60, "damage": 25 },
		"level_every_seconds": 30.0,
		"level_hp_mult": 1.4,
		"level_damage_add": 8,
		"loot_per_level": 40,
		"camp_every_seconds": 60.0,
		"camp_window_seconds": 5.0,
		"spawn_table": [
			{ "kind": "monster", "attack": C.Attack.BODY, "weight": 3 },
			{ "kind": "monster", "attack": C.Attack.LOW, "weight": 2 },
			{ "kind": "monster", "attack": C.Attack.HIGH, "weight": 2 },
			{ "kind": "obstacle", "obstacle": C.Obstacle.TOWER, "weight": 3 },
			{ "kind": "obstacle", "obstacle": C.Obstacle.HURDLE, "weight": 1 },
			{ "kind": "obstacle", "obstacle": C.Obstacle.BEAM, "weight": 1 },
		],
		# 40 s at 2x, then a 20 s sprint at 3x with less warning, repeat.
		"segments": [
			{ "seconds": 40.0, "speed": 2.0 },
			{ "seconds": 20.0, "speed": 3.0, "lookahead_seconds": 3.0 },
		],
	},
}


static func get_zone(id: String) -> Dictionary:
	return ZONES.get(id, ZONES[DEFAULT_ZONE])


static func is_valid(id: String) -> bool:
	return ZONES.has(id)


## Monster stats at a given level for a zone.
static func monster_hp(zone: Dictionary, level: int) -> int:
	return int(round(zone.monster.hp * pow(zone.level_hp_mult, level - 1)))


static func monster_damage(zone: Dictionary, level: int) -> int:
	return zone.monster.damage + zone.level_damage_add * (level - 1)


## Which pace segment applies at this depth, or {} if the zone has no segments.
static func segment_at(zone: Dictionary, run_seconds: float) -> Dictionary:
	if not zone.has("segments"):
		return {}
	var total := 0.0
	for seg in zone.segments:
		total += seg.seconds
	var t := fmod(run_seconds, total)
	for seg in zone.segments:
		if t < seg.seconds:
			return seg
		t -= seg.seconds
	return zone.segments[0]
