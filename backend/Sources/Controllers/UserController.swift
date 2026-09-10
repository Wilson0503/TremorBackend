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
        protected.get("bonds", "patient", use: getPatient)
        protected.put("bonds", "permissions", use: updateBondPermissions) // 🔥 新增更新權限端點
        protected.on(.PUT, "profile", body: .collect(maxSize: "10mb"), use: updateProfile)
        protected.delete("bonds", "unlink", use: unlinkBond)
    }
    
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
        
        guard let user = try await User.find(payload.userID, on: req.db), user.role == 0 else {
            throw Abort(.forbidden, reason: "只有被照護者可以查詢照護者列表")
        }
        
        let bonds = try await UserBond.query(on: req.db)
            .filter(\.$patientID == payload.userID)
            .all()
        
        var caregiversList: [CaregiverListResponseDTO] = []
        
        for bond in bonds {
            if let caregiver = try await User.find(bond.caregiverID, on: req.db) {
                caregiversList.append(CaregiverListResponseDTO(
                    bondID: bond.id!,
                    caregiverID: caregiver.id!,
                    partnerName: caregiver.name ?? "未具名家屬",
                    partnerEmail: caregiver.email,
                    canManageMedPlan: bond.canManageMedPlan, // 🔥 回傳權限
                    canAddMedRecord: bond.canAddMedRecord    // 🔥 回傳權限
                ))
            }
        }
        
        return caregiversList
    }
    
    // MARK: - API: 取得照護者綁定的患者資訊 (適用身分：照護者端)
    @Sendable
    func getPatient(req: Request) async throws -> SinglePatientResponseDTO {
        let payload = try req.auth.require(UserPayload.self)
        
        guard let user = try await User.find(payload.userID, on: req.db), user.role == 1 else {
            throw Abort(.forbidden, reason: "只有照護者可以查詢病患資訊")
        }
        
        guard let bond = try await UserBond.query(on: req.db)
            .filter(\.$caregiverID == payload.userID)
            .first() else {
            throw Abort(.notFound, reason: "尚未綁定任何病患")
        }
        
        guard let patient = try await User.find(bond.patientID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到該病患資訊")
        }
        
        return SinglePatientResponseDTO(
            partnerName: patient.name ?? "未具名病患",
            partnerEmail: patient.email,
            canManageMedPlan: bond.canManageMedPlan, // 🔥 回傳自身擁有的權限
            canAddMedRecord: bond.canAddMedRecord    // 🔥 回傳自身擁有的權限
        )
    }
    
    // MARK: - 🌟 API: 更新照護者權限 (PUT /users/bonds/permissions)
    @Sendable
    func updateBondPermissions(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        
        // 🛡️ 只有病患 (role == 0) 能配置授權
        guard let currentUser = try await User.find(payload.userID, on: req.db), currentUser.role == 0 else {
            throw Abort(.forbidden, reason: "只有被照護者有權限修改照護者授權")
        }
        
        let updateData = try req.content.decode(UpdateBondPermissionsRequestDTO.self)
        
        guard let bond = try await UserBond.query(on: req.db)
            .filter(\.$patientID == payload.userID)
            .filter(\.$caregiverID == updateData.caregiverID)
            .first() else {
            throw Abort(.notFound, reason: "找不到與該照護者的綁定紀錄")
        }
        
        if let canManage = updateData.canManageMedPlan {
            bond.canManageMedPlan = canManage
        }
        if let canAdd = updateData.canAddMedRecord {
            bond.canAddMedRecord = canAdd
        }
        
        try await bond.update(on: req.db)
        return .ok
    }    // MARK: - 🌟 更新個人基本資料與密碼 (方案 1: 舊密碼驗證 + Session 連鎖防禦)
    @Sendable
    func updateProfile(req: Request) async throws -> UserResponse {
        let payload = try req.auth.require(UserPayload.self)
        guard let user = try await User.find(payload.userID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到該使用者帳號")
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try req.content.decode(UpdateProfileRequestDTO.self, using: decoder)
        
        // 1. 一般個人資訊更新
        if let name = data.name { user.name = name }
        if let birth = data.birth { user.birth = birth }
        if let gender = data.gender { user.gender = gender }
        if let stage = data.diseaseStage { user.diseaseStage = stage }
        if let avatar = data.avatarData {user.avatarData = avatar }
        
        // 2. 密碼變更安全驗證
        if let newPassword = data.newPassword, !newPassword.isEmpty {
            guard let oldPassword = data.oldPassword, !oldPassword.isEmpty else {
                throw Abort(.badRequest, reason: "變更密碼時必須提供目前的舊密碼")
            }
            
            // 🛡️ 校驗 1：舊密碼 Hash 比對
            let isOldPasswordValid = try await req.password.async.verify(oldPassword, created: user.passwordHash)
            guard isOldPasswordValid else {
                throw Abort(.unauthorized, reason: "目前舊密碼輸入錯誤")
            }
            
            // 🛡️ 校驗 2：新舊密碼不得相同
            if oldPassword == newPassword {
                throw Abort(.badRequest, reason: "新密碼不能與舊密碼相同")
            }
            
            // 寫入新密碼 Hash
            user.passwordHash = try await req.password.async.hash(newPassword)
            
            // 🔥 連鎖防禦：更新 Session ID，使所有舊裝置上的舊 Token 即刻失效
            user.activeSessionID = UUID().uuidString
        }
        
        try await user.update(on: req.db)
        return user.toResponse()
    }
    // MARK: - 🌟 解除照護者與被照護者連結 (支援單一照護者精準解綁)
    @Sendable
    func unlinkBond(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        guard let currentUser = try await User.find(payload.userID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到該使用者帳號")
        }
        
        // 1. 若發起者是照護者 (role == 1)：直接解除自己綁定的單一病患
        if currentUser.role == 1 {
            guard let bond = try await UserBond.query(on: req.db)
                .filter(\.$caregiverID == payload.userID)
                .first() else {
                throw Abort(.notFound, reason: "目前尚未綁定任何病患")
            }
            try await bond.delete(on: req.db)
            return .noContent
        }
        
        // 2. 若發起者是病患 (role == 0)：解析欲解除的目標照護者 (相容 Body 或 Query)
        let bodyData = try? req.content.decode(UnlinkBondRequestDTO.self)
        let targetEmail = bodyData?.caregiverEmail ?? req.query[String.self, at: "caregiverEmail"]
        let targetCaregiverID = bodyData?.caregiverID ?? req.query[Int.self, at: "caregiverID"]
        
        let bondQuery = UserBond.query(on: req.db).filter(\.$patientID == payload.userID)
        
        if let caregiverID = targetCaregiverID {
            bondQuery.filter(\.$caregiverID == caregiverID)
        } else if let email = targetEmail {
            guard let targetCaregiver = try await User.query(on: req.db)
                .filter(\.$email == email)
                .first() else {
                throw Abort(.notFound, reason: "找不到該照護者帳號")
            }
            bondQuery.filter(\.$caregiverID == targetCaregiver.id!)
        } else {
            throw Abort(.badRequest, reason: "病患端解除綁定時，請指定要解除的照護者 Email 或 ID")
        }
        
        guard let bond = try await bondQuery.first() else {
            throw Abort(.notFound, reason: "找不到與該照護者的綁定紀錄")
        }
        
        try await bond.delete(on: req.db)
        return .noContent
    }
}
