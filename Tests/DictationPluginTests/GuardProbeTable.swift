import Foundation
import Testing

@testable import DictationPlugin

/// Regression tables for `FormatterGuard` (PR 134, review rounds 1 to 4). Every text is invented. A row says
/// whether a CORRECT cleanup of the input is `ok` (true: the guard accepts it unless the id is in
/// `GuardProbeTests.falseAlarms`, a documented fail-safe that pastes the raw text) or a text that loses the
/// final version or other content (false: with a retraction marker the guard must reject it, no exception;
/// without one it gets the verdict of `main`, and the ones `main` accepts are `limitsSharedWithMain`).
enum GuardProbeTable {
    typealias Row = (id: String, input: String, output: String, ok: Bool)

    /// Round 1 and 2 probes: attacks (H) and cleanups (N, F).
    static let rounds12: [Row] = [
        ("H1a", "zamów dwie pizze nie czekaj trzy pizze jednak bez cebuli", "Zamów dwie pizze bez cebuli.", false),
        ("H1b", "zamów dwie pizze nie czekaj trzy pizze przepraszam", "Zamów dwie pizze.", false),
        ("H1c", "order two pizzas no wait three pizzas sorry", "Order two pizzas.", false),
        (
            "H1d", "the meeting is at ten I mean eleven sorry for the late notice",
            "The meeting is at ten for the late notice.", false
        ),
        (
            "H1e", "spotkanie jest o dziesiątej nie czekaj o jedenastej właściwie w sali konferencyjnej",
            "Spotkanie jest o dziesiątej w sali konferencyjnej.", false
        ),
        ("H1f", "spotkajmy się we wtorek nie czekaj w środę jednak", "Spotkajmy się we wtorek.", false),
        ("H1g", "book the dentist for monday no wait tuesday actually", "Book the dentist for Monday.", false),
        (
            "H1h", "potrzebujemy pięćdziesięciu sztuk przepraszam sześćdziesięciu sztuk przepraszam",
            "Potrzebujemy 50 sztuk.", false
        ),
        ("H1i", "we need fifty units sorry sixty units wait", "We need 50 units.", false),
        ("H1j", "zamów dwie pizze nie czekaj trzy pizze to znaczy dużych", "Zamów dwie pizze dużych.", false),
        ("H2a", "budżet to sześćset złotych nie czekaj sześćdziesiąt złotych", "Budżet to sześćset złotych.", false),
        ("H2b", "we need eighteen units sorry eighty units", "We need eighteen units.", false),
        ("H2c", "we need seventy units sorry seventeen units", "We need seventy units.", false),
        ("H2d", "zamów cztery kartony nie czekaj czternaście kartonów", "Zamów cztery kartony.", false),
        ("H2e", "zamów trzy kartony nie czekaj trzynaście kartonów", "Zamów trzy kartony.", false),
        ("H2f", "spotkanie o dziewiątej nie czekaj o dziewiętnastej", "Spotkanie o dziewiątej.", false),
        ("H2g", "zamów siedemset sztuk przepraszam siedemdziesiąt sztuk", "Zamów siedemset sztuk.", false),
        ("H2h", "buy seven boxes sorry seventeen boxes", "Buy seven boxes.", false),
        ("H3a", "wyślij to do Kowalskiego nie czekaj do Kowalskiej", "Wyślij to do Kowalskiego.", false),
        ("H3b", "zadzwoń do Michała nie czekaj do Michaliny", "Zadzwoń do Michała.", false),
        ("H3c", "send it to John I mean to Johnson", "Send it to John.", false),
        ("H3d", "zaproś Aleksandra nie czekaj Aleksandrę", "Zaproś Aleksandra.", false),
        ("H3e", "send it to Stephen sorry to Stephanie", "Send it to Stephen.", false),
        ("H4a", "cena to cztery dwadzieścia nie czekaj pięć pięćdziesiąt", "Cena to 50.", false),
        ("H4b", "the price is five fifty sorry six sixty", "The price is 60.", false),
        ("H4c", "the train leaves at six fifteen sorry at seven seventeen", "The train leaves at 17.", false),
        ("H4d", "spotkanie o trzeciej nie czekaj o trzy trzydzieści", "Spotkanie o 30.", false),
        ("H4e", "send it to Jo I mean to Joanna", "Send it to Joanna.", true),
        ("H5a", "spotkanie piątego nie czekaj w piątek", "Spotkanie w 5.", false),
        ("H5b", "spotkanie czwartego nie czekaj w czwartek", "Spotkanie w 4.", false),
        ("H5c", "biuro jest na drugim nie czekaj na piętrze", "Biuro jest na 5.", false),
        (
            "H6a", "spotkanie jest o dziesiątej a nie o jedenastej w sali konferencyjnej na drugim piętrze",
            "Spotkanie jest o dziesiątej w sali konferencyjnej na drugim piętrze.", false
        ),
        (
            "H6b", "the meeting is at ten or rather eleven in the main room on the second floor",
            "The meeting is at ten in the main room on the second floor.", false
        ),
        (
            "H6c", "zamów dwie pizze znaczy trzy pizze z szynką i dwie cole", "Zamów dwie pizze z szynką i dwie cole.",
            false
        ),
        (
            "H6d", "spotkajmy się we wtorek nie nie w środę o piętnastej w biurze",
            "Spotkajmy się we wtorek o piętnastej w biurze.", false
        ),
        ("H7a", "o dziesiątej nie czekaj o jedenastej przepraszam o dwunastej", "O 12.", true),
        ("H7b", "o dziesiątej nie czekaj o jedenastej przepraszam o dwunastej", "O 10.", false),
        ("H7c", "o dziesiątej nie czekaj o jedenastej przepraszam o dwunastej", "O 11.", false),
        ("H7d", "zamów dwie pizze nie czekaj trzy pizze i sorry jeszcze colę", "Zamów dwie pizze i colę.", false),
        ("H8a", "jutro nie przyjdę do biura jednak zadzwonię", "Jutro zadzwonię.", false),
        ("H8b", "I am sorry I cannot come to the party on friday", "I cannot come to the party on Friday.", true),
        ("H8c", "wait for me at the station I mean the main one", "Wait for me at the main one.", false),
        ("H8d", "actually the budget is fine we can buy the new laptops", "We can buy the new laptops.", false),
        ("H8e", "właściwie to nie wiem czy zdążę na spotkanie", "Nie wiem, czy zdążę na spotkanie.", true),
        ("H8f", "albo zrobimy to dziś albo jutro zależy od klienta", "Zrobimy to jutro, zależy od klienta.", false),
        (
            "H9a", "pokój dwanaście nie czekaj pokój dwadzieścia na piętrze dwudziestym", "Pokój 12 na piętrze 20.",
            false
        ),
        ("H9b", "rozdział trzeci strona dwa nie czekaj strona pięć", "Rozdział 3, strona 5.", true),
        ("H9c", "zamów pięć pizz nie czekaj piątek dostawa", "Zamów 5 dostawa.", false),
        (
            "H10a", "the deadline is the twelfth no the thirteenth of March", "The deadline is the twelfth of March.",
            false
        ),
        ("H10b", "the deadline is the twelfth no the thirteenth of March", "The deadline is the 12th of March.", false),
        (
            "H10c", "send the file to Mark sorry to Steven and I will let you know",
            "Send the file to Steven and I will let you know.", true
        ),
        (
            "H10d", "send the file to Mark sorry to Steven and I will let you know",
            "Send the file to Steven and I will let.", false
        ),
        (
            "N1", "pociąg odjeżdża o szóstej trzydzieści to znaczy o szóstej czterdzieści", "Pociąg odjeżdża o 6:40.",
            true
        ),
        (
            "N2", "pociąg odjeżdża o szóstej trzydzieści to znaczy o szóstej czterdzieści",
            "Pociąg odjeżdża o szóstej czterdzieści.", true
        ),
        (
            "N3", "pociąg odjeżdża o szóstej trzydzieści to znaczy o szóstej czterdzieści", "Pociąg odjeżdża o 6:30.",
            false
        ),
        ("N4", "budżet wynosi tysiąc to znaczy tysiąc pięćset złotych", "Budżet wynosi 1500 złotych.", true),
        ("N5", "budżet wynosi tysiąc to znaczy tysiąc pięćset złotych", "Budżet wynosi 1 500 złotych.", true),
        ("N6", "budżet wynosi tysiąc to znaczy tysiąc pięćset złotych", "Budżet wynosi 1,500 złotych.", true),
        ("N7", "budżet wynosi tysiąc to znaczy tysiąc pięćset złotych", "Budżet wynosi 1.500 złotych.", true),
        ("N8", "budżet wynosi tysiąc to znaczy tysiąc pięćset złotych", "Budżet wynosi 1000 złotych.", false),
        ("N9", "budżet wynosi tysiąc to znaczy półtora tysiąca złotych", "Budżet wynosi 1500 złotych.", true),
        ("N10", "budżet wynosi tysiąc to znaczy półtora tysiąca złotych", "Budżet wynosi 1,5 tys. złotych.", true),
        ("N11", "czekamy godzinę nie czekaj pół godziny", "Czekamy pół godziny.", true),
        ("N12", "czekamy godzinę nie czekaj pół godziny", "Czekamy 30 minut.", false),
        ("N13", "spotkanie jest piętnastego nie czekaj szesnastego marca", "Spotkanie jest 16 marca.", true),
        ("N14", "spotkanie jest piętnastego nie czekaj szesnastego marca", "Spotkanie jest 15 marca.", false),
        ("N15", "termin to dwudziestego nie czekaj dwudziestego pierwszego maja", "Termin to 21 maja.", true),
        ("N16", "termin to dwudziestego nie czekaj dwudziestego pierwszego maja", "Termin to 20 maja.", false),
        ("N17", "termin to dwudziestego nie czekaj dwudziestego pierwszego maja", "Termin to 21. maja.", true),
        ("N18", "spotkajmy się o piętnastej nie czekaj o szesnastej", "Spotkajmy się o 16:00.", true),
        ("N19", "spotkajmy się o piętnastej nie czekaj o szesnastej", "Spotkajmy się o 15:00.", false),
        ("N20", "spotkajmy się o piętnastej nie czekaj o szesnastej", "Spotkajmy się o 16.00.", true),
        (
            "N21", "the invoice is one hundred and five dollars sorry one hundred and fifty dollars",
            "The invoice is 150 dollars.", true
        ),
        (
            "N22", "the invoice is one hundred and five dollars sorry one hundred and fifty dollars",
            "The invoice is $150.", true
        ),
        ("N23", "we start on the twenty-first I mean the twenty-second", "We start on the 22nd.", true),
        ("N24", "we start on the twenty-first I mean the twenty-second", "We start on the 21st.", false),
        (
            "N25", "the budget is twenty five thousand sorry thirty thousand dollars", "The budget is 30,000 dollars.",
            true
        ),
        ("N26", "the budget is twenty five thousand sorry thirty thousand dollars", "The budget is $30,000.", true),
        (
            "N27", "the budget is twenty five thousand sorry thirty thousand dollars", "The budget is 25,000 dollars.",
            false
        ),
        ("N28", "zamów pięć tysięcy sztuk nie czekaj dwa tysiące sztuk", "Zamów 2000 sztuk.", true),
        ("N29", "zamów pięć tysięcy sztuk nie czekaj dwa tysiące sztuk", "Zamów 2 tys. sztuk.", true),
        ("N30", "zamów pięć tysięcy sztuk nie czekaj dwa tysiące sztuk", "Zamów 5000 sztuk.", false),
        ("N31", "the meeting is at six forty sorry at seven", "The meeting is at 7.", true),
        ("N32", "the meeting is at six forty sorry at seven", "The meeting is at 7:00.", true),
        ("N33", "the meeting is at six forty sorry at seven", "The meeting is at 6:40.", false),
        ("N34", "spotkanie o szóstej czterdzieści nie czekaj o siódmej", "Spotkanie o 7:00.", true),
        ("N35", "spotkanie o szóstej czterdzieści nie czekaj o siódmej", "Spotkanie o siódmej.", true),
        ("N36", "zamów dwie pizze nie czekaj trzy pizze z szynką", "Zamów trzy pizze z szynką.", true),
        ("N37", "the year is twenty twenty four sorry twenty twenty five", "The year is 2025.", true),
        ("N38", "kupujemy pierwszego nie czekaj drugiego", "Kupujemy 2.", true),
        ("N39", "kupujemy pierwszego nie czekaj drugiego", "Kupujemy 2-go.", true),
        ("F1", "spotkajmy się we wtorek nie czekaj w środę", "Spotkajmy się w środę.", true),
        ("F2", "send it to Mark no wait to Steven", "Send it to Steven.", true),
        ("F3", "send it to Mark no wait to Steven", "Send it to Stephen.", true),
        ("F4", "wyślij to do Kasi nie czekaj do Marty", "Wyślij to do Marty.", true),
        ("F5", "wyślij to do kasi nie czekaj do marty yyy", "Wyślij to do Marty.", true),
        ("F6", "we need fifty units sorry sixty units actually", "We need 60 units.", true),
        ("F7", "zamów dwie pizze nie czekaj trzy pizze jednak", "Zamów trzy pizze.", true),
        (
            "F8", "actually I think we should move the meeting to thursday because the client cannot join on monday",
            "I think we should move the meeting to Thursday because the client can't join on Monday.", true
        ),
        (
            "F9", "actually I think we should move the meeting to thursday because the client cannot join on monday",
            "Actually, I think we should move the meeting to Thursday, because the client cannot join on Monday.", true
        ),
        ("F10", "jednak wolę zostać w domu i poczytać książkę", "Jednak wolę zostać w domu i poczytać książkę.", true),
        (
            "F11", "sorry I am late the traffic was terrible today", "Sorry, I'm late. The traffic was terrible today.",
            true
        ),
        (
            "F12", "przepraszam za spóźnienie korki były dzisiaj okropne",
            "Przepraszam za spóźnienie, korki były dzisiaj okropne.", true
        ),
        (
            "F13", "wait for me at the station near the main entrance",
            "Wait for me at the station near the main entrance.", true
        ),
        (
            "F14", "I mean business and I will not accept any delay", "I mean business and I won't accept any delay.",
            true
        ),
        (
            "F15", "właściwie to nie wiem czy zdążę na spotkanie o piętnastej",
            "Właściwie to nie wiem, czy zdążę na spotkanie o 15:00.", true
        ),
        (
            "F16", "właściwie to nie wiem czy zdążę na spotkanie o piętnastej",
            "Właściwie nie wiem, czy zdążę na spotkanie o 15.", true
        ),
        ("F17", "zadzwoń do Ani nie czekaj do Hanny w sprawie faktury", "Zadzwoń do Hanny w sprawie faktury.", true),
        (
            "F18", "zadzwoń do Ani nie czekaj do Hanny w sprawie faktury", "Zadzwoń do Hanny w sprawie faktury VAT.",
            false
        ),
        (
            "F19", "the meeting is at ten I mean eleven in the main room",
            "The meeting is at 11 a.m. in the main room.", true
        ),
        (
            "F20", "the meeting is at ten I mean eleven in the main room",
            "The meeting is at eleven o'clock in the main room.", true
        ),
        (
            "F21", "spotkanie jest w sali A nie czekaj w sali B na pierwszym piętrze",
            "Spotkanie jest w sali B na pierwszym piętrze.", true
        ),
        (
            "F22", "spotkanie jest w sali A nie czekaj w sali B na pierwszym piętrze",
            "Spotkanie jest w sali B na 1. piętrze.", true
        ),
        (
            "F23", "um so we will deploy on friday sorry on monday after the review",
            "We will deploy on Monday after the review.", true
        ),
        ("F24", "nie czekaj na mnie z kolacją wrócę późno", "Nie czekaj na mnie z kolacją, wrócę późno.", true),
        ("F25", "ok to znaczy że wszystko działa", "OK, to znaczy, że wszystko działa.", true),
        ("F26", "ok to znaczy że wszystko działa", "Okej, to znaczy, że wszystko działa.", true),

    ]

