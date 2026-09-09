class_name Constants
## Numbers shared by client and server. Change here, both sides agree.

const PORT := 7777
const MAX_PEERS := 100
const PARTY_SIZE := 4

const TICK_RATE := 30              # server simulation ticks per second (matches physics_ticks_per_second)
const SNAPSHOT_EVERY_TICKS := 1    # 1 = 30 Hz snapshots. Raise to 2 for 15 Hz.

const LANE_COUNT := 3
const LANE_WIDTH := 2.0

## Speed is zone identity, not difficulty. 1x is BASE_SPEED; a raid sprint might run 3x.
## Everything below that really means "how much time you get" is written in seconds and
## multiplied by the current speed, so the combat windows are identical at every speed.
const BASE_SPEED := 10.0               # metres per second at 1x
const SPEED_RAMP := 8.0                # m/s^2 easing toward a new target speed

const HIT_WINDOW_TICKS := 6            # a thing is "on" the party for this many ticks (0.2 s)
const ABILITY_SECONDS := 1.4           # ranged abilities (Warrior cleave) reach this far ahead
const SPAWN_AHEAD_SECONDS := 8.0       # server keeps this much track spawned ahead
const DESPAWN_BEHIND_SECONDS := 1.0    # things this far behind are removed
const FIRST_SPAWN_SECONDS := 3.0       # quiet start

## Spawn pace, knockback (= spawn pace), look-ahead, monsters and camps are per zone:
## see shared/zones.gd.

const OBSTACLE_DAMAGE := 20

## Dodging IS switching lanes. When true, every lane switch costs one dodge charge
## (recharging per role). Set false for unlimited lane switching.
const LANE_SWITCH_USES_DODGE := true

const JUMP_DURATION_TICKS := 18    # 0.6 s airborne
const SLIDE_DURATION_TICKS := 18   # 0.6 s sliding
const MAX_INPUTS_PER_TICK := 4     # server drops inputs beyond this per peer per tick

enum Action { NONE, LANE_LEFT, LANE_RIGHT, JUMP, SLIDE, ABILITY, EXTRACT }
enum Role { WARRIOR, HEALER, TANK, ROGUE }

## How a monster attacks, which decides how you avoid it without killing it.
enum Attack {
	BODY,   # blocks the lane: switch lane or kill it
	LOW,    # sweep at the legs: jump over it
	HIGH,   # swing at the head: slide under it
}

## Static things in the track. None can be attacked.
enum Obstacle {
	TOWER,  # full height: switch lane
	HURDLE, # low wall: jump
	BEAM,   # overhead bar: slide
}

## Per-role tuning. damage is the weapon hit landed on every impact.
## dodge_recharge is seconds per charge, ability_cd in seconds.
const ROLE_STATS := {
	Role.WARRIOR: { "name": "Warrior", "max_hp": 100, "damage": 15, "dodge_charges": 3, "dodge_recharge": 2.5, "ability_cd": 6.0, "color": Color(0.9, 0.5, 0.1) },
	Role.HEALER:  { "name": "Healer",  "max_hp": 80,  "damage": 8,  "dodge_charges": 3, "dodge_recharge": 2.5, "ability_cd": 5.0, "color": Color(0.3, 0.9, 0.4) },
	Role.TANK:    { "name": "Tank",    "max_hp": 160, "damage": 10, "dodge_charges": 2, "dodge_recharge": 3.5, "ability_cd": 8.0, "color": Color(0.3, 0.5, 0.9) },
	Role.ROGUE:   { "name": "Rogue",   "max_hp": 70,  "damage": 12, "dodge_charges": 5, "dodge_recharge": 1.2, "ability_cd": 7.0, "color": Color(0.8, 0.3, 0.8) },
}

static func lane_to_x(lane: int) -> float:
	return (lane - (LANE_COUNT - 1) / 2.0) * LANE_WIDTH

static func seconds_to_ticks(seconds: float) -> int:
	return int(ceil(seconds * TICK_RATE))
