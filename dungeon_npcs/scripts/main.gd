extends Node3D
## Builds the dungeon from an ASCII map using Kenney's Mini Dungeon models,
## spawns human and orc NPCs, and runs the interactions between them
## (chatting, trading, brawling, sitting, looting chests).

const NpcScript = preload("res://scripts/npc.gd")
const MailCheckerScript = preload("res://scripts/mail_checker.gd")
const MAIL_CARRIER_NAME := "Postie Pip"
const CalendarCheckerScript = preload("res://scripts/calendar_checker.gd")
const HERALD_NAME := "Herald Hruk"
const MODEL_DIR := "res://assets/models/"

# Map legend (one character = one 1x1 tile):
#   #  wall          .  floor        +  gate (doorway)
#   T  table         h  chair        C  chest
#   c  column        b  barrel       p  pot
#   r  rocks         S  stairs
const MAP := [
	"####################",
	"#.Th..#.......#....#",
	"#.....#..c..c.#..C.#",
	"#.....+.......+....#",
	"#..b..#..c..c.#..p.#",
	"###.###...b...##.###",
	"#.................r#",
	"#..h...............#",
	"#..T...####+###..b.#",
	"#..h...#......#....#",
	"#.C....#..p...+..C.#",
	"#......#......#...S#",
	"####################",
]
const WALKABLE := ".h+"

const HUMAN_NAMES := ["Alda", "Bram", "Cecily", "Doran", "Edda", "Fenn", "Gwen", "Hale"]
const ORC_NAMES := ["Grukk", "Mazog", "Throk", "Ugla", "Brakka", "Snarl", "Vorga", "Krul"]

# ---- Dialogue -------------------------------------------------------------
const CALL_OUT := {
	"human": ["Hey, %s!", "%s, wait up!", "Got a minute, %s?"],
	"orc": ["Oi! %s!", "%s! Come here!", "%s! Grah!"],
}
const GREET_BACK := {
	"human": ["Hello there.", "Oh, hi!", "What's new?"],
	"orc": ["Grah.", "What you want?", "Hrmph. Talk."],
}
const CHAT := {
	"human": [
		["Fine day for a dungeon crawl.", "Every day's fine down here."],
		["Have you looted the old chests?", "Mostly cobwebs, if you ask me."],
		["My feet are killing me.", "Try the chairs by the tables."],
		["These banners give me the creeps.", "They're just cloth. Probably."],
		["I heard orcs can't count past three.", "Then don't trade with them!"],
	],
	"orc": [
		["Grah! Hungry.", "Always hungry."],
		["Smash humans later?", "Smash humans later."],
		["Found shiny rock.", "Is coin? No? Bah."],
		["Human smell funny.", "Human say same about orc."],
		["Me guard gate today.", "Gate guard itself. Is gate."],
	],
}
const GOSSIP_REPLY := {
	"human": ["No! Really?", "I always knew it.", "Serves them right."],
	"orc": ["Hah! Good story.", "Grah. Not surprised.", "Me want to see that!"],
}
const TRADES := [
	["Potion, one coin. Interested?", "Deal!", "Too pricey."],
	["Want to buy a rusty key?", "Why not.", "Keep your junk."],
	["Shield for a coin. Good shield!", "Sounds fair.", "Not today."],
	["Map of the lower halls? One coin.", "Alright, hand it over.", "I know the way."],
]
const TAUNTS := {
	"human": ["Back off, orc!", "You want trouble?", "Not one step closer!"],
	"orc": ["Puny human!", "Me smash you!", "GRAAAH!"],
}
const WIN_LINES := {
	"human": ["Stay down!", "Ha! Too slow.", "Had enough?"],
	"orc": ["Me strongest!", "Orc wins!", "Hah! Squishy!"],
}
const SIT_LINES := {
	"human": ["Ahh, a seat at last.", "My feet thank me.", "Just a short rest..."],
	"orc": ["Chair good.", "Orc rest now.", "Hrrm. Comfy."],
}
const LOOT_LINES := {
	"human": ["Shiny!", "Ooh, gold!", "Finders keepers."],
	"orc": ["Mine now!", "Gold! Grah!", "Shiny for orc!"],
}
const EMPTY_LINES := {
	"human": ["Empty...", "Someone beat me to it."],
	"orc": ["Bah! Empty!", "Who take shiny?!"],
}

