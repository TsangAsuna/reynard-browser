//
//  DownloadStore.swift
//  Reynard
//
//  Created by Minh Ton on 2/4/26.
//

import Foundation
import GeckoView
import UniformTypeIdentifiers
import MobileCoreServices

struct DownloadStoreSummary {
    let totalCount: Int
    let activeCount: Int
    let aggregateProgress: Float
    let hasUnviewedCompletedDownloads: Bool
    
    var showsToolbarButton: Bool {
        return activeCount > 0 || (hasUnviewedCompletedDownloads && totalCount > 0)
    }
}

struct DownloadStoreSnapshot {
    let summary: DownloadStoreSummary
    let items: [DownloadItemSnapshot]
}

struct DownloadItemSnapshot {
    enum State: Equatable {
        case downloading
        case paused
        case cancelled
        case failed
        case completed
    }
    
    let id: UUID
    let fileName: String
    let fileURL: URL?
    let sourceURL: URL
    let originalURL: URL?
    let mimeType: String?
    let state: State
    let canPause: Bool
    let canResume: Bool
    let fileExists: Bool
    let totalBytes: Int64?
    let downloadedBytes: Int64
    let bytesPerSecond: Int64
    let addedAt: Date
}

final class DownloadStore: NSObject {
    static let shared = DownloadStore()
    
    struct WebExtensionDownloadItem {
        let id: Int
        let fileName: String
        let localFilePath: String
        let mimeType: String?
        let addedAt: Date
    }
    
    struct PendingDownload {
        let fileName: String
        fileprivate let startHandler: () -> WebExtensionDownloadItem?
    }
    
    private struct StorageURLs {
        let downloadsDirectoryURL: URL
        let appDataDirectoryURL: URL
        let manifestFileURL: URL
    }
    
    private enum PersistedDownloadState: String, Codable {
        case inProgress = "active"
        case paused
        case cancelled
        case completed
        case failed
    }

    private struct PersistedDownloadEntry: Codable {
        let id: UUID
        let fileName: String
        let relativePath: String
        let sourceURLString: String
        let originalURLString: String?
        let mimeType: String?
        let fileSize: Int64
        let addedAt: Date
        var state: PersistedDownloadState?
        // Resume data lets an interrupted or paused transfer continue from the
        // bytes already downloaded, including after an app relaunch.
        var resumeData: Data?
        var downloadedBytes: Int64?

        var effectiveState: PersistedDownloadState {
            return state ?? .completed
        }

        var isResumable: Bool {
            return resumeData != nil && effectiveState != .completed && effectiveState != .cancelled
        }
    }
    
    private struct ProgressSample {
        let bytesWritten: Int64
        let timestamp: TimeInterval
    }
    
    private final class ActiveDownload {
        let id: UUID
        let sourceURL: URL
        let originalURL: URL?
        let fileName: String
        let destinationURL: URL
        let mimeType: String?
        let addedAt: Date
        var task: URLSessionDownloadTask
        var expectedBytes: Int64?
        var downloadedBytes: Int64
        var bytesPerSecond: Int64
        var lastProgressSample: ProgressSample?
        var isPaused: Bool
        var autoRetryCount: Int

        init(
            id: UUID,
            sourceURL: URL,
            originalURL: URL?,
            fileName: String,
            destinationURL: URL,
            mimeType: String?,
            addedAt: Date,
            task: URLSessionDownloadTask,
            expectedBytes: Int64? = nil
        ) {
            self.id = id
            self.sourceURL = sourceURL
            self.originalURL = originalURL
            self.fileName = fileName
            self.destinationURL = destinationURL
            self.mimeType = mimeType
            self.addedAt = addedAt
            self.task = task
            self.expectedBytes = expectedBytes
            self.downloadedBytes = 0
            self.bytesPerSecond = 0
            self.isPaused = false
            self.autoRetryCount = 0
        }
    }

    private final class CapturedDownload {
        let id: UUID
        let localFilePath: String
        let sourceURL: URL
        let fileName: String
        let destinationURL: URL
        let mimeType: String?
        let addedAt: Date
        weak var originatingSession: GeckoSession?
        var expectedBytes: Int64?
        var downloadedBytes: Int64
        var bytesPerSecond: Int64
        var lastProgressSample: ProgressSample?
        var isPaused: Bool

        init(
            id: UUID,
            localFilePath: String,
            sourceURL: URL,
            fileName: String,
            destinationURL: URL,
            mimeType: String?,
            addedAt: Date,
            expectedBytes: Int64?,
            originatingSession: GeckoSession? = nil
        ) {
            self.id = id
            self.localFilePath = localFilePath
            self.sourceURL = sourceURL
            self.fileName = fileName
            self.destinationURL = destinationURL
            self.mimeType = mimeType
            self.addedAt = addedAt
            self.originatingSession = originatingSession
            self.expectedBytes = expectedBytes
            self.downloadedBytes = 0
            self.bytesPerSecond = 0
            self.isPaused = false
        }
    }
    
