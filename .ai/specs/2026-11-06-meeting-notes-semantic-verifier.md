# Semantyczna weryfikacja punktów notatek (zamiast reguł tekstowych)

Powiązane: `2026-11-03-meeting-notes.md` (potok MAP → NotesGuard → REDUCE), `2026-11-06-meeting-speaker-names.md`. Spec napisany w trybie autonomicznym: pytania bramki rozstrzygnięte domyślnymi, odwracalnymi odpowiedziami z sekcji „Resolved assumptions”; właściciel może je zmienić.

## 📝 TLDR
Osoba czytająca notatki dostaje dziś w większości surowe cytaty zamiast zwięzłych punktów: strażnik wierności podmienia tekst modelu na fragment transkryptu w około 70% punktów, a jednocześnie nie widzi odwróceń sensu (pewność, status). Proponowane przyszłe zachowanie: reguły tekstowe `driftedFromQuote`, `unsupportedDetail` i `negationChanged` przestają automatycznie podmieniać tekst; zamiast tego drugi, krótki przebieg modelu ocenia, czy punkt wynika z cytatu, a podmiana na cytat następuje tylko, gdy ocena jest negatywna. Twarde sprawdzenia (cytat jest w transkrypcie, język, osoba i termin zadania) zostają bez zmian.

