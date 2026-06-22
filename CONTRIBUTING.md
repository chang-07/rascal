# Contributing to Rascal

Thanks for wanting to help out. The full guide (principles, dev setup, the
test/PR checklist, how the code is wired, style, and where help is wanted) lives
in the README:

**[README → Contributing](README.md#contributing)**

The short version:

- Build & run: `./run.sh` (macOS 13+, Swift 5.9+ toolchain; Command Line Tools are enough).
- Before a PR, make these pass: `./build.sh debug`, `./smoketest.sh`, `./guitest.sh`.
- Add assertions for new behaviour to `Sources/FinderTwo/Tests/TestRunner.swift`.
- Keep it local-first, native, and fast, with no new third-party dependencies.
- Tests and captures stay off-screen, so they never open a visible window or take focus.

Questions or ideas? Open an issue.
