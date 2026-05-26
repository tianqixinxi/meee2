# @meee1/recap-core

Cross-platform recap contracts and pure recap logic for meee2 workspaces.

This package is intentionally framework-free. It must not import React, browser
APIs, Swift DTOs, localStorage, or app singletons. Runtime-specific callers adapt
their source state into the narrow recap input types exported here.
