# Harness jakości spotkań (transkrypcja i notatki)

## 📝 TLDR

Właściciel jest niezadowolony z jakości transkrypcji spotkań i generowanych z niej notatek. Dziś nie ma powtarzalnego pomiaru: testy na prawdziwych modelach (`LINTEL_*`) wypisują tekst przez `print`, nie ma kodu WER/CER, JSON-ów wyników ani porównania między uruchomieniami, a `docs/perf.md` (sekcje Meetings, Diarization, Notes) mówi „not measured". Proponowane (przyszłe zachowanie): offline'owy harness złożony z testów Swift wyłączonych domyślnie, które puszczają prawdziwe nagrania przez `MeetingSession` (plik WAV → VAD → ASR → segmenty → diarization) i `NotesPipeline`, zapisują wyniki jako JSON, oraz skryptu Python, który liczy metryki i porównuje przebiegi. Dopiero na tym baseline'ie wolno oceniać ulepszenia.

## ✅ Rozstrzygnięte pytania (2026-11-06, właściciel)

| # | Decyzja |
|---|---|
| Q1 Zakres | Bazą jest PR #52 (`feat/lintel-main-window`, repo nazywa się tam Lintel): zawiera `MeetingSession`, diarization i `NotesPipeline`. Mierzymy realny pipeline, nie klocki. |
| Q2 Forma | Testy Swift + JSON + Python (opcja A). Bez zmian w `Package.swift`, więc `risk-low` wg SDLC.md. Pomiary w `-c release`. CLI (opcja B) ewentualnie później, osobnym PR-em `risk-high`. |
| Q3 Narzędzia | `yt-dlp` i `ffmpeg` zainstalowane (zweryfikowane: `/opt/homebrew/bin`). |
| Q4 Referencja WER | „Złote fragmenty": 3 fragmenty po 3-5 min z filmu, szkic z mocnego modelu porównany z napisami YouTube, poprawiony i sprawdzony wyrywkowo przez właściciela. Reszta filmu służy do notatek i stabilności. |
| Q5 Sędzia notatek | Subagent `opus`, niezależny od generatora, stała wersjonowana rubryka. |
| Q6 Modele | Pobieramy Whisper large-v3-turbo (~1,5 GB) i Qwen3-30B-A3B (~19 GB). |
| Q7 Diarization | Mierzymy czas, pamięć, liczbę mówców (bez DER). Zmian w diarization nie robimy. |
| Q8 Gałąź | Pierwotnie stos na `feat/lintel-main-window`; PR #52 został w międzyczasie zmergowany, więc gałąź robocza `feat/meeting-quality-harness` bazuje na `main` (PR #57). Ten spec jest design-only. |
| Q9 Nagrania | Film DevMentors + angielskie wielu mówców/szum + polskie wielu mówców/żargon + FLEURS-pl (czysta referencja). |

## 📝 Stan wyjściowy (zweryfikowany w kodzie, commit `5bba7f3`)

