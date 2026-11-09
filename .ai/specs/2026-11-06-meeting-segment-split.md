# Podział segmentów transkryptu na zmianie mówcy

Powiązane: `2026-11-06-meeting-speaker-quality.md` (pomiar, który uzasadnia ten spec) i `2026-11-06-meeting-speaker-names.md` (nazwy mówców korzystają z lepszych etykiet). Nazwy w kodzie: produkt to Lintel (`LintelSpeech`, `LintelKit`, klucze `plugins.meetings.*`); repozytorium nazywa się Pounce.

## 📝 TLDR
Osoba czytająca transkrypt i notatki widzi jedną etykietę mówcy na cały segment ASR (~15 s), więc krótka wymiana „pytanie, odpowiedź” ląduje pod jednym mówcą; w pomiarze na ovn 15–20% segmentów mieszało osoby (próg 10% przekroczony). Proponowane przyszłe zachowanie: silnik mowy zwraca czasy słów, a po diaryzacji segment, w którym diaryzator widzi zmianę mówcy, jest dzielony w miejscu zmiany i każda część dostaje własną etykietę. Powód: bez tego zadanie zlecone w odpowiedzi trafia do niewłaściwej osoby, a imiona z drugiego specu przypisują się do złych fragmentów.

## 📝 Problem Statement
- Pomiar (`Pounce-eval-archive/diarization-measurement/REPORT.md`, miara widoczna w tekście, nie dokładność diaryzacji): segmenty mieszające osoby ovn 15,2% i 20,0%, polski 5,7% (4,7–23,3% zależnie od 8 niejasnych segmentów). Liczba mówców jest poprawna (9 klastrów i 9–10 osób na ovn), więc problemem jest ziarnistość, nie rozpoznawanie.
- Stan kodu (zweryfikowany): `TranscriptSegment` ma tylko `text` (`Sources/LintelSpeech/AudioPorts.swift`); `ParakeetEngine` zwraca `TranscriptSegment(text: result.text)` i odrzuca `ASRResult.tokenTimings` (`startTime`, `endTime` na token, FluidAudio `AsrTypes.swift`); `meeting_segment` ma `start_ms`, `end_ms`, `text`, `speaker_id`; `SpeakerAssigner.diarized` daje całemu segmentowi mówcę o największym nakładaniu czasu, choć `DiarizedSpan` zna zmiany z dokładnością do ułamków sekundy.

## 📝 Proposed Solution
1. **Czasy słów z silnika.** `TranscriptSegment` dostaje opcjonalne `words: [TimedWord]` (tekst, początek i koniec w ms względem początku segmentu; zmiana addytywna, `init(text:)` zostaje). `ParakeetEngine` składa słowa z `tokenTimings` (tokeny podsłowne łączone w słowa).
2. **Trwałe przechowanie** (decyzja użytkownika, Q2): czasy słów zapisane w zaszyfrowanej bazie razem z segmentem (nowa kolumna), do usunięcia spotkania.
3. **Podział po diaryzacji.** Czysta logika `SegmentSplitter` przypisuje każdemu słowu klaster diaryzatora (największe nakładanie czasu), tworzy odcinki kolejnych słów jednego klastra, odcinki krótsze niż próg scala z sąsiadem (Q3: zachowawczo) i dzieli segment tylko, gdy zostają co najmniej dwa odcinki. Cięcie jest przyciągane do najbliższego końca zdania, jeśli leży w granicach ~1 s (żeby nie rozcinać zdań, bo `NotesGuard` odrzuca cytaty przekraczające zmianę mówcy).
4. **Silnik bez czasów słów** (WhisperKit): `WhisperKitEngine` dziś przekazuje `wordTimestamps: false`, ale WhisperKit czasy słów obsługuje. Faza 3 najpierw próbuje je włączyć (koszt prędkości i dokładności do zmierzenia); dopiero jeśli nie, podział po końcach zdań z czasem proporcjonalnym do liczby znaków. Dotyczy to zwłaszcza polskich spotkań, jeśli `SwitchingEngine` wybiera Whisper z ustalonym językiem.

Odrzucone: *krótsze segmenty VAD przy nagrywaniu* (zmienia jakość ASR, która jest dobra, i nie daje granic zmiany mówcy); *tylko podział po tekście* (granice przesunięte o sekundę lub więcej, krótkie wtrącenia bez interpunkcji nie do uchwycenia); *przechowanie tymczasowe i tylko w pamięci* (rekomendowane, ale użytkownik wybrał trwałe, patrz Decyzje).

