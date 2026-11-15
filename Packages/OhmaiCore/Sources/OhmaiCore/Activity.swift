import Foundation

/// A supported agent tool.
public enum Agent: String, Sendable, Hashable, CaseIterable, Codable {
    case claude
    case codex
    case pi

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .pi: "pi"
        }
    }
}

/// Identifies one running agent instance (a **Session**).
public struct SessionKey: Sendable, Hashable {
    public let agent: Agent
    public let sessionId: String
    public let pid: Int32

    public init(agent: Agent, sessionId: String, pid: Int32) {
        self.agent = agent
        self.sessionId = sessionId
        self.pid = pid
    }
}

/// A session's state.
public enum Activity: String, Sendable, Hashable {
    case busy
    /// Waiting on the user (an approval or a question).
    case waiting
    case idle
    case gone
}

/// What every adapter emits.
public struct ActivityEvent: Sendable, Equatable {
    public let session: SessionKey
    public let activity: Activity
    public let at: Date
    /// The session's working directory. Metadata only, shown in the dropdown.
    public let project: String?

    public init(session: SessionKey, activity: Activity, at: Date, project: String? = nil) {
        self.session = session
        self.activity = activity
        self.at = at
        self.project = project
    }
}
