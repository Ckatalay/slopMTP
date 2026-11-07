# Translation guidance for slopMTP

slopMTP is a macOS app for moving files between a Mac and a modded Nintendo Switch over USB (MTP). It's used for backing up your own games, saves and screenshots, installing games, and homebrew development. Readers are Mac users comfortable with technical tools.

## Tone

- Clear, concise and neutral, like Apple's own macOS apps.
- Address the user the way macOS does in that language: informal in German (du), Spanish (tú), Italian (tu), Dutch (je), Polish (ty) and Brazilian Portuguese (você); formal in French (vous), Russian (вы), Ukrainian (ви) and Turkish (siz).
- Follow Apple's macOS terminology for each language: Finder, Downloads, Preview, Desktop, "Cancel", "Delete", "Back Up", "Show in Finder" and so on.
- Keep button and menu labels short; the UI has limited space.

## Never translate

- Product and app names: slopMTP, DBI, Sphaira, Nintendo Switch, Android File Transfer, OpenMTP, Homebrew, GitHub, TestFlight.
- Apple's own apps (Finder, Preview, QuickTime, Image Capture, Photos) use the name Apple shows in that language, for example 访达 for Finder and 照片 for Photos in Simplified Chinese. Where Apple keeps the English name, keep it too.
- File formats and protocol terms: NSP, NSZ, XCI, XCZ, MSP, MTP, PTP, USB, SD.
- MTP operation names such as SendObject, SendObjectInfo, SendObjectPropList, GetObject (they appear inside error messages).
- The button name "R" (the console's R button).
- Version labels like "v3" and title IDs like 0100ABC012345000.

## Glossary

| English | Meaning / guidance |
| --- | --- |
| Base Game | The game itself, as opposed to its update or DLC. |
| Update | A game patch. Keep the same word everywhere ("Update v3"). |
| DLC | Downloadable content (add-ons). Keep "DLC" unless the language has a well-established term that Nintendo uses in that language. |
| Install / Uninstall | Putting a game on / removing it from the console. |
| Back Up | Copying games or saves from the console to the Mac. Use the language's standard macOS verb for backing up. |
| Saves / save data | Game save files. |
| Album | The console's screenshot and video album (Nintendo's own term in each language, e.g. "Album" in German, "Álbum" in Spanish, "アルバム" in Japanese). |
| Capture | A screenshot or video in the Album. |
| SD Card / System Memory | The console's two install locations. Use Nintendo's terms for that language where known ("System Memory" is the internal storage). |
| title mode / applet mode | Two ways DBI can run on the console. Translate "mode" but keep the meaning: title mode = launched in place of a game (holding R); applet mode = launched from the Album. |
| storage | One of the storage areas the device exposes over MTP. |
| transfer | A copy in either direction. |

## Formatting

- Keep every placeholder (`%@`, `%lld`, `%u`) exactly, the same number of times. If the word order requires it, use positional forms (`%1$@`, `%2$@`).
- Use the target language's quotation marks around names that are quoted with “ ” in English (for example „…“ in German, « … » in French, 「…」 in Japanese).
- Keep the ellipsis character (…) on buttons and menu items that open a dialog.
- Keep symbols such as →, ·, — and A–Z ordering hints, adapting "A–Z" to the language's alphabet if natural.
- Strings that only contain placeholders or symbols stay as they are.
- Counted strings need the language's plural forms (CLDR categories).
