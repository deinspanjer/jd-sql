# Upstream jd submodule

This repository vendors the upstream josephburnett/jd project as a Git submodule under external/jd.

Purpose:
- Provide visibility into the upstream code, examples, and especially the spec tests used by jd.
- Allow jd-sql implementations to track the jd spec and verify behavior against the same cases.

Location:
- external/jd – the root of the upstream jd repo.
- Specs of interest live under external/jd/spec/test (cases and testdata).

First-time setup after cloning jd-sql:
- task jd-submodule-init

Updating to the latest upstream (fast-forward on current submodule branch):
- task jd-submodule-update

Checking out a specific tag/branch/commit inside the submodule:
- task jd-spec-pull -- REF=v2.2.0

Running upstream spec tests:
- A test wrapper will be provided in jd-sql to execute upstream jd spec cases against jd-sql implementations.
- For now, you can list available cases:
  - task jd-spec-test

Notes:
- Submodules are referenced by commit. After updating the submodule, commit the new submodule pointer in jd-sql to record the exact upstream version.
- Avoid making changes inside external/jd. If changes are needed, send a PR upstream; local modifications can be made on a branch within the submodule but should be avoided for clarity.
