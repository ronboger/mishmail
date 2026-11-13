#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Forces TextKit 1 layout and catches the Objective-C exception that
/// `-[NSLayoutManager ensureLayoutForTextContainer:]` can raise.
///
/// The layout manager raises NSRangeException when its glyph state is out of
/// step with the text storage (seen while the system inline-prediction panel
/// runs a nested event loop during typing). Swift cannot catch that. When the
/// call comes from `updateNSView`, the exception unwinds through SwiftUI's
/// view-update frames without running their cleanup. That leaves the
/// Observation thread-local access list pointing at a dead stack frame, and
/// the next read of any @Observable property outside a view update crashes
/// (EXC_BAD_ACCESS in ObservationTracking._AccessList.addAccess).
///
/// Returns NO when layout raised; the caller must not trust layout metrics.
BOOL MMEnsureTextLayout(NSLayoutManager *layoutManager,
                        NSTextContainer *textContainer);

NS_ASSUME_NONNULL_END
