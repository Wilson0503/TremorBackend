import Fluent
import Vapor
import Foundation

final class UserBond: Model, Content, @unchecked Sendable {
    static let schema = "user_bonds"

    @ID(custom: .id)
    var id: Int?

    @Field(key: "caregiver_id")
    var caregiverID: Int

    @Field(key: "patient_id")
    var patientID: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: Int? = nil, caregiverID: Int, patientID: Int) {
        self.id = id
        self.caregiverID = caregiverID
        self.patientID = patientID
    }
}
