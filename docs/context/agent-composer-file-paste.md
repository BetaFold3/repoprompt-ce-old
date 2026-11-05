# Agent composer file paste

Scope: read when the task touches Finder file paste, file-versus-preview precedence, composer PDF/HTML document admission and import, or the shared AppKit text-view image-drop admission path.
Authority: Authoritative
Last-verified: 2026-11-05

## Contract and ownership

- `ImagePasteboardTypes.filePayload` in `Sources/RepoPrompt/Infrastructure/UI/TextField/ResizableTextField.swift` owns explicit `public.file-url` precedence. It inspects every advertised file item (with a board-level fallback), not plain text or generic URL conversion.
- All explicit files must decode to existing, readable, non-directory image files before the image callback may consume the selection. Any document, malformed URL, missing/unreadable file, or directory defers the whole selection to native handling. A mixed PNG/PDF selection must not attach just the PNG.
- Explicit image files are prepared from their original URLs only. Their clipboard icons, previews, text paths, and `NSImage` renderings cannot substitute for them, even if a file disappears between admission and preparation.
- `AgentImageInputAdapter` in `Sources/RepoPrompt/Features/AgentMode/Views/AgentInputBar.swift` enforces this at both admission and preparation. Without explicit file payloads, its existing raw-image and plain-text heuristics remain unchanged.
- `ImageAwareTextView` vetoes deferred file payloads at paste, image-type `readSelection`, and image-drop admission. Preparing originals rather than previews remains the adapter's responsibility. A source-wide caller search found `AgentInputBar` is the only production `onImagePaste` caller; the other references are forwarding/wiring inside `ResizableTextField`. Rejected image callbacks in `performDragOperation` delegate to AppKit rather than reporting success unconditionally.
- Do not blacklist ICNS: an actual ICNS file or a standalone copied icon can still be an image. PDF renderability through `NSImage` does not make a PDF an image file.

## Document admission (PDF/HTML)

The [PDF/HTML attachment plan](plans/2026-11-04-agent-document-attachments.md) owns the overall design; the backend model, managed store, manifest and carriers are described there. Composer admission works as follows.

- `ComposerDocumentFileAdmission.classify` (in `ResizableTextField.swift`) classifies only explicit `public.file-url` references, using `ImagePasteboardTypes.explicitFileReferences`. It resolves Finder file-reference URLs (`file:///.file/id=…`) with `filePathURL` before reading the extension. It never uses previews, icons, plain-text paths or copied HTML text, so ordinary copied HTML stays text.
- Each slot is a `ComposerFileReference`: `.url`, `.notFile` (a drop provider that advertises no file URL), or `.unreadable` (an advertised file URL that failed to load, decode, or resolve, including a Finder reference whose file is gone). Suggested names are never used.
- Classification has three results:
  - `.documents`: every reference is a `.pdf`, `.html` or `.htm` file. Duplicates are dropped and order is kept.
  - `.rejected(unreadableReferenceMessage)`: any explicit file reference is unreadable, beside documents or images alike. The whole gesture is refused visibly; it never falls back to a preview, icon, image path or filename text. This is a recorded, reversible assumption (it also covers an image-only selection with a dead reference).
  - `.rejected(mixedSelectionMessage)`: documents are mixed with images or other files. The whole gesture is refused and nothing attaches; there is never partial success. This is a recorded, reversible assumption.
  - `.notDocuments`: every reference resolved and none is a document (or there is no file reference), so the existing image and native path runs unchanged.
- A missing or directory `.pdf` is still claimed, so the import reports it rather than falling back to filename insertion.
- `ImageAwareTextView.documentFileHandler` is opt-in, and only `AgentInputBar` installs it (`ResizableTextField(onDocumentFiles:)`). Other callers keep the image and native behavior described above.
- When installed, the handler runs before image and native handling in `paste`, the coordinator's `paste:` command, `readSelection`, drag admission (`draggingEntered`, `draggingUpdated`, `prepareForDragOperation`) and `performDragOperation`.
  - A claimed selection never inserts text or an icon and never reaches the image callback, even when the handler refuses it.
  - A refused drop returns false.
