# Animation Segment Transfer

> **Safety notice — stop using v0.1.0.** Animation Segment Transfer v0.1.0 has a confirmed editing fault in Godot 4.7.2. After a transfer into an animation with a selected key, dragging a key and using Undo can move the wrong key and overwrite existing animation data. Stop using this version until a corrected release is available.

**No corrected release is available.** The packaged GitHub downloads have been suspended. Original source and tagged source archives remain accessible for the record; they are affected, not safe replacements. The Godot Store listing has been set to draft, but its anonymous download availability has not been confirmed.

## If you already installed v0.1.0

Open **Project > Project Settings > Plugins**. In the **Animation Segment Transfer** row, turn off the checkbox in the **Enabled** column. This removes the add-on's controls. Disabling does not repair existing animation data or establish that existing Undo/Redo history is safe.

Do not follow the installation, Transfer, Undo/Redo or save instructions retained in old v0.1.0 documentation. Do not use further key dragging or Undo/Redo as a recovery attempt. Keep any known-good copies untouched; do not overwrite them with an affected scene. Do not discard unsaved work merely to disable the add-on. Disabling or reopening the editor is not a recovery guarantee.

The disable step was checked in Godot 4.7.2 on Linux. It removed the controls and remained disabled after restarting a disposable test project, without changing that project's saved animation scene. This is not evidence of recovery after damage, safety of prior history, or a fix for the editing fault.

MIT licensed. Original source and release history are preserved.
