# Dyktowanie głosowe (Voice to Text)

> Status: **projekt** — odpowiedzi na Open Questions przyjęte 2026-11-02, czeka na review. Proza po polsku, identyfikatory po angielsku (jak spec MVP).

## 📝 TLDR
Użytkownik chce dyktować tekst w dowolnej aplikacji, jak w superwhisper, głównie przy pisaniu promptów do LLM (często 2–5 minut mówienia, po polsku z angielskimi terminami). Dziś Pounce nie obsługuje mowy, a dyktowanie systemowe macOS daje jeden blok tekstu z „yyy” i poprawkami w locie. Proponowane przyszłe zachowanie: nowy plugin `DictationPlugin` nagrywa pod globalnym skrótem, transkrybuje **modelem mowy działającym w procesie Pounce** (audio nie opuszcza Maca), **porządkuje** tekst przez **lokalny serwer LLM użytkownika** (Ollama / LM Studio / llama-server, tylko loopback) i wkleja wynik do aplikacji, w której użytkownik pisze. Tekst (surowy i sformatowany) trafia do zaszyfrowanej historii; audio nigdy nie jest zapisywane.

## ✅ Rozstrzygnięte pytania (2026-11-02)

| # | Decyzja |
|---|---|
| Q1 | Jeden spec; formatowanie dla LLM to osobna faza. |
| Q2 | Użytkownikowi obojętne, czy model uruchamia Pounce, czy on sam — ma działać lokalnie i jak najlepiej. Na podstawie badań (sekcja Research): **mowa → tekst w procesie Pounce** (Parakeet TDT v3 przez FluidAudio), **formatowanie przez lokalny endpoint zgodny z OpenAI** (Ollama, LM Studio, llama-server; tylko adresy loopback). Wbudowany LLM (mlx-swift-lm) poza zakresem tego specu, możliwy później za tym samym portem. |
| Q3 | Polski i angielski z automatycznym wykrywaniem, także mieszane w zdaniu. |
| Q4 | Tryb „Porządkuj” (interpunkcja, akapity, listy, usunięcie wtrąceń, zastosowanie poprawek w locie; treść, kolejność i język bez zmian) + tryb „Surowy” bez LLM. Przepisywanie w strukturalny prompt i własne tryby — poza zakresem. |
| Q5 | Krótkie naciśnięcie skrótu przełącza nagrywanie, przytrzymanie działa jako push-to-talk; Esc anuluje. |
| Q6 | Wynik wklejany od razu do aplikacji aktywnej w chwili zakończenia nagrania; bez Accessibility — tylko kopia do schowka. |
| Q7 | Zaszyfrowana historia samego tekstu (surowy + sformatowany), nigdy audio. |
| Q8 | Model pobierany w Ustawieniach po zgodzie użytkownika (zweryfikowany SHA-256) albo wskazany folder z modelem pobranym ręcznie. |

## 📝 Problem Statement
- Pisanie długich promptów jest wolne; mówienie jest kilka razy szybsze, ale tylko gdy narzędzie nie gubi polskiego ani angielskich terminów i nie zostawia „ściany tekstu”.
- Dyktowanie systemowe (i surowy Whisper) zostawia wtrącenia, autokorekty mowy („nie, czekaj, chodziło mi o…”) i brak akapitów. Taki tekst jest gorszym promptem niż napisany ręcznie, więc trzeba go poprawiać ręcznie.
- Usługi chmurowe wysyłają audio na serwer. Wymaganie użytkownika: model działa na Macu.
- Pounce ma już prawie wszystkie klocki: globalne skróty z rejestratorem, wklejanie do poprzedniej aplikacji (`EventPoster`, Accessibility, Secure Event Input), szyfrowany magazyn (SQLCipher + Keychain + HKDF), list panel mode z podglądem, ekran Uprawnień i onboarding pluginów.

## 📝 Research (rynek i silniki, stan na 2026-11-02)

**Silniki mowy → tekst (lokalne, licencje zgodne z MIT):**

| Silnik | Polski | Auto-język | Rozmiar | Szybkość | Licencja | Werdykt |
|---|---|---|---|---|---|---|
| Parakeet TDT 0.6B v3 przez FluidAudio 0.18.x | tak, WER FLEURS-pl 7,31% | tak (per wypowiedź) | ~0,5–0,6 GB | ~110–190× czasu rzeczywistego (M4 Pro) | kod Apache-2.0, wagi CC-BY-4.0 | **domyślny** |
| WhisperKit 1.1.x (`argmax-oss-swift`), `large-v3-turbo_632MB` | tak (brak oficjalnego WER FLEURS-pl) | tak (per okno 30 s) | 0,65 GB (1,6 GB nieskompresowany) | wolniejszy od Parakeet | MIT | zapasowy, jeśli spike pokaże słabe code-switching Parakeeta |
| Apple `DictationTranscriber` (pl_PL) | tak | **nie** (jeden locale) | systemowy | — | system | odrzucony: brak mieszania języków |
| Apple `SpeechTranscriber` | **nie** | — | — | — | — | odrzucony |
| whisper.cpp 1.9.x | tak | tak | jak Whisper | dobra (Metal) | MIT | odrzucony: C++ bez Swift API, brak gotowego xcframework od 1.8 |

**Formatowanie (lokalny LLM):**
- Apple Foundation Models odpada: brak polskiego (16 języków Apple Intelligence) i 4 096 tokenów na wejście+wyjście, a 5 minut po polsku to ~2–2,5 tys. tokenów w każdą stronę.
- Ollama (`localhost:11434`), LM Studio (`localhost:1234`) i llama-server (`127.0.0.1:9931`, nowy domyślny port; dawniej 8080) mają `/v1/chat/completions` i `/v1/models`, więc wystarczy **jeden klient**.
- Modele ≤ 8B z dobrym polskim: **Bielik-4.5B-v3.0-Instruct** (Apache-2.0, najmocniejsze dowody dla polskiego w tej klasie) i Qwen3-4B/8B (Apache-2.0, tryb „thinking” trzeba wyłączyć albo wycinać `<think>`). Gemma/Llama — licencje nie-OSI, tylko jeśli użytkownik sam pobierze. Pounce **nie wybiera ani nie pobiera** modelu LLM; Ustawienia podpowiadają Bielika.
- **Opóźnienie to główne ryzyko:** 4B w 4-bit na bazowym M4 generuje ~31–38 tok/s, więc przepisanie 900 słów po zakończeniu nagrania trwałoby 30–70 s. Stąd projekt formatuje **kawałkami w trakcie nagrywania** (sekcja Architecture).

