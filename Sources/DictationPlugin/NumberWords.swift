import Foundation

/// The value of spoken numbers (Polish and English, 0 to 999 999), so `FormatterGuard` can tell that a
/// digit the model wrote stands for the number words the speaker said ("sześćdziesięciu" is 60) and not for
/// some other number. Pure; conservative: a word list that is not a well-formed number gives `nil`.
enum NumberWords {
    private enum Kind { case unit, teen, tens, hundred, thousand, hundredMultiplier }

    private static let english: [String: (Kind, Int)] = {
        var table: [String: (Kind, Int)] = [:]
        let units = [
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        ]
        for (index, word) in units.enumerated() { table[word] = (.unit, index + 1) }
        let unitOrdinals = [
            "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
        ]
        for (index, word) in unitOrdinals.enumerated() { table[word] = (.unit, index + 1) }
        let teens = [
            "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
            "nineteen",
        ]
        for (index, word) in teens.enumerated() { table[word] = (.teen, index + 10) }
        let teenOrdinals = [
            "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth",
            "seventeenth", "eighteenth", "nineteenth",
        ]
        for (index, word) in teenOrdinals.enumerated() { table[word] = (.teen, index + 10) }
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        let tensOrdinals = [
            "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth",
        ]
        for (index, word) in tens.enumerated() { table[word] = (.tens, (index + 2) * 10) }
        for (index, word) in tensOrdinals.enumerated() { table[word] = (.tens, (index + 2) * 10) }
        table["hundred"] = (.hundredMultiplier, 100)
        table["hundredth"] = (.hundredMultiplier, 100)
        table["thousand"] = (.thousand, 1000)
        table["thousandth"] = (.thousand, 1000)
        return table
    }()

    private static let ordinalEndings = ["y", "a", "e", "ego", "ej", "emu", "ym", "ą", "ych", "ymi"]

    /// Every Polish number word the guard knows, spelled out: a stem plus a CLOSED set of number endings (or
    /// whole forms), so "piątek", "czwartek", "piętro", "trzeba", "jednak" or "dworzec" are not numbers.
    private static let polish: [String: (Kind, Int)] = {
        var table: [String: (Kind, Int)] = [:]
        func add(_ kind: Kind, _ value: Int, whole: [String] = [], stem: String = "", endings: [String] = []) {
            for word in whole { table[word] = (kind, value) }
            for ending in endings { table[stem + ending] = (kind, value) }
        }
        let units: [(Int, [String], String, [String])] = [
            (1, ["jeden"], "jedn", ["a", "e", "o", "ą", "ego", "ej", "emu", "ym", "ych", "ymi"]),
            (2, ["dwa", "dwie", "dwaj", "dwóch", "dwu", "dwom", "dwoma", "dwiema"], "", []),
            (3, ["trzy", "trzech", "trzem", "trzema", "trzej"], "", []),
            (4, ["cztery", "czterech", "czterem", "czterema", "czterej"], "", []),
            (5, ["pięć", "pięciu", "pięcioma"], "", []),
            (6, ["sześć", "sześciu", "sześcioma"], "", []),
            (7, ["siedem", "siedmiu", "siedmioma"], "", []),
            (8, ["osiem", "ośmiu", "ośmioma"], "", []),
            (9, ["dziewięć", "dziewięciu", "dziewięcioma"], "", []),
        ]
        for (value, whole, stem, endings) in units { add(.unit, value, whole: whole, stem: stem, endings: endings) }
        // The ordinals: pierwszy, drugi, trzeci and the regular ones.
        add(.unit, 1, stem: "pierwsz", endings: ordinalEndings)
        add(.unit, 2, stem: "drug", endings: ["i", "a", "ie", "iego", "iej", "iemu", "im", "ą", "ich", "imi"])
        add(.unit, 3, stem: "trzec", endings: ["i", "ia", "ie", "iego", "iej", "iemu", "im", "ią", "ich", "imi"])
        add(.unit, 4, stem: "czwart", endings: ordinalEndings)
        add(.unit, 5, stem: "piąt", endings: ordinalEndings)
        add(.unit, 6, stem: "szóst", endings: ordinalEndings)
        add(.unit, 7, stem: "siódm", endings: ordinalEndings)
        add(.unit, 8, stem: "ósm", endings: ordinalEndings)
        add(.unit, 9, stem: "dziewiąt", endings: ordinalEndings)
        add(.teen, 10, whole: ["dziesięć", "dziesięciu", "dziesięcioma"], stem: "dziesiąt", endings: ordinalEndings)
        let teens: [(Int, [String])] = [
            (11, ["jedenast"]), (12, ["dwanast", "dwunast"]), (13, ["trzynast"]), (14, ["czternast"]),
            (15, ["piętnast"]), (16, ["szesnast"]), (17, ["siedemnast"]), (18, ["osiemnast"]),
            (19, ["dziewiętnast"]),
        ]
        for (value, roots) in teens {
            for root in roots {
                add(
                    .teen, value, whole: [String(root.dropLast(2)) + "ście"], stem: root,
                    endings: ordinalEndings + ["u", "oma"])
            }
        }
        let tensLow: [(Int, String, String)] = [
            (20, "dwadzieścia", "dwudziest"), (30, "trzydzieści", "trzydziest"), (40, "czterdzieści", "czterdziest"),
        ]
        for (value, nominative, root) in tensLow {
            add(.tens, value, whole: [nominative], stem: root, endings: ordinalEndings + ["u", "oma"])
        }
        let tensHigh: [(Int, String)] = [
            (50, "pięćdzies"), (60, "sześćdzies"), (70, "siedemdzies"), (80, "osiemdzies"), (90, "dziewięćdzies"),
        ]
        for (value, root) in tensHigh {
            add(.tens, value, whole: [root + "iąt"], stem: root + "iąt", endings: ordinalEndings)
            add(.tens, value, stem: root, endings: ["ięciu", "ięcioma"])
        }
        let hundreds: [String: Int] = [
            "sto": 100, "stu": 100, "sta": 100, "dwieście": 200, "dwustu": 200, "dwusta": 200, "trzysta": 300,
            "trzystu": 300, "czterysta": 400, "czterystu": 400, "pięćset": 500, "pięciuset": 500,
            "sześćset": 600, "sześciuset": 600, "siedemset": 700, "siedmiuset": 700, "osiemset": 800,
            "ośmiuset": 800, "dziewięćset": 900, "dziewięciuset": 900,
        ]
        for (word, value) in hundreds { table[word] = (.hundred, value) }
        // The ordinals of the hundreds: setny, dwusetny, trzechsetny ...
        let hundredOrdinals: [(Int, String)] = [
            (100, "setn"), (200, "dwusetn"), (300, "trzechsetn"), (400, "czterechsetn"), (500, "pięćsetn"),
            (600, "sześćsetn"), (700, "siedemsetn"), (800, "osiemsetn"), (900, "dziewięćsetn"),
        ]
        for (value, stem) in hundredOrdinals { add(.hundred, value, stem: stem, endings: ordinalEndings) }
        add(
            .thousand, 1000,
            whole: ["tysiąc", "tysiące", "tysięcy", "tysiącu", "tysiącem", "tysiącom", "tysiącami", "tysiącach"],
            stem: "tysięczn", endings: ordinalEndings)
        return table
    }()

