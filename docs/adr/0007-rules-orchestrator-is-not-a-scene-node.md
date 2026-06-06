# Rules Orchestrator Is Not a Scene Node

Rules-assisted Canvas Scenes use a deterministic Rules Orchestrator at the canvas runtime layer. The orchestrator controls turn order, legal next actions, role-specific context slices, and whether a produced action can advance Scene State. It is not represented as a node and does not call an AI model.

For Poker Table, GM remains a scene role but not the control plane. GM is a human responsibility node for rulings, approvals, and exceptional cases. Dealer is represented as `Dealer / Table State`: the node-scoped home for authoritative `game-state.json` and `action-log.json`, but not an AI session node. The system submits those artifacts on behalf of the Rules Orchestrator.

Authoritative scene state stays node-scoped by writing system-generated artifact versions into the Dealer output slots. This preserves the existing Artifact model and avoids introducing canvas-level artifacts, while still making it clear that player agents only produce proposed Player Action Artifacts.

The trade-off is that canvas runtime now owns a small amount of deterministic game logic. That is preferable to letting an AI GM or Dealer decide flow control, because turn order, hidden information, and legal action validation need predictable behavior.
