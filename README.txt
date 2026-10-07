OrbitBash 1.1.0

This package is the repaired host-side OrbitBash implementation based on the supplied v4/8-step specification and the Gemini-generated step files.

Install locally:
  bash install.sh

Check without starting the interactive UI:
  orbitbash --check

Version:
  orbitbash --version

First run:
  orbitbash
  Enter the master password when prompted.

Change master password:
  orbitbash --set-password

Diagnostics report:
  orbitbash --report

Daemon:
  orbitbash --daemon

Notes:
- The public one-line curl|bash installer URL is intentionally not claimed or invented; host it later and point your command at it.
- orbitbash-in is not included by design.
- Verified automatic cloud-image downloads are implemented for Ubuntu and Debian. Other OS choices work through container backends or Custom URL/ISO/image paths.
- No secret is embedded in this package.
