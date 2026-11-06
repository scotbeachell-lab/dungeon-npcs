extends Node
## Reads a Google Calendar through its private iCal address (read-only) and
## announces upcoming events: a summary of today at startup, a reminder a few
## minutes before each event, and a "starting now" call.
##
## Settings live in user://calendar.cfg, which is OUTSIDE the project folder:
##   Windows: %APPDATA%\Godot\app_userdata\Dungeon NPCs\calendar.cfg
## See README.md for how to fill it in.

signal status_changed(text: String)
signal announcement(speech: String, toast: String, log_text: String)

const CONFIG_PATH := "user://calendar.cfg"
const REFRESH_SECONDS := 900.0
const LOOKAHEAD_HOURS := 36
const DAY_CODES := ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

var ics_url := ""
var remind_minutes := 10
## Upcoming events: { key, start (unix seconds), summary, all_day, location }
var events: Array = []

var _announced := {}
var _http: HTTPRequest
var _first_load := true
var _bias_s := 0  # local time = UTC + _bias_s


func _ready() -> void:
	_bias_s = int(Time.get_time_zone_from_system()["bias"]) * 60
	var args := OS.get_cmdline_user_args()
	if "--calendar-selftest" in args:
		_selftest()
		return
	if "--fake-calendar" in args:
		status_changed.emit("Calendar: fake mode")
		_ingest(_sample_ics())
		_start_ticker()
		return
	if not _load_config():
		return
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	add_child(_http)
	_http.request_completed.connect(_on_fetched)
	_fetch()
	var refresh := Timer.new()
	refresh.wait_time = REFRESH_SECONDS
	refresh.autostart = true
	refresh.timeout.connect(_fetch)
	add_child(refresh)
	_start_ticker()


func _load_config() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		cfg.set_value("calendar", "ics_url", "")
		cfg.set_value("calendar", "remind_minutes_before", 10)
		cfg.save(CONFIG_PATH)
	ics_url = str(cfg.get_value("calendar", "ics_url", "")).strip_edges()
	if ics_url.begins_with("webcal://"):
		ics_url = "https://" + ics_url.trim_prefix("webcal://")
	remind_minutes = clampi(int(cfg.get_value("calendar", "remind_minutes_before", 10)), 1, 240)
	if ics_url == "":
		status_changed.emit("Calendar: not set up (see README.md)")
		return false
	return true


func _start_ticker() -> void:
	var t := Timer.new()
	t.wait_time = 15.0
	t.autostart = true
	t.timeout.connect(_tick)
	add_child(t)


func _fetch() -> void:
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	status_changed.emit("Calendar: updating...")
	if _http.request(ics_url) != OK:
		status_changed.emit("Calendar: bad address in calendar.cfg")


