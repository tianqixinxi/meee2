// Build metadata for the "About Meee2" panel (dev builds show commit/branch).
//
// This committed copy holds placeholder values so a plain `swift build`
// (CI's debug job, a fresh checkout) always compiles. scripts/gen-build-info.sh
// OVERWRITES it with the real git commit/branch/date and is wired into
// `pnpm build:dev` and `build.sh`. A local dev build therefore leaves this file
// modified in your working tree — that's expected; do NOT commit those changes
// (the placeholder below is the canonical committed state).
enum BuildInfo {
    static let gitCommit = "unknown"
    static let gitBranch = "unknown"
    static let buildDate = "unknown"
}
