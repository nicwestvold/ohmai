import Foundation

/// The lid helper's entire XPC surface. It's root code: keep this list short.
@objc public protocol LidHelperProtocol {
    /// `pmset -a disablesleep 1` for `leaseSeconds`, unless the helper's own battery or
    /// thermal guard refuses. Engaging while engaged renews. Reply: (ok, refusal reason).
    func engage(leaseSeconds: Int, batteryFloorPercent: Int, reply: @escaping @Sendable (Bool, String?) -> Void)
    /// Extends the lease. Replies false if not engaged or a guard tripped (and released).
    func renew(leaseSeconds: Int, batteryFloorPercent: Int, reply: @escaping @Sendable (Bool) -> Void)
    /// `pmset -a disablesleep 0`.
    func release(reply: @escaping @Sendable (Bool) -> Void)
    func status(reply: @escaping @Sendable (_ engaged: Bool, _ expiresAt: Date?) -> Void)
    /// The helper's build number (`CFBundleVersion`), so the app can spot a stale helper.
    func version(reply: @escaping @Sendable (String) -> Void)
}

public enum LidHelperXPC {
    public static let helperBundleID = "com.westvold.ohmai.lidhelper"
    public static let appBundleID = "com.westvold.ohmai"
    public static let machServiceName = helperBundleID
    public static let launchdPlistName = "\(helperBundleID).plist"

    /// The app's lease and renewal cadence.
    public static let leaseSeconds = 90
    public static let renewInterval: Duration = .seconds(30)

    /// The helper clamps whatever it's sent into these bounds.
    public static let leaseSecondsRange = 1...300
    public static let batteryFloorRange = 10...100

    /// Info.plist key carrying the team ID from `OHMAI_TEAM_ID`. Never hard-code the team ID.
    public static let teamIDInfoKey = "OHMAITeamID"

    /// Apple team IDs are 10 uppercase letters or digits.
    public static func isValidTeamID(_ id: String) -> Bool {
        id.count == 10 && id.allSatisfy { ($0.isASCII && $0.isUppercase && $0.isLetter) || ($0.isASCII && $0.isNumber) }
    }

    /// A code-signing requirement that matches `identifier` signed by `teamID`.
    /// Returns nil for an invalid team ID, so callers fail closed.
    public static func requirement(identifier: String, teamID: String) -> String? {
        guard isValidTeamID(teamID) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
