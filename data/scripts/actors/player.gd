# Copyright © 2016-2020 Hugo Locurcio and contributors - MIT License
# See `LICENSE.md` included in the source distribution for details.

extends Node2D

# Maximal running speed
const MAX_SPEED = 275 * 60

# Jump speed (velocity set when jumping)
const JUMP_SPEED = 350 * 60

# Jetpack speed
const JETPACK_SPEED = 17.5 * 60

## Horizontal speed bonus when using jetpack (factor)
const JETPACK_BONUS = 1.15

# Speed of bullets
const BULLET_SPEED = 1250

# Bullet inaccuracy (lower is more accurate)
const BULLET_SPREAD = 8

# Time in seconds between each bullet fire
const BULLET_REFIRE = 0.4

# Delay after dying required to wait before being allowed to respawn
const RESPAWN_DELAY = 2.5

# The speed at which higher falling speeds will deal damage to the player
const FALL_DAMAGE_THRESHOLD = 700

# Lower factors deal more damage
const FALL_DAMAGE_FACTOR = 6

# Using a timer for double-tap shooting fixes issues related to "lingering" input
# while allowing full-auto shooting. I don't know why.
var double_tap_shoot_timer := 0.0

puppet var puppet_position := Vector2()
puppet var puppet_linear_velocity := Vector2()
puppet var puppet_using_jetpack := false

onready var velocity = Vector2(0, 0)
onready var velocity_new = Vector2(0, 0)
onready var speed = 0
onready var bullet_scene = preload("res://data/scenes/misc/bullet.tscn")
onready var offset = Vector2(0, 0)
onready var relative_mouse_pos = Vector2(0, 0)
onready var player := $Player as RigidBody2D
onready var camera := $Player/Camera2D as Camera2D
onready var crosshair := $Crosshair as Sprite
onready var player_sprite := $Smoothing2D/Sprite as Sprite
onready var preloader := $ResourcePreloader as ResourcePreloader
onready var animation_player := $Player/AnimationPlayer as AnimationPlayer
onready var crosshair_color_gradient := preloader.get_resource("crosshair_color_gradient") as Gradient
onready var sprite_base_offset := player_sprite.position.y


func _ready() -> void:
	# Make our camera active, but not other players'
	camera.current = is_network_master()

	puppet_position = player.position

	# Set the number of enemies present in the level
	Game.kills_total = get_node("/root/Level/Enemies").get_child_count()

	# Set the number of items present in the level
	Game.items_total = get_node("/root/Level/Items").get_child_count()

	respawned()

	# Show HUD when player is in scene
	Game.show_hud()

	Input.set_mouse_mode(Input.MOUSE_MODE_CONFINED)
	hide_hardware_mouse_cursor()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_FOCUS_IN:
			call_deferred("hide_hardware_mouse_cursor")


func hide_hardware_mouse_cursor() -> void:
	if not is_network_master():
		return

	# Revert back to the default cursor. This is required; otherwise, the cursor will only change once.
	# (Only tested on Linux.)
	Input.set_custom_mouse_cursor(null)
	# Use a transparent cursor texture to hide the hardware cursor.
	Input.set_custom_mouse_cursor(preload("res://data/textures/transparent.png"))


func _process(delta):
	if is_network_master():
		double_tap_shoot_timer += delta
		# Mouse position/offset computations (for gun and crosshair)
		offset = -get_viewport().get_canvas_transform().origin * get_node("Player/Camera2D").get_zoom()  # Get the offset
		relative_mouse_pos = get_viewport().get_mouse_position() * get_node("Player/Camera2D").get_zoom() + offset  # And add it to the mouse position
		get_node("Player/Gun").look_at(relative_mouse_pos)
		# Move crosshair at mouse position
		get_node("Crosshair").set_position(relative_mouse_pos)

	# Add bobbing to the player sprite when moving and not airborne.
	if is_touching_ground():
		var velocity := player.linear_velocity.x if is_network_master() else puppet_linear_velocity.x
		player_sprite.position.y = sprite_base_offset - abs(sin(OS.get_ticks_msec() * 0.01) * velocity * 0.024)


