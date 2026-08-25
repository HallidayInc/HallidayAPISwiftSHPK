import SwiftUI

struct ChainFilterView: View {
    @Environment(AssetStore.self) private var assets
    @Environment(\.dismiss) private var dismiss
    @Binding var chain: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PickerTitle("Select a network")

                List {
                    row(icon: mark, name: "All networks") {
                        chain = nil
                        dismiss()
                    }
                    ForEach(assets.chains.keys.sorted(), id: \.self) { name in
                        row(icon: AnyView(TokenIcon(url: assets.chains[name]?.image)), name: name.capitalized) {
                            chain = name
                            dismiss()
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navBar(trailing: .close, onTrailing: { dismiss() })
        }
    }

    // No chain logo stands for "everything", so the Halliday mark does.
    private var mark: AnyView {
        AnyView(
            ZStack {
                Circle().fill(.white)
                Image("HallidayMark")
                    .resizable()
                    .scaledToFit()
            }
            .frame(width: 32, height: 32)
            .clipShape(.circle)
        )
    }

    private func row(icon: AnyView, name: String, _ select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(spacing: 12) {
                icon
                Text(name).haffer(16)
                Spacer()
            }
        }
        .tint(.primary)
    }
}
