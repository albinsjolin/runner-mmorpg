extends Node
## The RPC surface. This node lives at /root/Main/Net on BOTH client and server,
## which is what Godot's high-level multiplayer needs for rpc() to resolve.
## It contains no game logic: it just validates the direction and emits signals.

# server-side signals
signal join_requested(peer_id: int, role: int, zone_id: String, run_id: int, secret: String)
signal input_received(peer_id: int, input: int, client_tick: int)

# client-side signals
signal welcomed(party_id: int, seed: int, server_tick: int, zone_id: String)
signal snapshot_received(snapshot: Dictionary)
signal rejected(reason: String)
signal run_over(summary: Dictionary)


# ------------------------------------------------ client -> server

## Reliable on purpose: these are discrete presses (lane change, dodge). A lost press
## would mean the player never moved. Continuous input streams would use unreliable_ordered.
@rpc("any_peer", "call_remote", "reliable")
## Offline mode: role + zone. Meta mode: run_id + the secret from the player's run_ticket.
func request_join(role: int, zone_id: String, run_id: int, secret: String) -> void:
	if not multiplayer.is_server():
		return
	join_requested.emit(multiplayer.get_remote_sender_id(), role, zone_id, run_id, secret)


@rpc("any_peer", "call_remote", "reliable")
func send_input(input: int, client_tick: int) -> void:
	if not multiplayer.is_server():
		return
	input_received.emit(multiplayer.get_remote_sender_id(), input, client_tick)


# ------------------------------------------------ server -> client

@rpc("authority", "call_remote", "reliable")
func welcome(party_id: int, seed: int, server_tick: int, zone_id: String) -> void:
	welcomed.emit(party_id, seed, server_tick, zone_id)


@rpc("authority", "call_remote", "reliable")
func reject(reason: String) -> void:
	rejected.emit(reason)


## The run has been committed to the meta server; the client should head back to town.
@rpc("authority", "call_remote", "reliable")
func finish_run(summary: Dictionary) -> void:
	run_over.emit(summary)


## Unreliable: a newer snapshot always supersedes an older one, so resending is pointless.
@rpc("authority", "call_remote", "unreliable")
func receive_snapshot(snapshot: Dictionary) -> void:
	snapshot_received.emit(snapshot)
