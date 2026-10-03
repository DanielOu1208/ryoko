import CoreLocation
import Foundation

/// One location fix for live mode, with when-in-use permission.
///
/// Uses `CLServiceSession` (which shows the permission prompt in context) and
/// `CLLocationUpdate.liveUpdates()`, so there's no delegate. Time spent waiting
/// on the permission prompt doesn't count toward the timeout.
enum LocationFix {
    enum Failure: Error, Equatable {
        /// Location is off for Ryoko, restricted, or off system-wide.
        case denied
        /// No fix within the timeout.
        case unavailable
    }

    /// A fix this accurate is taken straight away; otherwise the best one seen
    /// before the timeout is used.
    static let goodAccuracy: CLLocationAccuracy = 65

    /// The current authorization, without prompting.
    static var authorization: CLAuthorizationStatus {
        CLLocationManager().authorizationStatus
    }

    static var isAuthorized: Bool {
        switch authorization {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    /// Asks for when-in-use permission if needed, then returns one fix.
    static func current(timeout: Duration = .seconds(15)) async throws -> CLLocation {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        let progress = Progress()
        progress.awaitingPermission = authorization == .notDetermined

        // Two tasks on the main actor: one waits for a good fix, the other
        // gives up after `timeout` (not counting time on the permission prompt).
        let fixTask = Task { try await firstGoodFix(progress) }
        let timer = Task {
            var waited = Duration.zero
            while waited < timeout {
                try await Task.sleep(for: .milliseconds(250))
                if !progress.awaitingPermission { waited += .milliseconds(250) }
            }
            fixTask.cancel()
        }
        defer { timer.cancel() }

        let fix: CLLocation?
        do {
            fix = try await withTaskCancellationHandler {
                try await fixTask.value
            } onCancel: {
                fixTask.cancel()
            }
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            fix = nil // timed out
        }
        if let fix { return fix }
        if let best = progress.best { return best }
        throw Failure.unavailable
    }

    @MainActor
    private final class Progress {
        var best: CLLocation?
        var awaitingPermission = false
    }

    private static func firstGoodFix(_ progress: Progress) async throws -> CLLocation? {
        for try await update in CLLocationUpdate.liveUpdates() {
            if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                throw Failure.denied
            }
            progress.awaitingPermission = update.authorizationRequestInProgress
            guard let location = update.location, location.horizontalAccuracy >= 0 else { continue }
            if progress.best.map({ location.horizontalAccuracy < $0.horizontalAccuracy }) ?? true {
                progress.best = location
            }
            if location.horizontalAccuracy <= goodAccuracy { return location }
        }
        return nil
    }
}
