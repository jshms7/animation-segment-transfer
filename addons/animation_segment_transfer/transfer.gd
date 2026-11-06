@tool
extends RefCounted

# Canonical float32 is for comparison only. Never retime an inserted source key.
static func canonical_time(value: float) -> float:
	return PackedFloat32Array([value])[0]

static func _valid_time(value: float) -> bool:
	return is_finite(value) and value >= 0.0 and is_finite(canonical_time(value))

static func time_in_range(time: float, start: float, end: float) -> bool:
	if not _valid_time(time) or not _valid_time(start) or not _valid_time(end) or start > end:
		return false
	return canonical_time(start) <= canonical_time(time) and canonical_time(time) <= canonical_time(end)

# Literal identity: scan and count every source row; find_track hides duplicates.
static func identity(animation: Animation, track: int) -> String:
	return "%d|%s" % [animation.track_get_type(track), str(animation.track_get_path(track))]

static func resolve_identities(source: Animation, identities: Array) -> Dictionary:
	if source == null:
		return failure("Choose a source clip.")
	var matches: Dictionary = {}
	for track in source.get_track_count():
		var key := identity(source, track)
		if not matches.has(key):
			matches[key] = []
		matches[key].append(track)
	var indices: Array = []
	var seen: Dictionary = {}
	for key in identities:
		if typeof(key) != TYPE_STRING or seen.has(key):
			return failure("Invalid or repeated track identity.")
		seen[key] = true
		if not matches.has(key):
			return failure("Selected track is missing: %s. Restore it or Forget it." % key)
		if matches[key].size() != 1:
			return failure("Ambiguous duplicate track identity: %s. Resolve it and select again." % key)
		var track: int = matches[key][0]
		var reason := scalar_error(source, track)
		if not reason.is_empty():
			return failure("Selected track %s: %s Restore support or Forget it." % [key, reason])
		indices.append(track)
	indices.sort()
	return {"ok": true, "indices": indices}

static func plan_by_identities(source: Animation, destination: Animation, identities: Array, start: float, end: float) -> Dictionary:
	var resolved := resolve_identities(source, identities)
	if not resolved.ok:
		return resolved
	return plan(source, destination, resolved.indices, start, end)

# A plan never changes either caller-owned Animation. The editor owns commit/undo.
static func plan(source: Animation, destination: Animation, selected: Array, start: float, end: float) -> Dictionary:
	if source == null or destination == null or source == destination:
		return failure("Choose two different animation resources.")
	if not _valid_time(start) or not _valid_time(end) or start > end:
		return failure("Use a finite inclusive range with 0 <= start <= end.")
	if not _valid_time(destination.length):
		return failure("Use a finite non-negative destination length representable in float32.")
	if selected.is_empty():
		return failure("Select at least one source track.")
	for animation in [source, destination]:
		var seen: Dictionary = {}
		for track in animation.get_track_count():
			var identity := [animation.track_get_path(track), animation.track_get_type(track)]
			if seen.has(identity):
				return failure("Ambiguous duplicate path + type: %s." % animation.track_get_path(track))
			seen[identity] = true
			if animation.track_is_compressed(track):
				return failure("Compressed tracks are not supported.")
			if animation == destination:
				for key in animation.track_get_key_count(track):
					if not _valid_time(animation.track_get_key_time(track, key)):
						return failure("Invalid destination key time on %s." % animation.track_get_path(track))
	var chosen: Dictionary = {}
	var notices: Array[Dictionary] = []
	for index in selected:
		if typeof(index) != TYPE_INT or index < 0 or index >= source.get_track_count() or chosen.has(index):
			return failure("Track selection is invalid or repeated. Refresh the player.")
		chosen[index] = true
		var reason := scalar_error(source, index)
		if not reason.is_empty():
			return failure("%s: %s" % [source.track_get_path(index), reason])
		for key in source.track_get_key_count(index):
			var notice := near_boundary_notice(source, index, key, start, end)
			if not notice.is_empty():
				notices.append(notice)
		var target := destination.find_track(source.track_get_path(index), Animation.TYPE_VALUE)
		if target >= 0:
			reason = scalar_error(destination, target)
			if not reason.is_empty():
				return failure("Destination %s: %s" % [destination.track_get_path(target), reason])
			if metadata(source, index) != metadata(destination, target):
				return failure("Track settings differ for %s. Align update/interpolation/enabled settings first." % source.track_get_path(index))
			if source.track_get_key_count(index) > 0 and destination.track_get_key_count(target) > 0:
				if typeof(source.track_get_key_value(index, 0)) != typeof(destination.track_get_key_value(target, 0)):
					return failure("Scalar value types differ for %s." % source.track_get_path(index))
	var before := _exact_duplicate(destination)
	var after := _exact_duplicate(destination)
	if before == null or after == null:
		return failure("Native copying cannot preserve every destination key and setting. No changes made.")
	var key_count := 0
	var new_tracks := 0
	var changes: Dictionary = {}
	var lines: PackedStringArray = []
	for track: int in selected:
		var target := after.find_track(source.track_get_path(track), Animation.TYPE_VALUE)
		var copied := 0
		var missing := target < 0
		for key in source.track_get_key_count(track):
			var time := source.track_get_key_time(track, key)
			if not time_in_range(time, start, end):
				continue
			if canonical_time(time) > canonical_time(destination.length):
				return failure("A selected key is outside the destination length. Extend that clip explicitly first.")
			if target >= 0 and after.track_find_key(target, time, Animation.FIND_MODE_APPROX) >= 0:
				return failure("Collision: %s already has a key at %.9f s (or approximately that time)." % [source.track_get_path(track), time])
			if target < 0:
				target = after.get_track_count()
				source.copy_track(track, after)
				while after.track_get_key_count(target) > 0:
					after.track_remove_key(target, 0)
				new_tracks += 1
			if not changes.has(target):
				changes[target] = {"source": track, "keys": []}
			var data := _key_data(source, track, key)
			changes[target].keys.append(data)
			if after.track_insert_key(target, data[0], data[1], data[2]) < 0:
				return failure("Native insertion cannot preserve every key time, value and transition on %s. No changes made." % source.track_get_path(track))
			key_count += 1
			copied += 1
		if copied > 0:
			lines.append("%s: %d %s, %s track" % [source.track_get_path(track), copied, "key" if copied == 1 else "keys", "new" if missing else "existing"])
	if key_count == 0:
		var rejected := failure("No keys in this inclusive range on the selected tracks.")
		rejected["notices"] = notices
		for notice in notices:
			rejected.error += "\n" + notice.message
		return rejected
	if not _verify_plan(before, after, source, changes):
		return failure("Native insertion cannot preserve every key time, value, transition and setting. No changes made.")
	return {"ok": true, "before": before, "after": after, "keys": key_count, "new_tracks": new_tracks, "lines": lines,
		"source_stamp": stamp(source), "destination_stamp": stamp(destination), "notices": notices}

