import Foundation

/// What is worth a place in the notes, decided by word lists on normalised words (lowercase, no diacritics): a
/// task that is not work, a question nobody can answer without the context, a report of a problem that says
/// nothing about its outcome, and two tasks that are one. Pure. The lists are deliberately short and
/// conservative: a miss only leaves an item in, which the owner can delete; a false hit loses it silently, so
/// each rule names what it looks for.
enum NotesRelevance {
    // MARK: Tasks that are not work

    /// Small talk that is a whole task: the text IS the courtesy or the call logistics, not a sentence that
    /// merely contains one ("Thanks, I'll send the report" is work).
    private static let nonWorkPhrases: [[String]] = [
        ["see", "you"], ["talk", "to", "you"], ["have", "a", "nice"], ["have", "a", "good"], ["enjoy", "the"],
        ["thank", "you"], ["say", "hi"], ["say", "hello"], ["good", "luck"], ["take", "a", "break"],
        ["share", "your", "screen"], ["share", "my", "screen"], ["can", "you", "hear"],
        ["turn", "on", "the", "camera"],
        ["turn", "on", "your", "camera"], ["do", "zobaczenia"], ["milego"], ["udanego"], ["dziekuje"],
        ["pozdrow"], ["powiedz", "czesc"], ["slychac"], ["udostepnij", "ekran"], ["wlacz", "kamere"],
        ["wlacz", "mikrofon"], ["wylacz", "mikrofon"], ["zrob", "przerwe"],
    ]

    /// Food and drink for the people in the room, as the object of a fetching verb: "bring coffee".
    private static let catering: Set<String> = [
        "coffee", "lunch", "pizza", "beer", "snacks", "kawa", "kawe", "kawy", "obiad", "obiadu", "pizze", "piwo",
    ]
    private static let fetching: Set<String> = [
        "bring", "get", "order", "buy", "grab", "fetch", "przynies", "zamow", "kup", "przywiez",
    ]

    /// Longest text (in words) that still counts as a bare courtesy or errand.
    private static let shortTask = 7

    /// Only the task's own text is looked at, never the quote: a courtesy that shares the sentence with real work
    /// ("Thanks, I'll send the report") must not remove the work.
    static func isNonWorkTask(text: String) -> Bool {
        let words = NotesText.words(text)
        guard !words.isEmpty, words.count <= shortTask else { return false }
        if words.contains(where: catering.contains), words.contains(where: fetching.contains) { return true }
        return nonWorkPhrases.contains { phrase in
            words.count <= phrase.count + 3 && contains(words, sequence: phrase)
        }
    }

    private static func contains(_ words: [String], sequence: [String]) -> Bool {
        guard !sequence.isEmpty, words.count >= sequence.count else { return false }
        for start in 0...(words.count - sequence.count)
        where Array(words[start..<(start + sequence.count)]) == sequence {
            return true
        }
        return false
    }

    // MARK: Questions without context

    /// Words that carry no subject: question words, auxiliaries, pronouns, articles, particles and bare
    /// states ("ready", "okay", "done"). Also used to compare tasks by their content words.
    static let emptyWords: Set<String> = [
        "when", "what", "who", "whom", "whose", "where", "why", "how", "which", "will", "would", "can", "could",
        "should", "shall", "may", "might", "must", "do", "does", "did", "is", "are", "was", "were", "be", "been",
        "am", "it", "its", "this", "that", "these", "those", "they", "them", "he", "she", "we", "you", "i", "me",
        "us", "there", "here", "the", "a", "an", "of", "to", "in", "on", "at", "for", "with", "about", "and", "or",
        "if", "then", "so", "ok", "okay", "yet", "still", "already", "soon", "now", "done", "ready", "finished",
        "right", "good", "fine", "sure", "yes", "no", "not", "have", "has", "had", "going", "get", "got", "go",
        "much", "many", "any", "some", "next", "else", "thing", "things", "one", "ones",
        "kiedy", "co", "kto", "kogo", "komu", "kim", "czym", "gdzie", "dlaczego", "czemu", "jak", "jaki", "jaka",
        "jakie", "ktory", "ktora", "ktore", "czy", "ono", "ten", "ta", "te", "tego", "tym", "ich", "im", "sie",
        "jest", "sa", "bedzie", "beda", "byl", "byla", "bylo", "moze", "mozemy", "mozna", "trzeba", "w", "z", "na",
        "do", "o", "od", "po", "za", "dla", "i", "a", "ze", "bo", "juz", "jeszcze", "tak", "nie", "dobrze", "my",
        "ja", "ty", "wy", "oni", "one", "mi", "nam", "wam", "mamy", "ma", "maja", "tu", "tutaj", "tam", "teraz",
        "potem", "wiec", "jakos", "cos", "gotowe", "gotowy", "gotowa", "skonczone", "zrobione",
    ]

    /// How many words of a question say what it is about (a clitic left by an apostrophe, "s" of "what's", is no
    /// word).
    static func subjectWordCount(of question: String) -> Int {
        let tokens = NotesText.tokens(question)
        return tokens.filter { token in
            if token.word.contains(where: \.isNumber) { return true }
            if token.word.count < 2 { return false }
            if token.capitalised, !token.startsSentence { return true }
            return !emptyWords.contains(token.word)
        }.count
    }

