import RulebookKit
import SwiftData
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var conversation: Conversation

    @State private var draft = ""
    @State private var streaming: ChatMessage?
    @State private var task: Task<Void, Never>?
    @State private var openCitation: Citation?
    @State private var dictation = Dictation()
    @FocusState private var inputFocused: Bool

    private var isBusy: Bool { task != nil }

    var body: some View {
        VStack(spacing: 0) {
            EngineBanner()
            ContextSummaryBar(context: conversation.context)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if conversation.messages.isEmpty {
                            SuggestionsView(role: conversation.context.role) { ask($0) }
                        }
                        ForEach(conversation.orderedMessages) { message in
                            MessageView(message: message, isStreaming: message == streaming) { openCitation = $0 }
                                .id(message.persistentModelID)
                        }
                    }
                    .padding()
                }
                .onChange(of: conversation.messages.count) {
                    if let last = conversation.orderedMessages.last {
                        withAnimation { proxy.scrollTo(last.persistentModelID, anchor: .bottom) }
                    }
                }
            }
            Divider()
            inputBar
        }
        .navigationTitle(conversation.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RaceContextMenu(context: Binding(get: { conversation.context }, set: { conversation.context = $0 }))
            }
        }
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $openCitation) { citation in
            NavigationStack {
                DocumentViewer(filename: citation.filename, pageIndex: citation.pageIndex, highlight: citation.excerpt)
                    .navigationTitle(citation.shortLabel)
                    #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { openCitation = nil }
                        }
                    }
            }
            #if os(macOS)
                .frame(minWidth: 700, minHeight: 800)
            #endif
        }
        .alert("Dictation unavailable", isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })) {
            Button("OK") { dictation.error = nil }
        } message: {
            Text(dictation.error ?? "")
        }
        .onDisappear {
            task?.cancel()
            dictation.stop()
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(dictation.isListening ? "Listening…" : "Ask about a rule…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(10)
                .background(.quaternary, in: .rect(cornerRadius: 18))
                .focused($inputFocused)
                .onSubmit { ask(draft) }
                .submitLabel(.send)
            if isBusy {
                Button("Stop", systemImage: "stop.circle.fill") { task?.cancel() }
                    .labelStyle(.iconOnly).font(.title)
            } else {
                if dictation.isAvailable {
                    Button(dictation.isListening ? "Stop dictation" : "Dictate",
                           systemImage: dictation.isListening ? "mic.circle.fill" : "mic.circle") { toggleDictation() }
                        .labelStyle(.iconOnly).font(.title)
                        .foregroundStyle(dictation.isListening ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                        .symbolEffect(.pulse, isActive: dictation.isListening)
                }
                Button("Send", systemImage: "arrow.up.circle.fill") { ask(draft) }
                    .labelStyle(.iconOnly).font(.title)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding()
    }

    /// Speech fills the ask box after whatever was already typed; the official reviews it and taps Send.
    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await dictation.start { spoken in
                draft = typed.isEmpty ? spoken : typed + " " + spoken
            }
        }
    }

    private func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy, let service = model.answerService else { return }
        dictation.stop()
        draft = ""
        let history = conversation.history
        let answerContext = conversation.context
        if conversation.messages.isEmpty { conversation.title = question }

        let userMessage = ChatMessage(isUser: true, text: question)
        userMessage.conversation = conversation
        context.insert(userMessage)

        let reply = ChatMessage(isUser: false, text: "", engine: model.engineName, createdAt: .now.addingTimeInterval(0.001))
        reply.conversation = conversation
        context.insert(reply)
        streaming = reply

        let backend = model.backend
        task = Task {
            defer {
                streaming = nil
                task = nil
                try? context.save()
            }
            do {
                guard !answerContext.included.isEmpty else {
                    reply.text = "No rule sets are included, so there is nothing to search. Tick at least one under Race & role."
                    return
                }
                guard let backend else {
                    let results = try await service.search(question, limit: 8, context: answerContext)
                    reply.citations = results
                    reply.text = results.isEmpty
                        ? "No matching rules found. Try different wording."
                        : "Here are the most relevant passages. (No language model is active, so there is no written answer. See the banner above.)"
                    return
                }
                for try await event in service.answer(question, history: history, backend: backend, context: answerContext) {
                    switch event {
                    case .sources(let citations): reply.citations = citations
                    case .text(let delta): reply.text += delta
                    case .finished(let cited): reply.citedIndexes = cited
                    }
                }
            } catch is CancellationError {
                reply.text += reply.text.isEmpty ? "Stopped." : " …"
            } catch {
                reply.failed = true
                reply.text = "Something went wrong: \(error.localizedDescription)"
            }
        }
    }
}

/// Example questions shown in an empty conversation, tailored to the official's role.
private struct SuggestionsView: View {
    let role: OfficialRole
    let ask: (String) -> Void

    private var examples: [String] {
        switch role {
        case .referee, .startFinishReferee:
            ["Who names the Referee for a technical event?", "What is a false start?",
             "When can a competitor get a re-run?", "What does the Referee post after each run?"]
        case .technicalDelegate:
            ["What should the TD include in the technical report?", "Who are the voting members of the jury?",
             "When can the jury interrupt a race?", "What makes an ideal technical delegate?"]
        case .chiefOfCourse:
            ["What vertical drop is allowed for U14 giant slalom?", "How should the finish area be laid out?",
             "What is a racecourse homologation?", "What does the course crew need on race day?"]
        case .chiefOfRace:
            ["What happens at the team captains' meeting?", "Who can stop the start during a course hold?",
             "What radio protocol should the jury use?", "How far ahead should officials be staffed?"]
        case .timing:
            ["How do I calculate a replacement time when electronic timing fails?", "How is the race penalty calculated?",
             "How must the start gate be wired for timing?", "What is the minimum vertical drop for a scored race?"]
        case .raceAdmin:
            ["How is the draw and seeding done?", "How do I transmit official results?",
             "What goes in the Team Captains' meeting minutes?", "Who needs SafeSport training?"]
        case .gateJudge, .competitionOfficial:
            ["What is a legal passage through a gate?", "What does a gate judge record on the card?",
             "What supplies does a gate judge need?", "What should I do if I suspect a concussion?"]
        case .coach, .none:
            ["Can a racer inspect the course by skiing through the gates?", "Who are the voting members of the jury?",
             "When can a competitor get a re-run?", "What are the helmet rules?"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask in plain language. Answers cite the document and page.")
                .foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { example in
                Button(example) { ask(example) }
                    .buttonStyle(.bordered)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical)
    }
}