var grid_w := 0
var grid_h := 0
var astar := AStarGrid2D.new()
var rng := RandomNumberGenerator.new()
var npcs: Array = []
var chairs: Array = []   # { cell, dir, occupied }
var chests: Array = []   # { cell, anim, busy }
var gates: Array = []    # { cell, anim, open }
var recent_events: Array = []
var _scene_cache := {}

var camera: Camera3D
var cam_target := Vector3.ZERO
var cam_yaw := 0.0
var cam_dist := 11.5
var follow_index := -1

var log_label: RichTextLabel
var log_lines: Array = []

# Mail
var mail_checker: Node
var mail_carrier = null
var mail_status_label: Label
# Calendar
var calendar_checker: Node
var herald = null
var calendar_status_label: Label
var toast_panel: PanelContainer
var toast_label: Label
var _toast_left := 0.0


func _ready() -> void:
	if "--corner" in OS.get_cmdline_user_args():
		_dock_window_top_left()
	rng.randomize()
	grid_h = MAP.size()
	grid_w = (MAP[0] as String).length()
	_setup_environment()
	_build_dungeon()
	_setup_astar()
	_setup_camera()
	_setup_hud()
	for i in 4:
		spawn_npc("human")
		spawn_npc("orc")
	mail_carrier = spawn_npc("human", MAIL_CARRIER_NAME, "mail")
	herald = spawn_npc("orc", HERALD_NAME, "calendar")
	log_event("[color=#d8c8a0]The dungeon stirs...[/color]")
	_setup_mail()
	_setup_calendar()
	_maybe_auto_screenshot()


## `-- --corner` (used by the Windows startup shortcut): shrink the window to
## half the desktop's width and height and put it in the top-left corner.
func _dock_window_top_left() -> void:
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)  # excludes the taskbar
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	# Size (as % of the desktop) and offset come from user://window.cfg.
	var cfg := ConfigFile.new()
	if cfg.load("user://window.cfg") != OK:
		cfg.set_value("window", "width_percent", 33)
		cfg.set_value("window", "height_percent", 33)
		cfg.set_value("window", "x", 0)
		cfg.set_value("window", "y", 0)
		cfg.save("user://window.cfg")
	var wp := clampf(float(cfg.get_value("window", "width_percent", 33)), 10.0, 100.0)
	var hp := clampf(float(cfg.get_value("window", "height_percent", 33)), 10.0, 100.0)
	var offset := Vector2i(int(cfg.get_value("window", "x", 0)), int(cfg.get_value("window", "y", 0)))

	var size := Vector2i(roundi(usable.size.x * wp / 100.0), roundi(usable.size.y * hp / 100.0))
	DisplayServer.window_set_size(size)
	# Window position is the outer frame; nudge so the title bar is fully on-screen.
	var deco := DisplayServer.window_get_size_with_decorations() - DisplayServer.window_get_size()
	DisplayServer.window_set_size(size - deco)
	DisplayServer.window_set_position(usable.position + offset + Vector2i(deco.x / 2, deco.y - deco.x / 2))
	# Smaller window: shrink the 2D overlay (help, log, status, banner) to match.
	get_window().content_scale_factor = clampf(minf(wp, hp) / 50.0 * 0.75, 0.45, 1.0)
	print("WINDOW DOCKED: pos=", DisplayServer.window_get_position(), " size=", DisplayServer.window_get_size(), " usable=", usable)


