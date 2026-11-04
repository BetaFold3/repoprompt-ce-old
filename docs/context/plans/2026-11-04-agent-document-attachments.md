# Agent composer PDF and HTML attachments

Scope: read when the task touches implementing or validating Agent Mode Finder PDF/HTML document attachments.
Authority: Authoritative

## Goal and acceptance

Finder copy/paste and drag/drop onto the text view or surrounding composer create removable document attachments, not icons, filenames, or inserted absolute paths. PDF and HTML originals copied from outside the workspace remain accessible after source movement, queued sending, restart, and subsequent agent reads. File-import or access failures are explicit and preserve the user's input. PNG/JPEG behavior is unchanged and is not part of this feature.

Implement the owner-approved proposal: verify actual agent access; add durable document attachments; connect paste and both drop surfaces; preserve attachments through draft, queue, transcript, recovery and scheduled sends; wire provider delivery and validate end to end. Do not fake images, route binary PDF through text decoding, broaden directory permissions, or imply remote transfer.

## Execution and evidence

The reviewable execution units, assumptions, validation, and review findings live in the local evidence directory: `docs/reviews/2026-11-04-finder-file-paste/evidence/`. The implementation sequence groups the approved proposal by dependency so no visible attachment can ship before its lifecycle and delivery are wired.

Step 1 — done | rounds 0/2 | open: none | downgraded: none | assumed: local managed originals; exact composer access remains Step 3 | deferred: crash-left staging cleanup and fault-injection coverage (evidence/step1-review-disposition.md)
Step 2 — todo | rounds 0/2 | open: none | downgraded: none | assumed: additive decoding defaults | deferred: none
Step 3 — todo | rounds 0/2 | open: none | downgraded: none | assumed: preserve image-only paths | deferred: none

## Decisions

- The owner requires actual PDF/HTML file attachments; filename/path insertion is a failure.
- PNG/JPEG already work and are outside this feature's scope.
- The owner authorized implementation with scoped workers, independent OracleA/OracleB review, and local commits per step.
- If signing fails once, the owner authorized an unsigned fallback, recording it and later re-signing; repository action-boundary approval requirements still apply.
