import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor
import JWT

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    
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
    formatter.dateFormat = "yyyy-MM-dd" // 設定與你資料庫一致的格式
    
    encoder.dateEncodingStrategy = .formatted(formatter)
    decoder.dateDecodingStrategy = .formatted(formatter)
    
    // 告訴 Vapor 全域使用這套編解碼器
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)
    
    app.migrations.add(CreateUser())
    app.migrations.add(CreateTremorData())
    app.migrations.add(CreateMedicationRecord())
    app.migrations.add(CreateDailyRecord())
    app.migrations.add(CreateUserBond()) // 🔥 加上這行
    app.jwt.signers.use(.hs256(key: Environment.get("JWT_SECRET") ?? "fallback_temporary_key"))
    // register routes
    try routes(app)
}
