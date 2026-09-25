/// A later claim replaced this start's; nothing current was touched.
struct CaptureSuperseded: Error {}

/// One counter, which is the newest claim; calls arrive on one serial queue, so claims keep the order opens began.
struct CaptureClaims {
    private var latest: Int64 = 0

    mutating func claim() -> Int64 {
        latest += 1
        return latest
    }

    /// Refuses a stale owner; an unowned (legacy) start claims afresh, so it still fences older owned starts.
    mutating func admit(_ owner: Int64?) throws {
        guard let owner = owner else {
            latest += 1
            return
        }
        guard owner == latest else { throw CaptureSuperseded() }
    }
}