**Co robią liderzy:**
- **superwhisper** (zamknięty): lokalne modele Whisper, Parakeet i Cohere Transcribe, „tryby” z promptami LLM, słownik własnych słów. Ma znany problem: automatyczne wykrywanie języka czasem daje angielski. Wnioski: Parakeet to rozsądny domyślny wybór, a własny słownik warto zrobić później.
- **VoiceInk** (GPL-3.0, więc tylko inspiracja, zero kodu):
  - silniki whisper.cpp i Parakeet przez FluidAudio;
  - transkrypcja strumieniowa w trakcie nagrania;
  - wklejanie ⌘V przez `CGEvent`;
  - „AI enhancement” przez Ollama albo własny endpoint zgodny z OpenAI. Transkrypcja idzie w znacznikach `<TRANSCRIPT>`, z regułami „nie odpowiadaj na pytania z transkrypcji”, „zachowaj język” i „zwróć tylko tekst”, z przykładami few-shot i z filtrem wycinającym `<think>`.
  
  Przejmujemy ten wzorzec bez kodu, dodając strażnika długości (Edge Cases).
- **Czego nie robimy (złożoność do pominięcia):**
  - konta;
  - modele w chmurze;
  - wiele trybów i promptów;
  - transkrypcja plików audio;
  - reguły per aplikacja („w Slacku inny tryb”);
  - wpisywanie znak po znaku zamiast ⌘V.

## 📝 Proposed Solution
Nowy wewnętrzny plugin `DictationPlugin` (`PluginID` `dictation`, nowy target i jedna linia w `PluginRegistry`). Przepływ:

1. **Skrót naciśnięty:**
   - shell chowa panel Pounce, jeśli jest widoczny;
   - plugin przejmuje na czas sesji klawisz Esc (krótkotrwały globalny skrót przez shell);
   - startuje `AVAudioEngine` (16 kHz mono, tylko w pamięci);
   - pokazuje mały HUD u dołu aktywnego ekranu: poziom dźwięku, czas, „Esc anuluje”;
   - jeśli model mowy nie jest w pamięci, ładuje go równolegle, a audio czeka w buforze, więc żadne słowo nie ginie.
2. **W trakcie mówienia:**
   - VAD (Silero, w FluidAudio) tnie mowę na segmenty i każdy zamknięty segment od razu idzie do transkrypcji;
   - w trybie „Porządkuj” złożone z segmentów **akapity** (≥ ~120 słów zakończone pauzą ≥ 1,5 s) od razu trafiają do lokalnego LLM;
   - dzięki temu po zakończeniu zostaje do przetworzenia tylko ostatni kawałek.
3. **Skrót puszczony albo naciśnięty ponownie:**
   - plugin transkrybuje i formatuje ogon nagrania, skleja akapity;
   - wkleja wynik przez schowek i ⌘V do aplikacji aktywnej **w tej chwili** (`WorkspaceClient.frontmostApplication` czytane w momencie końca; użytkownik mógł zmienić okno w trakcie); ten sam pid służy do sprawdzenia „cel zniknął”;
   - poprzednią zawartość schowka przywraca po 1 s (warunki w `TextPaster`);
   - zapisuje wpis w historii **po** wklejeniu, z wynikiem wklejenia;
   - zwalnia Esc.
4. **Esc albo błąd:** nagranie jest odrzucane, nic nie trafia do historii; HUD pokazuje powód.
5. **Wywołanie z menu paska:** zawsze startuje w trybie przełączania (menu nie zna puszczenia klawisza); kończy ponowny wybór w menu, skrót albo ✕ w HUD.

**Alternatywy, które przegrały:**
- **Wszystko przez serwery localhost** (whisper.cpp server do mowy): wymaga od użytkownika dwóch procesów i daje gorsze opóźnienie startu. Mowa jest mała (0,6 GB) i musi być natychmiastowa, więc należy do Pounce.
- **Wbudowany LLM (mlx-swift-lm) już w v1:** nowa, duża zależność (MLX, swift-transformers) o niezweryfikowanym statusie Swift 6, do tego kilka GB modelu w procesie z budżetem 150 MB w spoczynku. Port `TextFormatter` zostawia na to miejsce na później.
- **Jedno formatowanie całości po zakończeniu:** 30–70 s czekania na bazowym M-series, nie do przyjęcia.
- **Wklejanie przez Accessibility API (`AXValue`) zamiast ⌘V:** nie działa w wielu aplikacjach Electron i webowych; ⌘V jest już sprawdzone w schowku.

## 📝 Architecture

```mermaid
flowchart LR
    classDef existing fill:#e5e7eb,color:#111,stroke:#9ca3af
    classDef new fill:#2f6feb,color:#fff,stroke:#1b4fb0
    classDef external fill:#fde68a,color:#111,stroke:#b45309

    hk["HotkeyService (shell): key-down + key-up"]:::existing
    gesture["RecordingGesture (tap / hold)"]:::new
    session["DictationSession (actor)"]:::new
    capture["AudioCapture (AVAudioEngine)"]:::new
    stt["SpeechEngine: ParakeetEngine (FluidAudio)"]:::new
    fmt["TextFormatter: RawFormatter / LocalLLMFormatter"]:::new
    llm["Ollama / LM Studio / llama-server (loopback)"]:::external
    store["DictationStore (SQLCipher)"]:::new
    paste["TextPaster (PasteboardClient + EventPoster)"]:::new
    hud["DictationHUD (NSPanel non-activating)"]:::new
    models["ModelManager (download / folder / SHA-256)"]:::new

    hk --> gesture --> session
    session --> capture
    session --> stt
    models --> stt
    session --> fmt --> llm
    session --> store
    session --> paste
    session --> hud
```

Wniosek: cała logika żyje w `DictationPlugin`. Shell dostaje cztery addytywne rozszerzenia kontraktu (fazy naciśnięcia skrótu, uprawnienie mikrofonu, tymczasowe przejęcie Esc, schowanie panelu) oraz opis użycia i entitlement mikrofonu w bundlu. Aplikację na pierwszym planie plugin czyta z istniejącego `WorkspaceClient.frontmostApplication`.

**Wyjątek od zasady „pluginy nie sięgają po globalne obiekty”:** `AVAudioEngine`, `AVCaptureDevice.requestAccess`, `URLSession` i własny `NSPanel` są używane w pluginie, ale każdy za **wewnętrznym** (nie w `PounceKit`) protokołem wstrzykiwanym w inicjalizatorze: `AudioSource` (testy: plik WAV), `MicrophoneAuthorizer`, `HTTPTransport` (testy: `URLProtocol` stub), `HUDPresenter` (testy: rejestrujący stan). Nie dodajemy ich do `PounceKit`, bo potrzebuje ich jeden plugin; trafią tam, gdy pojawi się drugi. Jedyny proces poza Pounce to opcjonalny serwer LLM użytkownika.