    /// Round 3 probes: 40 to 60 word chunks (A: correct cleanups; B: lost final version or content).
    static let round3: [Row] = {
        var rows: [Row] = []
        func p(_ id: String, _ family: String, _ input: String, _ output: String, _ expected: String) {
            rows.append((id, input, output, expected.hasPrefix("accept")))
        }
        // Polish base (33 words) and English base (45 words), no marker, no filler.
        let pl =
            "ostatnio dużo pracujemy nad nowym modułem raportów i musimy dopracować wiele drobnych szczegółów zanim pokażemy go klientowi na spotkaniu w przyszłym tygodniu więc proszę żeby każdy przejrzał swoje zadania"
        let plOut =
            "Ostatnio dużo pracujemy nad nowym modułem raportów i musimy dopracować wiele drobnych szczegółów, zanim pokażemy go klientowi na spotkaniu w przyszłym tygodniu, więc proszę, żeby każdy przejrzał swoje zadania."
        let en =
            "we went through the whole list of open issues before the release because some of them are blocking the client and their team needs a clear answer from us by the end of the week otherwise they will escalate it to their management"
        let enOut =
            "We went through the whole list of open issues before the release, because some of them are blocking the client, and their team needs a clear answer from us by the end of the week. Otherwise, they will escalate it to their management."

        // ---------- A: ordinary correct outputs, no retraction ----------
        p(
            "A1", "punctuation only", pl + " i dać znać do piątku czy coś jeszcze blokuje prace",
            plOut + " I dać znać do piątku, czy coś jeszcze blokuje prace.", "accept")
        p("A2", "punctuation only", en, enOut, "accept")
        p("A3", "1 contraction", en, enOut.replacingOccurrences(of: "they will", with: "they'll"), "accept")
        let en3 =
            "we are going through the whole list of open issues before the release because it is blocking the client and their team needs a clear answer from us by the end of the week otherwise they will escalate it to their management"
        let en3Out =
            "We're going through the whole list of open issues before the release, because it's blocking the client, and their team needs a clear answer from us by the end of the week. Otherwise, they'll escalate it to their management."
        p("A4", "3 contractions", en3, en3Out, "accept")
        let en5 =
            "we are going through the whole list of open issues before the release because it is blocking the client and they are waiting for a clear answer from us by the end of the week otherwise they will escalate it and we do not want that"
        let en5Out =
            "We're going through the whole list of open issues before the release, because it's blocking the client, and they're waiting for a clear answer from us by the end of the week. Otherwise, they'll escalate it, and we don't want that."
        p("A5", "5 contractions", en5, en5Out, "accept")
        let plAsr2 = pl.replacingOccurrences(of: "żeby", with: "rzeby").replacingOccurrences(of: "dużo", with: "durzo")
        p("A6", "2 recognition fixes", plAsr2 + " i dać znać do piątku", plOut + " I dać znać do piątku.", "accept")
        let plAsr4 =
            plAsr2.replacingOccurrences(of: "wiele", with: "wiele").replacingOccurrences(
                of: "klientowi", with: "klijentowi"
            ).replacingOccurrences(of: "może", with: "morze") + " bo może coś jeszcze blokuje prace"
        p(
            "A7", "3 recognition fixes", plAsr4.replacingOccurrences(of: "bo może", with: "bo morze"),
            plOut.dropLast() + ", bo może coś jeszcze blokuje prace.", "accept")
        p(
            "A8", "leading particle 'no' dropped", "no to " + pl,
            "To " + plOut.prefix(1).lowercased() + plOut.dropFirst(), "accept")
        p("A9", "trailing particle 'no' dropped", pl + " no", plOut, "accept")
        p("A10", "trailing 'nie?' tag dropped", pl + " nie", plOut, "accept?")
        p(
            "A11", "ends 'okay' -> 'OK'", en + " so let me know if that works for you okay",
            enOut + " So let me know if that works for you, OK?", "accept")
        p(
            "A12", "ends 'procent' -> '%'", pl + " bo liczba zgłoszeń wzrosła o piętnaście procent",
            plOut.dropLast() + ", bo liczba zgłoszeń wzrosła o 15%.", "accept")
        p(
            "A13", "ends 'percent' -> '%'", en + " because the number of tickets went up by fifteen percent",
            enOut.dropLast() + " because the number of tickets went up by 15%.", "accept")
        p(
            "A14", "ends 'złotych' -> 'zł'", pl + " a licencja kosztuje dwieście złotych",
            plOut.dropLast() + ", a licencja kosztuje 200 zł.", "accept")
        p(
            "A15", "ends 'wpół do ósmej' -> '7:30'", pl + " a spotkanie zaczyna się o wpół do ósmej",
            plOut + " Spotkanie zaczyna się o 7:30.", "accept")
        p(
            "A16", "ends 'twenty twenty six' -> 2026", en + " and the contract runs until twenty twenty six",
            enOut.dropLast() + ", and the contract runs until 2026.", "accept")
        p(
            "A17", "last word recognition fix", en + " so please call me back when you khan",
            enOut + " So please call me back when you can.", "accept")
        p(
            "A18", "date at end", pl + " najpóźniej do piętnastego marca",
            plOut.dropLast() + " najpóźniej do 15 marca.", "accept")
        p(
            "A19", "digits mid-chunk",
            "w dwa tysiące dwudziestym szóstym roku chcemy wydać sto dwadzieścia pięć tysięcy złotych na serwery i dwadzieścia procent tej kwoty na szkolenia a spotkanie w tej sprawie będzie o szesnastej trzydzieści w sali na drugim piętrze obok kuchni więc proszę przygotować liczby",
            "W 2026 roku chcemy wydać 125 000 złotych na serwery i 20 procent tej kwoty na szkolenia, a spotkanie w tej sprawie będzie o 16:30 w sali na 2. piętrze obok kuchni, więc proszę przygotować liczby.",
            "accept")
        p(
            "A20", "'półtorej godziny' -> '1,5 godziny'",
            pl + " a samo spotkanie potrwa półtorej godziny i odbędzie się w sali obok",
            plOut + " Samo spotkanie potrwa 1,5 godziny i odbędzie się w sali obok.", "accept")
        p(
            "A21", "list 'first second'",
            "there are two things to check first the login page and second the export to the spreadsheet because both of them failed yesterday on the staging server and the client noticed it during the demo so we need to fix them before friday",
            "There are two things to check:\n1. The login page\n2. The export to the spreadsheet\nBecause both of them failed yesterday on the staging server and the client noticed it during the demo, we need to fix them before Friday.",
            "accept")
        p(
            "A22", "hesitations yyy x3",
            "yyy "
                + pl.replacingOccurrences(of: "musimy", with: "yyy musimy").replacingOccurrences(
                    of: "więc", with: "eee więc"), plOut, "accept")
        p(
            "A23", "two 'like' fillers dropped",
            "the build was like really slow yesterday and the tests were like timing out all the time so we restarted the runner twice and then it worked but we still do not know why it happened and we should look at the logs tomorrow morning",
            "The build was really slow yesterday and the tests were timing out all the time, so we restarted the runner twice and then it worked, but we still do not know why it happened, and we should look at the logs tomorrow morning.",
            "accept")
        // content markers (no retraction) followed by an ordinary cleanup
        p(
            "A24", "content 'actually' early, 'just' dropped later",
            "it is actually a small change we just need to rename the field in the export and update the two reports that use it and then run the whole test suite again before we send the new build to the client on thursday afternoon",
            "It is actually a small change. We need to rename the field in the export and update the two reports that use it, and then run the whole test suite again before we send the new build to the client on Thursday afternoon.",
            "accept")
        p(
            "A25", "content 'actually' early, 1 contraction later",
            "it is actually a small change we need to rename the field in the export and update the two reports that use it and then we will run the whole test suite again before we send the new build to the client on thursday",
            "It is actually a small change. We need to rename the field in the export and update the two reports that use it, and then we'll run the whole test suite again before we send the new build to the client on Thursday.",
            "accept")
        p(
            "A26", "content 'sorry' at start, contraction",
            "sorry I could not join the call this morning I was at the doctor so please send me the notes and I will go through them tonight and answer all the questions about the budget and the new hires before tomorrow",
            "Sorry, I couldn't join the call this morning, I was at the doctor, so please send me the notes and I'll go through them tonight and answer all the questions about the budget and the new hires before tomorrow.",
            "accept")
        p(
            "A27", "content 'to znaczy' explanation, particle 'no' dropped later",
            "ten moduł jest gotowy to znaczy przeszedł wszystkie testy i recenzję no i możemy go wdrożyć w czwartek po południu kiedy ruch jest najmniejszy a jeśli coś pójdzie nie tak to mamy plan wycofania i kopię bazy z rana",
            "Ten moduł jest gotowy, to znaczy przeszedł wszystkie testy i recenzję, i możemy go wdrożyć w czwartek po południu, kiedy ruch jest najmniejszy, a jeśli coś pójdzie nie tak, to mamy plan wycofania i kopię bazy z rana.",
            "accept")
        p(
            "A28", "content 'jednak' mid, filler 'jakby' dropped",
            pl + " jednak to jest jakby ważne żeby nikt nie odkładał tego na ostatnią chwilę",
            plOut + " Jednak to jest ważne, żeby nikt nie odkładał tego na ostatnią chwilę.", "accept")
        p(
            "A29", "content 'właściwie' mid, punctuation only", pl + " właściwie to wszystko co mam na dziś dziękuję",
            plOut + " Właściwie to wszystko, co mam na dziś, dziękuję.", "accept")
        p(
            "A30", "content 'I mean' mid, contraction later",
            en + " I mean it is not a big deal but we should not ignore it",
            enOut + " I mean, it's not a big deal, but we shouldn't ignore it.", "accept")
        p("A31", "content 'właściwie to' hedge dropped", "właściwie to " + pl, plOut, "accept?")
        p(
            "A32", "early 'przepraszam' apology then a real retraction",
            "przepraszam za spóźnienie zamów dwie pizze nie czekaj trzy pizze dla zespołu na dzisiejsze spotkanie o piętnastej",
            "Przepraszam za spóźnienie. Zamów trzy pizze dla zespołu na dzisiejsze spotkanie o 15:00.", "accept")
        p(
            "A33", "number + 'tysiąca'", "limit wynosi do pięciuset to znaczy do tysiąca złotych na osobę",
            "Limit wynosi do 1000 złotych na osobę.", "accept")

        // ---------- B: lost final version / lost content ----------
        p(
            "B1", "withdrawn person in another form (Tomka->Tomasza), final lost",
            "wyślij raport do Tomka nie czekaj do Adama jeszcze dziś", "Wyślij raport do Tomasza jeszcze dziś.",
            "reject")
        p(
            "B2", "withdrawn person in another form (Kate->Katie), final lost",
            "send the report to Kate no wait to Mark today", "Send the report to Katie today.", "reject")
        p(
            "B3", "withdrawn person in another form (Oli->Olki), final lost",
            "napisz do Oli nie czekaj do Ewy w sprawie urlopu", "Napisz do Olki w sprawie urlopu.", "reject")
        p(
            "B4", "B1 inside a 40-word chunk", pl + " wyślij raport do Tomka nie czekaj do Adama jeszcze dziś",
            plOut + " Wyślij raport do Tomasza jeszcze dziś.", "reject")
        p(
            "B5", "final name replaced by an invented name", "wyślij raport do Kasi nie czekaj do Marka jeszcze dziś",
            "Wyślij raport do Tomka jeszcze dziś.", "reject")
        p(
            "B6", "unlisted marker 'znaczy' mid long chunk, withdrawn kept",
            pl + " przesuń spotkanie na wtorek znaczy na środę o piętnastej w dużej sali",
            plOut + " Przesuń spotkanie na wtorek o piętnastej w dużej sali.", "reject")
        p(
            "B7", "unlisted marker 'or rather' mid long chunk, withdrawn kept",
            en + " and move the review to monday or rather to tuesday at noon in the big room",
            enOut.dropLast() + ", and move the review to Monday at noon in the big room.", "reject")
        p(
            "B8", "unlisted 'a nie' mid long chunk, withdrawn kept",
            pl + " spotkanie jest we wtorek a nie w środę o piętnastej w dużej sali",
            plOut + " Spotkanie jest we wtorek o piętnastej w dużej sali.", "reject")
        p(
            "B9", "unlisted 'poprawka' mid long chunk, withdrawn kept",
            pl + " zamów dwadzieścia krzeseł poprawka trzydzieści krzeseł do dużej sali na jutro",
            plOut + " Zamów 20 krzeseł do dużej sali na jutro.", "reject")
        p(
            "B10", "unlisted 'correction' mid long chunk, withdrawn kept",
            en + " and order twenty chairs correction thirty chairs for the big room tomorrow",
            enOut.dropLast() + ", and order 20 chairs for the big room tomorrow.", "reject")
        p(
            "B11", "no-marker long chunk: negation dropped", pl + " i nie wysyłać niczego klientowi bez mojej zgody",
            plOut + " I wysyłać niczego klientowi bez mojej zgody.", "reject")
        p(
            "B12", "no-marker long chunk: number changed mid-chunk",
            "spotkanie z klientem będzie o piętnastej w dużej sali " + pl,
            "Spotkanie z klientem będzie o 16:00 w dużej sali. " + plOut, "reject")
        p(
            "B13", "content 'właściwie' mid long chunk: 6 words before it deleted",
            pl + " ten nowy moduł raportów jest dla nas właściwie najważniejszy w tym kwartale",
            plOut + " Jest właściwie najważniejszy w tym kwartale.", "reject")
        p(
            "B14", "no-marker long chunk: 5 middle words deleted",
            pl + " i dać znać do piątku czy coś jeszcze blokuje prace",
            plOut.replacingOccurrences(of: "na spotkaniu w przyszłym tygodniu", with: "")
                + " I dać znać do piątku, czy coś jeszcze blokuje prace.", "reject")
        p(
            "B15", "early content 'sorry' then real retraction: withdrawn kept",
            "sorry for the delay please order two pizzas no wait three pizzas for the team meeting at three",
            "Sorry for the delay, please order two pizzas for the team meeting at three.", "reject")
        p(
            "B16", "early content 'właściwie' then real retraction: withdrawn kept",
            "to jest właściwie proste zamów dwie pizze nie czekaj trzy pizze dla zespołu",
            "To jest właściwie proste: zamów dwie pizze dla zespołu.", "reject")
        p(
            "B17", "first marker real, final version swapped by unsaid word in tail",
            "zamów pizzę z szynką nie czekaj z pieczarkami i colę", "Zamów pizzę z ananasem i colę.", "reject")
        p(
            "B18", "tail word replaced by a withdrawn word's diminutive (Kasi->Kaśki)",
            "wyślij raport do Kasi nie czekaj do Marka jeszcze dziś", "Wyślij raport do Kaśki jeszcze dziś.", "reject")
        p(
            "B19", "stutter inside tail (prefix word) dropped", "zamów dwie pizze nie czekaj pizze pizzerii obok",
            "Zamów pizzerii obok.", "reject")
        p(
            "B20", "number word final changed to another number via 'tysiąca' gap",
            "limit wynosi do pięciuset to znaczy do tysiąca złotych na osobę", "Limit wynosi do 500 złotych na osobę.",
            "reject")

        return rows
    }()

