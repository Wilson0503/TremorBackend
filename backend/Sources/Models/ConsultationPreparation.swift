import Fluent
import Vapor
import Foundation

final class ConsultationPreparation: Model, Content, @unchecked Sendable {
    static let schema = "consultation_preparations"

    @ID(custom: .id)
    var id: Int?

    @Field(key: "user_id")
    var userID: Int

    @Field(key: "content")
    var content: String

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: Int? = nil, userID: Int, content: String) {
        self.id = id
        self.userID = userID
        self.content = content
    }
}
