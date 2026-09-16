# SteadyHope Backend - 帕金森氏症智慧輔助系統後端核心服務

SteadyHope 後端是專為「以主動抑震為基礎之帕金森氏症智慧型輔助系統」所建構的雲端微服務。本專案基於 **Swift 6.1** 與 **Vapor 4** 框架開發，負責處理 STM32/ESP32 智慧抑震手套的高頻感測封包上傳、iOS 客戶端資料雙向同步、病患與照護者權限綁定，以及基於 **OpenAI GPT-4o-mini** 與 **PostgreSQL pgvector** 的長短期混合記憶智慧醫療對話助理（小安）。

---

## 核心技術特色

* **非同步事件驅動引擎**：以 Apple 原生 SwiftNIO 為底層核心，全面採用 Swift 6 `async/await` 與 Sendable 結構化併發模型，高效率處理高頻感測數據與大量客戶端請求。
* **AI 混合記憶架構（Hybrid Memory Architecture）**：
  * **短期工作記憶**：維護最新 4 筆時序連續滑動窗口，確保對話代名詞與脈絡理解。
  * **長期語意召回**：使用者提問即時向量化（1536 維度），透過 pgvector 餘弦距離（`<=>`）跨時間檢索歷史問題，且具備短期窗口自動去重防護。
  * **RAG 衛教知識庫檢索**：自動比對官方醫療指南、操作規範與演算法門檻條目。
  * **全自動 Agent 工具呼叫（Function Calling）**：小安具備代辦能力，可自動分派執行服藥登錄、排程建立、心情便利貼與突發症狀寫入，並能動態並行彙整近一週 7 大模組數據產生健康週報。
* **穿戴感測數據雙軌整合**：
  * **原始量測二進位包**：支援分批封裝上傳原始三軸角速度壓縮封包（每包 400 筆樣本），保留完整工作階段（Session ID）歸組查閱。
  * **特徵分析快照**：儲存 0.5 秒視窗演算法特徵（4–6 Hz 頻帶 RMS 強度、主頻、有效旗標與馬達作用比例）。
  * **防衝突更新機制**：提供專屬 `PATCH /tremor/analysis/:recordId` 端點，允許 App 補充生活情境標籤與備註時不覆寫感測數值，防止主鍵衝突。
* **照護雙軌綁定與隱私權限過濾**：
  * 支援 6 位數時效配對碼綁定，病患可自主授權照護者「管理用藥排程」與「新增用藥紀錄」權限。
  * 心情留言板支援真實發布者 ID 歸屬，病患端嚴格過濾「僅照護者可見（`is_caregiver_only`）」便利貼，並在查詢時動態反射發布者最新姓名。
* **單一裝置登入保護與連鎖防禦**：
  * 透過自訂 `SingleDeviceMiddleware` 檢查 JWT Payload 中的 `sessionID`。
  * 帳號於新裝置登入或變更密碼時，自動輪替資料庫 `active_session_id`，舊裝置 Token 即刻失效踢出。
  * 整合 Resend REST API 寄送 6 碼時效安全驗證信，實現標準忘記密碼與密碼強度檢核流程。

---

## 系統架構與技術棧

| 領域 / 元件 | 使用技術與版本 | 說明 |
| :--- | :--- | :--- |
| **開發語言 / 工具鏈** | Swift 6.1 (Docker: `swift:6.1-noble`) | `swift-tools-version: 6.0`，全面啟用型別安全檢查 |
| **後端核心框架** | Vapor 4 (v4.121.4) | 輕量、高效能的非同步 Web 伺服器框架 |
| **ORM / 資料庫驅動** | Fluent (v4.13.0) / FluentPostgresDriver (v2.12.0) | 資料庫抽象層，管理 17 項遷移步驟與連線池 |
| **關聯式資料庫** | PostgreSQL 16+ / pgvector 擴充套件 | 託管 13 張業務資料表，支援 1536 維度 HNSW 向量索引 |
| **身分驗證 / 加密** | JWT (v4.2.2) / BCrypt (SwiftCrypto 3.15.1) | HS256 Token 簽署、密碼雜湊與 Session ID 驗證 |
| **AI 模型與嵌入** | OpenAI `gpt-4o-mini` & `text-embedding-3-small` | 處理自然語言醫療助理、卡片生成與語意向量轉換 |
| **郵件傳輸服務** | Resend HTTP REST API | 寄送帳號驗證碼與密碼重設通知信 |
| **容器化與部屬** | Docker (Multi-stage) / Render Web Service | 雙階段建置優化映像檔，靜態連結 `jemalloc` 抑制定時記憶體碎片 |

