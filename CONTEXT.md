# Domain Context

Shared vocabulary for the dictation pipeline. Architecture reviews and future
changes should use these terms consistently. (Code structure lives in
`CLAUDE.md`; this file is about *what the words mean*.)

## Terms

**Refinement contract**
The single source of truth for how dictated text is cleaned up by the local
LLM: the refinement profiles, the prompt template, the sentinel/header token
lists, and the `llama-cli` argument vector. Defined once in
`Resources/refinement-contract.json`. The macOS app derives it at build time
into `Sources/Voice/Generated/RefinementContract.swift` (regenerate with
`swift scripts/gen-refinement-contract.swift`); the Linux CLI
(`tools/voice-cli/voice.py`) loads the JSON at runtime. Both platforms produce
byte-identical prompts from it — this is the seam that keeps them from drifting.

**Refinement profile**
A named tone preset selected by the user: `balanced`, `email`, `chat`, `blog`,
`literal`, `polished`. Each profile is `id` + `title` + `description` +
`instructions` (the tone guidance fed to the model) + `contentRule` (what the
model may or may not add — e.g. `blog` permits article-style expansion, the rest
forbid added content). Adding a profile is one entry in the refinement contract,
not a code change on either platform.

**Sentinel token**
A model end-of-output marker (`[end of text]`, `<|endoftext|>`,
`<end_of_turn>`, `</s>`) that `llama-cli` may emit. The output-cleanup step
strips these — both as standalone lines and as trailing fragments — so they
never reach the user's text. The token list lives in the refinement contract.
