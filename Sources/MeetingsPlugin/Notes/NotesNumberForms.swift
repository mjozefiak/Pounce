import Foundation

/// Brings numbers written in words and in digits to one form (Polish and English), for the fact guard: "dwa
/// tysiące pięćset", "twenty five" and "2500" are the same number. Words are normalised (`NotesText.words`).
enum NotesNumberForms {
    private enum Kind { case unit, teen, ten, hundred, thousand, million }

    private static let table: [String: (Int, Kind)] = {
        var result: [String: (Int, Kind)] = [:]
        func add(_ value: Int, _ kind: Kind, _ forms: String) {
            for form in forms.split(separator: " ") { result[String(form)] = (value, kind) }
        }
        add(0, .unit, "zero zera zerem")
        add(1, .unit, "jeden jedna jedno jednego jednej jednym one")
        add(2, .unit, "dwa dwie dwoch dwoma dwom dwojga two")
        add(3, .unit, "trzy trzech trzema trzem three")
        add(4, .unit, "cztery czterech czterema czterem four")
        add(5, .unit, "piec pieciu piecioma pieciom five")
        add(6, .unit, "szesc szesciu szescioma szesciom six")
        add(7, .unit, "siedem siedmiu siedmioma siedmiom seven")
        add(8, .unit, "osiem osmiu osmioma osmiom eight")
        add(9, .unit, "dziewiec dziewieciu dziewiecioma dziewieciom nine")
        add(10, .teen, "dziesiec dziesieciu dziesiecioma dziesieciom ten")
        add(11, .teen, "jedenascie jedenastu eleven")
        add(12, .teen, "dwanascie dwunastu twelve")
        add(13, .teen, "trzynascie trzynastu thirteen")
        add(14, .teen, "czternascie czternastu fourteen")
        add(15, .teen, "pietnascie pietnastu fifteen")
        add(16, .teen, "szesnascie szesnastu sixteen")
        add(17, .teen, "siedemnascie siedemnastu seventeen")
        add(18, .teen, "osiemnascie osiemnastu eighteen")
        add(19, .teen, "dziewietnascie dziewietnastu nineteen")
        add(20, .ten, "dwadziescia dwudziestu dwudziestoma twenty")
        add(30, .ten, "trzydziesci trzydziestu trzydziestoma thirty")
        add(40, .ten, "czterdziesci czterdziestu czterdziestoma forty")
        add(50, .ten, "piecdziesiat piecdziesieciu fifty")
        add(60, .ten, "szescdziesiat szescdziesieciu sixty")
        add(70, .ten, "siedemdziesiat siedemdziesieciu seventy")
        add(80, .ten, "osiemdziesiat osiemdziesieciu eighty")
        add(90, .ten, "dziewiecdziesiat dziewiecdziesieciu ninety")
        add(100, .hundred, "sto stu setka hundred")
        add(200, .hundred, "dwiescie dwustu")
        add(300, .hundred, "trzysta trzystu")
        add(400, .hundred, "czterysta czterystu")
        add(500, .hundred, "piecset pieciuset")
        add(600, .hundred, "szescset szesciuset")
        add(700, .hundred, "siedemset siedmiuset")
        add(800, .hundred, "osiemset osmiuset")
        add(900, .hundred, "dziewiecset dziewieciuset")
        // Ordinals (dates): "piętnastego marca", "the fifteenth".
        add(1, .unit, "pierwszego pierwszy first")
        add(2, .unit, "drugiego drugi second")
        add(3, .unit, "trzeciego trzeci third")
        add(4, .unit, "czwartego czwarty fourth")
        add(5, .unit, "piatego piaty fifth")
        add(6, .unit, "szostego szosty sixth")
        add(7, .unit, "siodmego siodmy seventh")
        add(8, .unit, "osmego osmy eighth")
        add(9, .unit, "dziewiatego dziewiaty ninth")
        add(10, .teen, "dziesiatego dziesiaty tenth")
        add(11, .teen, "jedenastego eleventh")
        add(12, .teen, "dwunastego twelfth")
        add(13, .teen, "trzynastego thirteenth")
        add(14, .teen, "czternastego fourteenth")
        add(15, .teen, "pietnastego fifteenth")
        add(16, .teen, "szesnastego sixteenth")
        add(17, .teen, "siedemnastego seventeenth")
        add(18, .teen, "osiemnastego eighteenth")
        add(19, .teen, "dziewietnastego nineteenth")
        add(20, .ten, "dwudziestego twentieth")
        add(30, .ten, "trzydziestego thirtieth")
        add(1000, .thousand, "tysiac tysiace tysiecy tysiaca thousand")
        add(1_000_000, .million, "milion miliony milionow miliona million")
        return result
    }()

