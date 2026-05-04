import Foundation

// MARK: - NavigationEngine
//
// Mimari:
//   InputEngine.swift (gyro) → raw motion
//   NavigationEngine          → intent (direction + velocity)
//   AtvRemoteService          → transport (sendDir)
//
// Thread model:
//   update() → herhangi bir thread (stateLock ile korunur)
//   tick()   → background task
//   onDirection callback → üst katman kontrol eder (AtvRemoteService @MainActor'a dispatch eder)

final class NavigationEngine {

    // MARK: - Config

    private let baseInterval: Double = 0.016
    private let minInterval:  Double = 0.006
    private let deadZone:     Float  = 0.08

    // MARK: - Direction

    enum Direction {
        case up, down, left, right

        var keyCode: Int {
            switch self {
            case .up:    return 19
            case .down:  return 20
            case .left:  return 21
            case .right: return 22
            }
        }
    }

    // MARK: - State (tamamı stateLock altında)

    private let stateLock = NSLock()
    private var _currentDir: Direction? = nil
    private var _currentInterval: Double = 0.016
    private var _lastDir: Direction? = nil
    private var _lastAxisIsX = true

    // MARK: - Discrete queue

    private var discreteQueue: [(code: Int, dir: Int)] = []
    private let queueLock = NSLock()

    private var task: Task<Void, Never>?
    private var isRunning = false

    // MARK: - Callback
    // Main thread dispatch üst katmanın sorumluluğu (AtvRemoteService)

    var onDirection: ((Int, Int) -> Void)?

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = self.stateLock.withLock { self._currentInterval }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self.tick()
            }
        }
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil

        stateLock.lock()
        _currentDir = nil
        _currentInterval = baseInterval
        _lastDir = nil
        _lastAxisIsX = true
        stateLock.unlock()

        // Discrete queue temizle
        queueLock.lock()
        discreteQueue.removeAll()
        queueLock.unlock()
    }

    // Continuous input — gyro/AirMouseView'dan gelir
    func update(dx: Float, dy: Float) {
        stateLock.lock()
        defer { stateLock.unlock() }

        if abs(dx) < deadZone && abs(dy) < deadZone {
            _currentDir = nil
            _currentInterval = baseInterval
            _lastDir = nil   // dead zone'da reset — sonraki swipe'ta ilk event kaybolmasın
            return
        }

        // Hysteresis — dx ≈ dy durumunda direction flip önle
        if abs(dx) > abs(dy) * 1.2 {
            _lastAxisIsX = true
        } else if abs(dy) > abs(dx) * 1.2 {
            _lastAxisIsX = false
        }

        let dir: Direction
        let velocity: Float
        if _lastAxisIsX {
            dir = dx > 0 ? .right : .left
            velocity = abs(dx)
        } else {
            dir = dy > 0 ? .down : .up
            velocity = abs(dy)
        }

        _currentDir = dir

        // Smoothstep acceleration — Apple benzeri easing
        let t = Double(min(velocity, 1.0))
        let smooth = t * t * (2.5 - 1.5 * t)  // organic curve — başlangıç yumuşak, orta hızlı
        _currentInterval = max(baseInterval - (baseInterval - minInterval) * smooth, minInterval)
    }

    // Discrete input — buton basımı
    func push(code: Int, dir: Int) {
        queueLock.lock()
        defer { queueLock.unlock() }
        if discreteQueue.count >= 30 {
            discreteQueue.removeFirst(10)
        }
        discreteQueue.append((code: code, dir: dir))
    }

    // MARK: - Tick (background thread)

    private func tick() {
        // Discrete queue — max 2/tick, priority over gyro
        queueLock.lock()
        let batch = Array(discreteQueue.prefix(1))  // burst azalt — SendScheduler spacing halleder
        discreteQueue.removeFirst(min(1, discreteQueue.count))
        let hasDiscrete = !batch.isEmpty
        queueLock.unlock()

        if hasDiscrete {
            for item in batch {
                onDirection?(item.code, item.dir)
                // usleep YOK — spacing üst katmanda (network buffer halleder)
            }
            return
        }

        // Continuous direction — check + update aynı critical section (TOCTOU önleme)
        stateLock.lock()
        guard let dir = _currentDir else {
            stateLock.unlock()
            return
        }
        let isNewDir = dir.keyCode != _lastDir?.keyCode
        if isNewDir { _lastDir = dir }
        stateLock.unlock()

        // Direction değişti → snappy, aynı yön → velocity controlled repeat
        onDirection?(dir.keyCode, 3)
    }
}

// MARK: - NSLock extension

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
