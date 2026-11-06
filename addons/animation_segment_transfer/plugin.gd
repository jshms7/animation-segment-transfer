@tool
extends EditorPlugin

const Transfer = preload("transfer.gd")
const SegmentPanel = preload("panel.gd")
var panel: SegmentPanel
var dock: EditorDock
var _shown_once := false

func _enter_tree() -> void:
	panel = SegmentPanel.new()
	dock = EditorDock.new()
	dock.title = "Segment Transfer"
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	dock.add_child(panel)
	add_dock(dock)
	panel.preview_requested.connect(preview)
	panel.transfer_requested.connect(transfer)
	panel.refresh_requested.connect(refresh_selection)
	EditorInterface.get_selection().selection_changed.connect(refresh_selection)
	scene_changed.connect(_scene_changed)
	get_undo_redo().version_changed.connect(_history_version_changed)
	refresh_selection()

func _exit_tree() -> void:
	get_undo_redo().version_changed.disconnect(_history_version_changed)
	EditorInterface.get_selection().selection_changed.disconnect(refresh_selection)
	disconnect_player_exit()
	scene_changed.disconnect(_scene_changed)
	remove_dock(dock)
	dock.queue_free()

func _history_version_changed() -> void:
	# Native undo/redo can change an unrelated scene property, not a watched clip.
	# Reconcile synchronously so an old deferred callback cannot clear a new result.
	panel.commit_inputs()
	panel.sync()
	panel.invalidate("native Undo/Redo")

func _scene_changed(_scene: Node) -> void:
	refresh_selection()

func disconnect_player_exit() -> void:
	if is_instance_valid(panel.player) and panel.player.tree_exiting.is_connected(_player_exiting):
		panel.player.tree_exiting.disconnect(_player_exiting)

func _player_exiting() -> void:
	disconnect_player_exit()
	panel.set_player(null)

func belongs_to_scene(value: Node, scene: Node) -> bool:
	return is_instance_valid(value) and is_instance_valid(scene) and (value == scene or scene.is_ancestor_of(value))

func refresh_selection() -> void:
	var scene := EditorInterface.get_edited_scene_root()
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var target: AnimationPlayer = panel.player if belongs_to_scene(panel.player, scene) else null
	var directly_selected := selected.size() == 1 and selected[0] is AnimationPlayer and belongs_to_scene(selected[0], scene)
	if directly_selected:
		target = selected[0]
	disconnect_player_exit()
	panel.set_player(target, scene)
	if is_instance_valid(target):
		target.tree_exiting.connect(_player_exiting)
		panel.player_label.text = "Working on: " + str(target.name) + ("" if directly_selected else " (not selected)")
		if not _shown_once:
			_shown_once = true
			dock.make_visible()

func guard() -> String:
	panel.commit_inputs()
	panel.sync()
	var scene := EditorInterface.get_edited_scene_root()
	if not is_instance_valid(panel.player) or scene == null:
		return "Select one AnimationPlayer in the current scene."
	if panel.player != scene and panel.player.owner != scene:
		return "Use a player owned directly by this scene, not an instanced/inherited player."
	if not scene.scene_file_path.is_empty():
		var packed := load(scene.scene_file_path) as PackedScene
		if packed != null and packed.get_state().get_base_scene_state() != null:
			return "Inherited scenes are excluded in v0.1. Use a local scene copy."
	var source: Animation = panel.source()
	var destination: Animation = panel.destination()
	if source == null or destination == null:
		var missing := panel.missing_clip_reason()
		return missing if not missing.is_empty() else "Choose source and destination clips."
	var selection_reason := panel.selection_error()
	if not selection_reason.is_empty():
		return selection_reason
	for animation in [source, destination]:
		if not animation.resource_path.is_empty():
			if scene.scene_file_path.is_empty() or not animation.resource_path.begins_with(scene.scene_file_path + "::"):
				return "Use local scene-embedded animations, not imported/external resources. Make a local copy first."
		if occurrences(scene, animation) != 1:
			return "A clip is shared by multiple players/names in this scene. Make it unique first."
	var root := panel.player.get_node_or_null(panel.player.root_node)
	if root == null:
		return "The player's animation root does not exist."
	for track: int in panel.selected_tracks():
		if track < 0 or track >= source.get_track_count():
			return "Source tracks changed. Refresh the selected player."
		var path := source.track_get_path(track)
		var node := root.get_node_or_null(NodePath(path.get_concatenated_names()))
		if node == null or path.get_subname_count() == 0:
			return "Unresolved property path: %s." % path
		var property: Variant = node.get_indexed(NodePath(":" + path.get_concatenated_subnames()))
		if typeof(property) not in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT]:
			return "The target property is not scalar: %s." % path
	return ""

func occurrences(node: Node, animation: Animation) -> int:
	var count := 0
	if node is AnimationPlayer:
		for clip in node.get_animation_list():
			if node.get_animation(clip) == animation:
				count += 1
	for child in node.get_children():
		count += occurrences(child, animation)
	return count

func preview() -> void:
	var reason := guard()
	if not reason.is_empty():
		panel.show_error(reason)
		return
	var result := Transfer.plan_by_identities(panel.source(), panel.destination(), panel.selected_identity_set(), panel.start_time.value, panel.end_time.value)
	if not result.ok:
		panel.show_error(result.error)
		return
	result["request"] = current_request()
	panel.show_preview(result)

func current_request() -> PackedByteArray:
	return var_to_bytes([panel.player.get_instance_id(), panel.picker_name(panel.source_picker),
		panel.picker_name(panel.destination_picker), panel.animation_state(panel.source()), panel.animation_state(panel.destination()),
		panel.start_time.value, panel.end_time.value, panel.selected_identity_set()])

func transfer() -> void:
	var had_preview := not panel.preview_plan.is_empty()
	var reason := guard()
	if not reason.is_empty():
		panel.show_error(reason)
		return
	if panel.preview_plan.is_empty():
		panel.show_error("A clip changed after preview. Preview again." if had_preview else "Preview first.")
		return
	if panel.preview_plan.get("request", PackedByteArray()) != current_request():
		panel.show_error("The request changed after preview. Preview again.")
		return
	if Transfer.stamp(panel.source()) != panel.preview_plan.source_stamp or Transfer.stamp(panel.destination()) != panel.preview_plan.destination_stamp:
		panel.show_error("A clip changed after preview. Preview again.")
		return
	# Validate again immediately before committing. No cached plan is applied blindly.
	var result := Transfer.plan_by_identities(panel.source(), panel.destination(), panel.selected_identity_set(), panel.start_time.value, panel.end_time.value)
	if not result.ok:
		panel.show_error(result.error)
		return
	var destination: Animation = panel.destination()
	var manager := get_undo_redo()
	manager.create_action("Transfer animation segment", UndoRedo.MERGE_DISABLE, destination)
	manager.add_do_method(self, "apply_state", destination, result.after)
	manager.add_undo_method(self, "apply_state", destination, result.before)
	manager.commit_action()
	panel.sync()
	panel.invalidate()
	panel.status.text = "Transferred %d %s. Undo/Redo in the editor; save the scene normally." % [result.keys, "key" if result.keys == 1 else "keys"]

func apply_state(destination: Animation, state: Animation) -> void:
	Transfer.apply_tracks(destination, state)
	panel.invalidate("animation changed by Transfer or Undo/Redo")
	EditorInterface.mark_scene_as_unsaved()
