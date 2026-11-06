@tool
extends VBoxContainer

signal preview_requested
signal transfer_requested
signal refresh_requested

const Transfer = preload("transfer.gd")
const TimeField = preload("time_field.gd")
var content := VBoxContainer.new()
var player: AnimationPlayer
var source_picker := OptionButton.new()
var destination_picker := OptionButton.new()
var start_time := TimeField.new()
var end_time := TimeField.new()
var fps := SpinBox.new()
var start_frame := LineEdit.new()
var end_frame := LineEdit.new()
var start_previous := Button.new()
var start_next := Button.new()
var end_previous := Button.new()
var end_next := Button.new()
var track_list := VBoxContainer.new()
var attention_list := VBoxContainer.new()
var _attention_scroll := ScrollContainer.new()
var preview_button := Button.new()
var transfer_button := Button.new()
var status := Label.new()
var player_label := Label.new()
var refresh_button := Button.new()
var track_filter := LineEdit.new()
var select_all := Button.new()
var select_none := Button.new()
var selection_count := Label.new()
var range_count := Label.new()
var boxes: Array[CheckBox] = []
var preview_plan: Dictionary = {}
var selected_identities: Dictionary = {}
var ambiguous_intents: Dictionary = {}
var _source_name := ""
var _destination_name := ""
var _observed: Array = []
var _watched: Array[Object] = []
var _sync_queued := false
var _refreshing_frames := false
var _applying_theme := false
var _sessions: Dictionary = {}
var _session_key := ""
var _source_states: Dictionary = {}

func _init() -> void:
	name = "SegmentTransfer"
	custom_minimum_size.x = 320
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	add_child(content)
	var working := HBoxContainer.new()
	player_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	player_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	working.add_child(player_label)
	refresh_button.text = "Refresh"
	refresh_button.tooltip_text = "Refresh working AnimationPlayer; keep choices and clear Preview."
	refresh_button.pressed.connect(func(): refresh_requested.emit())
	working.add_child(refresh_button)
	content.add_child(working)
	add_labeled("Source", source_picker)
	add_labeled("Destination", destination_picker)
	content.add_child(HSeparator.new())
	for field in [start_time, end_time]:
		field.custom_minimum_size.x = 80
		field.value_changed.connect(func(_value):
			refresh_frames()
			invalidate())
	fps.min_value = 1
	fps.max_value = 1000000
	fps.step = 1
	fps.value = 30
	fps.value_changed.connect(func(_value): refresh_frames())
	var range_heading := HBoxContainer.new()
	var range_label := Label.new()
	range_label.text = "Range, inclusive"
	range_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	range_heading.add_child(range_label)
	var fps_label := Label.new()
	fps_label.text = "FPS"
	range_heading.add_child(fps_label)
	fps.tooltip_text = "Frame rate for display and intentional frame edits only; does not retime keys."
	fps.custom_minimum_size.x = 72
	range_heading.add_child(fps)
	content.add_child(range_heading)
	var units := HBoxContainer.new()
	var spacer := Control.new()
	spacer.custom_minimum_size.x = 82
	units.add_child(spacer)
	var seconds_label := Label.new()
	seconds_label.text = "Seconds"
	seconds_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	units.add_child(seconds_label)
	var frame_label := Label.new()
	frame_label.text = "Frame"
	frame_label.custom_minimum_size.x = 72
	units.add_child(frame_label)
	content.add_child(units)
	add_time_controls(start_time, start_frame, start_previous, start_next)
	add_time_controls(end_time, end_frame, end_previous, end_next)
	content.add_child(range_count)
	content.add_child(HSeparator.new())
	var filter_row := HBoxContainer.new()
	track_filter.placeholder_text = "Filter tracks"
	track_filter.tooltip_text = "Case-insensitive path filter. Spaces mean OR. All/None affect shown supported tracks only."
	track_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	track_filter.text_changed.connect(func(_text): apply_filter())
	filter_row.add_child(track_filter)
	select_all.text = "All"
	select_none.text = "None"
	select_all.tooltip_text = "Select shown supported tracks; retain hidden choices."
	select_none.tooltip_text = "Clear shown supported choices; retain hidden and blocked intent."
	select_all.pressed.connect(func(): select_shown(true))
	select_none.pressed.connect(func(): select_shown(false))
	filter_row.add_child(select_all)
	filter_row.add_child(select_none)
	content.add_child(filter_row)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 130
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(track_list)
	track_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	content.add_child(selection_count)
	_attention_scroll.custom_minimum_size.y = 80
	_attention_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	attention_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_attention_scroll.add_child(attention_list)
	content.add_child(_attention_scroll)
	var actions := HBoxContainer.new()
	preview_button.text = "Preview"
	preview_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_button.pressed.connect(func(): preview_requested.emit())
	actions.add_child(preview_button)
	transfer_button.text = "Transfer"
	transfer_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	transfer_button.disabled = true
	transfer_button.pressed.connect(func(): transfer_requested.emit())
	actions.add_child(transfer_button)
	content.add_child(actions)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.text = "Select one AnimationPlayer in the scene tree."
	var feedback := ScrollContainer.new()
	feedback.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	feedback.custom_minimum_size.y = 120
	feedback.add_child(status)
	content.add_child(feedback)
	var footer := Label.new()
	footer.text = "MIT | Offline, no telemetry"
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(footer)
	source_picker.item_selected.connect(func(_index):
		var clip := picker_name(source_picker)
		if clip != _source_name:
			store_source_state()
			_source_name = clip
			restore_source_state()
		_observed = []
		sync())
	destination_picker.item_selected.connect(func(_index):
		_destination_name = picker_name(destination_picker)
		invalidate()
		sync())
	set_player(null)