func _on_fetched(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		status_changed.emit("Calendar: couldn't download (check internet) - retrying")
		# Common right after Windows starts, before Wi-Fi connects: try again soon.
		get_tree().create_timer(60.0).timeout.connect(_fetch)
		return
	if code != 200:
		status_changed.emit("Calendar: download failed (HTTP %d) - check the address" % code)
		return
	var text := body.get_string_from_utf8()
	if not text.contains("BEGIN:VCALENDAR"):
		status_changed.emit("Calendar: that address isn't an iCal calendar")
		return
	_ingest(text)


func _ingest(text: String) -> void:
	var now := int(Time.get_unix_time_from_system())
	events = parse_ics(text, now - 3600, now + LOOKAHEAD_HOURS * 3600)
	status_changed.emit("Calendar: %d upcoming - updated %s" % [_count_timed_upcoming(now), _hhmm(now)])
	if _first_load:
		_first_load = false
		_announce_today(now)
	_tick()


func _count_timed_upcoming(now: int) -> int:
	var n := 0
	for e in events:
		if not e["all_day"] and e["start"] >= now:
			n += 1
	return n


# ---- Announcements ----------------------------------------------------------

func _announce_today(now: int) -> void:
	var today := _local_day(now)
	var all_day: Array = []
	var timed: Array = []
	for e in events:
		if _local_day(e["start"]) != today:
			continue
		if e["all_day"]:
			all_day.append(e["summary"])
		elif e["start"] >= now:
			timed.append(e)

	var lines: Array = []
	if timed.is_empty():
		lines.append("No more events today!")
	else:
		var s := "" if timed.size() == 1 else "s"
		lines.append("You have %d event%s left today." % [timed.size(), s])
		lines.append("Next: \"%s\" at %s" % [timed[0]["summary"], _hhmm(timed[0]["start"])])
	if not all_day.is_empty():
		lines.append("All day: " + ", ".join(PackedStringArray(all_day)))

	var toast := "Today: no more events" if timed.is_empty() else \
		"Today: %d more event%s - next \"%s\" at %s" % [timed.size(), "" if timed.size() == 1 else "s", timed[0]["summary"], _hhmm(timed[0]["start"])]
	announcement.emit("\n".join(PackedStringArray(lines)), toast, lines[0])


func _tick() -> void:
	var now := int(Time.get_unix_time_from_system())
	for e in events:
		if e["all_day"]:
			continue
		var start: int = e["start"]
		var key_remind: String = e["key"] + "|remind"
		var key_start: String = e["key"] + "|start"
		var where: String = "" if e["location"] == "" else "\n@ " + e["location"]
		if now < start and now >= start - remind_minutes * 60 and not _announced.has(key_remind):
			_announced[key_remind] = true
			var mins := ceili((start - now) / 60.0)
			var s := "" if mins == 1 else "s"
			announcement.emit(
				"In %d minute%s:\n\"%s\"%s" % [mins, s, e["summary"], where],
				"In %d min: %s (%s)" % [mins, e["summary"], _hhmm(start)],
				"\"%s\" starts in %d minute%s." % [e["summary"], mins, s])
		elif now >= start and now < start + 120 and not _announced.has(key_start):
			_announced[key_start] = true
			_announced[key_remind] = true
			announcement.emit(
				"Starting now:\n\"%s\"%s" % [e["summary"], where],
				"Starting now: %s" % e["summary"],
				"\"%s\" is starting now." % e["summary"])


func _local_day(unix: int) -> int:
	return floori((unix + _bias_s) / 86400.0)


func _hhmm(unix: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(unix + _bias_s)
	return "%02d:%02d" % [d["hour"], d["minute"]]


# ---- iCal parsing -----------------------------------------------------------
# Times are handled as "local wall-clock seconds" (ls): a unix-style count of
# seconds where the clock reads local time. TZID times are assumed to be in
# this computer's time zone, which is true for most personal calendars.

func parse_ics(text: String, win_start: int, win_end: int) -> Array:
	text = text.replace("\r\n", "\n").replace("\n ", "").replace("\n\t", "")
	var raw: Array = []
	var cur = null
	for line in text.split("\n"):
		if line == "BEGIN:VEVENT":
			cur = {"exdates": []}
			continue
		if line == "END:VEVENT":
			if cur != null:
				raw.append(cur)
			cur = null
			continue
		if cur == null:
			continue
		var colon := _value_colon(line)
		if colon < 0:
			continue
		var head := line.substr(0, colon)
		var value := line.substr(colon + 1)
		var parts := head.split(";")
		var pname := parts[0].to_upper()
		var params := {}
		for i in range(1, parts.size()):
			var kv := parts[i].split("=", true, 1)
			if kv.size() == 2:
				params[kv[0].to_upper()] = kv[1].trim_prefix("\"").trim_suffix("\"")
		match pname:
			"SUMMARY", "LOCATION", "UID", "STATUS", "RRULE":
				cur[pname] = value
			"DTSTART", "RECURRENCE-ID":
				cur[pname] = _parse_time(value, params)
			"EXDATE":
				for v in value.split(",", false):
					cur["exdates"].append(_parse_time(v, params)["ls"])

	# Edited single occurrences of a repeating event replace the original one.
	var overridden := {}
	for r in raw:
		if r.has("RECURRENCE-ID") and r.has("UID"):
			if not overridden.has(r["UID"]):
				overridden[r["UID"]] = []
			overridden[r["UID"]].append(r["RECURRENCE-ID"]["ls"])

	var ws := win_start + _bias_s
	var we := win_end + _bias_s
	var out: Array = []
	for r in raw:
		if not r.has("DTSTART"):
			continue
		if str(r.get("STATUS", "")).to_upper() == "CANCELLED":
			continue
		var st: Dictionary = r["DTSTART"]
		var starts: Array = []
		if r.has("RRULE") and not r.has("RECURRENCE-ID"):
			var ex: Array = r["exdates"] + overridden.get(r.get("UID", ""), [])
			starts = _expand(st["ls"], r["RRULE"], ex, ws, we)
		else:
			starts = [st["ls"]]
		var summary := _unescape(str(r.get("SUMMARY", "(untitled event)")))
		for ls in starts:
			var earliest := ws - 86400 if st["all_day"] else ws
			if ls < earliest or ls > we:
				continue
			out.append({
				"key": "%s@%d" % [r.get("UID", summary), ls],
				"start": ls - _bias_s,
				"summary": summary,
				"all_day": st["all_day"],
				"location": _unescape(str(r.get("LOCATION", ""))),
			})
	out.sort_custom(func(a, b): return a["start"] < b["start"])
	return out


func _value_colon(line: String) -> int:
	var quoted := false
	for i in line.length():
		var c := line[i]
		if c == "\"":
			quoted = not quoted
		elif c == ":" and not quoted:
			return i
	return -1


func _parse_time(value: String, params: Dictionary) -> Dictionary:
	value = value.strip_edges()
	var all_day: bool = params.get("VALUE", "") == "DATE" or value.length() == 8
	var dt := {
		"year": value.substr(0, 4).to_int(),
		"month": value.substr(4, 2).to_int(),
		"day": value.substr(6, 2).to_int(),
		"hour": 0, "minute": 0, "second": 0,
	}
	if not all_day and value.length() >= 15:
		dt["hour"] = value.substr(9, 2).to_int()
		dt["minute"] = value.substr(11, 2).to_int()
		dt["second"] = value.substr(13, 2).to_int()
	var ls := Time.get_unix_time_from_datetime_dict(dt)
	if value.ends_with("Z"):
		ls += _bias_s
	return {"ls": ls, "all_day": all_day}


func _unescape(s: String) -> String:
	return s.replace("\\n", " ").replace("\\N", " ").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")


## Occurrences (as local wall-clock seconds) of a repeating event inside [ws, we].
## Supports FREQ=DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL,
## BYDAY (incl. "2TU" / "-1FR" for monthly) and BYMONTHDAY.
func _expand(start_ls: int, rrule: String, exdates: Array, ws: int, we: int) -> Array:
	var rule := {}
	for part in rrule.split(";", false):
		var kv := part.split("=", true, 1)
		if kv.size() == 2:
			rule[kv[0].to_upper()] = kv[1]
	var freq: String = rule.get("FREQ", "")
	var interval := maxi(1, str(rule.get("INTERVAL", "1")).to_int())
	var count := str(rule.get("COUNT", "0")).to_int()
	var until_ls := -1
	if rule.has("UNTIL"):
		var u := _parse_time(rule["UNTIL"], {})
		until_ls = u["ls"] + (86399 if u["all_day"] else 0)
	var byday: Array = []
	if rule.has("BYDAY"):
		for tok in str(rule["BYDAY"]).split(",", false):
			var wd := DAY_CODES.find(tok.right(2))
			if wd >= 0:
				byday.append([tok.left(tok.length() - 2).to_int(), wd])
	var bymonthday: Array = []
	if rule.has("BYMONTHDAY"):
		for tok in str(rule["BYMONTHDAY"]).split(",", false):
			bymonthday.append(tok.to_int())

	var d0 := floori(start_ls / 86400.0)
	var tod := start_ls - d0 * 86400
	var dict0 := Time.get_datetime_dict_from_unix_time(d0 * 86400)
	# Without COUNT every check is a pure date test, so we can start near the window.
	var d := d0 if count > 0 else maxi(d0, floori(ws / 86400.0) - 1)
	var last := floori(we / 86400.0)
	var res: Array = []
	var seen := 0
	var guard := 0
	while d <= last and guard < 40000:
		guard += 1
		if _matches(d, d0, dict0, freq, interval, byday, bymonthday):
			var ls := d * 86400 + tod
			if until_ls >= 0 and ls > until_ls:
				break
			seen += 1
			if count > 0 and seen > count:
				break
			if ls >= ws - 86400 and not exdates.has(ls):
				res.append(ls)
		d += 1
	return res


func _matches(d: int, d0: int, dict0: Dictionary, freq: String, interval: int, byday: Array, bymonthday: Array) -> bool:
	if d < d0:
		return false
	var wd := (d + 4) % 7  # 1970-01-01 was a Thursday; Sunday = 0
	match freq:
		"DAILY":
			if (d - d0) % interval != 0:
				return false
			return byday.is_empty() or _has_weekday(byday, wd)
		"WEEKLY":
			var weeks := floori((_week_start(d) - _week_start(d0)) / 7.0)
			if weeks % interval != 0:
				return false
			if byday.is_empty():
				return wd == (d0 + 4) % 7
			return _has_weekday(byday, wd)
		"MONTHLY":
			var dt := Time.get_datetime_dict_from_unix_time(d * 86400)
			var months: int = (dt["year"] - dict0["year"]) * 12 + dt["month"] - dict0["month"]
			if months % interval != 0:
				return false
			if not bymonthday.is_empty():
				return bymonthday.has(dt["day"])
			if not byday.is_empty():
				return _nth_weekday(byday, wd, dt)
			return dt["day"] == dict0["day"]
		"YEARLY":
			var dt := Time.get_datetime_dict_from_unix_time(d * 86400)
			if (dt["year"] - dict0["year"]) % interval != 0:
				return false
			return dt["month"] == dict0["month"] and dt["day"] == dict0["day"]
	return false


func _week_start(d: int) -> int:
	return d - (((d + 4) % 7) + 6) % 7  # weeks start on Monday


func _has_weekday(byday: Array, wd: int) -> bool:
	for e in byday:
		if e[1] == wd:
			return true
	return false


func _nth_weekday(byday: Array, wd: int, dt: Dictionary) -> bool:
	var day: int = dt["day"]
	for e in byday:
		if e[1] != wd:
			continue
		var n: int = e[0]
		if n == 0:
			return true
		if n > 0 and (day - 1) / 7 + 1 == n:
			return true
		if n < 0 and (_days_in_month(dt["year"], dt["month"]) - day) / 7 + 1 == -n:
			return true
	return false


func _days_in_month(y: int, m: int) -> int:
	if m == 2:
		return 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28
	return 30 if m in [4, 6, 9, 11] else 31


# ---- Testing aids -----------------------------------------------------------

func _fmt_local(ls: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(ls)
	return "%04d%02d%02dT%02d%02d%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"], d["second"]]


func _fmt_date(ls: int) -> String:
	return _fmt_local(ls).substr(0, 8)


## A calendar relative to "now" that exercises reminders, repeats and exceptions.
func _sample_ics() -> String:
	var now := int(Time.get_unix_time_from_system())
	var now_ls := now + _bias_s
	var today_wd: String = DAY_CODES[(floori(now_ls / 86400.0) + 4) % 7]
	var lines := [
		"BEGIN:VCALENDAR", "VERSION:2.0",
		"BEGIN:VEVENT", "UID:standup", "SUMMARY:Team standup",
		"DTSTART:" + _fmt_local(now + 240) + "Z", "LOCATION:Meeting room 2", "END:VEVENT",
		"BEGIN:VEVENT", "UID:lunch", "SUMMARY:Lunch with Sam",
		"DTSTART;TZID=Local/Zone:" + _fmt_local(now_ls + 3 * 3600), "END:VEVENT",
		"BEGIN:VEVENT", "UID:gym", "SUMMARY:Gym",
		"DTSTART;TZID=Local/Zone:" + _fmt_local(now_ls + 5 * 3600 - 21 * 86400),
		"RRULE:FREQ=WEEKLY;BYDAY=" + today_wd, "END:VEVENT",
		"BEGIN:VEVENT", "UID:review", "SUMMARY:Daily review",
		"DTSTART;TZID=Local/Zone:" + _fmt_local(now_ls + 2 * 3600 - 10 * 86400),
		"RRULE:FREQ=DAILY", "EXDATE;TZID=Local/Zone:" + _fmt_local(now_ls + 2 * 3600), "END:VEVENT",
		"BEGIN:VEVENT", "UID:bday", "SUMMARY:Mum's birthday",
		"DTSTART;VALUE=DATE:" + _fmt_date(now_ls), "RRULE:FREQ=YEARLY", "END:VEVENT",
		"BEGIN:VEVENT", "UID:old", "SUMMARY:Cancelled thing", "STATUS:CANCELLED",
		"DTSTART:" + _fmt_local(now + 600) + "Z", "END:VEVENT",
		"END:VCALENDAR",
	]
	# Fold one long line the way real feeds do, to test unfolding.
	return "\r\n".join(PackedStringArray(lines)).replace("SUMMARY:Lunch with Sam", "SUMMARY:Lunch w\r\n ith Sam")


func _selftest() -> void:
	var now := int(Time.get_unix_time_from_system())
	var evs := parse_ics(_sample_ics(), now - 3600, now + LOOKAHEAD_HOURS * 3600)
	print("CALENDAR SELFTEST now=", _hhmm(now), " bias_min=", _bias_s / 60)
	for e in evs:
		print("  ", Time.get_datetime_string_from_unix_time(e["start"] + _bias_s, true), "  all_day=", e["all_day"], "  ", e["summary"], "  [", e["location"], "]")
	get_tree().quit()
