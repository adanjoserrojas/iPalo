import ARKit
import simd
import Accelerate

public struct LocalPlane {
    public let pos: SIMD3<Float>
    public let normal: SIMD3<Float> // unit
}

final class PlaneEstimator {
    
    // Smoothing state
    private var previousNormal: SIMD3<Float>?
    private var previousPosition: SIMD3<Float>?
    private var normalHistory: [SIMD3<Float>] = []
    private var positionHistory: [SIMD3<Float>] = []
    private let historySize = 5
    
    // Exponential smoothing factors (0-1, higher = more smoothing)
    private let normalSmoothingFactor: Float = 0.85
    private let positionSmoothingFactor: Float = 0.7

    func getPlane(session: ARSession, frame: ARFrame) -> LocalPlane? {
        guard let sd = frame.sceneDepth else { return nil }
        let depthPB = sd.depthMap
        
        // Camera origin & forward in CAMERA space
        // In ARKit camera space: +Z points TOWARD viewer (out of screen), -Z away from viewer
        let camO = SIMD3<Float>(0, 0, 0)
        let camF = SIMD3<Float>(0, 0, -1)  // Forward is negative Z (into scene)
        
        // Lock depth
        CVPixelBufferLockBaseAddress(depthPB, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthPB, .readOnly) }
        let w = CVPixelBufferGetWidth(depthPB)
        let h = CVPixelBufferGetHeight(depthPB)
        guard let db = CVPixelBufferGetBaseAddress(depthPB)?.assumingMemoryBound(to: Float.self) else {
            return nil
        }
        let depthStride = CVPixelBufferGetBytesPerRow(depthPB) / MemoryLayout<Float>.size
        
        // Camera intrinsics (for capturedImage) -> scale to depth-map size
        let K = frame.camera.intrinsics
        let fx = K[0,0], fy = K[1,1]
        let cx = K[2,0], cy = K[2,1]
        
        let iw = CVPixelBufferGetWidth(frame.capturedImage)
        let ih = CVPixelBufferGetHeight(frame.capturedImage)
        let sx = Float(w) / Float(iw)
        let sy = Float(h) / Float(ih)
        let fx_d = fx * sx, fy_d = fy * sy, cx_d = cx * sx, cy_d = cy * sy
        
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(256)
        
        // Centered circular sampling
        let midx = w / 2
        let midy = h / 2
        let r = max(3, min(w, h) / 16)
        let r2 = r * r
        let step = max(1, r / 6)
        
        for vy in stride(from: max(0, midy - r), to: min(h, midy + r), by: step) {
            let dy = vy - midy
            for vx in stride(from: max(0, midx - r), to: min(w, midx + r), by: step) {
                let dx = vx - midx
                if dx*dx + dy*dy > r2 { continue }
                
                let z = db[vy * depthStride + vx]
                if !z.isFinite || z <= 0 { continue }
                
                // Back-project to camera space
                let xf = (Float(vx) - cx_d) / fx_d * z
                let yf = (Float(vy) - cy_d) / fy_d * z
                
                pts.append(SIMD3<Float>(xf, yf, z))
            }
        }
        
        guard pts.count >= 10 else { return nil }
        
        // Fit plane with reference normal for consistency
        if let plane = fitPlaneRANSAC(points: pts, iters: 100, threshold: 0.05, referenceNormal: previousNormal) {
            // Smooth the results
            let smoothedNormal = smoothNormal(plane.normal)
            let smoothedPos = smoothPosition(plane.point)
            
            return LocalPlane(pos: smoothedPos, normal: smoothedNormal)
        }

