import Vapor
import Foundation

// MARK: - 1. 新增生理數據請求 DTO
struct CreateHealthVitalsRequestDTO: Content {
    let date: Date
    let systolicBP: String?
    let diastolicBP: String?
    let bloodSugar: String?
    let bodyTemp: String?
    let bodyWeight: String?
    let sleepHours: String?
    let foodAmount: String?
}

// MARK: - 2. 編輯生理數據請求 DTO
struct UpdateHealthVitalsRequestDTO: Content {
    let date: Date?
    let systolicBP: String?
    let diastolicBP: String?
    let bloodSugar: String?
    let bodyTemp: String?
    let bodyWeight: String?
    let sleepHours: String?
    let foodAmount: String?
}

// MARK: - 3. 生理數據回傳響應 DTO (對齊 App 端)
struct HealthVitalsResponseDTO: Content {
    let id: Int?
    let userID: Int
    let date: Date
    let systolicBP: String?
    let diastolicBP: String?
    let bloodSugar: String?
    let bodyTemp: String?
    let bodyWeight: String?
    let sleepHours: String?
    let foodAmount: String?
    let createdAt: Date?
}