func _physics_process(delta):
	if animation_player.current_animation == "walk":
		var velocity := player.linear_velocity.x if is_network_master() else puppet_linear_velocity.x
		# Don't change the animation speed if currently displaying a shoot or pain animation.
		animation_player.set_speed_scale(min(abs(velocity) * 0.009, 2))

	if is_network_master():
		# Move the camera to partially follow the crosshair.
		# This helps the player get a better view on their surroundings.
		camera.global_position = lerp(player.global_position, crosshair.global_position, 0.25)

		# Increase time (shown on HUD)
		Game.time += delta

		if Game.health <= 0 and Game.status == Game.STATUS_ALIVE:
			die()
		# Change crosshair color depending on health, and ammo bar value depending on ammo
		if Game.health > 0:
			get_node("Crosshair").set_modulate(crosshair_color_gradient.interpolate(Game.health / 100.0))
		else:
			get_node("Crosshair").set_visible(false)
		get_node("Crosshair/ProgressBar").set_value(Game.ammo)

		# Flip player sprite if the crosshair is at the right of the player (player faces right),
		# else don't flip it (player faces left)
		if get_node("Crosshair").get_position().x > get_node("Player").get_position().x:
			get_node("Smoothing2D/Sprite").set_flip_h(true)
		else:
			get_node("Smoothing2D/Sprite").set_flip_h(false)

		if Game.status == Game.STATUS_ALIVE:
			# Health regeneration (1 per second)
			if Game.health > 0:
				Game.health = min(Game.health + delta, 100)

			velocity = get_node("Player").get_linear_velocity()

			if Input.is_action_pressed("move_left"):
				speed = clamp(speed - MAX_SPEED * 6 * delta, -MAX_SPEED, MAX_SPEED)
			elif Input.is_action_pressed("move_right"):
				speed = clamp(speed + MAX_SPEED * 6 * delta, -MAX_SPEED, MAX_SPEED)
			else:
				# Friction (when the player doesn't press any movement key)
				speed *= 0.85

			# Set the new velocity
			get_node("Player").set_linear_velocity(Vector2(speed * delta, velocity.y))

			# Falling damage
			if velocity_new.y - velocity.y >= FALL_DAMAGE_THRESHOLD:
				rpc("damage", get_tree().get_network_unique_id(), (velocity_new.y - velocity.y - FALL_DAMAGE_THRESHOLD) / FALL_DAMAGE_FACTOR)

			# Jumping
			if Input.is_action_pressed("move_up") and is_touching_ground():
				get_node("Player").set_linear_velocity(Vector2(velocity.x, -JUMP_SPEED * delta))

			# Jetpack (uses fuel)
			if Input.is_action_pressed("jetpack") and Game.fuel > 0:
				# Jump automatically if the player can jump.
				# This way, the player can benefit from the jetpack more.
				if is_touching_ground():
					get_node("Player").set_linear_velocity(Vector2(velocity.x, -JUMP_SPEED * delta))
				else:
					get_node("Player").set_linear_velocity(Vector2(JETPACK_BONUS * speed * delta, velocity.y - JETPACK_SPEED * delta))
					Game.fuel = max(0, Game.fuel - 50 * delta)
					get_node("Player/JetpackParticles").set_emitting(true)
					rset("puppet_using_jetpack", true)

			# Fuel regeneration
			if not Input.is_action_pressed("jetpack"):
				Game.fuel = min(100, Game.fuel + 6 * delta)
				# Disable jetpack particles
				get_node("Player/JetpackParticles").set_emitting(false)
				rset("puppet_using_jetpack", false)


			# Disable jetpack particles if having no fuel (even when pressing the key)
			if Game.fuel <= 1:
				get_node("Player/JetpackParticles").set_emitting(false)
				rset("puppet_using_jetpack", false)

			# Firing weapons
			if Input.is_action_pressed("attack") and Game.ammo >= 1 and get_node("BulletTimer").get_time_left() == 0:
				animation_player.play("shoot")
				animation_player.playback_speed = 1.0
				var bullet_position: Vector2 = get_node("Player/Gun").get_global_position()
				var bullet_velocity := Vector2(BULLET_SPEED, 0).rotated(get_node("Player/Gun").get_rotation() - deg2rad(BULLET_SPREAD / 2.0 + randf() * BULLET_SPREAD))
				rpc("fire_bullet", get_tree().get_network_unique_id(), bullet_position, bullet_velocity)

			elif Input.is_action_pressed("attack") and get_node("BulletTimer").get_time_left() == 0:
				Sound.play(Sound.Type.NON_POSITIONAL, self, preload("res://data/sounds/no_ammo.wav"), -12, rand_range(0.95, 1.05))
				if Game.weapon == Game.WEAPON_PISTOL:
					get_node("BulletTimer").set_wait_time(BULLET_REFIRE)
				elif Game.weapon == Game.WEAPON_CHAINGUN:
					get_node("BulletTimer").set_wait_time(BULLET_REFIRE / 3)
				get_node("BulletTimer").start()

			# Falling very fast kills the player
			if velocity.y >= 2000:
				rpc("damage", get_tree().get_network_unique_id(), 1000)

			velocity_new = get_node("Player").get_linear_velocity()

			# Synchronize my player's position to other players.
			rset_unreliable("puppet_position", player.position)
			# For animation purposes only.
			rset_unreliable("puppet_linear_velocity", player.linear_velocity)
	else:
		player.position = puppet_position
		get_node("Player/JetpackParticles").set_emitting(puppet_using_jetpack)

