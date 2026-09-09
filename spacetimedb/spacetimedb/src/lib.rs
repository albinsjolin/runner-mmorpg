//! Runner MMORPG meta server: accounts, town, inventory, parties, chat, and the
//! hand-off to the Godot ENet run servers. Runs never happen here; this module
//! decides who runs where with what gear, and makes loot real afterwards.

use spacetimedb::{
    client_visibility_filter, reducer, table, Filter, Identity, ReducerContext, ScheduleAt,
    SpacetimeType, Table, Timestamp,
};
use std::time::Duration;

/// Shared secret a run server presents to become trusted. Change before going public
/// and pass the same value to the run server with --stdb-secret.
const SERVER_SECRET: &str = "dev-run-server-secret";
const STARTING_GOLD: u64 = 100;
const PARTY_SIZE: usize = 4;
const HEARTBEAT_TIMEOUT_SECS: i64 = 30;
const RUN_CLAIM_TIMEOUT_SECS: i64 = 60;

// Role bases mirror shared/constants.gd ROLE_STATS. Gear adds on top.
const ROLE_BASE: [(&str, i32, i32, i32); 4] = [
    // name, max_hp, damage, dodge_charges
    ("Warrior", 100, 15, 3),
    ("Healer", 80, 8, 3),
    ("Tank", 160, 10, 2),
    ("Rogue", 70, 12, 5),
];

// ---------------------------------------------------------------- types

#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Slot {
    Weapon,
    Armor,
    Potion,
}

/// One member's outcome, sent by the run server in commit_run.
#[derive(SpacetimeType, Clone, Debug)]
pub struct RunResult {
    pub identity: Identity,
    pub loot: i64,
    pub extracted: bool,
    pub died: bool,
}

// ---------------------------------------------------------------- town tables

#[table(accessor = player, public)]
pub struct Player {
    #[primary_key]
    pub identity: Identity,
    pub name: String,
    pub role: u8,
    pub gold: u64,
    pub online: bool,
    #[index(btree)]
    pub party_id: u64,
    pub last_seen: Timestamp,
}

#[table(accessor = item_def, public)]
pub struct ItemDef {
    #[primary_key]
    pub id: u64,
    pub name: String,
    pub slot: Slot,
    pub damage: i32,
    pub armor: i32,
    pub hp: i32,
    pub dodge: i32,
    pub price: u64,
}

#[table(accessor = inventory_item, public)]
pub struct InventoryItem {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[index(btree)]
    pub owner: Identity,
    pub item_def_id: u64,
    pub quantity: u32,
}

#[table(accessor = equipment, public)]
pub struct Equipment {
    #[primary_key]
    pub owner: Identity,
    pub weapon_item: u64, // inventory_item id, 0 = none
    pub armor_item: u64,
}

#[table(accessor = party, public)]
pub struct Party {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    pub leader: Identity,
    pub zone: String,
    pub state: String, // town | launching | running
}

#[table(accessor = party_member, public)]
pub struct PartyMember {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[index(btree)]
    pub party_id: u64,
    #[unique]
    pub identity: Identity,
    pub ready: bool,
}

#[table(accessor = chat_message, public)]
pub struct ChatMessage {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[index(btree)]
    pub channel: String,
    pub sender: Identity,
    pub sender_name: String,
    pub text: String,
    pub sent_at: Timestamp,
}

// ---------------------------------------------------------------- run hand-off tables

#[table(accessor = run_server, public)]
pub struct RunServer {
    #[primary_key]
    pub identity: Identity,
    pub address: String,
    pub load: u32,
    pub last_heartbeat: Timestamp,
}

#[table(accessor = run, public)]
pub struct Run {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[index(btree)]
    pub party_id: u64,
    pub zone: String,
    pub seed: u64,
    #[index(btree)]
    pub server: Identity,
    pub address: String,
    pub state: String, // requested | ready | running | finished | failed
    pub created_at: Timestamp,
}

#[table(accessor = run_member, public)]
pub struct RunMember {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[index(btree)]
    pub run_id: u64,
    #[index(btree)]
    pub identity: Identity,
    pub name: String,
    pub role: u8,
    pub damage: i32,
    pub armor: i32,
    pub max_hp: i32,
    pub dodge_charges: i32,
    pub loot: i64,
    pub extracted: bool,
    pub died: bool,
}

