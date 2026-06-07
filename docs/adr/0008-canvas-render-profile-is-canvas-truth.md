# Canvas Render Profile Is Canvas Presentation Truth

Canvas presentation is modeled through a canvas-owned Render Profile: declarative Render Logic plus user-editable Render Values. Template Canvas and ordinary Canvas share the same canvas model; template identity lives in metadata and publication state, while legacy `kind=template` is migrated away. `monitor` remains a CanvasKind for v1 compatibility, but workflow, monitor, scene, and board rendering all move toward Canvas Object and Canvas Relation resolution.

Render Logic is changed through approved proposals because it can reshape what the canvas means, while Render Values may be written directly by UI gestures because they are presentation preferences inside the canvas content. The trade-off is that the canvas layer now owns a stronger render resolver and profile file, but nodes can stay narrowed to executable or owned work instead of carrying visual-only identities such as Artifacts, seats, backgrounds, and labels.

Legacy `sceneSpec`, `monitorSpec`, node widgets, and node layout remain migration sources only. Canvas Scene decisions from ADR-0006 and Rules Orchestrator decisions from ADR-0007 still hold, but the Render Profile is the implementation path for presenting those scenes rather than a parallel scene-specific rendering model.