func _ready() -> void:
	if has_theme_icon("Reload", "EditorIcons"):
		refresh_button.text = ""
		refresh_button.icon = get_theme_icon("Reload", "EditorIcons")
	apply_editor_action_theme()

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready() and not _applying_theme:
		apply_editor_action_theme()

func apply_editor_action_theme() -> void:
	if not Engine.is_editor_hint() or not has_theme_color("accent_color", "Editor"):
		return
	_applying_theme = true
	# No native primary Button variation exists in the exercised editor theme.
	# Keep native geometry and disabled styling; use its accent for the action.
	var accent := get_theme_color("accent_color", "Editor")
	var luminance := accent.srgb_to_linear().get_luminance()
	var ink := Color.BLACK if (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) else Color.WHITE
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		var native := get_theme_stylebox(state, "Button")
		if native is StyleBoxFlat:
			var style: StyleBoxFlat = native.duplicate()
			style.bg_color = accent
			transfer_button.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		transfer_button.add_theme_color_override(state, ink)
	var native_focus := get_theme_stylebox("focus", "Button")
	if native_focus is StyleBoxFlat:
		var focus: StyleBoxFlat = native_focus.duplicate()
		focus.border_color = ink
		transfer_button.add_theme_stylebox_override("focus", focus)
	_applying_theme = false

