extends Node
## Connection to the SpacetimeDB meta server (accounts, town, parties, run hand-off).
## Wraps the generated SpacetimeDB.Runner client with a saved identity, one subscription,
## and a couple of helpers. Both the town scene and the run server use this.

signal connected_and_subscribed
signal failed(reason: String)

var url := "http://127.0.0.1:3000"
var token_path := "user://player_token.dat"   # run server overrides with its own file
var identity: PackedByteArray

var client: RunnerModuleClient
var _sub: SpacetimeDBSubscription


func start(queries: PackedStringArray) -> void:
	client = SpacetimeDB.Runner
	client.token_save_path = token_path
	client.connected.connect(_on_connected.bind(queries))
	client.connection_error.connect(func(code: int, reason: String) -> void:
		failed.emit("SpacetimeDB error %d: %s" % [code, reason]))
	client.disconnected.connect(func() -> void: print("[meta] disconnected"))
	var o := SpacetimeDBConnectionOptions.new()
	o.one_time_token = false   # keep the same identity across launches
	o.save_token = true
	o.auto_reconnect = true
	o.max_reconnect_attempts = 0
	client.connect_db(url, "runner", o)


func _on_connected(id: PackedByteArray, _token: String, queries: PackedStringArray) -> void:
	identity = id
	print("[meta] connected as %s" % id.hex_encode().substr(0, 12))
	_sub = client.subscribe(queries)
	if _sub.error != OK:
		failed.emit("subscribe failed: %s" % error_string(_sub.error))
		return
	_sub.applied.connect(func() -> void: connected_and_subscribed.emit())


func me() -> RunnerPlayer:
	if client == null or client.db == null:
		return null
	return client.db.player.identity.find(identity)


func is_me(id: PackedByteArray) -> bool:
	return id == identity


## SQL literal for an identity, for subscription queries.
func id_sql(id: PackedByteArray = identity) -> String:
	return SpacetimeDBQuery.identity(id)


## Calls a reducer and returns "" on success or the error text.
func invoke(reducer: SpacetimeDBReducerCall) -> String:
	await reducer.wait_for_response()
	if reducer.is_ok():
		return ""
	if reducer.outcome == SpacetimeDBReducerCall.Outcome.TIMEOUT:
		return "timed out"
	return reducer.error_message if reducer.error_message != "" else "failed"
