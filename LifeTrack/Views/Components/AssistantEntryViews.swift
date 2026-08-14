import SwiftUI

struct AssistantToolbarLink: View {
    let context: AssistantFeatureContext

    var body: some View {
        NavigationLink {
            InsightAssistantView(featureContext: context, embedsNavigationStack: false)
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel(context.title)
    }
}

struct AssistantFeatureCard: View {
    let context: AssistantFeatureContext
    let title: String
    let subtitle: String

    var body: some View {
        NavigationLink {
            InsightAssistantView(featureContext: context, embedsNavigationStack: false)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