    private static func classify(_ word: String) -> (Kind, Int)? {
        if let entry = english[word] { return entry }
        return polish[word]
    }

    /// The number the words say, or `nil` when a word is not a number word or the order is not a number.
    /// The tokens are lower-cased words with no punctuation. "zero" alone is 0; English "a hundred", "one
    /// hundred and five", "fifteen hundred" and a bare "hundred" or "thousand" are read like the Polish
    /// "sto" and "tysiąc".
    static func value(of words: [String]) -> Int? {
        guard !words.isEmpty, words.count <= 9 else { return nil }
        if words == ["zero"] { return 0 }
        var total = 0
        var group = 0
        // 3 hundreds, 2 tens and teens, 1 units; 4 before anything in a group.
        var lastClass = 4
        var lastSingle = 0
        var thousandsUsed = false
        var pendingAnd = false
        for (index, word) in words.enumerated() {
            if word == "and" {
                // Only inside an English number: after the hundreds or the thousands, and before more.
                guard index > 0, index + 1 < words.count, !pendingAnd, lastClass >= 3,
                    group >= 100 || (total > 0 && group == 0)
                else { return nil }
                pendingAnd = true
                continue
            }
            if word == "a" {
                // "a hundred", "a thousand".
                guard index == 0, words.count > 1, ["hundred", "thousand"].contains(words[1]) else { return nil }
                group = 1
                lastSingle = 1
                lastClass = 1
                continue
            }
            pendingAnd = false
            guard let (kind, value) = classify(word) else { return nil }
            switch kind {
            case .hundred:
                guard lastClass == 4, group == 0 else { return nil }
                group = value
                lastClass = 3
            case .hundredMultiplier:
                if group == 0, lastClass == 4 {
                    group = 100
                } else {
                    guard lastClass <= 2, group == lastSingle, group >= 1, group <= 19 else { return nil }
                    group *= 100
                }
                lastClass = 3
            case .tens:
                guard lastClass > 2 else { return nil }
                group += value
                lastClass = 2
                lastSingle = 0
            case .teen:
                guard lastClass > 2 else { return nil }
                group += value
                lastClass = 2
                lastSingle = value
            case .unit:
                guard lastClass > 1 else { return nil }
                group += value
                lastSingle = lastClass == 4 ? value : 0
                lastClass = 1
            case .thousand:
                guard !thousandsUsed, group < 1000 else { return nil }
                total += (group == 0 ? 1 : group) * 1000
                group = 0
                lastClass = 4
                thousandsUsed = true
            }
        }
        guard !pendingAnd else { return nil }
        let result = total + group
        return result > 0 ? result : nil
    }

    /// The value of a digit token: "60", "6", or an English ordinal such as "10th". Anything else is `nil`.
    static func value(ofDigits token: String) -> Int? {
        let digits = token.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 7, digits.allSatisfy({ $0.isASCII }) else { return nil }
        let suffix = token.dropFirst(digits.count)
        guard suffix.isEmpty || ["st", "nd", "rd", "th"].contains(String(suffix)) else { return nil }
        return Int(digits)
    }

    /// The value of the digit tokens starting at `index`, grouped the way the tokenizer splits "25 000":
    /// a number of one to three digits followed by groups of exactly three digits. Gives every group length
    /// that reads as one number: 1 token, then 2, ... ("25", "000" is 25 and 25000).
    static func digitValues(in tokens: [String], at index: Int) -> [(tokens: Int, value: Int)] {
        guard index < tokens.count, let first = value(ofDigits: tokens[index]) else { return [] }
        var result = [(tokens: 1, value: first)]
        guard tokens[index].count <= 3, tokens[index].allSatisfy(\.isNumber) else { return result }
        var combined = tokens[index]
        var count = 1
        while index + count < tokens.count, tokens[index + count].count == 3,
            tokens[index + count].allSatisfy({ $0.isASCII && $0.isNumber }), combined.count < 7
        {
            combined += tokens[index + count]
            count += 1
            if let value = Int(combined) { result.append((count, value)) }
        }
        return result
    }
}
