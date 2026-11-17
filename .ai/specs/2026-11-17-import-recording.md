# Import nagrania: spotkanie z pliku audio lub wideo

Powiązane: `2026-11-03-meeting-notes.md` (potok spotkań, spool, biblioteka), `2026-11-06-meeting-speaker-names.md` („To ja”, nazwy mówców), `2026-11-06-meeting-segment-split.md` (planuje migrację `v2-segment-words`), PR #80 (`keepAudio`), issue #91 (flagi QA `--qa-meeting-*-wav` sparsowane, ale niepodpięte). Nazwy w kodzie: produkt to Lintel (`MeetingsPlugin`, `LintelSpeech`, klucze `plugins.meetings.*`); repozytorium nazywa się Pounce.

Stan: **propozycja, design-only**. Nic z tego dokumentu nie istnieje w kodzie. Interfejs wymaga prototypu zaakceptowanego przez właściciela (Faza 0) przed jakąkolwiek implementacją UI.

## 📝 TLDR
Osoba, która ma już nagranie rozmowy (plik audio albo duże nagranie ekranu `.mov`), nie może dziś zrobić z niego spotkania w Lintelu: biblioteka przyjmuje tylko to, co Lintel sam nagrał. Proponowane przyszłe zachowanie: użytkownik wskazuje plik (akcja „Import Recording…” albo przeciągnięcie), a Lintel wyciąga z niego samą ścieżkę audio, zapisuje ją do tego samego zaszyfrowanego spoola co nagranie na żywo i kończy spotkanie istniejącym potokiem (`MeetingResumer` → transkrypcja, `MeetingFinalizer` → diaryzacja, `NotesService` → notatki) w prawdziwej bibliotece. Spotkanie jest trwale oznaczone jako import, plik źródłowy nie jest kopiowany ani zmieniany, a audio znika po transkrypcji, chyba że włączone jest `keepAudio`.

## 📝 Problem Statement
- Nagrania powstają też poza Lintelem: nagranie ekranu QuickTime, eksport z komunikatora, dyktafon w telefonie, plik od współpracownika. Dziś nie da się ich przeszukać ani dostać z nich notatek w tej samej bibliotece co reszta spotkań.
- Stan kodu (zweryfikowany na `origin/main` @ `058d5f3`):
  - `MeetingSession` przyjmuje tylko `AudioInput` na żywo (mikrofon i opcjonalnie tor systemowy) i ma założenia czasu rzeczywistego (`heartbeat`, `stallTimeout`, `started_at = now`).
  - `MeetingResumer` potrafi już dokończyć spotkanie `processing` z samego spoola: VAD po spoolu, transkrypcja przez `SpeechEngineLease` z priorytetem `.background`, hak `MeetingFinalizer`, `markReady`, usunięcie spoola (albo `AudioState.kept` przy `keepAudio`). To jest dokładnie „reszta potoku” potrzebna importowi.
  - `AudioSampleSource` (pull, synchroniczny, „plaintext audio is never written to disk”) to gotowy kontrakt dla czytnika pliku; `MonoResampler` istnieje; `WAVFileAudioSource` czyta tylko 16 kHz mono WAV w całości do pamięci i jest używany wyłącznie w testach.
  - `meeting` nie ma kolumny pochodzenia; jedyna migracja to `v1-meetings`. Retencja liczy wiek od `started_at` (`MeetingsStore.swift`, zapytania `started_at < ?`), a zachowane audio od `COALESCE(ended_at, started_at)`.
  - `SpeakerAssigner` daje „Ja” tylko wtedy, gdy tor systemowy ma mowę; przy samym torze `mic` wszyscy są „Mówca N”, a użytkownik oznacza siebie przez „To ja” (`MeetingEdits.markSelf`).
  - `DiarizationBudget` to niezmierzone 90 minut na tor: dłuższy tor dostaje etykiety awaryjne (`speaker_mode = channels`).
  - Issue #91: `QAOptions` parsuje `--qa-meeting-mic-wav`, `--qa-meeting-system-wav`, `--qa-meeting-spool-dir`, ale `MeetingsRuntime` ich nie czyta, więc QA nie ma sposobu na spotkanie bez prawdziwego nagrania.

## 📝 Proposed Solution
Import to **nowe wejście do istniejącego potoku**, nie drugi potok:

1. **Sprawdzenie pliku** (`RecordingProbe`): czas trwania, obecność ścieżki audio, ochrona DRM, data z metadanych. Bez dekodowania całości.
2. **Arkusz importu** (wg prototypu): data spotkania do korekty, wybór notatek (model albo „bez notatek”), przypomnienie o zgodzie uczestników, informacja o jednym torze. Import nigdy nie startuje bez potwierdzenia w arkuszu, także po przeciągnięciu pliku.
3. **Wyciąganie audio** (`AssetAudioSource: AudioSampleSource`): `AVAssetReader` czyta wyłącznie ścieżki audio, strumieniowo, do 16 kHz mono; próbki idą prosto do `SpoolWriter` (zaszyfrowany spool, kanał `mic`). Wideo nie jest dekodowane, plik nie jest kopiowany, nie powstaje żaden plik tymczasowy z audio jawnym tekstem.
4. **Wpis w bibliotece**: po udanym wyciągnięciu powstaje wiersz `meeting` ze statusem `processing`, `origin = 'import'`, `started_at` z arkusza, `imported_at = now`.
5. **Dokończenie**: `MeetingResumer.resume` (ten sam kod co „Dokończ” i odzyskiwanie po awarii) transkrybuje, diaryzuje jeden tor i oznacza spotkanie `ready`; `onMeetingReady` kolejkuje notatki w `NotesService` (`LLMLease`, `background`).