/// Join secrets. Public table, but row-level filters below let a player see only
/// their own ticket and a run server only the tickets of runs assigned to it.
#[table(accessor = run_ticket, public)]
pub struct RunTicket {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[index(btree)]
    pub run_id: u64,
    #[index(btree)]
    pub identity: Identity,
    #[index(btree)]
    pub server: Identity,
    pub secret: String,
}

#[client_visibility_filter]
const TICKET_OWNER: Filter = Filter::Sql("SELECT * FROM run_ticket WHERE identity = :sender");

#[client_visibility_filter]
const TICKET_SERVER: Filter = Filter::Sql("SELECT * FROM run_ticket WHERE server = :sender");

// ---------------------------------------------------------------- private tables

#[table(accessor = trusted_server)]
pub struct TrustedServer {
    #[primary_key]
    pub identity: Identity,
}

#[table(accessor = cleanup_timer, scheduled(cleanup))]
pub struct CleanupTimer {
    #[primary_key]
    #[auto_inc]
    pub scheduled_id: u64,
    pub scheduled_at: ScheduleAt,
}

// ---------------------------------------------------------------- lifecycle

#[reducer(init)]
pub fn init(ctx: &ReducerContext) {
    let catalog = [
        (1, "Wooden Sword", Slot::Weapon, 0, 0, 0, 0, 0),
        (2, "Iron Sword", Slot::Weapon, 5, 0, 0, 0, 60),
        (3, "Steel Sword", Slot::Weapon, 12, 0, 0, 0, 200),
        (4, "Twin Daggers", Slot::Weapon, 3, 0, 0, 1, 120),
        (10, "Cloth Armor", Slot::Armor, 0, 0, 0, 0, 0),
        (11, "Leather Armor", Slot::Armor, 0, 3, 10, 0, 50),
        (12, "Chain Mail", Slot::Armor, 0, 6, 25, 0, 180),
        (13, "Scout Cloak", Slot::Armor, 0, 1, 0, 1, 90),
        (20, "Health Potion", Slot::Potion, 0, 0, 0, 0, 15),
    ];
    for (id, name, slot, damage, armor, hp, dodge, price) in catalog {
        if ctx.db.item_def().id().find(id).is_none() {
            ctx.db.item_def().insert(ItemDef { id, name: name.into(), slot, damage, armor, hp, dodge, price });
        }
    }
    if ctx.db.cleanup_timer().count() == 0 {
        ctx.db.cleanup_timer().insert(CleanupTimer {
            scheduled_id: 0,
            scheduled_at: ScheduleAt::Interval(Duration::from_secs(10).into()),
        });
    }
}

#[reducer(client_connected)]
pub fn on_connect(ctx: &ReducerContext) {
    if let Some(p) = ctx.db.player().identity().find(ctx.sender()) {
        ctx.db.player().identity().update(Player { online: true, last_seen: ctx.timestamp, ..p });
    }
}

#[reducer(client_disconnected)]
pub fn on_disconnect(ctx: &ReducerContext) {
    if let Some(p) = ctx.db.player().identity().find(ctx.sender()) {
        let p = ctx.db.player().identity().update(Player { online: false, last_seen: ctx.timestamp, ..p });
        // Leaving town drops you from a party that is still in town, so a closed client
        // cannot hold a seat or block the launch. Mid-run membership is left alone.
        if p.party_id != 0 {
            if let Some(party) = ctx.db.party().id().find(p.party_id) {
                if party.state == "town" {
                    remove_from_party(ctx, p);
                }
            }
        }
    }
    // A run server dropping off stops receiving runs.
    if ctx.db.trusted_server().identity().find(ctx.sender()).is_some() {
        ctx.db.run_server().identity().delete(ctx.sender());
    }
}

// ---------------------------------------------------------------- town reducers

/// First call creates the account with starter gear. Later calls just rename.
#[reducer]
pub fn register(ctx: &ReducerContext, name: String) -> Result<(), String> {
    let name = clean_name(&name)?;
    if let Some(p) = ctx.db.player().identity().find(ctx.sender()) {
        ctx.db.player().identity().update(Player { name, ..p });
        return Ok(());
    }
    ctx.db.player().insert(Player {
        identity: ctx.sender(),
        name,
        role: 0,
        gold: STARTING_GOLD,
        online: true,
        party_id: 0,
        last_seen: ctx.timestamp,
    });
    let sword = ctx.db.inventory_item().insert(InventoryItem { id: 0, owner: ctx.sender(), item_def_id: 1, quantity: 1 });
    let cloth = ctx.db.inventory_item().insert(InventoryItem { id: 0, owner: ctx.sender(), item_def_id: 10, quantity: 1 });
    ctx.db.equipment().insert(Equipment { owner: ctx.sender(), weapon_item: sword.id, armor_item: cloth.id });
    Ok(())
}

