resource "google_storage_bucket" "oops" {
  name     = "CHANGEME-project-oops"
  location = "EUROPE-WEST2"
}

# A decoy. Binding IAM on a bucket does not create or destroy the bucket, so the
# scanner must not report this line.
resource "google_storage_bucket_iam_member" "reader" {
  bucket = "CHANGEME-project-somewhere-else"
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:CHANGEME@CHANGEME-project.iam.gserviceaccount.com"
}

# A second decoy: commented-out configuration is not configuration.
# resource "google_storage_bucket" "commented_out" {
#   name = "CHANGEME-project-not-real"
# }
