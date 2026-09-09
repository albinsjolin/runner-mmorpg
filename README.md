# Runner MMORPG (PoC)

Server-authoritative lane runner with a persistent town. One Godot 4.7 project, a Rust
SpacetimeDB module for everything that persists, and an ENet run server for the runs.

```
spacetimedb/        SpacetimeDB module (Rust): accounts, inventory, parties, chat, run hand-off
addons/SpacetimeDB  Godot SpacetimeDB SDK (GDScript)
spacetime_bindings/ generated typed bindings for the module (regenerate after schema changes)
main.gd             --server flag picks run server; otherwise town (or --host for a direct run)
client/town.gd      the town: buildings, shop, inventory, party board, chat
client/character.gd the player model: Mixamo clips from animations/ merged into one player
animations/         Mixamo FBX clips (running, jump, slide, attack, magic), same rig
client/meta.gd      SpacetimeDB connection wrapper used by town and run server
shared/             code both sides run
  constants.gd      port, tick rate, lanes, roles, tuning
  simulation.gd     PartySim: the whole game rules, no nodes
  net.gd            the RPC surface (lives at /root/Main/Net on both sides)
server/server.gd    ENet host, fixed tick, parties, input validation, snapshots
client/client.gd    ENet client, sends inputs, receives snapshots
client/world.gd     3D renderer driven by snapshots
client/hud.gd       debug HUD
```

## Architecture

Two servers with different jobs:

- **SpacetimeDB** (`spacetimedb/`) is the meta server. Accounts, gold, inventory and
  equipment, parties, chat, and the run hand-off live in its tables. Clients subscribe to
  rows and call reducers; the town scene is nothing but a view of those rows.
- **The Godot run server** (`server/server.gd`) is trusted, stateless, and tick-based. It
  connects to SpacetimeDB too, with its own identity, registers with a shared secret, and
  picks up runs assigned to it.

The hand-off: the party leader calls `launch_run`. The module snapshots every member's
loadout (role base plus equipped gear) into `run_member` rows, picks the least loaded run
server, writes a `run` in state requested and a `run_ticket` secret per member. Row-level
filters make a ticket visible only to its owner and to the assigned server. The run server
sees the run, builds the PartySim from the loadouts, and calls `server_claim_run` with its
address. Clients see the run turn ready, connect over ENet, and send their ticket. When
everyone is dead, extracted, or gone, the run server calls `commit_run`, which turns banked
loot into gold in one transaction. Nothing the client says is trusted for any of it.

## Setup

1. Install the SpacetimeDB CLI and Rust with the wasm target
   (`rustup target add wasm32-unknown-unknown`).
2. Start a local server: `spacetime start`
3. Publish the module from `spacetimedb/`: `spacetime publish runner --server local --yes`
4. Regenerate bindings after any schema change (server must be running):

```
godot --headless --path . --import
godot --headless --path . --script res://addons/SpacetimeDB/cli.gd
```

The shared run-server secret is `SERVER_SECRET` in `spacetimedb/spacetimedb/src/lib.rs`;
pass the same value to the run server with `--stdb-secret=...`. Change it before going public.

## Run locally

Open the folder in Godot 4.7 once so it imports. Then either use the editor's
run button for a client and start a server from a terminal, or:

```powershell
$env:GODOT = "C:\path\to\Godot_v4.7.2-stable_win64_console.exe"
.\run_local.ps1 -Clients 2
```

Manual equivalents (note the `--` before game args):

```
godot --path . -- --profile=alice                    # town, own identity file per profile
godot --headless --path . -- --server                # offline run server
godot --headless --path . -- --server --speed=3      # force every party to 3x (testing)
godot --path . -- --host=127.0.0.1 --zone=canyon     # direct run, no town: forest, canyon, spine
godot --headless --path . -- --host=127.0.0.1 --role=3 --bot     # random-input bot, prints events
```

Controls: A/D or arrows dodge (switch lane), Space or W jump, S slide, K role ability.
There is no attack button: you swing on impact. Dodging costs a charge that recharges per role (`LANE_SWITCH_USES_DODGE` in
constants turns that off). Jump and slide are free but last a fixed window and cannot overlap.
Roles: 0 Warrior (cleave), 1 Healer (heal lowest), 2 Tank (party shield), 3 Rogue (refill dodges).

## Zones

A zone is a place you run through, defined in `shared/zones.gd`: pace, how far you can
see, spawn density, what lives there and how it scales with depth, and how often camps
come. Parties are per zone; a client picks one with `--zone`.