remotesync func fire_bullet(player_id: int, pos: Vector2, velocity: Vector2) -> void:
	# Bullet will be owned by the server.
	var bullet = bullet_scene.instance()
	bullet.set_position(pos)
	add_child(bullet)
	bullet.get_node("RigidBody2D").set_linear_velocity(velocity)

	# Play the sound positionally only when it's our client firing.
	# This prevents the sound from being located in only one of the player's ears.
	Sound.play(
			Sound.Type.NON_POSITIONAL if is_network_master() else Sound.Type.POSITIONAL_2D,
			self,
			preload("res://data/sounds/pistol.wav"),
			-12,
			rand_range(0.95, 1.05)
	)

	if is_network_master():
		Game.ammo -= 1
		if Game.weapon == Game.WEAPON_PISTOL:
			get_node("BulletTimer").set_wait_time(BULLET_REFIRE)
		elif Game.weapon == Game.WEAPON_CHAINGUN:
			get_node("BulletTimer").set_wait_time(BULLET_REFIRE / 3)
		get_node("BulletTimer").start()

func _input(event):
	if not is_network_master():
		return

	if OS.has_touchscreen_ui_hint() and event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.doubleclick:
			var action := InputEventAction.new()
			action.action = "attack"
			action.pressed = true
			Input.parse_input_event(action)
			double_tap_shoot_timer = 0.0

		if not mb.pressed and double_tap_shoot_timer > 0.0:
			var action := InputEventAction.new()
			action.action = "attack"
			Input.parse_input_event(action)

	var zoom = get_node("Player/Camera2D").get_zoom().x
	if event.is_action_pressed("zoom_in"):
		get_node("Player/Camera2D").set_zoom(Vector2(max(0.25, zoom - 0.125), max(0.25, zoom - 0.125)))
	if event.is_action_pressed("zoom_out"):
		get_node("Player/Camera2D").set_zoom(Vector2(min(2, zoom + 0.125), min(2, zoom + 0.125)))
	if event.is_action_pressed("zoom_reset"):
		get_node("Player/Camera2D").set_zoom(Vector2(0.5, 0.5))

	# Change weapon
	if event.is_action_pressed("weapon_previous"):
		Game.weapon = wrapi(Game.weapon - 1, 1, 3)
	if event.is_action_pressed("weapon_next"):
		Game.weapon = wrapi(Game.weapon + 1, 1, 3)

	# Respawn when clicking, if dead, after a delay of 2.5 seconds
	if Game.status == Game.STATUS_DEAD and event.is_action_pressed("attack") and get_node("RespawnTimer").get_time_left() == 0:
		get_tree().change_scene("res://data/scenes/levels/" + str(Game.level_to_play) + ".tscn")

	# Suicide (default key: Ctrl+K)
	if event.is_action_pressed("suicide") and Game.status == Game.STATUS_ALIVE:
		rpc("damage", get_tree().get_network_unique_id(), 1000)


# Returns true if the player is touching ground
func is_touching_ground():
	return get_node("Player/RayCast2D").is_colliding()


remotesync func damage(player_id: int, points: int):
	var ap := get_node("/root/Level/Players/%d/Player/AnimationPlayer" % player_id)
	ap.play("pain")
	ap.playback_speed = 1

	var positional: int = Sound.Type.NON_POSITIONAL if is_network_master() else Sound.Type.POSITIONAL_2D
	if Game.health <= 0:
		Sound.play(positional, self, preload("res://data/sounds/player_death.wav"), 0.5, 1.15)
	else:
		Sound.play(positional, self, preload("res://data/sounds/player_hurt.wav"), 0, rand_range(0.95, 1.05))

	if is_network_master():
		# If player has armor, divide damage by half on health and deplete armor
		if Game.armor > 0:
			Game.armor = max(0, Game.armor - points / 2)
			Game.health = max(0, Game.health - points / 2)
		# If player has no armor, deplete health
		else:
			Game.health = max(0, Game.health - points)


# Called when the player dies
func die():
	if is_network_master():
		Game.status = Game.STATUS_DEAD
		get_node("RespawnTimer").set_wait_time(RESPAWN_DELAY)
		get_node("RespawnTimer").start()


# Called when the player respawns
func respawned():
	Game.health = 100.0
	Game.armor = 0
	Game.ammo = 25
	Game.weapon = Game.WEAPON_PISTOL
	Game.fuel = 100.0

	Game.time = 0.0
	Game.kills = 0
	Game.items = 0
	Game.credits = 0
	Game.status = Game.STATUS_ALIVE


func _animation_finished(anim_name: String) -> void:
	match anim_name:
		"pain", "shoot":
			# Go back to the previous walk animation.
			animation_player.play("walk")
