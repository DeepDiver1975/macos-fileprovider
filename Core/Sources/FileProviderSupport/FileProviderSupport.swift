// FileProviderSupport: the Mac-only adapter layer that conforms the
// backend-agnostic OwnCloudCore value types to the FileProvider framework.
//
// Everything that imports FileProvider is behind `#if canImport(FileProvider)`
// so the SPM package still builds on Linux for AC-2's backend-contract tier
// (progress.md), where this target compiles to an empty module.
