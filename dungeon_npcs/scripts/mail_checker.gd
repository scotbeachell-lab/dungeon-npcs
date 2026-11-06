extends Node
## Polls a Gmail inbox over IMAP and reports new unread mail.
## It opens the inbox read-only (EXAMINE) and fetches headers with BODY.PEEK,
## so nothing is ever marked as read, moved or deleted.
##
## Settings live in user://gmail.cfg, which is OUTSIDE the project folder:
##   Windows: %APPDATA%\Godot\app_userdata\Dungeon NPCs\gmail.cfg
## See README.md for how to fill it in.

signal status_changed(text: String)
## First successful check: how many unread mails were already waiting.
signal baseline(unread_count: int)
## A new unread mail appeared since the last check.
signal new_mail(sender: String, subject: String)

const CONFIG_PATH := "user://gmail.cfg"
const HOST := "imap.gmail.com"
const PORT := 993
const TIMEOUT_MS := 20000
const MAX_ANNOUNCE := 5

var email := ""
var app_password := ""
var interval := 60.0

var _known := {}
var _first_check := true
var _tls: StreamPeerTLS
var _tag := 0


func _ready() -> void:
	if "--fake-mail" in OS.get_cmdline_user_args():
		_fake_mail()
		return
	if not _load_config():
		if "--mail-probe" in OS.get_cmdline_user_args():
			_probe()
		return
	_loop()


func config_path_on_disk() -> String:
	return ProjectSettings.globalize_path(CONFIG_PATH)


func _load_config() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		cfg.set_value("gmail", "email", "")
		cfg.set_value("gmail", "app_password", "")
		cfg.set_value("gmail", "check_every_seconds", 60)
		cfg.save(CONFIG_PATH)
	email = str(cfg.get_value("gmail", "email", "")).strip_edges()
	app_password = str(cfg.get_value("gmail", "app_password", "")).replace(" ", "").strip_edges()
	interval = maxf(20.0, float(cfg.get_value("gmail", "check_every_seconds", 60)))
	if email == "" or app_password == "":
		status_changed.emit("Mail: not set up (see README.md)")
		return false
	return true


func _loop() -> void:
	while is_inside_tree():
		await _check_once()
		await get_tree().create_timer(interval).timeout


func _check_once() -> void:
	status_changed.emit("Mail: checking...")
	var err: String = await _open()
	if err != "":
		_finish("Mail: " + err)
		return

	var r: Dictionary = await _cmd('LOGIN "%s" "%s"' % [_quote(email), _quote(app_password)])
	if not r["ok"]:
		_finish("Mail: sign-in failed - check email / app password")
		return
	r = await _cmd("EXAMINE INBOX")
	if not r["ok"]:
		_finish("Mail: couldn't open inbox")
		return
	r = await _cmd("UID SEARCH UNSEEN")
	if not r["ok"]:
		_finish("Mail: search failed")
		return

	var uids: Array[int] = []
	for line in (r["text"] as String).split("\r\n"):
		if line.begins_with("* SEARCH"):
			for part in line.substr(8).split(" ", false):
				uids.append(part.to_int())

	var fresh: Array[int] = []
	for u in uids:
		if not _known.has(u):
			fresh.append(u)
		_known[u] = true

	if _first_check:
		_first_check = false
		baseline.emit(uids.size())
	else:
		fresh.sort()
		for u in fresh.slice(maxi(0, fresh.size() - MAX_ANNOUNCE)):
			var f: Dictionary = await _cmd("UID FETCH %d (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])" % u)
			if f["ok"]:
				var h := _parse_headers(f["text"])
				new_mail.emit(h[0], h[1])

	await _cmd("LOGOUT")
	_finish("Mail: %d unread - checked %s" % [uids.size(), Time.get_time_string_from_system().substr(0, 5)])


func _finish(status: String) -> void:
	if _tls:
		_tls.disconnect_from_stream()
		_tls = null
	status_changed.emit(status)


# ---- Low-level IMAP over TLS ----------------------------------------------

func _open() -> String:
	var tcp := StreamPeerTCP.new()
	if tcp.connect_to_host(HOST, PORT) != OK:
		return "can't reach Gmail"
	var start := Time.get_ticks_msec()
	while true:
		tcp.poll()
		var s := tcp.get_status()
		if s == StreamPeerTCP.STATUS_CONNECTED:
			break
		if s == StreamPeerTCP.STATUS_ERROR or s == StreamPeerTCP.STATUS_NONE:
			return "can't reach Gmail"
		if Time.get_ticks_msec() - start > TIMEOUT_MS:
			return "connection timed out"
		await get_tree().process_frame

	_tls = StreamPeerTLS.new()
	if _tls.connect_to_stream(tcp, HOST, TLSOptions.client()) != OK:
		return "secure connection failed"
	while true:
		_tls.poll()
		var st := _tls.get_status()
		if st == StreamPeerTLS.STATUS_CONNECTED:
			break
		if st != StreamPeerTLS.STATUS_HANDSHAKING:
			return "secure connection failed"
		if Time.get_ticks_msec() - start > TIMEOUT_MS:
			return "connection timed out"
		await get_tree().process_frame

	# Server greeting: "* OK Gimap ready ..."
	var greeting: String = await _read_until(func(t: String) -> bool: return t.contains("\r\n"))
	if not greeting.begins_with("* OK"):
		return "unexpected server reply"
	return ""


