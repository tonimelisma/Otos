import Foundation

/// Perspective field solver guide
///
/// GeoCalib (Veicht et al., ECCV 2024; code Apache-2.0, weights CC-BY-4.0, ETH Zurich) reads a
/// photo in two parts. Its network predicts, for every pixel, the image direction of "up" and the
/// latitude of the pixel's ray (the angle between the ray and the horizon), each with a
/// confidence. This solver is the second part, ported from GeoCalib's `LMOptimizer` for its
/// pinhole camera: it finds the gravity direction and focal length whose perspective fields best
/// explain the predicted ones, by Levenberg–Marquardt on a confidence-weighted Huber cost, and
/// reports the roll's standard deviation from the inverse Hessian at the solution.
///
/// The port is exact, not approximate, so the uncertainty Otos gates on is the one measured in
/// `docs/research/2026-11-01-auto-straighten-and-crop-suggestions.md`:
/// - pixel `(x, y)` maps to `((x − w/2) / f, (y − h/2) / f)`;
/// - gravity is a unit vector updated on the sphere (a Householder chart) and the focal length in
///   log space, clamped to fields of view between 5° and 150°;
/// - the up residual is the predicted unit up vector minus the field's; the latitude residual is
///   sin of the predicted latitude minus the dot product of the pixel's unit ray with gravity;
/// - each cost is Huber with scale 0.01, weighted by its confidence; every step is accepted, the
///   damping goes ×10 when the cost rose and ×0.1 when it fell, within 1e-6…100;
/// - the solve stops at 30 steps or when the cost no longer changes (1e-8, absolute and relative).
///
/// Pure arithmetic on value types: no state, no isolation, safe to run on any thread.
nonisolated enum PerspectiveFieldSolver {
    /// The network's four fields at the size it ran at, row-major, `width × height` each.
    struct Fields {
        let width: Int
        let height: Int
        /// The up vector's x component per pixel, then its y component per pixel.
        let up: [Float]
        let upConfidence: [Float]
        /// Radians.
        let latitude: [Float]
        let latitudeConfidence: [Float]
    }

    struct Solution: Equatable {
        /// Radians, GeoCalib's convention: positive is the clockwise straighten that levels the
        /// photo.
        let roll: Double
        let pitch: Double
        /// One standard deviation of `roll`, radians.
        let rollUncertainty: Double
        /// Pixels at the network's size.
        let focal: Double
        let steps: Int
    }

    private static let lossScale = 0.01
    private static let maximumSteps = 30
    private static let tolerance = 1e-8

    static func solve(_ fields: Fields) -> Solution? {
        let pixels = fields.width * fields.height
        guard pixels > 0, fields.up.count == 2 * pixels, fields.upConfidence.count == pixels,
              fields.latitude.count == pixels, fields.latitudeConfidence.count == pixels
        else { return nil }
        let prepared = Prepared(fields)
        let height = Double(fields.height)
        var state = State(
            gravity: SIMD3(0, -1, 0),
            focal: 0.7 * Double(max(fields.width, fields.height))
        )
        let focalRange = (minimum: focal(fieldOfView: 150 * .pi / 180, size: height),
                          maximum: focal(fieldOfView: 5 * .pi / 180, size: height))
        var damping = 0.1
        var previousCost = 0.0
        var steps = maximumSteps
        for step in 0 ..< maximumSteps {
            let system = normalEquations(prepared, state, parameters: .tangentLogFocal)
            if step == 0 {
                previousCost = system.cost
            }
            let delta = dampedStep(gradient: system.gradient, hessian: system.hessian, damping: damping)
            state = State(
                gravity: plus(state.gravity, delta: SIMD2(delta.x, delta.y)),
                focal: min(max(exp(log(state.focal) + delta.z), focalRange.minimum), focalRange.maximum)
            )
            let cost = normalEquations(prepared, state, parameters: .none).cost
            damping = min(max(damping * (cost > previousCost ? 10 : 0.1), 1e-6), 1e2)
            if abs(cost - previousCost) <= tolerance + tolerance * abs(previousCost) {
                steps = step + 1
                break
            }
            previousCost = cost
        }
        let final = normalEquations(prepared, state, parameters: .rollPitchFocal)
        guard let covariance = inverse(final.hessian), covariance[0][0] >= 0 else { return nil }
        let angles = rollPitch(state.gravity)
        return Solution(
            roll: angles.roll,
            pitch: angles.pitch,
            rollUncertainty: covariance[0][0].squareRoot(),
            focal: state.focal,
            steps: steps
        )
    }

    // MARK: - Model

    private struct State {
        /// Unit vector, camera frame.
        let gravity: SIMD3<Double>
        let focal: Double
    }

    /// Which parameters the Jacobian is taken with respect to: the solver's own (a tangent step on
    /// the sphere and the log focal length), GeoCalib's uncertainty parameters (roll, pitch and
    /// the focal length in pixels), or none when only the cost is wanted.
    private enum Parameters {
        case tangentLogFocal
        case rollPitchFocal
        case none
    }

    private struct NormalEquations {
        var cost = 0.0
        var gradient = SIMD3<Double>()
        var hessian = [[Double]](repeating: [0, 0, 0], count: 3)
    }

    /// The fields as the solve reads them on every step: in `Double`, the latitude already as
    /// its sine, which is what the residual compares.
    private struct Prepared {
        let width: Int
        let height: Int
        let upX: [Double]
        let upY: [Double]
        let upConfidence: [Double]
        let sinLatitude: [Double]
        let latitudeConfidence: [Double]

        init(_ fields: Fields) {
            let pixels = fields.width * fields.height
            width = fields.width
            height = fields.height
            upX = fields.up[0 ..< pixels].map(Double.init)
            upY = fields.up[pixels ..< 2 * pixels].map(Double.init)
            upConfidence = fields.upConfidence.map(Double.init)
            sinLatitude = fields.latitude.map { sin(Double($0)) }
            latitudeConfidence = fields.latitudeConfidence.map(Double.init)
        }
    }

    /// The cost, gradient and Hessian over every pixel. Written as scalar arithmetic over
    /// unsafe buffers, with no per-pixel allocation, closure or generic call: the installed app
    /// is a Debug build, where those made each solve take seconds rather than a tenth of one.
    private static func normalEquations(_ fields: Prepared, _ state: State, parameters: Parameters) -> NormalEquations {
        let width = fields.width, height = fields.height, pixels = width * height
        let gx = state.gravity.x, gy = state.gravity.y, gz = state.gravity.z, f = state.focal
        let cx = Double(width) / 2, cy = Double(height) / 2
        // How gravity's three components move with the two parameters that steer it.
        let basis: (SIMD3<Double>, SIMD3<Double>) = switch parameters {
        case .tangentLogFocal: tangentBasis(state.gravity)
        case .rollPitchFocal: rollPitchBasis(state.gravity)
        case .none: (.zero, .zero)
        }
        let a0 = basis.0.x, a1 = basis.0.y, a2 = basis.0.z
        let b0 = basis.1.x, b1 = basis.1.y, b2 = basis.1.z
        // d(normalized coordinate)/d(focal parameter) is −u for the log focal, −u/f in pixels.
        let focalScale = parameters == .rollPitchFocal ? 1 / f : 1.0
        let wantsJacobian = parameters != .none
        let scale2 = lossScale * lossScale
        let minimumWeight = Double(Float.ulpOfOne)

        var upCost = 0.0, latitudeCost = 0.0
        var g0 = 0.0, g1 = 0.0, g2 = 0.0
        var h00 = 0.0, h01 = 0.0, h02 = 0.0, h11 = 0.0, h12 = 0.0, h22 = 0.0
        fields.upX.withUnsafeBufferPointer { upX in
            fields.upY.withUnsafeBufferPointer { upY in
                fields.upConfidence.withUnsafeBufferPointer { upConfidence in
                    fields.sinLatitude.withUnsafeBufferPointer { sinLatitude in
                        fields.latitudeConfidence.withUnsafeBufferPointer { latitudeConfidence in
                            // `while`, not `for in`, and explicit comparisons, not `min`/`max`: an
                            // unoptimized build calls a generic iterator and generic comparisons
                            // for those on every pixel.
                            var y = 0
                            while y < height {
                                let v = (Double(y) - cy) / f
                                var x = 0
                                while x < width {
                                    let index = y * width + x
                                    let u = (Double(x) - cx) / f
                                    x += 1

                                    // Up: the projected gravity (gx − gz·u, gy − gz·v), normalized.
                                    let px = gx - gz * u, py = gy - gz * v
                                    let rawLength = (px * px + py * py).squareRoot()
                                    let length = rawLength > 1e-12 ? rawLength : 1e-12
                                    let nx = px / length, ny = py / length
                                    let rx = upX[index] - nx, ry = upY[index] - ny
                                    // Huber at scale 0.01: the squared residual itself up to the scale, linear beyond it.
                                    let upScaled = (rx * rx + ry * ry) / scale2
                                    let upRoot = (upScaled + 1e-8).squareRoot()
                                    let upLoss = upScaled <= 1 ? upScaled * scale2 : (2 * upRoot - 1) * scale2
                                    let upLossWeight = upScaled <= 1 ? 1 : (1 / upRoot > minimumWeight ? 1 / upRoot : minimumWeight)
                                    upCost += upLoss * upConfidence[index]

                                    // Latitude: sin is the unit ray's dot product with gravity.
                                    let rayLength = (u * u + v * v + 1).squareRoot()
                                    let ru = u / rayLength, rv = v / rayLength, rw = 1 / rayLength
                                    let dot = ru * gx + rv * gy + rw * gz
                                    let predicted = dot < -1 + 1e-6 ? -1 + 1e-6 : (dot > 1 - 1e-6 ? 1 - 1e-6 : dot)
                                    let lr = sinLatitude[index] - predicted
                                    let latScaled = lr * lr / scale2
                                    let latRoot = (latScaled + 1e-8).squareRoot()
                                    let latLoss = latScaled <= 1 ? latScaled * scale2 : (2 * latRoot - 1) * scale2
                                    let latLossWeight = latScaled <= 1 ? 1 : (1 / latRoot > minimumWeight ? 1 / latRoot : minimumWeight)
                                    latitudeCost += latLoss * latitudeConfidence[index]

                                    guard wantsJacobian else { continue }

                                    // d(p)/d(gravity) = [[1, 0, −u], [0, 1, −v]]; d(p)/d(focal) = gz·(u, v)·focalScale.
                                    // d(unit up)/d(p) = (I − n nᵀ) / |p|.
                                    let dp0x = a0 - a2 * u, dp0y = a1 - a2 * v
                                    let dp1x = b0 - b2 * u, dp1y = b1 - b2 * v
                                    let dp2x = gz * u * focalScale, dp2y = gz * v * focalScale
                                    let d0 = nx * dp0x + ny * dp0y, d1 = nx * dp1x + ny * dp1y, d2 = nx * dp2x + ny * dp2y
                                    let j0x = (dp0x - nx * d0) / length, j0y = (dp0y - ny * d0) / length
                                    let j1x = (dp1x - nx * d1) / length, j1y = (dp1y - ny * d1) / length
                                    let j2x = (dp2x - nx * d2) / length, j2y = (dp2y - ny * d2) / length

                                    // d(unit ray)/d(focal parameter): the ray (u, v, 1) moves by (−u, −v, 0)·focalScale.
                                    let du = -u * focalScale, dv = -v * focalScale
                                    let along = ru * du + rv * dv
                                    let dru = (du - ru * along) / rayLength
                                    let drv = (dv - rv * along) / rayLength
                                    let drw = (-rw * along) / rayLength
                                    let l0 = ru * a0 + rv * a1 + rw * a2
                                    let l1 = ru * b0 + rv * b1 + rw * b2
                                    let l2 = dru * gx + drv * gy + drw * gz

                                    let wu = upLossWeight * upConfidence[index]
                                    let wl = latLossWeight * latitudeConfidence[index]
                                    g0 += wu * (j0x * rx + j0y * ry) + wl * l0 * lr
                                    g1 += wu * (j1x * rx + j1y * ry) + wl * l1 * lr
                                    g2 += wu * (j2x * rx + j2y * ry) + wl * l2 * lr
                                    h00 += wu * (j0x * j0x + j0y * j0y) + wl * l0 * l0
                                    h01 += wu * (j0x * j1x + j0y * j1y) + wl * l0 * l1
                                    h02 += wu * (j0x * j2x + j0y * j2y) + wl * l0 * l2
                                    h11 += wu * (j1x * j1x + j1y * j1y) + wl * l1 * l1
                                    h12 += wu * (j1x * j2x + j1y * j2y) + wl * l1 * l2
                                    h22 += wu * (j2x * j2x + j2y * j2y) + wl * l2 * l2
                                }
                                y += 1
                            }
                        }
                    }
                }
            }
        }
        var result = NormalEquations()
        result.cost = (upCost + latitudeCost) / Double(pixels)
        result.gradient = SIMD3(g0, g1, g2)
        result.hessian = [[h00, h01, h02], [h01, h11, h12], [h02, h12, h22]]
        return result
    }

    // MARK: - Gravity on the sphere

    /// The Householder vector and beta that take `x` to a multiple of the last axis (GeoCalib's
    /// `SphericalManifold.householder_vector`, pivoting on the last element).
    private static func householder(_ x: SIMD3<Double>) -> (v: SIMD3<Double>, beta: Double) {
        var sigma = x.x * x.x + x.y * x.y
        if sigma < 1e-7 {
            sigma += 1e-7
        }
        let norm = (x * x).sum().squareRoot()
        let pivot = x.z < 0 ? x.z - norm : -sigma / (x.z + norm)
        let beta = 2 * pivot * pivot / (sigma + pivot * pivot)
        return (SIMD3(x.x / pivot, x.y / pivot, 1), beta)
    }

    /// The first two columns of I − β v vᵀ: how gravity moves with a tangent step.
    private static func tangentBasis(_ g: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let (v, beta) = householder(g)
        let column0 = SIMD3(1, 0, 0) - v * (beta * v.x)
        let column1 = SIMD3(0, 1, 0) - v * (beta * v.y)
        return (column0, column1)
    }

    /// Gravity after a tangent step `delta` (GeoCalib's `SphericalManifold.plus`), normalized.
    private static func plus(_ g: SIMD3<Double>, delta: SIMD2<Double>) -> SIMD3<Double> {
        let length = (delta * delta).sum().squareRoot()
        let sinc = length < 1e-7 ? 1 : sin(length) / length
        let exponential = SIMD3(sinc * delta.x, sinc * delta.y, cos(length))
        let (v, beta) = householder(g)
        let moved = exponential - v * (beta * (v * exponential).sum())
        let scaled = moved * (g * g).sum().squareRoot()
        return scaled / (scaled * scaled).sum().squareRoot()
    }

    /// Gravity is (−sin r·cos p, −cos r·cos p, sin p); its derivatives by roll and by pitch.
    private static func rollPitchBasis(_ g: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let angles = rollPitch(g)
        let sr = sin(angles.roll), cr = cos(angles.roll)
        let sp = sin(angles.pitch), cp = cos(angles.pitch)
        return (SIMD3(-cr * cp, sr * cp, 0), SIMD3(sr * sp, cr * sp, cp))
    }

    /// GeoCalib's `Gravity.roll` and `Gravity.pitch`.
    private static func rollPitch(_ g: SIMD3<Double>) -> (roll: Double, pitch: Double) {
        let eps = 1e-4
        var roll = asin(-g.x / ((1 - g.z * g.z).squareRoot() + eps))
        if g.y >= 0 {
            roll = -roll - .pi * (g.x > 0 ? 1 : g.x < 0 ? -1 : 0)
        }
        return (roll, asin(g.z))
    }

    // MARK: - Small linear algebra

    private static func focal(fieldOfView: Double, size: Double) -> Double {
        size / 2 / tan(fieldOfView / 2)
    }

    /// Solves (H + diag(max(λ·diag H, 1e-6))) δ = g by Cholesky; zero when H is not positive
    /// definite, as GeoCalib stops moving then.
    private static func dampedStep(gradient: SIMD3<Double>, hessian: [[Double]], damping: Double) -> SIMD3<Double> {
        var a = hessian
        for i in 0 ..< 3 {
            a[i][i] += max(hessian[i][i] * damping, 1e-6)
        }
        var l = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0 ..< 3 {
            for j in 0 ... i {
                var sum = a[i][j]
                for k in 0 ..< j {
                    sum -= l[i][k] * l[j][k]
                }
                if i == j {
                    guard sum > 0 else { return .zero }
                    l[i][i] = sum.squareRoot()
                } else {
                    l[i][j] = sum / l[j][j]
                }
            }
        }
        var z = SIMD3<Double>()
        for i in 0 ..< 3 {
            var sum = gradient[i]
            for k in 0 ..< i {
                sum -= l[i][k] * z[k]
            }
            z[i] = sum / l[i][i]
        }
        var x = SIMD3<Double>()
        for i in stride(from: 2, through: 0, by: -1) {
            var sum = z[i]
            for k in (i + 1) ..< 3 {
                sum -= l[k][i] * x[k]
            }
            x[i] = sum / l[i][i]
        }
        return x
    }

    private static func inverse(_ m: [[Double]]) -> [[Double]]? {
        let a = m[0][0], b = m[0][1], c = m[0][2]
        let d = m[1][0], e = m[1][1], f = m[1][2]
        let g = m[2][0], h = m[2][1], i = m[2][2]
        let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(determinant) > 0, determinant.isFinite else { return nil }
        return [
            [(e * i - f * h) / determinant, (c * h - b * i) / determinant, (b * f - c * e) / determinant],
            [(f * g - d * i) / determinant, (a * i - c * g) / determinant, (c * d - a * f) / determinant],
            [(d * h - e * g) / determinant, (b * g - a * h) / determinant, (a * e - b * d) / determinant],
        ]
    }
}
