import CoreGraphics

struct OverlayProtectedRegions {
    let subjectRects: [CGRect]
    let avoidanceRects: [CGRect]

    static let empty = OverlayProtectedRegions(subjectRects: [], avoidanceRects: [])

    var isEmpty: Bool {
        subjectRects.isEmpty && avoidanceRects.isEmpty
    }

    func subjectOverlapFraction(with rect: CGRect) -> CGFloat {
        overlapFraction(of: rect, against: subjectRects)
    }

    func avoidanceOverlapFraction(with rect: CGRect) -> CGFloat {
        overlapFraction(of: rect, against: avoidanceRects)
    }

    private func overlapFraction(of rect: CGRect, against regions: [CGRect]) -> CGFloat {
        guard rect.width > 0, rect.height > 0, !regions.isEmpty else { return 0 }
        let rectArea = rect.width * rect.height
        guard rectArea > 0 else { return 0 }

        var intersectionArea: CGFloat = 0
        for region in regions {
            let intersection = rect.intersection(region)
            guard !intersection.isNull else { continue }
            intersectionArea += intersection.width * intersection.height
        }
        return min(max(intersectionArea / rectArea, 0), 1)
    }
}
