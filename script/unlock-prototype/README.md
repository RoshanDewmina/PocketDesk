# Farside unlock feasibility prototype

Standalone macOS 26+ Swift package. No shipping app target or behavior changes.

Human test instructions and pass/fail/cleanup criteria are in
[`Docs/plans/UNLOCK-PROTOTYPE-FEASIBILITY-TESTS.md`](../../Docs/plans/UNLOCK-PROTOTYPE-FEASIBILITY-TESTS.md).
Only build/sign and policy tests are agent-safe (`./test.sh`, `./build.sh`). Never run
`lab.sh`, the built GUI agent, or the control CLI on Roshan's in-use Mac. Installation,
permission prompts, capture, injection, lock/logout and removal are human lab actions.

Three executables: root XPC broker, Aqua/LoginWindow GUI agent, signed root-only local
CLI. `config.plist` is the lab kill switch; the integrated release gate is design only.
No network endpoint or phone password transport is implemented. Password input is a
hidden TTY prompt for disposable lowercase ASCII/digit credentials on ABC/U.S. layout.
LoginWindow input and CoreHID fallback are not implemented. The security review approves
only bounded lab source; actual capture, unlock and clean uninstall need physical tests.
