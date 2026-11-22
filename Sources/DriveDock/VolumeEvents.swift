import Darwin
import Dispatch

/// File system events (a volume mounted or left, a server stopped answering) straight from
/// the kernel via kqueue.
///
/// NSWorkspace's mount notifications would tell the same, but subscribing to them starts
/// AppKit's volume observer, which reads the attributes of every volume that appears. On an
/// SMB server that stopped answering mid-reconnect that call never returns – the thread hangs
/// in the kernel, and DriveDock could no longer quit (the process stays in "exiting" until
/// the volume recovers). The kernel event carries only flags and touches no volume.
final class VolumeEvents {
    private let source: DispatchSourceRead

    /// `handler` runs on `queue` with the `VQ_*` flags of all events since the last call.
    init?(queue: DispatchQueue = .main, handler: @escaping (UInt32) -> Void) {
        let kq = kqueue()
        guard kq >= 0 else { return nil }
        var event = kevent(ident: 0, filter: Int16(EVFILT_FS), flags: UInt16(EV_ADD | EV_CLEAR),
                           fflags: 0, data: 0, udata: nil)
        guard kevent(kq, &event, 1, nil, 0, nil) == 0 else {
            close(kq)
            return nil
        }
        source = DispatchSource.makeReadSource(fileDescriptor: kq, queue: queue)
        source.setEventHandler {
            var flags: UInt32 = 0
            var received = kevent()
            var noWait = timespec()
            while kevent(kq, nil, 0, &received, 1, &noWait) > 0 {
                flags |= received.fflags
            }
            if flags != 0 { handler(flags) }
        }
        source.setCancelHandler { close(kq) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
