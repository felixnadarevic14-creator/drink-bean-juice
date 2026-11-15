extends CollisionShape3D

@export_file("*.tscn") var target_scene := "res://node_3d.tscn"
@export var player_group := "Player"
@export var sensor_height := 0.1  # how far above the floor counts as "touching"

var _triggered := false

func _ready():
	# Build a sensor area using this same shape, nudged slightly up.
	var area := Area3D.new()
	area.position.y = sensor_height
	area.collision_mask = 1 | 2 | 4 | 8  # watch the first few layers; add your player's if it's higher
	add_child(area)

	var sensor_shape := CollisionShape3D.new()
	sensor_shape.shape = shape
	area.add_child(sensor_shape)

	area.body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if _triggered or not body.is_in_group(player_group):
		return
	_triggered = true
	get_tree().call_deferred("change_scene_to_file", target_scene)
