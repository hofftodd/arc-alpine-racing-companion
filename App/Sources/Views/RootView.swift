import SwiftData
import SwiftUI

/// Sidebar of saved conversations and the library; the chat is the detail column.
/// On iPhone this collapses into a navigation stack.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]

    enum Destination: Hashable {
        case conversation(PersistentIdentifier)
        case library
    }

    @State private var selection: Destination?
    @State private var showingSettings = false

    var body: some View {
        if let error = model.loadError {
            ContentUnavailableView("Rulebook unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            NavigationSplitView {
                List(selection: $selection) {
                    NavigationLink(value: Destination.library) {
                        Label("Library", systemImage: "books.vertical")
                    }
                    Section("Questions") {
                        ForEach(conversations) { conversation in
                            NavigationLink(value: Destination.conversation(conversation.persistentModelID)) {
                                VStack(alignment: .leading) {
                                    Text(conversation.title).lineLimit(2)
                                    Text(conversation.createdAt, style: .date)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
                .navigationTitle("ARC")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Question", systemImage: "square.and.pencil", action: newConversation)
                            .keyboardShortcut("n")
                    }
                    #if os(iOS)
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        }
                    #endif
                }
            } detail: {
                NavigationStack {
                    switch selection {
                    case .library:
                        LibraryView()
                    case .conversation(let id):
                        if let conversation = conversations.first(where: { $0.persistentModelID == id }) {
                            ChatView(conversation: conversation)
                        } else {
                            placeholder
                        }
                    case nil:
                        placeholder
                    }
                }
                .id(selection)
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack { SettingsView() }
            }
            .onAppear {
                if selection == nil, conversations.isEmpty { newConversation() }
            }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("Ask about the rules", systemImage: "figure.skiing.downhill")
        } description: {
            Text("Start a new question to search the officials' manual, study guides, and USSS, FIS and OISRA rules.")
        } actions: {
            Button("New Question", action: newConversation).buttonStyle(.borderedProminent)
        }
    }

    private func newConversation() {
        // Reuse an empty conversation instead of piling up blank ones.
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            selection = .conversation(empty.persistentModelID)
            return
        }
        let conversation = Conversation(context: model.defaultContext)
        context.insert(conversation)
        try? context.save()
        selection = .conversation(conversation.persistentModelID)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let conversation = conversations[index]
            if selection == .conversation(conversation.persistentModelID) { selection = nil }
            context.delete(conversation)
        }
    }
}