    /// The Polish ordinal stems of the hours a clock time is said with ("o piątej"), by value.
    private static let hourStems: [(String, Int)] = [
        ("pierwsz", 1), ("drug", 2), ("trzec", 3), ("czwart", 4), ("piat", 5), ("szost", 6), ("siodm", 7),
        ("osm", 8), ("dziewiat", 9), ("dziesiat", 10), ("jedenast", 11), ("dwunast", 12), ("trzynast", 13),
        ("czternast", 14), ("pietnast", 15), ("szesnast", 16), ("siedemnast", 17), ("osiemnast", 18),
        ("dziewietnast", 19), ("dwudziest", 20),
    ]

    /// Every number a text says: digits as written (an integer is read as a value) and runs of number words.
    /// `skipOne` leaves out the bare word "one"/"jeden" and its forms, which are mostly a pronoun.
    static func spokenValues(_ words: [String], skipOne: Bool = false) -> Set<Int> {
        var values: Set<Int> = []
        var total = 0
        var current = 0
        var lastKind: Kind?
        var run = 0
        var lastDigit: Int?
        func flush() {
            guard run > 0 else { return }
            let value = total + current
            if !(skipOne && run == 1 && value == 1) { values.insert(value) }
            if current != value, current > 0 { values.insert(current) }
            total = 0
            current = 0
            lastKind = nil
            run = 0
        }
        for word in words {
            if let digits = Int(word) {
                flush()
                values.insert(digits)
                lastDigit = digits
                continue
            }
            guard let (value, kind) = table[word] else {
                flush()
                lastDigit = nil
                continue
            }
            if let digit = lastDigit, kind == .thousand || kind == .million {
                values.insert(digit * value)  // "28 tysięcy"
                lastDigit = nil
                continue
            }
            lastDigit = nil
            switch kind {
            case .unit:
                if let last = lastKind, last == .unit || last == .teen { flush() }
                current += value
            case .teen:
                if let last = lastKind, last != .hundred, last != .thousand, last != .million { flush() }
                current += value
            case .ten:
                if let last = lastKind, last != .hundred, last != .thousand, last != .million { flush() }
                current += value
            case .hundred:
                if value == 100, lastKind == .unit, (1...9).contains(current) {
                    current *= 100  // English "two hundred"
                } else {
                    if let last = lastKind, last != .thousand, last != .million { flush() }
                    current += value
                }
            case .thousand:
                if current > 0 { values.insert(current) }
                total += (current == 0 ? 1 : current) * 1000
                current = 0
            case .million:
                total += (current == 0 ? 1 : current) * 1_000_000
                current = 0
            }
            lastKind = kind
            run += 1
        }
        flush()
        return values
    }

    static func isMagnitude(_ word: String) -> Bool {
        guard let (_, kind) = table[word] else { return false }
        return kind == .thousand || kind == .million
    }

    /// The endings of a feminine ordinal, the form a clock hour is said in ("o piątej", "na piątą", "trzecia").
    private static let hourEndings: Set<String> = ["a", "ej", "ia", "iej"]

    /// The hours named by Polish ordinals ("piątej" → 5). A weekday with the same stem ("piątek", "czwartku") or
    /// another ordinal ("drugi") names no hour.
    static func spokenHours(_ words: [String]) -> Set<Int> {
        var hours: Set<Int> = []
        for word in words {
            for (stem, value) in hourStems
            where word.hasPrefix(stem) && hourEndings.contains(String(word.dropFirst(stem.count))) {
                hours.insert(value)
            }
        }
        return hours
    }
}
