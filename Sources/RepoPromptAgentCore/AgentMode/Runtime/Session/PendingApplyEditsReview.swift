import Foundation

package struct ApplyEditsApprovalScope: Hashable {
    package let windowID: Int
    package let tabID: UUID

    package init(
        windowID: Int,
        tabID: UUID
    ) {
        self.windowID = windowID
        self.tabID = tabID
    }
}

package struct PendingApplyEditsReview: Identifiable, Hashable {
    package let id: UUID
    let scope: ApplyEditsApprovalScope
    package let path: String
    package let unifiedDiff: String
    let createdAt: Date

    package init(
        id: UUID = UUID(),
        scope: ApplyEditsApprovalScope,
        path: String,
        unifiedDiff: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.path = path
        self.unifiedDiff = unifiedDiff
        self.createdAt = createdAt
    }
}
