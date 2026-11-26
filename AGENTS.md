# Working on dckr

- Follow [LEARNING_PROJECT.md](LEARNING_PROJECT.md) and use [TODO.md](TODO.md) to identify the current learning unit. Write repository files in English and explain the work in the learner's language in chat.
- Confirm the learning question before starting a major implementation step. Advance one learning unit at a time, keeping the change small enough to trace from the CLI to the relevant Linux mechanism.
- Start with Go's standard library where it exposes the mechanism being studied. Add a dependency when it directly supports the learning question.
- Verify behavior in the ARM64 Linux VM. Include a reproducible command or focused comparison and explain which output answers the learning question.
- Explain the key concepts introduced by the experiment before asking one understanding question grounded in its results. A relevant explanation the learner has already given counts. Mark the unit complete in `TODO.md` once its behavior is verified and the learner can explain it.
- Update `TODO.md` as experiments clarify the roadmap. Add a note under `docs/` or a runnable example under `examples/` when it helps explain or reproduce a result.