## Testing aid: `godot --path . -- --screenshot=C:/out.png` saves a screenshot after 12 s and quits.
func _maybe_auto_screenshot() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			var out := arg.trim_prefix("--screenshot=")
			var delay := 12.0
			for a in OS.get_cmdline_user_args():
				if a.begins_with("--screenshot-delay="):
					delay = a.trim_prefix("--screenshot-delay=").to_float()
			await wait(delay)
			get_viewport().get_texture().get_image().save_png(out)
			get_tree().quit()


# ---- Grid helpers ---------------------------------------------------------

func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3(cell.x, 0.0, cell.y)


func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(roundi(p.x), roundi(p.z))


func char_at(cell: Vector2i) -> String:
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_w or cell.y >= grid_h:
		return "#"
	var row: String = MAP[cell.y]
	return row[cell.x]


func is_walkable(cell: Vector2i) -> bool:
	return WALKABLE.contains(char_at(cell))


func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if not is_walkable(from) or not is_walkable(to):
		return empty
	return astar.get_id_path(from, to)


func is_cell_claimed(cell: Vector2i, except = null) -> bool:
	for n in npcs:
		if n == except:
			continue
		if n.current_cell() == cell or n.dest_cell == cell:
			return true
	return false


func random_free_cell(except = null) -> Vector2i:
	for i in 200:
		var c := Vector2i(rng.randi_range(0, grid_w - 1), rng.randi_range(0, grid_h - 1))
		if char_at(c) == "." and not is_cell_claimed(c, except):
			return c
	return Vector2i(1, 1)


## A free floor cell next to `cell`, closest to `npc`. Returns null if none.
func free_neighbor(cell: Vector2i, npc):
	var best = null
	var best_d := INF
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			if dx == 0 and dz == 0:
				continue
			var c := cell + Vector2i(dx, dz)
			if char_at(c) != "." or is_cell_claimed(c, npc):
				continue
			# Diagonal spots only if both side cells are open (no talking through wall corners).
			if dx != 0 and dz != 0:
				if not is_walkable(cell + Vector2i(dx, 0)) or not is_walkable(cell + Vector2i(0, dz)):
					continue
			var d: float = cell_to_world(c).distance_to(npc.position)
			if d < best_d:
				best_d = d
				best = c
	return best


# ---- World building -------------------------------------------------------

func make_model(model_name: String) -> Node3D:
	if not _scene_cache.has(model_name):
		_scene_cache[model_name] = load(MODEL_DIR + model_name + ".glb")
	var scene: PackedScene = _scene_cache[model_name]
	return scene.instantiate() as Node3D


func find_anim(node: Node) -> AnimationPlayer:
	var found := node.find_children("*", "AnimationPlayer", true, false)
	if found.is_empty():
		return null
	return found[0] as AnimationPlayer


func place(model_name: String, cell: Vector2i, yaw := 0.0) -> Node3D:
	var n := make_model(model_name)
	n.position = cell_to_world(cell)
	n.rotation.y = yaw
	add_child(n)
	return n


## Rotation that makes a Kenney model (which faces +Z) face `dir`.
func yaw_for(dir: Vector2i) -> float:
	return atan2(float(dir.x), float(dir.y))


func _dir_to(cell: Vector2i, chars: String) -> Vector2i:
	for d in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, -1)]:
		if chars.contains(char_at(cell + d)):
			return d
	return Vector2i(0, 1)


func _touches_floor(cell: Vector2i) -> bool:
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var c := cell + Vector2i(dx, dz)
			if c.x >= 0 and c.y >= 0 and c.x < grid_w and c.y < grid_h and char_at(c) != "#":
				return true
	return false


