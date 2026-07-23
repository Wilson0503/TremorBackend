import Vapor
import Foundation

// 1. 上傳資料時使用的 Request DTO
struct TremorUploadRequest: Content {
    let accX: Double
    let accY: Double
    let accZ: Double
    let gyroX: Double
    let gyroY: Double
    let gyroZ: Double
    // 如果硬體端算好了，記得加上這兩個
    let tremorFrequency: Double?
    let amplitude: Double?
}

// 2. 回傳週報/分析時使用的 Response DTO
struct TrendPoint: Content {
    let date: Date
    let averageFrequency: Double
    let averageAmplitude: Double
}
