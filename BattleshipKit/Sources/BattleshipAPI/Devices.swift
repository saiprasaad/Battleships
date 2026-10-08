/// Which Apple Push Notification service a device token belongs to.
public enum PushEnvironment: String, Codable, Sendable, Hashable {
    /// Debug builds signed with a development profile.
    case sandbox
    /// TestFlight and App Store builds.
    case production
}

/// Registers a device to receive push notifications (`POST /v1/devices`).
public struct DeviceRegistration: Codable, Sendable, Hashable {
    /// The APNs device token, hex encoded.
    public var token: String
    public var environment: PushEnvironment

    public init(token: String, environment: PushEnvironment) {
        self.token = token
        self.environment = environment
    }
}