# Informational only: compare the same canonical values used by membership.
static func near_boundary_notice(source: Animation, track: int, key: int, start: float, end: float) -> Dictionary:
	var time := source.track_get_key_time(track, key)
	if time_in_range(time, start, end):
		return {}
	var canonical := canonical_time(time)
	var before := canonical < canonical_time(start)
	var distance := canonical_time(start) - canonical if before else canonical - canonical_time(end)
	if not is_finite(distance) or distance <= 0.0 or distance > 0.001:
		return {}
	var boundary := "start" if before else "end"
	var path := str(source.track_get_path(track))
	var message := "Not included: 1 key %.6f ms %s %s (%s, %.9f s). Use the %s key stepper to include it." % [distance * 1000.0, "before" if before else "after", boundary.capitalize(), path, time, boundary.capitalize()]
	return {"track": track, "path": path, "key": key, "time": time, "canonical_time": canonical,
		"boundary": boundary, "distance": distance, "message": message}

static func failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}

static func scalar_error(animation: Animation, track: int) -> String:
	if animation.track_get_type(track) != Animation.TYPE_VALUE:
		return "only scalar Value tracks are supported (not transform, method, audio, Bezier or animation tracks)."
	if animation.value_track_get_update_mode(track) not in [Animation.UPDATE_CONTINUOUS, Animation.UPDATE_DISCRETE]:
		return "capture update is not supported."
	if animation.track_get_interpolation_type(track) not in [Animation.INTERPOLATION_NEAREST, Animation.INTERPOLATION_LINEAR]:
		return "only nearest/linear interpolation is supported."
	var value_type := TYPE_NIL
	for key in animation.track_get_key_count(track):
		if not _valid_time(animation.track_get_key_time(track, key)):
			return "invalid key time (use finite non-negative times representable in float32)."
		var value: Variant = animation.track_get_key_value(track, key)
		if typeof(value) not in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT]:
			return "only bool, int and float keys are supported."
		if typeof(value) == TYPE_FLOAT and not is_finite(value):
			return "non-finite scalar keys are not supported."
		if value_type != TYPE_NIL and typeof(value) != value_type:
			return "mixed scalar types in one track are not supported."
		if not is_finite(animation.track_get_key_transition(track, key)):
			return "non-finite transitions are not supported."
		value_type = typeof(value)
	return ""

static func _key_data(animation: Animation, track: int, key: int) -> Array:
	return [animation.track_get_key_time(track, key), animation.track_get_key_value(track, key), animation.track_get_key_transition(track, key)]

