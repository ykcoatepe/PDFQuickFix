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
    
    // MARK: - Properties
    
    private var activeTasks: [UUID: TaskInfo] = [:]
    private var pendingTasks: [PendingTask] = []
    private var isPaused: Bool = false
    private let maxConcurrentTasks: Int
    
    static let shared = BackgroundTaskCoordinator()
    
    // MARK: - Initialization
    
    init(maxConcurrentTasks: Int = 4) {
        self.maxConcurrentTasks = maxConcurrentTasks
    }
    
    // MARK: - Internal Types
    
    private struct PendingTask {
        let id: UUID
        let name: String
        let priority: Priority
        let work: @Sendable () async -> Void
    }
    
    // MARK: - Public API
    
    @discardableResult
    func schedule(
        name: String,
        priority: Priority,
        work: @escaping @Sendable () async -> Void
    ) -> UUID {
        let id = UUID()
        let pending = PendingTask(id: id, name: name, priority: priority, work: work)
        
        // Add to pending queue
        pendingTasks.append(pending)
        
        // Sort pending tasks by priority (highest first)
        pendingTasks.sort { $0.priority > $1.priority }
        
        // Try to run tasks
        processQueue()
        
        return id
    }
    
    func cancel(id: UUID) {
        // Check active tasks
        if let info = activeTasks.removeValue(forKey: id) {
            info.task.cancel()
        }
        
        // Check pending tasks
        if let index = pendingTasks.firstIndex(where: { $0.id == id }) {
            pendingTasks.remove(at: index)
        }
        
        // Removing a task might open a slot if it was active? 
        // We already handled active removal above. If it was pending, no slot change for others.
        // If an active task was cancelled, we should try to fill the slot.
        processQueue()
    }
    
    func cancelBelow(priority: Priority) {
        // Cancel active
        let activeIdsToCancel = activeTasks.filter { $0.value.priority < priority }.map { $0.key }
        for id in activeIdsToCancel {
            if let info = activeTasks.removeValue(forKey: id) {
                info.task.cancel()
            }
        }
        
        // Cancel pending
        pendingTasks.removeAll { $0.priority < priority }
        
        processQueue()
    }
    
    func cancelAll() {
        for info in activeTasks.values {
            info.task.cancel()
        }
        activeTasks.removeAll()
        pendingTasks.removeAll()
    }
    
    func pause() {
        isPaused = true
        // We don't suspend running tasks, but we stop starting new ones (except high priority)
    }
    
    func resume() {
        isPaused = false
        processQueue()
    }
    
    var activeCount: Int {
        activeTasks.count
    }
    
    var paused: Bool {
        isPaused
    }
    
    // MARK: - Private
    
    private func processQueue() {
        // While we have slots and pending tasks
        while activeTasks.count < maxConcurrentTasks, !pendingTasks.isEmpty {
            // Peek at the highest priority pending task
            guard let next = pendingTasks.first else { break }
            
            // Check pause condition
            // If paused, only allow High priority
            if isPaused && next.priority < .high {
                // Since sorted by priority, if top is not high, none are (assuming strict order).
                // If we have mix of Low and High, High would be at top.
                // So if top is < High, we are effectively blocked by pause.
                break
            }
            
            // Launch it
            let pending = pendingTasks.removeFirst()
            runTask(pending)
        }
    }
    
    private func runTask(_ pending: PendingTask) {
        let id = pending.id
        let task = Task.detached(priority: pending.priority.taskPriority) {
            await pending.work()
        }
        
        let info = TaskInfo(id: id, name: pending.name, priority: pending.priority, task: task)
        activeTasks[id] = info
        
        // Cleanup handler
        Task {
            _ = await task.result
            self.taskFinished(id: id)
        }
    }
    
    private func taskFinished(id: UUID) {
        activeTasks.removeValue(forKey: id)
        processQueue()
    }
    
    private func removeTask(id: UUID) {
        // Legacy/internal helper replaced by taskFinished logic, keeping for compatibility if needed or removing.
        // The cleanup task above calls taskFinished.
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
