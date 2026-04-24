import Foundation

// MARK: - CalibPoint

struct CalibPoint: Codable {
    let id: Int
    let db: Double   // gyro pitch delta (bu pozisyondaki ölçüm)
    let da: Double   // gyro yaw delta
    let cx: Double   // karşılık gelen ekran X
    let cy: Double   // karşılık gelen ekran Y
}

// MARK: - GyroProcessor
// Beta ve alpha AYRI frekanslarda geldiği için ayrı track edilir.
// process() her accelerometer update'inde çağrılır — o anki rawAlpha dışarıdan verilir.

final class GyroProcessor {
    private var lastBeta:  Double?
    private var lastAlpha: Double?

    func reset() { lastBeta = nil; lastAlpha = nil }

    func process(beta: Double, alpha: Double) -> (db: Double, da: Double)? {
        guard let lb = lastBeta, let la = lastAlpha else {
            lastBeta = beta; lastAlpha = alpha; return nil
        }

        var db = beta - lb
        var da = alpha - la

        // Pitch wrap
        if db >  90 { db -= 180 }
        if db < -90 { db += 180 }

        // Yaw wrap
        if da >  180 { da -= 360 }
        if da < -180 { da += 360 }

        lastBeta  = beta
        lastAlpha = alpha
        return (db, da)
    }
}

// MARK: - MotionFilter
// alpha=0.5: bridge değeri — dengeli tepki/smooth
// 0.8 olursa cursor geride kalır ("kayıyor" hissi)

final class MotionFilter {
    private var smoothB: Double = 0
    private var smoothA: Double = 0
    let alpha: Double = 0.5

    func reset() { smoothB = 0; smoothA = 0 }

    func apply(db: Double, da: Double) -> (Double, Double) {
        smoothB = alpha * smoothB + (1 - alpha) * db
        smoothA = alpha * smoothA + (1 - alpha) * da
        return (smoothB, smoothA)
    }
}

// MARK: - Dead zone

func applyDeadZone(_ v: Double, threshold: Double) -> Double {
    abs(v) < threshold ? 0 : v
}

// MARK: - Acceleration
// Bridge'den birebir

func applyAcceleration(db: Double, da: Double) -> (Double, Double) {
    let speed = sqrt(db * db + da * da)
    let boost = speed > 3 ? (1.0 + (speed - 3) * 0.3) : 1.0
    return (db * boost, da * boost)
}

// MARK: - DeltaTime normalization
// 60Hz baz: dt=16ms→1.0, dt=8ms→0.5, dt=32ms→2.0
// max 3x — ani spike koruması

func normalizeDt(db: Double, da: Double, dt: Double) -> (Double, Double) {
    let factor = min(dt * 60.0, 3.0)
    return (db * factor, da * factor)
}

// MARK: - CalibrationEngine
// Bridge'deki map_to_screen() — IDW interpolasyon
// 9 nokta (3x3 grid), en yakın 4 nokta ağırlıklı ortalama

final class CalibrationEngine {
    private(set) var points: [CalibPoint] = []
    private let storageKey = "airmouse_calib_v1"

    var isReady: Bool { points.count >= 4 }
    var pointCount: Int { points.count }

    init() { load() }

    func addPoint(_ point: CalibPoint) {
        points.removeAll { $0.id == point.id }
        points.append(point)
        save()
    }

    func reset() {
        points.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func map(db: Double, da: Double) -> (cx: Double, cy: Double)? {
        guard isReady else { return nil }

        let sorted = points.sorted {
            distSq($0, db: db, da: da) < distSq($1, db: db, da: da)
        }
        let nearest = Array(sorted.prefix(4))

        var xSum = 0.0, ySum = 0.0, wSum = 0.0
        for p in nearest {
            let d = max(distSq(p, db: db, da: da), 0.0001)
            let w = 1.0 / d
            xSum += w * p.cx
            ySum += w * p.cy
            wSum += w
        }
        return (xSum / wSum, ySum / wSum)
    }

    private func distSq(_ p: CalibPoint, db: Double, da: Double) -> Double {
        (p.db - db) * (p.db - db) + (p.da - da) * (p.da - da)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(points) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let pts  = try? JSONDecoder().decode([CalibPoint].self, from: data)
        else { return }
        points = pts
    }
}

// MARK: - InputEngine (full pipeline)

final class InputEngine {
    let gyro        = GyroProcessor()
    let filter      = MotionFilter()
    let calibration = CalibrationEngine()

    var lastCursorX: Double = 960
    var lastCursorY: Double = 540
    var screenW: Double = 1920
    var screenH: Double = 1080

    private let edgeMargin: Double = 20

    func reset() {
        gyro.reset()
        filter.reset()
    }

    /// Tam pipeline — döndürür (dx, dy) veya nil (hareket yok)
    func process(
        beta: Double,
        alpha: Double,
        dt: Double,
        sensitivity: Double
    ) -> (dx: Int, dy: Int)? {

        // 1. Raw gyro → delta + wrap fix
        guard let (rawDb, rawDa) = gyro.process(beta: beta, alpha: alpha) else { return nil }

        // 2. Low-pass filter
        let (filtDb, filtDa) = filter.apply(db: rawDb, da: rawDa)

        // 3. Dead zone
        let db = applyDeadZone(filtDb, threshold: 0.3)
        let da = applyDeadZone(filtDa, threshold: 0.05)
        guard db != 0 || da != 0 else { return nil }

        // 4. DeltaTime normalization
        let (normDb, normDa) = normalizeDt(db: db, da: da, dt: dt)

        // 5. Acceleration curve
        let (accDb, accDa) = applyAcceleration(db: normDb, da: normDa)

        // 6. Calibration map veya delta fallback
        if calibration.isReady,
           let mapped = calibration.map(db: accDb, da: accDa) {
            let dx = Int((mapped.cx - lastCursorX).rounded())
            let dy = Int((mapped.cy - lastCursorY).rounded())
            return dx == 0 && dy == 0 ? nil : (dx, dy)
        } else {
            let dx = Int((accDa * sensitivity / 25.0).rounded())
            let dy = Int((accDb * sensitivity / 25.0 * -1.0).rounded())
            return dx == 0 && dy == 0 ? nil : (dx, dy)
        }
    }

    /// Bridge'deki onCursorPos() — edge'e gelince filter state sıfırla
    func onCursorUpdate(x: Double, y: Double) {
        lastCursorX = x
        lastCursorY = y
        if x >= screenW - edgeMargin || x <= edgeMargin { filter.reset() }
        if y >= screenH - edgeMargin || y <= edgeMargin { gyro.reset() }
    }
}