## 📝 Architecture
- **`LintelSpeech` (współdzielone z dyktowaniem):** `TimedWord` i `TranscriptSegment.words` addytywnie, domyślnie puste; `ParakeetEngine` wypełnia je z `ASRResult.tokenTimings`. `DictationPlugin` nic nie zmienia i ignoruje pole. Padding w `ParakeetEngine.transcribe` jest dopisywany na końcu i tylko dla wejścia krótszego niż 0,3 s (`ASRConstants.swift`), więc początek czasów tokenów się nie przesuwa; trzeba tylko przyciąć koniec tokenu do rzeczywistej długości próbek. Początek segmentu (`start_ms`) pochodzi z zakresu VAD, któremu odpowiadają dokładnie próbki oddane silnikowi, więc czasy słów względem początku segmentu są spójne z `start_ms` (zweryfikowane: `MeetingSession.accept`, `MeetingResumer.handleRange`). Jeśli FluidAudio ma gotowy łącznik tokenów w słowa (`buildWordTimings(from:)`, `AsrTypes.swift`), używamy go zamiast własnego.
- **`MeetingsPlugin`:**
  - zapis segmentu przekazuje `words` do `MeetingsStore` (kolumna `words_json`). Droga słów: `SegmentOutcome`, `TrackSegment`, bufor `held` z porządkowaniem i `EchoSuppressor` w `MeetingSession`, potem `insertSegment` (nowy parametr). Trzy miejsca wywołania: `MeetingSession.accept`, odtwarzanie `replayOne` i `MeetingResumer.handleRange`; pominięcie ostatniego dałoby spotkania odzyskane bez słów. Reguła spójności: `accept` przycina tekst, a `EchoSuppressor` może go zmienić, więc jeśli słowa po złożeniu nie odtwarzają `text` (z dokładnością do białych znaków), `words` jest odrzucane (NULL) zamiast zapisywane niespójnie.
  - `SegmentSplitter` (czysta logika, w `Diarization/`): wejście `[SegmentWithWords]` i `[AudioChannel: [DiarizedSpan]]`, wyjście `SegmentSplitPlan` (dla każdego dzielonego segmentu: lista odcinków z tekstem, `startMs`, `endMs`, `words`).
  - nowy odczyt `segmentsWithWords(meetingID:)` w `MeetingsStore` (`SegmentRef` nie ma tekstu ani słów, więc nie wystarcza).
  - `MeetingFinalizer` po diaryzacji i przed `SpeakerAssigner.diarized`: zastosuj plan w jednej transakcji (`MeetingsStore.applySegmentSplit`), odczytaj `segmentRefs` ponownie i dopiero wtedy przypisz mówców. Błąd podziału nie przerywa finalizacji: spotkanie zostaje z niepodzielonymi segmentami (log bez tekstu).
- **Reuse:** istniejące wyzwalacze FTS (`meeting_segment_ai/ad/au`) utrzymują indeks przy `UPDATE text` i `INSERT`, więc wyszukiwanie nie wymaga zmian.
- **Granice:** bez nowych zależności; `LintelKit` bez zmian.

## 📝 Data Model
- **Decyzja do właściciela (otwarta):** `BACKWARD_COMPATIBILITY.md` mówi, że `v1-meetings` było rozszerzane w miejscu, dopóki nie wyszło; nie wiemy, czy v1 już trafiło do użytkowników. Jeśli nie, kolumnę dodajemy do `v1-meetings` (bez v2). Jeśli tak, migracja `v2-segment-words` poniżej. Starszy build otwierający nowszy schemat wyłącza funkcję zamiast migrować (`BACKWARD_COMPATIBILITY.md`).
- Migracja addytywna (wariant v2) `v2-segment-words`: `ALTER TABLE meeting_segment ADD COLUMN words_json TEXT NULL` (JSON `[[text, startMs, endMs], …]`, czasy względem początku segmentu; NULL dla silników bez czasów i dla starych spotkań). Kolumna nie jest indeksowana ani w FTS. Stare spotkania bez `words_json` zachowują obecne zachowanie (brak podziału).
- Rozmiar (szacunek do potwierdzenia pomiarem): ~11 tys. słów na 72 min, rząd 200–300 KB na godzinę; spotkania z `retentionDays` (domyślnie 90) są kasowane wraz z kolumną (`ON DELETE CASCADE`), „Erase Data” usuwa całą bazę.
- Dane wrażliwe: czasy słów pochodzą z tekstu i leżą w tej samej bazie SQLCipher; nie trafiają do `NotesTrace`, logów ani `ranking.sqlite`.
- Po podziale kawałek dostaje własny podzbiór słów, więc ponowne uruchomienie (odzyskiwanie po awarii) daje ten sam wynik (idempotencja, test).