---

## 環境變數配置

在專案根目錄建立 `.env`（本機開發）或於 Render Dashboard 中設定以下環境變數：

```ini
# 基礎設定
LOG_LEVEL=info

# 資料庫連線配置 (PostgreSQL 需啟用 vector 擴充)
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USERNAME=postgres
DATABASE_PASSWORD=your_password
DATABASE_NAME=tremor_glove

# JWT 簽署金鑰
JWT_SECRET=your_super_secret_jwt_key_here

# OpenAI API 配置
OPENAI_API_KEY=sk-proj-xxxxxxxxxxxxxxxxxxxxxxxx

# 郵件重設密碼服務 (Resend)
RESEND_API_KEY=re_xxxxxxxxxxxxxxxxxxxx
ADMIN_NOTIFICATION_EMAIL=admin@steadyhope.com
```

---

## 本地開發與啟動

### 方法一：使用原生 Swift 工具鏈（macOS / Linux）

1. **啟動本機 PostgreSQL 資料庫**（需支援 `pgvector`）：
   ```bash
   docker run --name tremor-postgres -e POSTGRES_PASSWORD=123 -e POSTGRES_DB=tremor_glove -p 5432:5432 -d pgvector/pgvector:pg16
   ```
2. **解析相依套件**：
   ```bash
   swift package resolve
   ```
3. **編譯並執行伺服器**：
   ```bash
   swift run TremorBackend serve --hostname 0.0.0.0 --port 8080
   ```
   > 服務啟動時會自動執行未完成之資料庫遷移（Auto Migrate），並於背景啟動對話紀錄定期清理任務（每 24 小時清除超過 6 個月之歷史對話）。

### 方法二：使用 Docker Compose 快速啟動

專案內建完整 `docker-compose.yml`，一鍵啟動資料庫與應用程式：
```bash
# 建置映像檔並啟動所有服務 (背景運行)
docker compose up -d --build

# 檢視服務日誌
docker compose logs -f app
```

---

## 資料庫架構 (13 張資料表)

後端透過 Fluent Migration 精確維護 13 張資料表：

* **帳號與權限**：`users`（帳號、雜湊密碼、頭像、驗證碼、Session ID）、`user_bonds`（病患與照護者配對關係、用藥管理授權）。
* **震顫量測模組**：`raw_tremor_data`（壓縮原始角速度封包）、`tremor_analysis_records`（0.5s 特徵快照、RMS 強度、頻率、生活情境標籤）。
* **健康與用藥管理**：`medication_plans`（長期用藥提醒排程）、`medication_records`（單次服藥登錄、部位照片、皮膚狀況）、`health_vitals_records`（日常血壓、血糖、體重、睡眠體徵）、`symptom_records`（突發肢體表徵、媒體附件）。
* **日常生活與自評**：`daily_records`（心情看板便利貼、照護者專屬隱私）、`daily_assessment_records`（25 題綜合量表、情緒/生活自理/動作分項得分）。
* **AI 助理與知識庫**：`knowledge_base`（分類衛教知識、1536 維度 HNSW 向量）、`chat_history`（使用者與 AI 對話歷史、提問向量快取）、`consultation_preparations`（回診前準備事項與筆記）。

---

## 主要 API 端點索引

所有受保護端點皆須在 Header 帶入：`Authorization: Bearer <Token>`。

### 1. 使用者與照護關係 (`/users`)
* `POST /users/register` - 註冊新帳號
* `POST /users/login` - 登入並取得 JWT Token 與新 Session ID
* `POST /users/forgot-password` - 發送 6 碼密碼重設驗證信
* `POST /users/verify-reset-code` - 驗證重設碼是否有效
* `POST /users/reset-password` - 輸入驗證碼與新密碼完成重設
* `PUT  /users/profile` - 更新個人基本資料、頭像或修改密碼（舊密碼驗證）
* `POST /users/bonds/generate-code` - （病患端）生成 6 位數時效配對碼
* `POST /users/bonds/link` - （照護者端）輸入病患 Email 與配對碼發起綁定
* `GET  /users/bonds/caregivers` - （病患端）查詢已授權之照護者清單
* `GET  /users/bonds/patient` - （照護者端）查詢綁定之病患資訊與自身權限
* `PUT  /users/bonds/permissions` - （病患端）配置指定照護者之用藥排程/登錄權限
* `DELETE /users/bonds/unlink` - 解除病患與照護者綁定

