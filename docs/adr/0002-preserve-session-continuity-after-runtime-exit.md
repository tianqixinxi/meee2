# Preserve session continuity after runtime exit

Reliable Session Intake treats process exit, stale PID files, hook events, transcripts, and provider state as Session Observations of a Canonical Session Identity rather than as independent session lifetimes. meee2 preserves the stored session record when the runtime exits and only marks its runtime state as ended or recoverable, because deleting records keeps live lists tidy but breaks restart continuity, user-owned notes, queued messages, and stale-id recovery. Default Live Session Surfaces filter historical records instead of deleting them.
