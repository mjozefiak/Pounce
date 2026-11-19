import Foundation

/// What is worth a place in the notes, decided by word lists on normalised words (lowercase, no diacritics): a
/// task that is not work, a question nobody can answer without the context, a report of a problem that says
/// nothing about its outcome, and two tasks that are one. Pure. The lists are deliberately short and
/// conservative: a miss only leaves an item in, which the owner can delete; a false hit loses it silently, so
/// each rule names what it looks for.
enum NotesRelevance {
    // MARK: Tasks that are not work

    /// Phrases (as word sequences) that make a "task" small talk, a courtesy or call logistics.
    private static let nonWorkPhrases: [[String]] = [
        ["see", "you"], ["talk", "to", "you"], ["have", "a", "nice"], ["have", "a", "good"], ["enjoy", "the"],
        ["thank", "you"], ["thanks"], ["say", "hi"], ["say", "hello"], ["good", "luck"], ["take", "a", "break"],
        ["share", "your", "screen"], ["share", "my", "screen"], ["can", "you", "hear"], ["hear", "me"],
        ["turn", "on", "the", "camera"], ["turn", "on", "your", "camera"], ["unmute"], ["mute"],
        ["do", "zobaczenia"], ["milego"], ["udanego"], ["dziekuje"], ["dzieki"], ["pozdrow"], ["powiedz", "czesc"],
        ["slychac"], ["udostepnij", "ekran"], ["wlacz", "kamere"], ["wlacz", "mikrofon"], ["wylacz", "mikrofon"],
        ["zrob", "przerwe"],
    ]

    /// Food and drink for the people in the room: not an action item of the meeting's work.
    private static let catering: Set<String> = [
        "coffee", "lunch", "pizza", "beer", "snacks", "kawa", "kawe", "kawy", "obiad", "obiadu", "pizze", "piwo",
    ]

    static func isNonWorkTask(text: String, quote: String) -> Bool {
        let words = NotesText.words(text + " " + quote)
        if words.contains(where: catering.contains) { return true }
        return nonWorkPhrases.contains { contains(words, sequence: $0) }
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
    /// states ("ready", "okay", "done").
    private static let emptyWords: Set<String> = [
        "when", "what", "who", "whom", "whose", "where", "why", "how", "which", "will", "would", "can", "could",
        "should", "shall", "may", "might", "must", "do", "does", "did", "is", "are", "was", "were", "be", "been",
        "am", "it", "its", "this", "that", "these", "those", "they", "them", "he", "she", "we", "you", "i", "me",
        "us", "there", "here", "the", "a", "an", "of", "to", "in", "on", "at", "for", "with", "about", "and", "or",
        "if", "then", "so", "ok", "okay", "yet", "still", "already", "soon", "now", "right",
        "good", "fine", "sure", "yes", "no", "not", "have", "has", "had", "going", "get", "got", "go", "much",
        "many", "any", "some", "next", "else", "thing", "things", "one", "ones",
        "kiedy", "co", "kto", "kogo", "komu", "kim", "czym", "gdzie", "dlaczego", "czemu", "jak", "jaki", "jaka",
        "jakie", "ktory", "ktora", "ktore", "czy", "to", "ono", "ten", "ta", "te", "tego", "tym", "ich", "im",
        "sie", "jest", "sa", "bedzie", "beda", "byl", "byla", "bylo", "moze", "mozemy", "mozna", "trzeba", "w",
        "z", "na", "do", "o", "od", "po", "za", "dla", "i", "a", "ze", "bo", "juz", "jeszcze", "tak", "nie", "ok",
        "dobrze", "my", "ja", "ty", "wy", "oni", "one", "mi", "nam",
        "wam", "mamy", "ma", "maja", "tu", "tutaj", "tam", "teraz", "potem", "wiec", "jeszcze", "jakos", "cos",
    ]

    /// How many words of a question say what it is about.
    static func subjectWordCount(of question: String) -> Int {
        let tokens = NotesText.tokens(question)
        return tokens.filter { token in
            if token.word.contains(where: \.isNumber) { return true }
            if token.capitalised, !token.startsSentence { return true }
            return !emptyWords.contains(token.word)
        }.count
    }

    /// "When will it be ready?", "Is that okay?": the question holds fewer than two words that say what it is
    /// about, so a reader who was not there cannot tell what is asked.
    static func isContextFreeQuestion(_ text: String) -> Bool {
        subjectWordCount(of: text) < 2
    }

    // MARK: Reports without a verdict

    private static let problemWords: Set<String> = [
        "fail", "fails", "failed", "failing", "failure", "crash", "crashes", "crashed", "broken", "bug", "bugs",
        "error", "errors", "issue", "issues", "problem", "problems", "awaria", "awarie", "blad", "bledy",
        "problemy", "wywala", "zawiesza",
    ]
    private static let problemPhrases: [[String]] = [
        ["not", "working"], ["doesn", "t", "work"], ["don", "t", "work"], ["nie", "dziala"], ["nie", "dzialaja"],
    ]

    /// What turns a problem into a finding: a cause, a condition, a fix or workaround, or what to do about it.
    private static let verdictWords: Set<String> = [
        "because", "since", "caused", "cause", "causes", "due", "fixed", "fix", "resolved", "solved", "workaround",
        "patched", "reverted", "decided", "when", "whenever", "if", "unless", "after", "until", "so", "therefore",
        "should", "needs", "need", "will", "must", "poniewaz", "bo", "przez", "przyczyna", "przyczyny", "naprawiony",
        "naprawiona", "naprawione", "naprawiono", "rozwiazany", "rozwiazane", "rozwiazano", "obejscie", "zalatany",
        "wycofano", "zdecydowano", "gdy", "kiedy", "jesli", "jezeli", "dopoki", "dlatego", "trzeba", "nalezy",
        "bedzie", "musi", "musimy", "powinien", "powinna", "powinno",
    ]

    /// A finding that names a problem and gives no cause, condition, fix or next step ("The export fails on
    /// large files."): a report without a verdict.
    static func isReportWithoutVerdict(_ text: String) -> Bool {
        let words = NotesText.words(text)
        let isProblem =
            words.contains(where: problemWords.contains) || problemPhrases.contains { contains(words, sequence: $0) }
        return isProblem && !words.contains(where: verdictWords.contains)
    }

    // MARK: Task twins

    /// Two tasks that are the same work: the same sentence of the transcript, or quotes that share most words, or
    /// texts that share most words with the same (or an unnamed) person and no different dates.
    static func areSameTask(_ first: NotesPoint, _ second: NotesPoint) -> Bool {
        if NotesGuard.nearDuplicate(first, second) { return true }
        if let a = first.person, let b = second.person, !NotesText.namesMatch(a, b) { return false }
        if let a = first.due, let b = second.due, NotesText.words(a) != NotesText.words(b) { return false }
        let a = Set(NotesText.words(first.text))
        let b = Set(NotesText.words(second.text))
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.7
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
