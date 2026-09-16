import Fluent
import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: UserController())
    
    let protected = app.grouped(
        UserPayload.authenticator(),
        UserPayload.guardMiddleware(),
        SingleDeviceMiddleware()
    )
    try protected.register(collection: TremorController())
    try protected.register(collection: MedicationController())
    try protected.register(collection: DailyController())
    try protected.register(collection: AIController())
    try protected.register(collection: SymptomController())
    try protected.register(collection: MedicationPlanController())
    try protected.register(collection: HealthVitalsController())
    try protected.register(collection: DailyAssessmentController())
}
