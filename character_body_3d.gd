extends CharacterBody3D
## Bouncy ball player with spring-driven squash & stretch.
##
## Scene setup:
##   Player (CharacterBody3D, this script)
##   ├─ CollisionShape3D   (SphereShape3D, radius = ball_radius)
##   ├─ Visual             (Node3D pivot) -> assign to `ball_mesh`
##   │   └─ Guy            (your model; rotate/offset it here freely)
##   └─ Camera3D           (or a SpringArm3D holding it, for third person)
##
## Only the visual mesh deforms. The collision shape and body never scale,
## so physics stays stable and the camera doesn't warp.
## The mesh's editor rotation and scale are preserved.

@export_group("Movement")
@export var speed := 9.0
@export var ground_accel := 45.0
@export var air_accel := 14.0
@export var ground_friction := 18.0     # slowdown on the ground with no input
@export var jump_speed := 10
@export var mouse_sensitivity := 0.002
@export var cam: Camera3D

@export_group("Bounce")
@export_range(0.0, 1.2) var bounciness := 0.8   # 1.0 = no energy lost
@export var min_bounce_speed := 2.0              # weaker bounces than this just settle
@export var jump_boost := 4.0                    # extra kick if you press jump as you land
@export var max_bounce_speed := 25.0
@export var jump_buffer_time := 0.15

@export_group("Air & Wall")
@export var air_jumps := 1                # midair jumps before you need to touch something
@export var air_jump_speed := 6.5         # floaty "puff" upward, weaker than a real jump
@export_range(0.0, 1.2) var wall_bounciness := 0.85
@export var wall_jump_push := 8.0         # how hard a wall jump shoves you away
@export var wall_jump_up := 7.5
@export var wall_coyote_time := 0.12      # grace period after leaving a wall

@export_group("Squash & Stretch")
@export var ball_mesh: Node3D
@export var ball_radius := 0.5
@export var spring_stiffness := 320.0   # higher = faster jiggle
@export var spring_damping := 8.0       # lower = wobbles longer
@export var squash_per_impact := 3.50    # how hard impacts squash it
@export var air_stretch := 0.05        # stretch per m/s of speed while airborne
@export var axis_follow := 10.0         # how fast stretch turns to face the velocity
@export var min_squash := 0.35
@export var max_stretch := 1.7

@export_group("Facing")
@export var face_camera := true        # the Guy always glares into the camera
@export var face_camera_pitch := true  # false = only turn left/right, stay upright
@export var face_turn_speed := 20.0    # higher = snappier; 0 = instant
## Extra rotation (degrees) to fix a model whose face points the wrong way.
## Face points down?  try X = -90.  Points up? X = 90.  Backwards? Y = 180.
@export var model_rotation_fix := Vector3.ZERO

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var pitch := 0.0

var _squash := 1.0            # scale along _squash_axis (volume preserved sideways)
var _squash_vel := 0.0
var _squash_axis := Vector3.UP
var _contact_normal := Vector3.UP
var _contact_weight := 0.0
var _jump_buffer := 0.0
var _air_jumps_left := 0
var _wall_normal := Vector3.ZERO
var _wall_timer := 0.0
var _mesh_base_basis := Basis.IDENTITY   # editor rotation + scale of the visual
var _mesh_offset := Vector3.ZERO
var _face_basis := Basis.IDENTITY
var _spawn_transform := Transform3D.IDENTITY
var _spawn_pitch := 0.0


func _ready():
    if cam == null:
        cam = find_child("Camera3D", true, false)
    if ball_mesh == null:
        var meshes = find_children("*", "MeshInstance3D", true, false)
        if meshes.size() > 0:
            ball_mesh = meshes[0]
    if ball_mesh:
        # Capture the visual's rotation/scale/offset relative to the Player,
        # including any rotation on parent nodes (top_level would drop those).
        var rel := global_transform.affine_inverse() * ball_mesh.global_transform
        _mesh_base_basis = rel.basis
        _mesh_offset = rel.origin
        print("Squash/stretch is driving: ", get_path_to(ball_mesh))
        # Drive the mesh in world space so body yaw doesn't fight the squash axis.
        ball_mesh.top_level = true
    _spawn_transform = global_transform
    _spawn_pitch = pitch
    _ensure_actions()
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _ensure_actions():
    var binds = {
        "move_forward": KEY_W, "move_backward": KEY_S,
        "move_left": KEY_A, "move_right": KEY_D, "jump": KEY_SPACE,
        "reset player": KEY_R,
    }
    for action in binds:
        if not InputMap.has_action(action):
            InputMap.add_action(action)
            var ev = InputEventKey.new()
            ev.physical_keycode = binds[action]
            InputMap.action_add_event(action, ev)


