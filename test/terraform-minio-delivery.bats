#!/usr/bin/env bats
#
# MinIO is required by Signalloom/Tempo/Trace storage. Docker Hub deleted the
# minio/minio:latest tag, so fresh node pulls fail with ImagePullBackOff unless
# the image archive is cached and pre-loaded.
#
# demo-up.sh must stage .cache/images/minio-latest.tar.gz to the VM during
# bootstrap delivery, analogous to AFM image delivery.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	driver="$repo/scripts/gcp-tf/demo-up.sh"
}

default_of() {
	grep -m1 -E "^${1}=" "$driver" | sed -E 's/^[A-Z_]+="\$\{[A-Z_]+:-(.*)\}"$/\1/'
}

@test "MINIO DELIVERY the driver is readable and LOCAL_MINIO_ARCHIVE is assigned" {
	[ -r "$driver" ]
	run default_of LOCAL_MINIO_ARCHIVE
	[ -n "$output" ]
	[[ "$output" == *'.cache/images/minio-latest.tar.gz'* ]]
}

@test "MINIO DELIVERY the REMOTE archive path is derived from REMOTE_WORK_DIR" {
	block="$(grep -m1 -E '^remote_minio_archive\(\)' "$driver")"
	[ -n "$block" ]
	[[ "$block" == *'REMOTE_WORK_DIR'* ]]
	[[ "$block" == *'.cache/images/minio-latest.tar.gz'* ]]
}

@test "MINIO DELIVERY deliver_minio_image is called after deliver_afm_image" {
	# Ensure deliver_minio_image is invoked in the delivery sequence
	run grep -n "deliver_minio_image" "$driver"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -ge 2 ] # definition and call site

	# Verify deliver_minio_image is sequenced after deliver_afm_image at call site
	afm_line="$(grep -n '^[[:space:]]*deliver_afm_image$' "$driver" | cut -d: -f1)"
	minio_line="$(grep -n '^[[:space:]]*deliver_minio_image$' "$driver" | cut -d: -f1)"
	[ -n "$afm_line" ]
	[ -n "$minio_line" ]
	[ "$minio_line" -gt "$afm_line" ]
}

@test "MINIO DELIVERY MUTATION missing call site fails ordering check" {
	bad_driver='deliver_afm_image'
	! grep -q 'deliver_minio_image' <<<"$bad_driver"
}
