# ReloraDesign — token reference

One page. The values live in code (`Palette.swift`, `Typography.swift`,
`Spacing.swift`, `Shape.swift`, `Motion.swift`); this is the map and the rules.

Relora should read as a personal notebook, not a CRM: warm paper, white cards,
soft coral warmth, generous corners, short unshowy motion.

The **light palette is locked** and mirrors `apps/mobile/src/theme/tokens.ts`.
The **dark palette was designed in M1** (2026-08-31) and is described below.

---

## 1. Semantic roles

All contrast ratios are computed, not estimated: relative luminance per WCAG 2.1
(`L = 0.2126R + 0.7152G + 0.0722B` on linearized sRGB channels), ratio
`(L_lighter + 0.05) / (L_darker + 0.05)`.

### Surfaces

| Role | Light | Dark | Step above ground |
|---|---|---|---|
| `background` | `#FAF8F5` | `#1B1815` | — |
| `card` | `#FFFFFF` | `#24211E` | light 1.06:1 · **dark 1.10:1** |
| `warmCard` | `#FFF7EF` | `#2A2521` | light 1.00:1 · dark 1.17:1 |
| `warmTintStrong` | `#FFF2EC` | `#302823` | 1.10:1 / 1.11:1 above `card` |
| `softHighlight` | `#FFF9EC` | `#2C2820` | 1.05:1 / 1.09:1 above `card` |
| `dangerSurface` | `#FFF5F4` | `#2E211F` | 1.07:1 / 1.03:1 above `card` |
| `contextSurface` | `#F5F2EE` | `#272524` | light 1.05:1 **below** ground · dark 1.16:1 above |
| `offlineSurface` | `#E8E5E2` | `#2B2724` | 1.18:1 / 1.19:1 |

### Ink and lines

| Role | Light | Dark | Light range | Dark range |
|---|---|---|---|---|
| `ink` | `#2D2A26` | `#E8E1D9` | 11.38 – 14.28 | 11.15 – 13.64 |
| `mutedInk` | `#6B6762` | `#A19A91` | 4.47 – 5.61 | 5.19 – 6.35 |
| `tertiaryInk` | `#9B9892` | `#847D75` | **2.29 – 2.88** | **3.56 – 4.35** |
| `onAccent` | `#2D2A26` | `#2D2A26` | 7.21 – 8.94 on fills | 5.23 – 6.40 on fills |
| `hairline` | `ink` @ 8% | `ink` @ 10% | 1.16:1 on card | 1.30:1 on card |

Ranges are the minimum and maximum across all eight surfaces.

### Brand

| Role | Light | Dark | Notes |
|---|---|---|---|
| `accent` | `#FF9F8F` | `#D9877A` | fills only · `onAccent` 7.21 / 5.23 |
| `accentSoft` | `#FFB4A2` | `#D9998A` | fills only · `onAccent` 8.36 / 6.03 |
| `accentText` | `#AF4A26` | `#D48E7B` | text only · **4.37 – 5.48** / **5.47 – 6.70** |
| `lavender` | `#D4C5F9` | `#B4A7D4` | decorative fill · `onAccent` 8.94 / 6.40 |
| `blue` | `#A8C5E8` | `#8FA7C5` | decorative fill · `onAccent` 8.03 / 5.78 |
| `accentTintFill` | `accent` @ 12% | `accent` @ 10% | 1.09:1 / 1.17:1 on card |
| `accentTintBorder` | `accent` @ 20% | `accent` @ 16% | 1.14:1 / 1.30:1 on card |
| `accentGlow` | `#FF9F8F` @ 25% | `#FF9F8F` @ 25% | record button halo, both modes |

### Feedback

| Role | Light | Dark | Light range | Dark range |
|---|---|---|---|---|
| `success` | `#2F8A57` | `#57B681` | **3.42 – 4.29** | 5.79 – 7.08 |
| `danger` | `#B44A3D` | `#E97469` | 4.20 – 5.27 | 4.93 – 6.03 |

---

## 2. Full contrast matrix

Values below 4.5:1 are marked. **LG** clears 3:1 and is therefore legal for
Large text only (≥18pt regular / ≥14pt semibold). **X** clears neither.

### Light

| fg \ bg | background | card | warmCard | warmTintStrong | softHighlight | dangerSurface | contextSurface | offlineSurface |
|---|---|---|---|---|---|---|---|---|
| `ink` | 13.47 | 14.28 | 13.46 | 13.03 | 13.61 | 13.34 | 12.79 | 11.38 |
| `mutedInk` | 5.29 | 5.61 | 5.29 | 5.12 | 5.35 | 5.24 | 5.03 | 4.47 **LG** |
| `tertiaryInk` | 2.71 **X** | 2.88 **X** | 2.71 **X** | 2.63 **X** | 2.74 **X** | 2.69 **X** | 2.58 **X** | 2.29 **X** |
| `accentText` | 5.17 | 5.48 | 5.17 | 5.00 | 5.23 | 5.12 | 4.91 | 4.37 **LG** |
| `success` | 4.05 **LG** | 4.29 **LG** | 4.05 **LG** | 3.92 **LG** | 4.09 **LG** | 4.01 **LG** | 3.85 **LG** | 3.42 **LG** |
| `danger` | 4.97 | 5.27 | 4.97 | 4.81 | 5.02 | 4.92 | 4.72 | 4.20 **LG** |