**Komponenty `Sources/DictationPlugin/`:**
- `DictationPlugin` — manifest (`id: dictation`, `order` po schowku, `defaultEnabled: false`, bo funkcja wymaga pobrania modelu i mikrofonu), `commands`, `onboardingSteps`, `requiredPermissions = [.microphone, .accessibility]`, `settingsPane()`, `panelModes` (historia, Faza 3), `eraseData()` (klucz w Keychain).
- `RecordingGesture` — czysta maszyna stanów (bez I/O), z pełną tabelą stan × zdarzenie:

  | Stan \ zdarzenie | key-down | key-up | menu | Esc / ✕ |
  |---|---|---|---|---|
  | `idle` | → `pressed` (start) | ignoruj | → `toggle` (start) | ignoruj |
  | `pressed` | ignoruj (autorepeat) | < 300 ms → `toggle`; ≥ 300 ms → `finishing` | → `finishing` | → `idle` (anuluj) |
  | `toggle` | → `stopPressed` | ignoruj | → `finishing` | → `idle` (anuluj) |
  | `stopPressed` | ignoruj | → `finishing` | → `finishing` | → `idle` (anuluj) |
  | `finishing` | ignoruj | ignoruj | ignoruj | ignoruj (tekst już powstaje) |

  Kończenie w `toggle` następuje dopiero przy key-up drugiego naciśnięcia, żeby puszczenie klawisza nie trafiło do nowej sesji.
- `DictationSession` (`actor`) — jedno nagranie: bufor audio, kolejka segmentów, kolejność akapitów, anulowanie przez `Task` cancellation. Naraz istnieje najwyżej jedna sesja.
- `AudioCapture` — `AVAudioEngine` z tapem na wejściu, konwersja do 16 kHz mono `Float32`, poziom RMS dla HUD; wybrane urządzenie wejściowe albo systemowe.
- `SpeechEngine` (protokół) + `ParakeetEngine`:
  - `load(modelFolder:)`, `transcribe(segment:) async throws -> TranscriptSegment`, `unload()`;
  - model zostaje w pamięci przez `keepWarm` (domyślnie 10 min od ostatniego dyktowania), potem jest zwalniany;
  - `WhisperKitEngine` powstanie tylko, jeśli spike 0.1 tego wymaga.
- `Segmenter` — czysta logika: z segmentów VAD składa akapity do formatowania (próg słów, długość pauzy, maks. 400 słów na kawałek).
- `TextFormatter` (protokół): `format(chunk:previousContext:) async throws -> String`. Implementacje:
  - `RawFormatter` — tylko złożenie segmentów i spacje;
  - `LocalLLMFormatter` — klient `/v1/chat/completions` (`URLSession`, `stream: false`, `temperature: 0`) z promptem systemowym `CleanupPrompt` (zasoby pluginu, wersjonowany), z transkrypcją w `<transcript>…</transcript>` i z ogonem poprzedniego akapitu jako kontekstem tylko do odczytu;
  - `FormatterGuard` — wycina `<think>…</think>`; jeśli liczba słów wyjścia jest poza 0,6–1,15× wejścia albo zmienił się dominujący język, odrzuca kawałek i wstawia surowy.
- `EndpointProbe` — wykrywa serwery przez `GET /v1/models` na `127.0.0.1:11434`, `:1234`, `:9931` oraz pod adresem z Ustawień.
- `LoopbackPolicy` — czysta funkcja walidująca każdy URL przed żądaniem:
  - `localhost` zamieniany na `127.0.0.1` przez Pounce, bez DNS i `/etc/hosts`;
  - akceptowane tylko dosłowne `127.x.x.x` (forma kropkowa dziesiętna) i `[::1]`;
  - odrzucane adresy `::ffff:` mapowane, liczbowe i ósemkowe formy IP, URL z userinfo (`http://127.0.0.1@evil`) i schematy inne niż `http`;
  - klient LLM używa sesji `.ephemeral` z `connectionProxyDictionary = [:]` (bez proxy, bez `URLCache` na dysku) i blokuje przekierowania w `willPerformHTTPRedirection`;
  - pobieranie modelu idzie osobną sesją, wyłącznie do `huggingface.co` i jego CDN, po HTTPS.
- `ModelManager` — katalog wkompilowanych modeli (`ModelCatalog`: id, pliki, przypięta rewizja Hugging Face, SHA-256 każdego pliku, rozmiar, licencja i atrybucja). Pakiet obejmuje **wszystko**, czego silnik potrzebuje: Parakeet (encoder, decoder, joint), słownik/tokenizer i model VAD Silero. Wbudowane pobieranie FluidAudio (`downloadAndLoad`, domyślny katalog modeli) **nigdy nie jest używane**: silnik ładuje modele wyłącznie z folderu wskazanego przez `ModelManager` (sprawdzane w spike 0.1 z zablokowaną siecią). Skompilowane modele Core ML (`.mlmodelc`) to dane wag, nie kod wykonywalny, więc nie łamią zakazu ładowania kodu w runtime (`CODE_REVIEW.md`).
  `ModelManager`:
  - pobiera przez `URLSession` do `Plugins/dictation/Models/<model-id>.partial/` i weryfikuje sumy;
  - po weryfikacji wykonuje atomowy `rename`;
  - obsługuje wskazany folder (sprawdzenie listy plików i sum, bez kopiowania), wznawianie i anulowanie.
- `TextPaster`:
  - zapisuje tekst jako element schowka z `public.utf8-plain-text` i typem znacznika `PasteboardRepresentation.transientMarkerType` (nowa publiczna stała w `PounceKit` = `org.nspasteboard.TransientType`, którą `CaptureFilter` schowka już pomija; schowek przechodzi na stałą). Dzięki temu dyktowany tekst nie dubluje się w historii schowka;
  - robi ⌘V przez `EventPoster`, z decyzją jak `PasteDecision` w schowku: brak Accessibility, Secure Event Input albo brak celu → tylko kopia, bez przywracania schowka;
  - **przywracanie** poprzedniej zawartości odbywa się tylko wtedy, gdy:
    - dostęp do schowka jest dozwolony (`accessBehavior`; inaczej plugin nie czyta schowka i nie przywraca, żeby nie wywołać monitu macOS);
    - odczyt przed wklejeniem był kompletny (żadnych pominiętych typów `dyn.*`, obietnic ani elementów ponad limit rozmiaru);
    - `changeCount` nie zmienił się od wklejenia.
    
    Przywrócony zapis też dostaje znacznik transient, więc `ClipboardPlugin` nie łapie go ponownie i nie podbija starego wpisu.
