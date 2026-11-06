extends Node3D
## One dungeon inhabitant (human or orc). Walks the tile grid, decides what to
## do next, plays the Kenney character animations and shows speech bubbles.
## The interactions themselves are run by main.gd so both NPCs stay in sync.

enum State { IDLE, WALK, BUSY }

const WALK_SPEED := 1.3
const LOOPING := ["idle", "walk", "sprint", "sit"]

var main
var kind := "human"
var npc_name := ""
var gold := 0
## "" for ordinary NPCs, "mail" for the Gmail carrier, "calendar" for the herald.
var role := ""
## Messages waiting to be announced: { speech, toast, log, gossip }.
var announce_queue: Array = []
var state := State.IDLE
## True while this NPC is promised to an activity (a meeting, a chair, a chest).
var reserved := false
var path: Array[Vector2i] = []
var dest_cell := Vector2i(-1, -1)
var on_arrive := Callable()
var think_timer := 1.0
var face_dir := Vector3(0, 0, 1)
## How this NPC feels about others, by name: -5 (hates) .. 5 (friends).
var opinions := {}

var model: Node3D
var anim: AnimationPlayer
var name_label: Label3D
var bubble: Label3D
var bubble_timer := 0.0
var base_anim := "idle"
var _one_shot_left := 0.0


func setup(p_main, p_kind: String, p_name: String) -> void:
	main = p_main
	kind = p_kind
	npc_name = p_name
	name = p_name
	gold = main.rng.randi_range(0, 2)


func _ready() -> void:
	model = main.make_model("character-" + kind)
	add_child(model)
	anim = main.find_anim(model)
	if anim:
		for a in LOOPING:
			if anim.has_animation(a):
				anim.get_animation(a).loop_mode = Animation.LOOP_LINEAR

	var name_color := Color(0.62, 0.8, 1.0) if kind == "human" else Color(0.65, 0.92, 0.5)
	if role == "mail":
		name_color = Color(1.0, 0.83, 0.42)
		# A small chest worn on the back as a mail bag.
		var bag: Node3D = main.make_model("chest")
		bag.scale = Vector3.ONE * 0.42
		bag.position = Vector3(0, 0.3, -0.24)
		model.add_child(bag)
	elif role == "calendar":
		name_color = Color(0.82, 0.68, 1.0)
		# A banner carried on the back, like a town crier's standard.
		var flag: Node3D = main.make_model("banner")
		flag.scale = Vector3.ONE * 0.7
		flag.position = Vector3(0, 0.14, 0.12)
		model.add_child(flag)
	name_label = _make_label(1.0, 28, name_color)
	bubble = _make_label(1.22, 40, Color(1, 1, 1))
	bubble.visible = false
	bubble.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM  # multi-line speech grows upward
	_update_name()

	play_loop("idle")
	think_timer = main.rng.randf_range(0.5, 3.0)
	model.rotation.y = main.rng.randf() * TAU
	face_dir = Vector3(sin(model.rotation.y), 0, cos(model.rotation.y))


