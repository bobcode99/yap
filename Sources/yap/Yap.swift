import ArgumentParser

// MARK: - yap

@main struct Yap: AsyncParsableCommand {
    #if os(macOS)
    static let configuration = CommandConfiguration(
        abstract: "A CLI for on-device speech transcription.",
        subcommands: [
            Transcribe.self,
            Listen.self,
            Dictate.self,
            ListenAndDictate.self,
            Locales.self,
            MCP_Command.self,
        ],
        defaultSubcommand: Transcribe.self
    )
    #else
    static let configuration = CommandConfiguration(
        abstract: "A CLI for on-device speech transcription.",
        subcommands: [
            Transcribe.self,
            MCP_Command.self,
        ],
        defaultSubcommand: Transcribe.self
    )
    #endif
}
