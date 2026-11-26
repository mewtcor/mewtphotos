// UI models and data source contract for the Obsidian Glass Bento views.
// Pure Foundation/SwiftUI; must never import Photos or PhotosUI (enforced by ci.yml).
import Foundation
import SwiftUI

// MARK: - UI Models

public enum MewtItemStatus: String {
    case pending
    case verified
    case failed
    case unavailable

    public var label: String {
        switch self {
        case .pending: return "Pending"
        case .verified: return "Verified"
        case .failed: return "Failed"
        case .unavailable: return "Unavailable"
        }
    }
}

public enum MewtPhotoAccessState: Equatable {
    case full
    case limited
    case denied
    case restricted
    case notDetermined

    public var isFull: Bool { self == .full }
}

public struct MewtRunSummary: Equatable {
    public let considered: Int
    public let alreadyOnServer: Int
    public let verified: Int
    public let failed: Int
    public let unavailable: Int
    public let finished: Bool

    public init(
        considered: Int,
        alreadyOnServer: Int,
        verified: Int,
        failed: Int,
        unavailable: Int,
        finished: Bool
    ) {
        self.considered = considered
        self.alreadyOnServer = alreadyOnServer
        self.verified = verified
        self.failed = failed
        self.unavailable = unavailable
        self.finished = finished
    }
}

public struct MewtMediaItem: Identifiable, Hashable {
    public let id: String
    public let filename: String
    public let fileExtension: String
    public let sizeText: String
    public let dateText: String
    public let status: MewtItemStatus
    public let resourceParts: [String]
    public let destinationSummary: String
    public let shaSummary: String

    public init(
        id: String,
        filename: String,
        fileExtension: String,
        sizeText: String,
        dateText: String,
        status: MewtItemStatus,
        resourceParts: [String],
        destinationSummary: String,
        shaSummary: String
    ) {
        self.id = id
        self.filename = filename
        self.fileExtension = fileExtension
        self.sizeText = sizeText
        self.dateText = dateText
        self.status = status
        self.resourceParts = resourceParts
        self.destinationSummary = destinationSummary
        self.shaSummary = shaSummary
    }
}

public struct MewtAlertItem: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let detail: String
    public let isError: Bool

    public init(id: String, title: String, detail: String, isError: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isError = isError
    }
}

// MARK: - Data Source Protocol

@MainActor
public protocol MewtPhotosUIDataSource: ObservableObject {
    var serverName: String { get }
    var serverAddress: String { get }
    var isPaired: Bool { get }
    var isPairingBusy: Bool { get }
    var isQRScannerAvailable: Bool { get }
    var connectionSummary: String { get }
    var pairingErrorText: String? { get }
    var pairingNoticeText: String? { get }

    var photoAccessState: MewtPhotoAccessState { get }
    var photoAccessMessage: String { get }

    var coverageKnown: Bool { get }
    var isRecounting: Bool { get }
    var totalLibraryCount: Int { get }
    var backedUpCount: Int { get }
    var hiddenCount: Int { get }
    var onServerOnlyCount: Int? { get }

    var serverArchiveSizeText: String { get }
    var serverVerifiedCountText: String { get }
    var serverFreeSpaceText: String { get }
    var isServerVerifying: Bool { get }

    var isBackingUp: Bool { get }
    var activeFileName: String { get }
    var activeItemProgressText: String? { get }
    var activeFileProgress: Double { get }
    var transferSpeedMBps: Double { get }
    var speedSamples: [Double] { get }

    var lastRunSummary: MewtRunSummary? { get }
    var failedCount: Int { get }
    var stopWarning: String? { get }
    var editsNoticeText: String { get }

    var mediaItems: [MewtMediaItem] { get }
    var alerts: [MewtAlertItem] { get }
    var logExportURL: URL? { get }
    var appVersionText: String { get }

    func startBackup()
    func stopBackup()
    func retryFailed()
    func retryItem(id: String)
    func recountLibrary()
    func requestPhotoAccess()
    func triggerServerVerify()
    func inspectItemIfNeeded(id: String)
    func saveServerAddress(_ address: String)
    func forgetServer()
    func pair(fromQRPayload payload: String)
    func pairManually(address: String, code: String)
    func onBecameActive()
    func onEnteredBackground()
}

// MARK: - Preview / Mock Data Source

@MainActor
public final class PreviewMewtDataSource: MewtPhotosUIDataSource {
    @Published public var serverName: String = "macmini"
    @Published public var serverAddress: String = "http://192.168.4.48:8787"
    @Published public var isPaired: Bool = true
    @Published public var isPairingBusy: Bool = false
    @Published public var isQRScannerAvailable: Bool = true
    @Published public var connectionSummary: String = "Connected to macmini"
    @Published public var pairingErrorText: String? = nil
    @Published public var pairingNoticeText: String? = nil