    private let fileManager: FileManager
    private let storage: StorageURLs
    private let stateQueue = DispatchQueue(label: "com.minh-ton.Reynard.DownloadStore.Queue", qos: .userInitiated)
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    
    private var activeDownloads: [Int: ActiveDownload] = [:]
    private var capturedDownloads: [String: CapturedDownload] = [:]
    private var persistedDownloads: [PersistedDownloadEntry] = []
    private var lastSessionProgressNotificationTime: TimeInterval = 0
    private var hasUnviewedCompletedDownloads = false
    private var nextWebExtensionDownloadID = 1
    
    // MARK: - Lifecycle
    
    override init() {
        self.fileManager = .default
        
        guard let documentsDirectoryURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory is unavailable")
        }
        
        guard let applicationSupportDirectoryURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory is unavailable")
        }
        
        let downloadsDirectoryURL = documentsDirectoryURL.appendingPathComponent("Downloads", isDirectory: true)
        let appDataDirectoryURL = applicationSupportDirectoryURL.appendingPathComponent("AppData", isDirectory: true)
        let manifestFileURL = appDataDirectoryURL.appendingPathComponent("DownloadStore", isDirectory: false)
        self.storage = StorageURLs(
            downloadsDirectoryURL: downloadsDirectoryURL,
            appDataDirectoryURL: appDataDirectoryURL,
            manifestFileURL: manifestFileURL
        )
        
        super.init()
        
        stateQueue.sync {
            self.prepareStorageLocked()
            self.loadPersistedDownloadsLocked()
        }
    }
    
    // MARK: - Downloads
    
    func currentSnapshot() -> DownloadStoreSnapshot {
        stateQueue.sync {
            makeSnapshotLocked()
        }
    }
    
    // MARK: - Pending Downloads
    
    func pendingDownload(from response: ExternalResponseInfo, session: GeckoSession) -> PendingDownload? {
        guard let sourceURL = URL(string: response.url) else {
            return nil
        }

        let fileName = sanitizedFileName(
            suggestedFileName: response.filename,
            sourceURL: sourceURL
        )

        return PendingDownload(
            fileName: fileName,
            startHandler: { [weak self] in
                // Stop the engine transfer; the file is fetched by URLSession instead.
                // Unlike the engine's networking stack, URLSession honors the system
                // HTTP proxy and supports resumable transfers (resume data), so
                // interrupted downloads can continue instead of failing outright.
                response.cancel()
                self?.enqueueDownload(
                    sourceURL: sourceURL,
                    originalURL: nil,
                    suggestedFileName: response.filename,
                    mimeType: response.mimeType,
                    responseHeaders: response.headers,
                    expectedBytes: response.contentLength
                )
                return nil
            }
        )
    }
    
    func pendingDownload(from request: SavePdfInfo) -> PendingDownload? {
        let candidateURLs = [request.url, request.originalUrl].compactMap { $0 }.compactMap(URL.init(string:))
        guard let sourceURL = candidateURLs.first(where: { URLUtils.isWebURL($0) }) else {
            return nil
        }
        
        return PendingDownload(
            fileName: resolvedFileName(
                suggestedFileName: request.filename,
                sourceURL: sourceURL,
                mimeType: "application/pdf"
            ),
            startHandler: { [weak self] in
                self?.enqueueDownload(
                    sourceURL: sourceURL,
                    originalURL: URL(string: request.originalUrl ?? ""),
                    suggestedFileName: request.filename,
                    mimeType: "application/pdf"
                )
                return nil
            }
        )
    }
    
    func pendingDownload(from options: [String: Any?]) -> PendingDownload? {
        guard let urlString = options["url"] as? String,
              let sourceURL = URL(string: urlString) else {
            return nil
        }
        
        let suggestedFileName = options["filename"] as? String
        let mimeType = options["mimeType"] as? String
        
        return PendingDownload(
            fileName: resolvedFileName(
                suggestedFileName: suggestedFileName,
                sourceURL: sourceURL,
                mimeType: mimeType
            ),
            startHandler: { [weak self] in
                self?.beginWebExtensionDownload(
                    sourceURL: sourceURL,
                    suggestedFileName: suggestedFileName,
                    mimeType: mimeType
                )
            }
        )
    }
    
    @discardableResult
    func startDownload(_ pendingDownload: PendingDownload) -> WebExtensionDownloadItem? {
        return pendingDownload.startHandler()
    }
    
    // MARK: - Captured Download Events
    
    func updateCapturedDownload(localFilePath: String, bytesReceived: Int64) -> Bool {
        return stateQueue.sync {
            guard let active = capturedDownloads[localFilePath] else {
                return false
            }
            
            updateCapturedProgress(active, bytesReceived: bytesReceived)
            return true
        }
    }
    
    func completeCapturedDownload(localFilePath: String, succeeded: Bool) {
        stateQueue.sync {
            self.completeCapturedDownloadLocked(
                localFilePath: localFilePath,
                succeeded: succeeded
            )
        }
    }
    
    func failCapturedDownloads(for session: GeckoSession) {
        stateQueue.sync {
            let terminatedDownloads = capturedDownloads.values.filter {
                $0.originatingSession === session
            }
            for download in terminatedDownloads {
                capturedDownloads.removeValue(forKey: download.localFilePath)
                storePersistedEntryLocked(
                    makePersistedEntry(for: download, state: .failed)
                )
            }
            if !terminatedDownloads.isEmpty {
                postDidChange()
            }
        }
    }
    
    // MARK: - Download Management

    func cancel(id: UUID) {
        stateQueue.async {
            if let active = self.activeDownloads.values.first(where: { $0.id == id }) {
                self.activeDownloads.removeValue(forKey: active.task.taskIdentifier)
                self.storePersistedEntryLocked(
                    self.makePersistedEntry(for: active, state: .cancelled)
                )
                active.task.cancel()
                self.postDidChange()
                return
            }

            if let captured = self.capturedDownloads.values.first(where: { $0.id == id }) {
                self.capturedDownloads.removeValue(forKey: captured.localFilePath)
                self.storePersistedEntryLocked(
                    self.makePersistedEntry(for: captured, state: .cancelled)
                )
                self.postDidChange()
                return
            }

            // Persisted interrupted/paused downloads: cancelling discards the
            // saved resume data and drops the entry, matching user expectation
            // that a cancelled download no longer shows up as resumable.
            if let index = self.persistedDownloads.firstIndex(where: { $0.id == id }),
               self.persistedDownloads[index].effectiveState != .completed {
                self.persistedDownloads.remove(at: index)
                self.savePersistedDownloadsLocked()
                self.postDidChange()
            }
        }
    }

    func pause(id: UUID) {
        stateQueue.async {
            if let active = self.activeDownloads.values.first(where: { $0.id == id }) {
                guard !active.isPaused else {
                    return
                }

                active.isPaused = true
                active.bytesPerSecond = 0
                active.lastProgressSample = nil
                let downloadedBytes = active.downloadedBytes
                self.activeDownloads.removeValue(forKey: active.task.taskIdentifier)

                // Checkpoint the transfer into resume data so the pause survives
                // an app relaunch; resuming creates a new task from that data.
                active.task.cancel(byProducingResumeData: { [weak self] resumeData in
                    guard let self else {
                        return
                    }

                    self.stateQueue.async {
                        if let resumeData {
                            self.storePersistedEntryLocked(
                                self.makePersistedEntry(
                                    for: active,
                                    state: .paused,
                                    downloadedBytes: downloadedBytes,
                                    resumeData: resumeData
                                )
                            )
                        } else {
                            self.storePersistedEntryLocked(
                                self.makePersistedEntry(for: active, state: .cancelled)
                            )
                        }
                        self.postDidChange()
                    }
                })
                self.postDidChange()
                return
            }

            guard let captured = self.capturedDownloads.values.first(where: { $0.id == id }),
                  !captured.isPaused else {
                return
            }

            captured.isPaused = true
            captured.bytesPerSecond = 0
            captured.lastProgressSample = nil
            self.postDidChange()
        }
    }

    func resume(id: UUID) {
        stateQueue.async {
            if let active = self.activeDownloads.values.first(where: { $0.id == id }) {
                guard active.isPaused else {
                    return
                }

                active.task.resume()
                active.isPaused = false
                active.bytesPerSecond = 0
                active.lastProgressSample = nil
                self.postDidChange()
                return
            }

            // Resumable persisted download (paused or interrupted, possibly
            // from a previous app session): build a new transfer from the
            // saved resume data and keep the entry around (still marked
            // in progress with its resume data) so a crash mid-resume stays
            // recoverable.
            if let index = self.persistedDownloads.firstIndex(where: { $0.id == id }),
               let resumeData = self.persistedDownloads[index].resumeData,
               self.persistedDownloads[index].isResumable {
                let entry = self.persistedDownloads[index]
                guard !self.activeDownloads.values.contains(where: { $0.id == entry.id }),
                      let sourceURL = URL(string: entry.sourceURLString) else {
                    return
                }

                let task = self.session.downloadTask(withResumeData: resumeData)
                let active = ActiveDownload(
                    id: entry.id,
                    sourceURL: sourceURL,
                    originalURL: entry.originalURLString.flatMap(URL.init(string:)),
                    fileName: entry.fileName,
                    destinationURL: self.storage.downloadsDirectoryURL.appendingPathComponent(
                        entry.relativePath,
                        isDirectory: false
                    ),
                    mimeType: entry.mimeType,
                    addedAt: entry.addedAt,
                    task: task
                )
                active.downloadedBytes = entry.downloadedBytes ?? 0

                self.activeDownloads[task.taskIdentifier] = active
                var updatedEntry = entry
                updatedEntry.state = .inProgress
                self.persistedDownloads[index] = updatedEntry
                self.savePersistedDownloadsLocked()

                task.resume()
                self.postDidChange()
                return
            }

            guard let captured = self.capturedDownloads.values.first(where: { $0.id == id }),
                  captured.isPaused else {
                return
            }

            captured.isPaused = false
            captured.bytesPerSecond = 0
            captured.lastProgressSample = nil
            self.postDidChange()
        }
    }
    
    func removeDownload(id: UUID) {
        stateQueue.async {
            guard let index = self.persistedDownloads.firstIndex(where: { $0.id == id }) else {
                return
            }
            
            let entry = self.persistedDownloads.remove(at: index)
            let fileURL = self.storage.downloadsDirectoryURL.appendingPathComponent(entry.relativePath, isDirectory: false)
            
            if self.fileManager.fileExists(atPath: fileURL.path) {
                try? self.fileManager.removeItem(at: fileURL)
            }
            
            self.savePersistedDownloadsLocked()
            self.postDidChange()
        }
    }
    
    func clearCompletedDownloadFiles(since startDate: Date? = nil) {
        stateQueue.async {
            let removedDownloads = self.persistedDownloads.filter { entry in
                guard entry.effectiveState != .inProgress else {
                    return false
                }
                return startDate.map { entry.addedAt >= $0 } ?? true
            }
            let removedIDs = Set(removedDownloads.map(\.id))
            self.persistedDownloads.removeAll { removedIDs.contains($0.id) }
            
            let fileURLs: [URL]
            if startDate == nil {
                fileURLs = (try? self.fileManager.contentsOfDirectory(
                    at: self.storage.downloadsDirectoryURL,
                    includingPropertiesForKeys: nil
                )) ?? []
            } else {
                fileURLs = removedDownloads.map {
                    self.storage.downloadsDirectoryURL.appendingPathComponent($0.relativePath, isDirectory: false)
                }
            }
            
            for fileURL in Set(fileURLs) {
                try? self.fileManager.removeItem(at: fileURL)
            }
            
            if !self.fileManager.fileExists(atPath: self.storage.downloadsDirectoryURL.path) {
                try? self.fileManager.createDirectory(
                    at: self.storage.downloadsDirectoryURL,
                    withIntermediateDirectories: true
                )
            }
            
            for active in self.activeDownloads.values {
                if let startDate, active.addedAt < startDate {
                    continue
                }
                
                if self.fileManager.fileExists(atPath: active.destinationURL.path) {
                    try? self.fileManager.removeItem(at: active.destinationURL)
                }
            }
            
            self.savePersistedDownloadsLocked()
            self.postDidChange()
        }
    }
    
    func markCompletedAsViewed() {
        stateQueue.async {
            guard self.hasUnviewedCompletedDownloads else {
                return
            }
            
            self.hasUnviewedCompletedDownloads = false
            self.postDidChange()
        }
    }
    
    // MARK: - Captured Downloads

    // MARK: - URL Session Downloads

    private func enqueueDownload(
        sourceURL: URL,
        originalURL: URL?,
        suggestedFileName: String?,
        mimeType: String?,
        responseHeaders: [ExternalResponseHeader]? = nil,
        expectedBytes: Int64? = nil
    ) {
        stateQueue.async {
            self.prepareStorageLocked()

            let fileName = self.resolvedFileName(
                suggestedFileName: suggestedFileName,
                sourceURL: sourceURL,
                mimeType: mimeType
            )
            let destinationURL = self.makeUniqueDestinationURLLocked(for: fileName)

            var request = URLRequest(url: sourceURL)
            if let responseHeaders {
                // The engine hands over the original response headers; forward the
                // request-relevant ones so authenticated/CDN downloads keep working
                // when re-requested outside the engine.
                let forwardedNames: Set<String> = [
                    "cookie",
                    "authorization",
                    "user-agent",
                    "referer",
                    "origin",
                    "proxy-authorization",
                ]
                for header in responseHeaders {
                    let lowercasedName = header.name.lowercased()
                    if forwardedNames.contains(lowercasedName) || lowercasedName.hasPrefix("x-") {
                        request.setValue(header.value, forHTTPHeaderField: header.name)
                    }
                }
            }

            let task = self.session.downloadTask(with: request)
            let active = ActiveDownload(
                id: UUID(),
                sourceURL: sourceURL,
                originalURL: originalURL,
                fileName: destinationURL.lastPathComponent,
                destinationURL: destinationURL,
                mimeType: mimeType,
                addedAt: Date(),
                task: task,
                expectedBytes: expectedBytes
            )

            self.activeDownloads[task.taskIdentifier] = active
            self.storePersistedEntryLocked(
                self.makePersistedEntry(for: active, state: .inProgress)
            )
            task.resume()
            self.postDidStartDownload()
            self.postDidChange()
        }
    }

    private func beginWebExtensionDownload(
        sourceURL: URL,
        suggestedFileName: String?,
        mimeType: String?
    ) -> WebExtensionDownloadItem? {
        return stateQueue.sync {
            self.prepareStorageLocked()
            
            let fileName = self.resolvedFileName(
                suggestedFileName: suggestedFileName,
                sourceURL: sourceURL,
                mimeType: mimeType
            )
            let destinationURL = self.makeUniqueDestinationURLLocked(for: fileName)
            let localFilePath = self.fileManager.temporaryDirectory
                .appendingPathComponent(
                    "WebExtension-\(UUID().uuidString)",
                    isDirectory: false
                )
                .path
            let downloadID = self.nextWebExtensionDownloadID
            self.nextWebExtensionDownloadID += 1
            let addedAt = Date()
            
            let active = CapturedDownload(
                id: UUID(),
                localFilePath: localFilePath,
                sourceURL: sourceURL,
                fileName: destinationURL.lastPathComponent,
                destinationURL: destinationURL,
                mimeType: mimeType,
                addedAt: addedAt,
                expectedBytes: nil
            )
            self.capturedDownloads[localFilePath] = active
            self.storePersistedEntryLocked(
                self.makePersistedEntry(for: active, state: .inProgress)
            )
            self.postDidStartDownload()
            self.postDidChange()
            
            return WebExtensionDownloadItem(
                id: downloadID,
                fileName: destinationURL.lastPathComponent,
                localFilePath: localFilePath,
                mimeType: mimeType,
                addedAt: addedAt
            )
        }
    }

    // MARK: - Snapshots
    
    private func makeSnapshotLocked() -> DownloadStoreSnapshot {
        let sessionItems = activeDownloads.values
            .map { active in
                DownloadItemSnapshot(
                    id: active.id,
                    fileName: active.fileName,
                    fileURL: nil,
                    sourceURL: active.sourceURL,
                    originalURL: active.originalURL,
                    mimeType: active.mimeType,
                    state: active.isPaused ? .paused : .downloading,
                    canPause: true,
                    canResume: false,
                    fileExists: true,
                    totalBytes: active.expectedBytes,
                    downloadedBytes: active.downloadedBytes,
                    bytesPerSecond: active.bytesPerSecond,
                    addedAt: active.addedAt
                )
            }
            .sorted { $0.addedAt > $1.addedAt }

        let capturedItems = capturedDownloads.values
            .map { active in
                DownloadItemSnapshot(
                    id: active.id,
                    fileName: active.fileName,
                    fileURL: nil,
                    sourceURL: active.sourceURL,
                    originalURL: nil,
                    mimeType: active.mimeType,
                    state: active.isPaused ? .paused : .downloading,
                    canPause: false,
                    canResume: false,
                    fileExists: true,
                    totalBytes: active.expectedBytes,
                    downloadedBytes: active.downloadedBytes,
                    bytesPerSecond: active.bytesPerSecond,
                    addedAt: active.addedAt
                )
            }

        let activeItems = (sessionItems + capturedItems)
            .sorted { $0.addedAt > $1.addedAt }

        let terminalItems = persistedDownloads
            .compactMap { entry -> DownloadItemSnapshot? in
                guard entry.effectiveState != .inProgress else {
                    return nil
                }

                let fileURL = storage.downloadsDirectoryURL.appendingPathComponent(entry.relativePath, isDirectory: false)
                let isCompleted = entry.effectiveState == .completed
                let itemState: DownloadItemSnapshot.State
                switch entry.effectiveState {
                case .cancelled:
                    itemState = .cancelled
                case .completed:
                    itemState = .completed
                case .paused:
                    itemState = .paused
                default:
                    itemState = .failed
                }
                return DownloadItemSnapshot(
                    id: entry.id,
                    fileName: entry.fileName,
                    fileURL: isCompleted ? fileURL : nil,
                    sourceURL: URL(string: entry.sourceURLString) ?? storage.downloadsDirectoryURL,
                    originalURL: entry.originalURLString.flatMap(URL.init(string:)),
                    mimeType: entry.mimeType,
                    state: itemState,
                    canPause: false,
                    canResume: entry.isResumable,
                    fileExists: isCompleted && fileManager.fileExists(atPath: fileURL.path),
                    totalBytes: isCompleted ? entry.fileSize : nil,
                    downloadedBytes: isCompleted ? entry.fileSize : (entry.downloadedBytes ?? 0),
                    bytesPerSecond: 0,
                    addedAt: entry.addedAt
                )
            }

        return DownloadStoreSnapshot(summary: makeSummaryLocked(), items: activeItems + terminalItems)
    }
    
    private func makeSummaryLocked() -> DownloadStoreSummary {
        let activeProgress = activeDownloads.values.map { ($0.expectedBytes, $0.downloadedBytes) }
        + capturedDownloads.values.map { ($0.expectedBytes, $0.downloadedBytes) }
        let hasUnknownExpectedBytes = activeProgress.contains { $0.0 == nil }
        let totalExpectedBytes = activeProgress.reduce(Int64(0)) { partialResult, item in
            partialResult + max(item.0 ?? 0, 0)
        }
        let totalDownloadedBytes = activeProgress.reduce(Int64(0)) { partialResult, item in
            partialResult + min(item.1, item.0 ?? item.1)
        }
        let aggregateProgress: Float
        if totalExpectedBytes > 0 && !hasUnknownExpectedBytes {
            aggregateProgress = Float(totalDownloadedBytes) / Float(totalExpectedBytes)
        } else {
            aggregateProgress = 0
        }
        
        let terminalCount = persistedDownloads.lazy.filter { $0.effectiveState != .inProgress }.count
        return DownloadStoreSummary(
            totalCount: terminalCount + activeProgress.count,
            activeCount: activeProgress.count,
            aggregateProgress: min(max(aggregateProgress, 0), 1),
            hasUnviewedCompletedDownloads: hasUnviewedCompletedDownloads
        )
    }
    
    // MARK: - Persistence
    
    private func prepareStorageLocked() {
        try? fileManager.createDirectory(at: storage.downloadsDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: storage.appDataDirectoryURL, withIntermediateDirectories: true)
        
        guard !fileManager.fileExists(atPath: storage.manifestFileURL.path) else {
            return
        }
        
        let emptyManifest = (try? JSONEncoder().encode([PersistedDownloadEntry]())) ?? Data("[]".utf8)
        fileManager.createFile(atPath: storage.manifestFileURL.path, contents: emptyManifest)
    }
    
    private func loadPersistedDownloadsLocked() {
        guard let data = try? Data(contentsOf: storage.manifestFileURL) else {
            persistedDownloads = []
            savePersistedDownloadsLocked()
            return
        }
        
        if data.isEmpty {
            persistedDownloads = []
            savePersistedDownloadsLocked()
            return
        }
        
        if var entries = try? JSONDecoder().decode([PersistedDownloadEntry].self, from: data) {
            var markedInterruptedDownloads = false
            for index in entries.indices where entries[index].effectiveState == .inProgress {
                entries[index].state = .failed
                // Transfers with saved resume data stay resumable from the bytes
                // already downloaded; everything else is dead weight.
                if entries[index].resumeData == nil {
                    let destinationURL = storage.downloadsDirectoryURL.appendingPathComponent(
                        entries[index].relativePath,
                        isDirectory: false
                    )
                    try? fileManager.removeItem(at: destinationURL)
                }
                markedInterruptedDownloads = true
            }
            persistedDownloads = entries.sorted { $0.addedAt > $1.addedAt }
            if markedInterruptedDownloads {
                savePersistedDownloadsLocked()
            }
            return
        }
        
        persistedDownloads = []
        savePersistedDownloadsLocked()
    }
    
    private func savePersistedDownloadsLocked() {
        guard let data = try? JSONEncoder().encode(persistedDownloads.sorted { $0.addedAt > $1.addedAt }) else {
            return
        }
        
        try? data.write(to: storage.manifestFileURL, options: .atomic)
    }
    
    private func makePersistedEntry(
        for download: ActiveDownload,
        state: PersistedDownloadState,
        fileSize: Int64 = 0,
        downloadedBytes: Int64? = nil,
        resumeData: Data? = nil
    ) -> PersistedDownloadEntry {
        return PersistedDownloadEntry(
            id: download.id,
            fileName: download.fileName,
            relativePath: download.destinationURL.lastPathComponent,
            sourceURLString: download.sourceURL.absoluteString,
            originalURLString: download.originalURL?.absoluteString,
            mimeType: download.mimeType,
            fileSize: fileSize,
            addedAt: download.addedAt,
            state: state,
            resumeData: resumeData,
            downloadedBytes: downloadedBytes
        )
    }

    private func makePersistedEntry(
        for download: CapturedDownload,
        state: PersistedDownloadState,
        fileSize: Int64 = 0
    ) -> PersistedDownloadEntry {
        return PersistedDownloadEntry(
            id: download.id,
            fileName: download.fileName,
            relativePath: download.destinationURL.lastPathComponent,
            sourceURLString: download.sourceURL.absoluteString,
            originalURLString: nil,
            mimeType: download.mimeType,
            fileSize: fileSize,
            addedAt: download.addedAt,
            state: state,
            resumeData: nil,
            downloadedBytes: nil
        )
    }
    
    private func storePersistedEntryLocked(_ entry: PersistedDownloadEntry) {
        if let index = persistedDownloads.firstIndex(where: { $0.id == entry.id }) {
            persistedDownloads[index] = entry
        } else {
            persistedDownloads.insert(entry, at: 0)
        }
        savePersistedDownloadsLocked()
    }
    
    // MARK: - Files
    
    private func resolvedFileName(
        suggestedFileName: String?,
        sourceURL: URL,
        mimeType: String?
    ) -> String {
        let initialName = sanitizedFileName(
            suggestedFileName: suggestedFileName,
            sourceURL: sourceURL
        )
        
        guard URL(fileURLWithPath: initialName).pathExtension.isEmpty,
              let mimeType,
              let contentType = UTTypeCreatePreferredIdentifierForTag(
                kUTTagClassMIMEType,
                mimeType as CFString,
                nil
              )?.takeRetainedValue(),
              let preferredExtension = UTTypeCopyPreferredTagWithClass(
                contentType,
                kUTTagClassFilenameExtension
              )?.takeRetainedValue() as String? else {
            return initialName
        }
        
        return "\(initialName).\(preferredExtension)"
    }
    
    private func sanitizedFileName(suggestedFileName: String?, sourceURL: URL) -> String {
        let fallbackName = sourceURL.lastPathComponent.isEmpty
        ? NSLocalizedString("Download", comment: "")
        : sourceURL.lastPathComponent
        let candidateName: String
        if let suggestedFileName = suggestedFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggestedFileName.isEmpty {
            candidateName = suggestedFileName
        } else {
            candidateName = fallbackName
        }
        return sanitizeFileName(candidateName)
    }
    
    private func sanitizeFileName(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidCharacters = CharacterSet(charactersIn: "/:\n\r")
        let sanitized = trimmedValue
            .components(separatedBy: invalidCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        
        return sanitized.isEmpty ? NSLocalizedString("Download", comment: "") : sanitized
    }
    
    private func makeUniqueDestinationURLLocked(for fileName: String) -> URL {
        let candidateURL = storage.downloadsDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        let activeNames = Set(
            activeDownloads.values.map { $0.destinationURL.lastPathComponent.lowercased() }
            + capturedDownloads.values.map { $0.destinationURL.lastPathComponent.lowercased() }
        )
        
        guard !fileManager.fileExists(atPath: candidateURL.path), !activeNames.contains(fileName.lowercased()) else {
            let fileURL = URL(fileURLWithPath: fileName)
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            let extensionName = fileURL.pathExtension
            
            for index in 2...10_000 {
                let candidateName: String
                if extensionName.isEmpty {
                    candidateName = "\(baseName) \(index)"
                } else {
                    candidateName = "\(baseName) \(index).\(extensionName)"
                }
                
                let duplicateURL = storage.downloadsDirectoryURL.appendingPathComponent(candidateName, isDirectory: false)
                if !fileManager.fileExists(atPath: duplicateURL.path), !activeNames.contains(candidateName.lowercased()) {
                    return duplicateURL
                }
            }
            
            return storage.downloadsDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
        }
        
        return candidateURL
    }
    
    private func importFileLocked(from sourceURL: URL, to destinationURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return false
        }
        
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                try? fileManager.removeItem(at: sourceURL)
            }
            
            return true
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            return false
        }
    }
    
    // MARK: - Transfer Lifecycle
    
    private func completeCapturedDownloadLocked(localFilePath: String, succeeded: Bool) {
        guard let active = capturedDownloads.removeValue(forKey: localFilePath) else {
            try? fileManager.removeItem(at: URL(fileURLWithPath: localFilePath))
            return
        }
        
        guard succeeded else {
            storePersistedEntryLocked(
                makePersistedEntry(for: active, state: .failed)
            )
            postDidChange()
            return
        }
        
        let sourceFileURL = URL(fileURLWithPath: localFilePath)
        prepareStorageLocked()
        
        guard importFileLocked(from: sourceFileURL, to: active.destinationURL) else {
            storePersistedEntryLocked(
                makePersistedEntry(for: active, state: .failed)
            )
            postDidChange()
            return
        }
        
        let fileSize = resolvedFileSize(at: active.destinationURL) ?? active.downloadedBytes
        storePersistedEntryLocked(
            makePersistedEntry(for: active, state: .completed, fileSize: fileSize)
        )
        hasUnviewedCompletedDownloads = true
        postDidChange()
    }
    
    private func updateCapturedProgress(_ active: CapturedDownload, bytesReceived: Int64) {
        active.downloadedBytes = bytesReceived
        guard !active.isPaused else {
            postDidChange()
            return
        }
        
        updateTransferRate(
            totalBytesWritten: bytesReceived,
            bytesPerSecond: &active.bytesPerSecond,
            lastProgressSample: &active.lastProgressSample
        )
        postDidChange()
    }
    
    private func updateTransferRate(
        totalBytesWritten: Int64,
        bytesPerSecond: inout Int64,
        lastProgressSample: inout ProgressSample?
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        if let previousSample = lastProgressSample {
            let deltaTime = max(now - previousSample.timestamp, 0.001)
            let deltaBytes = max(totalBytesWritten - previousSample.bytesWritten, 0)
            let instantaneousSpeed = Int64(Double(deltaBytes) / deltaTime)
            if bytesPerSecond == 0 {
                bytesPerSecond = instantaneousSpeed
            } else {
                let smoothedSpeed = (Double(bytesPerSecond) * 0.65) + (Double(instantaneousSpeed) * 0.35)
                bytesPerSecond = Int64(smoothedSpeed)
            }
        }
        lastProgressSample = ProgressSample(bytesWritten: totalBytesWritten, timestamp: now)
    }
    
    private func completeDownload(taskIdentifier: Int, temporaryLocation: URL) {
        guard let active = activeDownloads.removeValue(forKey: taskIdentifier) else {
            return
        }
        
        prepareStorageLocked()
        
        do {
            if fileManager.fileExists(atPath: active.destinationURL.path) {
                try fileManager.removeItem(at: active.destinationURL)
            }
            
            try fileManager.moveItem(at: temporaryLocation, to: active.destinationURL)
            let fileSize = resolvedFileSize(at: active.destinationURL) ?? active.downloadedBytes
            
            storePersistedEntryLocked(
                makePersistedEntry(for: active, state: .completed, fileSize: fileSize)
            )
            hasUnviewedCompletedDownloads = true
        } catch {
            try? fileManager.removeItem(at: temporaryLocation)
            storePersistedEntryLocked(
                makePersistedEntry(for: active, state: .failed)
            )
        }
        
        postDidChange()
    }
    
    private func resolvedFileSize(at url: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        
        return size.int64Value
    }
    
    private func updateProgress(
        taskIdentifier: Int,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let active = activeDownloads[taskIdentifier] else {
            return
        }
        
        active.downloadedBytes = totalBytesWritten
        if totalBytesExpectedToWrite > 0 {
            active.expectedBytes = totalBytesExpectedToWrite
        }
        
        guard !active.isPaused else {
            postDidChange()
            return
        }
        
        updateTransferRate(
            totalBytesWritten: totalBytesWritten,
            bytesPerSecond: &active.bytesPerSecond,
            lastProgressSample: &active.lastProgressSample
        )
        
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSessionProgressNotificationTime >= 0.5 {
            lastSessionProgressNotificationTime = now
            postDidChange()
        }
    }
    
    private func failDownload(taskIdentifier: Int, resumeData: Data? = nil) {
        guard let active = activeDownloads.removeValue(forKey: taskIdentifier) else {
            return
        }

        // Transient failures (dropped proxy, network switch, timeouts) usually
        // leave resume data behind; retry automatically a few times before
        // surfacing the download as failed-but-resumable.
        if let resumeData, active.autoRetryCount < 3 {
            active.autoRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.retryDownload(active: active, resumeData: resumeData)
            }
            return
        }

        storePersistedEntryLocked(
            makePersistedEntry(
                for: active,
                state: .failed,
                downloadedBytes: active.downloadedBytes,
                resumeData: resumeData
            )
        )
        postDidChange()
    }

    private func retryDownload(active: ActiveDownload, resumeData: Data) {
        stateQueue.async {
            guard !self.activeDownloads.values.contains(where: { $0.id == active.id }) else {
                return
            }

            let task = self.session.downloadTask(withResumeData: resumeData)
            active.task = task
            active.isPaused = false
            active.bytesPerSecond = 0
            active.lastProgressSample = nil

            self.activeDownloads[task.taskIdentifier] = active
            task.resume()
            self.postDidChange()
        }
    }
    
    // MARK: - Notifications
    
    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .downloadStoreDidChange, object: self)
        }
    }
    
    private func postDidStartDownload() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .downloadStoreDidStartDownload, object: self)
        }
    }
}

extension DownloadStore: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        stateQueue.async {
            self.updateProgress(
                taskIdentifier: downloadTask.taskIdentifier,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }
    }
    
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        stateQueue.sync {
            // URLSession hands over the body even for HTTP errors (e.g. a 404
            // HTML page); never save those as the downloaded file.
            if let httpResponse = downloadTask.response as? HTTPURLResponse,
               httpResponse.statusCode >= 400 {
                self.failDownload(taskIdentifier: downloadTask.taskIdentifier)
                return
            }

            self.completeDownload(taskIdentifier: downloadTask.taskIdentifier, temporaryLocation: location)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            return
        }

        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        stateQueue.async {
            self.failDownload(taskIdentifier: task.taskIdentifier, resumeData: resumeData)
        }
    }
}
