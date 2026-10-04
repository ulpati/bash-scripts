# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.x | Yes |

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/ulpati/bash-scripts/security/advisories/new),
not in a public issue. Include the script, its version (`--version`), the
command you ran and what happened.

You will receive an acknowledgement within 7 days. Fixes are released as a
new version and credited in the changelog unless you prefer otherwise.

## How security is built in

The scripts follow a lightweight secure software development life cycle:

1. **Requirements**: no script may execute data it reads, modify files outside
   what the user selected, or publish anything without showing it first.
2. **Design**: a STRIDE threat model per tool, in
   [docs/threat-model.md](docs/threat-model.md).
3. **Implementation**: the rules in
   [CONTRIBUTING.md](CONTRIBUTING.md#secure-coding-rules): no `eval`, no
   sourcing of data, argument arrays, validated input, `--` before file names,
   private file permissions.
4. **Verification**: ShellCheck and 87 bats tests, including the injection
   and safety cases, run by CI on Ubuntu for every change.
5. **Maintenance**: GitHub Actions pinned by commit SHA, read-only workflow
   permissions and Dependabot updates.
