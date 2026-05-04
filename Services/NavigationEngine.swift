import Foundation

// MARK: - NavigationEngine
//
// Mimari:
//   GyroEngine (mevcut InputEngine.swift) → raw motion data
//   NavigationEngine                      → intent (up/down/left/right + velocity)
//   AtvRemoteService                      → transport (sendDir)
//
// UI → engine.update(dx:dy:) veya engine.push(code:)
// Engine → onDirection(code, dir) callback → AtvRemoteService.sendDir

final class NavigationEngine {

    // MARK: - Config

    private let baseInterval: Double = 0.016   // 60 FPS
    private let minInterval:  Double = 0.006   // max hız ~160 FPS
    private let accelFactor:  Double = 0.85    // hızlanma katsayısı
    private let deadZone:     Float  = 0.08    // küçük hareketleri ignore et

    // MARK: - Direction (intent)

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

    // MARK: - State

    private var currentDir: Direction? = nil   // nil = dead zone
    private var lastDir:    Direction? = nil
    private var currentInterval: Double = 0.016

    // Discrete key queue — buton tabanlı input
    private var discreteQueue: [(code: Int, dir: Int)] = []
    private let lock = NSLock()

    private var task: Task<Void, Never>?
    private var isRunning = false

    // MARK: - Callback
    // Engine sadece intent üretir, transport AtvRemoteService'e aittir

    var onDirection: ((Int, Int) -> Void)?   // (keyCode, direction)

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleNextTick()
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
        currentDir = nil
        lastDir = nil
        currentInterval = baseInterval
    }

    // Continuous input — GyroEngine veya AirMouseView'dan gelir
    // dx: yatay sapma, dy: dikey sapma (normalize edilmiş, -1...1 arası ideal)
    func update(dx: Float, dy: Float) {
        if abs(dx) < deadZone && abs(dy) < deadZone {
            currentDir = nil
            currentInterval = baseInterval
            return
        }

        let dir: Direction
        if abs(dx) > abs(dy) {
            dir = dx > 0 ? .right : .left
            let velocity = abs(dx)
            let speed = min(max(Double(velocity), 0.1), 1.0)
            currentInterval = max(baseInterval * pow(accelFactor, speed * 10), minInterval)
        } else {
            dir = dy > 0 ? .down : .up
            let velocity = abs(dy)
            let speed = min(max(Double(velocity), 0.1), 1.0)
            currentInterval = max(baseInterval * pow(accelFactor, speed * 10), minInterval)
        }

        currentDir = dir
    }

    // Discrete input — sendKey(code:) buraya yönlendirilir
    func push(code: Int, dir: Int) {
        lock.lock()
        defer { lock.unlock() }
        if discreteQueue.count >= 30 {
            discreteQueue.removeFirst(10)  // eski komutları at, son komutları koru
        }
        discreteQueue.append((code: code, dir: dir))
    }

    // MARK: - Tick loop (değişken interval)

    private func scheduleNextTick() {
        guard isRunning else { return }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.currentInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.tick()
            self.scheduleNextTick()
        }
    }

    @MainActor
    private func tick() {
        // 1. Discrete queue — max 3/tick
        lock.lock()
        let batch = Array(discreteQueue.prefix(3))
        discreteQueue.removeFirst(min(3, discreteQueue.count))
        lock.unlock()

        for item in batch {
            onDirection?(item.code, item.dir)
        }

        // 2. Continuous direction
        guard let dir = currentDir else { return }

        if dir.keyCode != lastDir?.keyCode {
            // Direction değişti → anında gönder (snappy hissi)
            onDirection?(dir.keyCode, 3)
            lastDir = dir
        } else {
            // Aynı yön → velocity controlled repeat
            onDirection?(dir.keyCode, 3)
        }
    }
}