#[reducer]
pub fn set_role(ctx: &ReducerContext, role: u8) -> Result<(), String> {
    if role as usize >= ROLE_BASE.len() {
        return Err("unknown role".into());
    }
    let p = require_player(ctx)?;
    ctx.db.player().identity().update(Player { role, ..p });
    Ok(())
}

#[reducer]
pub fn buy_item(ctx: &ReducerContext, item_def_id: u64) -> Result<(), String> {
    let p = require_player(ctx)?;
    let def = ctx.db.item_def().id().find(item_def_id).ok_or("no such item")?;
    if p.gold < def.price {
        return Err("not enough gold".into());
    }
    ctx.db.player().identity().update(Player { gold: p.gold - def.price, ..p });
    // Potions stack; gear is one row per piece.
    if def.slot == Slot::Potion {
        if let Some(stack) = ctx
            .db
            .inventory_item()
            .owner()
            .filter(ctx.sender())
            .find(|i| i.item_def_id == item_def_id)
        {
            ctx.db.inventory_item().id().update(InventoryItem { quantity: stack.quantity + 1, ..stack });
            return Ok(());
        }
    }
    ctx.db.inventory_item().insert(InventoryItem { id: 0, owner: ctx.sender(), item_def_id, quantity: 1 });
    Ok(())
}

#[reducer]
pub fn equip(ctx: &ReducerContext, inventory_item_id: u64) -> Result<(), String> {
    require_player(ctx)?;
    let item = ctx.db.inventory_item().id().find(inventory_item_id).ok_or("no such item")?;
    if item.owner != ctx.sender() {
        return Err("not yours".into());
    }
    let def = ctx.db.item_def().id().find(item.item_def_id).ok_or("bad item def")?;
    let eq = ctx.db.equipment().owner().find(ctx.sender()).ok_or("no equipment row")?;
    match def.slot {
        Slot::Weapon => ctx.db.equipment().owner().update(Equipment { weapon_item: item.id, ..eq }),
        Slot::Armor => ctx.db.equipment().owner().update(Equipment { armor_item: item.id, ..eq }),
        Slot::Potion => return Err("potions are used, not equipped".into()),
    };
    Ok(())
}

#[reducer]
pub fn send_chat(ctx: &ReducerContext, channel: String, text: String) -> Result<(), String> {
    let p = require_player(ctx)?;
    let text = text.trim().to_string();
    if text.is_empty() || text.chars().count() > 200 {
        return Err("message must be 1-200 characters".into());
    }
    let channel = match channel.as_str() {
        "town" => "town".to_string(),
        "party" if p.party_id != 0 => format!("party:{}", p.party_id),
        _ => return Err("unknown channel".into()),
    };
    ctx.db.chat_message().insert(ChatMessage {
        id: 0,
        channel,
        sender: ctx.sender(),
        sender_name: p.name.clone(),
        text,
        sent_at: ctx.timestamp,
    });
    Ok(())
}

// ---------------------------------------------------------------- parties

#[reducer]
pub fn create_party(ctx: &ReducerContext, zone: String) -> Result<(), String> {
    let p = require_player(ctx)?;
    if p.party_id != 0 {
        return Err("already in a party".into());
    }
    let zone = valid_zone(&zone)?;
    let party = ctx.db.party().insert(Party { id: 0, leader: ctx.sender(), zone, state: "town".into() });
    ctx.db.party_member().insert(PartyMember { id: 0, party_id: party.id, identity: ctx.sender(), ready: true });
    ctx.db.player().identity().update(Player { party_id: party.id, ..p });
    Ok(())
}