func _input(event):
    if event.is_action_pressed("reset player"):
        reset_player()
    if event.is_action_pressed("ui_cancel"):
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        rotate_y(-event.relative.x * mouse_sensitivity)
        pitch = clamp(pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-70), deg_to_rad(70))
        if cam:
            cam.rotation.x = pitch


func _physics_process(delta):
    _jump_buffer = max(_jump_buffer - delta, 0.0)
    if Input.is_action_just_pressed("jump"):
        _jump_buffer = jump_buffer_time

    _wall_timer = max(_wall_timer - delta, 0.0)

    var on_floor := is_on_floor()
    if on_floor:
        _air_jumps_left = air_jumps
    elif is_on_wall():
        _wall_normal = get_wall_normal()
        _wall_timer = wall_coyote_time
    if not on_floor:
        velocity.y -= gravity * delta

    # Acceleration-based steering, so bounces off walls aren't instantly erased.
    var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
    var wish = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized() * speed
    var hvel = Vector3(velocity.x, 0, velocity.z)
    if wish != Vector3.ZERO:
        hvel = hvel.move_toward(wish, (ground_accel if on_floor else air_accel) * delta)
    elif on_floor:
        hvel = hvel.move_toward(Vector3.ZERO, ground_friction * delta)
    velocity.x = hvel.x
    velocity.z = hvel.z

    if _jump_buffer > 0.0:
        if on_floor:
            # Normal jump from the ground.
            velocity.y = jump_speed
            _jump_buffer = 0.0
            _squash_axis = up_direction
            _squash_vel += jump_speed * squash_per_impact * 0.6   # launch stretch
        elif _wall_timer > 0.0:
            _wall_jump(_wall_normal)
        elif _air_jumps_left > 0:
            # Air jump: a floaty puff. It always lifts you a bit and keeps
            # some of your upward speed, but it's weaker than a ground jump.
            _air_jumps_left -= 1
            _jump_buffer = 0.0
            velocity.y = min(max(velocity.y, 0.0) * 0.4 + air_jump_speed, max_bounce_speed)
            _squash_axis = up_direction
            _squash_vel += air_jump_speed * squash_per_impact * 0.8

    var pre_vel := velocity
    move_and_slide()
    _handle_bounce(pre_vel)
    _update_deform(delta)


func _handle_bounce(pre_vel: Vector3):
    # Find the hardest hit this frame.
    var impact := 0.0
    var normal := Vector3.ZERO
    for i in get_slide_collision_count():
        var n := get_slide_collision(i).get_normal()
        var hit := -pre_vel.dot(n)
        if hit > impact:
            impact = hit
            normal = n
    if impact <= 0.0:
        return

    # Squash along the hit normal, proportional to how hard we hit.
    _squash_axis = normal
    _contact_normal = normal
    _contact_weight = 1.0
    _squash_vel -= impact * squash_per_impact

    # Reflect only the normal part of the velocity; keep the sideways part.
    var is_floor := normal.angle_to(up_direction) <= floor_max_angle
    var is_wall := not is_floor and absf(normal.dot(up_direction)) < 0.3
    if is_floor:
        _air_jumps_left = air_jumps
    if is_wall:
        _wall_normal = normal
        _wall_timer = wall_coyote_time
        if _jump_buffer > 0.0:
            # Jump pressed as you hit the wall: kick off it, adding some of the impact speed.
            _wall_jump(normal, impact)
            return

    var v_tangent := pre_vel - normal * pre_vel.dot(normal)
    var out_speed := impact * (wall_bounciness if is_wall else bounciness)
    if is_floor and _jump_buffer > 0.0:
        out_speed = max(out_speed + jump_boost, jump_speed)
        _jump_buffer = 0.0
    elif out_speed < min_bounce_speed:
        velocity = v_tangent   # too weak, settle down
        return

    velocity = v_tangent + normal * min(out_speed, max_bounce_speed)


