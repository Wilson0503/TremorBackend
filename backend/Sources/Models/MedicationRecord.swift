import Fluent
import Vapor
import Foundation

final class MedicationRecord: Model, Content, @unchecked Sendable {
    static let schema = "medication_records"
    
    @ID(custom: .id)
    var id: Int?
    
    @Field(key: "user_id")
    var userID: Int
    
    @Field(key: "date")
    var date: Date
    
    @Field(key: "name")
    var name: String
    
    @Field(key: "dose")
    var dose: String
    
    @Field(key: "med_type")
    var medType: String
    
    @OptionalField(key: "patch_region")
    var patchRegion: String?
    
    @OptionalField(key: "skin_condition")
    var skinCondition: String?
    
    @Field(key: "skin_image_data_list")
    var skinImageDataList: [Data]
    
    @Field(key: "creator_role")
    var creatorRole: Int
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    init() { }
    
    init(
        id: Int? = nil,
        userID: Int,
        date: Date,
        name: String,
        dose: String,
        medType: String,
        patchRegion: String? = nil,
        skinCondition: String? = nil,
        skinImageDataList: [Data] = [],
        creatorRole: Int = 0 // 🔥
    ) {
        self.id = id
        self.userID = userID
        self.date = date
        self.name = name
        self.dose = dose
        self.medType = medType
        self.patchRegion = patchRegion
        self.skinCondition = skinCondition
        self.skinImageDataList = skinImageDataList
        self.creatorRole = creatorRole
    }
}
