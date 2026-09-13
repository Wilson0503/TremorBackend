import Fluent
import Vapor
import JWT

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let users = routes.grouped("users")
        users.post("register", use: register)
        users.post("login", use: login)
        // 🔥 忘記密碼相關公開端點
        users.post("forgot-password", use: sendResetCode)
        users.post("verify-reset-code", use: verifyResetCode)
        users.post("reset-password", use: resetPasswordWithCode)
        
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
    // MARK: - 1. 發送重設密碼驗證碼 (POST /users/forgot-password)
    @Sendable
    func sendResetCode(req: Request) async throws -> HTTPStatus {
        let data = try req.content.decode(ForgotPasswordRequestDTO.self)
        let trimmedEmail = data.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        guard let user = try await User.query(on: req.db)
            .filter(\.$email == trimmedEmail)
            .first() else {
            throw Abort(.notFound, reason: "找不到該電子信箱對應的帳號")
        }
        
        // 產生 6 位數驗證碼 (時效 10 分鐘)
        let code = String(Int.random(in: 100000...999999))
        user.resetCode = code
        user.resetCodeExpiresAt = Date().addingTimeInterval(600)
        try await user.update(on: req.db)
        
        // 發送驗證信 (透過 Resend API)
        try await sendResendResetEmail(req: req, targetEmail: trimmedEmail, userName: user.name ?? "用戶", code: code)
        
        return .ok
    }
    
    // MARK: - 2. 校驗驗證碼是否正確與過期 (POST /users/verify-reset-code)
    @Sendable
    func verifyResetCode(req: Request) async throws -> HTTPStatus {
        let data = try req.content.decode(VerifyResetCodeRequestDTO.self)
        let trimmedEmail = data.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedCode = data.code.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let user = try await User.query(on: req.db)
            .filter(\.$email == trimmedEmail)
            .first() else {
            throw Abort(.notFound, reason: "找不到該電子信箱對應的帳號")
        }
        
        guard let dbCode = user.resetCode, dbCode == trimmedCode else {
            throw Abort(.unauthorized, reason: "驗證碼錯誤，請重新確認")
        }
        
        guard let expiry = user.resetCodeExpiresAt, expiry > Date() else {
            throw Abort(.badRequest, reason: "驗證碼已過期，請重新發送")
        }
        
        return .ok
    }
    
    // MARK: - 3. 輸入驗證碼與新密碼完成重設 (POST /users/reset-password)
    @Sendable
    func resetPasswordWithCode(req: Request) async throws -> HTTPStatus {
        let data = try req.content.decode(ResetPasswordWithCodeRequestDTO.self)
        let trimmedEmail = data.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedCode = data.code.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let user = try await User.query(on: req.db)
            .filter(\.$email == trimmedEmail)
            .first() else {
            throw Abort(.notFound, reason: "找不到該電子信箱對應的帳號")
        }
        
        // 再次防呆驗證驗證碼與時效
        guard let dbCode = user.resetCode, dbCode == trimmedCode else {
            throw Abort(.unauthorized, reason: "驗證碼錯誤")
        }
        
        guard let expiry = user.resetCodeExpiresAt, expiry > Date() else {
            throw Abort(.badRequest, reason: "驗證碼已過期，請重新申請")
        }
        
        // 密碼強度檢核 (至少 8 碼，包含大寫、小寫字母與數字)
        let passwordRegex = "^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d).{8,}$"
        guard data.newPassword.range(of: passwordRegex, options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "新密碼需至少 8 碼，且必須同時包含大寫英文字母、小寫英文字母與數字")
        }
        
        // 更新雜湊密碼、清空驗證碼，並連鎖撤銷舊 Session
        user.passwordHash = try await req.password.async.hash(data.newPassword)
        user.resetCode = nil
        user.resetCodeExpiresAt = nil
        user.activeSessionID = UUID().uuidString
        try await user.update(on: req.db)
        
        return .ok
    }
    
    // MARK: - 輔助函式：呼叫 Resend REST API 發送驗證信
    private func sendResendResetEmail(req: Request, targetEmail: String, userName: String, code: String) async throws {
        guard let apiKey = Environment.get("RESEND_API_KEY"), !apiKey.isEmpty else {
            req.logger.error("未配置 RESEND_API_KEY，略過信件發送，驗證碼為：\(code)")
            return
        }
        
        // 關鍵：若在未自訂網域的沙盒模式下，一律轉發至管理員 Email
        let destinationEmail = Environment.get("ADMIN_NOTIFICATION_EMAIL") ?? targetEmail
        
        let htmlBody = """
            <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 500px; margin: auto; padding: 24px; border: 1px solid #eaeaea; border-radius: 12px;">
                <h2 style="color: #2b5c8f;">SteadyHope 智慧醫療照護</h2>
                <p>您好 <strong>\(userName)</strong>：</p>
                <p>我們收到了您重設密碼的請求。請在 App 中輸入以下 6 位數安全驗證碼：</p>
                <div style="background-color: #f4f6f9; padding: 16px; border-radius: 8px; text-align: center; margin: 24px 0;">
                    <span style="font-size: 32px; font-weight: bold; letter-spacing: 6px; color: #1e3a8a;">\(code)</span>
                </div>
                <p style="color: #64748b; font-size: 13px;">• 該驗證碼將於 <strong>10 分鐘</strong> 後過期。<br>• 原請求帳號：\(targetEmail)<br>• 若非您本人發起此操作，請忽略本信件以確保帳戶安全。</p>
            </div>
            """
        
        let resendPayload = ResendEmailRequestDTO(
            from: "SteadyHope 系統通知 <onboarding@resend.dev>",
            to: [destinationEmail],
            subject: "【SteadyHope】密碼重設驗證碼 (\(targetEmail))",
            html: htmlBody
        )
        
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        headers.add(name: "Content-Type", value: "application/json")
        
        let response = try await req.client.post("https://api.resend.com/emails", headers: headers) { clientReq in
            try clientReq.content.encode(resendPayload, as: .json)
        }
        
        guard response.status == .ok else {
            let errorText = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0) ?? "未知錯誤"
            req.logger.error("Resend API 寄件失敗：\(errorText)")
            throw Abort(.badGateway, reason: "驗證信件發送失敗，請稍後再試")
        }
    }
}
