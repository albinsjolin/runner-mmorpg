extends Node3D
## Renders the party and monsters from server snapshots.
## Convention: the party stays at z = 0 and the world slides toward the camera.
## A monster at sim distance D is drawn at z = -(D - render_distance).

const C := preload("res://shared/constants.gd")
const SLAB_LENGTH := 10.0
const SLAB_COUNT := 12

## Text hint under a monster's hp telling the player how to avoid it.
const MONSTER_HINT := { C.Attack.BODY: "", C.Attack.LOW: "
JUMP", C.Attack.HIGH: "
SLIDE" }
const MONSTER_COLOR := {
	C.Attack.BODY: Color(0.85, 0.15, 0.15),
	C.Attack.LOW: Color(0.9, 0.45, 0.1),
	C.Attack.HIGH: Color(0.7, 0.15, 0.6),
}

var local_peer_id := 0
var render_distance := 0.0
var speed: float = C.BASE_SPEED          # from the latest snapshot; drives fog and field of view
var lookahead_seconds := 6.0             # from the latest snapshot (zone / segment)
var zone: Dictionary = Zones.get_zone(Zones.DEFAULT_ZONE)

var _camera: Camera3D
var _env: Environment

var _players := {}   # peer_id -> Node3D
var _monsters := {}  # monster_id -> Node3D
var _obstacles := {} # obstacle_id -> Node3D
var _camps := {}     # camp_id -> Node3D
var _slabs: Array[Node3D] = []
var _target_lane_x := {}  # peer_id -> float
var _pose := {}           # peer_id -> {jumping, sliding} from the last snapshot, for animation edges


func _ready() -> void:
	_build_environment()
	_build_ground()


func _process(delta: float) -> void:
	# Speed feel: visible track is lookahead_seconds of running, so fog thickens as pace rises,
	# and the camera widens a little so 3x looks like 3x.
	var visible := speed * lookahead_seconds
	_env.fog_density = lerpf(_env.fog_density, 2.5 / visible, minf(1.0, delta * 3.0))
	_camera.fov = lerpf(_camera.fov, 60.0 + 12.0 * (speed / C.BASE_SPEED - 1.0), minf(1.0, delta * 3.0))
	# Scroll ground slabs.
	var offset := fmod(render_distance, SLAB_LENGTH)
	for i in _slabs.size():
		_slabs[i].position.z = -(i * SLAB_LENGTH) + offset + SLAB_LENGTH
	# Smooth lane changes.
	for peer_id in _players:
		var node: Node3D = _players[peer_id]
		var tx: float = _target_lane_x.get(peer_id, 0.0)
		node.position.x = lerpf(node.position.x, tx, minf(1.0, delta * 12.0))
	# Monsters and obstacles slide toward the party.
	for id in _monsters:
		var m: Node3D = _monsters[id]
		# Glide toward the server distance so a knockback reads as a shove, not a teleport.
		var shown: float = lerpf(m.get_meta("shown"), m.get_meta("distance"), minf(1.0, delta * 8.0))
		m.set_meta("shown", shown)
		m.position.z = -(shown - render_distance)
		var bounce: float = maxf(0.0, m.get_meta("bounce") - delta * 2.5)
		m.set_meta("bounce", bounce)
		m.position.y = sin(bounce * PI) * 1.2
		var mmesh: MeshInstance3D = m.get_node("Mesh")
		mmesh.rotation.x = -bounce * 0.8
	for id in _obstacles:
		var o: Node3D = _obstacles[id]
		o.position.z = -(o.get_meta("distance") - render_distance)
	for id in _camps:
		var c: Node3D = _camps[id]
		c.position.z = -(c.get_meta("distance") - render_distance)


func apply_snapshot(snap: Dictionary) -> void:
	# Players. Stagger them slightly along z so party members sharing a lane read as a formation.
	var order: Array = snap.players.keys()
	order.sort()
	for peer_id in snap.players:
		var p: Dictionary = snap.players[peer_id]
		if not _players.has(peer_id):
			_players[peer_id] = _make_player(peer_id, p.role)
		var node: Node3D = _players[peer_id]
		_target_lane_x[peer_id] = C.lane_to_x(p.lane)
		node.position.z = 0.9 * order.find(peer_id)
		node.position.y = 0.5 if p.jumping else 0.0   # the clip has its own lift; this adds the clearance
		node.visible = p.alive
		var body: RunnerCharacter = node.get_node("Body")
		body.set_pace(speed / C.BASE_SPEED)
		var prev: Dictionary = _pose.get(peer_id, { "jumping": false, "sliding": false })
		if p.jumping and not prev.jumping:
			body.play_jump()
		elif p.sliding and not prev.sliding:
			body.play_slide()
		_pose[peer_id] = { "jumping": p.jumping, "sliding": p.sliding }
		var label: Label3D = node.get_node("Label")
		label.text = "%s%s %d/%d%s" % ["You: " if peer_id == local_peer_id else "", C.ROLE_STATS[p.role].name,
			p.hp, p.max_hp, " +%d" % p.shield if p.shield > 0 else ""]
	for peer_id in _players.keys():
		if not snap.players.has(peer_id):
			_players[peer_id].queue_free()
			_players.erase(peer_id)
			_target_lane_x.erase(peer_id)
			_pose.erase(peer_id)
	# Monsters
	for id in snap.monsters:
		var m: Dictionary = snap.monsters[id]
		if not _monsters.has(id):
			_monsters[id] = _make_monster(m.attack)
			_monsters[id].set_meta("shown", m.distance)
			_monsters[id].set_meta("bounce", 0.0)
		var node: Node3D = _monsters[id]
		node.position.x = C.lane_to_x(m.lane)
		node.set_meta("distance", m.distance)
		var label: Label3D = node.get_node("Label")
		label.text = "%s L%d  %d%s" % [zone.monster.name, m.level, m.hp, MONSTER_HINT[m.attack]]
		var mesh: MeshInstance3D = node.get_node("Mesh")
		mesh.scale.y = 0.4 + 0.6 * float(m.hp) / float(m.max_hp)
	for id in _monsters.keys():
		if not snap.monsters.has(id):
			_monsters[id].queue_free()
			_monsters.erase(id)
	for ev in snap.events:
		if ev.type == "knockback" and _monsters.has(ev.monster):
			_monsters[ev.monster].set_meta("bounce", 1.0)
		elif ev.type == "hit" and _players.has(ev.peer):
			_players[ev.peer].get_node("Body").play_attack()   # weapon lands on a monster
		elif ev.type in ["heal", "shield", "refresh"] and _players.has(ev.peer):
			_players[ev.peer].get_node("Body").play_magic()
	# Obstacles (static, only need creating once)
	for id in snap.obstacles:
		if not _obstacles.has(id):
			var o: Dictionary = snap.obstacles[id]
			var node := _make_obstacle(o.kind)
			node.position.x = C.lane_to_x(o.lane)
			node.set_meta("distance", o.distance)
			_obstacles[id] = node
	for id in _obstacles.keys():
		if not snap.obstacles.has(id):
			_obstacles[id].queue_free()
			_obstacles.erase(id)
	# Camps
	for id in snap.camps:
		if not _camps.has(id):
			var node := _make_camp()
			node.set_meta("distance", snap.camps[id].distance)
			_camps[id] = node
	for id in _camps.keys():
		if not snap.camps.has(id):
			_camps[id].queue_free()
			_camps.erase(id)


# ---------------------------------------------------------------- builders

func _make_player(peer_id: int, role: int) -> Node3D:
	var root := Node3D.new()
	root.name = "Player_%d" % peer_id
	var body := RunnerCharacter.new()
	body.name = "Body"
	root.add_child(body)
	# Role colour as a ring at the feet, brighter for the local player.
	var ring := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.55
	disc.bottom_radius = 0.55
	disc.height = 0.04
	ring.mesh = disc
	ring.position.y = 0.02
	var mat := StandardMaterial3D.new()
	mat.albedo_color = C.ROLE_STATS[role].color
	if peer_id == local_peer_id:
		mat.emission_enabled = true
		mat.emission = C.ROLE_STATS[role].color
		mat.emission_energy_multiplier = 0.8
	ring.material_override = mat
	root.add_child(ring)
	root.add_child(_make_label(2.2 if peer_id == local_peer_id else 1.9, ""))
	root.position.x = C.lane_to_x(C.LANE_COUNT / 2)
	add_child(root)
	return root


func _make_monster(attack: int) -> Node3D:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 1.6, 1.0)
	mesh.mesh = box
	mesh.position.y = 0.8
	mesh.material_override = _flat(MONSTER_COLOR[attack])
	root.add_child(mesh)
	# Show the attack zone: a low bar for LOW sweeps, a high bar for HIGH swings.
	if attack != C.Attack.BODY:
		var zone := MeshInstance3D.new()
		var bar := BoxMesh.new()
		bar.size = Vector3(C.LANE_WIDTH * 0.9, 0.15, 0.3)
		zone.mesh = bar
		zone.position = Vector3(0, 0.35 if attack == C.Attack.LOW else 1.7, -0.8)
		zone.material_override = _flat(Color(1, 0.9, 0.3))
		root.add_child(zone)
	root.add_child(_make_label(2.1, ""))
	add_child(root)
	return root


