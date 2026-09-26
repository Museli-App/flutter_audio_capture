/// A later claim replaced this start's; nothing current was touched.
struct CaptureSuperseded: Error {}

/// One counter, which is the newest claim; calls arrive on one serial queue, so claims keep the order opens began.
struct CaptureClaims {
    private var latest: Int64 = 0

    mutating func claim() -> Int64 {
        latest += 1
        return latest
    }

    /// Refuses every owner but the newest claim's.
    func admit(_ owner: Int64) throws {
        guard owner == latest else { throw CaptureSuperseded() }
    }
}
