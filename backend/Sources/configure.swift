import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor
import JWT

// configures your application
public func configure(_ app: Application) async throws {
    // 🎯 強制全域使用 Vapor 原生格式輸出 INFO 級別日誌 (包含 API 請求與遷移資訊)
    app.logger.logLevel = .info
    
    app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "postgres",
        password: Environment.get("DATABASE_PASSWORD") ?? "123",
        database: Environment.get("DATABASE_NAME") ?? "tremor_glove",
        tls: .disable)
    ), as: .psql)
    
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    
    encoder.dateEncodingStrategy = .formatted(formatter)
    decoder.dateDecodingStrategy = .formatted(formatter)
    
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)
    
    app.migrations.add(CreateUser())
    app.migrations.add(CreateNewTremorTables())
    app.migrations.add(CreateMedicationRecord())
    app.migrations.add(CreateDailyRecord())
    app.migrations.add(CreateUserBond())
    app.migrations.add(CreateKnowledgeBase())
    app.migrations.add(CreateChatHistory())
    app.migrations.add(UpdateDailyRecordAddCaregiverOnly())
    app.migrations.add(CreateSymptomRecord())
    app.migrations.add(CreateMedicationPlan())
    app.migrations.add(CreateHealthVitalsRecord())
    app.migrations.add(CreateDailyAssessmentRecord())
    app.migrations.add(UpdateUserBondAddPermissions())
    app.migrations.add(UpdateMedicationAddCreatorRole())
    app.migrations.add(CreateConsultationPreparation())
    app.migrations.add(UpdateUserAddAvatar())
    app.lifecycle.use(ChatCleanupTask())
    app.jwt.signers.use(.hs256(key: Environment.get("JWT_SECRET") ?? "fallback_temporary_key"))
    
    // register routes
    try routes(app)
    
    app.logger.info("🚀 正在嘗試自動執行資料庫遷移...")
    try await app.autoMigrate()
    app.logger.info("✅ 資料庫遷移成功完成！")
}