    /// Review round 3 probes (58, all invented): a dropped marker with both versions kept (M), an unsaid word in
    /// the replacement (S, P), units and negations at the end (E, C), dropped fillers (D). Rows C1, C2, E4 and E5
    /// have no marker, so they follow the length-and-language check of `main`.
    static let round4: [Row] = [
        (
            "VR1a", "wyślij raport do Tomka nie czekaj do Adama jeszcze dziś", "Wyślij raport do Tomasza jeszcze dziś.",
            false
        ),
        ("VR1b", "send the report to Kate no wait to Mark today", "Send the report to Katie today.", false),
        ("VR1c", "napisz do Oli nie czekaj do Ewy w sprawie urlopu", "Napisz do Olki w sprawie urlopu.", false),
        (
            "VR1d", "wyślij raport do Kasi nie czekaj do Marka jeszcze dziś", "Wyślij raport do Tomka jeszcze dziś.",
            false
        ),
        (
            "VR1e", "wyślij raport do Kasi nie czekaj do Marka jeszcze dziś", "Wyślij raport do Kaśki jeszcze dziś.",
            false
        ),
        ("VR1f", "zamów pizzę z szynką nie czekaj z pieczarkami i colę", "Zamów pizzę z ananasem i colę.", false),
        ("VR1g", "send it to Mark no wait to Steven and Paul today", "Send it to Zebra and Paul today.", false),
        ("VR2a", "spotkajmy się we wtorek a nie czekaj w środę", "Spotkajmy się we wtorek, a nie w środę.", false),
        ("VR2b", "pójdziemy na pizzę albo jednak na sushi", "Pójdziemy na pizzę albo na sushi.", false),
        (
            "VR2c", "przełóżmy spotkanie na piątek albo jednak na poniedziałek",
            "Przełóżmy spotkanie na piątek albo na poniedziałek.", false
        ),
        ("VR2d", "kupimy czerwoną sofę albo jednak szarą sofę", "Kupimy czerwoną sofę albo szarą sofę.", false),
        (
            "VR2e", "użyjemy chmury albo jednak zostaniemy przy własnym serwerze",
            "Użyjemy chmury albo zostaniemy przy własnym serwerze.", false
        ),
        (
            "VR2f", "wyślę to mailem albo jednak zadzwonię do klienta", "Wyślę to mailem albo zadzwonię do klienta.",
            false
        ),
        ("VS1", "wyślij to do Marka nie czekaj do Kasi", "Wyślij to do Basi.", false),
        ("VS2", "zadzwoń do Tomka przepraszam do Marka", "Zadzwoń do Mirka.", false),
        ("VS3", "send it to Mark no wait to Kate", "Send it to Nate.", false),
        ("VS4", "call Anna sorry call Jim tomorrow", "Call Tim tomorrow.", false),
        ("VS5", "napisz do Ewy nie czekaj do Uli w sprawie urlopu", "Napisz do Ali w sprawie urlopu.", false),
        ("VS6", "zrób to przed obiadem nie czekaj zrób to do południa", "Zrób to po południu.", false),
        ("VS7", "spotkajmy się w poniedziałek przepraszam za tydzień", "Spotkajmy się na tydzień.", false),
        ("VS8", "put it under the desk sorry in the drawer", "Put it on the drawer.", false),
        ("VS9", "przyjdę o dziesiątej nie czekaj przyjdę po dziesiątej", "Przyjdę do dziesiątej.", false),
        ("VS10", "the price is fifty dollars sorry sixty dollars", "The price is 60 euros.", false),
        ("VS11", "send it to Mark no wait to Steven", "Send it to Stephen.", true),
        ("VS12", "napisz do Marka nie czekaj do Tomka", "Napisz do Tomka.", true),
        ("VP1", "send it to Mark no wait to Steven", "Send it to O'Neil.", false),
        (
            "VP2", "tell the client he can join on friday sorry he can join on monday",
            "Tell the client he can't join on Monday.", false
        ),
        ("VP3", "the server is down wait the server is up", "The server isn't up.", false),
        ("VP4", "napisz do Marka nie czekaj do Tomka", "Napisz do O'Briena.", false),
        ("VP5", "invite Anna wait invite Mark he will come", "Invite Mark, he won't come.", false),
        ("VP6", "actually I think the client cannot join on monday", "I think the client can't join on Monday.", true),
        (
            "VM1", "wyślę to mailem do klienta albo jednak zadzwonię do klienta",
            "Wyślę to mailem albo zadzwonię do klienta.", false
        ),
        (
            "VM2", "spotkajmy się we wtorek o dziesiątej a nie czekaj w środę o dziesiątej",
            "Spotkajmy się we wtorek, a nie w środę o 10.", false
        ),
        (
            "VM3", "przełóżmy spotkanie na piątek rano albo jednak na poniedziałek rano",
            "Przełóżmy spotkanie na piątek albo na poniedziałek rano.", false
        ),
        (
            "VM4", "we will use the cloud server or actually our own server",
            "We will use the cloud or our own server.", false
        ),
        (
            "VM5", "meet me on tuesday at noon no wait on wednesday at noon",
            "Meet me on Tuesday, not on Wednesday at noon.", false
        ),
        ("VM6", "kupimy czerwoną sofę albo jednak szarą sofę", "Kupimy czerwoną albo szarą sofę.", false),
        (
            "VM7", "spotkajmy się we wtorek a nie czekaj w środę", "Spotkajmy się we wtorek, czekaj, a nie w środę.",
            false
        ),
        ("VM8", "zamów dwie pizze albo jednak trzy pizze", "Zamów 2 albo 3 pizze.", false),
        (
            "VM9", "wyślę to mailem do klienta albo jednak zadzwonię do klienta",
            "Wyślę to mailem do klienta albo jednak zadzwonię do klienta.", true
        ),
        ("VM10", "wyślę to mailem do klienta albo jednak zadzwonię do klienta", "Zadzwonię do klienta.", true),
        (
            "VE1", "budżet wzrośnie o piętnaście procent nie czekaj o dwadzieścia procent", "Budżet wzrośnie o 15%.",
            false
        ),
        ("VE2", "bilet kosztuje dwieście euro przepraszam dwieście złotych", "Bilet kosztuje 200 euro.", false),
        (
            "VE3", "czy wysyłamy raport klientowi dzisiaj wiesz co jednak nie", "Wysyłamy raport klientowi dzisiaj.",
            false
        ),
        ("VE4", "ten bilet kosztuje dwieście euro", "Ten bilet kosztuje 200 zł.", false),
        ("VE5", "podwyżka wyniesie piętnaście procent", "Podwyżka wyniesie 15 zł.", false),
        ("VE6", "the invoice is two hundred dollars okay", "The invoice is $200, OK?", true),
        ("VC1", "we will not ship it on friday", "We'll ship it on Friday.", false),
        ("VC2", "nie wysyłaj tego klientowi przed piątkiem", "Wysyłaj to klientowi przed piątkiem.", false),
        ("VC3", "send it on monday sorry we will not send it on monday", "We'll send it on Monday.", false),
        (
            "VC4", "we are sure it is not ready and we do not want it",
            "We're sure it isn't ready, and we don't want it.", true
        ),
        (
            "VD1", "move it to monday or rather to tuesday at noon in the big room",
            "Move it to Monday at noon in the big room.", false
        ),
        (
            "VD2", "przenieśmy to na wtorek znaczy na środę o piętnastej w dużej sali",
            "Przenieśmy to na wtorek o 15:00 w dużej sali.", false
        ),
        (
            "VD3", "the build was kind of slow yesterday so we restarted it",
            "The build was slow yesterday, so we restarted it.", true
        ),
        ("VD4", "no to wyślij mi ten plik jeszcze dziś", "Wyślij mi ten plik jeszcze dziś.", true),
    ]