- `Recording/MeetingSession.swift` (actor): wejście przez port `AudioInput`; `WAVFileAudioSource` (16 kHz mono) pozwala podać plik zamiast mikrofonu. Wystarczy `await session.start(); await session.finish()`. Zależności do podstawienia w teście: `MeetingsStore.open(in:keys:)` z kluczami testowymi, `SpoolStorage` w katalogu tymczasowym, `SleepAssertion`, `MeetingSessionGate`, świeży `SpeechEngineLease()`, prawdziwy `ParakeetEngine`/`WhisperKitEngine`, `LazyVAD(SileroVAD)`. Typy są `internal`, więc `@testable`.
- Segmentacja: Silero VAD z domyślnymi parametrami FluidAudio (brak pokręteł), twardy limit segmentu 15 s, brak nakładania segmentów. Pre-roll 0,5 s jest trzymany w pamięci, ale z kodu nie wynika, że trafia do transkrybowanego fragmentu (niezweryfikowane uruchomieniem).
- Na szybkim wejściu z pliku może zadziałać zapasowa ścieżka 60 s (`backgroundLimit`): segmenty idą do spoola i są transkrybowane po `finish()`. Wynik końcowy ten sam, ale pomiar czasu trzeba tak interpretować.
- ASR: domyślnie `parakeet-ultra` (bez kontroli języka, ryzyko dryfu do angielskiego, ADR 0003), alternatywa `whisper-large-v3-turbo` z językiem ustawianym `plugins.meetings.speechLanguage`. `RepetitionFilter` działa tylko dla Whispera. Brak słownika/promptu kontekstowego w obu silnikach.
- Echo mikrofon/system: `EchoSuppressor` (progi stałe w kodzie). Diarization: `FluidDiarizer` + `SpeakerAssigner`, budżet 90 min na ścieżkę oznaczony jako niezmierzony.
- Notatki: `NotesPipeline.run(utterances:)` działa na samym tekście (`[NotesUtterance]`) z `NotesModel(lease:runtime:modelURL:)`; map-reduce: kontekst 8192, chunk 3000 tokenów, nakładanie 3 wypowiedzi, reduce 4500, `mapMaxTokens` 700, `reduceMaxTokens` 1500, `NotesPrompt.version = 1`, `NotesGuard` weryfikuje cytaty. Model z `plugins.meetings.builtInLLMModel` (katalog: Qwen3-4B domyślny, Qwen3-30B-A3B).
- Pomiary dziś: `RealNotesTests` (`LINTEL_NOTES_LLM_MODEL`, `LINTEL_NOTES_TRANSCRIPT`, `LINTEL_NOTES_LONG_REPEAT`) wypisuje `NOTES-BENCH` z czasem i pamięcią; `DiarizationBenchmarks` (`LINTEL_DIARIZATION_MODEL_FOLDER`, `LINTEL_DIARIZATION_BENCH_AUDIO`) wypisuje czas, pamięć, liczbę mówców (pamięć „during" mierzona po zakończeniu, nie jest szczytem). Fixtures notatek (`Fixtures/notes/*.json`) są krótkie i syntetyczne.
- Brak: WER/CER, JSON wyników, korpusu audio z referencją, pomiaru halucynacji na ciszy.

## 📝 Problem Statement

Bez metryk każda zmiana (silnik, VAD, prompt, chunking, model LLM) jest zgadywaniem. Skargi na jakość dotyczą dwóch rzeczy: błędów rozpoznawania (nazwy własne, żargon, polski, wielu mówców) oraz notatek (kompletność, zmyślenia). Trzeba je rozdzielić, żeby wiedzieć, czy winny jest ASR czy generowanie.

## 📝 Proposed Solution

1. **Zestaw nagrań** (poza repo, w katalogu roboczym): film DevMentors `_kNc-n9Q26M` (PL, 3593 s, jeden wywiad, tylko napisy automatyczne), jedno nagranie EN wielu mówców z szumem (kandydat: AMI, licencja do potwierdzenia), jedno PL wielu mówców z żargonem (do wskazania po sprawdzeniu napisów i licencji), FLEURS-pl jako czysta referencja. Skrypt pobierający i konwertujący do 16 kHz mono WAV (`yt-dlp`, `ffmpeg`) trafia do repo, media nie.
2. **Referencje**: dla filmu DevMentors trzy „złote fragmenty" po 3-5 min (szkic mocnego ASR + napisy YouTube, korekta, wyrywkowa weryfikacja właściciela); dla korpusów ich oficjalne transkrypcje. Pozostałe części nagrań nie mają WER, tylko metryki bez referencji (halucynacje, powtórzenia, stabilność, RTF, pamięć, notatki).
3. **Runner** (Swift Testing, `LINTEL_MEETING_EVAL_*`, wyłączony w CI): dla każdego nagrania i konfiguracji (silnik, język, model LLM) uruchamia `MeetingSession` na pliku WAV w `-c release`, zapisuje `results/<run-id>/<nagranie>.json` (segmenty z czasami i tekstem, RTF, szczytowa pamięć próbkowana w tle, wersja kodu, silnik, model, liczba segmentów deferred, diarization: czas/pamięć/liczba mówców) i osobno puszcza `NotesPipeline` na transkrypcie (tekst, status, liczniki `dropped`/`failedChunks`, czas, pamięć). Wyniki zawierają treść transkrypcji, więc leżą tylko w katalogu roboczym, nigdy w repo ani w logach.
4. **Scorer** (`scripts/meeting-eval/*.py`, stdlib, uruchamiany z `python3 -I`): normalizacja (małe litery, interpunkcja, liczby) i WER/CER na złotych fragmentach; błędy terminów z ręcznej listy na nagranie; liczniki halucynacji na odcinkach ciszy i pętli powtórzeń; dryf WER po oknach 10 min; zestawienie Markdown „baseline vs zmiana".
5. **Ocena notatek**: rubryka punktowa (kompletność decyzji/zadań/osób/terminów, wierność źródłu z liczbą nieuzasadnionych twierdzeń, zwięzłość, struktura) w pliku wersjonowanym w repo; sędzią subagent `opus` w osobnym kontekście, wejście: transkrypt + notatki, bez wiedzy, który wariant je wygenerował; do tego deterministyczne sprawdzenia (nazwy i liczby z notatek występują w źródle).

## 📝 Architecture

Nowe pliki wyłącznie w `Tests/MeetingsPluginTests/Eval/` (runner, writer JSON, pomiar pamięci), `scripts/meeting-eval/` (pobieranie, konwersja, scorer), `docs/` (opis i raport baseline). Zero zmian w `Sources/`, `Package.swift`, kontraktach `LintelKit`. Zależności tylko w dół, prywatność: audio nie jest zapisywane poza szyfrowanym spoolem tworzonym przez sesję w katalogu tymczasowym usuwanym po teście; treści transkrypcji i notatek nie trafiają do logów ani `ranking.sqlite`; wyniki pomiarów z treścią zostają poza repo.

## 📝 Metryki

Transkrypcja: WER, CER, błędy terminów/nazw, halucynacje na ciszy/szumie, pętle powtórzeń, dryf WER na długim nagraniu, RTF (czas/czas audio), szczytowa pamięć, liczba segmentów deferred. Diarization: czas, pamięć, liczba wykrytych mówców (bez DER). Notatki: rubryka sędziego, `dropped`/`failedChunks`, czas, pamięć. Znane ograniczenia: referencja złotych fragmentów zależy od jakości korekty; WER mierzymy tylko na fragmentach; sędzia LLM jest szumny (powtarzamy ocenę i raportujemy rozrzut).

## 📝 Edge Cases & Failure Scenarios

Nagranie krótsze niż 15 s jest odrzucane przez sesję (`discardBelow`). Brak zainstalowanego modelu → test pominięty z komunikatem, nie błąd. Szybkie wejście z pliku uruchamia ścieżkę spoola; runner raportuje ją, żeby RTF nie był mylący. Pomiar szczytu pamięci wymaga próbkowania w tle (nie wartości na końcu). Wyniki z `debug` są odrzucane (runner sprawdza konfigurację).

## 📝 Risks & Impact Review

Niskie: zmiany tylko w testach i skryptach (`risk-low`, `skip-qa`). Ryzyka: prawa do materiału z internetu (nic z mediów ani cudzych transkrypcji do repo; fixture <30 s tylko jeśli licencja pozwala), wysyłka transkryptów publicznych nagrań do sędziego Claude (zaakceptowana w Q5), rozjazd z PR #52 (rebase), 19 GB Qwen3-30B tylko lokalnie.

## 📋 Phasing

- **Faza 1 (baseline):** runner, scorer, rubryka, nagrania, złote fragmenty, pomiar stanu obecnego (Parakeet i Whisper turbo × oba modele LLM). Zamykamy raport „baseline" w scratchpadzie i w `docs/perf.md`.
- **Faza 2 (eksperymenty):** jedna hipoteza = jeden pomiar. Kandydaci do sprawdzenia (nie założenia): silnik i język, Parakeet vs Whisper dla PL, dołączenie pre-rollu do segmentu, nakładanie segmentów, `RepetitionFilter` także dla Parakeeta, słownik/prompt kontekstowy, limit segmentu 15 s, progi `EchoSuppressor`, parametry chunkingu i prompt notatek, Qwen3-4B vs 30B.
- **Faza 3 (wdrożenie):** zwycięskie zmiany jako osobne PR-y z testami i raportem przed/po.

## 📋 Implementation Plan

### Faza 1
1. Skrypt `scripts/meeting-eval/fetch.sh` (yt-dlp + ffmpeg → 16 kHz mono WAV w katalogu wskazanym argumentem, napisy YouTube obok); test: uruchomienie na krótkim fragmencie, plik ma 16 kHz mono (ffprobe).
2. Zestaw nagrań i lista terminów na nagranie; potwierdzenie licencji AMI/FLEURS; wybór nagrania PL wielu mówców.
3. Złote fragmenty: szkic ASR + napisy → korekta → weryfikacja właściciela; zapis w katalogu roboczym.
4. `Tests/MeetingsPluginTests/Eval/`: writer JSON z wersją schematu, próbkowanie pamięci, runner `MeetingSession` z pliku WAV (wyłączony bez `LINTEL_MEETING_EVAL_AUDIO`); test jednostkowy writera i schematu włączony w CI.
5. Runner notatek na transkrypcie (`NotesPipeline`) z wyborem modelu GGUF; zapis JSON.
6. `scripts/meeting-eval/score.py` (WER/CER, halucynacje, dryf, zestawienie baseline/zmiana) z testami na danych syntetycznych (`python3 -I`).
7. Rubryka notatek (wersjonowany plik) i protokół sędziego.
8. Pobranie modeli (Whisper turbo, Qwen3-30B) przez `ModelManager`/`LINTEL_*_DOWNLOAD` lub ręcznie do `Models/`; pomiar baseline na wszystkich nagraniach; raport.
9. Bramka: `swift build`, `swift test`, `swift format lint --strict -r Sources Tests`; PR z opisem pomiarów.

### Faza 2 i 3
Zdefiniowane po baseline (lista hipotez wyżej, kolejność wg największego wpływu na metryki).