    @Published public var photoAccessState: MewtPhotoAccessState = .full
    @Published public var photoAccessMessage: String = "Mewt Photos can read your whole library."

    @Published public var coverageKnown: Bool = true
    @Published public var isRecounting: Bool = false
    @Published public var totalLibraryCount: Int = 4541
    @Published public var backedUpCount: Int = 4083
    @Published public var hiddenCount: Int = 0
    @Published public var onServerOnlyCount: Int? = 14

    @Published public var serverArchiveSizeText: String = "48.1 GB"
    @Published public var serverVerifiedCountText: String = "7,488 files verified"
    @Published public var serverFreeSpaceText: String = "105.0 GB"
    @Published public var isServerVerifying: Bool = false

    @Published public var isBackingUp: Bool = false
    @Published public var activeFileName: String = "IMG_8115.MOV"
    @Published public var activeItemProgressText: String? = "Item 1 of 458: IMG_8115.MOV"
    @Published public var activeFileProgress: Double = 0.58
    @Published public var transferSpeedMBps: Double = 44.2
    @Published public var speedSamples: [Double] = [18, 26, 22, 34, 41, 38, 45, 42, 48, 44]

    @Published public var lastRunSummary: MewtRunSummary? = MewtRunSummary(
        considered: 4541,
        alreadyOnServer: 4070,
        verified: 13,
        failed: 1,
        unavailable: 2,
        finished: true
    )
    public var failedCount: Int { lastRunSummary?.failed ?? 0 }
    @Published public var stopWarning: String? = nil
    public var editsNoticeText: String = "Edited versions of photos are not backed up yet. Only the originals are sent."

    @Published public var mediaItems: [MewtMediaItem] = [
        MewtMediaItem(
            id: "1",
            filename: "IMG_8115.MOV",
            fileExtension: "MOV",
            sizeText: "Video",
            dateText: "Today, 12:35",
            status: .pending,
            resourceParts: ["IMG_8115.MOV · video · 142.8 MB"],
            destinationSummary: "Not on server yet",
            shaSummary: "Pending transfer"
        ),
        MewtMediaItem(
            id: "2",
            filename: "IMG_8112.HEIC",
            fileExtension: "HEIC",
            sizeText: "Live Photo",
            dateText: "Nov 24, 18:14",
            status: .pending,
            resourceParts: [
                "IMG_8112.HEIC · photo · 4.6 MB",
                "IMG_8112.MOV · pairedVideo · 3.1 MB"
            ],
            destinationSummary: "Not on server yet",
            shaSummary: "Pending transfer"
        ),
        MewtMediaItem(
            id: "4",
            filename: "IMG_8281.DNG",
            fileExtension: "DNG",
            sizeText: "Photo",
            dateText: "Oct 28, 16:22",
            status: .verified,
            resourceParts: ["IMG_8281.DNG · photo · 41.0 MB"],
            destinationSummary: "Verified on server",
            shaSummary: "Confirmed"
        ),
        MewtMediaItem(
            id: "5",
            filename: "IMG_8120.MOV",
            fileExtension: "MOV",
            sizeText: "Video",
            dateText: "Oct 20, 23:41",
            status: .failed,
            resourceParts: ["IMG_8120.MOV · video · 218.4 MB"],
            destinationSummary: "Connection dropped while sending.",
            shaSummary: "Not backed up"
        )
    ]

    @Published public var alerts: [MewtAlertItem] = [
        MewtAlertItem(
            id: "a1",
            title: "1 item failed in last run",
            detail: "Tap Retry failed to resend IMG_8120.MOV.",
            isError: true
        )
    ]

    public var logExportURL: URL? = nil
    public var appVersionText: String = "Version 0.1.0 (build 39) · Git dev"

    public init() {}

    public func startBackup() { isBackingUp = true }
    public func stopBackup() { isBackingUp = false }
    public func retryFailed() { isBackingUp = true }
    public func retryItem(id: String) { isBackingUp = true }
    public func recountLibrary() {}
    public func requestPhotoAccess() { photoAccessState = .full }
    public func triggerServerVerify() { isServerVerifying = true }
    public func inspectItemIfNeeded(id: String) {}
    public func saveServerAddress(_ address: String) { serverAddress = address }
    public func forgetServer() { isPaired = false; isBackingUp = false }
    public func pair(fromQRPayload payload: String) { serverAddress = payload; isPaired = true }
    public func pairManually(address: String, code: String) { serverAddress = address; isPaired = true }
    public func onBecameActive() {}
    public func onEnteredBackground() { isBackingUp = false }
}
