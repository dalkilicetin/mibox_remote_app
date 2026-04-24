import Foundation

// MARK: - CalibPoint

struct CalibPoint: Codable {
    let id: Int
    let db: Double   // pipeline'dan geçmiş accDb
    let da: Double   // pipeline'dan geçmiş accDa
    let cx: Double   // ekran X
    let cy: Double   // ekran Y
}

// MARK: - MotionFilter
// alpha=0.3: daha responsive — 0.5 cursor lag yaratıyordu

final class MotionFilter {
    private var smoothB: Double = 0
    private var smoothA: Double = 0
    let alpha: Double = 0.3

    func reset() { smoothB = 0; smoothA = 0 }

    // Decay: ani reset yerine yumuşak düşüş (edge snap önleme)
    func decay(factor: Double = 0.7) {
        smoothB *= factor
        smoothA *= factor
    }

    func apply(db: Double, da: Double) -> (Double, Double) {
        smoothB = alpha * smoothB + (1 - alpha) * db
        smoothA = alpha * smoothA + (1 - alpha) * da
        return (smoothB, smoothA)
    }
}

// MARK: - Dead zone
// Eşitlenmiş threshold — yatay/dikey dengeli

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
// 60Hz baz, max 3x spike koruması + moving average (jitter önleme)

final class DtSmoother {
    private var samples: [Double] = []
    private let maxSamples = 4

    func smooth(_ dt: Double) -> Double {
        samples.append(dt)
        if samples.count > maxSamples { samples.removeFirst() }
        return samples.reduce(0, +) / Double(samples.count)
    }

    func reset() { samples.removeAll() }
}

func normalizeDt(db: Double, da: Double, dt: Double) -> (Double, Double) {
    let factor = min(dt * 60.0, 3.0)
    return (db * factor, da * factor)
}

// MARK: - CalibrationEngine
// IDW interpolasyon + screen bounds clamp + output smoothing

final class CalibrationEngine {
    private(set) var points: [CalibPoint] = []
    private let storageKey = "airmouse_calib_v1"

    // Output smoothing — mapping sonrası jitter azalt
    private var smoothX: Double = 960
    private var smoothY: Double = 540
    private let smoothAlpha: Double = 0.4

    var isReady: Bool { points.count >= 4 }
    var pointCount: Int { points.count }

    var screenW: Double = 1920
    var screenH: Double = 1080

    init() { load() }

    func addPoint(_ point: CalibPoint) {
        points.removeAll { $0.id == point.id }
        points.append(point)
        save()
    }

    func reset() {
        points.removeAll()
        smoothX = 960; smoothY = 540
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

        // Screen bounds clamp — edge extrapolation bozulmasın
        let rawX = max(0, min(screenW, xSum / wSum))
        let rawY = max(0, min(screenH, ySum / wSum))

        // Output smoothing — mapping sonrası jitter
        smoothX = smoothAlpha * smoothX + (1 - smoothAlpha) * rawX
        smoothY = smoothAlpha * smoothY + (1 - smoothAlpha) * rawY

        return (smoothX, smoothY)
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
    let filter      = MotionFilter()
    let calibration = CalibrationEngine()
    let dtSmoother  = DtSmoother()

    // Fix 1: Calibration için doğru delta — accDb/accDa expose et
    private(set) var lastAccDb: Double = 0
    private(set) var lastAccDa: Double = 0

    // Gyro state — CMDeviceMotion kullanıldığı için basit last value track
    private var lastBeta:  Double? = nil
    private var lastAlpha: Double? = nil

    var lastCursorX: Double = 960
    var lastCursorY: Double = 540
    var screenW: Double = 1920 { didSet { calibration.screenW = screenW } }
    var screenH: Double = 1080 { didSet { calibration.screenH = screenH } }

    private let edgeMargin: Double = 20

    func reset() {
        lastBeta = nil; lastAlpha = nil
        filter.reset()
        dtSmoother.reset()
        lastAccDb = 0; lastAccDa = 0
    }

    /// Tam pipeline
    /// beta/alpha: CMDeviceMotion'dan gelen attitude değerleri (°)
    func process(
        beta: Double,
        alpha: Double,
        dt: Double,
        sensitivity: Double
    ) -> (dx: Int, dy: Int)? {

        // 1. Delta hesapla + wrap fix
        guard let lb = lastBeta, let la = lastAlpha else {
            lastBeta = beta; lastAlpha = alpha; return nil
        }
        var rawDb = beta  - lb
        var rawDa = alpha - la

        if rawDb >  90 { rawDb -= 180 }; if rawDb < -90 { rawDb += 180 }
        if rawDa > 180 { rawDa -= 360 }; if rawDa < -180 { rawDa += 360 }

        lastBeta = beta; lastAlpha = alpha

        // 2. Low-pass filter (alpha=0.3)
        let (filtDb, filtDa) = filter.apply(db: rawDb, da: rawDa)

        // 3. Dead zone — eşitlenmiş threshold (0.12)
        let db = applyDeadZone(filtDb, threshold: 0.12)
        let da = applyDeadZone(filtDa, threshold: 0.12)
        guard db != 0 || da != 0 else { return nil }

        // 4. DeltaTime normalization (dt smoothed)
        let smoothedDt = dtSmoother.smooth(dt)
        let (normDb, normDa) = normalizeDt(db: db, da: da, dt: smoothedDt)

        // 5. Acceleration curve
        let (accDb, accDa) = applyAcceleration(db: normDb, da: normDa)

        // Fix 1: pipeline sonrası değerleri sakla — calibration bunu kullanır
        lastAccDb = accDb
        lastAccDa = accDa

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

    /// Edge'e gelince decay (ani reset yerine yumuşak düşüş)
    func onCursorUpdate(x: Double, y: Double) {
        lastCursorX = x
        lastCursorY = y
        if x >= screenW - edgeMargin || x <= edgeMargin { filter.decay() }
        if y >= screenH - edgeMargin || y <= edgeMargin { filter.decay() }
    }
}
