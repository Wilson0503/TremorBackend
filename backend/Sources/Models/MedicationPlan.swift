import Fluent
import Vapor
import Foundation

final class MedicationPlan: Model, Content, @unchecked Sendable {
    static let schema = "medication_plans"
    
    @ID(custom: .id)
    var id: Int?
    
    @Field(key: "user_id")
    var userID: Int
    
    @Field(key: "name")
    var name: String
    
    @Field(key: "dose")
    var dose: String
    
    @Field(key: "med_type")
    var medType: String
    
    @OptionalField(key: "default_patch_region")
    var defaultPatchRegion: String?
    
    @Field(key: "time_slots_raw")
    var timeSlotsRaw: String
    
    // 👇 新增的起始日欄位
    @Field(key: "start_date")
    var startDate: Date
    
    @Field(key: "repeat_frequency")
    var repeatFrequency: String
    
    @Field(key: "custom_interval")
    var customInterval: Int
    
    @Field(key: "custom_unit")
    var customUnit: String
    
    @Field(key: "weekdays_raw")
    var weekdaysRaw: String
    
    @Field(key: "month_days_raw")
    var monthDaysRaw: String
    
    @Field(key: "creator_role")
    var creatorRole: Int
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    init() { }
    
    init(
        id: Int? = nil,
        userID: Int,
        name: String,
        dose: String,
        medType: String,
        defaultPatchRegion: String? = nil,
        timeSlotsRaw: String = "",
        startDate: Date = Date(),
        repeatFrequency: String = "每天",
        customInterval: Int = 1,
        customUnit: String = "天",
        weekdaysRaw: String = "",
        monthDaysRaw: String = "",
        creatorRole: Int = 0 // 🔥
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.dose = dose
        self.medType = medType
        self.defaultPatchRegion = defaultPatchRegion
        self.timeSlotsRaw = timeSlotsRaw
        self.startDate = startDate
        self.repeatFrequency = repeatFrequency
        self.customInterval = customInterval
        self.customUnit = customUnit
        self.weekdaysRaw = weekdaysRaw
        self.monthDaysRaw = monthDaysRaw
        self.creatorRole = creatorRole
    }
}
