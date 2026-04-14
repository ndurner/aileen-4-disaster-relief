This repository consists of two projects:
    - the iOS app in apps/apple
    - the datacenter part in services/datacenter (not implemented)

Dependency and supply-chain policy:
    - Prefer first-party platform frameworks or dependencies we can build from source in our own CI over opaque prebuilt binaries.
    - Do not introduce retired, archived, or effectively unmaintained third-party dependencies unless explicitly approved for a time-boxed prototype.
    - Before adding a native third-party dependency, verify and document:
        - active maintenance and recent releases
        - exact upstream source provenance
        - whether artifacts are built from source reproducibly or by scripts we can run ourselves
        - checksum/signature/provenance coverage for distributed binaries
        - relevant license and patent implications
    - For Apple-native media/toolchain dependencies, prefer one of:
        - direct use of Apple frameworks
        - building upstream open-source components from pinned source revisions in CI and vendoring only the outputs we produced
        - a well-maintained package whose build scripts and provenance are transparent enough that we could take over the build ourselves if needed
    - Avoid curl-and-unzip bootstrap flows for executable/framework artifacts unless the downloaded artifact is our own build output or there is explicit approval with documented risk acceptance.
