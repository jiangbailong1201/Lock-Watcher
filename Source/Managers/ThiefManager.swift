//
//  ThiefManager.swift
//
//  Created on 06.01.2021.
//  Copyright © 2026 IGR Soft. All rights reserved.
//

import AppKit
import Combine
import CoreLocation
import PhotoSnap
import UserNotifications

/// A protocol that outlines the responsibilities of the `ThiefManager` class.
///
/// - Important: `@MainActor` isolation is required because:
///   - Interacts with `CLLocationManager` (requires main thread)
///   - Implements `UNUserNotificationCenterDelegate` (requires main thread)
///   - Manages `TriggerManager` which is `@MainActor`
@MainActor
protocol ThiefManagerProtocol: Sendable {
    func detectedTrigger() async -> Bool

    func restartWatching()

    var databaseManager: any DatabaseManagerProtocol { get }

    func setupLocationManager(enable: Bool)

    func showSnapshot(identifier: String)

    func completeDropboxAuthWith(url: URL) async -> String

    var dropboxUserNameUpdates: AsyncStream<String> { get }

    /// Cleans all data: resets database and app settings to defaults.
    func cleanAll()
}

/// The main class responsible for managing and responding to various triggers indicating potential unauthorized access.
///
/// This class is `@MainActor` isolated because:
/// - It implements `CLLocationManagerDelegate` which must be called on main thread
/// - It implements `UNUserNotificationCenterDelegate` which must be called on main thread
/// - It manages `TriggerManager` which is `@MainActor` isolated
@MainActor
final class ThiefManager: NSObject, ThiefManagerProtocol {
    // MARK: - Typealiases
    
    typealias WatchBlock = Commons.ThiefClosure
    
    // MARK: - Dependency injection
    
    private var triggerManager: TriggerManagerProtocol
    
    private let notificationManager: NotificationManagerProtocol
    
    private var watchBlock: WatchBlock = { _ in }
    
    private(set) var settings: AppSettingsProtocol
    
    private var logger: LogProtocol
    
    // MARK: - Variables
    
    private var lastThiefDetection: TriggerType = .setup
    
    /// store ThiefDto in database
    ///
    var databaseManager: any DatabaseManagerProtocol
    
    /// fetch ip address and trace route
    ///
    private lazy var networkUtil: NetworkUtilProtocol = NetworkUtil()
    
    private lazy var fileSystemUtil: FileSystemUtilProtocol = FileSystemUtil()
    
    /// fetch current location
    ///
    private(set) var locationManager = CLLocationManager()
    private var coordinate: CLLocationCoordinate2D?

    /// AsyncStream for Dropbox username updates
    private var dropboxUserNameContinuation: AsyncStream<String>.Continuation?

    /// Provides an AsyncStream of Dropbox username updates
    var dropboxUserNameUpdates: AsyncStream<String> {
        AsyncStream { continuation in
            self.dropboxUserNameContinuation = continuation
        }
    }
    
    // MARK: - initialiser
    
    init(settings: AppSettingsProtocol, triggerManager: TriggerManagerProtocol = TriggerManager(), logger: LogProtocol = Log(category: .thiefManager), watchBlock: @escaping WatchBlock = { _ in }) {
        self.settings = settings
        self.triggerManager = triggerManager
        self.watchBlock = watchBlock
        self.logger = logger
        
        notificationManager = NotificationManager(settings: settings)
        
        databaseManager = DatabaseManager(settings: settings)
        
        super.init()
        
        if settings.options.addLocationToSnapshot {
            setupLocationManager(enable: true)
        }
        
        startWatching(watchBlock)
        
        UNUserNotificationCenter.current().delegate = self
    }
    
    // MARK: - public
    
    /// These methods define how the manager should behave when various events occur.
    /// Sets up the location manager, either enabling or disabling location updates.
    func setupLocationManager(enable: Bool) {
        if enable {
            locationManager.delegate = self
            locationManager.startUpdatingLocation()
        } else {
            locationManager.delegate = nil
            locationManager.stopUpdatingLocation()
        }
    }
    
    /// Stops watching for triggers.
    func stopWatching() {
        logger.debug("Stop Watching")
        triggerManager.stop()
    }
    
    /// Restarts the trigger watching mechanism
    func restartWatching() {
        startWatching(watchBlock)
    }
    
    private func justDetectedTrigger() {
        Task {
            _ = await detectedTrigger()
        }
    }

