import Foundation

/// Screen-space drop geometry: macOS screen coordinates increase upwards.
/// Rows belonging to a root are supplied as one rectangle, including their gaps.
enum TaskDragGeometry {
    struct Group: Equatable {
        let taskID: String
        let frame: CGRect
        let topRegionID: UUID
        let bottomRegionID: UUID
    }

    struct Insertion: Equatable {
        let taskID: String
        let regionID: UUID
        let placement: SubtaskPlacement
    }

    static func insertion(at point: CGPoint, groups: [Group], lane: CGRect,
                          horizontalTolerance: CGFloat = 40,
                          verticalTolerance: CGFloat = 28) -> Insertion? {
        guard point.x >= lane.minX - horizontalTolerance,
              point.x <= lane.maxX + horizontalTolerance else { return nil }
        let candidates = groups.filter { !$0.frame.isEmpty }.map { group in
            (group: group, distance: max(max(group.frame.minY - point.y, point.y - group.frame.maxY), 0))
        }.filter { $0.distance <= verticalTolerance }
        guard let nearest = candidates.min(by: { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            let left = abs(lhs.group.frame.midY - point.y)
            let right = abs(rhs.group.frame.midY - point.y)
            return left == right ? lhs.group.taskID < rhs.group.taskID : left < right
        })?.group else { return nil }
        let placement: SubtaskPlacement = point.y >= nearest.frame.midY ? .before : .after
        return Insertion(taskID: nearest.taskID,
                         regionID: placement == .before ? nearest.topRegionID : nearest.bottomRegionID,
                         placement: placement)
    }
}