### Dark

| fg \ bg | background | card | warmCard | warmTintStrong | softHighlight | dangerSurface | contextSurface | offlineSurface |
|---|---|---|---|---|---|---|---|---|
| `ink` | 13.64 | 12.36 | 11.70 | 11.15 | 11.32 | 11.97 | 11.77 | 11.42 |
| `mutedInk` | 6.35 | 5.75 | 5.45 | 5.19 | 5.27 | 5.58 | 5.48 | 5.32 |
| `tertiaryInk` | 4.35 **LG** | 3.94 **LG** | 3.73 **LG** | 3.56 **LG** | 3.61 **LG** | 3.82 **LG** | 3.76 **LG** | 3.65 **LG** |
| `accentText` | 6.70 | 6.07 | 5.74 | 5.47 | 5.56 | 5.88 | 5.78 | 5.61 |
| `success` | 7.08 | 6.42 | 6.07 | 5.79 | 5.88 | 6.22 | 6.11 | 5.93 |
| `danger` | 6.03 | 5.47 | 5.17 | 4.93 | 5.01 | 5.30 | 5.21 | 5.05 |

**Every dark text pairing except `tertiaryInk` clears AA at any size.** The dark
minimum is `danger` on `warmTintStrong` at 4.93:1.

---

## 3. How the dark palette was designed

Not a mechanical inversion. Four decisions:

**Warm all the way down.** The ground `#1B1815` is a warm brown-gray near-black,
the same hue family as the light ink `#2D2A26` (R−B spread of 6 on 27, against
the light ink's 7 on 45). Pure black would make Relora a different product in
dark mode.

**Primary text matches light mode rather than maximizing.** The dark `ink` was
tuned so `ink`-on-`background` lands at 13.64:1, near the light mode's 13.47:1.
Pure white on this ground reaches about 18:1 and halates — thin glyphs bloom and
read *worse*, not better.

**Brand fills are the light values × 0.85, hue unchanged.** `accent`,
`accentSoft`, `lavender` and `blue` are each exactly 85% of their light channel
values (verified: per-channel scale factors 0.848 – 0.853). Their hue and their
relationships to one another survive the mode switch, and the fills stop glaring
against a near-black ground. One rule, four colors, reviewable in a diff.

**Dim roles get *more* contrast in dark, not less.** `tertiaryInk` sits at
3.56 – 4.35:1 where its light counterpart sits at 2.29 – 2.88:1, and `hairline`
carries 10% opacity against light's 8%. Thin light-on-dark elements lose
perceived contrast to display gamma and glare; the dark values buy back what the
optics take.

### Dark-mode elevation: the surface carries it, not the shadow

This is arithmetic, not preference. Compositing pure black over `#1B1815`:

| Black opacity | Contrast vs ground |
|---|---|
| 10% | 1.02:1 |
| 20% | 1.05:1 |
| 28% | 1.07:1 |
| 32% | 1.07:1 |

The light `card` shadow — black at **5%** on `#FAF8F5` — already reaches 1.11:1,
and the light `floating` shadow reaches 1.25:1. **There is no opacity at which a
black shadow on a near-black ground does what a shadow does on paper.** Pushing
it produces a smudge, not depth.

So the dark palette elevates with lightness: a dark `card` sits **1.10:1** above
the ground where a light card sits **1.06:1** — nearly double the step, chosen so
a card reads as raised with no shadow at all.

Per tier in dark mode:

- `card` — **no shadow** (0% opacity). The surface step is the whole cue.
- `raised` — black 20% (1.05:1) and `floating` — black 28% (1.07:1). Larger
  opacity numbers than light's 6% and 10%, yet a *weaker* shadow. They soften the
  edge where one elevated surface overlaps another; they do not signal elevation.
- `accentGlow` — unchanged at 25% in both modes, and it keeps the **bright**
  `#FF9F8F` even in dark where the accent fill is the deepened `#D9877A`. A glow
  is emitted light, not occlusion.

**Consequence for feature code:** never apply a shadow tier without the matching
surface color, or dark mode loses its only elevation cue. Use
`.reloraSurface(_:radius:shadow:)`, which applies both.

---

## 4. Usage rules

**`accentText` for text, `accent` for fills.** The coral reaches only 1.98:1 as
text on a white card (1.87:1 on the ground). Any accent-colored *word* uses
`accentText`. Any
accent-colored *shape* — button, pill, progress bar, avatar circle, record
button — uses `accent` or `accentSoft`.

**`onAccent` is the label on every brand fill, in both modes.** It is the dark
ink `#2D2A26` and does not change with the mode, because every brand fill is a
light tone in both palettes. Never put `ink` on a brand fill: in dark it inverts
to warm off-white and collapses to about 2:1.

**`success` and `danger` are feedback only.** Toasts, validation, destructive
confirmations. Never a brand color, never decoration, never a chart fill. Two
constraints follow from the matrix:

- Light `success` fails AA on every surface (3.42 – 4.29:1). Light-mode success
  text must be Large, or the color must be paired with an icon while the wording
  itself is `ink`. The light value is locked — flagged for review.
- Nothing that must be read goes on `offlineSurface` in light mode except `ink`:
  `mutedInk` (4.47), `accentText` (4.37) and `danger` (4.20) all miss AA there.

**`tertiaryInk` never carries meaning alone.** It fails 4.5:1 in both modes and
fails even 3:1 in light. Placeholders, timestamps, dividers, disabled glyphs —
information that is decorative or repeated elsewhere. Never an error, never a
label a user must read to act.

**`card` vs `warmCard`.** `card` is the default: anything holding the user's own
content — a contact row, a memory, a detail panel. `warmCard` is the app
speaking: notices, hero blocks, onboarding, auth and paywall panels, the local
backup prompt. If a surface contains something the user wrote, it is a `card`.

- `warmTintStrong` — a warm panel that must separate from a `warmCard` beside it
  (trial and usage banners).
- `softHighlight` — the gentle, non-urgent nudge (soft upgrade prompt).
- `dangerSurface` — the surface behind error content. A surface, not a signal;
  pair it with `danger` text.
- `contextSurface` — the quiet, hue-free block for supporting text. In dark it
  steps *up* rather than down (there is no room below the ground) and stays
  distinct from `warmCard` by hue: near-neutral, R−B spread 3, against
  `warmCard`'s 9.
- `offlineSurface` — the app talking about itself. Deliberately grayer than the
  warm surfaces.

**Never write a literal.** No hex, no point value, no duration in a view. Missing
token? Add it here with a comment saying why.

**Never check `accessibilityReduceMotion` in a feature.**
`.reloraAnimation(_:value:)` and `withReloraAnimation(_:)` already do, and a
feature that checks it once is a feature that forgets to check it elsewhere.

---

## 5. Type, spacing, shape, motion

**Type** — DM Sans, five roles, all Dynamic Type via
`Font.custom(_:size:relativeTo:)`:

| Role | Size / weight | `relativeTo` | RN equivalent |
|---|---|---|---|
| `largeTitle` | 34 Bold | `.largeTitle` | — (new) |
| `title` | 28 SemiBold | `.title` | `typography.heading` |
| `title3` | 22 SemiBold | `.title3` | `typography.title` |
| `body` | 15 Regular | `.body` | `typography.body` |
| `footnote` | 13 Medium | `.footnote` | `typography.label` |

The TTFs ship in the **app** bundle in M5, not this package. If a face is
missing, SwiftUI silently substitutes the system font at the same size — usable
but wrong, which is why `ReloraFont.assertFontsAvailable()` exists as a debug
tripwire. The PostScript names (`DMSans-Regular` / `-Medium` / `-SemiBold` /
`-Bold`) are an assumption until then and must be confirmed against the actual
files.

**Spacing** — `xs` 6, `sm` 10, `md` 16, `lg` 24, `xl` 32. Screen horizontal
padding 28 (wider than `lg` on purpose — the generous margin is most of the
notebook feeling). Content max width 560. Floating-layer offsets are deliberately
undefined until the milestone that builds the record button and toast layer; see
the note in `Spacing.swift`.

**Radii** — `sm` 12, `md` 16, `lg` 20, `xl` 24, `pill` 999. Large by iOS
convention, and that is the point.

**Motion** — `quick` 0.12s, `standard` 0.18s, `gentle` 0.22s, plus a spring
(`response` 0.32, `dampingFraction` 0.82) for anything a finger drives. Nothing
longer than a quarter second. If an interaction wants a longer or springier
animation, the interaction is probably wrong.

---

## 6. Open items

- **Light `success` fails AA at normal size on every surface** (3.42 – 4.29:1),
  and light `mutedInk` / `accentText` / `danger` all miss AA on `offlineSurface`
  (4.47 / 4.37 / 4.20). These are properties of the locked light palette, not
  choices made here. Either the usage rules above hold, or the light values need
  sign-off to change.
- **Shadow blur radii are ported 1:1 from RN `shadowRadius`** on the assumption
  that SwiftUI's `.shadow(radius:)` and `CALayer.shadowRadius` agree closely
  enough. Nobody has seen this on a device. Compare all four tiers against the RN
  build in M5 and adjust the radii if they read heavier or lighter — the
  opacities are derived and should not move.
- **DM Sans PostScript names** are unconfirmed until the TTFs land.
- **Accent tints** collapse six different coral alphas from RN
  (0.08 / 0.12 / 0.14 / 0.16 / 0.20 / 0.24) into `accentTintFill` and
  `accentTintBorder`. If a screen in M2+ genuinely needs a third step, add it
  here rather than re-introducing a one-off.