# Storage key arrays alone are insufficient: their getter narrows raw times.
static func _animation_data(animation: Animation) -> PackedByteArray:
	var fields: Array = []
	for property in animation.get_property_list():
		if property.usage & PROPERTY_USAGE_STORAGE:
			fields.append([property.name, animation.get(property.name)])
	for track in animation.get_track_count():
		for key in animation.track_get_key_count(track):
			fields.append([track, key, _key_data(animation, track, key)])
	return var_to_bytes(fields)

static func _exact_duplicate(animation: Animation) -> Animation:
	var copy := animation.duplicate() as Animation
	# duplicate() serializes key times through PackedFloat32Array. copy_track()
	# retains raw API times, but may coalesce neighbours: verify, or discard.
	while copy.get_track_count() > 0:
		copy.remove_track(copy.get_track_count() - 1)
	for track in animation.get_track_count():
		animation.copy_track(track, copy)
	return copy if _animation_data(copy) == _animation_data(animation) else null

static func _stored_fields(animation: Animation) -> Dictionary:
	var fields: Dictionary = {}
	for property in animation.get_property_list():
		if property.usage & PROPERTY_USAGE_STORAGE:
			fields[property.name] = var_to_bytes(animation.get(property.name))
	return fields

# Build the expected state from the exact original and source, never from the
# insertion result. Check stored fields once and raw keys in bounded passes.
# Native approximate lookup can miss a replacement: only this final check makes
# the detached plan committable. No caller-owned resource has changed on failure.
static func _verify_plan(before: Animation, after: Animation, source: Animation, changes: Dictionary) -> bool:
	var expected_fields := _stored_fields(before)
	var new_targets: Dictionary = {}
	var expected_keys: Dictionary = {}
	for track: int in changes:
		var original := before if track < before.get_track_count() else source
		var original_track: int = track if original == before else changes[track].source
		if original == source:
			new_targets[original_track] = track
		var keys: Array = []
		if original == before:
			for key in before.track_get_key_count(track):
				keys.append(_key_data(before, track, key))
		keys.append_array(changes[track].keys)
		keys.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		expected_keys[track] = keys
		# Only scalar Value tracks are touched. Retain all other key-payload
		# settings (including update mode) while predicting native float32 storage.
		var payload: Dictionary = original.get("tracks/%d/keys" % original_track).duplicate()
		var times := PackedFloat32Array()
		var transitions := PackedFloat32Array()
		var values: Array = []
		for data: Array in keys:
			times.append(data[0])
			values.append(data[1])
			transitions.append(data[2])
		payload["times"] = times
		payload["transitions"] = transitions
		payload["values"] = values
		expected_fields["tracks/%d/keys" % track] = var_to_bytes(payload)
	# Remap new-track settings in one source property pass, not one per key/track.
	if not new_targets.is_empty():
		for property in source.get_property_list():
			var name: String = property.name
			if property.usage & PROPERTY_USAGE_STORAGE and name.begins_with("tracks/"):
				var parts := name.split("/", true, 2)
				var track := int(parts[1])
				if new_targets.has(track) and parts[2] != "keys":
					expected_fields["tracks/%d/%s" % [new_targets[track], parts[2]]] = var_to_bytes(source.get(name))
	if _stored_fields(after) != expected_fields:
		return false
	for track in after.get_track_count():
		var count: int = expected_keys[track].size() if expected_keys.has(track) else before.track_get_key_count(track)
		if after.track_get_key_count(track) != count:
			return false
		for key in count:
			var data: Array = expected_keys[track][key] if expected_keys.has(track) else _key_data(before, track, key)
			if var_to_bytes(_key_data(after, track, key)) != var_to_bytes(data):
				return false
	return true

static func metadata(animation: Animation, track: int) -> Array:
	return [animation.track_get_interpolation_type(track), animation.track_get_interpolation_loop_wrap(track),
		animation.track_is_enabled(track), animation.value_track_get_update_mode(track)]

static func stamp(animation: Animation) -> int:
	var fields: Array = []
	for property in animation.get_property_list():
		if property.usage & PROPERTY_USAGE_STORAGE:
			fields.append([property.name, animation.get(property.name)])
	return hash(fields)

static func apply_tracks(destination: Animation, state: Animation) -> void:
	# Animation.clear() also resets length. Preserve all non-track stored fields.
	var settings: Dictionary = {}
	for property in destination.get_property_list():
		var name: String = property.name
		if property.usage & PROPERTY_USAGE_STORAGE and not name.begins_with("tracks/"):
			settings[name] = destination.get(name)
	destination.clear()
	for track in state.get_track_count():
		state.copy_track(track, destination)
	for name in settings:
		destination.set(name, settings[name])
	destination.emit_changed()
