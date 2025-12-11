import Foundation
import Dispatch
import CoreGraphics

/// Monitors system memory pressure and triggers cache eviction when memory is low.
/// Uses `DispatchSource.makeMemoryPressureSource` for efficient low-level monitoring.
final class MemoryPressureMonitor {
    
    // MARK: - Types
    
    enum PressureLevel {
        case normal
        case warning
        case critical
    }
    
    typealias PressureHandler = (PressureLevel) -> Void
    
    // MARK: - Properties
    
    private var source: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "com.pdfquickfix.memory-pressure", qos: .utility)
    private var handlers: [UUID: PressureHandler] = [:]
    private let handlersLock = NSLock()
    
    private(set) var currentLevel: PressureLevel = .normal
    
    static let shared = MemoryPressureMonitor()
    
    // MARK: - Initialization
    
    private init() {
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - Public API
    
    /// Register a handler to be called when memory pressure changes.
    /// - Returns: An ID that can be used to unregister the handler.
    @discardableResult
    func registerHandler(_ handler: @escaping PressureHandler) -> UUID {
        let id = UUID()
        handlersLock.lock()
        handlers[id] = handler
        handlersLock.unlock()
        return id
    }
    
    /// Unregister a previously registered handler.
    func unregisterHandler(_ id: UUID) {
        handlersLock.lock()
        handlers.removeValue(forKey: id)
        handlersLock.unlock()
    }
    
    // MARK: - Private
    
    private func startMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: queue
        )
        
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            
            let level: PressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            
            self.currentLevel = level
            self.notifyHandlers(level: level)
        }
        
        source.resume()
        self.source = source
    }
    
    private func stopMonitoring() {
        source?.cancel()
        source = nil
    }
    
    private func notifyHandlers(level: PressureLevel) {
        handlersLock.lock()
        let currentHandlers = handlers
        handlersLock.unlock()
        
        for handler in currentHandlers.values {
            DispatchQueue.main.async {
                handler(level)
            }
        }
    }
}

// MARK: - Convenience for StudioController

extension MemoryPressureMonitor {
    
    /// Register standard cache eviction behavior for the app.
    /// Call once at app launch or controller initialization.
    static func registerDefaultHandlers(
        thumbnailCache: NSCache<NSNumber, CGImage>,
        streamingLoader: StreamingPDFLoader,
        renderService: PDFRenderService
    ) -> UUID {
        return shared.registerHandler { level in
            switch level {
            case .warning:
                // Reduce cache limits
                thumbnailCache.countLimit = 100
                renderService.cancelAll()
                
            case .critical:
                // Aggressive eviction
                thumbnailCache.removeAllObjects()
                thumbnailCache.countLimit = 50
                streamingLoader.evictResolvedPages()
                renderService.cancelAll()
                
            case .normal:
                // Restore normal limits
                thumbnailCache.countLimit = 200
            }
        }
    }
}