func _build_dungeon() -> void:
	var banner_spots: Array = []
	for z in grid_h:
		for x in grid_w:
			var cell := Vector2i(x, z)
			var ch := char_at(cell)
			if ch == "#":
				if _touches_floor(cell):
					place("wall", cell)
				continue

			place("floor-detail" if rng.randf() < 0.18 else "floor", cell)
			match ch:
				".":
					if char_at(cell + Vector2i(0, -1)) == "#":
						banner_spots.append(cell)
				"T":
					place("table", cell)
				"c":
					place("column", cell)
				"b":
					place("barrel", cell, rng.randf() * TAU)
				"p":
					place("pot", cell, rng.randf() * TAU)
				"r":
					place("rocks", cell, rng.randf() * TAU)
				"S":
					place("stairs", cell, PI)
				"h":
					var to_table := _dir_to(cell, "T")
					place("chair", cell, yaw_for(to_table))
					chairs.append({"cell": cell, "dir": to_table, "occupied": false})
				"C":
					var open_dir := _dir_to(cell, ".")
					var chest := place("chest", cell, yaw_for(open_dir))
					chests.append({"cell": cell, "anim": find_anim(chest), "busy": false})
				"+":
					var walls_left_right := char_at(cell + Vector2i(-1, 0)) == "#"
					var gate := place("gate", cell, 0.0 if walls_left_right else PI / 2.0)
					gates.append({"cell": cell, "anim": find_anim(gate), "open": false})

	# Hang a few banners on north walls, each lit by a warm torch-like light.
	banner_spots.shuffle()
	for i in mini(6, banner_spots.size()):
		var cell: Vector2i = banner_spots[i]
		place("banner", cell)
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.62, 0.32)
		light.light_energy = 1.6
		light.omni_range = 3.5
		light.position = cell_to_world(cell) + Vector3(0, 1.0, -0.15)
		add_child(light)


func _setup_astar() -> void:
	astar.region = Rect2i(0, 0, grid_w, grid_h)
	astar.cell_size = Vector2(1, 1)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	for z in grid_h:
		for x in grid_w:
			if not is_walkable(Vector2i(x, z)):
				astar.set_point_solid(Vector2i(x, z), true)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.09, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.78)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 30, 0)
	sun.light_energy = 0.85
	sun.shadow_enabled = true
	add_child(sun)


# ---- Camera & HUD ---------------------------------------------------------

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 45.0
	add_child(camera)
	camera.current = true
	cam_target = Vector3((grid_w - 1) * 0.5, 0.0, (grid_h - 1) * 0.5)
	_update_camera()


func _update_camera() -> void:
	var offset := Vector3(0, cam_dist * 0.82, cam_dist * 0.57).rotated(Vector3.UP, cam_yaw)
	camera.position = cam_target + offset
	camera.look_at(cam_target, Vector3.UP)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var help := Label.new()
	help.text = "WASD / arrows: pan    Q / E: rotate    Wheel: zoom    Tab: follow next NPC    Esc: free camera    1 / 2: spawn human / orc"
	help.position = Vector2(12, 8)
	help.add_theme_color_override("font_color", Color(0.92, 0.92, 0.97))
	help.add_theme_color_override("font_outline_color", Color.BLACK)
	help.add_theme_constant_override("outline_size", 5)
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(help)

	var panel := PanelContainer.new()
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 12
	panel.offset_top = -168
	panel.offset_right = 452
	panel.offset_bottom = -12
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)

	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.scroll_following = true
	log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(log_label)

	# Mail status, top right.
	mail_status_label = Label.new()
	mail_status_label.text = "Mail: starting..."
	mail_status_label.anchor_left = 1.0
	mail_status_label.anchor_right = 1.0
	mail_status_label.offset_left = -460
	mail_status_label.offset_right = -12
	mail_status_label.offset_top = 34
	mail_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	mail_status_label.add_theme_color_override("font_color", Color(1.0, 0.83, 0.42))
	mail_status_label.add_theme_color_override("font_outline_color", Color.BLACK)
	mail_status_label.add_theme_constant_override("outline_size", 5)
	mail_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(mail_status_label)

	calendar_status_label = mail_status_label.duplicate()
	calendar_status_label.text = "Calendar: starting..."
	calendar_status_label.offset_top = 58
	calendar_status_label.add_theme_color_override("font_color", Color(0.82, 0.68, 1.0))
	layer.add_child(calendar_status_label)

	# "You've got mail" banner, top centre.
	toast_panel = PanelContainer.new()
	toast_panel.anchor_left = 0.5
	toast_panel.anchor_right = 0.5
	toast_panel.offset_left = -300
	toast_panel.offset_right = 300
	toast_panel.offset_top = 90
	toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tsb := StyleBoxFlat.new()
	tsb.bg_color = Color(0.16, 0.12, 0.05, 0.92)
	tsb.border_color = Color(1.0, 0.83, 0.42)
	tsb.set_border_width_all(2)
	tsb.set_corner_radius_all(8)
	tsb.set_content_margin_all(12)
	toast_panel.add_theme_stylebox_override("panel", tsb)
	toast_panel.visible = false
	layer.add_child(toast_panel)
	toast_label = Label.new()
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_label.add_theme_font_size_override("font_size", 20)
	toast_label.add_theme_color_override("font_color", Color(1.0, 0.93, 0.75))
	toast_panel.add_child(toast_label)