#[reducer]
pub fn join_party(ctx: &ReducerContext, party_id: u64) -> Result<(), String> {
    let p = require_player(ctx)?;
    if p.party_id != 0 {
        return Err("already in a party".into());
    }
    let party = ctx.db.party().id().find(party_id).ok_or("no such party")?;
    if party.state != "town" {
        return Err("party is out on a run".into());
    }
    if ctx.db.party_member().party_id().filter(party_id).count() >= PARTY_SIZE {
        return Err("party is full".into());
    }
    ctx.db.party_member().insert(PartyMember { id: 0, party_id, identity: ctx.sender(), ready: false });
    ctx.db.player().identity().update(Player { party_id, ..p });
    Ok(())
}

#[reducer]
pub fn leave_party(ctx: &ReducerContext) -> Result<(), String> {
    let p = require_player(ctx)?;
    if p.party_id == 0 {
        return Err("not in a party".into());
    }
    remove_from_party(ctx, p);
    Ok(())
}

#[reducer]
pub fn set_ready(ctx: &ReducerContext, ready: bool) -> Result<(), String> {
    require_player(ctx)?;
    let m = ctx.db.party_member().identity().find(ctx.sender()).ok_or("not in a party")?;
    ctx.db.party_member().id().update(PartyMember { ready, ..m });
    Ok(())
}

#[reducer]
pub fn set_party_zone(ctx: &ReducerContext, zone: String) -> Result<(), String> {
    let p = require_player(ctx)?;
    let party = ctx.db.party().id().find(p.party_id).ok_or("not in a party")?;
    if party.leader != ctx.sender() {
        return Err("only the leader picks the zone".into());
    }
    let zone = valid_zone(&zone)?;
    ctx.db.party().id().update(Party { zone, ..party });
    Ok(())
}

/// Leader launches. Snapshots every member's loadout, picks the least loaded run
/// server, and hands out join secrets. The run server takes it from there.
#[reducer]
pub fn launch_run(ctx: &ReducerContext) -> Result<(), String> {
    let p = require_player(ctx)?;
    let party = ctx.db.party().id().find(p.party_id).ok_or("not in a party")?;
    if party.leader != ctx.sender() {
        return Err("only the leader launches".into());
    }
    launch_party(ctx, party)
}

/// Pick a map at the gate and go. Solo players get a party of one; a leader retargets
/// the party's zone. Members who are not the leader cannot launch.
#[reducer]
pub fn quick_run(ctx: &ReducerContext, zone: String) -> Result<(), String> {
    let p = require_player(ctx)?;
    let zone = valid_zone(&zone)?;
    let party = if p.party_id == 0 {
        let party = ctx.db.party().insert(Party { id: 0, leader: ctx.sender(), zone, state: "town".into() });
        ctx.db.party_member().insert(PartyMember { id: 0, party_id: party.id, identity: ctx.sender(), ready: true });
        ctx.db.player().identity().update(Player { party_id: party.id, ..p });
        party
    } else {
        let party = ctx.db.party().id().find(p.party_id).ok_or("party vanished")?;
        if party.leader != ctx.sender() {
            return Err("only the party leader picks the map and launches".into());
        }
        if party.state != "town" {
            return Err("party is already launching".into());
        }
        ctx.db.party().id().update(Party { zone, ..party })
    };
    launch_party(ctx, party)
}

fn launch_party(ctx: &ReducerContext, party: Party) -> Result<(), String> {
    if party.state != "town" {
        return Err("party is already launching".into());
    }
    let members: Vec<PartyMember> = ctx.db.party_member().party_id().filter(party.id).collect();
    if let Some(m) = members.iter().find(|m| !m.ready) {
        let who = ctx.db.player().identity().find(m.identity).map(|x| x.name).unwrap_or_default();
        return Err(format!("{} is not ready", who));
    }
    let server = pick_server(ctx).ok_or("no run server is online")?;

    let seed: u64 = ctx.random();
    let run = ctx.db.run().insert(Run {
        id: 0,
        party_id: party.id,
        zone: party.zone.clone(),
        seed: if seed == 0 { 1 } else { seed },
        server: server.identity,
        address: String::new(),
        state: "requested".into(),
        created_at: ctx.timestamp,
    });
    for m in members {
        let mp = ctx.db.player().identity().find(m.identity).ok_or("member vanished")?;
        let (damage, armor, max_hp, dodge) = loadout_for(ctx, &mp);
        ctx.db.run_member().insert(RunMember {
            id: 0,
            run_id: run.id,
            identity: m.identity,
            name: mp.name.clone(),
            role: mp.role,
            damage,
            armor,
            max_hp,
            dodge_charges: dodge,
            loot: 0,
            extracted: false,
            died: false,
        });
        ctx.db.run_ticket().insert(RunTicket {
            id: 0,
            run_id: run.id,
            identity: m.identity,
            server: server.identity,
            secret: random_secret(ctx),
        });
    }
    ctx.db.run_server().identity().update(RunServer { load: server.load + 1, ..server });
    ctx.db.party().id().update(Party { state: "launching".into(), ..party });
    Ok(())
}

