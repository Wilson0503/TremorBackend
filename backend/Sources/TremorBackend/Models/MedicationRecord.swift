import Fluent
import Vapor

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

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: Int? = nil, userID: Int, date: Date, name: String, dose: String) {
        self.id = id
        self.userID = userID
        self.date = date
        self.name = name
        self.dose = dose
    }
}