    /// Detects and processes any triggers.
    func detectedTrigger() async -> Bool {
        logger.debug("Detected triggered action: \(lastThiefDetection.rawValue)")

        let ps = PhotoSnap()
        ps.photoSnapConfiguration.isSaveToFile = settings.sync.isSaveSnapshotToDisk

        if AppSettings.isImageCaptureDebug {
            let img = NSImage(systemSymbolName: "swift", accessibilityDescription: nil)!
            let date = Date()
            lastThiefDetection = .debug
            await processSnapshot(img, filename: ps.photoSnapConfiguration.dateFormatter.string(from: date), date: date)
            try? await Task.sleep(for: .seconds(1))
            return true
        }

        return await withCheckedContinuation { [weak self] continuation in
            ps.fetchSnapshot { photoModel in
                if let img = photoModel.images.last {
                    self?.logger.debug("\(img)")
                    let date = Date()
                    let dateFormatter = ps.photoSnapConfiguration.dateFormatter
                    // Already on MainActor through protocol, process snapshot directly
                    Task { [self] in
                        await self?.processSnapshot(img, filename: dateFormatter.string(from: date), date: date)
                        continuation.resume(returning: true)
                    }
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    /// Processes a given snapshot.
    func processSnapshot(_ snapshot: NSImage, filename: String, date: Date) async {
        let quality = settings.snapshot.quality.compressionFactor
        let scaledSnapshot = snapshot.resized(by: settings.snapshot.resolution.scaleFactor)

        guard let filePath = fileSystemUtil.store(image: scaledSnapshot, forKey: filename, quality: quality) else {
            let msg = "wrong file path"
            logger.error(msg)
            assertionFailure(msg)
            return
        }

        let ipAddress: String? = if settings.options.addIPAddressToSnapshot {
            networkUtil.getIFAddresses()
        } else {
            nil
        }

        let traceRoute: String? = if settings.options.addTraceRouteToSnapshot {
            await withCheckedContinuation { continuation in
                networkUtil.getTraceRoute(host: settings.options.traceRouteServer) { traceRouteLog in
                    continuation.resume(returning: traceRouteLog)
                }
            }
        } else {
            nil
        }

        let dto = ThiefDto(
            triggerType: lastThiefDetection,
            coordinate: coordinate,
            ipAddress: ipAddress,
            traceRoute: traceRoute,
            snapshot: scaledSnapshot,
            filePath: filePath,
            compressionFactor: quality,
            date: date
        )

        await notificationManager.send(dto)
        _ = databaseManager.send(dto)

        watchBlock(dto)
    }
    
    /// Opens a snapshot based on the given identifier.
    func showSnapshot(identifier: String) {
        if let filePath = databaseManager.latestImages.first(where: { Date.defaultFormat.string(from: $0.date) == identifier })?.path {
            NSWorkspace.shared.open(filePath)
        }
    }

    /// Cleans all data: resets database and app settings to defaults.
    func cleanAll() {
        databaseManager.cleanAll()
        settings.resetToDefaults()
        restartWatching()
    }

    // MARK: - private
    
    /// Starts watching for triggers.
    private func startWatching(_ watchBlock: @escaping WatchBlock = { _ in }) {
        logger.debug("Start Watching")
        
        self.watchBlock = watchBlock
        triggerManager.start(settings: settings, triggerBlock: triggered)
    }
    
    private func triggered(_ type: TriggerType) {
        guard type != .setup else { return }

        lastThiefDetection = type
        // Already on MainActor, call directly
        justDetectedTrigger()
    }
    
    /// Completes Dropbox authentication.
    /// - Parameter url: The callback URL from Dropbox OAuth.
    /// - Returns: The display name of the authenticated user, or empty string on failure.
    func completeDropboxAuthWith(url: URL) async -> String {
        let name = await notificationManager.completeDropboxAuthWith(url: url)
        dropboxUserNameContinuation?.yield(name)
        return name
    }
}

/// Location Manager Delegate Methods
extension ThiefManager: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.debug("\(error.localizedDescription)")
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        var statusName = "Unknown"
        switch status {
        case .restricted:
            statusName = "restricted"
        case .denied:
            statusName = "denied"
        case .authorized:
            statusName = "authorised"
        case .notDetermined:
            statusName = "not yet determined"
        default:
            break
        }
        
        logger.debug("location manager auth status changed to: \(statusName)")
    }
}

/// User Notification Center Delegate Methods:
extension ThiefManager: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ centre: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        showSnapshot(identifier: identifier)
    }
}

/// Preview implementation of `ThiefManagerProtocol` for SwiftUI previews.
@MainActor
final class ThiefManagerPreview: ThiefManagerProtocol {
    var dropboxUserNameUpdates: AsyncStream<String> {
        AsyncStream { continuation in
            continuation.yield("")
            continuation.finish()
        }
    }

    func completeDropboxAuthWith(url: URL) async -> String {
        ""
    }

    func showSnapshot(identifier: String) {}

    func setupLocationManager(enable: Bool) {}

    func detectedTrigger() async -> Bool {
        true
    }

    func restartWatching() {}

    func cleanAll() {}

    var databaseManager: any DatabaseManagerProtocol = DatabaseManager(settings: AppSettingsPreview())
}