    /// "When will it be ready?", "Is that okay?": no word says what is asked about, so a reader who was not
    /// there cannot tell. One subject word is enough ("When is the release?").
    static func isContextFreeQuestion(_ text: String) -> Bool {
        subjectWordCount(of: text) < 1
    }

    // MARK: Reports without a verdict

    private static let problemWords: Set<String> = [
        "fail", "fails", "failed", "failing", "failure", "crash", "crashes", "crashed", "broken", "bug", "bugs",
        "error", "errors", "awaria", "awarie", "blad", "bledy", "wywala",
    ]
    private static let problemPhrases: [[String]] = [
        ["not", "working"], ["doesn", "t", "work"], ["don", "t", "work"], ["nie", "dziala"], ["nie", "dzialaja"],
    ]

    /// What turns a problem into a finding: a cause, a condition, a fix or a next step. Whole words (English) ...
    private static let verdictWords: Set<String> = [
        "because", "since", "caused", "cause", "causes", "due", "fixed", "fix", "resolved", "solved", "workaround",
        "patched", "reverted", "decided", "when", "whenever", "if", "unless", "after", "until", "so", "therefore",
        "should", "needs", "need", "will", "must", "addressed", "dropped", "accepted", "works", "agreed", "removed",
        "improved", "reduced", "poniewaz", "bo", "przez", "gdy", "kiedy", "jesli", "jezeli", "dopoki", "dlatego",
        "trzeba", "nalezy", "bedzie", "musi", "musimy",
    ]
    /// ... and word stems (Polish forms differ by tense, gender and case: "naprawił", "naprawiono", "naprawiony").
    private static let verdictStems = [
        "napraw", "rozwiaz", "popraw", "usun", "spowod", "wynik", "powod", "wskutek", "przyczyn", "wycof",
        "zdecyd", "obejsc", "zalat", "zmniejsz", "poprawi", "zaakcept", "powinn",
    ]

    /// A finding that names a failure and gives no cause, condition, fix or next step ("The export fails on
    /// large files."): a report without a verdict.
    static func isReportWithoutVerdict(_ text: String) -> Bool {
        let words = NotesText.words(text)
        let isProblem =
            words.contains(where: problemWords.contains) || problemPhrases.contains { contains(words, sequence: $0) }
        guard isProblem else { return false }
        return !words.contains { word in
            verdictWords.contains(word) || verdictStems.contains { word.hasPrefix($0) }
        }
    }

    // MARK: Task twins

    /// The tokens that tell two otherwise equal tasks apart: a number or a token with a digit (`Q3`), an inner
    /// capital (`iOS`) or a capitalised word inside a sentence (a name, a platform).
    private static func distinguishing(_ text: String) -> Set<String> {
        let characters = Array(text)
        var result = Set<String>()
        for token in NotesText.tokens(text) {
            let raw = Array(characters[token.start..<min(token.end, characters.count)])
            let inner = raw.dropFirst().contains { $0.isUppercase }
            let capital = (raw.first?.isUppercase ?? false) && !token.startsSentence
            if token.word.contains(where: \.isNumber) || inner || capital { result.insert(token.word) }
        }
        return result
    }

    private static func contentWords(_ text: String) -> Set<String> {
        Set(NotesText.words(text).filter { !emptyWords.contains($0) })
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Two tasks that are the same work: the same person (or an unnamed one), no different dates, and either the
    /// same sentence of the transcript or texts or quotes that share most of their content words and every
    /// distinguishing token (`Q3` and `Q4`, `iOS` and `Android`, `Acme` and `Beta` are two tasks).
    static func areSameTask(_ first: NotesPoint, _ second: NotesPoint) -> Bool {
        if let a = first.person, let b = second.person, !NotesText.namesMatch(a, b) { return false }
        if let a = first.due, let b = second.due, NotesText.words(a) != NotesText.words(b) { return false }
        if let u1 = first.utterance, let u2 = second.utterance, let s1 = first.sentence, let s2 = second.sentence,
            u1 == u2, s1 == s2
        {
            return true
        }
        if distinguishing(first.text).symmetricDifference(distinguishing(second.text)).isEmpty == false {
            return false
        }
        if distinguishing(first.quote).symmetricDifference(distinguishing(second.quote)).isEmpty == false {
            return false
        }
        return jaccard(contentWords(first.text), contentWords(second.text)) >= 0.7
            || jaccard(contentWords(first.quote), contentWords(second.quote)) >= 0.7
    }

    /// The tasks without a repeat: the first of two twins stays and takes the person and date the later one has
    /// and it lacks. Returns the removed ids with the id of the task that stands for them.
    static func deduplicatedTasks(_ tasks: [NotesPoint]) -> (tasks: [NotesPoint], removed: [String: String]) {
        var kept: [NotesPoint] = []
        var removed: [String: String] = [:]
        for task in tasks {
            if let index = kept.firstIndex(where: { areSameTask($0, task) }) {
                removed[task.id] = kept[index].id
                if kept[index].person == nil { kept[index].person = task.person }
                if kept[index].due == nil { kept[index].due = task.due }
            } else {
                kept.append(task)
            }
        }
        return (kept, removed)
    }
}
