# Local Session Readiness gates M0 onboarding

M0 onboarding is gated by Local Session Readiness rather than by agent runtime installation alone. The app may allow Degraded Entry into the workspace when required readiness checks are failing, but that state is not considered ready and must keep unresolved Recovery Actions visible; this keeps first-run friction low without hiding broken local session ingestion.
