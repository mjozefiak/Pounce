# Makieta v2: HUD dyktowania, pokazanie cięcia samopoprawki (wariant B)

Statyczny HTML, bez kodu aplikacji, bez PR; nic nie dodano do repo. Otwórz `index.html` (przełączniki jasny/ciemny, PL/EN; `?theme=dark&lang=pl&shot=ref|b|life|big|hist` pokazuje jedną sekcję).

## Zawartość
- `index.html`: tylko wariant B z decyzjami 1–7: linia z przekreślonym fragmentem, przycisk Cofnij w HUD + ⌃Z, lista do 3 cięć (+N), ⌃Z cofa ostatnie, ⇧⌃Z wszystkie, stan „propozycja cięcia” (nic nie tnie, ten sam klawisz wycina), czas życia 6 s i wcześniejsze znikanie, rozmiar XL tekstu (narysowany), Zwiększony kontrast, Redukcja ruchu, tabela VoiceOver („Wklejono, 1 cięcie”), wiersz historii (przekreślony fragment, plakietka, „Wklej bez cięcia”).
- `wzorzec-*.png`: zrzuty PRAWDZIWEGO HUD dyktowania (nagrywanie, kończenie, wklejono, wklejono częściowo oczyszczone) i PRAWDZIWEGO widoku historii dyktowania, jasne i ciemne. Źródło: debug app z `origin/main` (1dcc8c96), własny worktree, `CONFIGURATION=debug scripts/make-app.sh`, uruchomiona z `--qa` (izolowane dane, nie /Applications, nie podpisana certyfikatem wydania). Zrzuty okien przez `screencapture -l`.
- `zrzut-<light|dark>-<pl|en>-<ref|b|life|big|hist>.png`: 20 zrzutów makiety, JEDEN proces własnego Chromium (playwright-core 1.65, chromium-headless-shell, domyślny tymczasowy profil; Chrome właściciela nie uruchamiano).

Dane: wszystkie zdania wymyślone (także w zrzutach wzorca).

## Jak wywołano stany wzorca (ważne)
W `--qa` nie ma flagi pokazującej HUD dyktowania ani zasiewającej historię (HUD wymaga prawdziwego nagrywania, mikrofonu i modelu). Zrobiłem więc LOKALNY, niezacommitowany patch DEBUG w moim worktree (klucze `plugins.dictation.qaHUD=cycle` i `qaHistorySeed=demo`: wywołanie `DictationHUDPanel.show(...)` w zadanym stanie i 4 wymyślone wpisy przez `history.record`). Widoki (`DictationHUDView`, panel historii) są prawdziwe, ale stany sztucznie wywołane; patch nie trafił do repo. Worktree usunięto po pracy.

## Czego NIE sprawdzono
- ⌃Z na działającej aplikacji: czy przechwycenie klawisza na czas widoczności linii działa i jak koliduje z suspend (SIGTSTP) w terminalu oraz z ⌃Z w aplikacjach docelowych. Do testu przy implementacji (decyzja 2).
- Cofnięcie w miejscu w prawdziwych aplikacjach (czy da się zamienić świeżo wklejony tekst; ruch kursora/zmiana pola jako unieważnienie): tylko opisane.
- Prawdziwy HUD z linią cięć: nie istnieje; nowy wiersz i karta 336 pt to rysunek. Liquid Glass w makiecie jest przybliżony; zrzuty wzorca okien przechwycone bez tła pulpitu (ciemniejsze/szarsze niż nad prawdziwym oknem), więc kolor szkła porównano z kodu i zrzutów, nie 1:1 na pulpicie.
- Nie wywołano prawdziwego HUD „Cofnięto”, „Propozycja cięcia” ani prawdziwego wiersza z plakietką: tych stanów nie ma w aplikacji.
- Duży tekst: rozmiar XL = skala 1,3 (z `TextSize.scale`), karta narysowana, nie zmierzona w aplikacji; HUD w prawdziwej aplikacji ma stałe 248×40 pt i NIE skaluje się z tekstem (zrzuty nie testowały XL w prawdziwym HUD).
- VoiceOver, Reduce Motion, Zwiększony kontrast: tylko narysowane/opisane, nie testowane w aplikacji.
- Opóźnienie z noty pomiarowej PR #180 (0,33 s na marker) nie z aplikacji.
- Klawisz „Wklej bez cięcia” ⌥↩ to placeholder (⌘↩ to już „Wklej surowy”; ⌥ na układzie PL wpisuje znaki: kolizja do sprawdzenia).
- Nie rozstrzygnięte w decyzjach: czy drugi ⌃Z po cofnięciu tnie ponownie (B2 pokazuje tylko „przywrócono”); który z kilku cięć jest „ostatnie” przy „+N” (przyjęto: najnowsze); wycięty fragment obejmujący wcześniejszy marker (reguła lewo→prawo z noty) nienarysowany; definicja „niepewne” (liczbowa) nieustalona.
- Korekta polszczyzny: moja, bez konsultacji z native speakerem; liczby (1 cięcie, 2–4 cięcia, 5+ cięć) uwzględnione.
- Brak badań z użytkownikami; czas 6 s i pasek odliczania to wartości z decyzji, nietestowane.
