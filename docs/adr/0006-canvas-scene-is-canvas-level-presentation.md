# Canvas Scene Is Canvas-Level Presentation

Canvas Scene is modeled as a canvas-level presentation layer, not as a node widget or a hidden bootstrap node. This keeps nodes reserved for AI sessions or human-owned work, while maps, poker tables, seats, cards, routes, and other scene entities remain presentation state, Template Assets, or node-produced Artifacts. The trade-off is that the canvas layer now owns scene rendering and artifact binding, but it avoids creating fake executable nodes whose only purpose is to host a visual surface.

ADR-0008 makes Canvas Render Profile the presentation truth for this layer. `sceneSpec` may still be decoded as a legacy migration source, but new scene presentation should be expressed as Canvas Objects, Canvas Relations, Render Logic, and Render Values.
