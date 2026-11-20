import Foundation

/// Round 5 probes (PR 134, ADR 0010 variant iii). Every text is invented. The `OV` rows are removals before a
/// marker word that is used as content: the rule that lets a span start at the beginning of the chunk, or on a
/// parallel word, must not delete a negation or a fact the speaker did not withdraw. The `OK` rows are correct
/// cleanups next to them, so the cost of the length floor and of the negation check stays visible.
extension GuardProbeTable {
    static let round6: [Row] = [
        // Reported in round 4 (O1 to O6): main rejects all of them by length.
        (
            "OV1", "we meet on monday and the review is on friday sorry on thursday and then we all go home",
            "We meet on Thursday and then we all go home.", false
        ),
        (
            "OV2", "zamów dwie pizze i trzy cole czekaj cztery cole i to wszystko na dziś",
            "Zamów 4 cole i to wszystko na dziś.", false
        ),
        ("OV3", "to nie jest właściwie gotowe do wysyłki", "Gotowe do wysyłki.", false),
        ("OV4", "we should not actually ship it today", "Ship it today.", false),
        ("OV5", "napisz Piotrkowi nie czekaj na mnie z kolacją", "Na mnie z kolacją.", false),
        ("OV6", "tell her i am sorry about the delay", "About the delay.", false),
        // New: a negation in the removed span.
        ("OV7", "i do not think we should actually change the plan", "Change the plan.", false),
        ("OV8", "nie chcę właściwie jechać tam jutro", "Jechać tam jutro.", false),
        ("OV9", "never send the file to the client actually without a review", "Without a review.", false),
        ("OV10", "don't call him sorry about that", "About that.", false),
        ("OV11", "nie dzwoń do niego przepraszam w tej sprawie", "W tej sprawie.", false),
        ("OV15", "the answer is not yes actually it depends", "It depends.", false),
        ("OV16", "to nie jest żaden problem jednak mamy opóźnienie", "Mamy opóźnienie.", false),
        ("OV17", "he never agreed to the price i mean to the date", "To the date.", false),
        (
            "OV19", "please do not send the invoice before friday wait send it on monday", "Send it on Monday.",
            false
        ),
        ("OV20", "nie wysyłaj faktury przed piątkiem czekaj wyślij w poniedziałek", "Wyślij w poniedziałek.", false),
        ("OV21", "i can't make it on friday sorry on monday", "On Monday.", false),
        ("OV29", "tell her sorry about the delay", "About the delay.", false),
        ("OV30", "do not actually ship it today", "Ship it today.", false),
        ("OV28", "nie lubię tej wersji właściwie lubię starą", "Lubię starą.", false),
        // New: a fact the speaker did not withdraw, or a long removal.
        ("OV12", "we will cancel the order i mean the second one is fine", "The second one is fine.", false),
        ("OV13", "on monday and on friday sorry on tuesday", "On Tuesday.", false),
        ("OV14", "we meet at ten and eat at noon sorry at one", "We meet at one.", false),
        ("OV18", "mamy pięć wolnych miejsc w sali czekaj sześć miejsc", "Sześć miejsc.", false),
        ("OV22", "kupmy trzy kilo jabłek i dwa kilo gruszek czekaj cztery kilo gruszek", "Cztery kilo gruszek.", false),
        (
            "OV23", "the first demo is on monday and the second is on friday wait on tuesday",
            "The first demo is on Tuesday.", false
        ),
        ("OV31", "tell her the plan is fine and we start monday or actually friday", "Friday.", false),
        ("OV32", "buy milk and eggs or actually bread", "Buy bread.", false),
        ("OV33", "we should not ship it or actually we should wait", "We should wait.", false),
        ("OV34", "we have two rooms free tonight and a third one tomorrow wait four rooms", "Four rooms.", false),
        // Correct cleanups beside them.
        ("OK9", "she isn't coming to the party actually she wants to stay home", "She wants to stay home.", true),
        (
            "OK10", "użyjemy chmury albo jednak zostaniemy przy własnym serwerze", "Zostaniemy przy własnym serwerze.",
            true
        ),
        ("OK11", "nie wysyłaj tego albo jednak wyślij to jutro", "Wyślij to jutro.", true),
        ("OK12", "take the red one or actually the blue one", "Take the blue one.", true),
        (
            "OK13", "the fee is eighteen thousand that is i mean twenty five thousand euros",
            "The fee is 25,000 euros.", true
        ),
        ("OK1", "we should ship today scratch that we should not ship today", "We should not ship today.", true),
        ("OK2", "let him come i mean don't let him come", "Don't let him come.", true),
        ("OK3", "they did not approve the budget actually they approved the plan", "They approved the plan.", true),
        (
            "OK4", "we are not going to hire anyone sorry we are going to hire two people",
            "We are going to hire two people.", true
        ),
        ("OK5", "he has no idea sorry he has no clue", "He has no clue.", true),
        ("OK6", "zamów dwie pizze nie czekaj trzy pizze", "Zamów trzy pizze.", true),
        ("OK7", "order two pizzas no wait three pizzas", "Order three pizzas.", true),
        (
            "OK8", "we meet on monday and the review is on friday sorry on thursday",
            "We meet on Monday and the review is on Thursday.", true
        ),
    ]
}
