import SwiftUI

/// Card-to-detail zoom transition (iOS 18+). On iOS 17 both modifiers do nothing and the normal push
/// is used. The system softens the zoom to a cross-fade when Reduce Motion is on.
extension View {
    /// Marks the card that a detail screen zooms out of.
    @ViewBuilder
    func zoomTransitionSource<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Put this on the pushed detail view (not inside a stack), with the same id and namespace.
    @ViewBuilder
    func zoomTransition<ID: Hashable>(from id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