func _make_label(height: float, size: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.pixel_size = 0.0095
	l.font_size = size
	l.outline_size = 12
	l.modulate = color
	l.outline_modulate = Color(0, 0, 0, 0.9)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.width = 420.0
	l.render_priority = 10
	l.outline_render_priority = 9
	l.position.y = height
	add_child(l)
	return l


func _update_name() -> void:
	if role == "mail":
		name_label.text = "%s · mail" % npc_name
	elif role == "calendar":
		name_label.text = "%s · calendar" % npc_name
	else:
		name_label.text = "%s · %dg" % [npc_name, gold]


func _process(delta: float) -> void:
	if bubble_timer > 0.0:
		bubble_timer -= delta
		if bubble_timer <= 0.0:
			bubble.visible = false

	if _one_shot_left > 0.0:
		_one_shot_left -= delta
		if _one_shot_left <= 0.0 and base_anim != "" and anim:
			anim.play(base_anim, 0.2)

	match state:
		State.IDLE:
			if not reserved:
				think_timer -= delta
				if think_timer <= 0.0:
					_decide()
		State.WALK:
			_step(delta)

	var yaw := atan2(face_dir.x, face_dir.z)
	model.rotation.y = lerp_angle(model.rotation.y, yaw, minf(1.0, 10.0 * delta))


# ---- Decisions & movement -------------------------------------------------

func _decide() -> void:
	think_timer = main.rng.randf_range(1.5, 4.0)
	if role != "" and main.try_start_announcement(self):
		return
	var roll: float = main.rng.randf()
	if roll < 0.4:
		if main.try_start_meeting(self):
			return
	elif roll < 0.52:
		if main.try_start_sit(self):
			return
	elif roll < 0.64:
		if main.try_start_loot(self):
			return
	_wander()


func _wander() -> void:
	var here := current_cell()
	for i in 20:
		var c: Vector2i = main.random_free_cell(self)
		if absi(c.x - here.x) + absi(c.y - here.y) <= 8 and go_to(c):
			return
	think_timer = 1.0


func current_cell() -> Vector2i:
	return main.world_to_cell(position)


## Walk to `cell`; `callback` runs on arrival. Returns false if unreachable.
func go_to(cell: Vector2i, callback := Callable()) -> bool:
	var p: Array[Vector2i] = main.find_path(current_cell(), cell)
	if p.is_empty():
		return false
	path = p  # starts with the current cell, so we first re-centre on it
	dest_cell = cell
	on_arrive = callback
	state = State.WALK
	play_loop("walk")
	return true


func _step(delta: float) -> void:
	if path.is_empty():
		_arrive()
		return
	var target: Vector3 = main.cell_to_world(path[0])
	var to := target - position
	to.y = 0.0
	var step := WALK_SPEED * delta
	if to.length() <= step:
		position = Vector3(target.x, position.y, target.z)
		path.remove_at(0)
		if path.is_empty():
			_arrive()
	else:
		face_dir = to.normalized()
		position += face_dir * step


func _arrive() -> void:
	state = State.IDLE
	dest_cell = Vector2i(-1, -1)
	play_loop("idle")
	if on_arrive.is_valid():
		var cb := on_arrive
		on_arrive = Callable()
		cb.call()


## Is this NPC free to be approached by someone else?
func is_available() -> bool:
	if not announce_queue.is_empty():
		return false
	return not reserved and (state == State.IDLE or state == State.WALK)


## Someone wants to talk: finish the current step and stand still.
func stop_and_wait() -> void:
	reserved = true
	on_arrive = Callable()
	if state == State.WALK:
		var here := current_cell()
		path.clear()
		path.append(here)
		dest_cell = here


func begin_interaction(look_at_pos: Vector3) -> void:
	state = State.BUSY
	path.clear()
	face(look_at_pos)
	play_loop("idle")


func end_interaction() -> void:
	state = State.IDLE
	reserved = false
	dest_cell = Vector2i(-1, -1)
	play_loop("idle")
	think_timer = main.rng.randf_range(1.5, 4.0)
	if not announce_queue.is_empty():
		think_timer = 0.2
	_update_name()


## Something to announce: drop whatever we're casually doing and say it.
## (If busy in a chat or fight, the announcement starts as soon as that ends.)
func hurry_to_announce() -> void:
	if reserved:
		return
	think_timer = 0.0
	if state == State.WALK:
		on_arrive = Callable()
		var here := current_cell()
		path.clear()
		path.append(here)
		dest_cell = here


func face(p: Vector3) -> void:
	var d := p - position
	d.y = 0.0
	if d.length() > 0.01:
		face_dir = d.normalized()


# ---- Animation & speech ---------------------------------------------------

func play_loop(anim_name: String) -> void:
	base_anim = anim_name
	_one_shot_left = 0.0
	if anim and anim.has_animation(anim_name) and anim.current_animation != anim_name:
		anim.play(anim_name, 0.2)


func play_once(anim_name: String) -> void:
	if anim and anim.has_animation(anim_name):
		anim.play(anim_name, 0.1)
		_one_shot_left = anim.get_animation(anim_name).length


func say(text: String, duration := 2.0) -> void:
	bubble.text = text
	bubble.visible = true
	bubble_timer = duration


func flinch(from_pos: Vector3) -> void:
	var away := position - from_pos
	away.y = 0.0
	away = away.normalized() * 0.15
	var home := position
	var tw := create_tween()
	tw.tween_property(self, "position", home + away, 0.08)
	tw.tween_property(self, "position", home, 0.18)
	if main.rng.randf() < 0.5:
		say(["Oof!", "Ow!", "Hey!"].pick_random(), 0.8)


func knock_out() -> void:
	base_anim = ""  # hold the last frame of "die"
	if anim and anim.has_animation("die"):
		anim.play("die", 0.1)
	_one_shot_left = 0.0
	say("Ugh...", 1.5)


func recover() -> void:
	play_loop("idle")


# ---- Relationships --------------------------------------------------------

func opinion_of(other) -> int:
	return opinions.get(other.npc_name, 0)


func change_opinion(other, amount: int) -> void:
	opinions[other.npc_name] = clampi(opinion_of(other) + amount, -5, 5)