func show_toast(text: String, seconds := 9.0) -> void:
	toast_label.text = text
	toast_panel.visible = true
	_toast_left = seconds


func log_event(msg: String) -> void:
	log_lines.append(msg)
	while log_lines.size() > 6:
		log_lines.pop_front()
	log_label.text = "\n".join(PackedStringArray(log_lines))


func remember(event_text: String) -> void:
	recent_events.append(event_text)
	while recent_events.size() > 5:
		recent_events.pop_front()


func cname(n) -> String:
	var col := "#8fc1ff" if n.kind == "human" else "#9be37a"
	if n.role == "mail":
		col = "#ffd36b"
	elif n.role == "calendar":
		col = "#d1adff"
	return "[color=%s]%s[/color]" % [col, n.npc_name]


func _process(delta: float) -> void:
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		move.z -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		move.z += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		move.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		move.x += 1
	if move != Vector3.ZERO:
		follow_index = -1
		cam_target += move.normalized().rotated(Vector3.UP, cam_yaw) * 8.0 * delta
	if Input.is_key_pressed(KEY_Q):
		cam_yaw -= 1.6 * delta
	if Input.is_key_pressed(KEY_E):
		cam_yaw += 1.6 * delta
	if follow_index >= 0 and follow_index < npcs.size():
		var target: Vector3 = npcs[follow_index].position
		cam_target = cam_target.lerp(target, minf(1.0, 4.0 * delta))
	cam_target.x = clampf(cam_target.x, -2.0, grid_w + 1.0)
	cam_target.z = clampf(cam_target.z, -2.0, grid_h + 1.0)
	_update_camera()
	_update_gates()
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			toast_panel.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist = maxf(4.0, cam_dist - 1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = minf(26.0, cam_dist + 1.0)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				spawn_npc("human")
			KEY_2:
				spawn_npc("orc")
			KEY_TAB:
				if not npcs.is_empty():
					follow_index = (follow_index + 1) % npcs.size()
					log_event("Camera follows %s." % cname(npcs[follow_index]))
			KEY_ESCAPE:
				follow_index = -1


func _update_gates() -> void:
	for g in gates:
		var gate_pos := cell_to_world(g["cell"])
		var someone_near := false
		for n in npcs:
			if n.position.distance_to(gate_pos) < 1.4:
				someone_near = true
				break
		if someone_near != g["open"]:
			g["open"] = someone_near
			var ap: AnimationPlayer = g["anim"]
			if ap:
				ap.play("open" if someone_near else "close")


# ---- NPCs -----------------------------------------------------------------

func spawn_npc(kind: String, forced_name := "", role := ""):
	var pool: Array = HUMAN_NAMES if kind == "human" else ORC_NAMES
	var used := {}
	for n in npcs:
		used[n.npc_name] = true
	var npc_name := forced_name
	for candidate in pool:
		if npc_name != "":
			break
		if not used.has(candidate):
			npc_name = candidate
			break
	if npc_name == "":
		npc_name = "%s %d" % [pool.pick_random(), npcs.size()]

	var npc = NpcScript.new()
	npc.setup(self, kind, npc_name)
	npc.role = role
	npc.position = cell_to_world(random_free_cell())
	add_child(npc)
	npcs.append(npc)
	if npcs.size() > 10:
		log_event("%s wanders into the dungeon." % cname(npc))
	return npc


func find_partner(npc):
	var candidates: Array = []
	for n in npcs:
		if n != npc and n.is_available() and n.position.distance_to(npc.position) < 10.0:
			candidates.append(n)
	if candidates.is_empty():
		return null
	candidates.sort_custom(func(a, b): return a.position.distance_to(npc.position) < b.position.distance_to(npc.position))
	return candidates[rng.randi_range(0, mini(1, candidates.size() - 1))]


func wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func toss_coin(from: Vector3, to: Vector3) -> void:
	var coin := make_model("coin")
	coin.scale = Vector3.ONE * 0.6
	add_child(coin)
	var start := from + Vector3(0, 0.5, 0)
	var finish := to + Vector3(0, 0.5, 0)
	coin.position = start
	var tw := create_tween()
	tw.tween_method(func(t: float) -> void:
		coin.position = start.lerp(finish, t) + Vector3(0, sin(t * PI) * 0.9, 0)
		coin.rotation.y = t * TAU * 2.0
	, 0.0, 1.0, 0.8)
	tw.tween_callback(coin.queue_free)


# Meeting: walk up to someone, then chat / trade / fight depending on who they are.
func try_start_meeting(npc) -> bool:
	var partner = find_partner(npc)
	if partner == null:
		return false
	var spot = free_neighbor(partner.current_cell(), npc)
	if spot == null:
		return false
	npc.reserved = true
	partner.stop_and_wait()
	if not npc.go_to(spot, func() -> void: run_meeting(npc, partner)):
		npc.reserved = false
		partner.reserved = false
		return false
	if rng.randf() < 0.6:
		npc.say(CALL_OUT[npc.kind].pick_random() % partner.npc_name, 1.6)
	return true


func run_meeting(a, b) -> void:
	a.begin_interaction(b.position)
	b.begin_interaction(a.position)
	if a.kind == b.kind:
		await _chat(a, b)
	else:
		var grudge: int = a.opinion_of(b) + b.opinion_of(a)
		var fight_chance := clampf(0.4 - grudge * 0.12, 0.1, 0.85)
		if rng.randf() < fight_chance:
			await _fight(a, b)
		else:
			await _trade(a, b)
	a.end_interaction()
	b.end_interaction()


func _chat(a, b) -> void:
	a.say(CALL_OUT[a.kind].pick_random() % b.npc_name)
	a.play_once("interact-right")
	await wait(1.6)
	b.say(GREET_BACK[b.kind].pick_random())
	b.play_once("emote-yes")
	await wait(1.6)

	var gossip: Array = recent_events.filter(func(e): return not e.contains(a.npc_name))
	var line: Array
	if not gossip.is_empty() and rng.randf() < 0.5:
		line = ["Did you hear? %s!" % gossip.pick_random(), GOSSIP_REPLY[b.kind].pick_random()]
	else:
		line = CHAT[a.kind].pick_random()
	a.say(line[0], 2.4)
	a.play_once("interact-left")
	await wait(2.4)
	b.say(line[1], 2.2)
	b.play_once("emote-yes" if rng.randf() < 0.7 else "emote-no")
	await wait(2.2)

	a.change_opinion(b, 1)
	b.change_opinion(a, 1)
	log_event("%s and %s had a chat." % [cname(a), cname(b)])


func _trade(seller, buyer) -> void:
	var offer: Array = TRADES.pick_random()
	seller.say(offer[0], 2.2)
	seller.play_once("interact-right")
	await wait(2.2)
	var wants: bool = rng.randf() < 0.6 + buyer.opinion_of(seller) * 0.1
	if wants and buyer.gold > 0:
		buyer.say(offer[1])
		buyer.play_once("emote-yes")
		await wait(0.6)
		buyer.gold -= 1
		seller.gold += 1
		toss_coin(buyer.position, seller.position)
		await wait(1.2)
		seller.say("Pleasure doing business.")
		seller.play_once("emote-yes")
		seller.change_opinion(buyer, 2)
		buyer.change_opinion(seller, 1)
		log_event("%s bought something from %s." % [cname(buyer), cname(seller)])
		remember("%s traded with %s" % [buyer.npc_name, seller.npc_name])
	else:
		buyer.say(offer[2] if buyer.gold > 0 else "I'm broke.")
		buyer.play_once("emote-no")
		await wait(1.8)
		seller.say("Your loss.")
		seller.change_opinion(buyer, -1)
		log_event("%s turned down %s's offer." % [cname(buyer), cname(seller)])
	await wait(1.4)


func _fight(a, b) -> void:
	a.say(TAUNTS[a.kind].pick_random(), 1.4)
	await wait(1.2)
	b.say(TAUNTS[b.kind].pick_random(), 1.4)
	await wait(1.0)
	log_event("[color=#ff9a7a]%s and %s started a brawl![/color]" % [cname(a), cname(b)])

	var hp := {a.npc_name: 3, b.npc_name: 3}
	var attacker = a
	var defender = b
	while true:
		attacker.face(defender.position)
		attacker.play_once(["attack-melee-right", "attack-melee-left", "attack-kick-right"].pick_random())
		await wait(0.35)
		var hit_chance := 0.65 if attacker.kind == "orc" else 0.6
		if rng.randf() < hit_chance:
			defender.flinch(attacker.position)
			hp[defender.npc_name] -= 1
			if hp[defender.npc_name] <= 0:
				break
		await wait(0.6)
		var tmp = attacker
		attacker = defender
		defender = tmp

	var winner = attacker
	var loser = defender
	loser.knock_out()
	await wait(0.5)
	winner.play_once("emote-yes")
	winner.say(WIN_LINES[winner.kind].pick_random())
	winner.gold += 1 if loser.gold > 0 else 0
	loser.gold = maxi(0, loser.gold - 1)
	log_event("[color=#ff9a7a]%s knocked out %s![/color]" % [cname(winner), cname(loser)])
	remember("%s knocked out %s" % [winner.npc_name, loser.npc_name])
	loser.change_opinion(winner, -3)
	winner.change_opinion(loser, -1)
	await wait(3.5)
	loser.recover()
	loser.say("Next time, %s..." % winner.npc_name)
	await wait(1.8)


# Sitting on a chair for a while.
func try_start_sit(npc) -> bool:
	var free: Array = chairs.filter(func(c): return not c["occupied"])
	if free.is_empty():
		return false
	var chair: Dictionary = free.pick_random()
	if is_cell_claimed(chair["cell"], npc):
		return false
	chair["occupied"] = true
	npc.reserved = true
	if not npc.go_to(chair["cell"], func() -> void: run_sit(npc, chair)):
		chair["occupied"] = false
		npc.reserved = false
		return false
	return true


func run_sit(npc, chair: Dictionary) -> void:
	var dir: Vector2i = chair["dir"]
	npc.begin_interaction(npc.position + Vector3(dir.x, 0, dir.y))
	npc.play_loop("sit")
	npc.say(SIT_LINES[npc.kind].pick_random())
	log_event("%s sat down for a rest." % cname(npc))
	await wait(rng.randf_range(5.0, 9.0))
	chair["occupied"] = false
	npc.end_interaction()


# Opening a chest.
func try_start_loot(npc) -> bool:
	var free: Array = chests.filter(func(c): return not c["busy"])
	if free.is_empty():
		return false
	var chest: Dictionary = free.pick_random()
	var spot = free_neighbor(chest["cell"], npc)
	if spot == null:
		return false
	chest["busy"] = true
	npc.reserved = true
	if not npc.go_to(spot, func() -> void: run_loot(npc, chest)):
		chest["busy"] = false
		npc.reserved = false
		return false
	return true


func run_loot(npc, chest: Dictionary) -> void:
	var chest_pos := cell_to_world(chest["cell"])
	var ap: AnimationPlayer = chest["anim"]
	npc.begin_interaction(chest_pos)
	npc.play_once("interact-right")
	if ap:
		ap.play("open")
	await wait(0.9)
	if rng.randf() < 0.6:
		toss_coin(chest_pos, npc.position)
		await wait(0.8)
		npc.play_once("pick-up")
		npc.say(LOOT_LINES[npc.kind].pick_random())
		npc.gold += 1
		log_event("%s found a coin in a chest." % cname(npc))
	else:
		npc.play_once("emote-no")
		npc.say(EMPTY_LINES[npc.kind].pick_random())
	await wait(1.6)
	if ap:
		ap.play("close")
	chest["busy"] = false
	npc.end_interaction()


# ---- Messengers (mail carrier & calendar herald) --------------------------
# Each messenger NPC has an announce_queue of { speech, toast, log, gossip }.
# When something is queued, the NPC drops casual activities and announces it.

const MESSENGER_OPENERS := {
	"mail": "Mail call!",
	"calendar": "Hear ye, hear ye!",
}


func queue_announcement(npc, item: Dictionary) -> void:
	if npc == null:
		return
	npc.announce_queue.append(item)
	npc.hurry_to_announce()


func _setup_mail() -> void:
	mail_checker = MailCheckerScript.new()
	mail_checker.status_changed.connect(func(t: String) -> void: mail_status_label.text = t)
	mail_checker.baseline.connect(_on_mail_baseline)
	mail_checker.new_mail.connect(_on_new_mail)
	add_child(mail_checker)


func _on_mail_baseline(count: int) -> void:
	if count <= 0:
		return
	var s := "" if count == 1 else "s"
	queue_announcement(mail_carrier, {
		"speech": "You've got %d unread letter%s waiting!" % [count, s],
		"toast": "%d unread email%s in your Gmail" % [count, s],
		"log": "%d unread emails waiting." % count,
	})


func _on_new_mail(sender: String, subject: String) -> void:
	queue_announcement(mail_carrier, {
		"speech": "Mail for you!\nFrom %s:\n\"%s\"" % [sender, subject],
		"toast": "New email from %s\n%s" % [sender, subject],
		"log": "brought a letter from [b]%s[/b]." % sender,
		"gossip": "%s brought a letter from %s" % [mail_carrier.npc_name, sender],
	})


func _setup_calendar() -> void:
	calendar_checker = CalendarCheckerScript.new()
	calendar_checker.status_changed.connect(func(t: String) -> void: calendar_status_label.text = t)
	calendar_checker.announcement.connect(func(speech: String, toast: String, log_text: String) -> void:
		queue_announcement(herald, {"speech": speech, "toast": toast, "log": log_text}))
	add_child(calendar_checker)


func try_start_announcement(npc) -> bool:
	if npc.announce_queue.is_empty():
		return false
	npc.reserved = true
	follow_index = npcs.find(npc)
	run_announcement(npc)
	return true


func run_announcement(npc) -> void:
	npc.begin_interaction(camera.global_position)
	npc.play_once("emote-yes")
	npc.say(MESSENGER_OPENERS.get(npc.role, "Listen up!"), 1.4)
	DisplayServer.window_request_attention()
	await wait(1.4)
	while not npc.announce_queue.is_empty():
		var item: Dictionary = npc.announce_queue.pop_front()
		npc.face(camera.global_position)
		npc.play_once("interact-right")
		npc.say(item["speech"], 7.0)
		show_toast(item["toast"])
		log_event("%s: %s" % [cname(npc), item["log"]])
		if item.has("gossip"):
			remember(item["gossip"])
		await wait(7.5)
	npc.play_once("emote-yes")
	npc.say("That's all for now!", 2.0)
	await wait(2.0)
	if follow_index == npcs.find(npc):
		follow_index = -1
	npc.end_interaction()
