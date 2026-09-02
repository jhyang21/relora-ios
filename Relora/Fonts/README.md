# Fonts

DM Sans static instances, cut from the upstream variable font
(`google/fonts` → `ofl/dmsans`, SIL Open Font License 1.1) at
`opsz=14` and weights 400/500/600/700 with fontTools' instancer.

PostScript names are `DMSans-Regular`, `DMSans-Medium`,
`DMSans-SemiBold`, `DMSans-Bold` — these are what
`ReloraDesign/Typography.swift` passes to `Font.custom`, and they
must stay in step with the `UIAppFonts` array in `Relora/Info.plist`.
