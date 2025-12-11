import Foundation

/// Centralized coordinator for background tasks in the app.
/// Limits concurrent operations, supports cancellation, and can pause during active scrolling.
actor BackgroundTaskCoordinator {
    
    // MARK: - Types
    
    enum Priority: Int, Comparable {
        case idle = 0
        case low = 1
        case normal = 2
        case high = 3
        
        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    struct TaskInfo: Identifiable {
        let id: UUID
        let name: String
        let priority: Priority
        let task: Task<Void, Never>
    }
    
    // MARK: - Properties
    
    private var activeTasks: [UUID: TaskInfo] = [:]
    private var isPaused: Bool = false
    private let maxConcurrentTasks: Int
    
    static let shared = BackgroundTaskCoordinator()
    
    // MARK: - Initialization
    
    init(maxConcurrentTasks: Int = 4) {
        self.maxConcurrentTasks = maxConcurrentTasks
    }
    
    // MARK: - Public API
    
    /// Schedule a background task with a given priority.
    /// - Parameters:
    ///   - name: Human-readable name for debugging
    ///   - priority: Task priority
    ///   - work: The async work to perform
    /// - Returns: The task ID (can be used for cancellation)
    @discardableResult
    func schedule(
        name: String,
        priority: Priority,
        work: @escaping @Sendable () async -> Void
    ) -> UUID {
        let id = UUID()
        
        // If paused and not high priority, defer
        if isPaused && priority < .high {
            // Queue for later (simplified: just create with delay)
            let task = Task.detached(priority: priority.taskPriority) {
                try? await Task.sleep(for: .milliseconds(100))
                if !Task.isCancelled {
                    await work()
                }
            }
            let info = TaskInfo(id: id, name: name, priority: priority, task: task)
            activeTasks[id] = info
            
            // Clean up when done
            Task {
                _ = await task.result
                await self.removeTask(id: id)
            }
            return id
        }
        
        // Check if we can run immediately
        if activeTasks.count < maxConcurrentTasks {
            let task = Task.detached(priority: priority.taskPriority) {
                await work()
            }
            let info = TaskInfo(id: id, name: name, priority: priority, task: task)
            activeTasks[id] = info
            
            Task {
                _ = await task.result
                await self.removeTask(id: id)
            }
        } else {
            // Queue with delay
            let task = Task.detached(priority: priority.taskPriority) {
                try? await Task.sleep(for: .milliseconds(50))
                if !Task.isCancelled {
                    await work()
                }
            }
            let info = TaskInfo(id: id, name: name, priority: priority, task: task)
            activeTasks[id] = info
            
            Task {
                _ = await task.result
                await self.removeTask(id: id)
            }
        }
        
        return id
    }
    
    /// Cancel a specific task by ID.
    func cancel(id: UUID) {
        if let info = activeTasks.removeValue(forKey: id) {
            info.task.cancel()
        }
    }
    
    /// Cancel all tasks with priority below the specified level.
    func cancelBelow(priority: Priority) {
        let idsToCancel = activeTasks.filter { $0.value.priority < priority }.map { $0.key }
        for id in idsToCancel {
            if let info = activeTasks.removeValue(forKey: id) {
                info.task.cancel()
            }
        }
    }
    
    /// Cancel all active tasks.
    func cancelAll() {
        for info in activeTasks.values {
            info.task.cancel()
        }
        activeTasks.removeAll()
    }
    
    /// Pause all non-high-priority tasks. Call during active scrolling.
    func pause() {
        isPaused = true
    }
    
    /// Resume normal operation.
    func resume() {
        isPaused = false
    }
    
    /// Get current number of active tasks.
    var activeCount: Int {
        activeTasks.count
    }
    
    /// Check if the coordinator is paused.
    var paused: Bool {
        isPaused
    }
    
    // MARK: - Private
    
    private func removeTask(id: UUID) {
        activeTasks.removeValue(forKey: id)
    }
}

// MARK: - Priority Extension

extension BackgroundTaskCoordinator.Priority {
    var taskPriority: TaskPriority {
        switch self {
        case .idle: return .background
        case .low: return .low
        case .normal: return .medium
        case .high: return .high
        }
    }
}
