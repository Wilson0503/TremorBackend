import Fluent
import Vapor

func routes(_ app: Application) throws {
    // 註冊 Controller
    try app.register(collection: UserController())
    
    // 🔥 修改：加上 SingleDeviceMiddleware() 進行三層防護
    let protected = app.grouped(
        UserPayload.authenticator(),
        UserPayload.guardMiddleware(),
        SingleDeviceMiddleware()
    )
    
    // 以下保持不變
    try protected.register(collection: TremorController())
    try protected.register(collection: MedicationController())
    try protected.register(collection: DailyController())
    try protected.register(collection: AIController())
    try protected.register(collection: SymptomController())
    try protected.register(collection: MedicationPlanController())
    try protected.register(collection: HealthVitalsController())
    try protected.register(collection: DailyAssessmentController())
}
