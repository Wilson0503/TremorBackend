import Fluent
import Vapor
import JWT

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let users = routes.grouped("users")
        users.post("register", use: register)
        users.post("login", use: login)
        
        // 🔥 在這裡把 SingleDeviceMiddleware() 也加進去！
        let protected = users.grouped(
            UserPayload.authenticator(),
            UserPayload.guardMiddleware(),
            SingleDeviceMiddleware() // 👈 加這行
        )
        
        protected.post("bonds", "generate-code", use: generatePairingCode)
        protected.post("bonds", "link", use: linkPatient)
        protected.get("bonds", "caregivers", use: getCaregivers)
        protected.get("bonds", "patient", use: getPatient)    }
    
    // MARK: - 註冊邏輯
    @Sendable
    func register(req: Request) async throws -> UserResponse {
        struct RegisterRequest: Content {
            let email: String
            let password: String
            let name: String?
            let birth: Date?
            let gender: Int?
            let diseaseStage: String?
            let role: Int
        }
        
        let data = try req.content.decode(RegisterRequest.self)
        
        let exists = try await User.query(on: req.db)
            .filter(\.$email == data.email)
            .first() != nil
        
        if exists {
            throw Abort(.conflict, reason: "此電子郵件已被註冊")
        }
        
        let hash = try await req.password.async.hash(data.password)
        
        let user = User(
            email: data.email,
            passwordHash: hash,
            birth: data.birth,
            name: data.name,
            gender: data.gender,
            diseaseStage: data.diseaseStage,
            role: data.role
        )
        
        try await user.save(on: req.db)
        return user.toResponse()
    }
    
    // MARK: - 登入邏輯
    @Sendable
    func login(req: Request) async throws -> Response {
        struct LoginRequest: Content {
            let email: String
            let password: String
        }
        
        let loginData = try req.content.decode(LoginRequest.self)
        guard let user = try await User.query(on: req.db)
            .filter(\.$email == loginData.email)
            .first() else {
            throw Abort(.unauthorized, reason: "帳號或密碼錯誤")
        }
        
        let isPasswordValid = try await req.password.async.verify(loginData.password, created: user.passwordHash)
        if !isPasswordValid {
            throw Abort(.unauthorized, reason: "帳號或密碼錯誤")
        }
        
        // 🔥 新增：1. 產生一組全新的隨機 Session ID
        let newSessionID = UUID().uuidString
        
        // 🔥 新增：2. 寫入資料庫，這代表之前的 Session ID 已經失效了
        user.activeSessionID = newSessionID
        try await user.update(on: req.db)
        
        // 🔥 修改：3. 將新的 Session ID 包進 JWT Payload 中
        let payload = UserPayload(
            userID: user.id!,
            sessionID: newSessionID,
            exp: .init(value: Date().addingTimeInterval(3600 * 24))
        )
        let token = try req.jwt.sign(payload)
        
        let loginResponse = LoginResponse(token: token, user: user.toResponse())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(loginResponse)
        
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }
    
    // MARK: - 🔥 實作一：產生 6 位數安全隨機配對碼
    @Sendable
    func generatePairingCode(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        
        guard let user = try await User.find(payload.userID, on: req.db) else {
            throw Abort(.notFound)
        }
        
        guard user.role == 0 else {
            throw Abort(.forbidden, reason: "只有被照護者（患者）有權限生成配對碼")
        }
        
        let randomCode = String(Int.random(in: 100000...999999))
        let expiryDate = Date().addingTimeInterval(600)
        
        user.pairingCode = randomCode
        user.pairingCodeExpiresAt = expiryDate
        try await user.update(on: req.db)
        
        let dtoList = PairingCodeResponseDTO(pairingCode: randomCode, expiresAt: expiryDate)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(dtoList)
        
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }
    
    // MARK: - 🔥 實作二：安全綁定（同步更新回傳型別為通用 DTO）
    @Sendable
    func linkPatient(req: Request) async throws -> LinkedPartnerResponseDTO {
        let caregiverPayload = try req.auth.require(UserPayload.self)
        let linkData = try req.content.decode(LinkPatientRequestDTO.self)
        
        let currentCaregiver = try await User.find(caregiverPayload.userID, on: req.db)
        guard currentCaregiver?.role == 1 else {
            throw Abort(.forbidden, reason: "只有照護者帳號才能發起綁定")
        }
        
        if currentCaregiver?.email == linkData.patientEmail {
            throw Abort(.badRequest, reason: "您不能將自己綁定為被照護者")
        }
        
        guard let patientUser = try await User.query(on: req.db)
            .filter(\.$email == linkData.patientEmail)
            .first() else {
            throw Abort(.notFound, reason: "找不到該病患帳號，請確認輸入是否有誤")
        }
        
        guard patientUser.role == 0 else {
            throw Abort(.badRequest, reason: "該帳號註冊身份為照護者，無法被綁定")
        }
        
        guard let dbCode = patientUser.pairingCode, dbCode == linkData.pairingCode else {
            throw Abort(.unauthorized, reason: "配對驗證碼錯誤，請重新確認")
        }
        
        guard let expiryDate = patientUser.pairingCodeExpiresAt, expiryDate > Date() else {
            throw Abort(.badRequest, reason: "配對碼已過期，請請病患重新生成一組")
        }
        
        let bond = UserBond(caregiverID: caregiverPayload.userID, patientID: patientUser.id!)
        
        do {
            try await bond.save(on: req.db)
        } catch {
            throw Abort(.conflict, reason: "您與該病患早已處於綁定狀態")
        }
        
        patientUser.pairingCode = nil
        patientUser.pairingCodeExpiresAt = nil
        try await patientUser.update(on: req.db)
        
        // 💡 改用通用 DTO 回傳
        return LinkedPartnerResponseDTO(
            bondID: bond.id!,
            partnerID: patientUser.id!,
            partnerName: patientUser.name ?? "未具名病患",
            partnerEmail: patientUser.email,
            partnerRole: patientUser.role
        )
    }
    
    // MARK: - API: 取得患者已綁定的照護者列表 (適用身分：病患端)
    @Sendable
    func getCaregivers(req: Request) async throws -> [CaregiverListResponseDTO] {
        let payload = try req.auth.require(UserPayload.self)
        
        // 安全檢查：確認發送請求的是病患 (role == 0)
        guard let user = try await User.find(payload.userID, on: req.db), user.role == 0 else {
            throw Abort(.forbidden, reason: "只有被照護者可以查詢照護者列表")
        }
        
        // 撈出所有指向該病患的綁定紀錄
        let bonds = try await UserBond.query(on: req.db)
            .filter(\.$patientID == payload.userID)
            .all()
        
        var caregiversList: [CaregiverListResponseDTO] = []
        
        // 查出對應的照護者詳細資料
        for bond in bonds {
            if let caregiver = try await User.find(bond.caregiverID, on: req.db) {
                caregiversList.append(CaregiverListResponseDTO(
                    partnerName: caregiver.name ?? "未具名家屬",
                    partnerEmail: caregiver.email
                ))
            }
        }
        
        // 回傳陣列格式 (完全符合前端規格)
        return caregiversList
    }
    
    // MARK: - API: 取得照護者綁定的患者資訊 (適用身分：照護者端)
    @Sendable
    func getPatient(req: Request) async throws -> SinglePatientResponseDTO {
        let payload = try req.auth.require(UserPayload.self)
        
        // 安全檢查：確認發送請求的是照護者 (role == 1)
        guard let user = try await User.find(payload.userID, on: req.db), user.role == 1 else {
            throw Abort(.forbidden, reason: "只有照護者可以查詢病患資訊")
        }
        
        // 照前端規格，目前照護者端維持單一患者，所以用 .first()
        guard let bond = try await UserBond.query(on: req.db)
            .filter(\.$caregiverID == payload.userID)
            .first() else {
            throw Abort(.notFound, reason: "尚未綁定任何病患")
        }
        
        guard let patient = try await User.find(bond.patientID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到該病患資訊")
        }
        
        // 回傳單一物件格式 (完全符合前端規格)
        return SinglePatientResponseDTO(
            partnerName: patient.name ?? "未具名病患",
            partnerEmail: patient.email
        )
    }
}