func add_labeled(text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 86
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	content.add_child(row)

func session_key(value: AnimationPlayer, scene: Node = null) -> String:
	if scene == null:
		scene = value.owner if value.owner != null else value
	var scene_key := scene.scene_file_path if not scene.scene_file_path.is_empty() else "instance:%d" % scene.get_instance_id()
	return scene_key + "|" + str(scene.get_path_to(value))

func store_source_state() -> void:
	commit_inputs()
	if not _source_name.is_empty():
		_source_states[_source_name] = {
			"start": start_time.value, "end": end_time.value,
			"selected": selected_identities.duplicate(), "ambiguous": ambiguous_intents.duplicate()}

func store_player_state() -> void:
	if _session_key.is_empty():
		return
	if is_instance_valid(player):
		var scene := player.owner if player.owner != null else player
		var unsaved_key := "instance:%d|%s" % [scene.get_instance_id(), scene.get_path_to(player)]
		# First Save changes this live scene's identity, not its working choices.
		# Migrate only its exact unsaved key; other scene/path sessions stay separate.
		if _session_key == unsaved_key and not scene.scene_file_path.is_empty():
			_sessions.erase(_session_key)
			_session_key = session_key(player, scene)
	store_source_state()
	_sessions[_session_key] = {"source": _source_name, "destination": _destination_name,
		"fps": fps.value, "sources": _source_states}

func restore_source_state() -> void:
	selected_identities.clear()
	ambiguous_intents.clear()
	if _source_states.has(_source_name):
		var state: Dictionary = _source_states[_source_name]
		start_time.value = state.start
		end_time.value = state.end
		selected_identities = state.selected.duplicate()
		ambiguous_intents = state.ambiguous.duplicate()
	else:
		initialize_source()

func set_player(value: AnimationPlayer, scene: Node = null) -> void:
	if player == value and is_instance_valid(value):
		commit_inputs()
		sync()
		invalidate("player refreshed")
		return
	store_player_state()
	unwatch()
	player = value
	_session_key = ""
	_source_states = {}
	selected_identities.clear()
	ambiguous_intents.clear()
	source_picker.clear()
	destination_picker.clear()
	if is_instance_valid(player):
		player_label.text = "Working on: " + str(player.name)
		for clip in player.get_animation_list():
			source_picker.add_item(clip)
			destination_picker.add_item(clip)
		# First attachment has no remembered clip names. Prefer an actual track
		# source rather than an empty destination when initializing its FPS.
		for i in source_picker.item_count:
			if player.get_animation(source_picker.get_item_text(i)).get_track_count() > 0:
				source_picker.select(i)
				break
		if destination_picker.item_count > 1:
			destination_picker.select(1 if source_picker.selected == 0 else 0)
	else:
		player_label.text = "Select one AnimationPlayer in the scene tree."
	source_picker.disabled = source_picker.item_count == 0
	destination_picker.disabled = destination_picker.item_count == 0
	_source_name = picker_name(source_picker)
	_destination_name = picker_name(destination_picker)
	if is_instance_valid(player):
		_session_key = session_key(player, scene)
		if _sessions.has(_session_key):
			var state: Dictionary = _sessions[_session_key]
			_source_name = state.source
			_destination_name = state.destination
			_source_states = state.sources
			fps.value = state.fps
		else:
			var animation := source()
			var inverse := 1.0 / animation.step if animation != null and animation.step > 0.0 else 30.0
			fps.value = round(inverse) if is_finite(inverse) and abs(inverse - round(inverse)) < 0.001 else 30
		sync_picker(source_picker, _source_name, true)
		sync_picker(destination_picker, _destination_name, true)
		restore_source_state()
	_observed = []
	sync()

func picker_name(picker: OptionButton) -> String:
	return picker.get_item_text(picker.selected) if picker.selected >= 0 else ""

func initialize_source() -> void:
	var animation := source()
	if animation == null:
		return
	start_time.value = 0.0
	end_time.value = animation.length

func queue_sync() -> void:
	if not _sync_queued:
		_sync_queued = true
		call_deferred("_sync_if_queued")

func _sync_if_queued() -> void:
	if _sync_queued:
		sync()

func unwatch() -> void:
	for object in _watched:
		if is_instance_valid(object):
			for signal_name in ["changed", "tracks_changed", "animation_list_changed"]:
				if object.has_signal(signal_name) and object.is_connected(signal_name, queue_sync):
					object.disconnect(signal_name, queue_sync)
	_watched.clear()

func watch_current() -> void:
	unwatch()
	for object in [player, source(), destination()]:
		if not is_instance_valid(object) or object in _watched:
			continue
		_watched.append(object)
		for signal_name in ["changed", "tracks_changed", "animation_list_changed"]:
			if object.has_signal(signal_name):
				object.connect(signal_name, queue_sync)

func sync_picker(picker: OptionButton, wanted: String, restore: bool = false) -> void:
	var names := player.get_animation_list() if is_instance_valid(player) else PackedStringArray()
	var shown := PackedStringArray()
	for i in picker.item_count:
		shown.append(picker.get_item_text(i))
	if shown != names:
		picker.clear()
		for clip in names:
			picker.add_item(clip)
		picker.select(names.find(wanted))
	elif restore:
		picker.select(names.find(wanted))
	picker.disabled = names.is_empty()

func animation_state(animation: Animation) -> Array:
	if animation == null:
		return []
	var raw: Array = []
	for track in animation.get_track_count():
		for key in animation.track_get_key_count(track):
			raw.append(animation.track_get_key_time(track, key))
	return [animation.get_instance_id(), Transfer.stamp(animation), var_to_bytes(raw)]

func sync() -> void:
	_sync_queued = false
	sync_picker(source_picker, _source_name)
	sync_picker(destination_picker, _destination_name)
	var state := [animation_state(source()), animation_state(destination())]
	if state != _observed:
		var reason := "source or destination clip changed"
		var source_changed: bool = _observed.is_empty() or state[0] != _observed[0]
		_observed = state
		if source_changed:
			rebuild_tracks()
		invalidate(reason)
	watch_current()

func selected_identity_set() -> Array:
	var result := selected_identities.keys()
	result.sort()
	return result

func selection_error() -> String:
	if not ambiguous_intents.is_empty():
		return "Ambiguous selected identity: %s. Resolve duplicates and select again, or Forget." % ", ".join(ambiguous_intents.keys())
	var result := Transfer.resolve_identities(source(), selected_identity_set())
	return "" if result.ok else result.error

func forget_identity(key: String) -> void:
	selected_identities.erase(key)
	ambiguous_intents.erase(key)
	rebuild_tracks()

func toggle_identity(key: String, pressed: bool) -> void:
	if pressed:
		selected_identities[key] = true
		ambiguous_intents.erase(key)
	else:
		selected_identities.erase(key)
	update_counts()
	invalidate()

func apply_filter() -> void:
	apply_filter_visibility()
	update_counts()

func apply_filter_visibility() -> void:
	var terms := track_filter.text.to_lower().split(" ", false)
	for box in boxes:
		var matches := terms.is_empty()
		for term in terms:
			if term in str(box.get_meta("path")).to_lower():
				matches = true
		box.visible = matches

func select_shown(pressed: bool) -> void:
	# LineEdit.text_changed can arrive after this mouse action. Reconcile the
	# current draft now, never borrow visibility from the previous filter.
	sync()
	apply_filter_visibility()
	for box in boxes:
		if box.visible and not box.disabled:
			var key: String = box.get_meta("identity")
			box.set_pressed_no_signal(pressed)
			if pressed:
				selected_identities[key] = true
				ambiguous_intents.erase(key)
			else:
				selected_identities.erase(key)
	update_counts()
	invalidate("shown track choices changed")

func update_counts() -> void:
	var shown := 0
	var visible_selected := 0
	for box in boxes:
		if box.visible:
			shown += 1
			if box.button_pressed:
				visible_selected += 1
	selection_count.text = "%d of %d selected, %d hidden · %d shown" % [selected_identities.size(), boxes.size(), selected_identities.size() - visible_selected, shown]
	var animation := source()
	var keys := 0
	var tracks := selected_tracks()
	if animation != null:
		for track: int in tracks:
			for key in animation.track_get_key_count(track):
				if Transfer.time_in_range(animation.track_get_key_time(track, key), start_time.value, end_time.value):
					keys += 1
	range_count.text = "%d %s on %d selected %s" % [keys, "key" if keys == 1 else "keys", tracks.size(), "track" if tracks.size() == 1 else "tracks"]

func identity_warning(key: String, reason: String) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.text = key + ": " + reason
	label.tooltip_text = label.text
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var forget := Button.new()
	forget.text = "Forget"
	forget.pressed.connect(func(): forget_identity(key))
	row.add_child(label)
	row.add_child(forget)
	attention_list.add_child(row)

func source() -> Animation:
	if not is_instance_valid(player) or source_picker.selected < 0:
		return null
	var clip := source_picker.get_item_text(source_picker.selected)
	return player.get_animation(clip) if player.has_animation(clip) else null

func destination() -> Animation:
	if not is_instance_valid(player) or destination_picker.selected < 0:
		return null
	var clip := destination_picker.get_item_text(destination_picker.selected)
	return player.get_animation(clip) if player.has_animation(clip) else null

func rebuild_tracks() -> void:
	for list in [track_list, attention_list]:
		for child in list.get_children():
			list.remove_child(child)
			child.queue_free()
	boxes.clear()
	var animation := source()
	var counts: Dictionary = {}
	var reasons: Dictionary = {}
	if animation != null:
		for track in animation.get_track_count():
			var key := Transfer.identity(animation, track)
			counts[key] = counts.get(key, 0) + 1
		for track in animation.get_track_count():
			var box := CheckBox.new()
			var key := Transfer.identity(animation, track)
			var reason := Transfer.scalar_error(animation, track)
			if counts[key] > 1:
				reason = "Ambiguous duplicate identity"
				if selected_identities.has(key):
					selected_identities.erase(key)
					ambiguous_intents[key] = true
			reasons[key] = reason
			box.text = str(animation.track_get_path(track))
			box.set_meta("path", str(animation.track_get_path(track)))
			box.set_meta("identity", key)
			box.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			box.tooltip_text = box.text + "\n" + ("Scalar Value track" if reason.is_empty() else reason)
			box.disabled = not reason.is_empty()
			box.set_pressed_no_signal(reason.is_empty() and selected_identities.has(key))
			if box.disabled:
				box.text += " (unsupported)"
			box.toggled.connect(func(pressed): toggle_identity(key, pressed))
			track_list.add_child(box)
			boxes.append(box)
	for key in selected_identities:
		if animation == null:
			identity_warning(key, "Choose a source clip.")
		elif not counts.has(key):
			identity_warning(key, "Selected track is missing: %s. Restore it or Forget it." % key)
		elif not reasons[key].is_empty():
			identity_warning(key, "Selected track %s: %s Restore support or Forget it." % [key, reasons[key]])
	for key in ambiguous_intents:
		identity_warning(key, "Resolve duplicates and select again")
	_attention_scroll.visible = attention_list.get_child_count() > 0
	apply_filter_visibility()
	preview_button.disabled = animation == null
	invalidate()
	refresh_frames()

func add_time_controls(field: TimeField, frame: LineEdit, previous: Button, next: Button) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Start" if field == start_time else "End"
	label.custom_minimum_size.x = 52
	row.add_child(label)
	previous.text = "‹"
	next.text = "›"
	previous.tooltip_text = "Previous key boundary"
	next.tooltip_text = "Next key boundary"
	previous.pressed.connect(func(): step_key(field, -1))
	next.pressed.connect(func(): step_key(field, 1))
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.tooltip_text = "Seconds, inclusive. Only an intentional edit changes the raw boundary."
	frame.custom_minimum_size.x = 72
	frame.text_submitted.connect(func(_input): commit_frame(field, frame))
	frame.focus_exited.connect(func():
		if frame.text != frame.get_meta("rendered", ""):
			commit_frame(field, frame))
	row.add_child(previous)
	row.add_child(field)
	row.add_child(next)
	row.add_child(frame)
	content.add_child(row)

func commit_frame(field: TimeField, frame: LineEdit) -> void:
	var input := frame.text
	# Consume the actual draft before a value signal can refresh either readout.
	frame.set_meta("rendered", input)
	if input.is_valid_int() and not input.begins_with("-"):
		field.value = input.to_float() / float(frame.get_meta("fps", fps.value))
	refresh_frames()

func commit_inputs() -> void:
	start_time.commit_edit()
	end_time.commit_edit()
	for pair in [[start_time, start_frame], [end_time, end_frame]]:
		if pair[1].text != pair[1].get_meta("rendered", ""):
			commit_frame(pair[0], pair[1])

func refresh_frames() -> void:
	if _refreshing_frames:
		return
	_refreshing_frames = true
	# Native text_changed is deferred. Preserve both drafts before any rendering,
	# including refreshes caused by the other boundary or display-only FPS edits.
	for pair in [[start_time, start_frame], [end_time, end_frame]]:
		if pair[1].text != pair[1].get_meta("rendered", ""):
			commit_frame(pair[0], pair[1])
	for pair in [[start_time, start_frame], [end_time, end_frame]]:
		var value: float = pair[0].value
		var frame := round(value * fps.value)
		var on_frame := Transfer.canonical_time(frame / fps.value) == Transfer.canonical_time(value)
		pair[1].text = String.num(frame, 0) if on_frame else "Not on frame"
		pair[1].set_meta("rendered", pair[1].text)
		pair[1].set_meta("fps", fps.value)
		pair[1].tooltip_text = "Frame at %d fps" % fps.value if on_frame else "Not on a %d fps frame" % fps.value
	_refreshing_frames = false
	update_counts()

func step_key(field: TimeField, direction: int) -> void:
	var animation := source()
	if animation == null:
		return
	var tracks := selected_tracks()
	if tracks.is_empty():
		for track in animation.get_track_count():
			if Transfer.scalar_error(animation, track).is_empty():
				tracks.append(track)
	var found := false
	var chosen := 0.0
	var boundary := Transfer.canonical_time(field.value)
	for track: int in tracks:
		for key in animation.track_get_key_count(track):
			var time := animation.track_get_key_time(track, key)
			var canonical := Transfer.canonical_time(time)
			if (direction > 0 and canonical > boundary and (not found or canonical < Transfer.canonical_time(chosen))) or (direction < 0 and canonical < boundary and (not found or canonical > Transfer.canonical_time(chosen))):
				chosen = time
				found = true
	if found:
		field.value = chosen

func selected_tracks() -> Array:
	var result := Transfer.resolve_identities(source(), selected_identity_set())
	return result.indices if result.ok and ambiguous_intents.is_empty() else []

func missing_clip_reason() -> String:
	if is_instance_valid(player):
		if not _source_name.is_empty() and source() == null and not player.has_animation(_source_name):
			return "Source clip is missing: " + _source_name
		if not _destination_name.is_empty() and destination() == null and not player.has_animation(_destination_name):
			return "Destination clip is missing: " + _destination_name
	return ""

func invalidate(reason: String = "") -> void:
	var missing := missing_clip_reason()
	if not missing.is_empty():
		reason = missing
	var had_preview := not preview_plan.is_empty()
	preview_plan = {}
	transfer_button.disabled = true
	transfer_button.text = "Transfer"
	status.tooltip_text = ""
	status.text = "Choose clips, tracks and range; preview before transferring." if is_instance_valid(player) else "Select one AnimationPlayer in the scene tree."
	if had_preview or not reason.is_empty():
		status.text = "Preview cleared: %s. Preview again." % (reason if not reason.is_empty() else "request changed")

func show_error(message: String) -> void:
	invalidate()
	status.text = "Not transferred: " + message

func show_preview(plan: Dictionary) -> void:
	preview_plan = plan
	transfer_button.disabled = false
	transfer_button.text = "Transfer %d %s" % [plan.keys, "key" if plan.keys == 1 else "keys"]
	var lines: Array = plan.lines
	status.text = "Preview ready: %d %s, %d new %s.\nOriginal times kept; no overwrite.\n%s" % [plan.keys, "key" if plan.keys == 1 else "keys", plan.new_tracks, "track" if plan.new_tracks == 1 else "tracks", "\n".join(lines.slice(0, 8))]
	if lines.size() > 8:
		status.text += "\n…and %d more" % (lines.size() - 8)
	status.tooltip_text = "\n".join(lines)
	for notice in plan.get("notices", []):
		status.text += "\n" + notice.message
