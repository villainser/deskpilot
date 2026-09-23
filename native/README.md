# Opcjonalny backend ruchu okien

`space_move.m` korzysta z mechanizmu proponowanego w [Hammerspoon PR #3889](https://github.com/Hammerspoon/hammerspoon/pull/3889), commit `8cde946e79d7a3e3d9aca366264a09a734b295bb`. Oryginalne `hs.spaces.moveWindowToSpace()` w Hammerspoon 1.1.1 używa starszego mechanizmu, który na Tahoe może zwrócić sukces bez przeniesienia okna.

Helper jest samodzielnym programem Objective-C. Potrzebuje lokalnych Apple Command Line Tools i Cocoa; nie potrzebuje LuaSkin, modyfikowania Hammerspoon, wstrzykiwania kodu do Docka ani wyłączania SIP. Prywatne API jest wykrywane dynamicznie. PR opisuje niezależny test mechanizmu na macOS 26.5 z SIP włączonym, ale nie stanowi gwarancji działania tego helpera, innych aplikacji ani macOS 26.6.2. Nie dodajemy prywatnych entitlements. Rzeczywista operacja może zależeć od uprawnień procesu uruchamiającego.

## Budowanie i bezpieczna diagnostyka

```sh
sh native/build.sh
native/bin/deskpilot-space-move --version
native/bin/deskpilot-space-move --check
native/bin/deskpilot-space-move --windows
native/bin/deskpilot-space-move --windows-framed
```

`--check` tylko ładuje systemowy framework i sprawdza obecność wymaganych symboli oraz klasy. Nie tworzy operacji i nie przenosi okien. `available` oznacza dostępność API, a nie potwierdzoną możliwość ruchu. Kod został przygotowany do wywołania przez `hs.task` ze ścieżką programu i osobnymi argumentami.

`--windows` wykonuje wyłącznie odczyt publicznym `CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID)`. Zwraca JSON z `status: "windows"` i tablicą `windows`. Elementy zachowują nazwy kluczy CoreGraphics: `kCGWindowNumber`, `kCGWindowLayer`, `kCGWindowOwnerPID`, `kCGWindowOwnerName`, `kCGWindowBounds` i `kCGWindowIsOnscreen` (jeżeli system je udostępnił). Nie zwraca tytułów okien ani obrazów. Opcja `All` obejmuje także okna poza ekranem; brak metadanych konkretnego ID nadal nie dowodzi, że to ID jest bezpieczne do pominięcia przy usuwaniu biurka.

Wersja 1.2.0 dodaje `kCGWindowBounds` — obiekt z liczbowymi polami `X`, `Y`, `Width`, `Height` we współrzędnych ekranowych CoreGraphics — oraz logiczne `kCGWindowIsOnscreen`. Pozwala to narysować schemat okien również wtedy, gdy okno na innym biurku nie ma jeszcze reprezentacji AX w Hammerspoon. To układ prostokątów, nie zdjęcie zawartości okien. System może pominąć `kCGWindowIsOnscreen` zamiast zwrócić `false`; brak tego pola nie jest błędem. Wartość `false` ani brak tego pola nie oznaczają pustego biurka ani okna możliwego do pominięcia przy sprzątaniu. Odczyt metadanych nie uruchamia przechwytywania obrazu ani nie prosi o zgodę na nagrywanie ekranu.

Wersja 1.3.0 dodaje `--windows-framed` dla transportu przez `hs.task`. Dane mają format `DESKPILOT-WINDOWS/1 <liczba bajtów base64>\n<base64(JSON)>\n`. JSON zawiera ten sam obiekt co `--windows`; także odpowiedzi błędów w tym trybie są opakowane w ramkę. Cała ramka używa ASCII, więc podział danych na fragmenty nie przecina znaków UTF-8 w nazwach aplikacji. DeskPilot dekoduje dane dopiero po otrzymaniu dokładnie zadeklarowanej długości i poprawnym zakończeniu helpera. Odbiornik ogranicza nagłówek do 64 bajtów, a zakodowane dane do 8 MiB. Przekroczenie limitu, dodatkowe dane lub brak fragmentu powodują odrzucenie wyniku bez uznawania starych metadanych za świeże. Dotychczasowe `--windows` nadal zwraca zwykły JSON.

Wersja 1.3.1 dodaje `--windows-stream`, używane przez DeskPilot. Po wysłaniu i opróżnieniu bufora ramki proces czeka do 4 sekund na dokładny wiersz `DESKPILOT-ACK/1\n` na standardowym wejściu. DeskPilot wysyła potwierdzenie dopiero po zebraniu kompletnej ramki, a JSON dekoduje po zakończeniu helpera z kodem 0. Zapobiega to równoczesnemu odczytowi stdout przez obsługę strumienia i zakończenia `hs.task`. Brak potwierdzenia, EOF, niepoprawne potwierdzenie lub błąd zapisu kończą proces kodem 5; nie powstaje drugi dokument na stdout. Do ręcznej diagnostyki należy używać `--windows` lub `--windows-framed`, które nie czekają na potwierdzenie.

Wersja **1.3.2** rozszerza odpowiedź metadanych o tablicę `displays`. Każdy wpis zawiera bieżące `id` ekranu, jego trwałe `uuid` oraz logiczne `builtIn` z `CGDisplayIsBuiltin`. Dotyczy to zarówno `--windows`, jak i opakowanych wariantów transportu; protokół ramki i potwierdzenia pozostaje bez zmian. DeskPilot porównuje te dane z aktualnymi ekranami Hammerspoon, aby odróżnić laptop od monitorów zewnętrznych i nie uruchamiać przywracania na podstawie samej liczby ekranów. Brak zgodnego wpisu wstrzymuje odczyt stanu sesji.

Przywracanie ostatniej sesji realizują moduły Lua. Helper dostarcza metadane oraz wykonuje pojedynczy zweryfikowany ruch okna; nie zapisuje układu, nie dopasowuje ramek i nie uruchamia aplikacji. Zapis sesji przechowuje UUID, lokalne indeksy biurek, identyfikatory aplikacji/profili, proporcjonalną geometrię i hashe tytułów — bez obrazów, pełnych tytułów i URL-i. Bieżące numery `id` ekranów oraz PID-y i ID okien z odpowiedzi helpera nie stają się trwałą tożsamością zapisanych okien.

## Interfejs

Wywołanie `deskpilot-space-move WINDOW_ID SPACE_ID` **przenosi wskazane okno**. Argumenty to aktualne numery ID, bez znaków i bez formatu zmiennoprzecinkowego. Nie zapisuj ich jako trwałych identyfikatorów między restartami.

Program zwraca pojedynczy obiekt JSON. Nie tworzy ani nie usuwa biurek, nie zmienia ich kolejności, nie przełącza aktywnego Space, nie ustawia rozmiaru okna i nie wywołuje fokusowania. Odrzuca okna przypisane do wielu Spaces oraz natywne okna fullscreen/Split View. Nie implementuje polityki wyboru monitora — odpowiada za nią DeskPilot przed wywołaniem.

| Kod wyjścia | Znaczenie |
| --- | --- |
| 0 | `moved` lub `already_on_target`; odczyt zwrotny potwierdził docelowy Space. Dla `--check`: tylko symbole obecne. Dla `--windows`: odczytano metadane. |
| 2 | Nieprawidłowe argumenty. |
| 3 | Brak wymaganego prywatnego API; ruchu nie podjęto. |
| 4 | Nieprawidłowy Space lub niejednoznaczne/nieobsługiwane okno. |
| 5 | Błąd połączenia, zapytania lub utworzenia operacji. |
| 6 | Operację zlecono, ale po 3 sekundach nie potwierdzono jej wyniku. |

Po kodzie 6 operacja mogła zostać opóźniona przez system. Kod sterujący powinien ponownie odczytać przypisanie okna i wstrzymać automatyczne tworzenie/usuwanie biurek. Nie wolno traktować kodu 6 jako pewności, że ruch nie nastąpił.

21.09.2026 na macOS 26.6.2 wykonano kontrolowany test na tymczasowym oknie TextEdit: przeniesienie na inne zwykłe biurko oraz powrót potwierdził odczyt helpera i hs.spaces.windowSpaces. Nie jest to weryfikacja wszystkich aplikacji, fullscreen ani przyszłych wersji macOS.