    /// Review round 4 probes (all invented): a marker that opens the chunk dropped (WB; the withdrawn version
    /// may be in the previous chunk, or the marker word is content), digits regrouped into another number (WD),
    /// fillers, contractions, several markers and a kept marker with the rest swapped (WF, WC, WM, WK).
    static let round5: [Row] = [
        ("WB1", "sorry on monday at noon in the small room", "On Monday at noon in the small room.", false),
        ("WB2", "czekaj w poniedziałek o dziesiątej w małej sali", "W poniedziałek o 10 w małej sali.", false),
        ("WB3", "wait for me at the entrance at eight", "For me at the entrance at 8.", false),
        ("WB4", "um sorry for the late reply i was travelling", "For the late reply, I was travelling.", false),
        ("WB5", "przepraszam za spóźnienie korki były straszne", "Za spóźnienie, korki były straszne.", false),
        ("WB6", "um sorry for the late reply i was travelling", "Sorry for the late reply, I was travelling.", true),
        (
            "WD1", "the budget is one hundred dollars sorry two hundred dollars", "The budget is 2,100 dollars.",
            false
        ),
        ("WD2", "the budget is one hundred dollars sorry two hundred dollars", "The budget is 200 dollars.", true),
        (
            "WD3", "zbierzmy dwadzieścia pięć tysięcy czekaj trzydzieści tysięcy złotych", "Zbierzmy 30 000 złotych.",
            true
        ),
        ("WD4", "przyjdę o dziewiątej sorry o dziesiątej trzydzieści", "Przyjdę o 10:30.", true),
        ("WF1", "wyślij to jutro czekaj nie wysyłaj tego wcale", "Wysyłaj tego wcale.", false),
        ("WF2", "tell them yes sorry tell them no", "Tell them.", false),
        ("WF3", "i just want tea sorry i just want coffee", "I want coffee.", false),
        ("WC1", "we can not do it on friday sorry we can not do it on monday", "We can't do it on Monday.", true),
        ("WC2", "we can not do it on friday sorry we can not do it on monday", "We can do it on Monday.", false),
        ("WC3", "it is not ready actually it is ready", "It isn't ready.", false),
        ("WC4", "he has not paid sorry he has paid", "He's paid.", true),
        (
            "WM1", "wyślij to w piątek czekaj w poniedziałek sorry we wtorek",
            "Wyślij to w piątek, czekaj, w poniedziałek we wtorek.", false
        ),
        (
            "WM2", "wyślij to w piątek czekaj w poniedziałek sorry we wtorek",
            "Wyślij to w poniedziałek, sorry, we wtorek.", true
        ),
        (
            "WM3", "wyślij to w piątek czekaj w poniedziałek sorry we wtorek", "Wyślij to w poniedziałek we wtorek.",
            false
        ),
        ("WK1", "send it to anna sorry to mark today", "Send it to Kate, sorry, to Mark today.", false),
    ]
}
