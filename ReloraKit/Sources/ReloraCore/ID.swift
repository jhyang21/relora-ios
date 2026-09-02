import Foundation

/// Entity id generation. Every id in the local store is a lowercase UUID v4
/// string, matching `generateId()` in apps/mobile/src/utils/id.ts
/// (`crypto.randomUUID()`, which already yields lowercase UUID v4 text).
public enum ReloraID {
    /// A new lowercase UUID v4 string.
    public static func new() -> String {
        UUID().uuidString.lowercased()
    }
}
