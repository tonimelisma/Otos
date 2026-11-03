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
            let system = normalEquations(fields, state, parameters: .tangentLogFocal)
            if step == 0 {
                previousCost = system.cost
            }
            let delta = dampedStep(gradient: system.gradient, hessian: system.hessian, damping: damping)
            state = State(
                gravity: plus(state.gravity, delta: SIMD2(delta.x, delta.y)),
                focal: min(max(exp(log(state.focal) + delta.z), focalRange.minimum), focalRange.maximum)
            )
            let cost = normalEquations(fields, state, parameters: .none).cost
            damping = min(max(damping * (cost > previousCost ? 10 : 0.1), 1e-6), 1e2)
            if abs(cost - previousCost) <= tolerance + tolerance * abs(previousCost) {
                steps = step + 1
                break
            }
            previousCost = cost
        }
        let final = normalEquations(fields, state, parameters: .rollPitchFocal)
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

    /// The Huber cost of a squared residual, and its weight, at GeoCalib's scale.
    private static func huber(_ squared: Double) -> (cost: Double, weight: Double) {
        let scale2 = lossScale * lossScale
        let x = squared / scale2
        if x <= 1 {
            return (x * scale2, 1)
        }
        let root = (x + 1e-8).squareRoot()
        return ((2 * root - 1) * scale2, max(Double(Float.ulpOfOne), 1 / root))
    }

    private static func normalEquations(_ fields: Fields, _ state: State, parameters: Parameters) -> NormalEquations {
        let width = fields.width, height = fields.height, pixels = width * height
        let g = state.gravity, f = state.focal
        let cx = Double(width) / 2, cy = Double(height) / 2
        // How gravity's three components move with the two parameters that steer it.
        let gravityBasis: (SIMD3<Double>, SIMD3<Double>) = switch parameters {
        case .tangentLogFocal: tangentBasis(g)
        case .rollPitchFocal: rollPitchBasis(g)
        case .none: (.zero, .zero)
        }
        // d(normalized coordinate)/d(focal parameter) is −u for the log focal, −u/f in pixels.
        let focalScale = parameters == .rollPitchFocal ? 1 / f : 1.0
        var result = NormalEquations()
        var upCost = 0.0, latitudeCost = 0.0
        for y in 0 ..< height {
            let v = (Double(y) - cy) / f
            for x in 0 ..< width {
                let index = y * width + x
                let u = (Double(x) - cx) / f

                // Up: the projected gravity (gx − gz·u, gy − gz·v), normalized.
                let px = g.x - g.z * u, py = g.y - g.z * v
                let length = max((px * px + py * py).squareRoot(), 1e-12)
                let nx = px / length, ny = py / length
                let rx = Double(fields.up[index]) - nx
                let ry = Double(fields.up[pixels + index]) - ny
                let upLoss = huber(rx * rx + ry * ry)
                let upConfidence = Double(fields.upConfidence[index])
                upCost += upLoss.cost * upConfidence

                // Latitude: sin is the unit ray's dot product with gravity.
                let rayLength = (u * u + v * v + 1).squareRoot()
                let ray = SIMD3(u, v, 1) / rayLength
                let predicted = min(max((ray * g).sum(), -1 + 1e-6), 1 - 1e-6)
                let latitudeResidual = sin(Double(fields.latitude[index])) - predicted
                let latitudeLoss = huber(latitudeResidual * latitudeResidual)
                let latitudeConfidence = Double(fields.latitudeConfidence[index])
                latitudeCost += latitudeLoss.cost * latitudeConfidence

                guard parameters != .none else { continue }

                /// d(unit up)/d(p) = (I − n nᵀ) / |p|.
                func upJacobian(_ dp: SIMD2<Double>) -> SIMD2<Double> {
                    let dot = nx * dp.x + ny * dp.y
                    return SIMD2((dp.x - nx * dot) / length, (dp.y - ny * dot) / length)
                }
                /// d(p)/d(gravity) = [[1, 0, −u], [0, 1, −v]].
                func projected(_ dg: SIMD3<Double>) -> SIMD2<Double> {
                    SIMD2(dg.x - dg.z * u, dg.y - dg.z * v)
                }
                // d(u, v)/d(focal parameter) = −(u, v)·focalScale, so d(p) = gz·(u, v)·focalScale.
                let upColumns = [
                    upJacobian(projected(gravityBasis.0)),
                    upJacobian(projected(gravityBasis.1)),
                    upJacobian(SIMD2(g.z * u, g.z * v) * focalScale),
                ]
                // d(unit ray)/d(focal parameter): the ray (u, v, 1) moves by (−u, −v, 0)·focalScale.
                let dRay = SIMD3(-u, -v, 0) * focalScale
                let dUnitRay = (dRay - ray * (ray * dRay).sum()) / rayLength
                let latitudeColumns = SIMD3(
                    (ray * gravityBasis.0).sum(),
                    (ray * gravityBasis.1).sum(),
                    (dUnitRay * g).sum()
                )

                let upWeight = upLoss.weight * upConfidence
                let latitudeWeight = latitudeLoss.weight * latitudeConfidence
                for row in 0 ..< 3 {
                    result.gradient[row] += upWeight * (upColumns[row].x * rx + upColumns[row].y * ry)
                    result.gradient[row] += latitudeWeight * latitudeColumns[row] * latitudeResidual
                    for column in 0 ..< 3 {
                        result.hessian[row][column] += upWeight * (upColumns[row].x * upColumns[column].x
                            + upColumns[row].y * upColumns[column].y)
                        result.hessian[row][column] += latitudeWeight * latitudeColumns[row] * latitudeColumns[column]
                    }
                }
            }
        }
        result.cost = (upCost + latitudeCost) / Double(pixels)
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
