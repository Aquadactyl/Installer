# Installer changelog

## v1.5-beta

- Target Aquadactyl Panel v1.3-beta by default. Explicit older panel tags remain
  supported; the Installer and panel have independent version numbers.
- Refresh Git installation, update and recovery examples for Installer v1.5-beta
  and Panel v1.3-beta. Preserve the Blueprint inventory and package-path fixes
  from v1.3-beta and v1.4-beta.
- Exercise the real-panel installation/update smoke test against Panel v1.3-beta.
  Retain configuration, application keys, uploads, original addon packages and
  installed-extension metadata during managed updates.

Review the panel and Manta release notes separately. Manta is updated on each
node, not by the panel installer. Panel v1.3-beta and Manta v1.3-beta do not add
configuration or data migrations.
