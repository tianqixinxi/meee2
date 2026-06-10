# Artifact Views Belong To Artifacts

An Artifact may expose multiple named views over the same underlying data, such as table, list, kanban, raw, or json. Those views are Artifact-owned presentation metadata: they travel with the Artifact across Canvas node cards, Inspector detail, and the Artifacts rail.

Canvas and Widget surfaces may choose a default view, remember a local selection, and render the selected projection, but they do not own the view definitions. This keeps one data object from being forked into multiple display-only artifacts and keeps Artifact history focused on data changes.

Artifact data writes and Artifact view writes are separate. `submit_node_output`, `attach_artifact_to_node`, and `update_artifact` write data versions only. View changes use `update_artifact_views`, upsert by stable view id, and do not append `PlannerArtifactVersion` records.

When an Artifact has no saved views, renderers may derive default views from the current payload shape. Derived views are a display fallback, not persisted metadata, until an agent or UI writes explicit Artifact Views through the view API.