### 2. 震顫量測與分析 (`/tremor`)
* `POST /tremor/raw` - 上傳 400 點壓縮原始量測二進位資料包
* `GET  /tremor/raw` - 查詢原始量測資料歷史（支援照護者代看）
* `POST /tremor/analysis` - 上傳單筆震顫特徵分析紀錄
* `PATCH /tremor/analysis/:recordID` - 更新既有分析紀錄的情境標籤與備註（相容 camelCase 與 snake_case）
* `GET  /tremor/history` - 查詢歷史分析特徵清單
* `GET  /tremor/weekly-report` - 取得動態週報趨勢數據

### 3. 用藥排程與紀錄 (`/medication`, `/medication-plan`)
* `POST   /medication-plan/save` - 新增/更新用藥排程（校驗 `canManageMedPlan` 權限）
* `GET    /medication-plan/all` - 取得所有用藥排程清單
* `DELETE /medication-plan/:planID` - 刪除排程（校驗 `canManageMedPlan` 權限）
* `POST   /medication/add` - 登記單次服藥紀錄（支援貼布照片上傳，校驗 `canAddMedRecord`）
* `GET    /medication/search` - 依日期查詢用藥紀錄
* `PUT    /medication/:recordID` - 修改用藥紀錄
* `DELETE /medication/:recordID` - 刪除用藥紀錄

### 4. 心情看板、生理體徵與症狀評估 (`/daily`, `/vitals`, `/symptom`, `/assessment`)
* `POST   /daily/sync` - 同步心情便利貼（自動識別發送者 ID，雙向相容 `is_caregiver_only`）
* `GET    /daily/all` - 取得看板所有便利貼（動態反射作者最新姓名，病患端過濾照護者專屬留言）
* `DELETE /daily/:recordID` - 刪除便利貼（嚴格限作者本人操作）
* `POST   /vitals/add` / `GET /vitals/search` - 新增與查詢生理指標
* `POST   /symptom/add` / `GET /symptom/search` - 記錄與查詢異常表徵（放寬支援 50MB 影音圖片）
* `POST   /assessment/submit` / `GET /assessment/search` - 提交與查詢每日 25 題自評量表得分

### 5. 智慧醫療 AI 助理 (`/api/ai`)
* `POST /api/ai/chat` - 小安對話生成（結合混合記憶、RAG 知識庫與 Function Calling 代辦）
* `GET  /api/ai/history` - 取得歷史對話紀錄（ISO 8601 時戳格式）
* `POST /api/ai/knowledge` - 手動新增單筆知識庫向量條目
* `POST /api/ai/knowledge/upload` - 批次上傳 `.txt` 或 `.json` 知識文件自動向量化
* `POST /api/ai/consultation-summary` - 產生診間看診溝通卡片結構化摘要（並行撈取 7 大模組數據）
* `GET  /api/ai/consultation-preparation` / `PUT` - 讀取與覆寫看診前準備事項

---

## 專案目錄結構

```text
TremorBackend/
├── Package.swift                    # SPM 套件相依設定 (Vapor, Fluent, JWT, NIOCore)
├── Dockerfile                       # 生產環境多階段建置設定 (swift:6.1 -> ubuntu:noble)
├── docker-compose.yml               # 本機開發容器化服務設定
└── Sources/
    ├── entrypoint.swift             # 應用程式啟動進入點
    ├── configure.swift              # 資料庫連線、日誌層級、JWT 與遷移註冊
    ├── routes.swift                 # 全域路由註冊與 SingleDeviceMiddleware 保護管線
    ├── Controllers/                 # RESTful API 控制器
    │   ├── UserController.swift     # 帳號、配對、權限與忘記密碼
    │   ├── TremorController.swift   # 原始數據、特徵分析與 PATCH 更新
    │   ├── MedicationController.swift
    │   ├── MedicationPlanController.swift
    │   ├── DailyController.swift    # 心情看板與動態姓名解析
    │   ├── AIController.swift       # 小安對話、Hybrid Memory、Agent 工具引擎
    │   ├── SymptomController.swift
    │   ├── HealthVitalsController.swift
    │   └── DailyAssessmentController.swift
    ├── Models/                      # Fluent 資料庫模型 (13 張資料表)
    ├── DTOs/                        # Request / Response 資料傳輸物件
    ├── Middlewares/                 # 安全中介軟體 (SingleDeviceMiddleware)
    ├── Migrations/                  # 資料庫結構建立與版本升級邏輯
    └── Tasks/                       # 常駐背景任務 (ChatCleanupTask: 定期清理舊對話)
```
