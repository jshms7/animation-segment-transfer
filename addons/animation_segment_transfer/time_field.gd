@tool
extends LineEdit

signal value_changed(value: float)
var _value: float = 0.0
var _edited := false
var _commit_revision := 0
var _settled_revision := 0
var value: float:
	get:
		return _value
	set(next):
		if not is_finite(next) or next < 0.0 or not is_finite(PackedFloat32Array([next])[0]):
			return
		var changed := _value != next
		_value = next
		_edited = false
		text = seconds_text(next)
		if changed:
			value_changed.emit(_value)

func _init() -> void:
	text = "0"
	text_changed.connect(func(next):
		# LineEdit's queued notification can read the text just rendered by Enter.
		if _commit_revision == _settled_revision or next != seconds_text(_value):
			_edited = true)
	text_submitted.connect(func(_text): commit_edit())
	focus_exited.connect(commit_edit)

func commit_edit() -> void:
	if not _edited and text == seconds_text(_value):
		return
	# Submission may precede the already queued text_changed. Inspect current text
	# now, then ignore only this commit's late canonical render notification.
	_commit_revision += 1
	_settle_commit.call_deferred(_commit_revision)
	var input := text.strip_edges()
	if input.is_valid_float():
		var parsed := input.to_float()
		if is_finite(parsed) and parsed >= 0.0 and is_finite(PackedFloat32Array([parsed])[0]):
			value = parsed
			return
	_edited = false
	text = seconds_text(_value)

func _settle_commit(revision: int) -> void:
	_settled_revision = maxi(_settled_revision, revision)

# Round the canonical value, not the raw double, to choose the closest shortest
# decimal in its float32 rounding interval. Scientific form covers subnormals.
static func seconds_text(raw: float) -> String:
	var canonical: float = PackedFloat32Array([raw])[0]
	if canonical == 0.0:
		return "0"
	var best := ""
	for places in range(15):
		var candidate := String.num(canonical, places)
		if PackedFloat32Array([candidate.to_float()])[0] == canonical:
			best = candidate
			break
	var exponent := int(floor(log(canonical) / log(10.0)))
	var mantissa := canonical / pow(10.0, exponent)
	for places in range(9):
		var rounded := String.num(mantissa, places)
		var candidate := "1e" + str(exponent + 1) if rounded == "10" else rounded + "e" + str(exponent)
		if PackedFloat32Array([candidate.to_float()])[0] == canonical:
			if best.is_empty() or candidate.length() < best.length():
				best = candidate
			break
	return best
