# Agent composer file paste

Scope: read when the task touches Finder file paste, file-versus-preview precedence, or the shared AppKit text-view image-drop admission path.
Authority: Authoritative
Last-verified: 2026-11-04

## Contract and ownership

- `ImagePasteboardTypes.filePayload` in `Sources/RepoPrompt/Infrastructure/UI/TextField/ResizableTextField.swift` owns explicit `public.file-url` precedence. It inspects every advertised file item (with a board-level fallback), not plain text or generic URL conversion.
- All explicit files must decode to existing, readable, non-directory image files before the image callback may consume the selection. Any document, malformed URL, missing/unreadable file, or directory defers the whole selection to native handling. A mixed PNG/PDF selection must not attach just the PNG.
- Explicit image files are prepared from their original URLs only. Their clipboard icons, previews, text paths, and `NSImage` renderings cannot substitute for them, even if a file disappears between admission and preparation.
- `AgentImageInputAdapter` in `Sources/RepoPrompt/Features/AgentMode/Views/AgentInputBar.swift` enforces this at both admission and preparation. Without explicit file payloads, its existing raw-image and plain-text heuristics remain unchanged.
- `ImageAwareTextView` vetoes deferred file payloads at paste, image-type `readSelection`, and image-drop admission. Preparing originals rather than previews remains the adapter's responsibility. A source-wide caller search found `AgentInputBar` is the only production `onImagePaste` caller; the other references are forwarding/wiring inside `ResizableTextField`. Rejected image callbacks in `performDragOperation` delegate to AppKit rather than reporting success unconditionally.
- Do not blacklist ICNS: an actual ICNS file or a standalone copied icon can still be an image. PDF renderability through `NSImage` does not make a PDF an image file.

## Limits

Native fallback is not a new document attachment or absolute-path insertion feature. A private-pasteboard AppKit characterization with a PDF URL, ICNS preview, and filename text inserted only the basename. Do not claim a usable original-file reference is restored without live evidence and an explicit insertion contract.

If a clipboard has an unavailable/non-image file URL alongside otherwise legitimate image bytes, explicit-file precedence intentionally prevents attaching those bytes. Native fallback can insert nothing when there is no usable text representation; the basename characterization above applies only to its specific fixture. Legacy-only `NSFilenamesPboardType` or file URLs advertised only as `public.url` retain the old heuristics, not this new explicit-file rule.

The separate asynchronous SwiftUI `NSItemProvider` drop path (`loadPreparedImages`) retains its previous behavior; this fix does not establish parity with clipboard paste. No cause for the user's reported recent onset was established. The literal “Pasted icon” label was not traced to a source string.

## Validation

`make dev-test FILTER=AgentImageInputAdapterTests` covers genuine CFURL-created file-reference wire strings (image, document, and mixed selection), document/icon combinations, malformed and missing file URLs, mixed selection order, image originals and partial disappearance, unreadable images, raw image cleanup, text-path compatibility, private-board native text fallback, board-level URL data, image-named directories, text-view reentry/drop admission, and accepted/rejected/absent-callback drag completion.

Tests use private pasteboards and temporary files; they must not overwrite the general clipboard. They validate adapter/AppKit behavior, not the installed app. Live Finder copy/paste and drag/drop (both text view and surrounding SwiftUI target), TCC-protected folders, running-build provenance, and a restored usable-file reference remain separate acceptance checks. App launch or relaunch requires action-boundary approval.
