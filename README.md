# OpaqueIconThemer v0.2

Настоящий SpringBoard icon themer, не WebClip и не Shortcuts.

Что готово:
- Manager IPA.
- Импорт bundle.id.png.
- IPC в SpringBoard через CFMessagePort.
- SpringBoard bridge.
- Персистентная тема после SpringBoard restart.
- Restore через удаление override.
- Badge/accessory layer не изменяется.
- Runtime fallback SBIconView / SBHIconView.
- GitHub Actions собирает IPA + arm64/arm64e bridge dylib.

Архитектура:
Manager IPA -> CFMessagePort -> SpringBoard Bridge -> настоящий SBIconView.

Ограничение:
На stock iOS 27 beta 6 обычная sideload-подпись не может сама загрузить dylib
в SpringBoard. Нужен отдельный совместимый injection/exploit backend.

Это специально не заменено фейковым WebClip fallback.
