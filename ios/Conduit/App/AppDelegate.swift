import UIKit
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "AppDelegate")

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Wire the shared Uploader's database reference before anything uses it.
        // Reuse AppState.shared's database to ensure a single connection to the file.
        let db = AppState.shared.database
        Uploader.shared.database = db
        // Reset any inflight rows whose background task was killed (§4.6).
        Uploader.shared.reconcileInflight()
        // Register the BGAppRefreshTask handler. This MUST run synchronously before
        // launch returns — iOS requires every task handler to be registered by the
        // end of launch. It's the fallback that drains the outbox when HealthKit
        // observer background delivery is throttled/skipped, so sync no longer
        // depends solely on observer wakes (§4.4).
        AppState.shared.syncEngine.registerBackgroundTask()
        // Returning users: first reconcile the persisted config + HealthKit
        // authorization against the current registry, so data types added in an
        // app update (e.g. appleStandHour) are auto-enabled and get a one-time
        // permission prompt; then start capture so observers register and data
        // flows into the outbox. Reconcile runs BEFORE startDataCapture so the
        // newly-enabled types have observers started immediately.
        // Fresh installs start capture from OnboardingViewModel.finishOnboarding().
        if AppState.shared.isOnboardingComplete {
            // Keep a background flush pending from first launch onward.
            AppState.shared.syncEngine.scheduleBackgroundFlush()
            Task { @MainActor in
                await AppState.shared.reconcileRegistry()
                AppState.shared.startDataCapture()
            }
        }
        return true
    }

    /// Refresh the pending background flush whenever we background, so iOS always
    /// has a request to run while we're suspended (belt-and-suspenders alongside
    /// the observer-wake and post-flush scheduling).
    func applicationDidEnterBackground(_ application: UIApplication) {
        guard AppState.shared.isOnboardingComplete else { return }
        AppState.shared.syncEngine.scheduleBackgroundFlush()
    }

    /// iOS relaunches the app to deliver background URLSession events when it
    /// finishes work while we were suspended. We stash the completion handler;
    /// `Uploader` calls it after draining the session's delegate callbacks.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("Resumed for background URLSession events: \(identifier, privacy: .public)")
        guard identifier == BackgroundSession.identifier else {
            completionHandler()
            return
        }
        Uploader.shared.backgroundCompletionHandler = completionHandler
    }
}
