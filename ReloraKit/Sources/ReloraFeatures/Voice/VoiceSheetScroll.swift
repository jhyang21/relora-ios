import SwiftUI

extension View {
    /// Wraps a composer panel so it scrolls rather than squeezes.
    ///
    /// Every stage of the voice sheet can be on screen at the `.medium`
    /// detent, which offers less height than the panels' prose needs at large
    /// Dynamic Type. SwiftUI answers a short vertical proposal by truncating
    /// the text — which is how "We could not finish that recording" arrived on
    /// screen ending in an ellipsis. `minHeight` keeps the centred look while
    /// there is room and lets the content grow past it when there is not.
    ///
    /// Used by the capture shell, the disclosure panel and the offline panel:
    /// three panels with the same layout problem and one answer to it.
    func voiceSheetScroll() -> some View {
        GeometryReader { proxy in
            ScrollView {
                self.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
