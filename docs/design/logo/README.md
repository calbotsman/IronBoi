# MYO logo

The mark is the One Body blob absorbing a smaller blob, the moment a user's
words merge into the coach. It's rendered with the app's own blob math
(`render_merge.py` is a port of `ios/.../Orb/OneBody.metal`), not drawn.

- `myo-icon-1024.png`: app icon (the "sinking" stage), also in `AppIcon.appiconset`
- `myo-wordmark.png`: MYO in ink with an amber blob as the period, also the `MYOWordmark` image asset
- `myo-lockup.png`: mark, wordmark and line ("Your new personal trainer.")
- `merge-*.png`: the four merge stages explored
- `wordmark-letters.svg`: the letterforms (Recraft V4 via FAL, recoloured to ink)

Regenerate: `python render_merge.py` (needs numpy + pillow).
