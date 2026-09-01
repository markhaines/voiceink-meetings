import Foundation

#if arch(arm64)
    import MLXLMCommon
    import Tokenizers

    /// Fork-owned replacement for mlx-swift-lm's `#huggingFaceTokenizerLoader()` macro.
    ///
    /// WHY THIS EXISTS. That macro is the ONLY thing this project used from the
    /// `MLXHuggingFace` product, and `MLXHuggingFace` is the only target in the resolved
    /// package graph that depends on the `MLXHuggingFaceMacros` compiler-plugin target.
    /// A macro is an executable Xcode builds and RUNS during compilation, so its presence
    /// forced `xcodebuild -skipMacroValidation` on CI (a headless runner cannot answer the
    /// "Trust & Enable" prompt), and that flag disables the trust gate for EVERY macro in
    /// the graph, present and future. Dropping the `MLXHuggingFace` product dependency
    /// takes the macro target out of the build graph entirely, so the flag is no longer
    /// needed and no macro executes at build time at all. See FORK-PATCHES.md.
    ///
    /// The bodies below are the macro's own expansion, transcribed verbatim from
    /// mlx-swift-lm `Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift`
    /// (`TokenizerLoaderMacro` and `TokenizerAdaptorMacro`) at the revision pinned in
    /// Package.resolved, cd1ab3dd98ce. mlx-swift-lm is MIT licensed. Behaviour is
    /// unchanged: same `AutoTokenizer.from(modelFolder:)` call, same adapter shims.
    /// If the pinned mlx-swift-lm revision is bumped, re-check that expansion against this
    /// file.
    struct HuggingFaceTokenizerLoader: MLXLMCommon.TokenizerLoader {
        init() {}

        func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
            let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
            return TokenizerBridge(upstream)
        }
    }

    private struct TokenizerBridge: MLXLMCommon.Tokenizer {
        private let upstream: any Tokenizers.Tokenizer

        init(_ upstream: any Tokenizers.Tokenizer) {
            self.upstream = upstream
        }

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }

        // swift-transformers uses `decode(tokens:)` instead of `decode(tokenIds:)`.
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }

        func convertTokenToId(_ token: String) -> Int? {
            upstream.convertTokenToId(token)
        }

        func convertIdToToken(_ id: Int) -> String? {
            upstream.convertIdToToken(id)
        }

        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            do {
                return try upstream.applyChatTemplate(
                    messages: messages, tools: tools, additionalContext: additionalContext)
            } catch Tokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }
    }
#endif
