# Configure optional CloudKit sync

Barrel keeps CloudKit sync off by default. The unsigned local build reports
sync as unavailable and continues to support all local shelf operations.

Use these instructions only when you want to provision multi-Mac sync for a
signed build.

The repository's SwiftPM build script stages a local app bundle without a
provisioned signature or entitlements. To enable sync, package the executable
in a signed macOS app target or extend your distribution signing pipeline to
apply the entitlements below.

## Prerequisites

You need all of the following resources:

- An active Apple Developer Program membership.
- A Developer Team selected for the app target.
- The iCloud capability with CloudKit enabled.
- An iCloud container named `iCloud.dev.bruno.barrel`.
- A provisioning profile and signature that include the required entitlements.
- A deployed CloudKit production schema before you distribute the app.

The container identifier is a project placeholder. If your Developer Team
can't register it, update the identifier in the source, entitlements, and
CloudKit configuration together.

## Provision the container

1. Open the Certificates, Identifiers & Profiles area of the Apple Developer
   website.
2. Create the iCloud container `iCloud.dev.bruno.barrel`.
3. Associate the container with the app identifier used to sign Barrel.
4. In Xcode, select your signed app target and Developer Team.
5. Add the **iCloud** capability.
6. Enable **CloudKit** and select `iCloud.dev.bruno.barrel`.
7. Regenerate the provisioning profile if Xcode doesn't manage signing for
   you.

The signed app must contain both of these entitlement values:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
  <string>iCloud.dev.bruno.barrel</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
  <string>CloudKit</string>
</array>
```

Barrel checks both values before it creates a CloudKit container. Missing
values produce an **Unavailable** status instead of blocking local storage.

## Prepare the CloudKit schema

Barrel uses the private database and a custom zone named `Barrel`. It stores
records with the `ShelfItem` record type and these fields:

- `payload`: JSON-encoded item metadata.
- `updatedAt`: the conflict-resolution timestamp.
- `modifiedByDeviceID`: the conflict-resolution device identifier.
- `assetPaths`: the relative paths for managed assets.
- `asset0`, `asset1`, and later numbered fields: file assets for the item and
  nested stack children.

Production accepts only fields included in the deployed schema. Exercise the
largest stack shape you plan to support in development, then confirm that its
numbered asset fields appear before you deploy the schema.

To prepare production:

1. Run a signed development build against the development environment.
2. Enable **CloudKit sync** in Barrel settings and choose **Sync Now**.
3. Confirm that the `Barrel` zone and `ShelfItem` record type appear in
   CloudKit Dashboard.
4. Inspect metadata and file assets in the private database.
5. Deploy the schema to production in CloudKit Dashboard.
6. Build and sign the distribution app with the same container entitlements.

## Validate a signed build

Test with two Macs signed into the same iCloud account:

1. Enable **CloudKit sync** on both Macs.
2. Add and rename an item on the first Mac.
3. Choose **Sync Now** on both Macs and confirm the newer version appears.
4. Sync a stack that contains more than one file and open each file.
5. Permanently delete an item, sync both Macs, and confirm it doesn't return.
6. Disable sync during a transfer and confirm local shelf operations continue.

The repository's automated tests cover conflict resolution, tombstones,
cancellation gates, and nested asset installation. They don't contact a real
CloudKit account. You must complete the signed, two-Mac test before release.