## 📝 UI/UX
Bez nowych elementów. Okno spotkania pokazuje więcej, krótszych wierszy, z własnym mówcą i czasem; zmiana nazwy mówcy działa jak dziś. Dostępność bez zmian.

## 📝 Edge Cases & Failure Scenarios
- **Brak `tokenTimings`** (`nil`, pusta tablica, inny silnik): `words` puste, segment nietknięty (faza 3 dodaje zapas).
- **Nakładająca się mowa:** słowo dostaje klaster o największym nakładaniu; remis idzie do wcześniejszego klastra (jak w `SpeakerAssigner`).
- **Krótkie wtrącenia** („yeah”, „ok”) poniżej progu (start: 1,5 s lub 3 słowa, do strojenia na pomiarze): scalone z sąsiadem, nie dzielą segmentu.
- **Błąd diaryzatora** tnie zdanie w środku: cięcie jest przyciągane do końca zdania w granicach ~1 s; poza nimi tnie na granicy słowa. Ryzyko: cytat przekraczający zmianę mówcy jest odrzucany przez `NotesGuard` (przypięty test `aQuoteCannotJumpAcrossSentencesOrSpeakers`), więc źle ucięte zdanie obniży liczbę zweryfikowanych punktów; mierzone w kroku 2.4.
- **Dwa tory** (mikrofon i system) dzielone osobno, bo diaryzowane osobno.
- **Przesunięcie czasów** przez padding silnika lub zaokrąglenia: test na sygnale o znanych granicach.
- **Odzyskiwanie po awarii:** to `MeetingResumer` uruchamia finalizację ponownie (nie `RecoveryJob`) i widzi już podzielone segmenty; niezmiennik: `SegmentSplitter` na odcinku jednego klastra zwraca pusty plan.
- **Awaria w trakcie podziału:** transakcja jest atomowa; nic nie jest dzielone w połowie.
- **Segmenty bez diaryzacji (`channels`, `none`):** podział nie działa.

## 📝 Risks & Impact Review
- Zmiana publicznego API `LintelSpeech` (pole `words` w `TranscriptSegment`) jest addytywna, z domyślnym pustym; konsumenci (`DictationPlugin`) bez zmian.
- Migracja bazy jest nieodwracalna po wdrożeniu (tylko dodatkowa kolumna, `BACKWARD_COMPATIBILITY.md`: migracje addytywne).
- Trwałe przechowanie czasów słów (wybór użytkownika) wydłuża czas trzymania danych o mowie ponad „tymczasowo”; to dane pochodne tekstu, objęte tą samą retencją i szyfrowaniem. Dopisane do opisu prywatności pluginu przy wdrożeniu.
- Brak wyłącznika ustawieniami: nowy klucz byłby trwałym kontraktem; zamiast tego bramka pomiarowa przed włączeniem (krok 2.4).
- Wynik zależy od jakości diaryzatora, której nie umiemy zmierzyć bez dźwięku; pomiar tekstowy daje tylko rażące błędy.

## 📋 Phasing
1. **Faza 1 — czasy słów** (bez zmiany zachowania; to przygotowanie bez wartości dla użytkownika, więc wdrażana razem z fazą 2, nie osobno): silnik, kolumna, zapis.
2. **Faza 2 — `SegmentSplitter` i integracja z finalizacją**, z bramką pomiarową. Jeśli bramka 2.4 zawiedzie, podział jest wyłączony stałą w kodzie, a kolumna zostaje nieużywana.
3. **Faza 3 — czasy słów dla WhisperKit** (lub zapas po zdaniach), tylko jeśli faza 2 zadziała.

Kolejność względem specu nazw: faza 2 specu nazw czeka na raport z kroku 1.4 specu jakości; ten spec jest następnym krokiem po nim. Podział zmienia statystyki per klaster w `SpeakerAssigner` (wybór „Ja” zależy od sumarycznego czasu mówcy), ale w minimalnym stopniu.

## 📋 Implementation Plan