- `DictationHUD` — własny `NSPanel` (`.nonactivatingPanel`, poziom `.statusBar`, nigdy nie przejmuje fokusu, ignoruje mysz poza przyciskiem anulowania), SwiftUI w środku. Własne okno pluginu, bo panel launchera shella jest aktywowany skrótem i zasłania pole tekstowe; nie dodajemy kontraktu „overlay”, dopóki potrzebuje go jeden plugin.
- `DictationStore` + `DictationKeyStore` (Faza 3) — patrz Data Model.

**Zmiany w shellu (`PounceApp`):**
- `HotkeyRegistrar` dostaje `setKeyUpHandler(for:_:)` (KeyboardShortcuts ma `onKeyUp`) oraz tymczasową rejestrację Esc bez modyfikatorów (Carbon hotkey, połyka klawisz tylko na czas sesji); `KeyboardShortcutsRegistrar` i rejestratory QA/testowe dostają implementację.
- `HotkeyService.syncCommands` i `AppCoordinator.perform`: dla komendy z `onKeyEvent` oba zdarzenia (`.down`, `.up`) są dostarczane **synchronicznie na main actorze, w kolejności**, bez owijania w `Task` (dziś `perform` robi `Task { await run() }`, co przy szybkim tapnięciu mogłoby odwrócić kolejność). Wywołanie z menu nadal woła `run`.
- `PermissionsReader` obsługuje `.microphone` (`AVCaptureDevice.authorizationStatus(for: .audio)`).
- Ustawienia → Uprawnienia pokazują mikrofon z linkiem `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
- `Resources/Info.plist`: `NSMicrophoneUsageDescription` (en + pl przez `InfoPlist.xcstrings`); `Resources/Pounce.entitlements`: `com.apple.security.device.audio-input` (wymagane przy hardened runtime).
- `scripts/make-app.sh` kopiuje zasoby FluidAudio, jeśli je ma (jak bundle KeyboardShortcuts).
- `THIRD_PARTY_NOTICES.txt`: FluidAudio (Apache-2.0); atrybucja wag Parakeet (CC-BY-4.0) w Ustawieniach przy modelu i w notkach.

**Zależności:**
- Nowa: **FluidAudio** (Apache-2.0, `from:` z dokładnym pinem jak KeyboardShortcuts) w `DictationPlugin`. Powód: natywny Swift 6, Parakeet + VAD + strumieniowanie, najlepszy wynik dla polskiego w tej klasie.
- `DictationPlugin` zależy też od `PouncePersistence` i produktu GRDB (jak `ClipboardPlugin`).
- Brak nowych zależności dla LLM (`URLSession`).

**Pamięć i budżety (nowe wiersze w `docs/perf.md`):**

| Budżet | Cel |
|---|---|
| Od naciśnięcia skrótu do startu nagrywania i widocznego HUD | < 150 ms (model nie musi być w pamięci; audio idzie do bufora) |
| Załadowanie modelu Parakeet (zimny start) | < 3 s, w tle, bez utraty audio |
| Tekst surowy gotowy po zakończeniu 5-minutowego nagrania | < 2 s |
| Tekst sformatowany gotowy po zakończeniu (ostatni akapit ≤ 400 słów, Bielik 4.5B Q4, bazowy M-series) | < 8 s (cel do potwierdzenia w spike 0.2) |
| Pamięć w spoczynku (model zwolniony) | bez zmian: < 150 MB dla całej aplikacji |
| Pamięć w trakcie dyktowania | budżet osobny, mierzony w spike 0.1 (oczekiwane ~0,8–1,2 GB) |

## 📝 Data Model
Trzy magazyny w `Application Support/Pounce/Plugins/dictation/` (katalog 0700, pliki 0600), wszystkie prywatne dla pluginu.

1. **`Models/<model-id>/`** — pliki modelu mowy (Faza 1). Odtwarzalne (ponowne pobranie), więc nie są chronionym formatem; chroniona jest tylko ścieżka katalogu pluginu (R4). Folder wskazany przez użytkownika nie jest kopiowany; jego ścieżka siedzi w ustawieniach.
2. **`dictation.sqlite`** — SQLCipher (Faza 3), własny `DatabaseMigrator` (migracja `v1-history`), otwierany przez `DatabaseFactory.openQueue` z `DatabaseKey`.
3. **Klucz** — element Keychain `service = app.pounce.dictation` (ten sam schemat co schowek: losowy klucz główny 256 bit, HKDF-SHA256, `info = sqlcipher`). Logika `KeyStore`/`HistoryOpener` zostaje **przeniesiona** z `ClipboardPlugin` do `PouncePersistence` jako `MasterKeyStore(service:)` i `EncryptedDatabaseOpener`, z niezmienionym zachowaniem dla schowka (krok 3.1); pluginy nie mogą importować się nawzajem, a kopia logiki kluczy to gorszy wybór. Tylko `errSecItemNotFound` może zresetować bazę (archiwum `dictation.sqlite.unreadable-<data>`, 30 dni); każdy inny błąd Keychain wyłącza historię bez kasowania.

**Tabela `dictation_entry`:**

| Kolumna | Typ | Znaczenie |
|---|---|---|
| `id` | INTEGER PK | |
| `created_at` | REAL (epoch) | koniec nagrania |
| `duration_ms` | INTEGER | długość mowy |
| `raw_text` | TEXT NOT NULL | transkrypcja przed formatowaniem |
| `formatted_text` | TEXT NULL | wynik „Porządkuj”; NULL w trybie surowym albo gdy formatowanie w całości zawiodło |
| `format_mode` | TEXT | `raw` / `clean` |
| `format_status` | TEXT | `none` / `ok` / `partial` (część kawałków surowa) / `failed` |
| `detected_languages` | TEXT | np. `pl,en` |
| `speech_model_id` | TEXT | np. `parakeet-tdt-0.6b-v3` |
| `formatter_model` | TEXT NULL | nazwa modelu zgłoszona przez endpoint |
| `target_bundle_id` | TEXT NULL | gdzie wklejono; NULL przy samej kopii |
| `paste_result` | TEXT | `pasted` / `copied` / `failed` |

Wirtualna tabela **`dictation_fts`** (FTS5, `content=dictation_entry`, kolumny `raw_text`, `formatted_text`) służy do wyszukiwania w historii.

**Retencja:** `RetentionJob` usuwa wpisy starsze niż `plugins.dictation.retentionDays` (domyślnie 30) i ponad `plugins.dictation.maximumEntries` (domyślnie 500); przy usunięciu robi `VACUUM` co najwyżej raz dziennie.

**Wrażliwe dane:** treść dyktowania nigdy nie trafia do logów (tylko długości i czasy), do `ranking.sqlite` (plugin nie wywołuje `PluginContext.usage`) ani do schowka systemowego na dłużej niż do przywrócenia. Audio istnieje wyłącznie w pamięci sesji i jest zerowane po transkrypcji segmentu.

Graf modelu danych pominięty: `dictation_entry` i jej indeks FTS nie mają relacji z żadną istniejącą encją (osobna baza, jak `clipboard.sqlite`), więc diagram byłby trywialny.

## 📝 API Contracts (addytywne zmiany `PounceKit`, `BACKWARD_COMPATIBILITY.md` §1)
- `Permission.microphone` — nowy przypadek enuma (`CaseIterable`; wszystkie `switch` w drzewie aktualizowane w tym samym PR).
- `PluginCommand.onKeyEvent: (@MainActor @Sendable (KeyPhase) -> Void)?` z `enum KeyPhase { case down, up }` — gdy ustawione, skrót dostarcza oba zdarzenia synchronicznie i w kolejności zamiast wołać `run`; menu dalej woła `run`. Domyślnie `nil`, nowy parametr inicjalizatora z wartością domyślną; dotychczasowe komendy działają bez zmian.
- `PluginContext.claimEscapeKey: @MainActor @Sendable (_ onEscape: @escaping @MainActor @Sendable () -> Void) -> EscapeKeyClaim` — shell rejestruje tymczasowy globalny skrót Esc i zwraca uchwyt z `release()`; naraz może istnieć jedno przejęcie (kolejne zwraca uchwyt pusty). Domyślnie uchwyt pusty, bez rejestracji (Esc wtedy nie działa, zostaje ✕ i ponowne naciśnięcie skrótu).
- `PluginContext.hidePanel: @MainActor @Sendable () -> Void` — chowa panel launchera, jeśli jest widoczny (inaczej ⌘V trafiłoby do pola wyszukiwania panelu). Domyślnie nic nie robi.
- `PasteboardRepresentation.transientMarkerType` — publiczna stała `org.nspasteboard.TransientType`, współdzielona przez schowek i dyktowanie.
- Wszystkie zmiany są addytywne i mają wartości domyślne. Aplikację docelową plugin czyta z istniejącego `WorkspaceClient.frontmostApplication`.

**Komendy pluginu:**
- `dictation.record` — „Dyktuj”, domyślny skrót **⌃⌥D** (zmienialny), w menu paska.
- `dictation.pasteLastRaw` — „Wklej surową wersję ostatniego dyktowania”, bez domyślnego skrótu, w menu.
- `dictation.history` — tryb listy „Historia dyktowania” (Faza 3), bez domyślnego skrótu.

**Klucze ustawień (`plugins.dictation.*`, nowa chroniona przestrzeń od wydania):**

| Klucz | Typ | Domyślnie |
|---|---|---|
| `enabled` | Bool | false |
| `speechModel` | String | `parakeet-tdt-0.6b-v3` |
| `speechModelFolder` | String? | brak (= pobrany model) |
| `inputDevice` | String? (UID) | brak (= systemowe) |
| `keepWarmMinutes` | Int | 10 |
| `formatMode` | `raw`/`clean` | `raw`; `clean` zapisywane wyłącznie po wyraźnym wyborze użytkownika (wykrycie serwera nigdy nie przełącza trybu samo) |
| `formatterEndpoint` | String (URL) | brak (= autodetekcja) |
| `formatterModel` | String? | brak (= pierwszy z `/v1/models`) |
| `restoreClipboard` | Bool | true |
| `historyEnabled` | Bool | true |
| `retentionDays` | Int | 30 |
| `maximumEntries` | Int | 500 |

KeyboardShortcuts: `KeyboardShortcuts_command_dictation_record`.

**Kontrakt endpointu LLM:**
- `POST {endpoint}/v1/chat/completions` z ciałem `{model, temperature: 0, stream: false, messages: [system: CleanupPrompt, user: "<previous>…</previous><transcript>…</transcript>"]}`;
- odpowiedź `choices[0].message.content`;
- timeout 20 s na kawałek;
- bez klucza API (opcjonalny nagłówek `Authorization` dla llama-server `--api-key`, trzymany w Keychain — poza v1, chyba że spike pokaże potrzebę).

## 📝 UI/UX
- **HUD:** pigułka 220×44 pt u dołu ekranu z kursorem. Stany:
  - „Nagrywanie” — czerwona kropka, wskaźnik poziomu, czas, tryb (Surowy/Porządkuj);
  - „Ładowanie modelu…” — nagrywanie już trwa;
  - „Kończenie…” — spinner, liczba akapitów w kolejce;
  - „Wklejono” — znika po 0,8 s;
  - „Skopiowano – zezwól na Dostępność, aby wklejać”;
  - „Sformatowanie niedostępne – wklejono surowy tekst”;
  - błąd mikrofonu.
  
  Esc i przycisk ✕ anulują. Bez dźwięków w v1; tylko „Zmniejsz ruch” wyłącza animację poziomu.
- **Ustawienia → Dyktowanie:**
  - włącznik;
  - rejestrator skrótu (`makeShortcutRecorder`) z opisem „naciśnij, aby przełączyć; przytrzymaj, aby mówić”;
  - **Model mowy:** karta modelu (rozmiar, licencja, atrybucja), „Pobierz (≈ 0,6 GB z huggingface.co)” z postępem i anulowaniem, „Wskaż folder…”, „Usuń model”;
  - mikrofon (lista urządzeń, wskaźnik poziomu „Test”);
  - **Formatowanie:** tryb, status endpointu („Znaleziono Ollama na localhost:11434 – model bielik…”), pole adresu z walidacją loopback, wybór modelu z `/v1/models`, przycisk „Wypróbuj na przykładzie”, podpowiedź „Zalecany model: Bielik-4.5B-v3.0-Instruct”;
  - **Prywatność:** przywracanie schowka, historia, retencja, „Wyczyść historię”.
- **Onboarding (`dictation.setup`)**, gdy plugin włączony:
  1. mikrofon — prośba o dostęp dopiero po kliknięciu, zgodnie z zasadą „Pounce nigdy nie pyta sam”;
  2. pobranie modelu albo folder;
  3. Accessibility (ten sam stan co w schowku);
  4. opcjonalnie wykrycie lokalnego LLM.
  
  Każdy krok można pominąć.
- **Historia (Faza 3):** list mode jak schowek: lista z datą i pierwszym zdaniem, podgląd z przełącznikiem Sformatowany/Surowy, ⏎ wkleja sformatowany, ⌘⏎ surowy, ⌃X usuwa; filtry ⌘1 Wszystkie, ⌘2 Sformatowane, ⌘3 Surowe.
- **Dostępność:** HUD ma `accessibilityLabel` ze stanem i ogłasza zmiany (`NSAccessibility.post(.announcementRequested)`) przy start/stop/wklejono; kontrast i XL jak reszta aplikacji. Lokalizacja: wszystkie nowe klucze w `Localizable.xcstrings` en + pl.

## 📝 Edge Cases & Failure Scenarios

| Sytuacja | Zachowanie |
|---|---|
| Brak modelu przy naciśnięciu skrótu | HUD „Pobierz model w Ustawieniach” + przycisk otwierający Ustawienia; nic nie jest nagrywane. |
| Mikrofon odmówiony / brak urządzenia / urządzenie odłączone w trakcie | Nagranie przerwane, dotychczasowy tekst transkrybowany i wklejony (odłączenie) albo komunikat z linkiem do Uprawnień (odmowa). |
| Pobieranie przerwane / zła suma SHA-256 / brak miejsca | Folder `.partial` zostaje do wznowienia; zła suma → usunięcie i komunikat; brak miejsca sprawdzany przed startem (rozmiar + 10%). |
| Wskazany folder zniknął (odmontowany dysk) | Status „Model niedostępny” w Ustawieniach i HUD; brak cichego pobierania. |
| Ładowanie modelu się nie udało (Core ML, za mało pamięci) | `activate()` nie rzuca (plugin działa); dyktowanie pokazuje błąd; log bez treści. |
| Endpoint LLM wyłączony / timeout / błąd HTTP | Kawałek wstawiany surowy, `format_status = partial/failed`, HUD informuje; brak ponowień w trakcie sesji poza jednym retry przy błędzie połączenia. |
| LLM „odpowiada” na dyktowany prompt zamiast go formatować | `CleanupPrompt` (reguły + few-shot) + `FormatterGuard` (stosunek długości, język); odrzucony kawałek → surowy. Surowa wersja zawsze dostępna: `dictation.pasteLastRaw` i historia. |
| Model z trybem thinking (Qwen3) | Wycinanie `<think>`; jeśli po wycięciu pusto → surowy. |
| Adres endpointu spoza loopback | Odrzucony w walidacji Ustawień; klient i tak sprawdza host przed każdym żądaniem. |
| Użytkownik zmienił aplikację w trakcie nagrania | Wklejenie do aplikacji aktywnej w chwili końca. |
| Pole docelowe to pole hasła (Secure Event Input) | Tylko kopia, komunikat; wpis w historii z `paste_result = copied`. |
| Brak Accessibility | Tylko kopia do schowka, bez przywracania poprzedniej zawartości. |
| Użytkownik skopiował coś w trakcie przywracania schowka | `changeCount` się zmienił → nie przywracamy. |
| Skrót naciśnięty, gdy otwarty jest panel Pounce | `PluginContext.hidePanel` zamyka panel, wynik idzie do aplikacji pod spodem. |
| Inna aplikacja trzyma już Esc jako globalny skrót | Rejestracja się nie udaje → anulowanie tylko przez ✕ w HUD; HUD pokazuje „✕ anuluje” zamiast „Esc anuluje”. |
| Schowek zawierał typy, których nie da się wiernie odtworzyć | Brak przywracania; zawartość schowka po dyktowaniu to dyktowany tekst (jak w superwhisper). |
| Bardzo długie nagranie (> 15 min) | Twardy limit 20 min; od 18 min HUD pokazuje odliczanie, potem automatyczne zakończenie. |
| Cisza / sam szum | Brak segmentów VAD → komunikat „Nic nie usłyszano”, brak wpisu. |
| Drugie naciśnięcie w czasie „Kończenie…” | Ignorowane; nowa sesja dopiero po wklejeniu. |
| Klucz Keychain niedostępny (inny błąd niż brak) | Historia wyłączona z komunikatem; dyktowanie działa dalej. |
| Uśpienie Maca w trakcie nagrania | Silnik audio zatrzymany → jak odłączenie urządzenia. |

## 📝 Risks & Impact Review
- **Obietnica „nic nie idzie przez sieć” (decyzja produktowa, zatwierdzona w Q8):**
  - FAQ na stronie mówi dziś „No… no update check”;
  - pobieranie modelu z huggingface.co to pierwsze połączenie sieciowe Pounce, wyłącznie na wyraźne kliknięcie;
  - endpoint LLM jest tylko loopback;
  - w Fazie 1 aktualizujemy `docs/index.html` (en + pl): „Pounce łączy się z siecią tylko wtedy, gdy sam pobierasz model mowy; audio i tekst nigdy nie opuszczają Maca”.
- **Kontrakt `PounceKit`:** pięć zmian addytywnych z wartościami domyślnymi; PR kroku 1.1 jest `risk-high` zgodnie z §1 i idzie osobno, przed resztą Fazy 1.
- **Polityka sieci i ładowania kodu:**
  - `CODE_REVIEW.md` traktuje każde połączenie sieciowe jako blocker, chyba że wprowadza je spec. Ten spec wprowadza dokładnie dwa: pobieranie modelu (HTTPS, `huggingface.co`, na kliknięcie) oraz klienta LLM (tylko loopback).
  - Krok 1.8 aktualizuje `CODE_REVIEW.md` i `AGENTS.md`: oba wyjątki zostają nazwane, a pliki `.mlmodelc` uznane za dane, nie kod.
  - Logi serwera LLM użytkownika (Ollama, LM Studio) mogą zapisywać prompty jawnym tekstem; Ustawienia mówią o tym przy włączaniu formatowania.
- **Entitlement i `Info.plist`:**
  - dodanie `com.apple.security.device.audio-input` zmienia podpisane entitlements, ale nie designated requirement (identyfikator + certyfikat);
  - PR wydania musi pokazać `codesign -dr -` zgodne z poprzednim wydaniem i ręcznie potwierdzić, że Accessibility, Full Disk Access i Keychain przetrwały aktualizację (§4).
- **Przeniesienie `KeyStore`/`HistoryOpener` do `PouncePersistence`:**
  - dotyka chronionego schematu kluczy schowka (§2);
  - zachowanie musi być bajt w bajt identyczne (ten sam `service`, `account = "master-key"`, `info`, ACL);
  - `EncryptedDatabaseOpener` dostaje jako parametry nazwę archiwum i opcjonalny katalog blobów (używany tylko przez schowek);
  - krok 3.1 to osobny PR `risk-high`, przed historią dyktowania;
  - test: baza schowka utworzona przed refaktorem otwiera się po nim.
  
  Wycofanie: revert jednego kroku.
- **Nowa zależność FluidAudio:**
  - wersja 0.x, szybkie zmiany API — pin dokładnej wersji;
  - API schowane za `SpeechEngine`, więc wymiana na WhisperKit to jeden plik;
  - licencja wag CC-BY-4.0 wymaga atrybucji (notki + karta modelu).
- **Pamięć:** ~1 GB w trakcie dyktowania przekracza obecny budżet aplikacji; świadomie oddzielony budżet „w trakcie”, model zwalniany po `keepWarmMinutes`. `MallocLargeCache=0` w `Info.plist` zostaje.
- **Jakość formatowania zależy od modelu użytkownika:** Pounce nie gwarantuje wyniku; strażnik i surowa wersja ograniczają szkodę. Zestaw ewaluacyjny ze spike 0.2 trafia do repo (teksty, nie audio) jako test regresji promptu.
- **Prompt formatujący jako zachowanie widoczne dla użytkownika:** wersjonowany (`CleanupPrompt.version`, widoczny w logach diagnostycznych, nie w bazie); zmiana promptu = notka w wydaniu (§5).
- **Odwracalność:**
  - wyłączenie pluginu zatrzymuje wszystko;
  - „Erase Data” usuwa `Plugins/dictation/` (modele, bazę) i element Keychain;
  - klucze ustawień zostają do ponownego włączenia;
  - żadna zmiana nie dotyka `ranking.sqlite` ani danych innych pluginów, z wyjątkiem refaktoru kluczy (powyżej).
- **Poza zakresem:**
  - wbudowany LLM (mlx-swift-lm) — osobny spec;
  - własne tryby i prompty;
  - słownik własnych słów;
  - tekst na żywo w trakcie mówienia;
  - transkrypcja plików;
  - reguły per aplikacja;
  - modele i usługi w chmurze;
  - WhisperKit, chyba że wymusi go spike 0.1.

## 📋 Phasing
- **Faza 0 — Spike'i (bez kodu produkcyjnego w `main`, wynik jako ADR):**
  - **0.1:** silnik mowy, sprawdzany na nagraniach użytkownika (PL, EN, mieszane) — FluidAudio/Parakeet przeciw WhisperKit turbo: jakość, opóźnienia, pamięć, zgodność ze Swift 6 strict concurrency, hardened runtime i podpisem ad-hoc;
  - **0.2:** prompt formatujący z Bielik-4.5B i Qwen3-4B przez Ollama na tym samym zestawie — jakość, opóźnienie na kawałek, skuteczność strażnika.
- **Faza 1 — Dyktowanie surowe (samodzielnie użyteczne):** kontrakt, plugin, model (pobieranie / folder), nagrywanie z gestem tap/hold, transkrypcja w trakcie, HUD, wklejanie, Ustawienia, onboarding, Uprawnienia, strona WWW.
- **Faza 2 — Formatowanie dla LLM:** klient endpointu, autodetekcja, kawałkowanie w trakcie nagrania, prompt, strażnik, tryb „Porządkuj”, komenda „Wklej surową wersję ostatniego dyktowania”.
- **Faza 3 — Historia:** przeniesienie logiki kluczy do `PouncePersistence`, zaszyfrowana baza, retencja, list mode historii, Erase Data.

Każda faza to osobna gałąź `feat/` i osobny PR do `main`.

## 📋 Implementation Plan

### Faza 0 — Spike'i
- **0.1 Spike silnika mowy.**
  - Gałąź robocza z minimalnym targetem: FluidAudio i WhisperKit transkrybują 10–20 nagrań WAV użytkownika (PL, EN, mieszane, 30 s – 5 min).
  - Mierzymy WER względem ręcznej transkrypcji, czas zimnego ładowania, RTF, szczyt pamięci, budowanie ze strict concurrency i uruchomienie w bundlu podpisanym ad-hoc z hardened runtime.
  - Sprawdzamy też ładowanie modeli z lokalnego folderu przy zablokowanej sieci (FluidAudio nie może niczego pobrać samo), pełną listę plików pakietu (z VAD i tokenizerem) oraz tymczasowy globalny skrót Esc (czy połyka klawisz i czy da się go zwolnić).
  - Wynik: `docs/decisions/0003-speech-engine.md`.
  - Test: tabela wyników w ADR; decyzja Parakeet vs WhisperKit.
- **0.2 Spike formatowania.**
  - Na transkrypcjach z 0.1: `CleanupPrompt` v1 przez Ollama z Bielik-4.5B Q4 i Qwen3-4B, kawałki 120–400 słów.
  - Mierzymy czas na kawałek (bazowy M-series), oceniamy zachowanie treści (ręcznie, 3 kryteria: nic nie dodane, nic nie zgubione, język zachowany) i liczbę fałszywych odrzuceń strażnika.
  - Wynik: `docs/decisions/0004-dictation-formatting.md` + zestaw tekstów w `Tests/DictationPluginTests/Fixtures/cleanup/` (tylko tekst, za zgodą użytkownika).
  - Test: ADR z tabelą; potwierdzony albo skorygowany budżet „< 8 s”.

### Faza 1 — Dyktowanie surowe
- **1.1 Kontrakt (osobny PR, `risk-high`).**
  - Zmiany: `Permission.microphone`, `PluginCommand.onKeyEvent` + `KeyPhase`, `PluginContext.claimEscapeKey` + `EscapeKeyClaim`, `PluginContext.hidePanel`, `PasteboardRepresentation.transientMarkerType`, wszystkie z wartościami domyślnymi.
  - Implementacje w shellu: `PermissionsReader`, `HotkeyRegistrar` (key-up, tymczasowy Esc), synchroniczne dostarczanie faz w `AppCoordinator`. `CaptureFilter` schowka przechodzi na wspólną stałą. Uprawnienia pokazują mikrofon tylko, gdy wymaga go włączony plugin.
  - Test:
    - `PounceKitTests`: domyślne wartości;
    - `PounceAppTests`: `.down` i `.up` dostarczone w kolejności, także gdy przychodzą w tym samym przebiegu pętli zdarzeń; komenda bez `onKeyEvent` dalej woła `run`; drugie przejęcie Esc zwraca pusty uchwyt; `release()` wyrejestrowuje; mapowanie statusu mikrofonu;
    - `ClipboardPluginTests`: znacznik transient z `PounceKit` jest pomijany.
- **1.2 Szkielet pluginu.**
  - Target `DictationPlugin` + `DictationPluginTests`, zależność FluidAudio (pin), rejestracja w `PluginRegistry`, manifest z `defaultEnabled: false`.
  - `Info.plist` (`NSMicrophoneUsageDescription` en/pl), entitlement audio-input, `make-app.sh` (zasoby), notki licencyjne.
  - Test: `swift build`, test rejestru pluginów, `StringCatalogTests`, `codesign -d --entitlements -` na zbudowanej aplikacji.
- **1.3 `ModelCatalog` + `ModelManager`.**
  - Pobieranie z wznawianiem i SHA-256, atomowe przeniesienie, wskazany folder, usuwanie, sprawdzenie miejsca.
  - Test: jednostkowy z `URLProtocol` stubem (dobra suma, zła suma, przerwanie, wznowienie, brak miejsca) i tymczasowymi katalogami.
- **1.4 `RecordingGesture`.**
  - Czysta maszyna stanów tap/hold/menu/Esc z wstrzykiwanym zegarem.
  - Test: każda komórka tabeli stan × zdarzenie (w tym autorepeat key-down, menu w każdym stanie, Esc w każdym stanie, zdarzenia w `finishing`).
- **1.5 `AudioCapture` + `SpeechEngine`/`ParakeetEngine` + `DictationSession`.**
  - Bufor podczas ładowania modelu, segmenty VAD transkrybowane w trakcie, sklejanie, `keepWarm`/unload, limit 20 min.
  - Test: `DictationSession` z fałszywym `SpeechEngine` i źródłem audio z pliku (kolejność segmentów, anulowanie, cisza, limit); test integracyjny z prawdziwym modelem tylko lokalnie (jak benchmarki, domyślnie wyłączony).
- **1.6 `TextPaster`.**
  - Znacznik transient, ⌘V przez `EventPoster`, warunkowe przywracanie schowka (dostęp, kompletny odczyt, `changeCount`), decyzje kopiuj/wklej.
  - Test: nazwany pasteboard + `EventPoster` testowy. Przypadki:
    - wklejono;
    - brak Accessibility;
    - Secure Event Input;
    - cel zniknął;
    - zmieniony `changeCount`;
    - niekompletny odczyt → brak przywracania;
    - dostęp niedozwolony → brak odczytu;
    - przywrócony zapis ma znacznik transient.
- **1.7 `DictationHUD`.**
  - Stany, dostępność, „Zmniejsz ruch”.
  - Test: testy modelu widoku stanów; QA ręczne ze zrzutami (jasny/ciemny) w PR.
- **1.8 Ustawienia + onboarding + strona WWW.**
  - Panel Dyktowania (model, mikrofon, skrót), krok `dictation.setup`, aktualizacja FAQ `docs/index.html` (en + pl, `data-i18n`), `docs/perf.md` (nowe wiersze), `AGENTS.md`, `CODE_REVIEW.md` (wyjątki sieciowe, `.mlmodelc` jako dane) i `BACKWARD_COMPATIBILITY.md` (nowy plugin, klucze, entitlement), `docs/qa.md` (zgoda na mikrofon ginie przy każdym przebudowaniu podpisanym ad-hoc).
  - Test: `StringCatalogTests`, workflow `pages.yml`, QA ręczne z `--qa…` (izolowane ustawienia; mikrofon wymaga ręcznego testu).
- **1.9 Pomiary.**
  - Budżety z sekcji Architecture zmierzone i wpisane do `docs/perf.md`; ręczne przejście VoiceOverem.
  - Test: tabela w PR.

### Faza 2 — Formatowanie dla LLM
- **2.1 `EndpointProbe` + `LoopbackPolicy`.**
  - Test: stub `URLProtocol` dla trzech portów.
  - Odrzucane przez `LoopbackPolicy`:
    - `example.com`, `192.168.x`, `0.0.0.0`;
    - `[::ffff:127.0.0.1]`;
    - `http://2130706433`, `http://0177.0.0.1`;
    - `http://127.0.0.1@evil.com`;
    - `https` do hosta spoza loopback.
  - `localhost` mapowany na `127.0.0.1` bez DNS.
  - Przekierowanie z serwera stubu zablokowane.
  - Sesja bez proxy i bez cache na dysku.