func _make_obstacle(kind: int) -> Node3D:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box := BoxMesh.new()
	match kind:
		C.Obstacle.TOWER:
			box.size = Vector3(1.2, 4.0, 1.2)
			mesh.position.y = 2.0
			mesh.material_override = _flat(Color(0.45, 0.45, 0.5))
		C.Obstacle.HURDLE:
			box.size = Vector3(C.LANE_WIDTH * 0.9, 0.7, 0.4)
			mesh.position.y = 0.35
			mesh.material_override = _flat(Color(0.6, 0.4, 0.2))
		C.Obstacle.BEAM:
			box.size = Vector3(C.LANE_WIDTH * 0.9, 0.4, 0.4)
			mesh.position.y = 1.5
			mesh.material_override = _flat(Color(0.55, 0.35, 0.15))
			for side in [-1, 1]:
				var post := MeshInstance3D.new()
				var pb := BoxMesh.new()
				pb.size = Vector3(0.15, 1.7, 0.15)
				post.mesh = pb
				post.position = Vector3(side * C.LANE_WIDTH * 0.42, 0.85, 0)
				post.material_override = mesh.material_override
				root.add_child(post)
	mesh.mesh = box
	root.add_child(mesh)
	add_child(root)
	return root


## A camp spans every lane: a lit patch of ground, a tent, and a fire.
func _make_camp() -> Node3D:
	var root := Node3D.new()
	var ground := MeshInstance3D.new()
	var slab := BoxMesh.new()
	slab.size = Vector3(C.LANE_COUNT * C.LANE_WIDTH + 1.0, 0.05, 3.0)
	ground.mesh = slab
	ground.position.y = 0.03
	ground.material_override = _flat(Color(0.35, 0.3, 0.2))
	root.add_child(ground)
	var tent := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(1.6, 1.4, 1.6)
	tent.mesh = prism
	tent.position = Vector3(-(C.LANE_COUNT * C.LANE_WIDTH) / 2.0 - 1.2, 0.7, 0)
	tent.material_override = _flat(Color(0.8, 0.75, 0.6))
	root.add_child(tent)
	var fire := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.25
	ball.height = 0.5
	fire.mesh = ball
	fire.position = Vector3((C.LANE_COUNT * C.LANE_WIDTH) / 2.0 + 1.0, 0.3, 0)
	var glow := _flat(Color(1.0, 0.55, 0.1))
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.5, 0.1)
	glow.emission_energy_multiplier = 3.0
	fire.material_override = glow
	root.add_child(fire)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.2)
	light.light_energy = 3.0
	light.omni_range = 8.0
	light.position = fire.position + Vector3(0, 0.6, 0)
	root.add_child(light)
	var label := _make_label(2.6, "CAMP")
	root.add_child(label)
	add_child(root)
	return root