Odrzucone warianty:
- **`MeetingSession` z plikiem jako `AudioInput`**: sesja zakłada czas rzeczywisty (limity z zegara, `stallTimeout`, strumień `.unbounded` bez przeciwciśnienia: 3 h audio trafiłyby do pamięci szybciej, niż da się je zapisać). Wymagałoby to gałęzi „nie na żywo” w 976-liniowym aktorze. Ten adapter powstaje tylko dla QA (#91), z tempem czasu rzeczywistego.
- **Osobny potok importu** (własna transkrypcja, własny zapis): łamie wymaganie „ten sam potok” i dubluje reguły spoola, odzyskiwania i `keepAudio`.
- **`AVAssetExportSession` do pliku `.m4a`/`.wav`**: zapisuje audio jawnym tekstem na dysku i kopiuje dane; sprzeczne z regułą „audio is never written in plain form”.
- **ffmpeg lub inna biblioteka** dla `.mkv`/`.webm`/`.ogg`: nowa zależność; poza zakresem (błąd „nieobsługiwany format”).

Porównanie z rynkiem (z wiedzy ogólnej, bez pomiaru): MacWhisper, Aiko i Buzz importują pliki przez przeciągnięcie i transkrybują lokalnie, ale traktują plik jako dokument (trzymają ścieżkę albo kopię). Lintel świadomie tego nie robi: po imporcie nie zależy od pliku źródłowego i nie pamięta jego położenia. Otter i Fireflies importują do chmury, co odpada z definicji. To, co tamte robią dobrze i warto przejąć: przeciągnięcie pliku jako główne wejście i widoczny postęp z anulowaniem.

## 📝 Architecture
Wszystko w `Sources/MeetingsPlugin/`, nowy folder domenowy `Import/` (testy `Tests/MeetingsPluginTests/Import/`). Bez zmian w `LintelKit`, `LintelSpeech`, `LintelCore`, `LintelPersistence`; bez nowych pakietów (AVFoundation jest już zależnością `LintelSpeech` i `MeetingsPlugin`).

| Element | Status | Rola |
|---|---|---|
| `RecordingProbe` | nowy | `AVURLAsset` → `RecordingInfo` (czas trwania, liczba ścieżek audio, `hasProtectedContent`, data z metadanych) albo `ImportError`. Czyta tylko nagłówki. |
| `AssetAudioSource` | nowy | `AudioSampleSource` nad `AVAssetReader` + `AVAssetReaderAudioMixOutput` (wszystkie ścieżki audio zmiksowane, LPCM Float32). Docelowo 16 kHz mono wprost z ustawień wyjścia czytnika; jeśli spike 0.2 pokaże, że konwersja czytnika zawodzi dla któregoś formatu, czytnik oddaje format źródłowy, a `MonoResampler` robi resztę. Jeden bufor naraz w pamięci. |
| `MeetingImporter` | nowy (aktor) | Etapy: wyciąganie → wpis → `MeetingResumer` → wynik. Jedyny właściciel anulowania i sprzątania. Zdarzenia `ImportEvent` niosą liczby i ułamki, nigdy tekst, ścieżkę ani nazwę pliku. |
| `ImportState` | nowy (czysty) | Maszyna stanów widoku, jak `MeetingHUDState`: `confirming`, `extracting(fraction)`, `waitingForModel`, `transcribing(remaining)`, `recognisingSpeakers`, `done(meetingID)`, `failed(ImportError)`, `cancelled`. |
| `FileAudioInput` | nowy, tylko DEBUG | `AudioInput` nad dowolnym `AudioSampleSource`, w tempie czasu rzeczywistego. Podpina flagi z issue #91. |
| `SpoolWriter`, `SpoolStorage`, `MeetingKeys` | istniejące | Zaszyfrowany spool `Spool/<uuid>/`, kanał `mic`. |
| `MeetingResumer`, `MeetingFinalizer`, `SpeakerAssigner` | istniejące, bez zmian zachowania | VAD, transkrypcja `.background`, diaryzacja, `ready`, `keepAudio`. |
| `NotesService` | istniejący, mała zmiana | `Job` dostaje opcjonalny model na jedno zlecenie (wybór z arkusza), tylko w pamięci. |
| `MeetingsStore` | istniejący, migracja | Kolumny `origin`, `imported_at`; retencja liczona od importu. |
| `MeetingsLibrary.registerLive`, `IOKitSleepAssertion` | istniejące | Import rejestruje spotkanie jako żywe (retencja, odzyskiwanie i „Delete Temporary Recordings…” go nie dotykają) i trzyma blokadę uśpienia do końca. |

```mermaid
flowchart LR
  F[plik źródłowy, tylko odczyt] --> P[RecordingProbe · nowy]
  P --> S[arkusz importu · nowy, wg prototypu]
  S --> A[AssetAudioSource · nowy]
  A --> W[SpoolWriter · istniejący, szyfrowany]
  W --> R[wiersz meeting processing, origin=import · migracja]
  R --> M[MeetingResumer · istniejący]
  M --> D[MeetingFinalizer · istniejący]
  D --> N[NotesService · istniejący]
```

Wniosek z diagramu: nowy kod kończy się na spoolu i wierszu; od tego miejsca import jest nieodróżnialny od spotkania przerwanego w stanie `processing`, więc odzyskiwanie po awarii, `keepAudio`, biblioteka, okno spotkania i źródło Notes (`MeetingNoteSource`) działają bez zmian.

### Jeden tor: skutki
Plik jest zmiksowany, więc Lintel nie wie, który głos jest użytkownika. Import zapisuje wszystko jako kanał `mic` bez toru `system`:
- **Brak automatycznego „Ja”.** `SpeakerAssigner` przyznaje „Ja” tylko przy mowie na torze systemowym, więc każdy mówca importu to „Mówca N” (jak spotkanie w sali). Użytkownik oznacza siebie istniejącym „To ja” (`MeetingEdits.markSelf`) w oknie spotkania albo w Notes; notatki stają się `stale` i po ponownym wygenerowaniu zadania w pierwszej osobie dostają właściciela (`plugins.meetings.selfName`).
- **Notatki przed „To ja”** nie przypisują zadań w pierwszej osobie użytkownikowi. Arkusz importu i okno gotowego importu mówią o tym wprost (treść i miejsce wg prototypu).
- **Nakładające się głosy** na jednym torze pogarszają transkrypcję i diaryzację bardziej niż przy dwóch torach; nie ma też czego odejmować w `EchoSuppressor` (nie jest używany).
- **Importy dłuższe niż budżet diaryzacji** (dziś niezmierzone 90 min, `DiarizationBudget`) dostają etykiety awaryjne: `speaker_mode = channels`, jeden „Mówca 1”, a „To ja” jest wtedy odrzucane. To istniejące ograniczenie, które import pokazuje częściej; zniesie je pomiar z ADR 0007, nie ten spec.
- **Wiele ścieżek audio w pliku** (np. nagranie ekranu z osobnym mikrofonem) jest miksowane do jednej. Rozpoznawanie „ścieżka 1 = ja” jest poza zakresem (pytanie Q4).

### Kolejka i współbieżność
- Jeden import naraz; drugi dostaje `ImportError.importInProgress`. Import nie startuje, gdy trwa nagranie albo jego kończenie (`recordingActive`).
- Nagranie na żywo **zawsze** może wystartować w trakcie importu. Oba idą przez `SpeechEngineLease` z priorytetem `.background`: ten sam model dzieli licznik, inny model daje nagraniu istniejące `modelUnavailable(busy:)` (segmenty czekają w spoolu). Dyktowanie (`interactive`) wyprzedza oba.
- Notatki importu to zwykłe zlecenie `NotesService` (`LLMLease`, `background`), jedno naraz, anulowane między tokenami przez zlecenie `interactive`.

## 📝 Data Model
**Jedna addytywna migracja, w jednym własnym PR-ze** (krok 2.1): `vN-meeting-origin`, gdzie `N` to kolejny wolny numer w chwili implementacji (`v2`, albo `v3`, jeśli `v2-segment-words` wejdzie wcześniej; kolejność rejestracji w `MeetingsStore.migrator` jest kolejnością wejścia na `main`).

```sql
ALTER TABLE meeting ADD COLUMN origin TEXT NOT NULL DEFAULT 'live';
ALTER TABLE meeting ADD COLUMN imported_at DOUBLE;
```

- `origin`: `live` (każdy dotychczasowy wiersz) albo `import`. Znaczenie stałe od wydania; nieznana wartość jest czytana jak `live`. Wartość ustawiana raz przy wstawieniu wiersza i nigdy nie zmieniana (brak API do zmiany).
- `imported_at`: chwila importu; `NULL` dla `live`.
- `started_at` importu to czas spotkania (metadane albo korekta użytkownika), `ended_at = started_at + duration_ms`. Lista biblioteki dalej sortuje po `started_at`.
- **Retencja liczy wiek importu od `imported_at`**: zapytania retencji używają `COALESCE(imported_at, started_at)`, a zachowane audio `COALESCE(imported_at, ended_at, started_at)`. Bez tego nagranie sprzed pół roku znikłoby przy pierwszym przebiegu `RetentionJob` (`retentionDays` = 90).
- Kanał: `meeting_segment.channel` i `meeting_speaker.source_channel` = `mic`. Nie powstaje nowa wartość `AudioChannel` (enum jest `CaseIterable` i steruje spoolem, echem i przypisaniem mówców); o tym, że to import, mówi `origin`.
- `source_bundle_id` = `NULL`. `title` = nazwa pliku bez rozszerzenia, oczyszczona przez `MeetingEdits.visible`, do zmiany jak każdy tytuł. **Ścieżka pliku, zakładka (bookmark) ani skrót zawartości nie są zapisywane nigdzie.**
- Dane wrażliwe: tytuł, transkrypt i notatki w SQLCipher jak dotąd; audio tylko w zaszyfrowanym spoolu; nic w `ranking.sqlite`, `UserDefaults` ani logach.
- Starsza wersja aplikacji z nowszą bazą: krok 2.1 sprawdza i opisuje w `BACKWARD_COMPATIBILITY.md`, jak `MeetingsLibrary` zachowuje się wobec nieznanej migracji (oczekiwane: biblioteka wyłączona bez usuwania czegokolwiek); migracji nie da się cofnąć.

Graf modelu danych pominięty: dwie kolumny w istniejącej tabeli, bez nowych encji i relacji.

## 📝 API Contracts
Brak nowych kontraktów w `LintelKit`. Powierzchnie chronione (`BACKWARD_COMPATIBILITY.md`), wszystkie zmiany addytywne i dopisywane do tego pliku w PR-ze, który je wprowadza:

| Sekcja BC | Zmiana |
|---|---|
| 1. Kontrakt wtyczek | Bez zmian. `MeetingsPlugin` zaczyna odpowiadać na istniejące `handleOpenedFile(_:)` (dziś domyślne `false`). |
| 2. Dane na dysku | Migracja `vN-meeting-origin`; stałe znaczenie `origin` i `imported_at`; reguła retencji importów. |
| 3. Klucze ustawień | **Zero nowych kluczy.** Import czyta istniejące: `speechModel`, `speechLanguage`, `speechModelFolder`, `diarization`, `diarizationModelFolder`, `notesEnabled`, `builtInLLMModel`, `keepAudio`, `keptAudioDays`, `consentReminder`, `selfName`, `retentionDays`. Wybory z arkusza (data, model notatek) dotyczą jednego importu i nie są zapisywane w ustawieniach. |
| 4. Tożsamość pakietu | `Resources/Info.plist` dostaje `CFBundleDocumentTypes` dla `public.audio` i `public.movie` (rola `Viewer`, `LSHandlerRank` = `Alternate`): Lintel pojawia się w „Otwórz w”, nigdy jako domyślna aplikacja. Bez nowych uprawnień i entitlementów. |
| 5. Skróty i zachowanie | Polecenie `meetings.import` („Import Recording…”, w menu, **bez domyślnego skrótu**); akcja wiersza `meetings.library.import`; limit 3 h; reguła „import nie zachowuje pliku ani audio”. |

Kontrakty wewnętrzne (nie chronione):

```swift
struct RecordingInfo: Equatable, Sendable {
    var durationMs: Int
    var audioTrackCount: Int
    var recordedAt: Date?        // metadane zasobu, potem data utworzenia pliku
}

enum ImportError: Error, Equatable, Sendable {   // stałe kody do logów: "import.<case>"
    case unreadable            // brak pliku, brak dostępu, nośnik odłączony
    case noAudioTrack
    case protectedContent      // DRM
    case unsupportedFormat     // kontener albo kodek, którego AVFoundation nie czyta
    case tooLong               // > MeetingSessionLimits.maximumDuration (3 h)
    case nothingHeard          // VAD nie znalazł mowy
    case lowDisk
    case speechModelMissing
    case libraryUnavailable    // błąd Keychain albo bazy: nic nie jest usuwane
    case importInProgress
    case recordingActive
    case sourceChanged         // plik zniknął albo zmienił się w trakcie
}

struct ImportRequest: Sendable {
    var url: URL
    var startedAt: Date
    var notes: NotesChoice     // .settingsDefault | .none | .model(LLMModel.ID)
}

actor MeetingImporter {
    func probe(_ url: URL) async -> Result<RecordingInfo, ImportError>
    func run(_ request: ImportRequest, events: @escaping @Sendable (ImportEvent) -> Void) async -> ImportOutcome
    func cancel() async        // idempotentne
}
```

Walidacja: `startedAt` nie może być w przyszłości (przycinane do „teraz”); `url` musi być plikiem lokalnym (`isFileURL`), nie katalogiem ani pakietem; typ sprawdzany przez AVFoundation, nie po rozszerzeniu.

## 📝 UI/UX
**Bramka:** żaden krok Fazy 3 nie startuje, zanim właściciel zaakceptuje prototyp ekranów `meet-import-*` w `.ai/prototypes/lintel-app/` (krok 0.1). Po akceptacji ten rozdział dostaje wiersz `Prototype:` z dokładną wersją; implementacja ma być zgodna 1:1. Poniżej są wymagania, które prototyp musi pokryć, nie układ.

Wejścia:
1. **Polecenie `meetings.import`** („Import Recording…” / „Importuj nagranie…”): menu paska, paleta poleceń (`PluginContext.availableCommands`), bez skrótu. Otwiera `NSOpenPanel` (typy `.audio`, `.movie`, jeden plik).
2. **Biblioteka spotkań** (`meetings.library`): akcja wiersza „Import Recording…” oraz przycisk w stanie pustym.
3. **Przeciągnięcie pliku**: na ikonę w Docku i na okno główne; oba idą przez istniejące `PluginHost.openFile` → `MeetingsPlugin.handleOpenedFile`. Panel launchera nie przyjmuje upuszczeń (chowa się przy utracie fokusu).

Każde wejście kończy się tym samym **arkuszem importu**; upuszczenie pliku nigdy nie zaczyna importu samo. Arkusz pokazuje:
- nazwę pliku, czas trwania, informację „plik nie zostanie skopiowany ani zmieniony; przetwarzanie odbywa się na tym Macu”;
- **datę i godzinę spotkania** z metadanych, do korekty;
- **notatki**: zainstalowane modele z `LLMModelCatalog` (domyślnie `builtInLLMModel`, gdy `notesEnabled`), „Bez notatek”, oraz odsyłacz „Get It in Models”, gdy żaden nie jest zainstalowany;
- **zgodę uczestników**, gdy `consentReminder` jest włączone: to samo przypomnienie co przy nagrywaniu, w wersji dla cudzego nagrania („upewnij się, że uczestnicy zgodzili się na nagranie i przetwarzanie”);
- **jeden tor**: „Lintel nie wie, który głos jest Twój; oznaczysz siebie po imporcie”;
- gdy `keepAudio` jest włączone: informację, że zaszyfrowane audio zostanie na `keptAudioDays` dni; gdy wyłączone, że audio zniknie po transkrypcji.

Postęp i anulowanie: etapy z `ImportState` z paskiem (wyciąganie: ułamek czasu pliku; transkrypcja: pozostałe segmenty), stale widoczne „Cancel”. Wiersz w bibliotece ma w trakcie plakietkę „Importing”. Po `ready` anulowanie znika (zostaje zwykłe Delete z potwierdzeniem), a notatki mają dotychczasowe stany `NotesBoard`.

Po imporcie: stała plakietka „Imported” na wierszu biblioteki i w oknie spotkania; w oknie importu bez `is_self` podpowiedź „Oznacz siebie” prowadząca do istniejącego „To ja”; korekta daty spotkania tylko dla importów.

Dostępność: każdy etap i błąd ogłaszany VoiceOverem, postęp jako wartość, Reduce Motion respektowane, pełna obsługa z klawiatury (Esc = Cancel w arkuszu; anulowanie trwającego importu wymaga jawnego przycisku). Wszystkie napisy w `Localizable.xcstrings` (`en` + `pl`). Kolory tylko z `LintelBrand`.

Makiety w tym PR-ze: brak, celowo (patrz „Mockups” w opisie PR): aplikacja natywna, a obowiązującym wzorcem jest prototyp z kroku 0.1.

## 📝 Edge Cases & Failure Scenarios
| Sytuacja | Co widzi użytkownik | Co zostaje |
|---|---|---|
| Plik bez ścieżki audio (nieme nagranie ekranu) | „To nagranie nie ma dźwięku.” w arkuszu, przed startem | nic |
| DRM (`hasProtectedContent`) | „Tego pliku nie można odczytać, bo jest chroniony.” | nic |
| Nieobsługiwany kontener albo kodek (`.mkv`, `.webm`, `.ogg`) | „Lintel nie czyta tego formatu. Zapisz nagranie jako .mov, .mp4, .m4a, .mp3 lub .wav.” | nic |
| Dłuższy niż 3 h | „Nagranie jest dłuższe niż 3 godziny.” przed startem; bez przycinania | nic |
| Cisza albo brak mowy | „Nic nie usłyszano” (jak przy nagraniu) | wiersz i spool usunięte |
| Za mało miejsca (`SpoolFormat.minimumFreeBytes`; 3 h to ok. 346 MB spoola) | komunikat przed startem | nic |
| Brak modelu mowy | „Get It in Models”, import nie startuje | nic |
| Biblioteka niedostępna (błąd Keychain inny niż `errSecItemNotFound`) | import odrzucony, komunikat biblioteki | nic nie jest usuwane ani resetowane |
| Plik znika, zmienia się albo nośnik zostaje odłączony w trakcie | „Nie udało się odczytać pliku do końca.” | wiersz i spool usunięte; brak częściowego spotkania |
| **Anulowanie** w dowolnym etapie przed `ready` | powrót do stanu sprzed importu | wiersz (kaskadowo segmenty i mówcy), spool i stan w pamięci usunięte; nic w logach poza kodem `import.cancelled` |
| Wyjście z aplikacji albo wyłączenie wtyczki podczas wyciągania | brak komunikatu | folder spoola bez wiersza: usuwany od razu przy zamykaniu, a po awarii przez `OrphanSpoolSweep` (karencja 1 h) |
| Wyjście albo awaria po powstaniu wiersza | spotkanie `processing`, dokańczane po uruchomieniu | istniejące `RecoveryJob` → `MeetingResumer`; wybór modelu notatek z arkusza przepada, obowiązuje `notesEnabled` |
| Model mowy zajęty innym kluczem (`ModelLeaseError.busy`) | „Czeka na model” | import czeka; po przekroczeniu prób spotkanie `incomplete` z „Dokończ”, jak dziś |
| Diaryzacja niedostępna, wyłączona albo ponad budżet | baner trybu `channels` (istniejący) | transkrypt z „Mówca 1” |
| Wybrany model notatek odinstalowany przed końcem | stan „czeka na model” (`NotesBoard.needsModel`) | transkrypt gotowy, notatki później przez „Regenerate” |
| Ten sam plik importowany drugi raz | drugie, osobne spotkanie | brak wykrywania duplikatów (nie przechowujemy niczego, po czym dałoby się je wykryć) |
| Plik w miejscu chronionym TCC (Pulpit, Dokumenty, dysk zewnętrzny) | wybór w `NSOpenPanel` lub upuszczenie daje dostęp do tego pliku; brak zgody = `unreadable` | Lintel nie prosi o Full Disk Access dla importu; zachowanie upuszczenia potwierdza spike 0.2 |
| Wtyczka Meetings wyłączona, plik upuszczony | plik nieobsłużony (istniejące zachowanie `PluginHost.openFile`) | nic |
| Nagranie zaczyna się w trakcie importu | nagranie startuje normalnie | import trwa dalej w tle |
| Zmienna liczba klatek, kilka ścieżek audio, dźwięk 5.1, 48/96 kHz | bez komunikatu | wszystko miksowane do 16 kHz mono |

## 📝 Risks & Impact Review
- **Schemat (trudno odwracalne).** Dwie kolumny zostają na zawsze. Ograniczenie: wartości domyślne zachowują dotychczasowe zachowanie każdego wiersza, a kod sprzed migracji nie czyta nowych kolumn. Kolizja nazwy z `v2-segment-words` rozwiązana regułą „kolejny wolny numer”.
- **Retencja (zachowanie danych).** Zmiana zapytań retencji dotyka usuwania danych użytkownika. Ryzyko ogranicza `COALESCE(imported_at, …)`, które dla `live` daje dokładnie dzisiejszy wynik; test porównuje zbiory usuwanych wierszy przed i po dla bazy bez importów.
- **Prywatność.** Import cudzego nagrania to przetwarzanie cudzych słów bez udziału Lintela w nagraniu. Ograniczenia: przypomnienie o zgodzie w arkuszu, wszystko lokalnie (jedyna sieć to istniejące pobieranie modeli), żadnej ścieżki, nazwy pliku, tytułu, transkryptu ani nazwy urządzenia w logach (`ImportLogging`: kody, liczby, czasy), plik otwierany tylko do odczytu, bez zakładek i bez listy „ostatnie”.
- **Rejestracja typów dokumentów.** Lintel pojawi się w „Otwórz w” dla każdego pliku audio i wideo. Odwracalne w jednym wydaniu (usunięcie wpisów z `Info.plist`); `Alternate` wyklucza przejęcie roli domyślnej aplikacji.
- **Pamięć i czas dużych plików.** Wielogigabajtowy `.mov` nie może trafić do pamięci. Projekt trzyma jeden bufor naraz; spike 0.2 mierzy szczyt pamięci i czas dla pliku ≥ 5 GB / 3 h, wyniki idą do `docs/perf.md` (do tego czasu „not yet measured”).
- **Jakość na jednym torze.** Notatki z importu mogą być słabsze niż z nagrania dwutorowego (brak „Ja”, nakładanie głosów). To kierunek produktowy, nie wada: opisany w arkuszu i w oknie spotkania.
- **Współdzielenie kolejki z nagraniem.** Import w tle może opóźnić transkrypt nagrania na żywo (segmenty czekają w spoolu, nic nie ginie). Jeśli pomiar pokaże kłopot, import ustępuje nagraniu (pytanie Q8).
- **Wycofanie.** Fazy 1 i 2 nie mają wejścia dla użytkownika (poza DEBUG). Faza 3 dodaje wejścia; ich usunięcie nie wymaga zmian danych: zaimportowane spotkania zostają zwykłymi spotkaniami z `origin = 'import'`.

## 📋 Phasing
Każda faza jest osobno wydawalna; każdy krok to jeden mały PR z `main` (gałąź `feat/`), z pełną bramką (`swift build`, `swift test`, `swift format lint --strict -r Sources Tests`).

- **Faza 0 — prototyp i spike.** Decyzje bez kodu produkcyjnego. Bramka dla Fazy 3 (prototyp) i dla wyboru ścieżki resamplingu (spike).
- **Faza 1 — czytnik plików.** `RecordingProbe`, `AssetAudioSource`, adapter QA (zamyka podpięcie flag z #91). Bez zmian widocznych dla użytkownika.
- **Faza 2 — import bez interfejsu.** Migracja, `MeetingImporter`, model notatek na zlecenie; uruchamiany tylko flagą DEBUG.
- **Faza 3 — interfejs.** Polecenie, arkusz, postęp, plakietki, przeciągnięcie. Od tej fazy funkcja jest dostępna dla użytkowników.
- **Faza 4 — domknięcie.** Dokumentacja, budżety, QA.

## 📋 Implementation Plan

### Faza 0 — prototyp i spike
**0.1 Prototyp `meet-import-*`** (`.ai/prototypes/lintel-app/`, PR design-only): arkusz (stan zwykły, bez modelu notatek, z `keepAudio`), postęp z anulowaniem, każdy błąd z tabeli, wiersz biblioteki „Importing”/„Imported”, okno spotkania importu z podpowiedzią „Oznacz siebie”, stan pusty biblioteki, jasny i ciemny motyw.
- Given prototyp w PR-ze, When właściciel go zaakceptuje, Then spec dostaje wiersz `Prototype:` z wersją i dopiero wtedy wolno zacząć Fazę 3.

**0.2 Spike AVFoundation** (wynik w treści PR i `docs/perf.md`, bez kodu w `Sources`): `AVAssetReaderAudioMixOutput` z wyjściem 16 kHz mono na `.mov` (H.264 i HEVC, ≥ 5 GB), `.mp4`, `.m4a`, `.mp3`, `.wav`, `.flac`, pliku z dwiema ścieżkami audio i pliku 5.1; szczyt pamięci, czas względem długości, zachowanie dla DRM i braku audio, dostęp do pliku upuszczonego z Pulpitu bez Full Disk Access.
- Given plik 3 h, When audio jest wyciągane strumieniowo, Then szczyt dodatkowej pamięci i czas są zapisane liczbowo, a decyzja „konwersja czytnika albo `MonoResampler`” jest podjęta.

### Faza 1 — czytnik plików
**1.1 `RecordingProbe` + `ImportError`.**
- Given plik bez ścieżki audio, Then `noAudioTrack`. Given plik dłuższy niż limit, Then `tooLong`. Given plik tekstowy z rozszerzeniem `.mp4`, Then `unsupportedFormat`. Given brak pliku, Then `unreadable`.
- Given plik z datą w metadanych, Then `recordedAt` jest tą datą; Given bez niej, Then datą utworzenia pliku.

**1.2 `AssetAudioSource`.**
- Given 48 kHz stereo o znanej zawartości (ton 440 Hz w lewym kanale), When czytany do końca, Then próbki są 16 kHz mono, długość zgadza się co do ±1 bufora, ton jest obecny, `endState == .complete`.
- Given plik z wideo i audio, Then żadne wyjście wideo nie jest dodawane do czytnika (test na konfigurację) i wynik jest ten sam co dla samego audio.
- Given plik obcinany w trakcie czytania, Then `nextChunk()` rzuca, a nie kończy się czysto.
- Given czytanie, Then katalog tymczasowy i folder pliku źródłowego nie zyskują żadnego pliku; data modyfikacji i rozmiar źródła są niezmienione.

**1.3 `FileAudioInput` i flagi QA (issue #91, tylko DEBUG).** `MeetingsRuntime` w trybie QA buduje tory z `--qa-meeting-mic-wav` / `--qa-meeting-system-wav` przez `FileAudioInput` (tempo czasu rzeczywistego), spool w `--qa-meeting-spool-dir`; `docs/qa.md` poprawione, łącznie z uwagą o kluczu w pamięci przy drugim uruchomieniu.
- Given aplikacja QA z obiema flagami, When „Record Meeting”, Then powstaje spotkanie z dwóch plików bez dotykania mikrofonu i Core Audio (`NoRealSystemTests` nadal przechodzi).
- Given build release, Then żaden z tych typów nie jest wkompilowany (test skanujący źródła na `#if DEBUG`).

### Faza 2 — import bez interfejsu
**2.1 Migracja `vN-meeting-origin` i retencja** (jedyna migracja tego speca, osobny PR; `BACKWARD_COMPATIBILITY.md` sekcja 2 w tym samym PR-ze).
- Given baza po `v1-meetings` z wierszami, When migracja, Then każdy wiersz ma `origin = 'live'`, `imported_at IS NULL`, a transkrypty, notatki i indeksy FTS są nietknięte.
- Given baza bez importów, Then retencja wybiera dokładnie te same wiersze co przed zmianą.
- Given import z `started_at` sprzed 200 dni i `imported_at` sprzed 10 dni, `retentionDays = 90`, Then retencja go nie usuwa; po 91 dniach od importu usuwa.
- Given `keepAudio` i import, Then zachowane audio jest usuwane po `keptAudioDays` od `imported_at`.

**2.2 `MeetingImporter`** (wyciąganie → spool → wiersz → `MeetingResumer`), rejestracja jako żywe, blokada uśpienia, DEBUG `--qa-meeting-import <path>`.
- Given plik z mową dwóch osób, When import się kończy, Then spotkanie jest `ready`, `origin = 'import'`, segmenty mają kanał `mic`, żaden mówca nie ma `is_self`, spool jest usunięty, `audio_state = deleted`.
- Given `keepAudio = true`, Then spool zostaje i `audio_state = kept`.
- Given anulowanie podczas wyciągania, transkrypcji albo diaryzacji, Then nie ma wiersza, segmentów, mówców ani folderu spoola, a liczba spotkań jest taka jak przed importem.
- Given plik z samą ciszą, Then `nothingHeard` i brak wiersza.
- Given trwające nagranie, Then `recordingActive`; Given trwający import, Then `importInProgress`.
- Given import w toku, When rusza `RetentionJob`, `RecoveryJob` albo „Delete Temporary Recordings…”, Then spool importu jest nietknięty.
- Given przechwycony log całego importu, Then nie zawiera ścieżki, nazwy pliku, tytułu ani tekstu (test na `ImportLogging`).
- Given silnik mowy, Then każde wypożyczenie ma priorytet `.background` (fałszywy `SpeechEngineLease` to potwierdza).

**2.3 Model notatek na zlecenie** (`NotesService.Job.model`, w pamięci).
- Given import z `.model(X)`, When spotkanie staje się `ready`, Then notatki pisze X i `notes_model = X`, a `plugins.meetings.builtInLLMModel` się nie zmienia.
- Given `.none`, Then notatki nie są kolejkowane nawet przy `notesEnabled = true`, a późniejsze „Regenerate” działa jak dziś.
- Given `.settingsDefault`, Then zachowanie jak dla nagrania.

### Faza 3 — interfejs (po akceptacji 0.1)
**3.1 Polecenie `meetings.import`, arkusz, postęp, anulowanie, błędy** (`ImportState`, napisy `en`/`pl`, BC sekcja 5).
- Given `consentReminder = true`, Then arkusz pokazuje przypomnienie o zgodzie; Given `false`, Then nie.
- Given data z metadanych, When użytkownik ją zmienia, Then `started_at` jest wartością z arkusza.
- Given każdy `ImportError`, Then `ImportState` daje osobny, przetłumaczony komunikat (test tabelaryczny), a VoiceOver go ogłasza.
- Given `DefaultShortcutTests`, Then nadal przechodzi (polecenie nie ma skrótu).

**3.2 Biblioteka i okno spotkania**: akcja wiersza i stan pusty, plakietki „Importing”/„Imported”, podpowiedź „Oznacz siebie”, korekta daty dla importów (`MeetingEdits`).
- Given import bez `is_self`, Then okno pokazuje podpowiedź; When „To ja”, Then znika, a notatki są `stale`.
- Given spotkanie `live`, Then nie ma plakietki ani korekty daty.
- Given tryb biblioteki, Then nadal nic nie trafia do `ranking.sqlite` (istniejący test rozszerzony o import).

**3.3 Przeciągnięcie pliku**: `handleOpenedFile`, upuszczenie na okno główne, `CFBundleDocumentTypes` (BC sekcja 4).
- Given plik audio albo wideo i aktywna wtyczka, When `handleOpenedFile`, Then zwraca `true` i otwiera arkusz, a import **nie** startuje. Given `.lintellayouts` albo inny typ, Then `false` (Windows nadal dostaje swój plik).
- Given wtyczka wyłączona, Then plik nie jest obsłużony i nic nie powstaje.
- Given `Info.plist`, Then typy mają rangę `Alternate` (test na plik).

### Faza 4 — domknięcie
**4.1 Dokumentacja i QA**: wiersz Meetings w `AGENTS.md` (folder `Import/`), `docs/qa.md` (procedura importu z `--qa-meeting-import`, zrzuty jasny/ciemny każdego stanu), `docs/perf.md` (budżety importu z liczbami ze spike'u), `BACKWARD_COMPATIBILITY.md` sprawdzony w całości.
- Given PR z UI, Then ma zrzuty działającej aplikacji QA porównane 1:1 z prototypem.

### Plan testów
- **Jednostkowe (CI, `swift test`)**: wszystko z kryteriów powyżej. Pliki testowe są **generowane w teście** (`AVAudioFile`/`AVAssetWriter` w katalogu tymczasowym: ton, cisza, dwa kanały, plik z pustą ścieżką wideo); żadnych binariów w repozytorium, żadnych prawdziwych nagrań. Porty w pamięci (`InMemoryKeychainClient`, `InMemorySettingsStore`), fałszywy silnik mowy i diaryzator, `MeetingsSystem.quiet`.
- **TSan**: testy `MeetingImporter` (anulowanie w każdym etapie, wyścig anulowania z `ready`) dołączone do przebiegu `--sanitize=thread`.
- **Skany źródeł**: brak `fatalError`/`try!`/force unwrap w `Import/`; brak wywołań loggera z interpolacją `url`, `path`, `title`; typy QA tylko pod `#if DEBUG`.
- **Lokalne, poza CI** (wyniki w treści PR): prawdziwy model mowy na jednym prawdziwym nagraniu (`LINTEL_DICTATION_MODEL_FOLDER`), plik ≥ 5 GB, plik z dysku zewnętrznego, upuszczenie z Pulpitu bez Full Disk Access, VoiceOver.
- **Regresja**: istniejące testy `MeetingResumer`, `RecoveryJob`, `RetentionJob`, `OrphanSpoolSweep` i `NoRealSystemTests` bez zmian asercji.

## Resolved assumptions (autonomous defaults)
Bramka pytań otwartych została rozstrzygnięta automatycznie; każdą wartość właściciel może zmienić przed merge'em. Żadna nie osłabia bezpieczeństwa ani chronionego kontraktu, więc żadna nie nosi znacznika `⚠ NEEDS HUMAN CONFIRMATION`. Pytania, przy których zdanie właściciela ma największą wagę, są oznaczone **(właściciel)**.

| # | Pytanie | Przyjęta wartość | Uzasadnienie |
|---|---|---|---|
| Q1 | Czy podpięcie flag QA z #91 należy do tego speca, czy do osobnego? | W tym specu, jako samodzielny krok 1.3 | Dzieli czytnik plików; krok jest osobnym PR-em i można go wydać bez reszty. |
| Q2 **(właściciel)** | Co z nagraniem dłuższym niż 3 h? | Odmowa przed startem, bez przycinania | Najmniejsza powierzchnia; ciche ucięcie rozmowy byłoby gorsze niż komunikat. Alternatywa: import pierwszych 3 h za zgodą w arkuszu. |
| Q3 **(właściciel)** | Od czego liczyć retencję importu? | Od `imported_at` | Wariant, który usuwa mniej; inaczej stare nagranie znika przy pierwszym przebiegu. Alternatywa: importy wyłączone z retencji. |
| Q4 | Plik z kilkoma ścieżkami audio: miksować czy pytać, która jest „moja”? | Miksować wszystkie do jednego toru | Wymaganie „jeden tor”; wybór ścieżki to osobna funkcja. |
| Q5 | Jak zapisać kanał importu? | Istniejące `mic`, o imporcie mówi `origin` | Bez nowej wartości w `AudioChannel` i bez zmian w spoolu, echu i przypisaniu mówców. |
| Q6 **(właściciel)** | Gdzie żyje wybór modelu notatek dla importu? | W arkuszu, na jedno zlecenie, tylko w pamięci; późniejsza zmiana = model w ustawieniach + „Regenerate” | Zero nowych kluczy i kolumn. Koszt: po awarii przed notatkami obowiązują ustawienia. |
| Q7 **(właściciel)** | Gdzie można upuścić plik? | Ikona w Docku i okno główne (istniejące `handleOpenedFile`); nie panel launchera | Bez nowego kontraktu w `LintelKit`. Skutek uboczny: Lintel w „Otwórz w” dla audio i wideo (ranga `Alternate`). |
| Q8 | Czy import ustępuje nagraniu na żywo? | Nie startuje podczas nagrania; nagranie może wystartować w trakcie importu i oba dzielą kolejkę `.background` | Nigdy nie blokuje funkcji na żywo; bez nowego mechanizmu priorytetów do czasu pomiaru. |
| Q9 | Czy zapamiętać plik źródłowy (ścieżka, zakładka, skrót) albo wykrywać duplikaty? | Nie | Prywatność i wymaganie „plik nie jest kopiowany”; drugi import to drugie spotkanie. |
| Q10 | Przypomnienie o zgodzie: zawsze czy wg `consentReminder`? | Wg `consentReminder` (domyślnie włączone) | „Jak przy nagrywaniu”; bez nowego klucza. |
| Q11 | Język mowy i model mowy dla importu? | Z ustawień (`speechModel`, `speechLanguage`), bez wyboru w arkuszu | Najmniejszy arkusz; do rozszerzenia w prototypie. |
| Q12 | Tytuł importu? | Nazwa pliku bez rozszerzenia, edytowalna | Rozpoznawalne w bibliotece; przechowywane tylko w zaszyfrowanej bazie. |
| Q13 | Korekta daty po imporcie? | Tak, tylko dla `origin = 'import'` | Spotkania na żywo mają czas z zegara; zmiana ich daty to inna decyzja. |
| Q14 | Kilka plików naraz albo kolejka importów? | Jeden plik, jeden import naraz | Najmniejszy zakres; kolejka to dodatek bez zmian danych. |
| Q15 | Formaty spoza AVFoundation (`.mkv`, `.webm`, `.ogg`)? | Nieobsługiwane, komunikat z podpowiedzią | Wymaganie „bez nowych zależności”. |
| Q16 | Import dłuższy niż budżet diaryzacji (90 min)? | Istniejące zachowanie awaryjne („Mówca 1”) | Budżet jest tematem ADR 0007, nie tego speca. |
