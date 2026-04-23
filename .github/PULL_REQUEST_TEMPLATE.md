## Summary

<!-- One or two sentences: what does this change, and why. Link any related issue. -->

## Changes

<!-- Bullet list of the notable changes. Mention touched modules: Services / Views / Board / CLI / plugin-kit / ... -->

-
-

## Test Plan

<!-- Concrete, checkable items. Delete what doesn't apply. -->

- [ ] `swift build` clean
- [ ] `swift test` passes
- [ ] `./scripts/validate.sh` passes
- [ ] Manually verified affected surface (menu bar / TUI / CLI / web board / plugin load / hook flow)
- [ ] Screenshots or GIF attached for UI changes
- [ ] If the on-disk `SessionData` schema changed: bumped `SessionData.currentSchemaVersion` and added a migrator with tests

## Notes for Reviewers

<!-- Optional: risky bits, alternatives considered, follow-up work. -->
