# Descriptor-bound export staging report

## Root cause

Export staging validation opened `.barrel-export-staging` with `O_NOFOLLOW`, but closed that descriptor before copying. Copy, hash, identity capture, exclusive publication, cleanup, and recovery then resolved stored pathnames again. Replacing the validated directory with a symlink could therefore redirect later operations.

## Change

- Keep validated destination and staging directory descriptors open for the complete export transaction.
- Create each staged child with `openat(O_CREAT | O_EXCL | O_NOFOLLOW, 0600)` and copy through source/staged file descriptors.
- Hash and capture identity from the staged file descriptor.
- Publish with `renameatx_np(stagingDirFD, stagingName, destinationDirFD, destinationName, RENAME_EXCL)`.
- Clean staged children with `unlinkat` against the validated staging descriptor.
- Reject replacement of the staging directory entry after validation by comparing its `fstatat(..., AT_SYMLINK_NOFOLLOW)` identity with the open descriptor.
- During recovery, validate the journaled path relationship, reopen both directories without following symlinks, and perform destination/staging lookup, identity, hashing, publication, and cleanup relative to those descriptors.

Journal ordering and recovery phases are unchanged: the pending export is persisted before publication, and final history state is committed only after descriptor-bound verification of the published file.

## Adversarial coverage

- `testExportStagingDirectoryReplacementCannotRedirectCopyOrCleanup` swaps the staging directory for an attacker symlink immediately after validation and verifies rejection without copying outside the validated directory.
- `testExportStagingDirectoryReplacementCannotRedirectCleanup` swaps it after staging and injects failure, proving cleanup removes the child from the original validated directory and leaves the attacker sentinel untouched.
- Red verification temporarily restored pathname-based copy; the first adversarial test failed by observing the staged UUID in the attacker directory.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HistoryRepositoryTests/testExportStagingDirectoryReplacement` — 2 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — 169 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make verify` — app built and verification launch succeeded.
- `git diff --check` — clean.