func _wall_jump(n: Vector3, impact := 0.0):
    _jump_buffer = 0.0
    _wall_timer = 0.0
    _air_jumps_left = air_jumps   # touching a wall refreshes your air jump
    var along := velocity - n * velocity.dot(n)
    along.y = 0.0
    velocity = along + n * min(wall_jump_push + impact * wall_bounciness * 0.5, max_bounce_speed)
    velocity.y = max(velocity.y, wall_jump_up)
    # Squish against the wall, then spring off it.
    _squash_axis = n
    _contact_normal = n
    _contact_weight = 1.0
    _squash_vel -= wall_jump_push * squash_per_impact * 0.5


func _update_deform(delta: float):
    if ball_mesh == null:
        return

    var spd := velocity.length()
    var target := 1.0

    if is_on_floor():
        _contact_normal = get_floor_normal()
        _contact_weight = 1.0
    else:
        _contact_weight *= exp(-15.0 * delta)
        if spd > 1.0:
            # Stretch along the direction of travel. The axis is sign-agnostic,
            # so flip the target rather than swinging through zero.
            var vdir := velocity / spd
            if vdir.dot(_squash_axis) < 0.0:
                vdir = -vdir
            _squash_axis = _squash_axis.slerp(vdir, 1.0 - exp(-axis_follow * delta)).normalized()
            target = 1.0 + min(spd * air_stretch, max_stretch - 1.0)

    # Damped spring, which gives the jiggle after impacts.
    var accel := spring_stiffness * (target - _squash) - spring_damping * _squash_vel
    _squash_vel += accel * delta
    _squash += _squash_vel * delta
    if _squash < min_squash or _squash > max_stretch:
        _squash = clamp(_squash, min_squash, max_stretch)
        _squash_vel *= -0.3   # soft rebound off the limits

    # Volume-preserving scale along an arbitrary axis: S = p*I + (s - p) * n nᵀ
    var n := _squash_axis
    var s := _squash
    var p := 1.0 / sqrt(s)
    var k := s - p
    var S := Basis(
        Vector3(p, 0, 0) + n * (k * n.x),
        Vector3(0, p, 0) + n * (k * n.y),
        Vector3(0, 0, p) + n * (k * n.z))

    # Keep the contact side planted while squashed: shift the center by how much
    # the ellipsoid's extent toward the surface changed.
    var c := _contact_normal
    var d := n.dot(c)
    var extent := ball_radius * sqrt(s * s * d * d + p * p * (1.0 - d * d))
    var offset := c * (extent - ball_radius) * _contact_weight

    var center := global_transform * _mesh_offset + offset
    var facing := _get_facing(center, delta)
    ball_mesh.global_transform = Transform3D(S * facing * Basis.from_euler(model_rotation_fix * (PI / 180.0)) * _mesh_base_basis, center)


func _get_facing(center: Vector3, delta: float) -> Basis:
    # Default: turn with the player's yaw.
    var target_basis := global_transform.basis.orthonormalized()

    if face_camera and cam:
        var to_cam := cam.global_position - center
        if not face_camera_pitch:
            to_cam.y = 0.0
        # Skip if the camera is basically inside the Guy or straight above/below him,
        # where looking_at has no stable answer.
        if to_cam.length() > 0.01 and absf(to_cam.normalized().dot(Vector3.UP)) < 0.99:
            # use_model_front = true: the model's +Z (Godot's model-front convention)
            # points at the camera.
            target_basis = Basis.looking_at(to_cam, Vector3.UP, true)

    if face_turn_speed <= 0.0:
        _face_basis = target_basis
    else:
        var t := 1.0 - exp(-face_turn_speed * delta)
        _face_basis = Basis(_face_basis.get_rotation_quaternion().slerp(
            target_basis.get_rotation_quaternion(), t))
    return _face_basis


## Put the player back where it started and clear all motion.
func reset_player():
    global_transform = _spawn_transform
    velocity = Vector3.ZERO
    pitch = _spawn_pitch
    if cam:
        cam.rotation.x = pitch
    _squash = 1.0
    _squash_vel = 0.0
    _squash_axis = Vector3.UP
    _contact_normal = Vector3.UP
    _contact_weight = 0.0
    _jump_buffer = 0.0
    _air_jumps_left = air_jumps
    _wall_timer = 0.0
