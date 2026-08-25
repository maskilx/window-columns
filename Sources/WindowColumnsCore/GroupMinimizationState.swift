/// Tracks deliberate minimization independently for each saved group.
///
/// The controller can minimize a group from its Dock menu while a different
/// group is selected. Keeping this state keyed by group prevents the selected
/// group from inheriting another group's reconciliation pause.
public struct GroupMinimizationState<GroupID: Hashable> {
    private var minimizedGroupIDs: Set<GroupID> = []

    public init() {}

    public func contains(_ groupID: GroupID) -> Bool {
        minimizedGroupIDs.contains(groupID)
    }

    public func containsActiveGroup(_ activeGroupID: GroupID?) -> Bool {
        activeGroupID.map(minimizedGroupIDs.contains) ?? false
    }

    public mutating func minimize(_ groupID: GroupID) {
        minimizedGroupIDs.insert(groupID)
    }

    public mutating func restore(_ groupID: GroupID) {
        minimizedGroupIDs.remove(groupID)
    }

    public mutating func retain<S: Sequence>(only validGroupIDs: S) where S.Element == GroupID {
        minimizedGroupIDs.formIntersection(Set(validGroupIDs))
    }
}