- **2.2 `LocalLLMFormatter` + `CleanupPrompt` + `FormatterGuard`.**
  - Test: stub odpowiedzi (poprawna, z `<think>`, za długa, za krótka, inny język, timeout, HTTP 500) → oczekiwany wynik albo surowy kawałek; prompt-snapshot test.
- **2.3 `Segmenter` i formatowanie w trakcie nagrania.**
  - Kolejka kawałków w `DictationSession`, kontekst poprzedniego akapitu, kolejność wyniku niezależna od kolejności odpowiedzi.
  - Test: fałszywy formatter z losowymi opóźnieniami → poprawna kolejność; anulowanie w trakcie formatowania.
- **2.4 Ustawienia i HUD dla formatowania.**
  - Tryb, status endpointu, wybór modelu, „Wypróbuj”, komunikaty częściowego formatowania, komenda `dictation.pasteLastRaw` (ostatni surowy tekst tylko w pamięci).
  - Test: modele widoków; QA ręczne z Ollama.
- **2.5 Test regresji promptu.**
  - Zestaw z 0.2 uruchamiany lokalnie przeciw endpointowi (domyślnie wyłączony, jak benchmarki), wynik w PR przy zmianie promptu.

### Faza 3 — Historia
- **3.1 Przeniesienie logiki kluczy.**
  - `MasterKeyStore(service:)` i `EncryptedDatabaseOpener` w `PouncePersistence`; `ClipboardPlugin` przechodzi na nie bez zmiany zachowania.
  - Test: istniejące testy schowka bez zmian + nowy test „baza schowka z poprzedniego wydania otwiera się po refaktorze”.
- **3.2 `DictationStore`.**
  - Migracja `v1-history`, FTS5, zapis po każdej sesji, `RetentionJob`.
  - Test: migracja na pustej bazie, wyszukiwanie FTS, retencja (dni i liczba), błąd Keychain → historia wyłączona bez kasowania, `errSecItemNotFound` → archiwum.
- **3.3 List mode „Historia dyktowania”.**
  - Podgląd sformatowany/surowy, ⏎/⌘⏎/⌃X, filtry.
  - Test: `PanelModeSource` (kolejność, filtry, akcje); QA ręczne ze zrzutami.
- **3.4 Prywatność i Erase Data.**
  - Ustawienia historii, „Wyczyść historię”, `eraseData()` usuwa element Keychain.
  - Test: `eraseData` z `InMemoryKeychainClient`; QA ręczne.
