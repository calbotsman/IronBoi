# MYO logo

The mark is the One Body blob absorbing a smaller blob, the moment a user's
words merge into the coach. It's rendered with the app's own blob math
(`render_merge.py` is a port of `ios/.../Orb/OneBody.metal`), not drawn.

- `myo-icon-1024.png`: app icon (the "sinking" stage), also in `AppIcon.appiconset`
- `myo-wordmark.png`: lowercase myo drawn as one metaball field, all amber, shaded like the One Body orb (pale centre, soft edge, glow, grain), also the `MYOWordmark` image asset. Made by `wordmark_blob.py`
- `myo-lockup.png`: mark, wordmark and line ("Your new personal trainer.")
- `merge-*.png`: the four merge stages explored
- `wordmark-letters.svg`, `wordmark.py`: the old caps wordmark (Recraft V4 letters), replaced 2026-10-15
- `myo-lockup.png`: still shows the old caps wordmark

Regenerate: `python render_merge.py` and `python wordmark_blob.py` (need numpy + pillow).
