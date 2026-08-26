import Fluent
import Vapor
import Foundation

final class HealthVitalsRecord: Model, Content, @unchecked Sendable {
    static let schema = "health_vitals_records"

    @ID(custom: .id)
    var id: Int?

    @Field(key: "user_id")
    var userID: Int

    @Field(key: "date")
    var date: Date

    @OptionalField(key: "systolic_bp")
    var systolicBP: String?

    @OptionalField(key: "diastolic_bp")
    var diastolicBP: String?

    @OptionalField(key: "blood_sugar")
    var bloodSugar: String?

    @OptionalField(key: "body_temp")
    var bodyTemp: String?

    @OptionalField(key: "body_weight")
    var bodyWeight: String?

    @OptionalField(key: "sleep_hours")
    var sleepHours: String?

    @OptionalField(key: "food_amount")
    var foodAmount: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: Int? = nil,
        userID: Int,
        date: Date = Date(),
        systolicBP: String? = nil,
        diastolicBP: String? = nil,
        bloodSugar: String? = nil,
        bodyTemp: String? = nil,
        bodyWeight: String? = nil,
        sleepHours: String? = nil,
        foodAmount: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.date = date
        self.systolicBP = systolicBP
        self.diastolicBP = diastolicBP
        self.bloodSugar = bloodSugar
        self.bodyTemp = bodyTemp
        self.bodyWeight = bodyWeight
        self.sleepHours = sleepHours
        self.foodAmount = foodAmount
    }
}
extension HealthVitalsRecord {
    func toDTO() -> HealthVitalsResponseDTO {
        return HealthVitalsResponseDTO(
            id: self.id,
            userID: self.userID,
            date: self.date,
            systolicBP: self.systolicBP,
            diastolicBP: self.diastolicBP,
            bloodSugar: self.bloodSugar,
            bodyTemp: self.bodyTemp,
            bodyWeight: self.bodyWeight,
            sleepHours: self.sleepHours,
            foodAmount: self.foodAmount,
            createdAt: self.createdAt
        )
    }
}
