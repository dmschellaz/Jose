import Testing
import Foundation
@testable import RedlineCore

private let which = LiveQuestion(text: "Which button?", options: ["Save", "Cancel"])

@Suite struct ChattyConversationTests {
    let sentence = UUID()

    @Test func questionOpensAndOnlyItsTextIsSpoken() throws {
        var c = ChattyConversation()
        let out = c.respond(say: "I marked Save.", question: which, sentenceID: sentence, at: 5)
        let q = try #require(out.asked)
        #expect(out.speak == "Which button?")
        #expect(out.said == nil)
        #expect(c.open == q)
        #expect(q.askedAt == 5 && q.sentenceID == sentence && q.options == ["Save", "Cancel"])
        #expect(q.event == .aiQuestion(id: q.id, sentenceID: sentence, text: "Which button?", options: ["Save", "Cancel"], t: 5))
    }

    @Test func onlyOneQuestionAtATime() throws {
        var c = ChattyConversation()
        let firstOut = c.respond(say: "", question: which, sentenceID: sentence, at: 5)
        let first = try #require(firstOut.asked)
        // A second question while one is open is dropped; the question also counts as the last spoken line.
        let soon = c.respond(say: "I marked Save.", question: LiveQuestion(text: "Which row?", options: ["Top", "Bottom"]),
                             sentenceID: UUID(), at: 8)
        #expect(soon == ChattyConversation.Outcome())
        #expect(c.open == first)
        // Later, the remark from the same answer may still be spoken, but the question stays dropped.
        let later = c.respond(say: "I marked Save.", question: LiveQuestion(text: "Which row?", options: ["Top", "Bottom"]),
                              sentenceID: UUID(), at: 15)
        #expect(later == ChattyConversation.Outcome(speak: "I marked Save.", said: "I marked Save."))
        #expect(c.open == first)
    }

    @Test func remarksAtMostEveryTenSeconds() {
        var c = ChattyConversation()
        #expect(c.respond(say: " Now on billing. ", question: nil, sentenceID: sentence, at: 0)
                == ChattyConversation.Outcome(speak: "Now on billing.", said: "Now on billing."))
        #expect(c.respond(say: "Now on profile.", question: nil, sentenceID: sentence, at: 9.9) == ChattyConversation.Outcome())
        #expect(c.respond(say: "Now on profile.", question: nil, sentenceID: sentence, at: 10).speak == "Now on profile.")
        #expect(c.respond(say: "   ", question: nil, sentenceID: sentence, at: 60) == ChattyConversation.Outcome())
    }

    @Test func questionsIgnoreTheLineLimit() {
        var c = ChattyConversation()
        _ = c.respond(say: "Now on billing.", question: nil, sentenceID: sentence, at: 0)
        let out = c.respond(say: "", question: which, sentenceID: sentence, at: 3)
        #expect(out.asked != nil)
        #expect(out.speak == "Which button?")
    }

    @Test func clickAnswerClosesTheQuestion() throws {
        var c = ChattyConversation()
        let qOut = c.respond(say: "", question: which, sentenceID: sentence, at: 5)
        let q = try #require(qOut.asked)
        #expect(c.answer("Save", via: .click, at: 7) == .questionAnswered(id: q.id, answer: "Save", via: .click, t: 7))
        #expect(c.open == nil)
        #expect(c.answer("Cancel", via: .click, at: 8) == nil)
    }

    @Test func voiceAnswerIsTheNextSentenceAfterTheQuestion() throws {
        var c = ChattyConversation()
        let qOut = c.respond(say: "", question: which, sentenceID: sentence, at: 5)
        let q = try #require(qOut.asked)
        // A sentence already under way when the question came isn't the answer.
        #expect(c.voiceAnswer(text: "and also the header", start: 4, at: 6) == nil)
        #expect(c.open == q)
        let answeredOut = c.voiceAnswer(text: "the save one", start: 5.5, at: 7)
        let answered = try #require(answeredOut)
        #expect(answered.question == q)
        #expect(answered.event == .questionAnswered(id: q.id, answer: "the save one", via: .voice, t: 7))
        #expect(c.open == nil)
    }

    @Test func expireClosesOnlyThatQuestionAndResetClearsEverything() throws {
        var c = ChattyConversation()
        let qOut = c.respond(say: "", question: which, sentenceID: sentence, at: 5)
        let q = try #require(qOut.asked)
        #expect(c.expire(UUID(), at: 25) == nil)
        #expect(c.expire(q.id, at: 25) == .questionAnswered(id: q.id, answer: "", via: .skipped, t: 25))
        #expect(c.expire(q.id, at: 26) == nil)
        _ = c.respond(say: "", question: which, sentenceID: sentence, at: 30)
        c.reset()
        #expect(c.open == nil)
        #expect(c.respond(say: "Hello.", question: nil, sentenceID: sentence, at: 31).speak == "Hello.")
    }
}
