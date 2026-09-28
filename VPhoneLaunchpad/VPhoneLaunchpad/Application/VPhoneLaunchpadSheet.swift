import SwiftUI

/// The frame every sheet shares, after the console: a title over a divider,
/// the content, and a divider over the buttons. A sheet's toolbar only lays its
/// buttons along the bottom and shows no title, so the sheet had no head.
struct VPhoneLaunchpadSheet<Content: View, Accessory: View, Actions: View>: View {
    let title: Text
    @ViewBuilder let content: Content
    /// Secondary buttons or status, on the leading side of the footer.
    @ViewBuilder let accessory: Accessory
    /// Cancel and confirm, on the trailing side of the footer.
    @ViewBuilder let actions: Actions

    init(
        _ title: Text,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder actions: () -> Actions,
    ) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                title
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                accessory
                Spacer(minLength: 16)
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

extension VPhoneLaunchpadSheet where Accessory == EmptyView {
    init(
        _ title: Text,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions,
    ) {
        self.init(title, content: content, accessory: { EmptyView() }, actions: actions)
    }
}
