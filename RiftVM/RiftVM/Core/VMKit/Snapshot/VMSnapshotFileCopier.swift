//
//  VMSnapshotFileCopier.swift
//  RiftVM
//

import Foundation
import Darwin

/// Copies one bundle item for a snapshot with progress and cancellation
/// *inside* a large file.
///
/// Regular files go through `copyfile(3)` with `COPYFILE_CLONE`, so a copy on
/// one APFS volume is still an instant clone. When the file system cannot
/// clone, `copyfile` falls back to a data copy and reports how far it is, which
/// is also where cancellation is honoured.
///
/// Everything that is not a regular file (directories, symbolic links, ...)
/// keeps using `FileManager.copyItem`, so its behaviour is unchanged.
enum VMSnapshotFileCopier {
    struct Cancelled: Error {}

    /// - Parameters:
    ///   - allowClone: `false` forces a data copy. Tests use it to exercise
    ///     the progress path on a volume that would otherwise clone.
    ///   - isCancelled: polled before the copy and at every progress step.
    ///   - progress: logical bytes of `source` written so far. Not called for
    ///     clones or for items that are not regular files.
    /// - Throws: `Cancelled` when `isCancelled` returned true, after removing
    ///   the partial destination. Any other failure is a Cocoa file error.
    static func copyItem(
        at source: URL,
        to destination: URL,
        allowClone: Bool = true,
        isCancelled: () -> Bool = { false },
        progress: (UInt64) -> Void = { _ in }
    ) throws {
        if isCancelled() { throw Cancelled() }

        let sourcePath = source.path(percentEncoded: false)
        var status = stat()
        guard lstat(sourcePath, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            // Missing items also land here so the error is FileManager's own.
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }

        try withoutActuallyEscaping(isCancelled) { isCancelled in
            try withoutActuallyEscaping(progress) { progress in
                try copyRegularFile(
                    sourcePath: sourcePath,
                    destination: destination,
                    allowClone: allowClone,
                    context: CallbackContext(isCancelled: isCancelled, progress: progress)
                )
            }
        }
    }

    private final class CallbackContext {
        let isCancelled: () -> Bool
        let progress: (UInt64) -> Void
        var cancelled = false

        init(isCancelled: @escaping () -> Bool, progress: @escaping (UInt64) -> Void) {
            self.isCancelled = isCancelled
            self.progress = progress
        }
    }

    private typealias StatusCallback = @convention(c) (
        Int32, Int32, copyfile_state_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Int32

    private static let statusCallback: StatusCallback = { what, stage, state, _, _, rawContext in
        guard let rawContext else { return COPYFILE_CONTINUE }
        let context = Unmanaged<CallbackContext>.fromOpaque(rawContext).takeUnretainedValue()
        if context.cancelled || context.isCancelled() {
            context.cancelled = true
            return COPYFILE_QUIT
        }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0, copied > 0 {
                context.progress(UInt64(copied))
            }
        }
        return COPYFILE_CONTINUE
    }

    private static func copyRegularFile(
        sourcePath: String,
        destination: URL,
        allowClone: Bool,
        context: CallbackContext
    ) throws {
        let destinationPath = destination.path(percentEncoded: false)
        guard let state = copyfile_state_alloc() else {
            throw fileError(code: ENOMEM, destinationPath: destinationPath)
        }
        defer { copyfile_state_free(state) }

        let unmanagedContext = Unmanaged.passUnretained(context)
        copyfile_state_set(
            state,
            UInt32(COPYFILE_STATE_STATUS_CB),
            unsafeBitCast(statusCallback, to: UnsafeRawPointer.self)
        )
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanagedContext.toOpaque())

        // Like FileManager.copyItem: never overwrite, never follow a link.
        var flags = UInt32(COPYFILE_ALL) | UInt32(COPYFILE_EXCL) | UInt32(COPYFILE_NOFOLLOW)
        if allowClone {
            flags |= UInt32(COPYFILE_CLONE)
        }

        let result = withExtendedLifetime(context) {
            copyfile(sourcePath, destinationPath, state, copyfile_flags_t(flags))
        }
        guard result != 0 else { return }

        let code = errno
        // EEXIST means the destination belongs to someone else; leave it.
        if code != EEXIST {
            unlink(destinationPath)
        }
        if context.cancelled {
            throw Cancelled()
        }
        throw fileError(code: code, destinationPath: destinationPath)
    }

    private static func fileError(code: Int32, destinationPath: String) -> Error {
        let cocoaCode: CocoaError.Code
        switch code {
        case ENOSPC, EDQUOT: cocoaCode = .fileWriteOutOfSpace
        case EEXIST: cocoaCode = .fileWriteFileExists
        case ENOENT: cocoaCode = .fileNoSuchFile
        case EACCES, EPERM: cocoaCode = .fileWriteNoPermission
        case EROFS: cocoaCode = .fileWriteVolumeReadOnly
        default: cocoaCode = .fileWriteUnknown
        }
        return CocoaError(cocoaCode, userInfo: [
            NSFilePathErrorKey: destinationPath,
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        ])
    }
}
