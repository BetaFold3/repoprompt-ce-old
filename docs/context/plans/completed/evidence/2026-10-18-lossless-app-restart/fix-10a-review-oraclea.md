# Step 10a review: OracleA

Scope: read when the task touches test isolation of the window-session file (WindowSessionStore) or Step 10 of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA review of the window-session test-isolation change

The change separates production-path calculation from session-file selection, redirecting DEBUG XCTest runs to a lazily initialized, process-stable temporary URL. XCTest detection matches `GlobalSettingsStore.makeSharedStore()`. Release builds and non-XCTest app runs retain the existing path and directory-creation behavior. The updated window-path assertions check both the production location and test isolation.

## Findings

No in-scope P0–P3 findings. The unrelated workspace-root changes were excluded from review.

All three acceptance criteria are satisfied by the supplied code. The static temporary URL also ensures repeated calls use the same file rather than generating separate files for readers and writers.

Validation is supportive but qualified: the two source-built suites provide relevant evidence; the 33 stale artifact reruns do not validate the current source snapshot. The observed live-file mtime change cannot independently establish a test write while the real app is running.

## Recommendations

Approve Step 10a with no required changes. Keep the commit limited to the session-store implementation and window-path assertions, and preserve the stale-artifact caveat in the validation record.