| Zone   | Pace       | See ahead | Spawn every | Monster        | Level up every | Camp every |
|--------|------------|-----------|-------------|----------------|----------------|------------|
| forest | 1x         | 6.0 s     | 1.2 s       | Wolf 30 hp     | 45 s           | 40 s       |
| canyon | 1.6x       | 4.5 s     | 1.0 s       | Raptor 45 hp   | 40 s           | 45 s       |
| spine  | 2x / 3x    | 3.5/3.0 s | 1.0 s       | Drake 60 hp    | 30 s           | 60 s       |

Depth is measured in seconds of running, so it holds at any pace. Monster level rises with
depth: hp multiplies and damage adds per level. The spine raid has `segments`: 40 s at 2x,
then a 20 s sprint at 3x with less warning, repeating.

## Extraction loop

Every kill is worth `loot_per_level` times the monster level to everyone who hit it, and it
stays unbanked until the party passes a camp. Reaching a camp banks it and opens a short
window in which E extracts you from the run with everything banked. Die and you lose what
was unbanked. The party decides together whether to push on.

## Player model

`client/character.gd` instantiates `animations/running.fbx` and pulls the `mixamo_com`
clip out of every other FBX into one AnimationLibrary named run, jump, slide, attack and
magic. Forward root motion on the hips is stripped so the character runs on the spot; the
rig is scaled to 1.75 m from its bones. Jump and slide play on the rising edge of the
snapshot flags, attack plays on a `hit` event (a swing that landed on a monster), magic on
heal, shield, and refresh. Run speed follows the zone pace. Drop new Mixamo clips for the
same rig into `animations/` and add them to `CLIPS`.

## Speed

