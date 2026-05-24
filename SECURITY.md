# Security Policy

Vigil takes administrator privileges to write to `/Library/PrivilegedHelperTools/` and `/etc/sudoers.d/`, and uses private macOS APIs. Reports of security issues are appreciated.

## Reporting a vulnerability

Email **security@dbuskariol.com** with the details. Please do not open public GitHub issues for security reports.

Include:
- The Vigil version (visible in About / menu bar).
- macOS version.
- A reproduction or proof of concept.
- Whether you've shared this with anyone else.

You should receive an acknowledgement within 7 days.

## Scope

In scope:
- Local privilege escalation beyond the documented scoped sudoers rule (which is intentionally narrow to `pmset` + the approval-status query).
- Sparkle update verification bypass (EdDSA signature, version downgrade, MITM on the appcast).
- Anything that lets a non-admin process modify the privileged helper at `/Library/PrivilegedHelperTools/com.vigil.app.helper`.

Out of scope:
- Vigil intentionally uses private Apple APIs and is not App Store-safe. That is a documented design choice, not a vulnerability.
- The `disable-library-validation` entitlement on the bundled `vigil` CLI is required for the private-framework access Vigil exists to do. Reports that it weakens the runtime contract are correct but already documented.