## 📝 Problem Statement (zmierzone)
- Ślad (`ovn-names-a/b`, `ovn-ctrl-a`): 35 z 52, 61 z 87 i 46 z 81 punktów naprawionych (podmienionych na cytat); powody: `unsupportedDetail`, `driftedFromQuote`, `negationChanged`. Sędziowie dają strukturze i zwięzłości 2 z 5 („I'll put a link.” jako punkt).
- Audyt (`Pounce-eval-archive/results/oracle2/GUARD-AUDIT.md`, 60 punktów z trzech przebiegów jednego spotkania, jeden oceniający, uzgodnienie 8/10): z 30 naprawionych 57% to były poprawne parafrazy (fałszywa naprawa), 40% drobne odchylenia, 1 z 30 faktyczny błąd; spośród 30 punktów zachowanych 23% to MINOR lub WRONG (7% WRONG, np. „pracuje nad” zamienione na „działa”). Żadna reguła nie łapie zmiany statusu lub pewności.
- Udział tekstu modelu w notatkach: dziś ok. 22% punktów, szacunek z weryfikatorem 66–71%.
- Ograniczenia pomiaru: jedno spotkanie (angielskie), 51 unikalnych tekstów w próbie, przedziały ufności szerokie, ocena tym samym typem modelu co sędziowie.

## 📝 Proposed Solution
1. `NotesVerifier` (protokół, wejście: punkt z tekstem i cytatem plus ±2 sąsiednie wypowiedzi jako kontekst; wyjście: `supported` / `weaker` / `unsupported`). Realizacja `LLMNotesVerifier` korzysta z tego samego `LLMRuntime` co MAP (bez ładowania drugiego modelu), dekodowanie zachłanne, krótka odpowiedź w ustalonym formacie.
2. Zmiana `NotesGuard`: punkt, który reguły tekstowe dziś naprawiają, trafia do weryfikatora; `supported` zachowuje tekst modelu, pozostałe wartości dają dotychczasową podmianę na cytat. Punkty dziś zachowane też idą do weryfikatora, żeby łapać zmiany statusu; `unsupported` daje podmianę na cytat, `weaker` podmianę na cytat (bez odrzucania).
3. Twarde sprawdzenia bez zmian: `quoteNotInTranscript`, `quoteTooShort`, `languageChanged`, sprawdzenie osoby i terminu zadania, `ownerFromSpeaker`.
4. **Fail closed:** każda odpowiedź weryfikatora, której nie da się sparsować, brak modelu, błąd, przekroczony czas lub anulowanie = dotychczasowe zachowanie (podmiana na cytat). Weryfikator nie może pogorszyć wyniku względem stanu obecnego.

Odrzucone: *wyłączenie reguł bez weryfikatora* (nie złapie żadnego odwrócenia sensu, a 7% kept to już WRONG); *drugi, większy model jako weryfikator domyślnie* (osobne ładowanie, pamięć; zostaje jako opcja pomiaru).

## 📝 Architecture
- `Sources/MeetingsPlugin/Notes/`: `NotesVerifier.swift` (protokół, prompt wersjonowany osobno od `NotesPrompt.version`, parser odpowiedzi), integracja w `NotesPipeline` między parsowaniem MAP a składaniem (strażnik dostaje wynik weryfikatora jako dane, `NotesGuard` pozostaje czystą logiką bez I/O).
- Prompt weryfikatora traktuje transkrypt jako dane niezaufane (jak MAP); odpowiedź jest akceptowana tylko w ścisłym formacie, inaczej fail closed. Rezydualne ryzyko: transkrypt mogący wpłynąć na ocenę (już udokumentowane w `NotesGuard`); weryfikator nie zmienia treści punktu, tylko wybiera między tekstem modelu a cytatem.
- Koszt: jedno dodatkowe wywołanie krótkie na punkt lub na paczkę punktów; mierzony czas i liczba tokenów w `NotesTrace` jako liczniki (bez tekstu).
- Brak zmian schematu bazy, ustawień i kontraktów `LintelKit`; `NotesTrace` dostaje liczniki (addytywnie).

## 📝 Edge Cases & Failure Scenarios
- Model weryfikator myli się w obie strony: pomyłka „zbyt łaskawa” zostawia niewierny tekst (mierzone jako odsetek WRONG przepuszczonych); „zbyt surowa” kończy podmianą na cytat (stan dzisiejszy).
- Czas: dla spotkania z ~90 punktami dodatkowe wywołania nie mogą wydłużyć generacji notatek ponad ustalony budżet; po jego przekroczeniu pozostałe punkty idą stara drogą (podmiana).
- Polski: etykiety i reguły fleksji nie są sprawdzone na polskim materiale; osobny pomiar przed włączeniem dla polskich spotkań.
- Anulowanie i `stale` bez zmian.

## 📝 Risks & Impact Review
Zmiana zachowania notatek widoczna dla użytkownika (więcej tekstu modelu, mniej surowych cytatów); to decyzja produktowa wynikająca z audytu, odwracalna (stała w kodzie). Przed włączeniem bramka pomiarowa poniżej. Nie zmienia kontraktów chronionych.

## Resolved assumptions (autonomous defaults)
| Pytanie | Wybór | Uzasadnienie |
|---|---|---|
| Który model weryfikuje? | Ten sam co MAP (bez drugiego ładowania) | Najmniejszy koszt i pamięć; większy model tylko jako eksperyment pomiarowy |
| Czy weryfikować też punkty dziś zachowane? | Tak | Audyt: 23% zachowanych to MINOR/WRONG, tylko weryfikator łapie zmiany statusu |
| Wyłącznik w ustawieniach? | Nie, stała w kodzie | Nowy klucz ustawień byłby trwałym kontraktem |
| Gdzie przechowywać ocenione próbki? | Archiwum eval, nie repozytorium | Zawierają tekst spotkania |

## 📋 Phasing
1. **Faza A — weryfikator i jego pomiar offline** na 60 oznaczonych punktach (bez zmiany potoku).
2. **Faza B — integracja z potokiem** z bramką pomiarową na pełnych przebiegach i sędziach.

## 📋 Implementation Plan

### Faza A
- **A.1** `NotesVerifier` (protokół, prompt, parser w ścisłym formacie, fail closed) z testami parsera i odpowiedzi błędnych (puste, wielosłowne, wstrzyknięcie w odpowiedzi).
- **A.2** Test oceny offline (wyłączony domyślnie, `LINTEL_NOTES_VERIFIER_EVAL_*`): 60 oznaczonych punktów (`Pounce-eval-archive/guard-audit/sample.json` plus oznaczenia F/M/W) przez `LLMNotesVerifier` na Qwen3-4B (i opcjonalnie 30B-A3B). Wynik: macierz pomyłek.
- **A.3 Bramka:** weryfikator przepuszcza (`supported`) co najmniej 70% FAITHFUL i odrzuca co najmniej 2 z 3 WRONG oraz co najmniej połowę MINOR; w przeciwnym razie Faza B nie startuje, wniosek do raportu.

### Faza B (warunkowa)
- **B.1** Integracja z `NotesPipeline` i `NotesGuard` (weryfikator jako dane wejściowe, fail closed), liczniki w `NotesTrace`; istniejące testy strażnika bez zmian.
- **B.2** Pomiar: trzy przebiegi ovn i dwa polskie przed/po, udział tekstu modelu, liczba zweryfikowanych punktów, czas, sędziowie Opus (≥2 na wariant); wynik w PR bez deklaracji „poprawy jakości” ponad zmierzone.