Speed is zone identity, not difficulty. `BASE_SPEED` is 1x; a raid sprint might run 3x.
Every distance in the simulation that really means "how much time you get" is written in
seconds (the zone's `spawn_seconds`, `HIT_WINDOW_TICKS`, `ABILITY_SECONDS`) and
multiplied by the current speed, so the combat windows are identical at every pace. The sim
eases toward a new target speed at `SPEED_RAMP` so mid-run changes do not snap.

The one thing deliberately not scaled is how far you can see: the client fogs the track at
the zone's `lookahead_seconds` of running. Reaction time is visible distance over speed, which makes
that the pressure dial for a fast zone. Set it per zone.

## Combat

Combat happens on impact. When a monster reaches the party, every player in its lane who
is not jumping over or sliding under it lands their weapon damage at once. If that kills
it, nobody is hurt. If it survives, it hits everyone who clashed with it and flies
one spawn interval of track backwards, and the party runs into it again then.
Knockback equals the spawn interval, so a survivor lands on the next spawn's spot
and they stack. In a stack each player swings at one monster per impact and every survivor
strikes back, so a stack is worth clearing with a full lane.

The intended play: one player clashes with a monster and takes a hit, a teammate moves
into the lane while it is flying back, and the two of them kill it together on the return
and take no damage.

What comes down the track, all drawn from the party seed:

| Thing            | Avoid by            | Notes                      |
|------------------|---------------------|----------------------------|
| Monster (body)   | switch lane or kill | red                        |
| Monster (low)    | jump, or kill       | orange, low bar, "JUMP"    |
| Monster (high)   | slide, or kill      | purple, high bar, "SLIDE"  |
| Tower            | switch lane only    | tall grey column           |
| Hurdle           | jump                | low wooden wall            |
| Beam             | slide               | overhead bar on posts      |

Weights live in `Constants.SPAWN_TABLE`.

## Tests

```
godot --headless --path . -s tests/sim_test.gd
```

Runs the simulation rules without networking: seeded spawns, jump/slide/lane avoidance per
thing type, dodge charges, impact combat, knockback, teaming up on a return, stacks,
speed windows at 3x, monster levels by depth, camps, loot banking, death, and extraction.

## How the netcode works

- The server ticks every party at 30 Hz in `_physics_process` and sends a snapshot
  every tick over the unreliable channel. A newer snapshot always wins, so lost ones
  are simply skipped and out-of-order ones are dropped on the client.
- Clients send discrete inputs (lane change, jump, slide, ability) over the reliable
  channel. They are presses, not a stream, so a lost press would be a lost move.
- The server validates: peer must be in a party, action must be a known enum value,
  at most `MAX_INPUTS_PER_TICK` per peer per tick. Everything else the simulation
  decides (cooldowns, dodge charges, range).
- The client extrapolates forward motion between snapshots using the constant run
  speed, and lerps lane changes. No prediction of your own inputs yet; that is the
  next step and it is why the simulation is in `shared/`.
- Snapshots are compact arrays (see `PartySim.to_snapshot`), a few hundred bytes for a
  party. Stay under ENet's ~1400 byte MTU or unreliable packets fragment and drop.

## Host the ENet run server on DigitalOcean

This is the setup that was tested: a 1 GB Ubuntu droplet in Amsterdam running the Godot
run server headless, clients on PCs joining it directly over UDP. Everything needed is in
`deploy/`. Use the 1 GB size or bigger: Godot's import step runs the engine in editor mode
and gets OOM-killed on the 512 MB droplet. The running server itself idles at about 125 MB.

### 1. Create the droplet

Ubuntu 24.04, 1 GB, a region near the players (Amsterdam or Frankfurt from Sweden), your
SSH key added. Note the public IP; the commands below use `IP` for it.

### 2. One-time setup on the box

From your PC:

```powershell
scp deploy/setup_vps.sh deploy/runner-server.service root@IP:/root/
ssh root@IP bash /root/setup_vps.sh
```

The script waits for the first-boot apt run to release its lock (it prints
"waiting for the first-boot apt run to finish..." meanwhile), installs the libraries Godot
wants, downloads Godot 4.7.2 for Linux to `/opt/godot/godot` (the editor binary runs
headless, so no export templates), adds a 1 GB swap file, creates the `runner` user and
`/opt/runner/app`, opens SSH and UDP 7777 in ufw, and installs the `runner-server` systemd
service. The server flags live in `/etc/runner.env`, preset to offline mode with the
droplet's public IP as its address. It is safe to rerun.

If the droplet has a DigitalOcean Cloud Firewall attached, add an inbound rule for UDP
7777 there too; it drops packets silently otherwise.

### 3. Deploy the project

From your PC, and again after every code change:

```powershell
.\deploy\deploy.ps1 -VpsHost root@IP
```

It packs the project without caches (about 1 MB), uploads it with scp, unpacks it to
`/opt/runner/app`, runs Godot's import on the box to build the `.godot` cache and class
registry, and restarts the service. It ends with "import ok: N classes registered" and the
service status. If the import fails it prints the import log and stops.

### 4. Check it is running

On the box:

```
systemctl status runner-server --no-pager
journalctl -u runner-server -n 20 --no-pager      # expect: [server] listening on UDP 7777
ss -lunp | grep 7777                              # expect a godot process on the port
```

### 5. Join and measure latency

From each PC:

```
godot --path . -- --host=IP --zone=forest
```

The top-right HUD line shows the ENet round trip, packet loss, and how stale the newest
snapshot is. Green under 80 ms, yellow under 150. Amsterdam from Sweden measures around
20 to 40 ms. With no client prediction yet, the delay between a key press and the
character moving is one round trip.

### If it does not start

The server log showing `Could not find type "RunnerModuleClient"` or `Identifier
"Constants" not declared` means the `.godot` cache is missing: the import did not run.
Run it by hand and restart:

```
sudo -u runner HOME=/opt/runner /opt/godot/godot --headless --path /opt/runner/app --import
systemctl restart runner-server && sleep 2 && ss -lunp | grep 7777
```

The import prints progress lines ending in `[ DONE ] reimport`. A final
`ERROR: Couldn't return to previous working directory` is harmless: the runner user cannot
read /root. "Killed" means the box ran out of memory; check `free -m` and `swapon --show`.

Other useful commands on the box:

```
journalctl -u runner-server -f                    # follow the server log
nano /etc/runner.env && systemctl restart runner-server   # change flags (speed, meta mode)
```

### Meta mode on the VPS (town, parties, loot)

Rerun setup with `WITH_SPACETIMEDB=1` to install SpacetimeDB on the box, publish the
module to it from your PC, switch `/etc/runner.env` to the meta line, and point clients at
it with `--stdb`:

```
ssh root@IP WITH_SPACETIMEDB=1 bash /root/setup_vps.sh
spacetime server add vps http://IP:3000
cd spacetimedb; spacetime publish runner --server vps --yes; cd ..
ssh root@IP "sed -i 's/^RUNNER_ARGS=--server --address/# &/; s/^# RUNNER_ARGS=--server --stdb/RUNNER_ARGS=--server --stdb/' /etc/runner.env && systemctl restart runner-server"
godot --path . -- --stdb=http://IP:3000 --profile=me
```

## Next steps worth doing

- Client-side prediction of your own lane/dodge using `PartySim` locally, reconciled
  against snapshots by tick.
- Binary snapshots via `StreamPeerBuffer` once parties get big.
- Delta snapshots (only changed monsters) and a monster despawn list.
- Potions do nothing yet, and gear has no durability or rarity.
- Dead and extracted players spectate until the run ends; no rejoin.
- Run servers are a static pool. Spinning them up per run is a later problem.
- SpacetimeDB is local; for DigitalOcean run `spacetimedb` on the droplet next to the
  run server and point clients at it with `--stdb`.
