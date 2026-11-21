# Localization

Last updated 2026-11-12.

Culla ships in English, Russian and Turkmen. It follows the system language and falls back to English. Settings ▸ General has a language choice for people whose system is in another language; this matters most for Turkmen, which macOS itself is not translated into.

## What is translated and what is not

Translated: every piece of text a person sees or VoiceOver reads. Menus, toolbar, sidebar, headers, hint lines, captions, tooltips, alerts, Settings, the apply screen, the help windows and the About text.

Not translated, on purpose:

- The app's name, Culla.
- The `_Rejected` folder name, sidecar contents and anything else written to disk. Files must mean the same thing whatever language wrote them, and undo must find them again.
- File names, camera and lens names, and other metadata read from photos.
- `culla-eval`, the benchmark tool, the automation harness, state dumps and log messages. These are developer tools.
- The documents in `docs/` and the README.

## Rules for code

- No user-facing text is fixed English. Text comes from a string catalog (`Localizable.xcstrings`), one per target that shows text.
- No sentence is built by joining fragments, and no plural is built with `count == 1`. Word order and plural forms differ: Russian has four plural forms. Use one catalog entry per sentence, with plural variations.
- Numbers, dates, sizes and lists go through the system formatters with the app's language.
- Every catalog entry carries a comment for the translator: where the text appears and what each placeholder stands for.
- Keys work by position when the typed character is not a bindable one, so P, X and U keep working on a Russian or Turkmen keyboard layout.
- A line of key hints never loses its start: when it does not fit, whole hints drop from the end. The full line stays in the tooltip and for VoiceOver.
- Layouts grow, wrap or reflow for longer text. Nothing is sized for the English word.

## Working on translations

```bash
python3 Scripts/l10n.py check --require ru,tk     # must pass before a commit
python3 Scripts/l10n.py stats
python3 Scripts/l10n.py export tk --out tk.json    # add --missing-only for new entries
python3 Scripts/l10n.py import tk tk.json          # refuses a file with any problem
python3 Scripts/l10n.py clean                      # removes entries an Xcode build added
Scripts/ui-all.sh --only screens                   # walks every screen in en, ru and tk
```

The export file's format is described at the top of `Scripts/l10n.py`. After a change, look at the walk's snapshots in the changed language, and run `Scripts/l10n-screens.py <ru or tk run> <en run>` to find text left in English. The terms the translators settled beyond the glossary below are in `docs/l10n/terms-ru.txt` and `docs/l10n/terms-tk.txt`.

## Style

- **Russian.** Commands and menu items are infinitives («Открыть папку…»). Sentences address the person as «вы», lower case. The letter ё is always written. System things use the names macOS uses in Russian: Корзина, Настройки, Finder.
- **Turkmen.** Latin alphabet with ä, ç, ž, ň, ö, ş, ü, ý. Commands and menu items are the short imperative («Bukjany aç…», «Görkez», «Gizle»). Sentences address the person as «siz». A noun after a number stays singular («5 surat»).
- Both keep sentences as short as the English. Hint lines and toolbar labels have little room.
- Key names, symbols and letters are not translated: P, X, ⌘Z, ↩.

## Glossary

| English | Russian | Turkmen |
|---|---|---|
| Culla | Culla | Culla |
| shoot | съёмка | surata düşüriş; «bukja» where the folder is meant |
| photo | фото | surat |
| frame | кадр | kadr |
| stack (similar shots) | серия | tapgyr |
| Similar Stacks | Похожие серии | Meňzeş tapgyrlar |
| best pick | лучший кадр | iň gowy kadr |
| current frame | текущий кадр | häzirki kadr |
| keep / kept | оставить / оставленные | galdyr / galdyrylan |
| reject / rejected | отклонить / отклонённые | ret et / ret edilen |
| clear decision | снять отметку | karary aýyr |
| decision | решение | karar |
| unreviewed | непросмотренные (group), не просмотрено (count) | seredilmedik |
| duplicates / exact duplicates | дубликаты / точные дубликаты | dublikatlar / takyk dublikatlar |
| blurry / sharp | нерезкий / резкий | bulaşyk / anyk |
| eyes closed | закрытые глаза | ýumuk gözler |
| exposure | экспозиция | ekspozisiýa |
| highlights / shadows | света / тени | ýagty ýerler / kölegeler |
| overexposed / underexposed | пересвечено / недосвечено | aşa ýagty / aşa garaňky |
| other issues | другие проблемы | beýleki kemçilikler |
| tilted horizon | заваленный горизонт | gyşyk gorizont |
| loupe | лупа | lupa |
| grid | сетка | tor |
| compare | сравнение | deňeşdirme |
| filmstrip | лента кадров | kadrlar zolagy |
| face strip | лента лиц | ýüzler zolagy |
| face boxes | рамки лиц | ýüz çarçuwalary |
| inspector | инспектор | maglumat paneli |
| review and apply | проверить и применить | gözden geçir we ulan |
| apply decisions | применить решения | kararlary ulan |
| undo / redo | отменить / повторить | yzyna al / gaýtala |
| sidecar | файл XMP; сопроводительный файл XMP where first explained | XMP faýly; XMP goşmaça faýly where first explained |
| Trash / move to the Trash | Корзина / переместить в Корзину | Sebet / Sebede taşla |
| score (a detector's number) | оценка | bal |
| Certain / Likely | «Точно» / «Вероятно» | «Şübhesiz» / «Ähtimal» |
| flag (Culla's) | пометка | bellik |
| set (of duplicates) | набор | toplum |
| copy (verb) | скопировать | nusgala |
| folder / file | папка / файл | bukja / faýl |
| Settings | Настройки | Sazlamalar |
| threshold | порог | çäk |
| preset | набор настроек | taýýar sazlama |
| detection tuning | настройка обнаружения | ýüze çykaryş sazlamalary |
| rescan | пересканировать | täzeden barla |
| analysis | анализ | derňew |
| rating / stars | рейтинг / звёзды | baha / ýyldyz |
| colour label | цветная метка | reňk belligi |
| show / hide | показать / скрыть | görkez / gizle |
| open / close | открыть / закрыть | aç / ýap |
| cancel / OK | отменить / ОК | ýatyr / Bolýar |
| delete / quit | удалить / завершить | poz / çyk |
| cache | кэш | keş |
| keyboard shortcuts | сочетания клавиш | düwme utgaşmalary |