// ---------------------------------------------------------------- run server reducers

#[reducer]
pub fn server_register(ctx: &ReducerContext, secret: String, address: String) -> Result<(), String> {
    if secret != SERVER_SECRET {
        return Err("bad server secret".into());
    }
    if ctx.db.trusted_server().identity().find(ctx.sender()).is_none() {
        ctx.db.trusted_server().insert(TrustedServer { identity: ctx.sender() });
    }
    let row = RunServer { identity: ctx.sender(), address, load: 0, last_heartbeat: ctx.timestamp };
    if ctx.db.run_server().identity().find(ctx.sender()).is_some() {
        ctx.db.run_server().identity().update(row);
    } else {
        ctx.db.run_server().insert(row);
    }
    Ok(())
}

#[reducer]
pub fn server_heartbeat(ctx: &ReducerContext, load: u32) -> Result<(), String> {
    require_trusted(ctx)?;
    let s = ctx.db.run_server().identity().find(ctx.sender()).ok_or("not registered")?;
    ctx.db.run_server().identity().update(RunServer { load, last_heartbeat: ctx.timestamp, ..s });
    Ok(())
}

/// The run server has built the sim and is listening; tell the party where to connect.
#[reducer]
pub fn server_claim_run(ctx: &ReducerContext, run_id: u64, address: String) -> Result<(), String> {
    require_trusted(ctx)?;
    let run = ctx.db.run().id().find(run_id).ok_or("no such run")?;
    if run.server != ctx.sender() {
        return Err("run is assigned to another server".into());
    }
    if run.state != "requested" {
        return Err("run is not waiting to be claimed".into());
    }
    if let Some(party) = ctx.db.party().id().find(run.party_id) {
        ctx.db.party().id().update(Party { state: "running".into(), ..party });
    }
    ctx.db.run().id().update(Run { address, state: "ready".into(), ..run });
    Ok(())
}

/// The run is over. Loot becomes gold here and nowhere else.
#[reducer]
pub fn commit_run(ctx: &ReducerContext, run_id: u64, results: Vec<RunResult>) -> Result<(), String> {
    require_trusted(ctx)?;
    let run = ctx.db.run().id().find(run_id).ok_or("no such run")?;
    if run.server != ctx.sender() {
        return Err("run is assigned to another server".into());
    }
    if run.state == "finished" {
        return Err("already committed".into());
    }
    for r in results {
        let Some(member) = ctx.db.run_member().run_id().filter(run_id).find(|m| m.identity == r.identity) else {
            continue; // not a member of this run; ignore
        };
        let loot = r.loot.max(0);
        ctx.db.run_member().id().update(RunMember { loot, extracted: r.extracted, died: r.died, ..member });
        if let Some(p) = ctx.db.player().identity().find(r.identity) {
            ctx.db.player().identity().update(Player { gold: p.gold + loot as u64, ..p });
        }
    }
    for t in ctx.db.run_ticket().run_id().filter(run_id).collect::<Vec<_>>() {
        ctx.db.run_ticket().id().delete(t.id);
    }
    if let Some(party) = ctx.db.party().id().find(run.party_id) {
        ctx.db.party().id().update(Party { state: "town".into(), ..party });
        for m in ctx.db.party_member().party_id().filter(party.id).collect::<Vec<_>>() {
            if m.identity != party.leader {
                ctx.db.party_member().id().update(PartyMember { ready: false, ..m });
            }
        }
    }
    if let Some(s) = ctx.db.run_server().identity().find(ctx.sender()) {
        ctx.db.run_server().identity().update(RunServer { load: s.load.saturating_sub(1), ..s });
    }
    ctx.db.run().id().update(Run { state: "finished".into(), ..run });
    Ok(())
}