## Sends one tagged command and waits for its tagged OK/NO/BAD reply.
func _cmd(command: String) -> Dictionary:
	if _tls == null:
		return {"ok": false, "text": ""}
	_tag += 1
	var tag := "a%d" % _tag
	_tls.put_data((tag + " " + command + "\r\n").to_utf8_buffer())
	var text: String = await _read_until(func(t: String) -> bool: return _tag_line_start(t, tag) >= 0)
	var pos := _tag_line_start(text, tag)
	if pos < 0:
		return {"ok": false, "text": text}
	return {"ok": text.substr(pos).begins_with(tag + " OK"), "text": text}


func _tag_line_start(t: String, tag: String) -> int:
	var pos := -1
	if t.begins_with(tag + " "):
		pos = 0
	else:
		var i := t.find("\r\n" + tag + " ")
		if i >= 0:
			pos = i + 2
	if pos >= 0 and t.find("\r\n", pos) >= 0:
		return pos
	return -1


func _read_until(done: Callable) -> String:
	var data := PackedByteArray()
	var start := Time.get_ticks_msec()
	while _tls != null:
		_tls.poll()
		var n := _tls.get_available_bytes()
		if n > 0:
			var res := _tls.get_data(n)
			if res[0] == OK:
				data.append_array(res[1])
			if done.call(data.get_string_from_ascii()):
				return data.get_string_from_utf8()
		elif _tls.get_status() != StreamPeerTLS.STATUS_CONNECTED:
			break
		if Time.get_ticks_msec() - start > TIMEOUT_MS:
			break
		await get_tree().process_frame
	return data.get_string_from_utf8()


func _quote(s: String) -> String:
	return s.replace("\\", "\\\\").replace("\"", "\\\"")


# ---- Header parsing ---------------------------------------------------------

func _parse_headers(text: String) -> Array:
	var unfolded := text.replace("\r\n ", " ").replace("\r\n\t", " ")
	var sender := "someone"
	var subject := "(no subject)"
	for line in unfolded.split("\r\n"):
		var l := line.strip_edges()
		var lower := l.to_lower()
		if lower.begins_with("from:"):
			sender = _friendly_sender(_decode_mime(l.substr(5).strip_edges()))
		elif lower.begins_with("subject:"):
			var s := _decode_mime(l.substr(8).strip_edges())
			if s != "":
				subject = s
	if subject.length() > 80:
		subject = subject.substr(0, 77) + "..."
	return [sender, subject]


func _friendly_sender(from: String) -> String:
	var lt := from.find("<")
	if lt > 0:
		var display_name := from.substr(0, lt).strip_edges().trim_prefix("\"").trim_suffix("\"").strip_edges()
		if display_name != "":
			return display_name
	return from.replace("<", "").replace(">", "").strip_edges()


## Decodes RFC 2047 words like =?UTF-8?B?...?= and =?UTF-8?Q?...?=
func _decode_mime(s: String) -> String:
	s = RegEx.create_from_string("\\?=\\s+=\\?").sub(s, "?==?", true)
	var re := RegEx.create_from_string("=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=")
	var out := ""
	var last := 0
	for m in re.search_all(s):
		out += s.substr(last, m.get_start() - last)
		var payload := m.get_string(3)
		var bytes := PackedByteArray()
		if m.get_string(2).to_upper() == "B":
			bytes = Marshalls.base64_to_raw(payload)
		else:
			var i := 0
			while i < payload.length():
				var c := payload[i]
				if c == "_":
					bytes.append(32)
				elif c == "=" and i + 2 < payload.length() + 1:
					bytes.append(payload.substr(i + 1, 2).hex_to_int())
					i += 2
				else:
					bytes.append(c.unicode_at(0))
				i += 1
		out += bytes.get_string_from_utf8()
		last = m.get_end()
	return out + s.substr(last)


# ---- Testing aids -----------------------------------------------------------

## `-- --fake-mail`: pretend mail arrives, to test the mail carrier without Gmail.
func _fake_mail() -> void:
	status_changed.emit("Mail: fake mode")
	await get_tree().create_timer(2.0).timeout
	baseline.emit(3)
	await get_tree().create_timer(9.0).timeout
	new_mail.emit(_friendly_sender(_decode_mime("=?UTF-8?Q?Sam_Lee?= <sam@example.com>")), _decode_mime("=?UTF-8?B?RGlubmVyIEZyaWRheT8=?="))


## `-- --mail-probe`: check that Gmail's IMAP server is reachable, without signing in.
func _probe() -> void:
	status_changed.emit("Mail: probing Gmail...")
	var err: String = await _open()
	if err == "":
		await _cmd("LOGOUT")
	_finish("Mail probe: " + ("Gmail reachable" if err == "" else err))
	print("MAIL PROBE RESULT: ", "Gmail reachable" if err == "" else err)