- The surrounding SwiftUI drop (`AgentInputBar.handleImageDrop`) has the same rule, through `AgentModeViewModel.admitDroppedComposerFiles`.
  - When any provider advertises a file URL, the destination is reserved synchronously at gesture start, before the asynchronous URL load.
  - `AgentImageInputAdapter.loadDroppedFileReferences` then loads each provider's explicit file URL in provider order: `.notFile` for no file URL, `.unreadable` for a failed load.
  - The reservation's destination is checked before any branch, including the image fallback: a drop whose composer was reset, closed, replaced, re-bound or frozen while its URLs loaded is discarded. A replaced or re-bound session shows the neutral "files were not attached because this session changed" message, image-only drops included; reset, close and freeze stay quiet.
  - Resolved image-only drops release the reservation and reach the unchanged image loader (`loadDroppedImages`); the real adapter still prepares the original image file. The transient "Checking dropped files…" row and the drop's optimistic `true` remain.
  - Drops with no file-URL provider skip classification and reservation entirely.
- `AgentModeViewModel+ComposerDocumentImport.swift` owns the import.
  - Every gesture first calls `reserveComposerDocumentAdmission`, which captures the tab, session object, persisted binding and binding generation. A sync gesture then starts its copy at once; a drop starts it after its URLs load. The reservation spans both phases.
  - `attachDocumentFiles(tabID:urls:)` copies the files into `AgentDocumentAttachmentStore` as one atomic batch on the store actor. A chip appears only after its managed original exists.
  - While a reservation is registered, the composer shows "Checking dropped files…" (URLs still loading) or an importing row, and send and schedule are refused. The submit claim rejects with `documentImportInProgress`.
  - The importing row has a Cancel control (`cancelComposerDocumentImports`): it settles every reservation of the tab as discarded, cancels running copies (`composerDocumentImportCopyTasks`; the store checks cancellation before publishing), and keeps the draft and existing chips. A stuck resolving drop is released this way; there is no timeout.
  - The reverse gate: while any composer send or schedule claim is active in the window (`isComposerSubmitInFlight`), a document gesture is refused visibly (`composerSubmitInFlightDocumentMessage`, past tense because the row can outlive the send) and no copy starts, because that submit captures and clears its composer after awaits (a schedule may also roll its snapshot back). Window-wide scope is a recorded, reversible assumption covering a first send's fresh destination tab.
  - The reservation is re-checked before a copy starts and again before it attaches. The check reads `sessions[tabID]` only and never creates or redirects a session. Switching tabs never moves it. A closed tab or composer reset (`cancelComposerDocumentImports`) discards it. A replaced session or binding transition discards it with a visible message. A shutdown freeze refuses new imports and discards in-flight ones without changing the frozen composer.
  - A failure shows a dismissible per-tab composer message ending "Nothing was attached." and adds no chip. Typed text is never changed.
- A document chip (`AgentAttachmentsStrip`) shows the original filename and kind. Its tooltip shows name, kind and size, never a path. Removing a chip removes only the reference; the managed original is retained, and there is no garbage collection.
- An opted-in composer text view also registers `public.file-url` as a drag type (`acceptableDragTypes`); NSTextView alone registers only the legacy filenames and `public.url` types.
- Document-only sends, scheduled-send props, editing and removal (`removingDocumentAttachmentIDs`), user-bubble chips, and recovery-list attachment names include documents. Attachment-strip snapshots and reserved heights take documents explicitly (no defaults).
- Existing scheduled-message editors and other agent text fields do not accept new document drops.
- Admission does not check provider capability. The Step 2 send preflight blocks unsupported destinations and keeps the draft.

## Limits

Without an installed document handler, native fallback is not a document attachment or absolute-path insertion feature. A private-pasteboard AppKit characterization with a PDF URL, ICNS preview, and filename text inserted only the basename. Do not claim a usable original-file reference is restored without live evidence and an explicit insertion contract.