        return nil
    }
    
    // Reset smoothing (call when tracking is lost or restarted)
    func resetSmoothing() {
        previousNormal = nil
        previousPosition = nil
        normalHistory.removeAll()
        positionHistory.removeAll()
    }

    // --- Smoothing Functions ---
    
    private func smoothNormal(_ rawNormal: SIMD3<Float>) -> SIMD3<Float> {
        // Add to history
        normalHistory.append(rawNormal)
        if normalHistory.count > historySize {
            normalHistory.removeFirst()
        }
        
        // Weighted moving average with exponential decay
        var smoothed = rawNormal
        if let prev = previousNormal {
            smoothed = simd_normalize(prev * normalSmoothingFactor + rawNormal * (1.0 - normalSmoothingFactor))
        }
        
        previousNormal = smoothed
        return smoothed
    }
    
    private func smoothPosition(_ rawPos: SIMD3<Float>) -> SIMD3<Float> {
        // Add to history
        positionHistory.append(rawPos)
        if positionHistory.count > historySize {
            positionHistory.removeFirst()
        }
        
        // Exponential smoothing
        var smoothed = rawPos
        if let prev = previousPosition {
            smoothed = prev * positionSmoothingFactor + rawPos * (1.0 - positionSmoothingFactor)
        }
        
        previousPosition = smoothed
        return smoothed
    }

    // --- Improved RANSAC with Normal Consistency ---
    
    private func fitPlaneRANSAC(points: [SIMD3<Float>], iters: Int = 100, threshold: Float = 0.05, referenceNormal: SIMD3<Float>?) -> (normal: SIMD3<Float>, point: SIMD3<Float>)? {
        guard points.count >= 3 else { return nil }
        
        var bestInlierCount = 0
        var bestInliers: [SIMD3<Float>] = []
        
        for _ in 0..<iters {
            // Randomly sample 3 distinct points
            guard let sample = sampleDistinct(from: points, count: 3) else { continue }
            
            let p1 = sample[0], p2 = sample[1], p3 = sample[2]
            let v1 = p2 - p1
            let v2 = p3 - p1
            
            // Check for degenerate triangle (collinear points)
            let cross = simd_cross(v1, v2)
            let crossLen = simd_length(cross)
            if crossLen < 1e-6 { continue }
            
            var n = cross / crossLen  // Normalized
            
            // Make sure normal consistency with reference
            if let ref = referenceNormal {
                if simd_dot(n, ref) < 0 {
                    n = -n  // Flip to match previous orientation
                }
            }
            
            // Count inliers
            var inliers: [SIMD3<Float>] = []
            for p in points {
                let dist = abs(simd_dot(n, p - p1))
                if dist < threshold {
                    inliers.append(p)
                }
            }
            
            if inliers.count > bestInlierCount {
                bestInlierCount = inliers.count
                bestInliers = inliers
            }
        }
        
        // Require at least 30% inliers
        guard bestInlierCount >= max(3, points.count / 3) else { return nil }
        
        // Refine plane using ALL inliers with SVD
        return refinePlane(points: bestInliers, referenceNormal: referenceNormal)
    }
    
    // Fit plane to points using SVD (least-squares optimal)
    private func refinePlane(points: [SIMD3<Float>], referenceNormal: SIMD3<Float>?) -> (normal: SIMD3<Float>, point: SIMD3<Float>)? {
        guard points.count >= 3 else { return nil }
        
        // Compute centroid
        var centroid = SIMD3<Float>(0, 0, 0)
        for p in points {
            centroid += p
        }
        centroid /= Float(points.count)
        
        // Build covariance matrix (3x3)
        var cov = matrix_float3x3()
        for p in points {
            let d = p - centroid
            cov[0][0] += d.x * d.x
            cov[0][1] += d.x * d.y
            cov[0][2] += d.x * d.z
            cov[1][0] += d.y * d.x
            cov[1][1] += d.y * d.y
            cov[1][2] += d.y * d.z
            cov[2][0] += d.z * d.x
            cov[2][1] += d.z * d.y
            cov[2][2] += d.z * d.z
        }
        
        // Extract columns
        let col0 = SIMD3<Float>(cov[0][0], cov[1][0], cov[2][0])
        let col1 = SIMD3<Float>(cov[0][1], cov[1][1], cov[2][1])
        let col2 = SIMD3<Float>(cov[0][2], cov[1][2], cov[2][2])
        
        // Find two most significant directions (largest variance)
        let v0_len = simd_length(col0)
        let v1_len = simd_length(col1)
        let v2_len = simd_length(col2)
        
        var dir1: SIMD3<Float>
        var dir2: SIMD3<Float>
        
        if v0_len >= v1_len && v0_len >= v2_len {
            dir1 = col0
            dir2 = v1_len >= v2_len ? col1 : col2
        } else if v1_len >= v2_len {
            dir1 = col1
            dir2 = v0_len >= v2_len ? col0 : col2
        } else {
            dir1 = col2
            dir2 = v0_len >= v1_len ? col0 : col1
        }
        
        // Normal is perpendicular to the two main directions
        var normal = simd_normalize(simd_cross(dir1, dir2))
        
        // Ensure normal consistency with reference
        if let ref = referenceNormal {
            if simd_dot(normal, ref) < 0 {
                normal = -normal  // Flip to match previous orientation
            }
        }
        
        // Ensure normal is valid
        if !normal.x.isFinite || !normal.y.isFinite || !normal.z.isFinite {
            return nil
        }
        
        // Ensure normal points toward camera (positive Z in camera space)
        // The camera is at origin looking down -Z, so normals should have positive Z component
        if normal.z < 0 {
            normal = -normal
        }
        
        return (normal: normal, point: centroid)
    }
    
    // Sample N distinct elements from array
    private func sampleDistinct(from array: [SIMD3<Float>], count: Int) -> [SIMD3<Float>]? {
        guard array.count >= count else { return nil }
        
        var indices = Set<Int>()
        var attempts = 0
        while indices.count < count && attempts < count * 10 {
            indices.insert(Int.random(in: 0..<array.count))
            attempts += 1
        }
        
        guard indices.count == count else { return nil }
        return indices.map { array[$0] }
    }
}
