//
//  AIDTO.swift
//

import Vapor
import Foundation

// MARK: - 1. 前端 App 互動用 DTO
struct ChatRequestDTO: Content {
    let message: String
}

struct ChatResponseDTO: Content {
    let reply: String
    let createdAt: Date
}

struct ChatHistoryResponseDTO: Content {
    let id: UUID?
    let role: String
    let content: String
    let createdAt: Date?
}

// MARK: - 2. 知識庫管理用 DTO
struct AddKnowledgeDTO: Content {
    let category: String
    let content: String
}

struct UploadKnowledgeDTO: Content {
    let category: String?
    let file: File
}

struct BatchKnowledgeDTO: Content {
    let category: String
    let content: String
}

// MARK: - 3. OpenAI Chat Completions & Function Calling DTO
struct OpenAIChatRequest: Content {
    var model: String
    var messages: [Message]
    var tools: [Tool]?
    
    struct Message: Content {
        var role: String
        var content: String?
        var tool_calls: [ToolCall]?
        var tool_call_id: String?
    }
    
    struct Tool: Content {
        var type: String = "function"
        var function: FunctionDefinition
        
        struct FunctionDefinition: Content {
            var name: String
            var description: String
            var parameters: ParameterSchema
            
            struct ParameterSchema: Content {
                var type: String = "object"
                var properties: [String: PropertyItem] = [:]
                var required: [String]?
                
                struct PropertyItem: Content {
                    var type: String = "string"
                    var description: String
                }
            }
        }
    }
}

struct OpenAIChatResponse: Content {
    struct Choice: Content {
        struct Message: Content {
            var role: String?
            var content: String?
            var tool_calls: [ToolCall]?
        }
        var message: Message
        var finish_reason: String?
    }
    var choices: [Choice]
}

struct ToolCall: Content {
    struct FunctionCall: Content {
        var name: String
        var arguments: String
    }
    var id: String
    var type: String
    var function: FunctionCall
}

// MARK: - 4. OpenAI Embedding DTO
struct OpenAIEmbeddingRequest: Content {
    let input: String
    var model: String = "text-embedding-3-small"
}

struct OpenAIEmbeddingResponse: Codable {
    struct EmbeddingData: Codable {
        let embedding: [Float]
    }
    let data: [EmbeddingData]
}

// MARK: - 5. 診間溝通卡片與醫療報告匯出 DTO
struct CustomReportFieldDTO: Content {
    var title: String
    var content: String
}

struct GenerateConsultationSummaryRequestDTO: Content {
    let startDate: Date
    let endDate: Date
    let selectedReportTypes: [String]
    let selectedCategories: [String]
    let customCategoryText: String?
    let includeMoodNotes: Bool
    let customFields: [CustomReportFieldDTO]?
}

struct ConsultationSummaryResponseDTO: Content {
    let preparationBeforeVisit: String
    let patientStatusDescription: String
    let comparisonWithLastVisit: String
    let otherMedicationsOrNotes: String
    let questionsForDoctor: String
    let customFieldsSummary: [CustomReportFieldDTO]
}
// MARK: - 6. 看診前準備提示同步 DTO
struct UpdateConsultationPreparationRequestDTO: Content {
    let content: String
}

struct ConsultationPreparationResponseDTO: Content {
    let content: String
    let updatedAt: Date?
}
