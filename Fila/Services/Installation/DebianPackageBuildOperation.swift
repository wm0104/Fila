import Foundation

/// Coordinates metadata saving and packing without treating them as one transaction.
@MainActor
enum DebianPackageBuildOperation {
    enum Outcome {
        case kept
        /// Metadata was saved, but packing could not be presented.
        case saved
        case packed
        case failed(Error, informationSaved: Bool)
    }

    static func run(
        control: String,
        expecting identity: FileIdentity,
        save: @MainActor (String, FileIdentity) async throws -> Bool,
        build: @MainActor (String) async throws -> Bool,
    ) async -> Outcome {
        do {
            guard try await save(control, identity) else { return .kept }
        } catch {
            return .failed(error, informationSaved: false)
        }
        do {
            // Both stages receive this operation's confirmed text, not a later editor's.
            guard try await build(control) else { return .saved }
            return .packed
        } catch {
            return .failed(error, informationSaved: true)
        }
    }
}
