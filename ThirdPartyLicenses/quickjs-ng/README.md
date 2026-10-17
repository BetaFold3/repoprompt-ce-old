# QuickJS-ng

`Sources/CRepoPromptCodeMode/vendor/quickjs-ng/` holds an unmodified subset of
QuickJS-ng 0.17.0, the JavaScript engine behind the experimental `code_mode`
executor (MIT License; copy in [`LICENSE`](LICENSE)).

- Upstream: <https://github.com/quickjs-ng/quickjs>, tag `v0.17.0`.
- Source archive: <https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.17.0.tar.gz>,
  SHA-256 `559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9`
  (verified before copying, 2026-10-18).
- Copied files: the four library compilation units `quickjs.c`, `libregexp.c`,
  `libunicode.c` and `dtoa.c`, plus exactly the headers they include. `quickjs-libc`,
  the CLI, the compiler, tests and generators are not vendored.
- Per-file checksums: [`vendor.sha256`](vendor.sha256); check from the repository root with
  `shasum -a 256 -c ThirdPartyLicenses/quickjs-ng/vendor.sha256`.

To update, download the new tag's archive, verify its checksum, replace the same file set
verbatim, regenerate `vendor.sha256`, and update this record and `THIRD_PARTY_NOTICES.md`.
