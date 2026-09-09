class_name RunnerCharacter
extends Node3D
## The player model: the Mixamo farmer from animations/, with every clip merged into one
## AnimationPlayer. Runs in place (forward root motion is stripped), faces down the track,
## and is scaled to a fixed height so the FBX unit scale does not matter.

const CLIPS := {
	"run": "res://animations/running.fbx",
	"jump": "res://animations/jump.fbx",
	"slide": "res://animations/slide.fbx",
	"attack": "res://animations/attack.fbx",
	"magic": "res://animations/magic.fbx",
}
const SOURCE_ANIM := "mixamo_com"   # Mixamo names every clip this
const TARGET_HEIGHT := 1.75
## One-shots are squeezed to roughly the sim window so the pose matches what the server
## thinks is happening (jump/slide last 0.6 s).
const ONE_SHOT_SECONDS := { "jump": 0.7, "slide": 0.8, "attack": 0.55, "magic": 0.9 }

static var _library: AnimationLibrary   # built once, shared by every character

var run_speed_scale := 1.0   # pace multiplier; 3x zones run the legs 3x faster

var _player: AnimationPlayer
var _body: Node3D
var _current := ""


func _ready() -> void:
	_body = load(CLIPS.run).instantiate()
	_body.rotation.y = PI   # Mixamo faces +Z; the party runs toward -Z
	add_child(_body)
	_player = _body.get_node("AnimationPlayer")
	if _library == null:
		_library = _build_library()
	_player.add_animation_library("clips", _library)
	_player.animation_finished.connect(_on_finished)
	_fit_height()
	play_run()


func play_run() -> void:
	_current = "run"
	_player.play("clips/run", 0.15, run_speed_scale)


func play_jump() -> void:
	_one_shot("jump")


func play_slide() -> void:
	_one_shot("slide")


func play_attack() -> void:
	_one_shot("attack")


func play_magic() -> void:
	_one_shot("magic")


func set_pace(multiplier: float) -> void:
	run_speed_scale = maxf(0.5, multiplier)
	if _current == "run":
		_player.speed_scale = run_speed_scale


func _one_shot(clip: String) -> void:
	# Attacks interrupt anything; a jump or slide does not cut off a swing already playing.
	if _current == "attack" and clip != "attack":
		return
	_current = clip
	var length: float = _library.get_animation(clip).length
	_player.play("clips/" + clip, 0.08, length / ONE_SHOT_SECONDS[clip])


func _on_finished(_name: StringName) -> void:
	if _current != "run":
		play_run()


## Scale the whole character so the rig stands TARGET_HEIGHT tall, whatever units the FBX
## used. Measured from the bones in rest pose: a skinned mesh's AABB is not trustworthy.
func _fit_height() -> void:
	var skeleton: Skeleton3D = null
	for child in _body.find_children("*", "Skeleton3D", true, false):
		skeleton = child
		break
	if skeleton == null:
		return
	var head := skeleton.find_bone("mixamorig_Head")
	var toe := skeleton.find_bone("mixamorig_LeftToeBase")
	if head < 0 or toe < 0:
		return
	var skel_xform: Transform3D = _body.global_transform.affine_inverse() * skeleton.global_transform
	var head_y: float = (skel_xform * skeleton.get_bone_global_rest(head).origin).y
	var toe_y: float = (skel_xform * skeleton.get_bone_global_rest(toe).origin).y
	var height := (head_y - toe_y) * 1.12   # the head bone sits below the crown
	if height > 0.001:
		var k := TARGET_HEIGHT / height
		scale = Vector3(k, k, k)
		_body.position.y = -toe_y   # feet on the ground (body-local units, parent scale applies)


## Pull every clip's animation into one library, in-place and named.
static func _build_library() -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	for clip in CLIPS:
		var scene: PackedScene = load(CLIPS[clip])
		var inst := scene.instantiate()
		var ap: AnimationPlayer = inst.get_node("AnimationPlayer")
		var anim: Animation = ap.get_animation(SOURCE_ANIM).duplicate(true)
		_strip_forward_motion(anim)
		anim.loop_mode = Animation.LOOP_LINEAR if clip == "run" else Animation.LOOP_NONE
		lib.add_animation(clip, anim)
		inst.free()
	return lib


## Mixamo clips move the hips forward along Z; hold Z at the first key so the
## character runs on the spot while the world scrolls.
static func _strip_forward_motion(anim: Animation) -> void:
	for t in anim.get_track_count():
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		if not str(anim.track_get_path(t)).ends_with("Hips"):
			continue
		var n := anim.track_get_key_count(t)
		if n == 0:
			continue
		var z0: float = (anim.track_get_key_value(t, 0) as Vector3).z
		for k in n:
			var v: Vector3 = anim.track_get_key_value(t, k)
			anim.track_set_key_value(t, k, Vector3(v.x, v.y, z0))
