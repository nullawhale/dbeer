# Windows development-candidate signing policy

These ZIPs are unsigned development candidates. An exact SHA256 and source/build
identity identify bytes but do not authenticate their publisher. Compare a hash
through an independent trusted channel and retain the original archive. Windows
security warnings may appear. No code disables SmartScreen/Defender, changes
system trust, imports certificates or requests an administrator token.

The portable archive requires no installer or elevation. Windows Credential
Manager is the native password store. A future owner-authorized Authenticode
release must use the owner's Windows signing policy and new artifacts; never
replace an existing archive, renumber a release or reuse Apple's development
identity for Windows. Code signing/publication are outside this preparation.
Manual complete-folder updates remain the model; no unattended updater exists.
