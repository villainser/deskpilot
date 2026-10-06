# DeskPilot Native 0.1.2

Autorska, samodzielna aplikacja macOS oparta na zasadach DeskPilot 2. Natywny panel SwiftUI/AppKit oraz obsługa Spaces w Swift i Objective-C. Hammerspoon, WebKit, helper uruchamiany co kilka sekund i osobny menedżer okien nie są wymagane.

## Stan wydania

To wersja rozwojowa do weryfikacji na komputerze użytkownika. Kompilacja i 22 testy reguł przeszły. Na macOS 27.0.1 potwierdzono odczyt jednego monitora i sześciu biurek oraz obecność mechanizmu przenoszenia. W procesie testowym uruchomionym z narzędzia diagnostycznego wykonano rzeczywisty test: własne okno testowe zostało przeniesione na drugie istniejące biurko, odczyt potwierdził cel, a następnie potwierdził powrót na pierwotne biurko. Przywracanie całych profili oraz podłączanie i odłączanie monitorów zewnętrznych wymagają jeszcze testu na docelowym zestawie monitorów.

## Uruchomienie

1. Uruchom `DeskPilot Native.app`. Pierwszy start ma wstrzymaną automatykę. Aplikacja jest widoczna w Docku oraz na pasku menu. „X” chowa panel; **Zakończ DeskPilot** lub **Cmd+Q** kończy cały proces.
2. Kliknij **Nadaj dostęp**. Na macOS 27 otworzy się Ustawienia systemowe → Prywatność i ochrona → **Sterowanie urządzeniami i dostęp do danych**; na starszych systemach ten dostęp nazywa się **Dostępność**. Po powrocie do aplikacji uprawnienie jest sprawdzane ponownie. Jeżeli stary wpis jest włączony, a program nadal nie ma dostępu, usuń ten wpis i dodaj dokładnie uruchamianą kopię `.app`. Przycisk **Pokaż tę kopię w Finderze** wskazuje właściwy plik. Lokalny podpis może wymagać odnowienia wpisu po przebudowie.
3. Przed włączeniem automatyki wstrzymaj poprzedni DeskPilot w Hammerspoonie.
4. W Biurku i Docku wyłącz automatyczne porządkowanie Spaces według ostatniego użycia. Osobne Spaces dla monitorów powinny być włączone. Aplikacja nie zmienia tych preferencji za użytkownika.
5. Przypisz aplikacje ręcznie z kart biurek albo użyj **Organizuj teraz**. Włącz automatykę dla nowych okien.
6. Zapisz profil dla laptopa jako domyślny. Po podłączeniu monitorów ułóż okna i zapisz profil dla tego zestawu. Po odłączeniu / podłączeniu monitorów automat odczekuje pięć sekund stabilizacji.

Nazwy są widoczne w panelu i na pasku menu. Systemowe etykiety Mission Control pozostają nazwami nadawanymi przez macOS. Zmiana kolejności lub monitora całego biurka zachowuje jego tożsamość, gdy macOS nadal zwraca ten sam UUID.

## Ikona 0.1.2

Dodano dostarczoną przez autora projektu ikonę okien na granatowym tle. Skrypt budowania tworzy wszystkie warianty standardowe i Retina, zachowując przezroczystość.

## Poprawki 0.1.1

- Wyraźny przycisk zakończenia, standardowe menu Cmd+Q i ikona w Docku.
- Blokada uruchomienia drugiego silnika z tych samych ustawień.
- Aktualna nazwa uprawnienia na macOS 27 oraz sprawdzanie dostępu przy powrocie do aplikacji i włączaniu automatyki.
- Diagnostyka wskazuje dokładną ścieżkę uruchomionej kopii. Lokalny `runtime-status.json` zapisuje jej PID i stan uprawnienia, bez tytułów okien.

Na komputerze użytkownika wykryto dwie uruchomione kopie poprzedniej wersji. Po ich zamknięciu i ponownym dodaniu właściwego pliku do uprawnień potwierdzono w rzeczywistym panelu dostęp, odczyt okien, włączenie automatyki oraz zachowanie uprawnienia po restarcie. Przycisk zakończenia faktycznie usunął proces. Próba drugiego uruchomienia zachowała jeden silnik.

## Obsługa

- Ctrl+Option+spacja: panel.
- Ctrl+Option+1…9: biurko według kolejności monitorów i zwykłych biurek.
- Ctrl+Option+Shift+1…9: przeniesienie aplikacji/profilu do biurka i zapamiętanie przypisania.
- Ctrl+Option+lewo/prawo: okno na lewej/prawej połowie ekranu.
- Ctrl+Option+P: pauza/wznowienie.
- Menu okna na karcie: układ i przenoszenie.
- Dodaj aplikację: ręczne współdzielenie biurka przez kilka aplikacji.

## Profile Chrome