If a clipboard has an unavailable/non-image file URL alongside otherwise legitimate image bytes, explicit-file precedence intentionally prevents attaching those bytes. Native fallback can insert nothing when there is no usable text representation; the basename characterization above applies only to its specific fixture. Legacy-only `NSFilenamesPboardType` or file URLs advertised only as `public.url` retain the old heuristics, not this new explicit-file rule.

Unverified, not guaranteed: a drop source whose provider type only conforms to `public.file-url` (file promises from Photos, Mail or browsers) and fails to load would now be refused as unreadable instead of reaching the image path; a non-document, non-image file (for example `.txt`) dragged onto the opted-in text view falls through to native NSTextView handling, whose insertion is uncharacterized. Both need live evidence before any change.

For images, the asynchronous SwiftUI `NSItemProvider` drop path keeps its previous behavior and is not at parity with clipboard paste. Only document admission shares the explicit-file rule described above. Document classification is extension-only: there is no content sniffing, no OCR and no upload. No cause for the user's reported recent onset was established. The literal “Pasted icon” label was not traced to a source string.

## Validation

`make dev-test FILTER=AgentImageInputAdapterTests` covers genuine CFURL-created file-reference wire strings (image, document, and mixed selection), document/icon combinations, malformed and missing file URLs, mixed selection order, image originals and partial disappearance, unreadable images, raw image cleanup, text-path compatibility, private-board native text fallback, board-level URL data, image-named directories, text-view reentry/drop admission, and accepted/rejected/absent-callback drag completion.

`make dev-test FILTER=AgentComposerDocumentAdmissionTests` covers the following:

- document classification from genuine file-reference wire strings with ICNS or PNG previews and filename text
- Unicode and `.HTM` names, multiple files with deduplication, claimed missing and directory documents
- mixed selections refused in either order, and image, copied-HTML and path text left as non-documents
- text-view paste, `readSelection`, drag admission and drop, with and without the opt-in handler
- SwiftUI provider loading and mixed drops
- held real `NSItemProvider` loads through `admitDroppedComposerFiles`:
  - the reservation and send block before the URLs load
  - a tab switch during the load still attaches to the original tab
  - reset, close (not re-created), replacement, rebinding and freeze during the load each discard the drop with no copy
  - image-only loads release the reservation and keep the image path; a failed load (even with a PNG preview) and a mixed drop are refused visibly with no fallback
  - a late image drop after reset, close, rebinding or freeze is discarded before the image path (rebinding shows the changed message)
  - a resolved PNG file still reaches the real image adapter as its original
- an unresolved Finder reference (document or image) refused whole on paste, `readSelection` and drop with no text or image
- Cancel before the copy task starts and while resolving (draft kept, no original, send gate released); cancellation during an active copy is not deterministically tested
- document gestures refused visibly while a send claim is active, then accepted after release
- the composer text view's `public.file-url` drag registration
- managed import from outside the workspace (byte identity, survival after the source is removed, draft preserved)
- missing, unreadable and directory failures with nothing attached
- tab switch, reset, close, session replacement, binding transition and shutdown fences
- the submit-claim gate
- chip removal keeping the original
- strip, schedule and import presentation

`AgentScheduledSendDispatchTests` covers the import gate on a schedule claim, refusal of a gesture during the claim, and a document-only composer schedule carrying its documents durably. `AgentRecoveryVMProducerAdmissionTests` covers a held composer intent with a document: its recovery row names the document and Edit places it back with the text.

Tests use private pasteboards and temporary files; they must not overwrite the general clipboard. They validate adapter/AppKit behavior, not the installed app. After the owner reported rebuilding and relaunching, one HTML and two PDF attachments arrived with managed-original paths and matching byte counts; the local agent successfully read the HTML source and extracted text from both PDFs using PDF-capable tools. This is live attachment delivery and file-access evidence, not just filename insertion. RepoPrompt `read_file` remains workspace-scoped and refused the managed path; local shell access succeeded without expanding its allowlist.

The precise paste/drop routes used for those attachments were not recorded. Both drop surfaces, visible importing/failure/chip presentation, TCC behavior, independently verified build provenance, source movement, and attachment survival across a subsequent restart/scheduled delivery remain separate live acceptance checks. App launch or relaunch requires action-boundary approval.
