import Foundation

struct CoachMessage: Identifiable, Equatable {
    let id: String
    let messageId: String
    let role: Role
    let content: String
    let status: Status
    let timestamp: Date
    let riskLevel: String?

    enum Role: String {
        case user
        case coach
        case tool
        case system
    }

    enum Status: String {
        case queued
        case streaming
        case complete
        case blocked
        case error
        case unknown
    }

    var isUser: Bool {
        role == .user
    }

    var isPendingCoachReply: Bool {
        role == .coach && status == .streaming && content.isEmpty
    }
}