Tożsamość opiera się na katalogu profilu, z nazwą odczytaną z lokalnej listy profili Chrome i jednoznacznym sufiksem tytułu Accessibility. Algorytm zachowuje zasady istniejącego DeskPilot, m.in. złożone nazwy i wykrywanie kolizji. Gdy Chrome nie ujawnia jednoznacznego profilu, automat nie zgaduje. W menu okna można wskazać profil ręcznie; takie powiązanie obowiązuje dla życia tego okna. Żadne karty nie są przenoszone ani otwierane przez rozpoznawanie profilu.

## Zasoby i prywatność

Brak okresowego skanowania podczas bezczynności. Odczyty wynikają ze zdarzeń Accessibility, uruchomienia aplikacji, zmiany biurka, monitorów i jawnego odświeżenia. Zdarzenia są grupowane; niekompletne nowe okno ma ograniczony czas ponownego odczytu. Krótkie odczyty potwierdzające działają wyłącznie podczas konkretnego ruchu okna.

Aplikacja nie wykonuje zrzutów ekranu i nie łączy się z siecią. W zapisach przechowuje identyfikatory, nazwy, proporcje ramek i hashe tytułów; nie zapisuje adresów kart ani pełnych tytułów okien. Ustawienia są w `~/Library/Application Support/DeskPilot Native/state.json`. Uszkodzony lub nieobsługiwany zapis nie jest nadpisywany.

Wstępny pojedynczy pomiar uruchomionej wersji testowej: ok. 36 MB RSS. W późniejszym 20-sekundowym odczycie przy wstrzymanej automatyce RSS zmieniał się od 12,6 do 34,1 MiB, a skumulowany czas procesora wzrósł o 0,20 sekundy. W tym czasie zmieniał się stan uprawnień i aplikacji, więc nie jest to izolowany pomiar bezczynności. Pełna automatyka i docelowy zestaw monitorów wymagają osobnego pomiaru; nie ma jeszcze porównania liczbowego z wersją Hammerspoon.

## Ograniczenia

- Binarium przygotowano dla Apple Silicon, macOS 14 lub nowszego. Mechanizm Spaces wymaga osobnego sprawdzenia dla każdej wersji macOS.
- Prywatne funkcje macOS mogą zmienić się po aktualizacji. Ich dostępność jest sprawdzana przed ruchem, a zakończenie ruchu potwierdzane odczytem. Nie wymaga wyłączenia SIP.
- Automatyczne przypisywanie obejmuje zwykłe okna i zwykłe biurka. Okna na wszystkich biurkach i natywny pełny ekran nie są automatycznie przenoszone.
- Nie usuwa biurek automatycznie.
- Dostępność może chwilowo nie ujawniać okien na nieodwiedzonych biurkach. Brak okna w odczycie nie jest podstawą do usunięcia biurka.
- Przy kilku oknach jednej aplikacji odtworzenie geometrii wymaga jednoznacznego dopasowania tytułu. Zamkniętych dokumentów i kart nie odtwarza samodzielnie.
- Podpis lokalny ad hoc, bez notaryzacji Apple. Po przebudowie system może wymagać ponownego nadania Dostępności.

## Budowanie i weryfikacja

Wymagane Apple Command Line Tools. Bez zewnętrznych paczek.

Polecenia poniżej wykonuj w katalogu `macos/`. Skrypt budowania przekształca dostarczoną grafikę `Resources/AppIcon.png` w pełny zestaw rozmiarów macOS i plik `AppIcon.icns`; gotowa aplikacja jest w `.build/DeskPilot Native.app`. Ikona jest używana w Docku, Finderze oraz panelu aplikacji.

```sh
sh build.sh
sh test.sh
".build/DeskPilot Native.app/Contents/MacOS/DeskPilotNative" --diagnose
".build/DeskPilot Native.app/Contents/MacOS/DeskPilotNative" --verify-move
```

`--diagnose` jest tylko do odczytu. `--verify-move` wymaga Dostępności i dwóch zwykłych biurek na jednym monitorze. Tworzy własne tymczasowe okno, przenosi je na drugie biurko, weryfikuje położenie i powrót, a potem je zamyka. Nie przenosi istniejących okien użytkownika. Wynik uprawnienia w procesie uruchomionym z terminala/narzędzia diagnostycznego nie zastępuje sprawdzenia normalnie otwartej aplikacji — macOS może przypisać mu kontekst dostępu programu nadrzędnego.

Opcja `--data-dir /ścieżka` izoluje zapis ustawień na potrzeby testów. `--background` uruchamia panel jako ukryty; `--smoke` kończy test po trzech sekundach.

Mechanizm ruchu i odczytu jest rozwinięciem kodu z https://github.com/villainser/deskpilot (stan referencyjny a370e11b05f5dfaa20e65030682a7a7bd25fec97). Fragment wyszukiwania symbolu i operacji ruchu zachowuje licencję Hammerspoon — zobacz LICENSE-Hammerspoon.txt.
