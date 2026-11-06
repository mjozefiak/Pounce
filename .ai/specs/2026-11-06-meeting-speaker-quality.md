# Jakość etykiet mówców: pomiar diaryzacji

Powiązany spec: `2026-11-06-meeting-speaker-names.md` (nazwy). Ten spec jest **pierwszy** i jest głównie pomiarem.

## 📝 TLDR
Użytkownicy Lintela oglądają transkrypt i notatki z etykietami mówców, ale nie wiemy, jak często etykieta jest poprawna: na nagraniu ovn-kubernetes wykryto 9 mówców i nie wiadomo, czy to prawda, a etykieta jest nadawana segmentowi ASR (~15 s), więc szybka wymiana zdań dostaje jedną etykietę. Proponowane przyszłe zachowanie: najpierw zmierzyć dokładność przypisania mówców na ręcznie oznaczonym fragmencie, a dopiero wynik decyduje, czy dzielimy segmenty na zmianie mówcy. Powód: nazwy mówców (osobny spec) nic nie dadzą na błędnych etykietach.

## 📝 Problem Statement
- `SpeakerAssigner` przypisuje segmentowi mówcę po największym nakładaniu czasu; segment ASR bywa dłuższy niż wypowiedź jednej osoby (przykład z ovn: `[33:32]` łączy prośbę i odpowiedź pod jedną etykietą).
- Dokładność diaryzacji (`FluidDiarizer`, community-1) nie była mierzona na żadnym nagraniu; „rozpoznawanie mówców działa dobrze” to wrażenie, nie pomiar.

## 📝 Proposed Solution
1. **Pomiar (Faza 1).** Fragment 5–10 min polskiego nagrania (DevMentors) i fragment ovn są oznaczone ręcznie przez Claude’a na podstawie transkryptu z czasami (decyzja Q5; bez udziału użytkownika), wynik zapisany jako plik odniesienia w eval-harness. Metryki: zgodność etykiet per segment po dopasowaniu klastrów do mówców odniesienia, liczba wykrytych klastrów vs prawdziwa liczba osób, odsetek segmentów mieszających co najmniej dwie osoby.
2. **Decyzja po pomiarze (Faza 2).** Jeśli odsetek segmentów mieszających osoby jest niski (próg zapisany z góry w kroku 1.3), nic nie zmieniamy w potoku; jeśli wysoki, projektujemy podział segmentów po znacznikach czasu słów z diaryzacji (Q6: dopiero po pomiarze).

Odrzucone: *podział segmentów od razu* (zmiana potoku zanim wiemy, czy boli); *korpus z internetu jako jedyny pomiar* (angielski, niepodobny do spotkań użytkownika).

## 📝 Architecture
- Bez zmian w kodzie produktu w Fazie 1: tylko harness w `Tests/MeetingsPluginTests/Eval/` i skrypt w archiwum `Pounce-eval-archive/scripts/`.
- Dane odniesienia (etykiety mówców) są w archiwum, nie w repozytorium: transkrypty spotkań nie wchodzą do gita.
- Faza 2 (warunkowa) dotknęłaby `SpeakerAssigner` i potoku ASR → diaryzacja; projekt dopiero po wyniku.

## 📝 Edge Cases & Failure Scenarios
- **Główne ograniczenie metody:** oznaczający widzi tekst, nie dźwięk, więc mierzymy „odsetek segmentów mieszających osoby widoczny w tekście”, nie dokładność diaryzacji. Błędów niewidocznych w tekście (podobni mówcy, klaster przecięty w środku zdania) metoda nie wykryje, a ten sam model oznacza i ocenia. Dlatego dodajemy drugi sygnał niewymagający oznaczania: liczba klastrów vs liczba osób, które się przedstawiają, plus 10 segmentów do potwierdzenia ze słuchu przez właściciela (opcjonalnie). Oznaczenia robione z transkryptu bez dźwięku są niepewne przy nakładającej się mowie; segmenty niejednoznaczne oznaczamy `unknown` i wyłączamy z metryki, raportując ich liczbę.
- Mały fragment (5–10 min) wykrywa rażące błędy, nie estymuje dokładności z przedziałem ufności; wynik raportujemy tak, nie jako „dokładność X%”.
- Wynik dla jednego nagrania nie uogólnia się na inne akustyki; zapisujemy to w wynikach.

## 📝 Risks & Impact Review
Niskie: pomiar, bez zmian w produkcie. Ryzyko metodologiczne (oznaczający i oceniający to ten sam model) łagodzimy zapisem reguł oznaczania przed pomiarem i raportowaniem liczby `unknown`.

## 📋 Phasing
1. **Faza 1 — pomiar** (bez zmian w produkcie).
2. **Faza 2 — warunkowe przekazanie:** tylko wskazanie, czy potrzebny jest osobny spec poprawy podziału segmentów.

## 📋 Implementation Plan

### Faza 1 — pomiar
- **1.1** Reguły oznaczania zapisane w archiwum (kto jest kim, co to `unknown`) przed oznaczaniem.
- **1.2** Oznaczenie odniesienia 5–10 min polskiego i ovn (pliki w archiwum). Weryfikacja: losowa próbka 20 segmentów sprawdzona ponownie przez drugi przebieg, zgodność raportowana.
- **1.3** Metryki jako kod Swift w `Tests/MeetingsPluginTests/Eval/` (zgodność per segment, liczba klastrów vs osoby, odsetek segmentów mieszających; w archiwum zostają tylko dane odniesienia, bo CI uruchamia `swift test`). **Próg decyzji, ustalony przed pomiarem:** Faza 2 startuje, gdy odsetek segmentów mieszających przekracza 10% albo liczba klastrów różni się od liczby osób o co najmniej 2. Test jednostkowy metryk na sztucznym przykładzie ze znanym wynikiem.
- **1.4** Raport w `PLAN-meeting-notes-quality.md` z liczbami, liczbą `unknown` i wnioskiem (zmieniamy/nie zmieniamy Fazy 2).

### Faza 2 — warunkowa
- **2.1** Poza zakresem tego specu: jeśli próg z 1.3 zostanie przekroczony, podział segmentów dostaje własny spec (z testami `SpeakerAssigner`, benchmarkiem 1 h i pomiarem przed/po). Ten spec kończy się raportem z kroku 1.4.

## Decyzje użytkownika (bramka zamknięta)
Q5 oznacza Claude, 5–10 min nagrania · Q6 podział segmentów dopiero po pomiarze.

## Wynik kroków 1.1–1.2 (2026-11-06)
Pełny raport: `Pounce-eval-archive/diarization-measurement/REPORT.md`. Miara widoczna w tekście, nie dokładność; ten sam model oznaczał i weryfikował (zgodność 19/20, nieniezależna).
- Segmenty mieszające osoby: ovn 15,2% i 20,0% (okna 10–20 i 20–30 min), polski 5,7% (4,7–23,3% zależnie od 8 `unknown`). **Próg 10% przekroczony na ovn.**
- Klastry vs osoby: ovn 9 klastrów, 9–10 osób nazwanych w tekście (różnica 0–1); polski 2 vs 2. Kryterium liczby klastrów nie zadziałało.
- Wniosek: liczba mówców wygląda poprawnie, problemem jest **ziarnistość** (segment ASR ~15 s dostaje jedną etykietę, a krótkie pytanie i odpowiedź lądują razem). Faza 2 (osobny spec podziału segmentów) jest uzasadniona. Do kroku 1.3 (metryki w Swifcie) nadal należy ten sam pomiar jako powtarzalny test.
