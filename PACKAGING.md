# Packaging winghostty for Distribution

This repository publishes Windows user artifacts directly from GitHub Releases.
The public packaging targets are:

- `winghostty-<version>-windows-x64-setup.exe`
- `winghostty-<version>-windows-x64-portable.zip`
- `SHA256SUMS.txt`

Primary distribution URL:

```text
https://github.com/amanthanvi/winghostty/releases
```

## Release Inputs

winghostty releases use plain semver tags such as `v1.3.100`.

Release versioning standard:

- `major.minor` track the Ghostty upstream compatibility line
- `patch` is the winghostty release number on that line
- fork releases should start at patch `100` for a new upstream line

The exact upstream base release is stored in
`dist/windows/release-metadata.json`. For example, a release tagged
`v1.3.105` can still declare `upstreamBaseVersion = 1.3.2`.

The release workflow builds the Windows executable, stages runtime files, then
produces:

1. An Inno Setup installer
2. A portable ZIP
3. SHA256 checksums for published assets
4. A release icon asset used by Chocolatey metadata
5. Generated Chocolatey and Scoop package-manager metadata

Unsigned releases are allowed. SmartScreen friction is expected until code
signing is added.

## Local Packaging

Build the app first:

```powershell
zig build -Demit-exe=true
```

If Zig cannot hydrate its dependency cache automatically in your environment,
seed the Windows build dependency cache first:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-zig-deps.ps1
zig build -Demit-exe=true
```

Then stage release assets:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package-windows.ps1 -Version 1.3.100
```

If Inno Setup is available on the machine, the packaging script can also build
the installer. If it is not installed, the portable artifact and checksums are
still produced so packaging can be validated locally.

To generate the package-manager metadata from staged release assets:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package-package-managers.ps1 `
  -Version 1.3.100 `
  -UpstreamBaseVersion 1.3.2 `
  -FirstForkPatch 100
```

This emits:

- `dist/artifacts/winghostty-<version>-windows-x64/package-managers/chocolatey/`
- `dist/artifacts/winghostty-<version>-windows-x64/package-managers/scoop/`
- `dist/artifacts/winghostty-<version>-windows-x64/package-managers/metadata.json`

## Release Automation

The release workflow can optionally publish to Windows package managers after
the GitHub Release is live. Each path is explicit and configuration-gated.

Release metadata comes from the committed `dist/windows/release-metadata.json`
file, so the release tag, generated package-manager metadata, and GitHub release
notes all agree on the current upstream base.

### WinGet

- Secret: `WINGETCREATE_TOKEN`
- Repo variable: `WINGET_PACKAGE_IDENTIFIER`
- Current automation path: `wingetcreate update ... --submit`

The first WinGet submission still needs a human bootstrap check. The
`wingetcreate new` path remains interactive even when it can infer defaults, so
the workflow only uses the truthful non-interactive update path after the
package already exists in `microsoft/winget-pkgs`.

### Chocolatey

- Secret: `CHOCOLATEY_API_KEY`
- Publish target: `https://push.chocolatey.org/`

Chocolatey Community is happiest on the new numeric release tags. Plain semver
releases pass through unchanged.

### Scoop

- Secret: `SCOOP_BUCKET_TOKEN`
- Repo variable: `SCOOP_BUCKET_REPO`
- Optional repo variables: `SCOOP_BUCKET_BRANCH`, `SCOOP_BUCKET_MANIFEST_PATH`

The workflow updates a manifest in a configured Scoop bucket repository. It
does not attempt to auto-open PRs against `ScoopInstaller/Extras`; that path is
review-driven and should stay explicit.

## Zig Version

This repo is pinned to Zig `0.15.2` in CI. Packaging should use the same Zig
version unless the repo is intentionally updated to a newer one.

## Library Consumers

`libghostty-vt` remains intentionally retained and keeps its existing public
name. The app binary and Windows packaging are rebranded to `winghostty`, but
the library surface is not being renamed as part of this packaging cleanup.