/// Every 10 s: forget run servers that stopped heartbeating, fail runs nobody claimed.
#[reducer]
pub fn cleanup(ctx: &ReducerContext, _timer: CleanupTimer) {
    let now = ctx.timestamp;
    for s in ctx.db.run_server().iter().collect::<Vec<_>>() {
        if age_secs(now, s.last_heartbeat) > HEARTBEAT_TIMEOUT_SECS {
            ctx.db.run_server().identity().delete(s.identity);
        }
    }
    for run in ctx.db.run().iter().collect::<Vec<_>>() {
        if run.state == "requested" && age_secs(now, run.created_at) > RUN_CLAIM_TIMEOUT_SECS {
            if let Some(party) = ctx.db.party().id().find(run.party_id) {
                ctx.db.party().id().update(Party { state: "town".into(), ..party });
            }
            for t in ctx.db.run_ticket().run_id().filter(run.id).collect::<Vec<_>>() {
                ctx.db.run_ticket().id().delete(t.id);
            }
            ctx.db.run().id().update(Run { state: "failed".into(), ..run });
        }
    }
}

// ---------------------------------------------------------------- helpers

fn require_player(ctx: &ReducerContext) -> Result<Player, String> {
    ctx.db.player().identity().find(ctx.sender()).ok_or_else(|| "register first".to_string())
}

fn require_trusted(ctx: &ReducerContext) -> Result<(), String> {
    if ctx.db.trusted_server().identity().find(ctx.sender()).is_none() {
        return Err("not a trusted run server".into());
    }
    Ok(())
}

fn clean_name(name: &str) -> Result<String, String> {
    let name = name.trim();
    let n = name.chars().count();
    if n < 2 || n > 16 {
        return Err("name must be 2-16 characters".into());
    }
    Ok(name.to_string())
}

fn valid_zone(zone: &str) -> Result<String, String> {
    match zone {
        "forest" | "canyon" | "spine" => Ok(zone.to_string()),
        _ => Err("unknown zone".into()),
    }
}

fn remove_from_party(ctx: &ReducerContext, p: Player) {
    let party_id = p.party_id;
    ctx.db.party_member().identity().delete(ctx.sender());
    ctx.db.player().identity().update(Player { party_id: 0, ..p });
    let Some(party) = ctx.db.party().id().find(party_id) else { return };
    let rest: Vec<PartyMember> = ctx.db.party_member().party_id().filter(party_id).collect();
    if rest.is_empty() {
        ctx.db.party().id().delete(party_id);
    } else if party.leader == ctx.sender() {
        let new_leader = rest[0].identity;
        ctx.db.party_member().id().update(PartyMember { ready: true, ..rest[0].clone() });
        ctx.db.party().id().update(Party { leader: new_leader, ..party });
    }
}

/// Role base plus equipped gear: (damage, armor, max_hp, dodge_charges).
fn loadout_for(ctx: &ReducerContext, p: &Player) -> (i32, i32, i32, i32) {
    let (_, base_hp, base_damage, base_dodge) = ROLE_BASE[p.role as usize % ROLE_BASE.len()];
    let (mut damage, mut armor, mut hp, mut dodge) = (base_damage, 0, base_hp, base_dodge);
    if let Some(eq) = ctx.db.equipment().owner().find(p.identity) {
        for item_id in [eq.weapon_item, eq.armor_item] {
            let Some(item) = ctx.db.inventory_item().id().find(item_id) else { continue };
            let Some(def) = ctx.db.item_def().id().find(item.item_def_id) else { continue };
            damage += def.damage;
            armor += def.armor;
            hp += def.hp;
            dodge += def.dodge;
        }
    }
    (damage, armor, hp, dodge)
}

fn pick_server(ctx: &ReducerContext) -> Option<RunServer> {
    ctx.db
        .run_server()
        .iter()
        .filter(|s| age_secs(ctx.timestamp, s.last_heartbeat) <= HEARTBEAT_TIMEOUT_SECS)
        .min_by_key(|s| s.load)
}

fn random_secret(ctx: &ReducerContext) -> String {
    let a: u64 = ctx.random();
    let b: u64 = ctx.random();
    format!("{:016x}{:016x}", a, b)
}

fn age_secs(now: Timestamp, then: Timestamp) -> i64 {
    (now.to_micros_since_unix_epoch() - then.to_micros_since_unix_epoch()) / 1_000_000
}

impl Clone for PartyMember {
    fn clone(&self) -> Self {
        PartyMember { id: self.id, party_id: self.party_id, identity: self.identity, ready: self.ready }
    }
}
