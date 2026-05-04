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
        startLoop()
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

    // MARK: - Tick loop — single while loop, recursive scheduling yok

    private func startLoop() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                // Interval her tick'te hesaplanır — gecikme yok
                let interval = self.currentInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self.tick()
            }
        }
    }

    @MainActor
    private func tick() {
        // Priority: discrete (button) > continuous (gyro)
        lock.lock()
        let batch = Array(discreteQueue.prefix(2))
        discreteQueue.removeFirst(min(2, discreteQueue.count))
        let hasDiscrete = !batch.isEmpty
        lock.unlock()

        if hasDiscrete {
            // Discrete input varsa gyro'yu ignore et
            for (i, item) in batch.enumerated() {
                onDirection?(item.code, item.dir)
            }
            return
        }

        // Gyro/continuous direction
        guard let dir = currentDir else { return }

        if dir.keyCode != lastDir?.keyCode {
            // Direction değişti → anında gönder (snappy)
            onDirection?(dir.keyCode, 3)
            lastDir = dir
        } else {
            // Aynı yön → velocity controlled repeat
            onDirection?(dir.keyCode, 3)
        }
    }
}
