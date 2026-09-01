import Vapor
import Foundation

struct AssessmentAnswerDetailDTO: Content {
    let questionId: Int
    let section: String
    let title: String
    let score: Int
    let selectedOptionTitle: String
}

struct CreateDailyAssessmentRequestDTO: Content {
    let date: Date
    let totalScore: Int
    let moodScore: Int
    let adlScore: Int
    let motorScore: Int
    let details: [AssessmentAnswerDetailDTO]?
}

struct DailyAssessmentResponseDTO: Content {
    let id: Int?
    let date: Date
    let totalScore: Int
    let moodScore: Int
    let adlScore: Int
    let motorScore: Int
    let details: [AssessmentAnswerDetailDTO]?
}