### Faza 1 — czasy słów
- **1.1** `TimedWord` i `TranscriptSegment.words` (domyślnie puste) w `LintelSpeech`. Test: `init(text:)` zachowuje się jak dziś, istniejące testy bez edycji.
- **1.2** `ParakeetEngine`: składanie słów z `tokenTimings` (preferowany `buildWordTimings(from:)`, przycięcie końca tokenu do rzeczywistej długości próbek). Test na atrapie `tokenTimings` z oczekiwanymi granicami; `nil` daje puste `words`. Do zweryfikowania w tym kroku: czy `tokenTimings` jest niepuste dla modelu Ultra i czy `result.text` równa się złożonym tokenom (zamiana słownika CTC mogłaby je rozjechać).
- **1.3** Kolumna `words_json` (wariant v1 w miejscu albo `v2-segment-words`, wg decyzji powyżej) i zapis w `MeetingsStore`. Zmiana istniejących testów `StoreTests` (lista kolumn i lista zastosowanych migracji; uzasadniona zmiana schematu). Test migracji na bazie poprzedniego schematu z danymi (wymóg `BACKWARD_COMPATIBILITY.md`; stare wiersze NULL), zapis i odczyt, kaskadowe usuwanie, usunięcie spotkania i „Erase Data” nie zostawiają słów.
- **1.4** Zapis słów w trzech miejscach (`MeetingSession.accept`, `replayOne`, `MeetingResumer.handleRange`) z regułą spójności z `text`. Test przepływu z atrapą silnika, w tym odzyskany segment, przycięty tekst i segment po `EchoSuppressor`.

### Faza 2 — podział
- **2.1** `SegmentSplitter` (czysta logika): przypisanie słów, odcinki, scalanie krótkich, przyciąganie do końca zdania, niezmienniki: konkatenacja tekstów odcinków równa tekstowi segmentu (z dokładnością do białych znaków), brak zgubionych ani zdublowanych słów, idempotencja. Testy tablicowe i właściwości (losowe spany).
- **2.2** `MeetingsStore.applySegmentSplit` (jedna transakcja: `UPDATE` pierwszego, `INSERT` pozostałych, FTS przez wyzwalacze). Test: FTS po podziale znajduje oba fragmenty, liczba wierszy, kolejność.
- **2.3** Integracja w `MeetingFinalizer` (podział, ponowne `segmentRefs`, `SpeakerAssigner`); błąd podziału nie psuje finalizacji; odzyskiwanie po awarii daje ten sam wynik. Test z atrapą diaryzatora.
- **2.4** **Bramka pomiarowa.** Etykiety z pomiaru wyjściowego są kluczowane indeksem segmentu sprzed podziału, więc po podziale: (a) nowe oznaczenie tych samych okien czasowych według `RULES.md` (nowe indeksy), (b) metryka niezależna od wielkości segmentów: udział punktów cięcia leżących na końcu zdania lub w granicach 1 s od niego oraz liczba zweryfikowanych punktów notatek (eval ovn i polski, ≥3 przebiegi na wariant, przed/po). Warunki włączenia: udział mieszających poniżej 10% na ovn, liczba zweryfikowanych punktów nie spada, właściciele zadań raportowani. Samo spadnięcie udziału mieszających nie wystarcza, bo krótsze segmenty obniżają go prawie z definicji. Niespełnienie = podział wyłączony stałą w kodzie.
- **2.5** Test `SpeakerAssigner` na podzielonych segmentach (wybór „Ja”, kolejność mówców) i benchmark 1 h (wyłączony domyślnie) z pomiarem czasu podziału i rozmiaru `words_json`; wynik w PR (wymóg ze specu jakości).

### Faza 3 — zapas bez czasów słów (warunkowa)
- **3.1** `WhisperKitEngine`: spróbować `wordTimestamps: true` i zmierzyć koszt prędkości i WER na polskim nagraniu; gdy koszt nieakceptowalny, podział po zdaniach z czasem proporcjonalnym. Kryterium: mediana odchylenia granicy względem czasów słów Parakeet na tym samym materiale poniżej 1 s (próg do potwierdzenia pomiarem).

## Decyzje użytkownika (bramka zamknięta)
Q1 czasy tokenów z Parakeet plus zapas · Q2 **trwale w bazie** (inaczej niż rekomendowane tymczasowe przechowanie; wpływ opisany w Data Model i Risks) · Q3 zachowawczo, próg stroi pomiar (start: 1,5 s lub 3 słowa).