func _flat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


func _make_label(height: float, text: String) -> Label3D:
	var label := Label3D.new()
	label.name = "Label"
	label.text = text
	label.position.y = height
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.008
	label.font_size = 48
	label.outline_size = 12
	return label


func _build_ground() -> void:
	for i in SLAB_COUNT:
		var slab := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(C.LANE_COUNT * C.LANE_WIDTH + 1.0, 0.2, SLAB_LENGTH - 0.3)
		slab.mesh = box
		slab.position.y = -0.1
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.22, 0.24, 0.3) if i % 2 == 0 else Color(0.28, 0.3, 0.36)
		slab.material_override = mat
		add_child(slab)
		_slabs.append(slab)
	# Lane guide lines.
	for lane in C.LANE_COUNT:
		var line := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.05, 0.02, SLAB_LENGTH * SLAB_COUNT)
		line.mesh = box
		line.position = Vector3(C.lane_to_x(lane), 0.01, -SLAB_LENGTH * SLAB_COUNT / 2.0 + SLAB_LENGTH)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.6, 0.6, 0.7)
		line.material_override = mat
		add_child(line)


func _build_environment() -> void:
	var cam := Camera3D.new()
	cam.fov = 60
	add_child(cam)
	cam.look_at_from_position(Vector3(0, 5.5, 9), Vector3(0, 0.5, -8))
	cam.current = true
	_camera = cam

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.1, 0.14)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.55, 0.7)
	e.ambient_light_energy = 0.6
	e.fog_enabled = true
	e.fog_light_color = Color(0.09, 0.1, 0.14)
	e.fog_density = 2.5 / (C.BASE_SPEED * zone.speed * zone.lookahead_seconds)
	env.environment = e
	add_child(env)
	_env = e
